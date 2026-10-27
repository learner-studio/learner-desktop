import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// CLI sessions: the uploader's status.json read with learner-server's health rules.
@Suite("CLI sessions status", .quietLog) struct SessionsTests {
    func write(_ dir: TempDir, _ json: [String: Any]) -> String {
        let path = dir.file("status.json")
        FileManager.default.createFile(atPath: path, contents: try! JSONSerialization.data(withJSONObject: json))
        return path
    }
    let iso = ISO8601DateFormatter()

    @Test func aHealthyUploaderHasNoProblem() throws {
        let dir = TempDir()
        let now = Date()
        let s = try #require(CLISessions.readStatus(write(dir, [
            "version": 1, "clientId": "ben-mbp", "pid": 4242, "state": "ok", "files": 88, "pendingFiles": 0, "pendingBytes": 0,
            "lastSuccessAt": iso.string(from: now), "nextRunAt": iso.string(from: now.addingTimeInterval(20)),
            "diverged": [], "failed": [], "lastError": NSNull()])))
        #expect(CLISessions.problem(s, now: now, alive: { _ in true }) == nil)
        #expect(CLISessions.summary(s).hasPrefix("88 files · ok"))
    }

    @Test func eachUnhealthyStateIsAProblem() throws {
        let dir = TempDir()
        let now = Date()
        func status(_ change: [String: Any]) throws -> CLISessions.Status {
            var base: [String: Any] = ["pid": 4242, "state": "ok", "nextRunAt": iso.string(from: now.addingTimeInterval(10))]
            base.merge(change) { _, new in new }
            return try #require(CLISessions.readStatus(write(dir, base)))
        }
        let alive = { (_: Int32) in true }
        #expect(CLISessions.problem(try status(["state": "auth-error", "lastError": "HTTP 403"]), now: now, alive: alive)?.contains("refused the device key") == true)
        #expect(CLISessions.problem(try status(["state": "error", "lastError": "disk full"]), now: now, alive: alive) == "error: disk full")
        #expect(CLISessions.problem(try status([:]), now: now, alive: { _ in false })?.hasPrefix("not running") == true)
        // More than 2× the interval overdue is a stall; just due is not.
        #expect(CLISessions.problem(try status(["nextRunAt": iso.string(from: now.addingTimeInterval(-61))]), now: now, alive: alive)?.hasPrefix("stalled") == true)
        #expect(CLISessions.problem(try status(["nextRunAt": iso.string(from: now.addingTimeInterval(-30))]), now: now, alive: alive) == nil)
        // Per-file trouble is listed, not an outage.
        let perFile = try status(["diverged": [["provider": "claude", "path": "p", "reason": "r"]], "failed": [["provider": "codex", "path": "q", "reason": "r"]]])
        #expect(CLISessions.problem(perFile, now: now, alive: alive) == nil)
        #expect(CLISessions.summary(perFile).contains("1 diverged") && CLISessions.summary(perFile).contains("1 failed"))
        #expect(CLISessions.problem(nil) != nil)
    }

    @Test func noUploaderRunsWhenTheServerIsOnThisMac() {
        let saved = CLISessions.serverOnThisMac
        defer { CLISessions.serverOnThisMac = saved }
        CLISessions.serverOnThisMac = true
        #expect(CLISessions.helper(key: { "k" }) == nil)
        CLISessions.serverOnThisMac = false
        #expect(CLISessions.helper(key: { "k" }) != nil)
    }
}
