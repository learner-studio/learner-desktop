import Foundation

// What the coach listens to. The coach only ever sees SpeechSpans (who spoke, from when to
// when on the audio clock) and CallPolls (is a call on). Today both come from screenpipe's
// transcription tables; an on-device speech detector plugs in as another SpeechSource
// without touching the streak, stimulus or trial logic.

// MARK: - Protocols

/// A stretch of confirmed speech.
struct SpeechSpan: Sendable {
    enum Speaker: String { case me, other }

    let speaker: Speaker
    /// First and last moment of the speech, on the audio clock when `audioClock`, else on
    /// the coach's clock at arrival.
    let start: Date
    let end: Date
    let words: Int
    let audioClock: Bool
    /// The source's own timestamp for the audio; arrival minus this is the ingest lag.
    let capturedAt: Date
    /// habit_events metadata.transcription_path: "live_meeting", "background", ...
    let path: String
    /// For the log: which row or event this was.
    let label: String
    /// Adds its words to the turn in progress but no timing (screenpipe's late spans for
    /// the owner, once the microphone times the turn).
    var wordsOnly = false
}

/// Something that hears speech. The coach asks once a second (main thread); a detector
/// that pushes can deliver whenever it likes, as long as it does so on the main thread.
@MainActor
protocol SpeechSource: AnyObject {
    func poll(now: Date, deliver: @escaping @MainActor ([SpeechSpan]) -> Void)
}

struct CallState: Equatable, Sendable {
    let app: String
    let title: String?
}

enum CallPoll: Sendable {
    /// The call in progress, or nil for none.
    case answered(CallState?)
    /// The poll failed; it says nothing about the call.
    case failed(String)
}

/// Something that knows whether a call is on. Asked once a second; delivers on main.
@MainActor
protocol CallSource: AnyObject {
    func poll(deliver: @escaping @MainActor (CallPoll) -> Void)
}

// MARK: - screenpipe HTTP

/// The one way the coach talks to screenpipe's local API. One request per poll name at a
/// time (a slow screenpipe is not hammered with overlapping polls), bounded by `timeout`,
/// every failure counted and logged (the first one as a warning, repeats collapsed, the
/// recovery as info), and every answer delivered on the main thread.
@MainActor
final class ScreenpipeAPI {
    typealias Fetch = @MainActor (URLRequest, @escaping @Sendable (Data?, URLResponse?, Error?) -> Void) -> Void

    static let shared = ScreenpipeAPI(base: URL(string: "http://localhost:3030")!)

    let base: URL
    let timeout: TimeInterval
    private let fetch: Fetch
    private let log = Log("Coach")
    private var inFlight = Set<String>()
    private(set) var failures: [String: Int] = [:]
    private(set) var requests: [String: Int] = [:]

    init(base: URL, timeout: TimeInterval = 2, fetch: Fetch? = nil) {
        self.base = base
        self.timeout = timeout
        self.fetch = fetch ?? { req, done in URLSession.shared.dataTask(with: req, completionHandler: done).resume() }
    }

    /// GET `path`; `done` gets the decoded JSON on success, `failed` the reason otherwise.
    func get(_ name: String, _ path: String, failed: (@MainActor (String) -> Void)? = nil, done: @escaping @MainActor (Any) -> Void) {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.timeoutInterval = timeout
        send(name, req, failed) { json in done(json); return (true, "") }
    }

    /// POST /raw_sql; `done` gets the rows on success (an SQL error is a failure).
    func sql(_ name: String, _ query: String, failed: (@MainActor (String) -> Void)? = nil,
             done: @escaping @MainActor ([[String: Any]]) -> Void) {
        var req = URLRequest(url: base.appendingPathComponent("raw_sql"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])
        req.timeoutInterval = timeout
        send(name, req, failed) { json in
            guard let rows = json as? [[String: Any]] else {
                return (false, "not rows: \(String(describing: json).prefix(160))")
            }
            done(rows)
            return (true, "")
        }
    }

