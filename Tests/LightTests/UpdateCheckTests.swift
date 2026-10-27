import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// Ported from tests/test_update_check.py: a screenpipe update starts a logged, fenced-in
// Claude Code session, once per version, after the version has settled.

private func check(_ dir: TempDir, _ job: JobName) -> ScreenpipeUpdateCheck {
    var c = ScreenpipeUpdateCheck.Config()
    c.jobName = job.name
    c.statePath = dir.file("state.json")
    c.logDir = dir.file("logs")
    c.claudePath = "/nonexistent/claude"
    c.installedVersion = { nil }
    return ScreenpipeUpdateCheck(config: c)
}

private func read(_ relative: String) -> String { (try? String(contentsOfFile: Vault.repo + "/" + relative, encoding: .utf8)) ?? "" }

@Suite("screenpipe update check", .quietLog, .timeLimit(.minutes(1))) struct UpdateCheckTests {
    @Test func theFirstSightingIsABaselineNotARun() {
        let dir = TempDir("uc"), job = JobName("uc")
        let uc = check(dir, job)
        #expect(uc.decide(version: "2.7.120") == .baseline("2.7.120"))
        #expect(uc.decide(version: "2.7.120") == .nothing)
        #expect(uc.decide(version: nil) == .nothing)
    }

    @Test func waitsForTheVersionToSettleThenRunsOncePerVersion() {
        let dir = TempDir("uc"), job = JobName("uc")
        let uc = check(dir, job)
        let t0 = Date()
        _ = uc.decide(version: "2.7.120", now: t0)
        #expect(uc.config.settleSeconds >= 300)
        #expect(uc.decide(version: "2.7.121", now: t0) == .waiting("2.7.121"))
        #expect(uc.decide(version: "2.7.121", now: t0.addingTimeInterval(uc.config.settleSeconds - 1)) == .waiting("2.7.121"))
        #expect(uc.decide(version: "2.7.121", now: t0.addingTimeInterval(uc.config.settleSeconds))
                == .run(reason: "screenpipe updated from 2.7.120 to 2.7.121"))
        #expect(uc.decide(version: "2.7.121", now: t0.addingTimeInterval(9999)) == .nothing)
        // Remembered across a restart.
        #expect(check(dir, job).decide(version: "2.7.121") == .nothing)
    }

    @Test func aVersionThatChangesAgainWhileSettlingRestartsTheWait() {
        let dir = TempDir("uc"), job = JobName("uc")
        let uc = check(dir, job)
        let t0 = Date()
        _ = uc.decide(version: "1", now: t0)
        _ = uc.decide(version: "2", now: t0)
        #expect(uc.decide(version: "3", now: t0.addingTimeInterval(500)) == .waiting("3"))
        #expect(uc.decide(version: "3", now: t0.addingTimeInterval(500 + uc.config.settleSeconds - 1)) == .waiting("3"))
    }

    @Test func aClaudeThatCannotStartIsLoggedAsAFailedRun() {
        let dir = TempDir("uc"), job = JobName("uc")
        let uc = check(dir, job)
        let outcome = uc.run(reason: "manual test")
        #expect(describe(outcome).hasPrefix("failed: STATUS: RUN FAILED") || describe(outcome).hasPrefix("failed: STATUS: NO REPORT"))
        #expect(dir.read("logs/index.log").contains("manual test"))
        #expect(uc.lastRunSummary != nil)
        #expect(!uc.isRunning)
    }

    // MARK: Phase tag

    @Test func everyTurnCarriesTheCapturePhase() throws {
        // The same versions as the test below: CaptureEnvironment is process-wide.
        CaptureEnvironment.screenpipeAppVersion = "2.7.1"
        CaptureEnvironment.screenpipeVersion = "0.3.0"
        let rig = CoachRig(mode: .baseline)
        rig.monologue(0, 12)
        rig.say(13, 14, speaker: .other)
        let m = meta(try #require(rig.rows.first))
        #expect(m["capture_phase"] as? String == "screenpipe 2.7.1 / engine 0.3.0")
        #expect(m["screenpipe_app_version"] as? String == "2.7.1")
        #expect(m["screenpipe_version"] as? String == "0.3.0")
    }

    @Test func theTurnTagMatchesTheGrowthBookPhaseName() {
        CaptureEnvironment.screenpipeAppVersion = "2.7.1"
        CaptureEnvironment.screenpipeVersion = "0.3.0"
        #expect(CaptureEnvironment.capturePhase == "screenpipe 2.7.1 / engine 0.3.0")
        #expect(CapturePhase.phaseName(app: "2.7.1", engine: "0.3.0") == CaptureEnvironment.capturePhase)
    }

    // MARK: The agent's fence

    private var permissions: [String: Any] {
        let data = FileManager.default.contents(atPath: Vault.repo + "/config/screenpipe-update-agent.json")!
        return (try! JSONSerialization.jsonObject(with: data) as! [String: Any])["permissions"] as! [String: Any]
    }

    @Test func noBlanketShellOrEditAccess() {
        let allow = permissions["allow"] as! [String], deny = permissions["deny"] as! [String]
        for rule in ["Bash", "Bash(*)", "Bash(:*)", "Edit", "Write"] { #expect(!allow.contains(rule), "\(rule)") }
        for rule in ["Bash(kill:*)", "Bash(pkill:*)", "Bash(rm:*)", "Bash(git push:*)", "Edit", "Write"] { #expect(deny.contains(rule), "\(rule)") }
    }

    @Test func everyFixInTheRunbookIsPermitted() {
        let runbook = read("docs/screenpipe-update-runbook.md")
        let allow = permissions["allow"] as! [String]
        for command in ["launchctl setenv SCREENPIPE_SKIP_ONBOARDING 1", "open -g -a /Applications/screenpipe.app",
                        "\"/Users/benpollack/Applications/Learner Desktop.app/Contents/MacOS/learner-desktop\" tool preflight",
                        "git add config/screenpipe-settings.json"] {
            #expect(runbook.contains(command), "\(command)")
            #expect(allow.contains("Bash(\(command))"), "\(command)")
        }
        #expect(runbook.contains("tool start-capture-phase"))
        #expect(allow.contains { $0.hasPrefix("Bash(") && $0.contains("learner-desktop\" tool start-capture-phase:*)") })
    }

    @Test func canReadTheLogsItIsToldToCheck() {
        let dirs = permissions["additionalDirectories"] as! [String]
        #expect(dirs.contains { $0.hasSuffix("/.screenpipe") })
        #expect(dirs.contains { $0.hasSuffix("/.ai-aggregator") })
    }

    @Test func theRunbookHasItsReportAndHardLimits() {
        let runbook = read("docs/screenpipe-update-runbook.md")
        for status in ["STATUS: OK", "STATUS: FIXED", "STATUS: NEEDS ATTENTION"] { #expect(runbook.contains(status)) }
        #expect(runbook.contains("Signal screenpipe"))
        #expect(runbook.contains("Never read transcript or screen"))
    }
}
