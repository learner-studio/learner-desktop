import AppKit
import Foundation
import ObjCCatch
import Synchronization

// The app runs a handful of workflows -- the speaking coach, the trial outbox, the chat
// export, the helper processes and the status probe -- and they all share what is here:
// one log format (Log), one retry policy (Backoff), one way to run another program
// (ChildProcess), one way to run recurring work (Job) and one clock (Scheduler).

// MARK: - Shared state

/// A value several threads read and write: a `Mutex` in a class, so it can be a `static let`
/// or be captured by an escaping closure (a bare `Mutex` is non-copyable and can be neither).
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }

    var value: Value {
        get { mutex.withLock { $0 } }
        set { mutex.withLock { $0 = newValue } }
    }

    func withLock<R: Sendable>(_ body: (inout Value) throws -> R) rethrows -> R {
        try mutex.withLock { try body(&$0) }
    }
}

// MARK: - Paths

/// Where the app keeps its data. One place, so the test lanes can move it all to a
/// throwaway folder (LEARNER_DATA_DIR, AI_VAULT_DATA) and never touch the real files.
enum Paths {
    private static let env = ProcessInfo.processInfo.environment
    /// A test process (`swift test`) never defaults to the real folders: only the heavy
    /// lane (LEARNER_HEAVY=1) reads them, and an explicit override always wins.
    static let underTest = ["swiftpm-testing-helper", "xctest"].contains(ProcessInfo.processInfo.processName)
        && env["LEARNER_HEAVY"] != "1"
    private static let scratch = NSTemporaryDirectory() + "learner-test-\(getpid())"
    private static func real(_ path: String, _ testName: String) -> String { underTest ? "\(scratch)/\(testName)" : path }

    static let data = env["LEARNER_DATA_DIR"] ?? real(NSHomeDirectory() + "/.ai-aggregator", "data")
    static let logs = data + "/logs"
    /// ai-vault's export (its own default location).
    static let vault = env["AI_VAULT_DATA"] ?? real(NSHomeDirectory() + "/ai-vault-data", "ai-vault-data")
    /// ai-vault's logins and settings.
    static let aiVaultConfig = env["AI_VAULT_CONFIG"] ?? real(NSHomeDirectory() + "/.ai-vault/config.json", "ai-vault-config.json")
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

