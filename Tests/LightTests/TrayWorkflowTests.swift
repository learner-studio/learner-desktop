import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// The tray's own workflows: the quit sequence, the heartbeat it sends, and which problem
// the tray shows when several are true at once.
@Suite("Tray workflows", .tags(.light, .shutdown, .status), .quietLog, .timeLimit(.minutes(1))) struct TrayWorkflowTests {

    @Test func quitSendsEveryQueuedTrialBeforeClosingTheDatabase() throws {
        let dir = TempDir("quit")
        let logger = HabitEventLogger(path: dir.file("trials.sqlite"))
        @Sendable func turn(_ i: Int) {
            logger.logTurn(sessionId: "s-\(i)", callApp: "Solo Mic", treatmentArm: "baseline", turnDurationSec: 12,
                           wordsSpoken: 30, warningFiredAt: nil, shockFiredAt: nil, latencyToYieldSec: nil,
                           breached30s: false, breached60s: false, wasRewarded: false)
        }
        for i in 0..<3 { turn(i) }
        let order = Locked<[String]>([])
        let seenBySend = Locked(-1)
        let steps = TrayAppManager.shutdownSteps(
            finishTurn: { order.withLock { $0.append("turn") }; turn(3) },   // the in-flight turn
            logger: logger,
            drain: { _ in order.withLock { $0.append("send") }; seenBySend.value = logger.getUnsyncedCount(); return 0 },
            stopJobs: { order.withLock { $0.append("jobs") } },
            stopTunnel: { order.withLock { $0.append("tunnel") } })
        _ = capturingLog { Shutdown.run(steps, total: 10) }
        #expect(order.value == ["turn", "send", "jobs", "tunnel"])
        #expect(seenBySend.value == 4)   // all four rows, read from an open database
        let send = try #require(steps.map(\.name).firstIndex(of: "send queued trials"))
        let close = try #require(steps.map(\.name).firstIndex(of: "close the trial database"))
        #expect(send < close)
    }

    @Test func theHeartbeatMatchesTheContractInEveryCaptureState() throws {
        let schema = Schema.input("recordAppHeartbeat")
        for capture: AppStatus.Capture in [.unknown, .recording, .degraded("audio stalled"), .stopped("port 3030 closed")] {
            var s = AppStatus(capture: capture, outboxDepth: 3)
            s.problems = [Problem(source: "Export", text: "rate limited")]
            for (sent, version) in [(Date?.none, String?.none), (Date(), "0.3.0")] {
                let body = TrayAppManager.heartbeat(s, appVersion: "1.0.0", screenpipeVersion: version, capturePhase: nil,
                                                    lastSentAt: sent, lastExport: sent, outboxStatus: "sent 3")
                let json = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: body))
                #expect(Schema.validate(json, schema).isEmpty, "\(capture): \(Schema.validate(json, schema))")
            }
        }
    }

    @Test func theWorstProblemShowsWhenEveryProblemIsTrue() {
        // Worst first; each is removed in turn and the next one must show.
        var s = AppStatus(capture: .stopped("port 3030 closed"), serverReachable: false, loginItemBlocked: true)
        s.problems = [Problem(source: "Helper:tunnel", text: "down"), Problem(source: "Archive", text: "HTTP 503"),
                      Problem(source: "Trials", text: "db"), Problem(source: "Export", text: "login"),
                      Problem(source: "Outbox", text: "key refused")]
        var seen: [String] = []
        for _ in 0..<9 {
            let kind = TrayState.make(s, coach: CoachLive()).kind
            seen.append(kind)
            switch kind {
            case "login-item": s.loginItemBlocked = false
            case "outbox": s.problems.removeAll { $0.source == "Outbox" }
            case "server": s.serverReachable = true
            case "screenpipe": s.capture = .degraded("audio stalled")
            case "export": s.problems.removeAll { $0.source == "Export" }
            case "trials": s.problems.removeAll { $0.source == "Trials" }
            case let k where k.hasPrefix("problem:"): s.problems.removeFirst()
            case "screenpipe-degraded": s.capture = .recording
            default: break
            }
        }
        #expect(seen == ["login-item", "outbox", "server", "screenpipe", "export", "trials",
                         "problem:Helper:tunnel", "problem:Archive", "screenpipe-degraded"])
    }

    @Test func aLoginItemChangeIsLogged() {
        let on = AppStatus(capture: .recording)
        var off = on
        off.loginItemBlocked = true
        let lines = capturingLog { StatusProbe.logChanges(from: on, to: off, serverError: nil) }
        #expect(lines.contains { $0.contains("WARN") && $0.contains("Login Items") })
        let back = capturingLog { StatusProbe.logChanges(from: off, to: on, serverError: nil) }
        #expect(back.contains { $0.contains("allowed in Login Items again") })
    }
}
