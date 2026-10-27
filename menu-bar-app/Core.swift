import AppKit
import Foundation
import ServiceManagement
import SQLite3
import CoreBluetooth
import CommonCrypto

// The app runs a handful of workflows -- the speaking coach, the trial outbox, the chat
// export, the helper processes and the status probe -- and they all share what is here:
// one log format (Log), one retry policy (Backoff), one way to run another program
// (ChildProcess), one way to run recurring work (Job) and one clock (Scheduler).

// MARK: - Paths

/// Where the app keeps its data. One place, so the test lanes can move it all to a
/// throwaway folder (LEARNER_DATA_DIR, AI_VAULT_DATA) and never touch the real files.
enum Paths {
    static let data = ProcessInfo.processInfo.environment["LEARNER_DATA_DIR"] ?? NSHomeDirectory() + "/.ai-aggregator"
    static let logs = data + "/logs"
    /// ai-vault's export (its own default location).
    static let vault = ProcessInfo.processInfo.environment["AI_VAULT_DATA"] ?? NSHomeDirectory() + "/ai-vault-data"
}

// MARK: - Logging

/// Every line in menubar.log: `2026-10-27 14:00:00 WARN  [Export] chatgpt: stuck, stopped`.
/// INFO, WARN and ERROR lines are always written and flushed. Only `noisy` lines -- the
/// ones a retry loop repeats, like a band out of range -- are collapsed: a line that
/// repeats within 10 minutes (numbers ignored) is held back and counted.
struct Log {
    let prefix: String
    init(_ prefix: String) { self.prefix = prefix }

    func info(_ message: String) { AppLog.write("INFO  [\(prefix)] \(message)", collapse: false) }
    func warn(_ message: String) { AppLog.write("WARN  [\(prefix)] \(message)", collapse: false) }
    func error(_ message: String) { AppLog.write("ERROR [\(prefix)] \(message)", collapse: false) }
    func noisy(_ message: String) { AppLog.write("INFO  [\(prefix)] \(message)", collapse: true) }
}

/// A stray `print` still lands in the log, timestamped, as a collapsible line.
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    AppLog.write(items.map { "\($0)" }.joined(separator: separator), collapse: true)
}

enum AppLog {
    static let path = Paths.logs + "/menubar.log"
    static let maxBytes: UInt64 = 10_000_000
    static let repeatWindow: TimeInterval = 600

    /// Tests capture lines here instead of stdout.
    static var sink: ((String) -> Void)?
    private static let lock = NSLock()
    private static var lastSeen: [String: (at: Date, held: Int)] = [:]
    private static var writes = 0
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Send stdout/stderr to the log file (launchd points them there too; this lets the app
    /// rotate it). Not used by the one-shot CLI modes, which print to the terminal.
    static func attachToFile() {
        rotate()
        freopen(path, "a", stdout)
        freopen(path, "a", stderr)
    }

    static func write(_ line: String, collapse: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        var text = line
        if collapse {
            let key = line.replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
            if let seen = lastSeen[key], now.timeIntervalSince(seen.at) < repeatWindow {
                lastSeen[key] = (seen.at, seen.held + 1)
                return
            } else if let seen = lastSeen[key], seen.held > 0 {
                text += "  [repeated \(seen.held)x in the previous \(Int(repeatWindow / 60)) min]"
            }
            if lastSeen.count > 2000 { lastSeen.removeAll() }
            lastSeen[key] = (now, 0)
        }
        let stamped = "\(stamp.string(from: now)) \(text)"
        if let sink = sink { sink(stamped); return }
        Swift.print(stamped)
        fflush(stdout)
        writes += 1
        if writes % 500 == 0 { rotate() }
    }

    /// Keep one previous file: menubar.log -> menubar.1.log once it passes maxBytes.
    private static func rotate() {
        guard LogFile.rotate(path, maxBytes: maxBytes) else { return }
        freopen(path, "a", stdout)
        freopen(path, "a", stderr)
    }
}

/// Append-only log files the helpers and child programs write (watcher.log,
/// vault-export.log, update-check transcripts), each kept to one previous copy.
enum LogFile {
    /// Moves `path` to `<name>.1.log` once it passes `maxBytes`; true when it rotated.
    @discardableResult
    static func rotate(_ path: String, maxBytes: UInt64 = 5_000_000) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
        guard size > maxBytes else { return false }
        let old = path.replacingOccurrences(of: ".log", with: ".1.log")
        try? FileManager.default.removeItem(atPath: old)
        try? FileManager.default.moveItem(atPath: path, toPath: old)
        return true
    }

