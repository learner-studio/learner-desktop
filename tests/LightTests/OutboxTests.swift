import Foundation
import Testing
@testable import LearnerDesktop

/// A scratch trial database with `count` turns, and an outbox sending to a stub.
final class OutboxFixture {
    let dir = TempDir("outbox")
    let job = JobName("outbox")
    let heartbeat = JobName("heartbeat")
    let logger: HabitEventLogger
    let stub: StubTransport
    let sender: OutboxSender
    private final class KeySource {
        let lock = NSLock()
        var reads = 0
        let key: String?
        init(_ key: String?) { self.key = key }
        func read() -> String? { lock.withLock { reads += 1; return key } }
    }
    private let keys: KeySource

    var keyReadCount: Int { keys.lock.withLock { keys.reads } }

    init(turns: Int, key: String? = "test-key", handler: @escaping (StubTransport.Seen) -> HTTPReply) {
        let keys = KeySource(key)
        self.keys = keys
        logger = HabitEventLogger(path: dir.file("trials.sqlite"))
        stub = StubTransport(handler)
        var c = OutboxSender.Config()
        c.jobName = job.name
        c.heartbeatJobName = heartbeat.name
        let rpc = LearnerRPC(baseURL: "http://stand-in.invalid", transport: stub, key: { _ in keys.read() })
        sender = OutboxSender(logger: logger, rpc: rpc, config: c)
        for i in 0..<turns { OutboxFixture.logTurn(logger, i) }
        logger.waitUntilIdle()
    }

    static func logTurn(_ logger: HabitEventLogger, _ i: Int) {
        logger.logTurn(occurredAt: Date(timeIntervalSince1970: 1_767_000_000 + Double(i)), sessionId: "session-\(i)", callApp: "Solo Mic",
                       treatmentArm: "baseline", turnDurationSec: 31.5, wordsSpoken: 80, warningFiredAt: 30, shockFiredAt: nil,
                       latencyToYieldSec: nil, breached30s: true, breached60s: false, wasRewarded: false, metadata: ["source": "test"])
    }

    /// Event ids in send order.
    var ids: [String] { (logger.unsentEvents(limit: 1000) ?? []).compactMap { $0["eventId"] as? String } }
}

func accepted(_ s: StubTransport.Seen) -> HTTPReply {
    StubTransport.json(200, ["data": ["accepted": s.eventIds.count, "duplicates": 0]])
}