    /// `accept` returns false (and why) when the JSON is not what was asked for.
    private func send(_ name: String, _ req: URLRequest, _ failed: (@MainActor (String) -> Void)?,
                      _ accept: @escaping @MainActor (Any) -> (Bool, String)) {
        guard !inFlight.contains(name) else {
            log.noisy("screenpipe \(name): previous poll still running; skipped")
            return
        }
        inFlight.insert(name)
        requests[name, default: 0] += 1
        fetch(req) { data, response, error in
            var body: Data?
            var why = "no JSON in the response"
            if let error = error {
                why = error.localizedDescription
            } else if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                why = "HTTP \(status)"
            } else {
                body = data
            }
            DispatchQueue.main.async {
                self.inFlight.remove(name)
                let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) }
                if let json = json {
                    let (ok, problem) = accept(json)
                    if ok {
                        if let n = self.failures.removeValue(forKey: name) {
                            self.log.info("screenpipe \(name): answering again after \(n) failed poll(s)")
                        }
                        return
                    }
                    why = problem
                }
                let n = self.failures[name, default: 0] + 1
                self.failures[name] = n
                if n == 1 { self.log.warn("screenpipe \(name) failed: \(why); polling on") }
                else { self.log.noisy("screenpipe \(name) still failing (\(n) in a row): \(why)") }
                failed?(why)
            }
        }
    }
}


// MARK: - screenpipe speech

/// Speech from screenpipe's two transcription tables:
///   meeting_transcript_segments  the live meeting stream (~2.4 s behind the audio);
///                                rows carry the capture START only.
///   audio_transcriptions         chunked background STT (5-12 s behind). While a meeting
///                                stream runs, screenpipe suppresses it and back-fills it
///                                when the meeting ends -- speech the live stream already
///                                delivered, which is dropped here so it is not counted twice.
/// Each table is paged forward from a watermark; the first poll only reads MAX(id), so
/// history is never replayed as live speech.
final class ScreenpipeSpeechSource: SpeechSource {
    final class Stream {
        let name: String
        let table: String
        let page: (Int64) -> String
        private(set) var watermark: Int64?

        init(name: String, table: String, page: @escaping (Int64) -> String) {
            self.name = name
            self.table = table
            self.page = page
        }

        var query: String {
            watermark.map(page) ?? "SELECT COALESCE(MAX(id), 0) AS id FROM \(table) LIMIT 1;"
        }

        /// The rows past the watermark, oldest first; the first answer only sets it.
        func accept(_ rows: [[String: Any]], log: Log) -> [[String: Any]] {
            guard let mark = watermark else {
                let start = rows.first.flatMap { ScreenpipeSpeechSource.int($0["id"]) } ?? 0
                watermark = start
                log.info("screenpipe \(name): connected, reading from id \(start)")
                return []
            }
            let fresh = rows.filter { (ScreenpipeSpeechSource.int($0["id"]) ?? 0) > mark }
            watermark = fresh.compactMap { ScreenpipeSpeechSource.int($0["id"]) }.max().map { max(mark, $0) } ?? mark
            return fresh
        }
    }

    let api: ScreenpipeAPI
    private let log = Log("Coach")
    let live = Stream(name: "live transcripts", table: "meeting_transcript_segments") {
        "SELECT id, device_type, transcript, captured_at FROM meeting_transcript_segments WHERE id > \($0) ORDER BY id ASC LIMIT 50;"
    }
    let background = Stream(name: "background transcripts", table: "audio_transcriptions") {
        "SELECT t.id, t.audio_chunk_id, t.transcription, t.timestamp, c.timestamp AS chunk_timestamp, t.start_time, t.end_time, c.file_path FROM audio_transcriptions t JOIN audio_chunks c ON t.audio_chunk_id = c.id WHERE t.id > \($0) ORDER BY t.id ASC LIMIT 50;"
    }
    /// Audio already delivered by the live stream.
    private(set) var liveCoveredUntil: Date?

    init(api: ScreenpipeAPI) { self.api = api }

    func poll(now: Date, deliver: @escaping @MainActor ([SpeechSpan]) -> Void) {
        api.sql(live.name, live.query) { [self] rows in
            deliver(live.accept(rows, log: log).compactMap { liveSpan($0, now: now) })
        }
        api.sql(background.name, background.query) { [self] rows in
            deliver(background.accept(rows, log: log).compactMap { backgroundSpan($0, now: now) })
        }
    }

    private func liveSpan(_ row: [String: Any], now: Date) -> SpeechSpan? {
        let text = row["transcript"] as? String ?? ""
        guard ScreenpipeSpeechSource.isSpeech(text),
              let at = (row["captured_at"] as? String).flatMap(ScreenpipeSpeechSource.parseDate) else { return nil }
        liveCoveredUntil = max(liveCoveredUntil ?? at, at)
        // Capture start only: never turn a word count into seconds, never extend the turn
        // into unobserved time.
        return SpeechSpan(speaker: (row["device_type"] as? String)?.lowercased() == "input" ? .me : .other,
                          start: at, end: at, words: ScreenpipeSpeechSource.words(text), audioClock: true,
                          capturedAt: at, path: "live_meeting",
                          label: "live #\(ScreenpipeSpeechSource.int(row["id"]) ?? 0) \"\(text.prefix(30))\"")
    }

