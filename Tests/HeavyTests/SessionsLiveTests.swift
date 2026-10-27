import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// Live, read-only: the uploader running on this Mac is healthy by learner-server's rules.
@Suite("CLI sessions uploader (live)", .quietLog,
       .enabled(if: ProcessInfo.processInfo.environment["LEARNER_HEAVY"] == "1", "heavy lane: set LEARNER_HEAVY=1"),
       .enabled(if: FileManager.default.fileExists(atPath: CLISessions.statusPath), "the uploader has not run on this Mac"))
struct SessionsLiveTests {
    @Test func theUploaderIsHealthyAndUpToDate() throws {
        let s = try #require(CLISessions.readStatus())
        #expect(s.state != "auth-error" && s.state != "error", "\(s.state): \(s.lastError ?? "")")
        #expect(s.files > 0)
        #expect(s.failed == 0, "\(s.failed) files failed to upload")
    }
}
