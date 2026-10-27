import AppKit
import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// Live, read-only: the running screenpipe will not sit waiting on a sign-in. Either it was
// launched with SCREENPIPE_SKIP_ONBOARDING=1, or its server answers (it is recording).
@Suite("screenpipe sign-in flag (live)", .quietLog, .enabled(if: ProcessInfo.processInfo.environment["LEARNER_HEAVY"] == "1"))
struct ScreenpipeFlagTests {
    @Test func theRunningScreenpipeCanRecordWithoutASignIn() throws {
        let running = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "screenpi.pe").first,
                                    "screenpipe is not running")
        let env = ChildProcess.commandLine(running.processIdentifier, includeEnvironment: true) ?? ""
        let answers = HTTPProbe.get(StatusProbe.screenpipeURL + "/health").status == 200
        #expect(env.contains("SCREENPIPE_SKIP_ONBOARDING=1") || answers)
    }

    @Test func launchdCarriesTheFlagForTheNextLaunch() {
        let r = ChildProcess.run("/bin/launchctl", ["getenv", "SCREENPIPE_SKIP_ONBOARDING"], timeout: 5)
        #expect(r.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
    }
}

// Live, read-only: the status workflow against the real machine.
@Suite("Status (live)", .quietLog, .enabled(if: ProcessInfo.processInfo.environment["LEARNER_HEAVY"] == "1"))
struct LiveStatusTests {
    @Test func screenpipeAndTheServerAnswerAndProblemsAreNamed() {
        #expect(StatusProbe.screenpipe() != .stopped("port 3030 closed"))
        #expect(HTTPProbe.get(StatusProbe.serverHealthURL, timeout: 10).status == 200)
    }
}
