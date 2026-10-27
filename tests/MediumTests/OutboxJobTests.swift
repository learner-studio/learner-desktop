import Foundation
import Testing
@testable import LearnerDesktop

private final class OutboxFixture {
    let dir = TempDir("outbox")
    let job = JobName("outbox")
    let heartbeat = JobName("heartbeat")
    let server: HTTPStandIn
    let logger: HabitEventLogger
    let sender: OutboxSender

    init(turns: Int, handler: @escaping (HTTPStandIn.Request) -> HTTPStandIn.Response) throws {
        server = try HTTPStandIn(handler)
        logger = HabitEventLogger(path: dir.file("trials.sqlite"))
        var c = OutboxSender.Config()
        c.jobName = job.name
        c.heartbeatJobName = heartbeat.name
        c.heartbeatFirstRun = 0
        sender = OutboxSender(logger: logger, rpc: LearnerRPC(baseURL: server.baseURL + "/learner-api", key: { _ in "medium-key" }), config: c)
        for i in 0..<turns {
            logger.logTurn(occurredAt: Date(timeIntervalSince1970: 1_767_000_000 + Double(i)), sessionId: "s-\(i)", callApp: "Solo Mic",
                           treatmentArm: "baseline", turnDurationSec: 40, wordsSpoken: 90, warningFiredAt: 30, shockFiredAt: nil,
                           latencyToYieldSec: nil, breached30s: true, breached60s: false, wasRewarded: false)
        }
        logger.waitUntilIdle()
    }

    var ids: [String] { (logger.unsentEvents(limit: 1000) ?? []).compactMap { $0["eventId"] as? String } }
}

private func accepted(_ req: HTTPStandIn.Request) -> HTTPStandIn.Response {
    .json(200, ["data": ["accepted": (req.data?["events"] as? [Any])?.count ?? 0, "duplicates": 0]])
}

private func eventIds(_ req: HTTPStandIn.Request) -> [String] {
    (req.data?["events"] as? [[String: Any]] ?? []).compactMap { $0["eventId"] as? String }
}

@Suite("Outbox job (real TCP stand-in)", .serialized, .timeLimit(.minutes(1))) struct OutboxJobTests {
    @Test func theJobSendsTheQueueOverHTTP() throws {
        let f = try OutboxFixture(turns: 3, handler: accepted)
        f.sender.job.kick("test")
        #expect(waitFor(10) { f.logger.getUnsyncedCount() == 0 })
        let req = try #require(f.server.requests.first)
        #expect(req.method == "POST")
        #expect(req.path == "/learner-api/rpc/recordHabitEvents")
        #expect(req.header("x-api-key") == "medium-key")
        #expect(req.data?["clientId"] as? String == "ben-mbp")
        #expect(eventIds(req).count == 3)
        #expect(f.sender.lastStatus == "sent 3 (3 accepted, 0 duplicates)")
    }

    @Test func aBadRequestParksTheRowInsteadOfRetryingForever() throws {
        let f = try OutboxFixture(turns: 3, handler: accepted)
        let bad = f.ids[1]
        f.server.handler = { req in eventIds(req).contains(bad) ? .json(400, ["message": "invalid input"]) : accepted(req) }
        let s = run(f.sender.job)
        #expect(s.summary == "sent 2, parked 1")
        #expect(f.logger.parkedCount() == 1 && f.logger.getUnsyncedCount() == 0)
        let n = f.server.requests.count
        #expect(describe(f.sender.runOnce()) == "idle") // nothing left: the parked row is not resent
        #expect(f.server.requests.count == n)
    }

    @Test func aServerOutageBacksOffThenRecovers() throws {
        let f = try OutboxFixture(turns: 2) { _ in .json(503, [:]) }
        let s = run(f.sender.job)
        #expect(s.summary == "server error 503" && s.failures == 1)
        let wait = s.nextRun.timeIntervalSince(s.lastRun!)
        #expect(wait > 0 && wait <= 2.01)
        f.server.handler = accepted
        let s2 = run(f.sender.job)
        #expect(s2.failures == 0 && s2.problemSince == nil)
        #expect(f.logger.getUnsyncedCount() == 0)
    }

    @Test func nothingListeningIsAFailureThatNamesTheError() throws {
        let f = try OutboxFixture(turns: 1, handler: accepted)
        f.server.stop()
        Thread.sleep(forTimeInterval: 0.2)
        let s = run(f.sender.job)
        #expect(s.summary.hasPrefix("server unreachable: "))
        #expect(s.summary.contains("NSURLErrorDomain"))
    }

    @Test func theQuitDrainIsBoundedByItsDeadlineEvenWhenTheServerHangs() throws {
        let f = try OutboxFixture(turns: 2) { req in .json(200, [:], delay: 5) }
        let started = Date()
        let left = f.sender.drain(until: Date().addingTimeInterval(1))
        let took = Date().timeIntervalSince(started)
        #expect(took < 1.6, "drain took \(took) s")
        #expect(left == 2)
    }

    @Test func aRefusedKeyBlocksUntilSendNow() throws {
        let f = try OutboxFixture(turns: 1) { _ in .json(401, [:]) }
        let s = run(f.sender.job)
        #expect(s.blocked && f.sender.keyProblem)
        f.server.handler = accepted
        let before = f.sender.job.snapshot.lastRun
        f.sender.sendNow()
        #expect(waitFor(10) { f.sender.job.snapshot.lastRun != before })
        #expect(!f.sender.keyProblem)
        #expect(f.logger.getUnsyncedCount() == 0)
    }

    @Test func theHeartbeatJobSendsTheTraysInput() throws {
        let f = try OutboxFixture(turns: 0) { _ in .json(200, ["data": ["serverTime": "2026-10-27T12:00:00Z"]]) }
        f.sender.setHeartbeatInput { ["clientId": "ben-mbp", "appVersion": "test", "captureState": "recording", "outboxDepth": 0] }
        let s = run(f.sender.heartbeatJob)
        #expect(s.summary == "sent")
        let req = try #require(f.server.requests.first)
        #expect(req.path == "/learner-api/rpc/recordAppHeartbeat")
        #expect(req.data?["captureState"] as? String == "recording")
    }
}

@Suite("Job state survives a restart", .timeLimit(.minutes(1))) struct JobPersistenceTests {
    @Test func aFailureKeepsItsBackoffAndABlockStaysBlocked() {
        let name = JobName("persist")
        let first = Job(name.name, period: 3600, backoff: Backoff(base: 600, max: 3600)) { _ in .failed("boom") }
        let s = run(first)
        #expect(s.failures == 1 && s.summary == "boom")
        let again = Job(name.name, period: 3600, backoff: Backoff(base: 600, max: 3600)) { _ in .ok("fine") }
        #expect(again.snapshot.failures == 1)
        #expect(abs(again.snapshot.nextRun.timeIntervalSince(s.nextRun)) < 1)
        #expect(again.snapshot.problemSince != nil)

        let blockedName = JobName("persist-blocked")
        let b = Job(blockedName.name, period: 1, backoff: Backoff(base: 1, max: 1)) { _ in .blocked("needs the user") }
        run(b)
        var ran = false
        let b2 = Job(blockedName.name, period: 1, backoff: Backoff(base: 1, max: 1)) { _ in ran = true; return .ok("x") }
        #expect(b2.snapshot.blocked)
        #expect(b2.problem == "needs the user")
        b2.tick()
        Thread.sleep(forTimeInterval: 0.3)
        #expect(!ran)
    }
}
