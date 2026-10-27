import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

/// A fake `ai-vault`: prints $FIXTURES/<provider>.out (exit $FIXTURES/<provider>.status);
/// with $FIXTURES/<provider>.hang it prints one line, ignores SIGTERM and hangs.
private let fakeAiVault = """
    #!/bin/sh
    provider="$2"
    echo "$provider" >> "$FIXTURES/calls.log"
    if [ -f "$FIXTURES/$provider.hang" ]; then
      trap '' TERM
      echo "[1/9] Fetching..."
      echo $$ > "$FIXTURES/sh.pid"
      sleep 30 &
      echo $! > "$FIXTURES/sleep.pid"
      wait
      exit 0
    fi
    cat "$FIXTURES/$provider.out"
    exit "$(cat "$FIXTURES/$provider.status" 2>/dev/null || echo 0)"
    """

private final class ExportFixture {
    let dir = TempDir("export")
    let job = JobName("export")
    private let runsAfter = Locked(0)
    var afterRuns: Int { runsAfter.value }
    let export: VaultExport

    init(voice: VoiceTranscripts? = nil, cli: String? = nil, afterRun: (@Sendable () -> Void)? = nil, configure: (inout VaultExport.Config) -> Void = { _ in }) {
        let script = dir.write("bin/ai-vault", fakeAiVault, mode: 0o755)
        dir.write("ai-vault-config.json", "{}")
        var c = VaultExport.Config()
        c.jobName = job.name
        c.cliPath = { cli ?? script }
        c.env = ["PATH": "/usr/bin:/bin", "FIXTURES": dir.path]
        c.logPath = dir.file("vault-export.log")
        c.loginsPath = dir.file("logins.json")
        c.aiVaultConfig = dir.file("ai-vault-config.json")
        // Generous: a busy machine can take seconds to start a script. The stall test
        // shortens it itself.
        c.stallTimeout = 8
        c.killGrace = 0.5
        c.maxRunTime = 60
        c.orphanMarkers = []
        c.voice = voice
        configure(&c)
        c.afterRun = { [runsAfter] in runsAfter.withLock { $0 += 1 }; afterRun?() }
        export = VaultExport(config: c)
    }

    func output(_ provider: String, _ text: String, status: Int = 0) {
        dir.write("\(provider).out", text)
        dir.write("\(provider).status", "\(status)")
    }

    var calls: [String] { dir.read("calls.log").split(separator: "\n").map(String.init) }
}