    private func backgroundSpan(_ row: [String: Any], now: Date) -> SpeechSpan? {
        let text = row["transcription"] as? String ?? ""
        guard ScreenpipeSpeechSource.isSpeech(text) else { return nil }
        let path = row["file_path"] as? String ?? ""
        let startOffset = (row["start_time"] as? NSNumber)?.doubleValue ?? 0
        let endOffset = max(startOffset, (row["end_time"] as? NSNumber)?.doubleValue ?? 0)
        // Audio time = the CHUNK's start + start_time. (Since 10-27 screenpipe stamps the
        // transcription row itself with chunk start + start_time; adding start_time to that
        // would count the offset twice. Older rows carried the chunk start in both.)
        let chunk = ((row["chunk_timestamp"] ?? row["timestamp"]) as? String).flatMap(ScreenpipeSpeechSource.parseDate)
        let start = chunk.map { $0.addingTimeInterval(startOffset) } ?? now
        if let covered = liveCoveredUntil, chunk != nil, start <= covered { return nil }
        return SpeechSpan(speaker: path.contains("input") || path.contains("Microphone") ? .me : .other,
                          start: start, end: chunk.map { $0.addingTimeInterval(endOffset) } ?? now,
                          words: ScreenpipeSpeechSource.words(text), audioClock: chunk != nil,
                          capturedAt: chunk ?? now, path: "background",
                          label: "background #\(ScreenpipeSpeechSource.int(row["id"]) ?? 0) \"\(text.prefix(30))\"")
    }

    // MARK: Parsing

    nonisolated static func int(_ v: Any?) -> Int64? { (v as? NSNumber)?.int64Value }

    nonisolated static func words(_ text: String) -> Int { text.split { $0.isWhitespace }.count }

    /// Whisper hallucinates subtitle credits on silence, and bracketed noise tags are not
    /// speech; anything under two words is a grunt.
    nonisolated static func isSpeech(_ raw: String) -> Bool {
        let text = raw.replacingOccurrences(of: "\\[.*?\\]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\(.*?\\)", with: "", options: .regularExpression)
        let lower = text.lowercased()
        if ["sous-titrage", "subtitles by", "transcription by", "s.t.o.s"].contains(where: lower.contains) { return false }
        return text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.count >= 2
    }

    // screenpipe writes both "…T16:10:12-04:00" and "…T15:12:11.241-04:00"; one formatter
    // handles only one of them. nonisolated(unsafe): ISO8601DateFormatter is thread-safe and
    // these two are never changed after setup.
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated static func parseDate(_ value: String) -> Date? { fractional.date(from: value) ?? plain.date(from: value) }
}

// MARK: - screenpipe calls

/// The call in progress, from screenpipe's /meetings: the first meeting with no end that has
/// lasted `minDuration`. screenpipe opens a "meeting" whenever a call app uses audio (a voice
/// message, a notification sound, a huddle preview); on 10-27 those ran 1-2 min. Shorter
/// ones are not calls here: no call session, no cues, the mic kept.
final class ScreenpipeCallSource: CallSource {
    let api: ScreenpipeAPI
    let minDuration: TimeInterval
    let clock: @Sendable () -> Date

    init(api: ScreenpipeAPI, minDuration: TimeInterval = 180, clock: @escaping @Sendable () -> Date = Date.init) {
        self.api = api
        self.minDuration = minDuration
        self.clock = clock
    }

    func poll(deliver: @escaping @MainActor (CallPoll) -> Void) {
        let (minDuration, now) = (minDuration, clock())
        api.get("meetings", "meetings", failed: { deliver(.failed($0)) }) { json in
            guard let meetings = json as? [[String: Any]] else { deliver(.failed("meetings: not a list")); return }
            deliver(.answered(ScreenpipeCallSource.call(in: meetings, now: now, minDuration: minDuration)))
        }
    }

    /// The first open meeting that has lasted `minDuration` (one without a start time counts).
    nonisolated static func call(in meetings: [[String: Any]], now: Date, minDuration: TimeInterval) -> CallState? {
        let active = meetings.first { m in
            guard !(m["meeting_end"] is String) else { return false }
            guard let start = (m["meeting_start"] as? String).flatMap(ScreenpipeSpeechSource.parseDate) else { return true }
            return now.timeIntervalSince(start) >= minDuration
        }
        return active.map { CallState(app: $0["meeting_app"] as? String ?? "Unknown app", title: $0["title"] as? String) }
    }
}