    private struct State {
        /// Tests capture lines here instead of stdout.
        var sink: (@Sendable (String) -> Void)?
        var lastSeen: [String: (at: Date, held: Int)] = [:]
        var writes = 0
        let stamp: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return f
        }()
    }
    private static let state = Mutex(State())

    /// Tests capture lines here instead of stdout.
    static var sink: (@Sendable (String) -> Void)? {
        get { state.withLock { $0.sink } }
        set { state.withLock { $0.sink = newValue } }
    }

    /// Send stdout/stderr to the log file (launchd points them there too; this lets the app
    /// rotate it). Not used by the one-shot CLI modes, which print to the terminal.
    static func attachToFile() {
        rotate()
        freopen(path, "a", stdout)
        freopen(path, "a", stderr)
    }

    static func write(_ line: String, collapse: Bool) {
        state.withLock { s in
            let now = Date()
            var text = line
            if collapse {
                let key = line.replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
                if let seen = s.lastSeen[key], now.timeIntervalSince(seen.at) < repeatWindow {
                    s.lastSeen[key] = (seen.at, seen.held + 1)
                    return
                } else if let seen = s.lastSeen[key], seen.held > 0 {
                    text += "  [repeated \(seen.held)x in the previous \(Int(repeatWindow / 60)) min]"
                }
                if s.lastSeen.count > 2000 { s.lastSeen.removeAll() }
                s.lastSeen[key] = (now, 0)
            }
            let stamped = "\(s.stamp.string(from: now)) \(text)"
            if let sink = s.sink { sink(stamped); return }
            Swift.print(stamped)
            fflush(stdout)
            s.writes += 1
            if s.writes % 500 == 0 { rotate() }
        }
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
                    input: Data? = nil, onStart: ((Process) -> Void)? = nil) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let env = env { p.environment = env }
        // Secrets go in on stdin, never in the arguments (which `ps` shows anyone).
        let stdin = input.map { _ in Pipe() }
        p.standardInput = stdin ?? FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = stderr ? out : FileHandle.nullDevice
        let log = logFile.flatMap(LogFile.open)
        defer { try? log?.close() }
        log?.write(Data("=== \(Date()) \(([executable] + args).map { ($0 as NSString).lastPathComponent }.prefix(3).joined(separator: " "))\n".utf8))

        struct Reading { var data = Data(), eof = false, lastOutput = Date() }
        let reading = Locked(Reading())
        out.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            reading.withLock { r in
                if chunk.isEmpty {
                    r.eof = true
                    h.readabilityHandler = nil
                } else {
                    r.data.append(chunk)
                    r.lastOutput = Date()
                    log?.write(chunk)
                }
            }
        }
        do {
            try p.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            return Result(status: nil, output: "", stopped: "could not start: \(error.localizedDescription)")
        }
        if let stdin, let input {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }
        onStart?(p)
        let started = Date()
        var stopped: String?
        while p.isRunning {
            usleep(50_000)
            let now = Date()
            if now.timeIntervalSince(started) > timeout {
                stopped = "ran over \(Int(timeout)) s"
            } else if let stall = stallTimeout, now.timeIntervalSince(reading.value.lastOutput) > stall {
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
        while Date() < drained && !reading.value.eof { usleep(10_000) }
        out.fileHandleForReading.readabilityHandler = nil
        if let why = stopped { log?.write(Data("\n=== stopped: \(why)\n".utf8)) }
        let text = String(data: reading.value.data, encoding: .utf8) ?? ""
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
///
/// The body is synchronous and runs on the job's own serial queue, so it may block on a
/// child process, SQLite or HTTP. Everything mutable sits in one Mutex.
final class Job: Sendable {
    enum Outcome: Sendable {
        /// Done; next run after `period` (or `next`, when given).
        case ok(String, next: TimeInterval? = nil)
        /// Failed; retried after the backoff (or `retryAfter`, e.g. a rate limit's).
        case failed(String, retryAfter: TimeInterval? = nil)
        /// Held off by someone else (a rate limit): nothing is broken and nothing for the user
        /// to do, so not a failure. Retried after `retryAfter`; shown as waiting, not red.
        case waiting(String, retryAfter: TimeInterval)
        /// Needs the user (an expired login, no device key): no retry until `kick()`.
        case blocked(String)
        /// Nothing to do this time; does not touch the backoff or the log.
        case idle
    }

    struct State: Codable, Sendable {
        var nextRun: Date
        var failures = 0
        var lastRun: Date?
        var summary = "not run yet"
        var problemSince: Date?
        var blocked = false
        /// Since when it has been held off (`.waiting`), back to back.
        var waitingSince: Date?
    }

    private static let registry = Locked<[Job]>([])
    private static let sharedStateDir = Locked(Paths.data + "/jobs")
    /// Every job made so far, in the order they were made.
    static var all: [Job] { registry.value }
    /// Where job state is kept; tests point it at a temp directory.
    static var stateDir: String {
        get { sharedStateDir.value }
        set { sharedStateDir.value = newValue }
    }

    let name: String
    let log: Log
    let period: TimeInterval
    /// A failure counts as a problem for the tray once it has lasted this long.
    let problemGrace: TimeInterval
    /// Whether runs and ok outcomes are logged (not for every-8-second jobs).
    let quiet: Bool
    /// A blocked job is checked again once at launch and then this often, so a block that
    /// was wrong, or that the user fixed elsewhere, clears itself.
    let blockedRecheck: TimeInterval
    private let body: @Sendable (Job) -> Outcome
    private let queue: DispatchQueue
    private let statePath: String
    /// The persisted state, plus what only lives while the app runs.
    private struct Live {
        var state: State
        var backoff: Backoff
        var running = false
        var rerun = false
    }
    private let live: Mutex<Live>

    init(_ name: String, period: TimeInterval, firstRun: TimeInterval = 0, backoff: Backoff,
         problemGrace: TimeInterval = 0, quiet: Bool = false, stateDir: String = Job.stateDir,
         blockedRecheck: TimeInterval = 6 * 3600, body: @escaping @Sendable (Job) -> Outcome) {
        self.name = name
        self.log = Log(name)
        self.period = period
        self.problemGrace = problemGrace
        self.quiet = quiet
        self.blockedRecheck = blockedRecheck
        self.body = body
        self.queue = DispatchQueue(label: "learner.job.\(name)", qos: .utility)
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        statePath = "\(stateDir)/\(name).json"
        let fresh = State(nextRun: Date().addingTimeInterval(firstRun))
        var restored = backoff
        var state = fresh
        if let data = FileManager.default.contents(atPath: statePath),
           var saved = try? JSONDecoder().decode(State.self, from: data) {
            // A saved schedule is kept (a backoff survives restarts), but never later than
            // a fresh start would run it, unless it is waiting on a backoff.
            if saved.failures == 0 && !saved.blocked { saved.nextRun = min(saved.nextRun, fresh.nextRun) }
            // Blocked at the last launch: check once now that the app has started again.
            if saved.blocked { saved.nextRun = fresh.nextRun }
            state = saved
            restored.restore(failures: saved.failures)
        }
        live = Mutex(Live(state: state, backoff: restored))
        Job.registry.withLock { $0.append(self) }
    }

    var snapshot: State { live.withLock { $0.state } }

    /// What the tray shows: blocked, or failing for longer than `problemGrace`.
    var problem: String? {
        let s = snapshot
        if s.blocked { return s.summary }
        guard let since = s.problemSince, Date().timeIntervalSince(since) >= problemGrace else { return nil }
        return s.summary
    }

    /// What the tray shows as waiting (yellow): held off by a rate limit, not failing.
    var waiting: String? {
        let s = snapshot
        guard s.waitingSince != nil, !s.blocked else { return nil }
        return "\(s.summary); next try \(DateFormatter.localizedString(from: s.nextRun, dateStyle: .none, timeStyle: .short))"
    }

    /// Called by the Scheduler; runs the job when it is due.
    func tick() {
        let due = live.withLock { !$0.running && Date() >= $0.state.nextRun }
        if due { start(reason: nil) }
    }

    /// Runs now (or right after the current run), clearing a block: after a sign-in, a
    /// menu click, a restored key.
    func kick(_ reason: String) {
        live.withLock { $0.state.blocked = false }
        start(reason: reason)
    }

    private func start(reason: String?) {
        let go: Bool = live.withLock {
            if $0.running { $0.rerun = true; return false }
            $0.running = true
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
        let again: Bool = live.withLock { l in
            defer { l.running = false; l.rerun = false }
            let again = l.rerun
            let now = Date()
            switch outcome {
            case .idle:
                if !quiet { log.info("nothing to do (\(took))") }
                l.state.nextRun = now.addingTimeInterval(period)
                return again
            case let .ok(summary, next):
                if l.state.problemSince != nil { log.info("recovered: \(summary)") }
                else if !quiet { log.info("ok in \(took): \(summary)") }
                l.backoff.succeeded()
                l.state.failures = 0
                l.state.problemSince = nil
                l.state.blocked = false
                l.state.waitingSince = nil
                l.state.summary = summary
                l.state.nextRun = now.addingTimeInterval(next ?? period)
            case let .failed(summary, retryAfter):
                // A fixed retry (a rate limit's) still counts as an attempt.
                let backedOff = l.backoff.failed()
                let wait = retryAfter ?? backedOff
                l.state.failures = l.backoff.failures
                l.state.problemSince = l.state.problemSince ?? now
                l.state.blocked = false
                l.state.waitingSince = nil
                l.state.summary = summary
                l.state.nextRun = now.addingTimeInterval(wait)
                log.warn("failed in \(took) (attempt \(l.state.failures)): \(summary); retrying in \(Job.describe(wait))")
            case let .waiting(summary, retryAfter):
                // Counted as an attempt (callers grow the wait with it), but not a problem.
                _ = l.backoff.failed()
                l.state.failures = l.backoff.failures
                l.state.problemSince = nil
                l.state.blocked = false
                l.state.waitingSince = l.state.waitingSince ?? now
                l.state.summary = summary
                l.state.nextRun = now.addingTimeInterval(retryAfter)
                log.warn("held off in \(took) (attempt \(l.state.failures)): \(summary); trying again in \(Job.describe(retryAfter))")
            case let .blocked(summary):
                if !l.state.blocked || l.state.summary != summary { log.warn("blocked: \(summary); waiting for the user (checking again in \(Job.describe(blockedRecheck)))") }
                l.state.blocked = true
                l.state.waitingSince = nil
                l.state.nextRun = now.addingTimeInterval(blockedRecheck)
                l.state.problemSince = l.state.problemSince ?? now
                l.state.summary = summary
            }
            let routine = quiet && l.state.failures == 0 && l.state.problemSince == nil && !l.state.blocked
            l.state.lastRun = now
            // Under the lock, so two saves can never land out of order.
            if !routine { save(l.state) }
            return again
        }
        if again { start(reason: "queued while running") }
    }

    private func save(_ state: State) {
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
///
/// Why not NSBackgroundActivityScheduler for the hourly jobs (Export, Archive): due-ness
/// is the job's persisted nextRun, which a backoff, a rate limit's fixed retry, a block's
/// recheck or a kick moves at any time. An OS activity would have to be torn down and
/// rescheduled after every outcome, may defer the work by far more than a 15 min backoff
/// asks for, and would be a second clock the tests cannot drive. A 1 s tick that compares
/// two dates costs nothing measurable; the timer's tolerance lets macOS coalesce it.
@MainActor
enum Scheduler {
    private struct Task { let name: String; let every: TimeInterval; var last: Date; let run: @MainActor () -> Void }
    private static var tasks: [Task] = []
    private static var timer: Timer?

    /// Main-thread work on a fixed period (the coach's 1 s tick, the tray refresh).
    static func every(_ seconds: TimeInterval, _ name: String, _ run: @escaping @MainActor () -> Void) {
        tasks.append(Task(name: name, every: seconds, last: .distantPast, run: run))
    }

    static func start() {
        guard timer == nil else { return }
        // On the main run loop, so it always fires on the main thread.
        let t = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { fire() } }
        t.tolerance = 0.1
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
            guarded(tasks[i].name, tasks[i].run)
        }
        for job in Job.all { guarded(job.name, job.tick) }
    }

    /// An Objective-C exception raised in one task stops that tick of it, never the clock:
    /// one escaping the timer leaves it marked as firing and it never fires again (10-28:
    /// the coach, the tray and every job stood still for an hour behind a red tray).
    static func guarded(_ name: String, _ run: () -> Void) {
        if let raised = LDCatchException(run) {
            Log("Scheduler").error("\(name) raised \(raised.name.rawValue): \(raised.reason ?? "no reason"); the clock keeps running")
        }
    }
}

// MARK: - Shutdown

/// Quit, SIGTERM (launchctl) and Cmd-Q all end here. Steps run in order, each with its
/// own budget and logged with how long it took; a step that overruns is left behind with
/// a warning so the rest still run, and the whole sequence stays inside `total` (launchd
/// SIGKILLs 20 s after SIGTERM).
enum Shutdown {
    struct Step: Sendable {
        let name: String
        let budget: TimeInterval
        /// Runs on the calling (main) thread: must be quick, as it cannot be timed out.
        var onCallingThread = false
        /// Gets its deadline; returns a short note for the log (or nil).
        let run: @Sendable (Date) -> String?
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
            let took = { String(format: "%.1f s", Date().timeIntervalSince(started)) }
            let note: String?
            if step.onCallingThread {
                note = step.run(deadline)
            } else {
                let done = DispatchSemaphore(value: 0)
                let result = Locked<String?>(nil)
                DispatchQueue.global(qos: .userInitiated).async {
                    result.value = step.run(deadline)
                    done.signal()
                }
                if done.wait(timeout: .now() + deadline.timeIntervalSinceNow + 0.5) == .timedOut {
                    log.warn("\(step.name): still running after \(took()); moving on")
                    continue
                }
                note = result.value
            }
            log.info("\(step.name): done in \(took())\(note.map { " (\($0))" } ?? "")")
            finished.append(step.name)
        }
        log.info("shutdown complete")
        return finished
    }
}