@Suite("Export job (fake ai-vault, real processes)", .tags(.medium, .chats), .quietLog, .serialized, .timeLimit(.minutes(1))) struct ExportJobTests {
    @Test func anExpiredProviderIsSkippedUntilItsLoginChanges() throws {
        let f = ExportFixture()
        f.output("claude", Fixture.aiVaultOk)
        f.output("chatgpt", Fixture.aiVaultExpired)
        let s = run(f.export.job)
        #expect(!s.blocked)
        #expect(s.summary == "claude: ok (3 new), chatgpt: login expired")
        #expect(f.export.expiredLogins == ["chatgpt"])
        #expect(f.afterRuns == 1)
        #expect(f.dir.read("vault-export.log").contains("Archived: 3"))

        run(f.export.job)
        #expect(f.calls == ["claude", "chatgpt", "claude"])

        // Signed in from a terminal: ai-vault's config changed, so chatgpt is tried again.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: f.dir.file("ai-vault-config.json"))
        f.output("chatgpt", Fixture.aiVaultOk)
        let s3 = run(f.export.job)
        #expect(f.calls.suffix(2) == ["claude", "chatgpt"])
        #expect(f.export.expiredLogins.isEmpty)
        #expect(s3.summary == "claude: ok (3 new), chatgpt: ok (3 new)")
    }

    @Test func aBlockedExportReChecksItsLoginsAndClearsItself() throws {
        // On 10-27 an offline Mac read as "both logins expired"; a block must not be forever.
        let f = ExportFixture(configure: { $0.blockedRecheck = 1 })
        f.output("claude", Fixture.aiVaultExpired)
        f.output("chatgpt", Fixture.aiVaultExpired)
        #expect(run(f.export.job).blocked)
        f.output("claude", Fixture.aiVaultOk)
        f.output("chatgpt", Fixture.aiVaultOk)
        let before = try #require(f.export.job.snapshot.lastRun)
        #expect(waitFor(3) { f.export.job.snapshot.nextRun <= Date() })
        f.export.job.tick()   // the re-check is due: it runs, and tries the "expired" logins again
        #expect(waitFor(15) { f.export.job.snapshot.lastRun != before })
        #expect(!f.export.job.snapshot.blocked)
        #expect(f.export.expiredLogins.isEmpty)
        #expect(f.export.job.problem == nil)
    }

    @Test func allLoginsExpiredBlocksUntilASignIn() {
        let f = ExportFixture()
        f.output("claude", Fixture.aiVaultExpired)
        f.output("chatgpt", Fixture.aiVaultExpired)
        let s = run(f.export.job)
        #expect(s.blocked)
        #expect(f.export.job.problem?.contains("Sign In Again") == true)
        f.export.job.tick() // blocked: a tick does nothing
        Thread.sleep(forTimeInterval: 0.3)
        #expect(f.calls.count == 2)

        f.output("claude", Fixture.aiVaultOk)
        let before = f.export.job.snapshot.lastRun
        f.export.signedIn("claude")
        #expect(waitFor(15) { f.export.job.snapshot.lastRun != before })
        let after = f.export.job.snapshot
        #expect(!after.blocked)
        #expect(f.calls.suffix(1) == ["claude"]) // chatgpt still expired: skipped
        #expect(after.summary == "claude: ok (3 new), chatgpt: login expired")
    }

    /// The schedule itself, with an injected 1 s period instead of the real hour: the
    /// Scheduler's ticks run the export when due and not before.
    @Test func ticksRunTheExportOnItsPeriod() {
        let f = ExportFixture(configure: {
            $0.period = 1
            $0.firstRun = 0
        })
        f.output("claude", Fixture.aiVaultOk)
        f.output("chatgpt", Fixture.aiVaultOk)
        let started = Date()
        while Date().timeIntervalSince(started) < 2.6 {
            f.export.job.tick()
            Thread.sleep(forTimeInterval: 0.05)
        }
        // Runs at ~0 s, ~1 s and ~2 s (each run takes a few ms): two or three, never one per tick.
        let runs = f.calls.filter { $0 == "claude" }.count
        #expect((2...3).contains(runs), "\(runs) runs")
    }

    /// On 10-27 ChatGPT answered 429 for hours while both logins worked, and the tray sat at
    /// 🔴 VAULT (a stale block, then "failed" every 30 min). A rate limit is waiting, not failing:
    /// it clears a stale expired mark and block, is not a tray problem, and waits longer each time.
    @Test func aRateLimitWaitsLongerEachTimeAndIsNotAFailure() throws {
        let f = ExportFixture(configure: { $0.problemGrace = 0; $0.blockedRecheck = 1 })
        // Blocked first (both "expired"), as the owner's state was; the re-check then meets
        // a working Claude login and ChatGPT's 429.
        f.output("claude", Fixture.aiVaultExpired)
        f.output("chatgpt", Fixture.aiVaultExpired)
        #expect(run(f.export.job).blocked)
        f.output("claude", Fixture.aiVaultOk)
        f.output("chatgpt", Fixture.aiVaultRateLimited)
        let blockedAt = try #require(f.export.job.snapshot.lastRun)
        #expect(waitFor(3) { f.export.job.snapshot.nextRun <= Date() })
        f.export.job.tick()
        #expect(waitFor(15) { f.export.job.snapshot.lastRun != blockedAt })
        var waits: [TimeInterval] = []
        for i in 0..<5 {
            let s = i == 0 ? f.export.job.snapshot : run(f.export.job)
            #expect(!s.blocked)
            #expect(s.summary.hasPrefix("claude: ok (3 new), chatgpt: rate limited"), "\(s.summary)")
            waits.append(s.nextRun.timeIntervalSince(try #require(s.lastRun)))
        }
        #expect(waits.map { Int(($0 / 60).rounded()) } == [30, 60, 120, 240, 360])
        #expect(f.export.expiredLogins.isEmpty, "a 429 comes after a working login")
        #expect(f.export.job.problem == nil)
        #expect(f.export.job.waiting?.contains("chatgpt: rate limited") == true)
        // Over: back to normal, and the next limit starts at 30 min again.
        f.output("chatgpt", Fixture.aiVaultOk)
        let ok = run(f.export.job)
        #expect(ok.waitingSince == nil && ok.failures == 0 && f.export.job.waiting == nil)
        f.output("chatgpt", Fixture.aiVaultRateLimited)
        let again = run(f.export.job)
        #expect(abs(again.nextRun.timeIntervalSince(try #require(again.lastRun)) - 1800) < 5)
    }

    @Test func aStuckExportThatIgnoresSIGTERMIsKilledAndRetriedWithBackoffAcrossARestart() throws {
        let f = ExportFixture(configure: { $0.stallTimeout = 1.5 })
        f.dir.write("claude.hang", "")
        f.output("chatgpt", Fixture.aiVaultOk)
        let started = Date()
        let s = run(f.export.job)
        let took = Date().timeIntervalSince(started)
        #expect(took < 10, "took \(took) s")
        #expect(s.summary.hasPrefix("claude: stuck, stopped (no output for"))
        #expect(s.failures == 1)
        let shPid = try #require(pid(in: f.dir.file("sh.pid"))), sleepPid = try #require(pid(in: f.dir.file("sleep.pid")))
        #expect(waitFor(2) { !isAlive(shPid) && !isAlive(sleepPid) })
        // 15 min doubling: the first retry is 12-15 min away (jitter), not an hour.
        let wait = s.nextRun.timeIntervalSince(try #require(s.lastRun))
        #expect(wait >= 15 * 60 * 0.8 - 2 && wait <= 15 * 60 + 2)
        #expect(f.dir.read("vault-export.log").contains("=== stopped: no output for"))

        // A restart keeps the failure count and the retry time.
        var c = f.export.config
        c.afterRun = nil
        let relaunched = VaultExport(config: c)
        #expect(relaunched.job.snapshot.failures == 1)
        #expect(abs(relaunched.job.snapshot.nextRun.timeIntervalSince(s.nextRun)) < 1)
    }

    @Test func quitStopsARunningExportAtOnce() throws {
        let f = ExportFixture(configure: { $0.stallTimeout = 60 })
        f.dir.write("claude.hang", "")
        f.output("chatgpt", Fixture.aiVaultOk)
        f.export.job.kick("test")
        #expect(waitFor(5) { f.dir.exists("sleep.pid") && f.export.isRunning })
        let started = Date()
        f.export.stopForQuit()
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(waitFor(5) { !f.export.isRunning })
        // Not recorded as a failure: no backoff, no problem, the next launch resumes soon.
        Thread.sleep(forTimeInterval: 0.3)
        #expect(f.export.job.snapshot.failures == 0)
        #expect(f.export.job.problem == nil)
        #expect(!isAlive(try #require(pid(in: f.dir.file("sh.pid")))))
        #expect(f.calls == ["claude"]) // chatgpt not started after quit
    }

    @Test func aMissingOrBrokenCLIIsAFailureNotSilence() {
        let f = ExportFixture(cli: "/nonexistent/ai-vault")
        let s = run(f.export.job)
        #expect(s.failures == 1)
        #expect(s.summary.contains("claude: ai-vault could not start"))
    }

    @Test func exportThenVoiceThenArchiveEndToEnd() throws {
        let vault = TempDir("vault")
        Fixture.conversation(vault.path, "typed-1", "A typed question", provider: "claude")
        vault.write("chatgpt/conversations/voice-1/conversation.md", Fixture.voiceMd)
        vault.write("ai-vault-config.json", #"{"providers":{"chatgpt":{"cookies":{"__Secure-next-auth.session-token":"fake-session"}}}}"#)

        let chatgpt = try HTTPStandIn { req in
            switch req.path {
            case "/api/auth/session": return .json(200, ["accessToken": "fake-token"])
            case "/backend-api/conversation/voice-1":
                return req.header("authorization") == "Bearer fake-token" ? .json(200, Fixture.voiceApi) : .json(401, [:])
            default: return .json(404, [:])
            }
        }
        let server = try HTTPStandIn { req in
            .json(200, ["data": ["accepted": (req.data?["documents"] as? [Any])?.count ?? 0, "updated": 0, "unchanged": 0]])
        }
        var vc = VoiceTranscripts.Config()
        vc.root = vault.path
        vc.baseURL = chatgpt.baseURL
        vc.aiVaultConfig = vault.file("ai-vault-config.json")
        vc.memoPath = vault.file("memo.json")
        vc.delay = 0
        let archiveJob = JobName("archive")
        var ac = Archive.Config()
        ac.jobName = archiveJob.name
        ac.root = vault.path
        ac.ledgerPath = vault.file("ledger.sqlite")
        let archive = Archive(rpc: LearnerRPC(baseURL: server.baseURL + "/learner-api", key: { _ in "medium-key" }), config: ac)

        let f = ExportFixture(voice: VoiceTranscripts(config: vc), afterRun: { archive.job.kick("after export") })
        f.output("claude", Fixture.aiVaultOk)
        f.output("chatgpt", Fixture.aiVaultOk)
        let s = run(f.export.job)
        #expect(s.summary == "claude: ok (3 new), chatgpt: ok (3 new), voice: 1 need transcripts: 1 updated (2 messages)")
        #expect(chatgpt.requests.map(\.path) == ["/api/auth/session", "/backend-api/conversation/voice-1"])
        #expect(chatgpt.requests.first?.header("cookie") == "__Secure-next-auth.session-token=fake-session")

        #expect(waitFor(15) { archive.status.ledger.synced == 2 })
        let req = try #require(server.requests.first)
        #expect(req.path == "/learner-api/rpc/archiveConversationDocuments")
        #expect(req.header("x-api-key") == "medium-key")
        let docs = req.data?["documents"] as? [[String: Any]] ?? []
        #expect(docs.compactMap { $0["documentId"] as? String }.sorted() == ["ai-vault:chatgpt:voice-1", "ai-vault:claude:typed-1"])
        let voice = docs.first { $0["documentId"] as? String == "ai-vault:chatgpt:voice-1" }
        let texts = (voice?["messages"] as? [[String: Any]])?.compactMap { $0["text"] as? String }
        #expect(texts == ["What should I do first today?", "Start with the walk."])

        // The next export finds nothing new: the archive sends nothing.
        run(f.export.job)
        Thread.sleep(forTimeInterval: 0.5)
        #expect(server.requests.count == 1)
    }
}
