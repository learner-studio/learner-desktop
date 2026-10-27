import Foundation
import Testing
@testable import LearnerDesktop

/// Recorded ai-vault output (fictional titles). ai-vault exits 0 even when its summary
/// lists errors: from 10-23 to 10-27 the menu said "claude: ok" while every run failed.
enum AiVaultOutput {
    static let expired = [
        "Authentication failed\nYour session cookies appear to be expired or invalid.",
        "Errors: 1\n  • Archive process failed: Organization ID not available. Authentication may have failed.",
        "Errors: 1\n  • Archive process failed: page.evaluate: Error: API request failed: 401 ",
        "Errors: 1\n  • Archive process failed: page.evaluate: Error: API request failed: 403 ",
    ]
    static let failed = "Errors: 2\n  • Archive process failed: net::ERR_INTERNET_DISCONNECTED\n\nCompleted with 2 errors"
    static let crashed = "[1047/1239] ✗ Failed: A fictional title - browser.newContext: Target page, context or browser has been closed"
    static let ok = "Conversations:\n  Archived: 3\n\nErrors: 0\n\nCompleted in 40.2s"
    static let nothingNew = "  Only New: Yes (skipping previously downloaded)\n[1/2] Skipped: Untitled (already downloaded)\nConversations:\n  Archived: 0\n\nErrors: 0\n\nCompleted in 0.2s"
    static let rateLimited = "Errors: 1\n  • Archive process failed: page.evaluate: Error: API request failed: 429 Too Many Requests"
}

@Suite("Chat export", .timeLimit(.minutes(1))) struct ExportTests {
    @Test func expiredLoginsAreRecognised() {
        for sample in AiVaultOutput.expired {
            #expect(VaultExport.classify(status: 0, stopped: nil, output: sample) == .loginExpired, "\(sample)")
        }
    }

    @Test func otherErrorsAreFailuresNotOk() {
        #expect(VaultExport.classify(status: 0, stopped: nil, output: AiVaultOutput.failed) == .failed("failed (see vault-export.log)"))
    }

    @Test func aRateLimitIsNotAnExpiredLogin() {
        #expect(VaultExport.classify(status: 0, stopped: nil, output: AiVaultOutput.rateLimited) == .rateLimited)
    }

    @Test func aCrashedBrowserIsAFailure() {
        #expect(VaultExport.classify(status: 0, stopped: nil, output: AiVaultOutput.crashed) == .failed("browser crashed (see vault-export.log)"))
    }

    @Test func aStuckRunIsAFailure() {
        #expect(VaultExport.classify(status: nil, stopped: "no output for 10 min", output: "[3/9] Waiting 20.1s before next fetch...")
                == .failed("stuck, stopped (no output for 10 min)"))
        #expect(VaultExport.classify(status: nil, stopped: "could not start: No such file", output: "")
                == .failed("ai-vault could not start: No such file"))
    }

    @Test func aNonZeroExitWithQuietOutputIsAFailure() {
        #expect(VaultExport.classify(status: 1, stopped: nil, output: "TypeError: x is undefined") == .failed("exit 1 (see vault-export.log)"))
    }

    @Test func aCleanRunIsOkWithItsCount() {
        #expect(VaultExport.classify(status: 0, stopped: nil, output: AiVaultOutput.ok) == .ok(archived: 3))
        #expect(VaultExport.classify(status: 0, stopped: nil, output: AiVaultOutput.nothingNew) == .ok(archived: 0))
    }

    @Test func theExportRunsHourlyAndAFailureBacksOffFromFifteenMinutesToTwoHours() {
        let c = VaultExport.Config()
        #expect(c.period == 3600)
        #expect(c.firstRun == 120)
        #expect(c.rateLimitRetry == 30 * 60)
        var b = c.failureBackoff
        b.jitter = 0
        var waits: [TimeInterval] = []
        for _ in 0..<5 { waits.append(b.failed()) }
        let expected: [TimeInterval] = [900, 1800, 3600, 7200, 7200]
        #expect(waits == expected)
    }

    @Test func aMissingCLIFailsAndSaysSoAndStillKicksTheArchive() {
        let dir = TempDir("export")
        let job = JobName("export")
        var kicked = 0
        var c = VaultExport.Config()
        c.jobName = job.name
        c.cliPath = { nil }
        c.orphanMarkers = []
        c.voice = nil
        c.loginsPath = dir.file("logins.json")
        c.afterRun = { kicked += 1 }
        let export = VaultExport(config: c)
        #expect(describe(export.runOnce()) == "failed: ai-vault CLI not found")
        #expect(export.lastSummary.contains("ai-vault CLI not found"))
        #expect(export.lastRun != nil)
        #expect(kicked == 1)
    }

    @Test func expiredLoginsSurviveARestart() {
        let dir = TempDir("logins")
        dir.write("logins.json", #"{"chatgpt": 12.5}"#)
        let job = JobName("logins")
        var c = VaultExport.Config()
        c.jobName = job.name
        c.loginsPath = dir.file("logins.json")
        // Signing in kicks a run: keep it away from the real ai-vault, archive and server.
        c.cliPath = { nil }
        c.orphanMarkers = []
        c.voice = nil
        c.afterRun = nil
        let export = VaultExport(config: c)
        #expect(export.expiredLogins == ["chatgpt"])
        export.signedIn("chatgpt")
        #expect(export.expiredLogins.isEmpty)
        #expect(dir.read("logins.json") == "{}")
        // Let the kicked run end before the fixture goes.
        let deadline = Date().addingTimeInterval(5)
        while export.job.snapshot.lastRun == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        #expect(export.job.snapshot.summary == "ai-vault CLI not found")
    }
}
