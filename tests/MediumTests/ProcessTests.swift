import Foundation
import Testing
@testable import LearnerDesktop

// ChildProcess and ManagedHelper against real child processes: stalls, programs that
// ignore SIGTERM, process trees, orphans from a crashed launch, crash loops.
@Suite("Child processes and helpers", .serialized) struct ProcessTests {

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
        let r = ChildProcess.run(script, [], timeout: 1.5, grace: 0.5)
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

    @Test func aHelperThatCrashesIsRestartedWithBackoff() {
        let dir = TempDir()
        defer { dir.cleanup() }
        let launches = dir.file("launches")
        let script = dir.write("crashy.sh", "#!/bin/bash\necho x >> \"\(launches)\"\nexit 1\n", executable: true)
        let helper = ManagedHelper(name: "crashy", executable: script, arguments: [], marker: "crashy.sh", runtimeDir: dir.path)
        DispatchQueue.main.sync { helper.start() }
        // Restarts after 1 s, 2 s, 4 s ...: about three launches in 4.5 s, not dozens.
        let count = { ((try? String(contentsOfFile: launches, encoding: .utf8)) ?? "").split(separator: "\n").count }
        #expect(eventually(6) { count() >= 3 })
        let seen = count()
        #expect(seen <= 4)
        #expect(helper.problem != nil)
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
        var lines: [String] = []
        let lock = NSLock()
        AppLog.sink = { l in lock.withLock { lines.append(l) } }
        defer { AppLog.sink = nil }
        DispatchQueue.main.sync { helper.start() }
        // Retries at 1 s, 2 s: at least two "could not start" lines within 3.5 s.
        #expect(eventually(4) { lock.withLock { lines.filter { $0.contains("could not start") }.count } >= 2 })
        // The binary appears (an upgrade finished): the helper comes up on its own.
        _ = dir.write("not-there", "#!/bin/bash\nwhile true; do sleep 1; done\n", executable: true)
        #expect(eventually(6) { helper.isRunning })
        helper.stop(grace: 0.5)
    }
}
