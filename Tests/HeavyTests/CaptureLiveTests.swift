import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// The live capture stack on :3030, READ-ONLY: GET /health, SELECTs through /raw_sql,
// ~/.screenpipe/store.bin, and `tool preflight` (which only reads). Nothing
// is started, stopped or written. Needs LEARNER_HEAVY=1 (scripts/test.sh heavy sets it)
// and a running screenpipe; each suite skips with the reason otherwise.

enum Live {
    static let env = ProcessInfo.processInfo.environment
    static let heavy = env["LEARNER_HEAVY"] == "1"
    static let destructive = heavy && env["LEARNER_HEAVY_DESTRUCTIVE"] == "1"
    static let remote = heavy && env["LEARNER_REMOTE_E2E"] == "1"
    static let api = env["SCREENPIPE_API"] ?? "http://localhost:3030"

    static func json(_ url: String, body: Any? = nil) -> Any? {
        let r = Tools.http(url, method: body == nil ? "GET" : "POST", json: body, timeout: 8)
        guard r.status == 200, let d = r.data else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }

    static var health: [String: Any]? { json(api + "/health") as? [String: Any] }
    static let screenpipeUp = heavy && health != nil

    static func sql(_ query: String) -> Any? { json(api + "/raw_sql", body: ["query": query]) }
}

@Suite("Live screenpipe (read-only)", .quietLog, .enabled(if: Live.heavy, "heavy lane: set LEARNER_HEAVY=1"),
       .enabled(if: Live.screenpipeUp, "screenpipe is not answering on :3030"))
struct CaptureLiveTests {
    let health = Live.health ?? [:]

    @Test func audioPipelineIsHealthyAndRealtime() {
        #expect(health["status"] as? String == "healthy")
        #expect(health["audio_status"] as? String == "ok")
        // Chunked mode reintroduces the transcription backlog the coach cannot live with.
        #expect((health["audio_pipeline"] as? [String: Any])?["transcription_mode"] as? String == "realtime")
    }

    @Test(.enabled(if: !LiveMachine.screenpipeWaiting, "screenpipe has paused capture (screen locked)"))
    func capturesBothTheMicrophoneAndSystemAudio() {
        let devices = ((health["audio_pipeline"] as? [String: Any])?["audio_devices"] as? [String] ?? []).map { $0.lowercased() }
        #expect(devices.contains { $0.contains("output") || $0.contains("system audio") || $0.contains("tap") }, "no meeting-side device in \(devices)")
        #expect(devices.contains { $0.contains("input") || $0.contains("mic") || $0.contains("airpods") }, "no microphone in \(devices)")
    }

    @Test func healthReportsTheVersionStampedOntoTurns() {
        #expect((health["version"] as? String)?.isEmpty == false)
    }

    @Test func rawSQLReturnsEveryColumnTheAppPolls() throws {
        let rows = Live.sql("SELECT t.id, t.audio_chunk_id, t.transcription, t.timestamp, t.start_time, t.end_time, c.file_path FROM audio_transcriptions t JOIN audio_chunks c ON t.audio_chunk_id=c.id ORDER BY t.id DESC LIMIT 1;")
        let list = try #require(rows as? [[String: Any]], "raw_sql returned an error: \(String(describing: rows))")
        try #require(!list.isEmpty, "no transcriptions recorded yet")
        for column in ["id", "audio_chunk_id", "transcription", "timestamp", "start_time", "end_time", "file_path"] {
            #expect(list[0][column] != nil, "missing \(column)")
        }
    }

    @Test func everyTimestampIsAFormatTheAppParses() throws {
        // The two shapes the coach's ISO8601 formatters accept; anything else silently
        // demotes a turn to the arrival clock.
        let rows = try #require(Live.sql("SELECT timestamp FROM audio_transcriptions ORDER BY id DESC LIMIT 200;") as? [[String: Any]])
        let shape = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$"#
        let bad = rows.compactMap { $0["timestamp"] as? String }.filter { $0.range(of: shape, options: .regularExpression) == nil }
        #expect(bad.isEmpty, "timestamps the app would fail to parse: \(bad.prefix(5))")
    }

    @Test func aTranscriptionIsStampedFromItsChunkNotWhenItWasWritten() throws {
        // The coach takes audio time from the chunk (chunk timestamp + start_time). screenpipe
        // has stamped transcriptions with the chunk start (before 10-27) and with chunk start +
        // start_time (since); both are audio time. A write-time stamp would shift every turn.
        let rows = try #require(Live.sql("SELECT t.timestamp t_ts, c.timestamp c_ts, t.start_time FROM audio_transcriptions t JOIN audio_chunks c ON t.audio_chunk_id=c.id ORDER BY t.id DESC LIMIT 20;") as? [[String: Any]])
        let parse = { (v: Any?) in (v as? String).flatMap(ScreenpipeSpeechSource.parseDate) }
        let off = rows.filter { r in
            guard let t = parse(r["t_ts"]), let c = parse(r["c_ts"]) else { return true }
            let start = (r["start_time"] as? NSNumber)?.doubleValue ?? 0
            return abs(t.timeIntervalSince(c)) > 0.01 && abs(t.timeIntervalSince(c) - start) > 0.05
        }
        #expect(off.isEmpty, "rows whose stamp is neither the chunk start nor chunk start + start_time: \(off.prefix(3))")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.screenpipe/store.bin"), "no ~/.screenpipe/store.bin"))
    func liveSettingsMatchTheCommittedCapture() throws {
        let live = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: NSHomeDirectory() + "/.screenpipe/store.bin"))) as? [String: Any])["settings"] as? [String: Any] ?? [:]
        let expected = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: toolsRepoRoot() + "/config/screenpipe-settings.json"))) as? [String: Any])["settings"] as? [String: Any] ?? [:]
        // Preflight's own comparison, so redacted entries mean the same thing here.
        let drift = expected.filter { k, v in (v as? String) != Preflight.redacted && !(live[k].map { Preflight.equal($0, v) } ?? (v is NSNull)) }.keys.sorted()
        #expect(drift.isEmpty, "settings drifted from config/screenpipe-settings.json (update it if deliberate): \(drift)")
    }

    @Test func preflightPassesAgainstTheLiveStack() {
        let r = ChildProcess.run(appBinary, ["tool", "preflight"], timeout: 120, stderr: true)
        #expect(r.status == 0, "preflight reported drift:\n\(r.output)")
    }
}
