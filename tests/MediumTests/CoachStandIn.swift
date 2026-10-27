import Foundation
import Network
import SQLite3
@testable import LearnerDesktop

/// A local HTTP server standing in for screenpipe (loopback only). It can answer, drop
/// every connection (screenpipe restarting) or hold requests forever (screenpipe stuck).
final class StandInServer {
    enum Mode { case answer, refuse, hang }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "coach-stand-in")
    private let lock = NSLock()
    private var _mode = Mode.answer
    private var _hits: [String] = []
    private var held: [NWConnection] = []
    private let handler: (_ path: String, _ body: Data) -> Any
    private(set) var port: UInt16 = 0

    var mode: Mode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue } }
    }
    var hits: [String] { lock.withLock { _hits } }

    init(handler: @escaping (_ path: String, _ body: Data) -> Any) throws {
        self.handler = handler
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func stop() {
        listener.cancel()
        lock.withLock { held.forEach { $0.cancel() } }
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        switch mode {
        case .refuse: c.cancel()
        case .hang: lock.withLock { held.append(c) }
        case .answer: read(c, Data())
        }
    }

    private func read(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self = self else { return }
            var buf = buffer
            if let data = data { buf.append(data) }
            guard let split = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if done || error != nil { c.cancel() } else { self.read(c, buf) }
                return
            }
            let head = String(decoding: buf[..<split.lowerBound], as: UTF8.self)
            let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            let body = buf[split.upperBound...]
            guard body.count >= length else { return self.read(c, buf) }
            let path = String(head.split(separator: " ").dropFirst().first ?? "/")
            self.lock.withLock { self._hits.append(path) }
            let json = (try? JSONSerialization.data(withJSONObject: self.handler(path, Data(body)))) ?? Data("[]".utf8)
            let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n"
            c.send(content: Data(response.utf8) + json, completion: .contentProcessed { _ in c.cancel() })
        }
    }
}

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