@Suite("Trial outbox", .timeLimit(.minutes(1))) struct OutboxTests {
    @Test func sendsEverythingAndMarksItSent() {
        let f = OutboxFixture(turns: 3, handler: accepted)
        #expect(describe(f.sender.runOnce()) == "ok: sent 3")
        #expect(f.logger.getUnsyncedCount() == 0)
        #expect(f.sender.lastStatus == "sent 3 (3 accepted, 0 duplicates)")
        #expect(f.sender.lastSentAt != nil)
        let r = f.stub.seen[0]
        #expect(r.path == "/rpc/recordHabitEvents")
        #expect(r.headers["x-api-key"] == "test-key")
        // Nothing left: idle, no request.
        #expect(describe(f.sender.runOnce()) == "idle")
        #expect(f.stub.seen.count == 1)
    }

    @Test(arguments: [400, 422])
    func aRefusedRowIsIsolatedAndParkedNotRetriedForever(status: Int) {
        let f = OutboxFixture(turns: 5, handler: accepted)
        let bad = f.ids[3]
        f.stub.handler = { s in s.eventIds.contains(bad) ? StubTransport.json(status, ["message": "bad row"]) : accepted(s) }
        #expect(describe(f.sender.runOnce()) == "ok: sent 4, parked 1")
        #expect(f.logger.getUnsyncedCount() == 0)
        #expect(f.logger.parkedCount() == 1)
        #expect(f.sender.lastStatus.contains("parked event \(bad)") || f.sender.lastStatus.hasPrefix("sent"))
        // Parked rows are never sent again.
        let before = f.stub.seen.count
        #expect(describe(f.sender.runOnce()) == "idle")
        #expect(f.stub.seen.count == before)
    }

    @Test func aLoneOversizedRowIsParked() {
        let f = OutboxFixture(turns: 1) { _ in StubTransport.status(413) }
        #expect(describe(f.sender.runOnce()) == "ok: sent 0, parked 1")
        #expect(f.logger.parkedCount() == 1)
        #expect(f.sender.lastStatus.hasSuffix("too large (413)"))
    }

    @Test func tooLargeHalvesTheBatch() {
        let f = OutboxFixture(turns: 4) { s in s.eventIds.count > 1 ? StubTransport.status(413) : accepted(s) }
        #expect(describe(f.sender.runOnce()) == "ok: sent 4")
        #expect(f.stub.seen.map(\.eventIds.count) == [4, 2, 1, 1, 1, 1])
    }

    @Test(arguments: [401, 403])
    func aRefusedKeyBlocksAndIsReadAgainAfterSendNow(status: Int) {
        let f = OutboxFixture(turns: 2) { _ in StubTransport.status(status) }
        #expect(describe(f.sender.runOnce()).hasPrefix("blocked: device key refused (HTTP \(status))"))
        #expect(f.logger.getUnsyncedCount() == 2)
        #expect(f.sender.lastStatus == "device key refused (HTTP \(status))")
        let reads = f.keyReadCount
        f.stub.handler = accepted
        #expect(describe(f.sender.runOnce()) == "ok: sent 2")
        #expect(f.keyReadCount == reads + 1) // the refused key was forgotten
    }

    @Test func noKeyBlocksWithoutARequest() {
        let f = OutboxFixture(turns: 1, key: nil, handler: accepted)
        #expect(describe(f.sender.runOnce()).hasPrefix("blocked: no device key"))
        #expect(f.stub.seen.isEmpty)
    }

    @Test func serverErrorsAndNoAnswerAreRetryableFailures() {
        let f = OutboxFixture(turns: 1) { _ in StubTransport.status(503) }
        #expect(describe(f.sender.runOnce()) == "failed: server error 503")
        f.stub.handler = { _ in HTTPReply(status: 0, body: nil, error: "The request timed out. (NSURLErrorDomain -1001)") }
        #expect(describe(f.sender.runOnce()) == "failed: server unreachable: The request timed out. (NSURLErrorDomain -1001)")
        #expect(f.logger.getUnsyncedCount() == 1)
    }

    @Test func otherClientErrorsWaitHalfAnHourInsteadOfRetryingForever() {
        let f = OutboxFixture(turns: 1) { _ in StubTransport.status(404) }
        #expect(describe(f.sender.runOnce()) == "failed: unexpected HTTP 404 from http://stand-in.invalid (retry 1800)")
        #expect(f.logger.getUnsyncedCount() == 1)
    }

    @Test func theQuitDrainNeverRunsPastItsDeadline() {
        // Every call hangs until its timeout: the drain must cut each one to the time left.
        let f = OutboxFixture(turns: 3) { _ in HTTPReply(status: 0, body: nil, error: "slow") }
        let slow = SlowTransport()
        let sender = OutboxSender(logger: f.logger, rpc: LearnerRPC(baseURL: "http://x.invalid", transport: slow, key: { _ in "k" }),
                                  config: { var c = OutboxSender.Config(); c.jobName = f.job.name + "-d"; c.heartbeatJobName = f.heartbeat.name + "-d"; return c }())
        let started = Date()
        let left = sender.drain(until: Date().addingTimeInterval(1))
        let took = Date().timeIntervalSince(started)
        #expect(left == 3)
        #expect(took < 1.5, "drain took \(took) s")
        #expect(slow.timeouts.allSatisfy { $0 <= 1.0 })
        try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/.ai-aggregator/jobs/\(f.job.name)-d.json")
    }

    @Test func theDrainSendsWhatIsQueued() {
        let f = OutboxFixture(turns: 3, handler: accepted)
        #expect(f.sender.drain(until: Date().addingTimeInterval(5)) == 0)
    }

    @Test func theHeartbeatIsBuiltOnlyWhenItIsSent() {
        let f = OutboxFixture(turns: 0) { _ in StubTransport.json(200, ["data": ["serverTime": "2026-10-27T12:00:00Z"]]) }
        #expect(describe(f.sender.sendHeartbeat()) == "idle") // no input provider yet
        var built = 0
        f.sender.setHeartbeatInput { built += 1; return ["clientId": "ben-mbp", "outboxDepth": 0] }
        #expect(built == 0)
        #expect(describe(f.sender.sendHeartbeat()) == "ok: sent")
        #expect(built == 1)
        #expect(f.stub.seen[0].path == "/rpc/recordAppHeartbeat")
        #expect((f.stub.seen[0].body?["data"] as? [String: Any])?["outboxDepth"] as? Int == 0)
        f.stub.handler = { _ in StubTransport.status(401) }
        #expect(describe(f.sender.sendHeartbeat()).hasPrefix("blocked: device key refused"))
        f.stub.handler = { _ in StubTransport.status(400) }
        #expect(describe(f.sender.sendHeartbeat()) == "failed: heartbeat refused (HTTP 400) (retry 1800)")
    }

    /// Ported from tests/test_pavlok_audit.py: intervention records persist without
    /// becoming speaking trials.
    @Test func interventionRecordsPersistWithoutCountingAsTrials() throws {
        let dir = TempDir("audit")
        let logger = HabitEventLogger(path: dir.file("behavior_experiments.sqlite"))
        for phase in ["requested", "transport_result"] {
            logger.logTurn(habitType: "pavlok_intervention", sessionId: "manual_test_fixture", callApp: "Manual device test",
                           callCategory: "device_test", treatmentArm: "manual_test", turnDurationSec: 0, wordsSpoken: 0,
                           warningFiredAt: nil, shockFiredAt: nil, latencyToYieldSec: nil, breached30s: false, breached60s: false,
                           wasRewarded: false, metadata: ["operation_id": "fixture", "phase": phase, "modality": "beep",
                                                          "intensity_percent": 40, "device_acknowledged": phase == "transport_result"])
        }
        logger.waitUntilIdle()
        #expect(logger.getTotalTrialCount() == 0)
        #expect(logger.getUnsyncedCount() == 2)
        logger.close()

        let reopened = HabitEventLogger(path: dir.file("behavior_experiments.sqlite"))
        let rows = try #require(reopened.unsentEvents(limit: 10))
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0["habitType"] as? String == "pavlok_intervention" })
        let meta = rows.map { $0["metadata"] as? [String: Any] ?? [:] }
        #expect(meta.map { $0["operation_id"] as? String } == ["fixture", "fixture"])
        #expect(Set(meta.compactMap { $0["device_acknowledged"] as? Bool }) == [false, true])
        #expect(meta.allSatisfy { $0["intensity_percent"] as? Int == 40 })
        reopened.close()
        // After close, a late turn is dropped (logged), not a crash.
        reopened.logTurn(sessionId: "late", callApp: nil, treatmentArm: "x", turnDurationSec: 1, wordsSpoken: 0, warningFiredAt: nil,
                         shockFiredAt: nil, latencyToYieldSec: nil, breached30s: false, breached60s: false, wasRewarded: false)
        reopened.waitUntilIdle()
    }

    @Test func anUnreadableDatabaseIsAFailureNotAnEmptyOutbox() {
        let dir = TempDir("baddb")
        try! FileManager.default.createDirectory(atPath: dir.file("trials.sqlite"), withIntermediateDirectories: true) // a directory: will not open
        let logger = HabitEventLogger(path: dir.file("trials.sqlite"))
        let job = JobName("baddb"), hb = JobName("baddb-hb")
        var c = OutboxSender.Config()
        c.jobName = job.name
        c.heartbeatJobName = hb.name
        let sender = OutboxSender(logger: logger, rpc: LearnerRPC(baseURL: "http://x.invalid", transport: StubTransport(accepted), key: { _ in "k" }), config: c)
        #expect(logger.unsentEvents(limit: 10) == nil)
        #expect(logger.unsyncedCount() == nil)
        #expect(describe(sender.runOnce()) == "failed: cannot read the trial database")
        #expect(logger.problem == "the trial database will not open")
    }
}

/// Answers nothing, after waiting out each call's timeout; records the timeouts it was given.
final class SlowTransport: HTTPTransport {
    private let lock = NSLock()
    private var given: [TimeInterval] = []
    var timeouts: [TimeInterval] { lock.withLock { given } }

    func send(_ request: URLRequest, timeout: TimeInterval) -> HTTPReply {
        lock.withLock { given.append(timeout) }
        Thread.sleep(forTimeInterval: timeout)
        return HTTPReply(status: 0, body: nil, error: "no answer in \(Int(timeout)) s")
    }
}
