import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// The shared workflow primitives every workflow runs through (Core.swift).
// Serialized within the suite; log capture is locked and each test has its own job folder.
@Suite("Core primitives", .quietLog, .serialized) struct CoreTests {

    @Test func backoffDoublesFromTheBaseUpToTheCapAndResets() {
        var b = Backoff(base: 10, max: 60, jitter: 0)
        #expect([b.failed(), b.failed(), b.failed(), b.failed()] == [10, 20, 40, 60])
        b.succeeded()
        #expect(b.failed() == 10)
        var j = Backoff(base: 100, max: 100, jitter: 0.2)
        let d = j.failed()
        #expect(d >= 80 && d <= 100)
    }

    @Test func warningsAreNeverCollapsedButNoisyRepeatsAre() {
        let log = Log("Test\(UUID().uuidString.prefix(4))")
        let lines = capturingLog {
            log.warn("server down 1")
            log.warn("server down 2")
            log.noisy("band out of range 1")
            log.noisy("band out of range 2")
        }
        #expect(lines.filter { $0.contains("WARN  [") && $0.contains("server down") }.count == 2)
        #expect(lines.filter { $0.contains("band out of range") }.count == 1)
        #expect(lines.allSatisfy { $0.range(of: #"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d "#, options: .regularExpression) != nil })
    }

    @Test func childProcessReturnsOutputAndStatus() {
        let r = ChildProcess.run("/bin/sh", ["-c", "echo hello; echo oops >&2; exit 3"], timeout: 5, stderr: true)
        #expect(r.status == 3)
        #expect(r.output.contains("hello") && r.output.contains("oops"))
        #expect(r.stopped == nil)
    }

    @Test func childProcessThatOverrunsItsDeadlineIsStopped() {
        let started = Date()
        let r = ChildProcess.run("/bin/sleep", ["30"], timeout: 0.5, grace: 0.2)
        #expect(r.status == nil)
        #expect(r.stopped?.contains("ran over") == true)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func childProcessThatCannotStartSaysWhy() {
        let r = ChildProcess.run("/nonexistent/tool", [], timeout: 1)
        #expect(r.status == nil)
        #expect(r.stopped?.contains("could not start") == true)
    }

    @Test func childProcessStreamsToALogFile() {
        let dir = TempDir()
        defer { dir.cleanup() }
        _ = ChildProcess.run("/bin/echo", ["line for the log"], timeout: 5, logFile: dir.file("x.log"))
        let text = (try? String(contentsOfFile: dir.file("x.log"), encoding: .utf8)) ?? ""
        #expect(text.contains("=== ") && text.contains("line for the log"))
    }

    // MARK: Job

    /// Each test's jobs keep their state in their own folder (never the shared Job.stateDir,
    /// which other suites use in parallel).
    private func withJobDir(_ body: (TempDir) -> Void) {
        let dir = TempDir("jobs")
        defer { dir.cleanup() }
        body(dir)
    }

    private func waitForRun(_ job: Job, after previous: Date?) -> Bool {
        eventually(5) { job.snapshot.lastRun != nil && job.snapshot.lastRun != previous }
    }

    @Test func okSchedulesTheNextRunAPeriodLater() {
        withJobDir { dir in
            let job = Job("ok-\(UUID().uuidString.prefix(6))", period: 3600, backoff: Backoff(base: 60, max: 600), stateDir: dir.path) { _ in .ok("done") }
            job.kick("test")
            #expect(waitForRun(job, after: nil))
            let s = job.snapshot
            #expect(s.summary == "done" && s.failures == 0 && job.problem == nil)
            #expect(abs(s.nextRun.timeIntervalSinceNow - 3600) < 5)
        }
    }

    @Test func failuresBackOffAndBecomeAProblemAfterTheGrace() {
        withJobDir { dir in
            let job = Job("fail-\(UUID().uuidString.prefix(6))", period: 3600, backoff: Backoff(base: 60, max: 600, jitter: 0),
                          problemGrace: 0, stateDir: dir.path) { _ in .failed("server down") }
            job.kick("test")
            #expect(waitForRun(job, after: nil))
            #expect(job.snapshot.failures == 1)
            #expect(abs(job.snapshot.nextRun.timeIntervalSinceNow - 60) < 5)
            #expect(job.problem == "server down")
            let first = job.snapshot.lastRun
            job.kick("again")
            #expect(waitForRun(job, after: first))
            #expect(abs(job.snapshot.nextRun.timeIntervalSinceNow - 120) < 5)
        }
    }

    @Test func aRetryAfterOverridesTheBackoff() {
        withJobDir { dir in
            let job = Job("rate-\(UUID().uuidString.prefix(6))", period: 3600, backoff: Backoff(base: 60, max: 600), stateDir: dir.path) { _ in
                .failed("rate limited", retryAfter: 1800)
            }
            job.kick("test")
            #expect(waitForRun(job, after: nil))
            #expect(abs(job.snapshot.nextRun.timeIntervalSinceNow - 1800) < 5)
        }
    }

    @Test func anIdleRunOfANonQuietJobSaysSo() {
        withJobDir { dir in
            let job = Job("idle-\(UUID().uuidString.prefix(6))", period: 60, backoff: Backoff(base: 1, max: 1), stateDir: dir.path) { _ in .idle }
            let lines = capturingLog {
                job.kick("test")
                _ = eventually(0.5) { false }   // the run takes milliseconds
            }
            #expect(lines.contains { $0.contains("nothing to do") })
        }
    }

