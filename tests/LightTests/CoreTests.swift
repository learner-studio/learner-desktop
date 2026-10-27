import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// The shared workflow primitives every workflow runs through (Core.swift).
// Serialized: AppLog.sink and Job.stateDir are process-wide.
@Suite("Core primitives", .serialized) struct CoreTests {

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

    private func withJobDir(_ body: (TempDir) -> Void) {
        let dir = TempDir("jobs")
        let saved = Job.stateDir
        Job.stateDir = dir.path
        defer { Job.stateDir = saved; dir.cleanup() }
        body(dir)
    }

    private func waitForRun(_ job: Job, after previous: Date?) -> Bool {
        eventually(5) { job.snapshot.lastRun != nil && job.snapshot.lastRun != previous }
    }

    @Test func okSchedulesTheNextRunAPeriodLater() {
        withJobDir { _ in
            let job = Job("ok-\(UUID().uuidString.prefix(6))", period: 3600, backoff: Backoff(base: 60, max: 600)) { _ in .ok("done") }
            job.kick("test")
            #expect(waitForRun(job, after: nil))
            let s = job.snapshot
            #expect(s.summary == "done" && s.failures == 0 && job.problem == nil)
            #expect(abs(s.nextRun.timeIntervalSinceNow - 3600) < 5)
        }
    }

    @Test func failuresBackOffAndBecomeAProblemAfterTheGrace() {
        withJobDir { _ in
            let job = Job("fail-\(UUID().uuidString.prefix(6))", period: 3600, backoff: Backoff(base: 60, max: 600, jitter: 0),
                          problemGrace: 0) { _ in .failed("server down") }
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
        withJobDir { _ in
            let job = Job("rate-\(UUID().uuidString.prefix(6))", period: 3600, backoff: Backoff(base: 60, max: 600)) { _ in
                .failed("rate limited", retryAfter: 1800)
            }
            job.kick("test")
            #expect(waitForRun(job, after: nil))
            #expect(abs(job.snapshot.nextRun.timeIntervalSinceNow - 1800) < 5)
        }
    }

    @Test func blockedWaitsForAKickAndIsAProblemAtOnce() {
        withJobDir { _ in
            var blocked = true
            let job = Job("blk-\(UUID().uuidString.prefix(6))", period: 1, backoff: Backoff(base: 1, max: 1),
                          problemGrace: 3600) { _ in blocked ? .blocked("login expired") : .ok("fine") }
            job.kick("test")
            #expect(waitForRun(job, after: nil))
            #expect(job.problem == "login expired")
            let first = job.snapshot.lastRun
            usleep(1_200_000)
            job.tick()   // due by period, but blocked: must not run
            usleep(200_000)
            #expect(job.snapshot.lastRun == first)
            blocked = false
            job.kick("signed in")
            #expect(waitForRun(job, after: first))
            #expect(job.problem == nil && job.snapshot.summary == "fine")
        }
    }

    @Test func aKickWhileRunningQueuesExactlyOneRerun() {
        withJobDir { _ in
            let gate = DispatchSemaphore(value: 0)
            var runs = 0
            let lock = NSLock()
            let job = Job("single-\(UUID().uuidString.prefix(6))", period: 3600, backoff: Backoff(base: 1, max: 1)) { _ in
                lock.withLock { runs += 1 }
                if lock.withLock({ runs }) == 1 { gate.wait() }
                return .ok("run")
            }
            job.kick("first")
            #expect(eventually(2) { lock.withLock { runs } == 1 })
            job.kick("second"); job.kick("third"); job.kick("fourth")
            gate.signal()
            #expect(eventually(3) { lock.withLock { runs } == 2 })
            usleep(300_000)
            #expect(lock.withLock { runs } == 2)
        }
    }

    @Test func stateSurvivesARestart() {
        withJobDir { _ in
            let name = "persist-\(UUID().uuidString.prefix(6))"
            let a = Job(name, period: 3600, backoff: Backoff(base: 600, max: 6000, jitter: 0)) { _ in .failed("down") }
            a.kick("test")
            #expect(waitForRun(a, after: nil))
            // A new launch: the backoff and the failure are remembered, not reset to "run in 2 min".
            let b = Job(name, period: 3600, firstRun: 120, backoff: Backoff(base: 600, max: 6000, jitter: 0)) { _ in .ok("up") }
            #expect(b.snapshot.failures == 1)
            #expect(b.snapshot.summary == "down")
            #expect(b.snapshot.nextRun.timeIntervalSinceNow > 500)
        }
    }
}
