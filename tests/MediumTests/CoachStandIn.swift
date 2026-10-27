import Foundation
import Network
import SQLite3
@testable import LearnerDesktop
import TestSupport

/// The parts of screenpipe the coach reads, with rows the test adds as it goes.
final class FakeScreenpipeData {
    private let lock = NSLock()
    private var _live: [[String: Any]] = []
    private var _meetings: [[String: Any]] = []

    func addLive(_ row: [String: Any]) { lock.withLock { _live.append(row) } }
    var meetings: [[String: Any]] {
        get { lock.withLock { _meetings } }
        set { lock.withLock { _meetings = newValue } }
    }

    func answer(_ path: String, _ body: Data) -> Any {
        if path.hasSuffix("/meetings") { return meetings }
        let sql = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["query"] as? String ?? ""
        if sql.contains("MAX(id)") { return [["id": 0]] }
        guard sql.contains("meeting_transcript_segments") else { return [] }
        let mark = Int(sql.components(separatedBy: "id > ").last?.prefix { $0.isNumber } ?? "0") ?? 0
        return lock.withLock { _live.filter { ($0["id"] as? Int ?? 0) > mark } }
    }
}

final class QuietWearable: Wearable {
    var isEnabled = false
    func send(_ m: Modality, intensity: Int, reason: String, context: StimulusContext,
              completion: @escaping (StimulusResult) -> Void) { completion(.notSent("off")) }
}

final class QuietToast: CoachToast {
    func show(streak: TimeInterval, callApp: String?) {}
    func hide() {}
}

func scratchLogger() -> (HabitEventLogger, String) {
    let path = NSTemporaryDirectory() + "coach-medium-\(UUID().uuidString).sqlite"
    let before = ProcessInfo.processInfo.environment["LEARNER_OUTBOX_DB"]
    setenv("LEARNER_OUTBOX_DB", path, 1)
    defer { if let before = before { setenv("LEARNER_OUTBOX_DB", before, 1) } else { unsetenv("LEARNER_OUTBOX_DB") } }
    return (HabitEventLogger(), path)
}

func turnDurations(_ path: String) -> [Double] {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(db, "SELECT turn_duration_sec FROM habit_events WHERE habit_type = 'monologue_streak' ORDER BY rowid", -1, &stmt, nil)
    defer { sqlite3_finalize(stmt) }
    var out: [Double] = []
    while sqlite3_step(stmt) == SQLITE_ROW { out.append(sqlite3_column_double(stmt, 0)) }
    return out
}

/// Ticks `coach` every 100 ms until `condition` holds or `seconds` pass; true if it held.
@MainActor
@discardableResult
func tick(_ coach: SpeakingCoach, until condition: () -> Bool, within seconds: Double) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        coach.tick()
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return condition()
}
