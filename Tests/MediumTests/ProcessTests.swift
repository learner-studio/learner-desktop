import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// ChildProcess and ManagedHelper against real child processes: stalls, programs that
// ignore SIGTERM, process trees, orphans from a crashed launch, crash loops.
@Suite("Child processes and helpers", .tags(.medium, .helpers, .core), .timeLimit(.minutes(1)), .quietLog, .serialized) struct ProcessTests {

    private func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    @Test func aStalledProgramIsStoppedWhileABusyOneRunsOn() {
        let dir = TempDir()
        defer { dir.cleanup() }
        // Prints every 0.2 s for 2 s: busy, so a 1 s stall timeout must not stop it.
        let busy = ChildProcess.run("/bin/sh", ["-c", "for i in 1 2 3 4 5 6 7 8 9 10; do echo $i; sleep 0.2; done"],
                                    timeout: 30, stallTimeout: 1)
        #expect(busy.status == 0 && busy.stopped == nil)
        // Prints once, then goes quiet: stopped as stuck after about a second.
        let started = Date()
        let stuck = ChildProcess.run("/bin/sh", ["-c", "echo start; sleep 60"], timeout: 30, stallTimeout: 1,
                                     logFile: dir.file("stall.log"), grace: 0.5)
        #expect(stuck.status == nil)
        #expect(stuck.stopped?.contains("no output") == true)
        #expect(Date().timeIntervalSince(started) < 10)
        let log = (try? String(contentsOfFile: dir.file("stall.log"), encoding: .utf8)) ?? ""
        #expect(log.contains("start") && log.contains("=== stopped: no output"))
    }

    @Test func aProgramThatIgnoresSIGTERMIsKilledWithItsChildren() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        // Like ai-vault after its browser died: traps SIGTERM, and has a child of its own.
        let script = dir.write("stubborn.sh", """
            #!/bin/bash
            trap '' TERM
            sleep 60 &
            echo $! > "\(dir.file("child.pid"))"
            echo started
            while true; do sleep 1; done
            """, executable: true)
        var childPid: pid_t = 0
        let started = Date()
        // Long enough for a loaded machine to start bash and write the pid file.
        let r = ChildProcess.run(script, [], timeout: 4, grace: 0.5)
        #expect(r.status == nil)
        #expect(Date().timeIntervalSince(started) < 8)
        if let text = try? String(contentsOfFile: dir.file("child.pid"), encoding: .utf8) {
            childPid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        #expect(childPid > 0)
        #expect(eventually(3) { !alive(childPid) })
    }

    @Test func orphansFromACrashedLaunchAreKilled() {
        let marker = "learner-orphan-test-\(UUID().uuidString.prefix(8))"
        // A double fork leaves `sleep` parented to launchd, like a child of a crashed app.
        _ = ChildProcess.run("/bin/sh", ["-c", "(exec -a \(marker) sleep 60 &) ; true"], timeout: 5)
        let find = { ChildProcess.run("/usr/bin/pgrep", ["-f", marker], timeout: 5).output.split(separator: "\n").compactMap { pid_t($0) } }
        #expect(eventually(3) { !find().isEmpty })
        let killed = ChildProcess.killOrphans(matching: marker, log: Log("Test"))
        #expect(killed >= 1)
        #expect(eventually(3) { find().isEmpty })
    }

    @Test func orphanCleanupLeavesUnrelatedAndParentedProcessesAlone() {
        let marker = "learner-orphan-keep-\(UUID().uuidString.prefix(8))"
        // A live, parented process whose command line matches the marker: not an orphan.
        let parented = Process()
        parented.executableURL = URL(fileURLWithPath: "/bin/sh")
        parented.arguments = ["-c", "exec -a \(marker) sleep 30"]
        try? parented.run()
        defer { parented.terminate() }
        #expect(eventually(3) { !ChildProcess.run("/usr/bin/pgrep", ["-f", marker], timeout: 5).output.isEmpty })
        #expect(ChildProcess.killOrphans(matching: marker, log: Log("Test")) == 0)
        #expect(parented.isRunning)

        // A pid file left by a crash, but the pid now belongs to an unrelated program.
        let dir = TempDir()
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["30"]
        try? unrelated.run()
        defer { unrelated.terminate() }
        try? String(unrelated.processIdentifier).write(toFile: dir.file("tunnel.pid"), atomically: true, encoding: .utf8)
        let helper = ManagedHelper(name: "tunnel", executable: "/usr/bin/true", arguments: [], marker: "3200:127.0.0.1:3200", runtimeDir: dir.path)
        DispatchQueue.main.sync { helper.start() }
        Thread.sleep(forTimeInterval: 0.5)
        #expect(unrelated.isRunning, "a recycled pid must not be killed")
        helper.stop(grace: 0.2)
    }

    @Test func aHelperThatCrashesIsRestartedWithBackoff() {
        let dir = TempDir()
        defer { dir.cleanup() }
        let launches = dir.file("launches")
        let script = dir.write("crashy.sh", "#!/bin/bash\necho x >> \"\(launches)\"\nexit 1\n", executable: true)
        let helper = ManagedHelper(name: "crashy", executable: script, arguments: [], marker: "crashy.sh", runtimeDir: dir.path)
        DispatchQueue.main.sync { helper.start() }
        // Launches at 0 s, 1 s and 3 s (waits of 1, 2, 4 s): exactly three in the first 4.5 s. A
        // fixed 1 s wait (no backoff) would launch at 0, 1, 2, 3 and 4 s; a fixed wait here, so it cannot pass early.
        let count = { ((try? String(contentsOfFile: launches, encoding: .utf8)) ?? "").split(separator: "\n").count }
        Thread.sleep(forTimeInterval: 4.5)
        let seen = count()
        #expect(seen == 3, "launched \(seen) times in 4.5 s")
        // The third exit is counted a moment after the third launch.
        #expect(eventually(3) { helper.problem != nil })
        helper.stop(grace: 0.5)
    }

    @Test func aHelperIsStoppedWithItsChildrenAndItsOrphanIsReapedOnNextStart() {
        let dir = TempDir()
        defer { dir.cleanup() }
        let marker = "learner-helper-\(UUID().uuidString.prefix(8))"
        let script = dir.write("\(marker).sh", """
            #!/bin/bash
            trap '' TERM
            sleep 300 &
            echo $! > "\(dir.file("child.pid"))"
            while true; do sleep 1; done
            """, executable: true)
        let helper = ManagedHelper(name: "tree", executable: script, arguments: [], marker: marker, runtimeDir: dir.path)
        DispatchQueue.main.sync { helper.start() }
        #expect(eventually(3) { FileManager.default.fileExists(atPath: dir.file("child.pid")) })
        let child = pid_t((try? String(contentsOfFile: dir.file("child.pid"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        #expect(helper.isRunning && alive(child))
        helper.stop(grace: 0.5)
        #expect(!helper.isRunning)
        #expect(eventually(3) { !alive(child) })

        // A crashed app leaves the helper running with its pid file: the next start reaps it.
        let orphan = Process()
        orphan.executableURL = URL(fileURLWithPath: script)
        try? orphan.run()
        try? String(orphan.processIdentifier).write(toFile: dir.file("tree.pid"), atomically: true, encoding: .utf8)
        let next = ManagedHelper(name: "tree", executable: script, arguments: [], marker: marker, runtimeDir: dir.path)
        DispatchQueue.main.sync { next.start() }
        #expect(eventually(6) { !orphan.isRunning })
        next.stop(grace: 0.5)
    }

    @Test func aHelperWhoseBinaryIsMissingKeepsRetrying() {
        let dir = TempDir()
        defer { dir.cleanup() }
        let helper = ManagedHelper(name: "missing", executable: dir.file("not-there"), arguments: [], marker: "not-there", runtimeDir: dir.path)
        let lines = capturingLog {
            DispatchQueue.main.sync { helper.start() }
            // Retries at 1 s, 2 s: two "could not start" lines within 3.5 s.
            usleep(3_500_000)
        }
        #expect(lines.filter { $0.contains("could not start") }.count >= 2)
        // The binary appears (an upgrade finished): the helper comes up on its own.
        _ = dir.write("not-there", "#!/bin/bash\nwhile true; do sleep 1; done\n", executable: true)
        #expect(eventually(6) { helper.isRunning })
        helper.stop(grace: 0.5)
    }
}
