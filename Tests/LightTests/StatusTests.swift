import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// The status workflow: what the tray shows for each state, worst first, and that every
// change is logged.
@Suite("Tray status", .tags(.light, .status), .timeLimit(.minutes(1)), .quietLog, .serialized) struct StatusTests {
    let healthy = AppStatus(capture: .recording, serverReachable: true, chatgptChats: 600, claudeChats: 33)

    @Test func healthyShowsTheChatCount() {
        let t = TrayState.make(healthy, coach: CoachLive())
        #expect(t.kind == "ok" && t.title == "🧠 🟢 633")
    }

    @Test func beforeTheFirstCheckItSaysStartingNotHealthy() {
        #expect(TrayState.make(AppStatus(), coach: CoachLive()).kind == "starting")
        #expect(TrayState.make(AppStatus(), coach: CoachLive(alert: true, duration: "1:01")).kind == "talk-alert")
    }

    @Test func eachProblemHasItsOwnTrayState() {
        func kind(_ change: (inout AppStatus) -> Void, coach: CoachLive = CoachLive()) -> String {
            var s = healthy
            change(&s)
            return TrayState.make(s, coach: coach).kind
        }
        #expect(kind({ $0.loginItemBlocked = true }) == "login-item")
        #expect(kind({ $0.problems = [Problem(source: "Outbox", text: "device key refused")] }) == "outbox")
        #expect(kind({ $0.serverReachable = false }) == "server")
        #expect(kind({ $0.capture = .stopped("port 3030 closed") }) == "screenpipe")
        #expect(kind({ $0.problems = [Problem(source: "Export", text: "claude login expired")] }) == "export")
        #expect(kind({ $0.problems = [Problem(source: "Trials", text: "the trial database will not open")] }) == "trials")
        #expect(kind({ $0.problems = [Problem(source: "Archive", text: "HTTP 503")] }) == "problem:Archive")
        #expect(kind({ $0.problems = [Problem(source: "Helper:tunnel", text: "tunnel keeps exiting")] }) == "problem:Helper:tunnel")
        #expect(kind({ $0.capture = .degraded("vision ok, audio stalled") }) == "screenpipe-degraded")
        // A rate limit is waiting (yellow): below every red problem, above a degraded capture.
        let limited = Problem(source: "Export", text: "chatgpt: rate limited", waiting: true)
        #expect(kind({ $0.problems = [limited] }) == "waiting:Export")
        #expect(TrayState.make({ var s = AppStatus(capture: .recording); s.problems = [limited]; return s }(), coach: CoachLive()).title.contains("🟡"))
        #expect(kind({ $0.problems = [limited]; $0.capture = .degraded("audio stalled") }) == "waiting:Export")
        #expect(kind({ $0.problems = [limited, Problem(source: "Archive", text: "HTTP 503")] }) == "problem:Archive")
        #expect(kind({ _ in }, coach: CoachLive(call: "Zoom")) == "call")
    }

    @Test func aMonologueOutranksEveryProblemAndAWarningOutranksTheRest() {
        var broken = healthy
        broken.serverReachable = false
        broken.loginItemBlocked = true
        #expect(TrayState.make(broken, coach: CoachLive(alert: true, warning: true, duration: "1:05")).kind == "talk-alert")
        #expect(TrayState.make(broken, coach: CoachLive(warning: true, duration: "0:35")).kind == "talk-warning")
        #expect(TrayState.make(broken, coach: CoachLive()).kind == "login-item")
    }

    @Test func theSyncTagNamesWhereTheProblemIs() {
        var s = healthy
        s.problems = [Problem(source: "Archive", text: "HTTP 503")]
        #expect(TrayState.make(s, coach: CoachLive()).title == "🧠 🔴 SYNC")
        s.problems = [Problem(source: "Helper:tunnel", text: "down")]
        #expect(TrayState.make(s, coach: CoachLive()).title == "🧠 🔴 TUNNEL")
    }

    @Test func everyChangeIsLoggedAndNothingElse() {
        var down = healthy
        down.capture = .stopped("port 3030 closed")
        down.serverReachable = false
        down.problems = [Problem(source: "Export", text: "chatgpt: rate limited")]
        var lines = capturingLog { StatusProbe.logChanges(from: healthy, to: down, serverError: "timed out") }
        #expect(lines.contains { $0.contains("[Status] screenpipe: recording -> stopped (port 3030 closed)") })
        #expect(lines.contains { $0.contains("WARN") && $0.contains("learner-server unreachable (timed out)") })
        #expect(lines.contains { $0.contains("WARN") && $0.contains("problem: Export: chatgpt: rate limited") })
        lines = capturingLog { StatusProbe.logChanges(from: down, to: down, serverError: nil) }
        #expect(lines.isEmpty)
        lines = capturingLog { StatusProbe.logChanges(from: down, to: healthy, serverError: nil) }
        #expect(lines.contains { $0.contains("learner-server reachable again") })
        #expect(lines.contains { $0.contains("cleared: Export") })
    }
}
