import Foundation
import Testing
@testable import LearnerDesktop

private final class UpdateCheckFixture {
    let dir = TempDir("uc")
    let project = TempDir("uc-project")
    let job = JobName("uc")
    let check: ScreenpipeUpdateCheck

    init(claude script: String, timeout: TimeInterval = 30, marker: String = "never-matches-\(UUID().uuidString)") {
        let claude = dir.write("bin/claude", script, mode: 0o755)
        var c = ScreenpipeUpdateCheck.Config()
        c.jobName = job.name
        c.statePath = dir.file("state.json")
        c.logDir = dir.file("logs")
        c.tokenPath = dir.file("no-token")
        c.projectDir = project.path
        c.claudePath = claude
        c.timeout = timeout
        c.killGrace = 0.5
        c.installedVersion = { nil }
        c.orphanMarker = marker
        check = ScreenpipeUpdateCheck(config: c)
    }
}

@Suite("Update check job (fake claude, real processes)", .serialized) struct UpdateCheckJobTests {
    @Test func aRunIsLoggedWithItsStatusSessionAndCost() throws {
        let f = UpdateCheckFixture(claude: """
            #!/bin/sh
            pwd > "$0.cwd"
            for a in "$@"; do echo "$a"; done > "$0.args"
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
        let args = f.dir.read("bin/claude.args")
        #expect(args.contains("--settings\n\(f.project.path)/config/screenpipe-update-agent.json"))
        #expect(args.contains("--max-budget-usd\n5"))
        let reports = try FileManager.default.contentsOfDirectory(atPath: f.dir.file("logs")).filter { $0.hasSuffix(".md") }
        #expect(reports.count == 1)
        #expect(f.dir.read("logs/\(reports[0])").contains("claude --resume s-1"))
        #expect(!f.check.isRunning)
    }

    @Test func aHungSessionThatIgnoresSIGTERMIsKilledAtItsTimeout() {
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
        let shell = pid(in: f.dir.file("bin/claude.pid")), sleeper = pid(in: f.dir.file("bin/claude.sleep"))
        #expect(waitFor(2) { !isAlive(shell!) && !isAlive(sleeper!) })
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
        var version = "1.0.0"
        c.installedVersion = { version }
        c.settleSeconds = 0.5
        let check = ScreenpipeUpdateCheck(config: c)
        #expect(describe(check.runOnce()) == "idle") // baseline
        version = "1.0.1"
        #expect(describe(check.runOnce()) == "idle") // seen, settling
        Thread.sleep(forTimeInterval: 0.6)
        #expect(describe(check.runOnce()) == "ok: STATUS: OK")
        #expect(describe(check.runOnce()) == "idle") // once per version
        #expect(f.dir.read("logs/index.log").components(separatedBy: "screenpipe updated from 1.0.0 to 1.0.1").count == 2)
    }
}