    @Test func blockedWaitsForAKickAndIsAProblemAtOnce() {
        withJobDir { dir in
            let blocked = Locked(true)
            let job = Job("blk-\(UUID().uuidString.prefix(6))", period: 1, backoff: Backoff(base: 1, max: 1),
                          problemGrace: 3600, stateDir: dir.path) { _ in blocked.value ? .blocked("login expired") : .ok("fine") }
            job.kick("test")
            #expect(waitForRun(job, after: nil))
            #expect(job.problem == "login expired")
            let first = job.snapshot.lastRun
            usleep(1_200_000)
            job.tick()   // due by period, but blocked: must not run
            usleep(200_000)
            #expect(job.snapshot.lastRun == first)
            blocked.value = false
            job.kick("signed in")
            #expect(waitForRun(job, after: first))
            #expect(job.problem == nil && job.snapshot.summary == "fine")
        }
    }

    @Test func aBlockedJobChecksAgainOnItsOwnAndAtTheNextLaunch() {
        withJobDir { dir in
            let blocked = Locked(true)
            let name = "recheck-\(UUID().uuidString.prefix(6))"
            let job = Job(name, period: 3600, backoff: Backoff(base: 1, max: 1), stateDir: dir.path,
                          blockedRecheck: 0.3) { _ in blocked.value ? .blocked("login expired") : .ok("fine") }
            job.kick("test")
            #expect(waitForRun(job, after: nil))
            #expect(job.snapshot.blocked)
            let first = job.snapshot.lastRun
            blocked.value = false
            usleep(400_000)
            job.tick()
            #expect(waitForRun(job, after: first))
            #expect(!job.snapshot.blocked && job.problem == nil)

            // Saved blocked, then a new launch: it is checked at once, not left blocked.
            blocked.value = true
            job.kick("block again")
            _ = eventually(2) { job.snapshot.blocked }
            let relaunched = Job(name, period: 3600, firstRun: 0, backoff: Backoff(base: 1, max: 1), stateDir: dir.path) { _ in .ok("fine") }
            #expect(relaunched.snapshot.blocked)
            #expect(relaunched.snapshot.nextRun.timeIntervalSinceNow < 1)
        }
    }

    @Test func aKickWhileRunningQueuesExactlyOneRerun() {
        withJobDir { dir in
            let gate = DispatchSemaphore(value: 0)
            let runs = Locked(0)
            let job = Job("single-\(UUID().uuidString.prefix(6))", period: 3600, backoff: Backoff(base: 1, max: 1), stateDir: dir.path) { _ in
                if runs.withLock({ $0 += 1; return $0 }) == 1 { gate.wait() }
                return .ok("run")
            }
            job.kick("first")
            #expect(eventually(2) { runs.value == 1 })
            job.kick("second"); job.kick("third"); job.kick("fourth")
            gate.signal()
            #expect(eventually(3) { runs.value == 2 })
            usleep(300_000)
            #expect(runs.value == 2)
        }
    }

    @Test func stateSurvivesARestart() {
        withJobDir { dir in
            let name = "persist-\(UUID().uuidString.prefix(6))"
            let a = Job(name, period: 3600, backoff: Backoff(base: 600, max: 6000, jitter: 0), stateDir: dir.path) { _ in .failed("down") }
            a.kick("test")
            #expect(waitForRun(a, after: nil))
            // A new launch: the backoff and the failure are remembered, not reset to "run in 2 min".
            let b = Job(name, period: 3600, firstRun: 120, backoff: Backoff(base: 600, max: 6000, jitter: 0), stateDir: dir.path) { _ in .ok("up") }
            #expect(b.snapshot.failures == 1)
            #expect(b.snapshot.summary == "down")
            #expect(b.snapshot.nextRun.timeIntervalSinceNow > 500)
        }
    }
}

// Shutdown: ordered, each step logged, bounded overall, a hung step skipped not waited on.
@Suite("Shutdown", .quietLog) struct ShutdownTests {
    @Test func stepsRunInOrderAndAHungStepIsLeftBehind() {
        var order: [String] = []
        let lock = NSLock()
        let mark = { (n: String) in lock.withLock { order.append(n) } }
        let started = Date()
        var finished: [String] = []
        let lines = capturingLog {
            finished = Shutdown.run([
                .init(name: "turn", budget: 1, onCallingThread: true) { _ in mark("turn"); return nil },
                .init(name: "flush", budget: 1) { _ in mark("flush"); return "3 rows" },
                .init(name: "hangs", budget: 0.3) { _ in usleep(5_000_000); return nil },
                .init(name: "close", budget: 1) { _ in mark("close"); return nil },
            ], total: 3)
        }
        #expect(lock.withLock { order } == ["turn", "flush", "close"])
        #expect(finished == ["turn", "flush", "close"])
        #expect(Date().timeIntervalSince(started) < 2.5)
        #expect(lines.contains { $0.contains("flush: done in") && $0.contains("(3 rows)") })
        #expect(lines.contains { $0.contains("WARN") && $0.contains("hangs: still running") })
    }

    @Test func stepsPastTheTotalAreSkippedWithAWarning() {
        var finished: [String] = []
        let lines = capturingLog {
            finished = Shutdown.run([
                .init(name: "slow", budget: 1) { _ in usleep(900_000); return nil },
                .init(name: "late", budget: 1) { _ in nil },
            ], total: 1)
        }
        #expect(finished == ["slow"])
        #expect(lines.contains { $0.contains("late: skipped, out of time") })
    }
}