    /// An append handle (the file is created, and rotated if large), or nil if it cannot be opened.
    static func open(_ path: String) -> FileHandle? {
        rotate(path)
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        let h = FileHandle(forWritingAtPath: path)
        h?.seekToEndOfFile()
        return h
    }

    static func append(_ path: String, _ text: String) {
        guard let h = open(path) else {
            Log("LogFile").warn("cannot write \(path)")
            return
        }
        h.write(Data(text.utf8))
        try? h.close()
    }
}

// MARK: - Retry policy

/// Exponential backoff with jitter: base, 2×base, 4×base ... capped at `max`, each
/// delay drawn from [ (1-jitter)·d, d ].
struct Backoff {
    let base: TimeInterval
    let max: TimeInterval
    var jitter: Double = 0.2
    private(set) var failures = 0

    init(base: TimeInterval, max: TimeInterval, jitter: Double = 0.2) {
        self.base = base
        self.max = max
        self.jitter = jitter
    }

    /// Records a failure and returns how long to wait before the next attempt.
    mutating func failed() -> TimeInterval {
        failures += 1
        let d = Swift.min(max, base * pow(2, Double(failures - 1)))
        return d * Double.random(in: (1 - jitter)...1)
    }

    mutating func succeeded() { failures = 0 }

    /// Restores a count saved before a restart.
    mutating func restore(failures: Int) { self.failures = Swift.max(0, failures) }
}

// MARK: - Child processes

/// The one way the app runs another program and waits for it. Nothing waits forever:
/// past `timeout` (or `stallTimeout` without output) the program and everything it
/// started get SIGTERM, then SIGKILL after `grace`. Output can stream to a log file.
enum ChildProcess {
    struct Result {
        /// nil when it could not start or was stopped.
        let status: Int32?
        let output: String
        /// Why it was stopped, when it was.
        let stopped: String?
        var ok: Bool { status == 0 }
    }

