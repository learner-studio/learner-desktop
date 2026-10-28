import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// The shared workflow primitives every workflow runs through (Core.swift).
// Serialized within the suite; log capture is locked and each test has its own job folder.
@Suite("Core primitives", .tags(.light, .core), .timeLimit(.minutes(1)), .quietLog, .serialized) struct CoreTests {

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

    @Test func childProcessThatCannotStartSaysWhy() {
        let r = ChildProcess.run("/nonexistent/tool", [], timeout: 1)
        #expect(r.status == nil)
        #expect(r.stopped?.contains("could not start") == true)
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
                _ = waitForRun(job, after: nil)
            }
            #expect(lines.contains { $0.contains("nothing to do") })
        }
    }

    @Test func blockedWaitsForAKickAndIsAProblemAtOnce() {
        withJobDir { dir in
            let blocked = Locked(true)
            let job = Job("blk-\(UUID().uuidString.prefix(6))", period: 0.2, backoff: Backoff(base: 1, max: 1),
                          problemGrace: 3600, stateDir: dir.path) { _ in blocked.value ? .blocked("login expired") : .ok("fine") }
            job.kick("test")
            #expect(waitForRun(job, after: nil))
            #expect(job.problem == "login expired")
            let first = job.snapshot.lastRun
            usleep(300_000)
            job.tick()   // due by period, but blocked: must not run
            usleep(150_000)
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
            #expect(waitFor(2) { job.snapshot.nextRun <= Date() })   // the 0.3 s recheck is due
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
            // And the backoff carries on from there: the next failure is attempt 2 (2 × base).
            let c = Job(name, period: 3600, backoff: Backoff(base: 600, max: 6000, jitter: 0), stateDir: dir.path) { _ in .failed("still down") }
            let before = c.snapshot.lastRun
            c.kick("test")
            #expect(waitForRun(c, after: before))
            #expect(c.snapshot.failures == 2)
            #expect(c.snapshot.nextRun.timeIntervalSinceNow > 1100)
        }
    }
}

// Shutdown: ordered, each step logged, bounded overall, a hung step skipped not waited on.
@Suite("Shutdown", .tags(.light, .shutdown, .core), .timeLimit(.minutes(1)), .quietLog) struct ShutdownTests {
    @Test func stepsRunInOrderAndAHungStepIsLeftBehind() {
        let order = Locked<[String]>([])
        let mark: @Sendable (String) -> Void = { n in order.withLock { $0.append(n) } }
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
        #expect(order.value == ["turn", "flush", "close"])
        #expect(finished == ["turn", "flush", "close"])
        #expect(Date().timeIntervalSince(started) < 2.5)
        #expect(lines.contains { $0.contains("flush: done in") && $0.contains("(3 rows)") })
        #expect(lines.contains { $0.contains("WARN") && $0.contains("hangs: still running") })
    }

    @Test func stepsPastTheTotalAreSkippedWithAWarning() {
        var finished: [String] = []
        let lines = capturingLog {
            finished = Shutdown.run([
                .init(name: "slow", budget: 0.3) { _ in usleep(250_000); return nil },
                .init(name: "late", budget: 0.3) { _ in nil },
            ], total: 0.3)
        }
        #expect(finished == ["slow"])
        #expect(lines.contains { $0.contains("late: skipped, out of time") })
    }
}

// An Objective-C exception in one scheduled task (AVAudioEngine raises them) must not stop
// the app's clock; a stalled main thread is noticed, sampled once and its length logged.
@Suite("Clock and stalls", .tags(.light, .core), .timeLimit(.minutes(1)), .quietLog, .serialized) struct ClockStallTests {
    @MainActor @Test func anExceptionInATaskIsLoggedAndTheNextOneStillRuns() {
        var ran: [String] = []
        let lines = capturingLog {
            Scheduler.guarded("mic") {
                ran.append("mic")
                NSException(name: .invalidArgumentException, reason: "Failed to create tap due to format mismatch", userInfo: nil).raise()
                ran.append("after the raise")
            }
            Scheduler.guarded("tray") { ran.append("tray") }
        }
        #expect(ran == ["mic", "tray"])
        #expect(lines.contains { $0.contains("[Scheduler] mic raised NSInvalidArgumentException: Failed to create tap due to format mismatch") })
    }

    @Test func aStalledMainThreadIsSampledOnceAndItsLengthLogged() {
        let pending = Locked<[@Sendable () -> Void]>([])
        let samples = Locked<[String]>([])
        let watch = MainThreadWatch(threshold: 1, cooldown: 600,
                                    onMain: { ping in pending.withLock { $0.append(ping) } },
                                    sample: { file in samples.withLock { $0.append(file) } })
        let lines = capturingLog {
            watch.check(now: 100)            // ping sent; the main thread never runs it
            watch.check(now: 100.5)          // not overdue yet
            watch.check(now: 101.2)          // overdue: sampled
            watch.check(now: 103)            // the same stall: not sampled again
            watch.answered(now: 104)         // it ran at last: 4 s
            watch.check(now: 105)            // a new ping...
            watch.answered(now: 105.1)       // ...answered at once: nothing logged
        }
        #expect(pending.value.count == 2)
        #expect(samples.value.count == 1 && samples.value[0].contains("/main-thread-stall-"))
        #expect(lines.filter { $0.contains("[Stall] the main thread was blocked for 4.0 s") }.count == 1)
        #expect(lines.filter { $0.contains("sampling it") }.count == 1)
    }

    @Test func anOpenMenuIsNotAStall() {
        let samples = Locked<[String]>([])
        let watch = MainThreadWatch(threshold: 1, onMain: { _ in }, sample: { file in samples.withLock { $0.append(file) } })
        let lines = capturingLog {
            watch.check(now: 100)
            watch.menu(open: true)           // the menu loop holds the main thread...
            watch.check(now: 103)
            watch.check(now: 110)            // ...for as long as the menu stays open
            watch.menu(open: false)
            watch.answered(now: 111)         // the ping from before the menu: not counted
        }
        #expect(samples.value.isEmpty)
        #expect(!lines.contains { $0.contains("[Stall]") })
    }

    @Test func eachSampleGetsItsOwnFileAndOnlyTheNewestFiveAreKept() {
        let dir = TempDir("stalls")
        for i in 1...7 { dir.write("main-thread-stall-2026102\(i)-000000.txt", "") }
        dir.write("menubar.log", "")
        let file = MainThreadWatch.sampleFile(at: Date(), dir: dir.path)
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        #expect(left == ["main-thread-stall-20261024-000000.txt", "main-thread-stall-20261025-000000.txt", "main-thread-stall-20261026-000000.txt",
                         "main-thread-stall-20261027-000000.txt", "menubar.log"])
        #expect(file.hasPrefix(dir.path + "/main-thread-stall-") && file.hasSuffix(".txt"))
    }
}
