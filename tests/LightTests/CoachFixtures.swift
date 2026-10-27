import Foundation
import SQLite3
@testable import LearnerDesktop

// Stand-ins for everything around the coach: speech, calls, the wristband, the toast,
// the clock. The settings store and the trial logger are the real ones, pointed at a
// throwaway UserDefaults suite and a throwaway SQLite file.

final class FakeSpeech: SpeechSource {
    var queued: [SpeechSpan] = []
    func poll(now: Date, deliver: @escaping ([SpeechSpan]) -> Void) {
        let spans = queued
        queued = []
        deliver(spans)
    }
}

final class FakeCalls: CallSource {
    var next: CallPoll = .answered(nil)
    func poll(deliver: @escaping (CallPoll) -> Void) { deliver(next) }
}

final class FakeWearable: Wearable {
    struct Sent: Equatable {
        let modality: Modality
        let intensity: Int
        let arm: String
    }
    var isEnabled = true
    var sent: [Sent] = []
    var reasons: [String] = []
    /// What the "device" answers, per modality (default: acknowledged over Bluetooth).
    var answers: [Modality: StimulusResult] = [:]

    func send(_ modality: Modality, intensity: Int, reason: String, context: StimulusContext,
              completion: @escaping (StimulusResult) -> Void) {
        sent.append(Sent(modality: modality, intensity: intensity, arm: context.arm))
        reasons.append(reason)
        completion(answers[modality] ?? StimulusResult(delivered: true, transport: .ble, detail: "BLE acknowledged by wristband"))
    }
}

final class FakeToast: CoachToast {
    var visible = false
    var shows = 0
    func show(streak: TimeInterval, callApp: String?) { visible = true; shows += 1 }
    func hide() { visible = false }
}

/// A throwaway UserDefaults suite.
func scratchDefaults() -> UserDefaults {
    let name = "learner-coach-test-" + UUID().uuidString
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

private let envLock = NSLock()

/// A HabitEventLogger writing to its own temp file (it reads LEARNER_OUTBOX_DB at init).
func scratchLogger() -> (HabitEventLogger, String) {
    let path = NSTemporaryDirectory() + "coach-trials-\(UUID().uuidString).sqlite"
    return envLock.withLock {
        let before = ProcessInfo.processInfo.environment["LEARNER_OUTBOX_DB"]
        setenv("LEARNER_OUTBOX_DB", path, 1)
        let logger = HabitEventLogger()
        if let before = before { setenv("LEARNER_OUTBOX_DB", before, 1) } else { unsetenv("LEARNER_OUTBOX_DB") }
        return (logger, path)
    }
}

/// habit_events rows of one type, oldest first, with metadata decoded.
func trialRows(_ path: String, type: String = "monologue_streak") -> [[String: Any]] {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    let sql = """
        SELECT session_id, call_app, call_category, treatment_arm, turn_duration_sec, words_spoken,
               warning_fired_at, shock_fired_at, latency_to_yield_sec, breached_30s, breached_60s,
               was_rewarded, metadata FROM habit_events WHERE habit_type = '\(type)' ORDER BY rowid
        """
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }
    let names = ["session_id", "call_app", "call_category", "treatment_arm", "turn_duration_sec", "words_spoken",
                 "warning_fired_at", "shock_fired_at", "latency_to_yield_sec", "breached_30s", "breached_60s", "was_rewarded"]
    var rows: [[String: Any]] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        var row: [String: Any] = [:]
        for (i, name) in names.enumerated() {
            let c = Int32(i)
            switch sqlite3_column_type(stmt, c) {
            case SQLITE_NULL: break
            case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(stmt, c))
            case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, c)
            default: row[name] = String(cString: sqlite3_column_text(stmt, c))
            }
        }
        let meta = String(cString: sqlite3_column_text(stmt, 12))
        row["metadata"] = (try? JSONSerialization.jsonObject(with: Data(meta.utf8))) as? [String: Any] ?? [:]
        rows.append(row)
    }
    return rows
}

/// The coach wired to stand-ins, on a clock the test moves.
final class CoachRig {
    let speech = FakeSpeech()
    let calls = FakeCalls()
    let wearable = FakeWearable()
    let toast = FakeToast()
    let settings: CoachSettings
    let logger: HabitEventLogger
    let dbPath: String
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date
    var sounds: [String] = []
    private(set) var coach: SpeakingCoach!

    init(mode: AssignmentMode, call: String? = "Zoom", settings: CoachSettings? = nil) {
        self.settings = settings ?? CoachSettings(defaults: scratchDefaults())
        (logger, dbPath) = scratchLogger()
        now = t0
        self.settings.assignmentMode = mode
        calls.next = .answered(call.map { CallState(app: $0, title: "Weekly sync") })
        coach = makeCoach()
        coach.tick()
    }

    func makeCoach() -> SpeakingCoach {
        SpeakingCoach(settings: settings, speech: speech, calls: calls, wearable: wearable, toast: toast,
                      logger: logger, clock: { [unowned self] in self.now },
                      playSound: { [unowned self] in self.sounds.append($0); return true })
    }

    /// I speak from `from` to `to` seconds after t0, heard 1 s after it ends.
    func say(_ from: TimeInterval, _ to: TimeInterval, speaker: SpeechSpan.Speaker = .me, words: Int = 10) {
        let start = t0.addingTimeInterval(from), end = t0.addingTimeInterval(to)
        speech.queued.append(SpeechSpan(speaker: speaker, start: start, end: end, words: words, audioClock: true,
                                        capturedAt: start, path: "live_meeting", label: "fixture \(Int(from))-\(Int(to))"))
        now = max(now, end.addingTimeInterval(1))
        coach.tick()
    }

    /// Continuous speech in 4 s spans from `from` to `to`.
    func monologue(_ from: TimeInterval, _ to: TimeInterval) {
        var t = from
        while t < to {
            say(t, min(t + 4, to))
            t += 4
        }
    }

    func wait(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        coach.tick()
    }

    var rows: [[String: Any]] {
        logger.waitUntilIdle()
        return trialRows(dbPath)
    }

    var interventions: [[String: Any]] { (rows.last?["metadata"] as? [String: Any])?["interventions"] as? [[String: Any]] ?? [] }
}

func meta(_ row: [String: Any]?) -> [String: Any] { row?["metadata"] as? [String: Any] ?? [:] }