    /// PATH for programs the app runs: ai-vault's node (nvm), bun, Homebrew, system.
    static var toolPath: String {
        let home = NSHomeDirectory()
        let nvm = ((try? FileManager.default.contentsOfDirectory(atPath: home + "/.nvm/versions/node")) ?? [])
            .sorted().reversed().map { "\(home)/.nvm/versions/node/\($0)/bin" }
        return (nvm + ["\(home)/.local/bin", "\(home)/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin",
                       "/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
    }

    static var toolEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = toolPath
        return env
    }

    /// Runs `executable` to completion (bounded). `onStart` gets the running process, e.g.
    /// to remember it for a stop at quit.
    static func run(_ executable: String, _ args: [String], timeout: TimeInterval,
                    stallTimeout: TimeInterval? = nil, env: [String: String]? = nil,
                    stderr: Bool = false, logFile: String? = nil, grace: TimeInterval = 2,
                    onStart: ((Process) -> Void)? = nil) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let env = env { p.environment = env }
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = stderr ? out : FileHandle.nullDevice
        let log = logFile.flatMap(LogFile.open)
        defer { try? log?.close() }
        log?.write(Data("=== \(Date()) \(([executable] + args).map { ($0 as NSString).lastPathComponent }.prefix(3).joined(separator: " "))\n".utf8))

        let lock = NSLock()
        var data = Data()
        var eof = false
        var lastOutput = Date()
        out.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            lock.lock()
            if chunk.isEmpty {
                eof = true
                h.readabilityHandler = nil
            } else {
                data.append(chunk)
                lastOutput = Date()
                log?.write(chunk)
            }
            lock.unlock()
        }
        do {
            try p.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            return Result(status: nil, output: "", stopped: "could not start: \(error.localizedDescription)")
        }
        onStart?(p)
        let started = Date()
        var stopped: String?
        while p.isRunning {
            usleep(50_000)
            let now = Date()
            if now.timeIntervalSince(started) > timeout {
                stopped = "ran over \(Int(timeout)) s"
            } else if let stall = stallTimeout, now.timeIntervalSince(lock.withLock { lastOutput }) > stall {
                stopped = "no output for \(Int(stall / 60)) min"
            }
            if stopped != nil {
                stop(p, grace: grace)
                break
            }
        }
        p.waitUntilExit()
        // Output held open by a grandchild is abandoned after a second.
        let drained = Date().addingTimeInterval(1)
        while Date() < drained && !(lock.withLock { eof }) { usleep(10_000) }
        out.fileHandleForReading.readabilityHandler = nil
        if let why = stopped { log?.write(Data("\n=== stopped: \(why)\n".utf8)) }
        let text = lock.withLock { String(data: data, encoding: .utf8) ?? "" }
        return Result(status: stopped == nil ? p.terminationStatus : nil, output: text, stopped: stopped)
    }

    /// SIGTERM to the process, then SIGKILL to it and every descendant after `grace`.
    /// (ai-vault can sit in its own SIGTERM handler forever once its browser has died.)
    static func stop(_ p: Process, grace: TimeInterval) {
        let pid = p.processIdentifier
        let tree = [pid] + descendants(of: pid)
        if p.isRunning { p.terminate() }
        let deadline = Date().addingTimeInterval(grace)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        for child in tree where kill(child, 0) == 0 { kill(child, SIGKILL) }
    }

    static func descendants(of pid: pid_t) -> [pid_t] {
        let kids = run("/usr/bin/pgrep", ["-P", String(pid)], timeout: 5).output
            .split(separator: "\n").compactMap { pid_t($0) }
        return kids + kids.flatMap { descendants(of: $0) }
    }

    /// Kills processes left by a crashed earlier launch: parented to launchd (ppid 1) and
    /// matching `marker` in their command line. Returns how many it killed.
    @discardableResult
    static func killOrphans(matching marker: String, log: Log) -> Int {
        var killed = 0
        for line in run("/bin/ps", ["-axo", "pid=,ppid=,command="], timeout: 5).output.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, f[1] == "1", let pid = pid_t(f[0]), f[2].contains(marker) else { continue }
            let tree = [pid] + descendants(of: pid)
            for p in tree { kill(p, SIGKILL) }
            log.warn("killed a leftover '\(marker)' from an earlier launch (pid \(pid), \(tree.count) process(es))")
            killed += 1
        }
        return killed
    }

    /// A process's command line, optionally followed by the environment it was started with
    /// (readable for the current user's own processes).
    static func commandLine(_ pid: pid_t, includeEnvironment: Bool = false) -> String? {
        let r = run("/bin/ps", (includeEnvironment ? ["-wwE"] : []) + ["-p", String(pid), "-o", "command="], timeout: 5)
        return r.ok ? r.output : nil
    }
}

// MARK: - Jobs

/// Recurring background work: the chat export, the trial outbox, the status probe, the
/// heartbeat, the screenpipe update check. A job runs its body on its own serial queue,
/// one run at a time (asking while it runs queues exactly one rerun), every `period`,
/// and retries a failure with `backoff`. Its schedule and last outcome are kept in
/// ~/.ai-aggregator/jobs/<name>.json, so a restart neither skips a backoff nor forgets a
/// failure. Every run and outcome is logged under its name, and `problem` feeds the tray.
final class Job {
    enum Outcome {
        /// Done; next run after `period` (or `next`, when given).
        case ok(String, next: TimeInterval? = nil)
        /// Failed; retried after the backoff (or `retryAfter`, e.g. a rate limit's).
        case failed(String, retryAfter: TimeInterval? = nil)
        /// Needs the user (an expired login, no device key): no retry until `kick()`.
        case blocked(String)
        /// Nothing to do this time; does not touch the backoff or the log.
        case idle
    }

    struct State: Codable {
        var nextRun: Date
        var failures = 0
        var lastRun: Date?
        var summary = "not run yet"
        var problemSince: Date?
        var blocked = false
    }

