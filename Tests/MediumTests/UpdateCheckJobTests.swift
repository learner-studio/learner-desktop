import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

private final class UpdateCheckFixture {
    let dir = TempDir("uc")
    let project = TempDir("uc-project")
    let job = JobName("uc")
    let check: ScreenpipeUpdateCheck

    init(claude script: String, timeout: TimeInterval = 30, marker: String = "never-matches-\(UUID().uuidString)",
         token: String? = nil) {
        let claude = dir.write("bin/claude", script, mode: 0o755)
        if let token = token { dir.write("claude-token", token) }
        var c = ScreenpipeUpdateCheck.Config()
        c.jobName = job.name
        c.statePath = dir.file("state.json")
        c.logDir = dir.file("logs")
        c.tokenPath = dir.file(token == nil ? "no-token" : "claude-token")
        c.projectDir = project.path
        c.claudePath = claude
        c.timeout = timeout
        c.killGrace = 0.5
        c.installedVersion = { nil }
        c.orphanMarker = marker
        check = ScreenpipeUpdateCheck(config: c)
    }
}

@Suite("Update check job (fake claude, real processes)", .tags(.medium, .status), .quietLog, .serialized, .timeLimit(.minutes(1))) struct UpdateCheckJobTests {
    @Test func aRunIsLoggedWithItsStatusSessionAndCost() throws {
        let f = UpdateCheckFixture(claude: """
            #!/bin/sh
            pwd > "$0.cwd"
            for a in "$@"; do printf '%s\\0' "$a"; done > "$0.args"
            env | grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' | tr -d = | sort -u > "$0.env"
            echo '{"type":"system","session_id":"s-1"}'
            printf '%s\\n' '{"type":"result","session_id":"s-1","total_cost_usd":0.12,"is_error":false,"result":"One-line summary.\\n\\nSTATUS: OK\\nNothing to fix."}'
            """)
        f.check.start(reason: "medium test")
        #expect(f.check.isRunning)
        #expect(waitFor(15) { f.check.job.snapshot.lastRun != nil })
        let s = f.check.job.snapshot
        #expect(s.summary == "STATUS: OK" && s.failures == 0)
        #expect(f.check.lastRunSummary?.contains("STATUS: OK  session s-1  $0.12") == true)
        #expect(f.dir.read("bin/claude.cwd").trimmingCharacters(in: .newlines) == f.project.path)
        // claude is started with exactly these flags (the prompt names the runbook), and no
        // saved token means no token variable.
        let args = f.dir.read("bin/claude.args").split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
        try #require(args.count == 9, "\(args)")
        #expect(args[0] == "-p")
        #expect(args[1].hasPrefix("medium test (detected by Learner Desktop).") && args[1].contains("docs/screenpipe-update-runbook.md"), "\(args[1])")
        #expect(Array(args[2...]) == ["--output-format", "stream-json", "--verbose",
                                      "--settings", "\(f.project.path)/config/screenpipe-update-agent.json",
                                      "--max-budget-usd", "5"])
        let envNames = Set(f.dir.read("bin/claude.env").split(separator: "\n").map(String.init))
        #expect(envNames.contains("PATH"))
        #expect(!envNames.contains("CLAUDE_CODE_OAUTH_TOKEN"))
        let reports = try FileManager.default.contentsOfDirectory(atPath: f.dir.file("logs")).filter { $0.hasSuffix(".md") }
        try #require(reports.count == 1)
        #expect(f.dir.read("logs/\(reports[0])").contains("claude --resume s-1"))
        #expect(!f.check.isRunning)
    }

    @Test func aSavedTokenIsPassedToClaudeWithoutTheWhitespaceAPasteAdds() {
        let f = UpdateCheckFixture(claude: """
            #!/bin/sh
            printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN" > "$0.token"
            printf '%s\\n' '{"type":"result","session_id":"s-3","total_cost_usd":0,"is_error":false,"result":"STATUS: OK"}'
            """, token: "fixture-oauth-\n  value\n")
        f.check.start(reason: "token test")
        #expect(waitFor(15) { f.check.job.snapshot.lastRun != nil })
        #expect(f.dir.read("bin/claude.token") == "fixture-oauth-value")
    }

    @Test func aHungSessionThatIgnoresSIGTERMIsKilledAtItsTimeout() throws {
        let f = UpdateCheckFixture(claude: """
            #!/bin/sh
            trap '' TERM
            echo '{"type":"system","session_id":"s-2"}'
            echo $$ > "$0.pid"
            sleep 30 &
            echo $! > "$0.sleep"
            wait
            """, timeout: 1.5)
        let started = Date()
        f.check.start(reason: "hang test")
        #expect(waitFor(15) { f.check.job.snapshot.lastRun != nil })
        #expect(Date().timeIntervalSince(started) < 6)
        let s = f.check.job.snapshot
        #expect(s.summary.hasPrefix("STATUS: RUN FAILED (ran over"))
        #expect(s.failures == 1)
        let shell = try #require(pid(in: f.dir.file("bin/claude.pid"))), sleeper = try #require(pid(in: f.dir.file("bin/claude.sleep")))
        #expect(waitFor(2) { !isAlive(shell) && !isAlive(sleeper) })
        #expect(f.dir.read("logs/index.log").contains("STATUS: RUN FAILED (ran over 1 s)  session s-2"))
        #expect(f.check.lastRunSummary?.contains("RUN FAILED") == true)
    }

    @Test func aRunOrphanedByACrashIsKilledOnRelaunch() throws {
        let marker = "uc-orphan-\(UUID().uuidString.prefix(8))"
        let f = UpdateCheckFixture(claude: "#!/bin/sh\n", marker: marker)
        let script = f.dir.write("\(marker).sh", "echo $$ > \"$0.pid\"\nsleep 60 &\nwait\n")
        // Started detached, so its parent exits and launchd adopts it, as after a crash.
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = ["-c", "nohup /bin/sh '\(script)' >/dev/null 2>&1 &"]
        try launcher.run()
        launcher.waitUntilExit()
        #expect(waitFor(5) { pid(in: script + ".pid") != nil })
        let orphan = try #require(pid(in: script + ".pid"))
        #expect(isAlive(orphan))
        _ = f.check.runOnce()
        #expect(waitFor(3) { !isAlive(orphan) })
    }

    @Test func aVersionChangeRunsOnceAfterItSettles() {
        let f = UpdateCheckFixture(claude: "#!/bin/sh\necho '{\"type\":\"result\",\"session_id\":\"s-3\",\"result\":\"STATUS: OK\"}'\n")
        var c = f.check.config
        let version = Locked("1.0.0")
        c.installedVersion = { version.value }
        c.settleSeconds = 0.5
        let check = ScreenpipeUpdateCheck(config: c)
        #expect(describe(check.runOnce()) == "idle") // baseline
        version.value = "1.0.1"
        #expect(describe(check.runOnce()) == "idle") // seen, settling
        Thread.sleep(forTimeInterval: 0.6)
        #expect(describe(check.runOnce()) == "ok: STATUS: OK")
        #expect(describe(check.runOnce()) == "idle") // once per version
        #expect(f.dir.read("logs/index.log").components(separatedBy: "screenpipe updated from 1.0.0 to 1.0.1").count == 2)
    }
}
