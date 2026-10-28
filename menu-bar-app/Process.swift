import AppKit
import Foundation

// MARK: - Bundled Helpers (the CLI uploader)

/// A helper process the app runs for as long as it is running. The SSH tunnel and the
/// transcript watcher used to be separate /bin/bash LaunchAgents, which Login Items lists
/// as "bash" from an unknown developer; once switched off there, launchd silently stopped
/// starting them at login (ten days down after the 2026-10-11 reboot). As children of the
/// app they share its one Login Items entry and start, stop and restart with it.
///
/// Started, restarted and reaped on the main thread; stopped from any thread; read by the
/// Status job off the main thread. Its state is behind one lock.
final class ManagedHelper: Sendable {
    let name: String
    private let executable: String
    private let arguments: [String]
    /// Part of the helper's command line, to recognise an orphan from a crashed run.
    private let marker: String
    private let logPath: String
    private let pidPath: String
    private let log: Log
    private struct State {
        var process: Process?
        var logHandle: FileHandle?
        var stopping = false
        var startedAt = Date.distantPast
        /// Restarts back off 1 s doubling to 60 s; a run that stayed up a minute resets it.
        var backoff = Backoff(base: 1, max: 60, jitter: 0)
        var lastExit: (code: Int32, rule: ExitRule)?
    }
    private let state: Locked<State>
    static let healthyAfter: TimeInterval = 60
    /// How long an orphan from a crashed run gets to exit after SIGTERM before SIGKILL.
    private let reapWait: TimeInterval

    /// Extra environment, read at each launch (so a key is fetched fresh and never stored).
    private let environment: @Sendable () -> [String: String]
    /// What particular exit codes mean for this helper: a wait before the next start, and
    /// whether to show it as a problem (a config error) or not (another copy is running).
    struct ExitRule: Sendable { let note: String; let wait: TimeInterval; let isProblem: Bool }
    private let exitRules: [Int32: ExitRule]
    /// The shortest wait before a restart (the uploader expects about 30 s, like launchd's
    /// ThrottleInterval).
    private let minRestart: TimeInterval

    init(name: String, executable: String, arguments: [String], marker: String,
         runtimeDir: String = Paths.data, environment: @escaping @Sendable () -> [String: String] = { [:] },
         minRestart: TimeInterval = 1, exitRules: [Int32: ExitRule] = [:],
         restartBackoff: Backoff = Backoff(base: 1, max: 60, jitter: 0), reapWait: TimeInterval = 3) {
        var initial = State()
        initial.backoff = restartBackoff
        state = Locked(initial)
        self.reapWait = reapWait
        self.environment = environment
        self.minRestart = minRestart
        self.exitRules = exitRules
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.marker = marker
        self.log = Log("Helper:\(name)")
        logPath = runtimeDir + "/logs/\(name).log"
        pidPath = runtimeDir + "/\(name).pid"
        try? FileManager.default.createDirectory(atPath: runtimeDir + "/logs", withIntermediateDirectories: true)
    }

    var isRunning: Bool { state.value.process?.isRunning ?? false }

    /// For the tray: down, or restarting again and again.
    var problem: String? {
        let s = state.value
        if s.stopping { return nil }
        let running = s.process?.isRunning ?? false
        if let last = s.lastExit, !running { return last.rule.isProblem ? "\(name): \(last.rule.note)" : nil }
        if !running { return "\(name) is not running" }
        return s.backoff.failures >= 3 ? "\(name) keeps exiting (\(s.backoff.failures) restarts)" : nil
    }

    func start() {
        state.withLock { $0.stopping = false }
        reapOrphan()
        launch()
    }

    /// Stops (blocking, off the main thread) and starts again on the main thread.
    func restart() {
        log.info("restart requested")
        DispatchQueue.global(qos: .userInitiated).async {
            self.stop()
            DispatchQueue.main.async { self.start() }
        }
    }