    static private(set) var all: [Job] = []
    /// Where job state is kept; tests point it at a temp directory.
    static var stateDir = Paths.data + "/jobs"

    let name: String
    let log: Log
    let period: TimeInterval
    /// A failure counts as a problem for the tray once it has lasted this long.
    let problemGrace: TimeInterval
    /// Whether runs and ok outcomes are logged (not for every-8-second jobs).
    let quiet: Bool
    private var backoff: Backoff
    private let body: (Job) -> Outcome
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var state: State
    private var running = false
    private var rerun = false
    private let statePath: String

    init(_ name: String, period: TimeInterval, firstRun: TimeInterval = 0, backoff: Backoff,
         problemGrace: TimeInterval = 0, quiet: Bool = false, body: @escaping (Job) -> Outcome) {
        self.name = name
        self.log = Log(name)
        self.period = period
        self.backoff = backoff
        self.problemGrace = problemGrace
        self.quiet = quiet
        self.body = body
        self.queue = DispatchQueue(label: "learner.job.\(name)", qos: .utility)
        try? FileManager.default.createDirectory(atPath: Job.stateDir, withIntermediateDirectories: true)
        statePath = "\(Job.stateDir)/\(name).json"
        let fresh = State(nextRun: Date().addingTimeInterval(firstRun))
        if let data = FileManager.default.contents(atPath: statePath),
           var saved = try? JSONDecoder().decode(State.self, from: data) {
            // A saved schedule is kept (a backoff survives restarts), but never later than
            // a fresh start would run it, unless it is waiting on a backoff.
            if saved.failures == 0 && !saved.blocked { saved.nextRun = min(saved.nextRun, fresh.nextRun) }
            state = saved
            self.backoff.restore(failures: saved.failures)
        } else {
            state = fresh
        }
        Job.all.append(self)
    }

    var snapshot: State { lock.withLock { state } }

    /// What the tray shows: blocked, or failing for longer than `problemGrace`.
    var problem: String? {
        let s = snapshot
        if s.blocked { return s.summary }
        guard let since = s.problemSince, Date().timeIntervalSince(since) >= problemGrace else { return nil }
        return s.summary
    }

    /// Called by the Scheduler; runs the job when it is due.
    func tick() {
        let due = lock.withLock { !state.blocked && !running && Date() >= state.nextRun }
        if due { start(reason: nil) }
    }

    /// Runs now (or right after the current run), clearing a block: after a sign-in, a
    /// menu click, a restored key.
    func kick(_ reason: String) {
        lock.withLock { state.blocked = false }
        start(reason: reason)
    }

    private func start(reason: String?) {
        let go: Bool = lock.withLock {
            if running { rerun = true; return false }
            running = true
            return true
        }
        guard go else { return }
        if !quiet { log.info(reason.map { "run: \($0)" } ?? "run") }
        queue.async { self.execute() }
    }

    private func execute() {
        let started = Date()
        let outcome = body(self)
        let took = String(format: "%.1f s", Date().timeIntervalSince(started))
        var again = false
        lock.withLock {
            running = false
            again = rerun
            rerun = false
            let now = Date()
            switch outcome {
            case .idle:
                state.nextRun = now.addingTimeInterval(period)
                return
            case let .ok(summary, next):
                if state.problemSince != nil { log.info("recovered: \(summary)") }
                else if !quiet { log.info("ok in \(took): \(summary)") }
                backoff.succeeded()
                state.failures = 0
                state.problemSince = nil
                state.blocked = false
                state.summary = summary
                state.nextRun = now.addingTimeInterval(next ?? period)
            case let .failed(summary, retryAfter):
                // A fixed retry (a rate limit's) still counts as an attempt.
                let backedOff = backoff.failed()
                let wait = retryAfter ?? backedOff
                state.failures = backoff.failures
                state.problemSince = state.problemSince ?? now
                state.summary = summary
                state.nextRun = now.addingTimeInterval(wait)
                log.warn("failed in \(took) (attempt \(state.failures)): \(summary); retrying in \(Job.describe(wait))")
            case let .blocked(summary):
                if !state.blocked || state.summary != summary { log.warn("blocked: \(summary); waiting for the user") }
                state.blocked = true
                state.problemSince = state.problemSince ?? now
                state.summary = summary
            }
            let routine = quiet && state.failures == 0 && state.problemSince == nil && !state.blocked
            state.lastRun = now
            if !routine { save() }
        }
        if again { start(reason: "queued while running") }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        do { try data.write(to: URL(fileURLWithPath: statePath), options: .atomic) }
        catch { log.warn("cannot save job state: \(error.localizedDescription)") }
    }

    static func describe(_ t: TimeInterval) -> String {
        t < 120 ? "\(Int(t)) s" : t < 7200 ? "\(Int(t / 60)) min" : String(format: "%.1f h", t / 3600)
    }
}

// MARK: - Clock

/// The app's one clock: a 1 s main-thread timer in .common mode (it keeps running while
/// a menu is open). Each registered task runs every `every` seconds; every Job is ticked
/// each second and decides for itself whether it is due.
enum Scheduler {
    private struct Task { let name: String; let every: TimeInterval; var last: Date; let run: () -> Void }
    private static var tasks: [Task] = []
    private static var timer: Timer?

    /// Main-thread work on a fixed period (the coach's 1 s tick, the tray refresh).
    static func every(_ seconds: TimeInterval, _ name: String, _ run: @escaping () -> Void) {
        tasks.append(Task(name: name, every: seconds, last: .distantPast, run: run))
    }

    static func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { _ in fire() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Log("Scheduler").info("started: \(tasks.map { "\($0.name) every \(Job.describe($0.every))" }.joined(separator: ", ")); jobs: \(Job.all.map(\.name).joined(separator: ", "))")
    }

    /// At quit: no more ticks or job runs.
    static func stop() {
        timer?.invalidate()
        timer = nil
    }

    private static func fire() {
        let now = Date()
        for i in tasks.indices where now.timeIntervalSince(tasks[i].last) >= tasks[i].every - 0.05 {
            tasks[i].last = now
            tasks[i].run()
        }
        for job in Job.all { job.tick() }
    }
}

// MARK: - Shutdown

/// Quit, SIGTERM (launchctl) and Cmd-Q all end here. Steps run in order, each with its
/// own budget and logged with how long it took; a step that overruns is left behind with
/// a warning so the rest still run, and the whole sequence stays inside `total` (launchd
/// SIGKILLs 20 s after SIGTERM).
enum Shutdown {
    struct Step {
        let name: String
        let budget: TimeInterval
        /// Runs on the calling (main) thread: must be quick, as it cannot be timed out.
        var onCallingThread = false
        /// Gets its deadline; returns a short note for the log (or nil).
        let run: (Date) -> String?
    }

    /// Returns the names of the steps that finished in time.
    @discardableResult
    static func run(_ steps: [Step], total: TimeInterval, log: Log = Log("Shutdown")) -> [String] {
        let end = Date().addingTimeInterval(total)
        var finished: [String] = []
        log.info("shutting down: \(steps.map(\.name).joined(separator: ", "))")
        for step in steps {
            let left = end.timeIntervalSinceNow
            guard left > 0.2 else {
                log.warn("\(step.name): skipped, out of time")
                continue
            }
            let deadline = Date().addingTimeInterval(min(step.budget, left))
            let started = Date()
            let done = DispatchSemaphore(value: 0)
            var note: String?
            if !step.onCallingThread {
                DispatchQueue.global(qos: .userInitiated).async {
                    note = step.run(deadline)
                    done.signal()
                }
            }
            let took = { String(format: "%.1f s", Date().timeIntervalSince(started)) }
            if step.onCallingThread {
                let note = step.run(deadline)
                log.info("\(step.name): done in \(took())\(note.map { " (\($0))" } ?? "")")
                finished.append(step.name)
                continue
            }
            if done.wait(timeout: .now() + deadline.timeIntervalSinceNow + 0.5) == .timedOut {
                log.warn("\(step.name): still running after \(took()); moving on")
            } else {
                log.info("\(step.name): done in \(took())\(note.map { " (\($0))" } ?? "")")
                finished.append(step.name)
            }
        }
        log.info("shutdown complete")
        return finished
    }
}