    private func launch() {
        guard !state.value.stopping, !isRunning else { return }
        let out = LogFile.open(logPath)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.currentDirectoryURL = URL(fileURLWithPath: (pidPath as NSString).deletingLastPathComponent)
        p.environment = ChildProcess.toolEnvironment.merging(environment()) { _, extra in extra }
        if let out = out {
            p.standardOutput = out
            p.standardError = out
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.exited(proc) }
        }
        do {
            try p.run()
        } catch {
            // A missing binary, or one being replaced: keep trying, backing off.
            try? out?.close()
            let wait = state.withLock { $0.backoff.failed() }
            log.error("could not start: \(error.localizedDescription); retrying in \(Job.describe(wait))")
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.launch() }
            return
        }
        state.withLock {
            $0.process = p
            $0.logHandle = out
            $0.startedAt = Date()
            $0.lastExit = nil
        }
        do { try String(p.processIdentifier).write(toFile: pidPath, atomically: true, encoding: .utf8) }
        catch { log.warn("cannot write \(pidPath): \(error.localizedDescription); a crash would leave it orphaned") }
        log.info("started (pid \(p.processIdentifier))")
    }

    private func exited(_ proc: Process) {
        let (current, handle, stopping, startedAt) = state.withLock { s -> (Bool, FileHandle?, Bool, Date) in
            guard proc === s.process else { return (false, nil, s.stopping, s.startedAt) }
            defer { s.process = nil; s.logHandle = nil }
            return (true, s.logHandle, s.stopping, s.startedAt)
        }
        guard current else { return }
        try? handle?.close()
        try? FileManager.default.removeItem(atPath: pidPath)
        if stopping { return }
        let code = proc.terminationStatus
        let ran = Job.describe(Date().timeIntervalSince(startedAt))
        let rule = exitRules[code]
        let wait: TimeInterval = state.withLock { s in
            // One that stayed up a minute was healthy, so bring it back promptly; one that dies
            // straight away (no network, port already held) backs off instead of spinning.
            if Date().timeIntervalSince(startedAt) > ManagedHelper.healthyAfter { s.backoff.succeeded() }
            s.lastExit = rule.map { (code, $0) }
            return rule?.wait ?? max(minRestart, s.backoff.failed())
        }
        if let rule = rule {
            if rule.isProblem { log.warn("exited \(code) (\(rule.note)) after \(ran); trying again in \(Job.describe(wait))") }
            else { log.info("exited \(code) (\(rule.note)) after \(ran); checking again in \(Job.describe(wait))") }
        } else {
            log.warn("exited (status \(code)) after \(ran); restarting in \(Job.describe(wait))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.launch() }
    }

    /// SIGTERM, then SIGKILL for it and its children (autossh's ssh) after `grace`. Blocks
    /// the caller, so call it off the main thread except at quit.
    func stop(grace: TimeInterval = 5) {
        let p: Process? = state.withLock { $0.stopping = true; return $0.process }
        guard let p = p else { return }
        if p.isRunning {
            ChildProcess.stop(p, grace: grace)
            log.info("stopped")
        }
        let handle: FileHandle? = state.withLock { s in
            defer { s.process = nil; s.logHandle = nil }
            return s.logHandle
        }
        try? handle?.close()
        try? FileManager.default.removeItem(atPath: pidPath)
    }

    /// macOS has no parent-death signal, so a crashed or force-killed app leaves its
    /// helpers running and holding the forwarded ports. The pid file lets the next launch
    /// stop them first -- but only if that pid still belongs to one (pids are reused).
    private func reapOrphan() {
        defer { try? FileManager.default.removeItem(atPath: pidPath) }
        guard let text = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1,
              let command = ChildProcess.commandLine(pid), command.contains(marker) else { return }
        log.warn("stopping one left over from a previous run (pid \(pid))")
        let tree = [pid] + ChildProcess.descendants(of: pid)
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(reapWait)
        while kill(pid, 0) == 0 && Date() < deadline { usleep(100_000) }
        for p in tree where kill(p, 0) == 0 { kill(p, SIGKILL) }
    }
}
