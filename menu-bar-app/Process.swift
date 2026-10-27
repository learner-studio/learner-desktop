import AppKit
import Foundation
import ServiceManagement
import SQLite3
import CoreBluetooth
import CommonCrypto

// MARK: - Bundled Helpers (SSH tunnel, transcript watcher)

/// A helper process the app runs for as long as it is running. The SSH tunnel and the
/// transcript watcher used to be separate /bin/bash LaunchAgents, which Login Items lists
/// as "bash" from an unknown developer; once switched off there, launchd silently stopped
/// starting them at login (ten days down after the 2026-10-11 reboot). As children of the
/// app they share its one Login Items entry and start, stop and restart with it.
final class ManagedHelper {
    let name: String
    private let executable: String
    private let arguments: [String]
    /// Part of the helper's command line, to recognise an orphan from a crashed run.
    private let marker: String
    private let logPath: String
    private let pidPath: String
    private let log: Log
    private var process: Process?
    private var logHandle: FileHandle?
    private var stopping = false
    private(set) var startedAt = Date.distantPast
    /// Restarts back off 1 s doubling to 60 s; a run that stayed up a minute resets it.
    private var backoff = Backoff(base: 1, max: 60, jitter: 0)
    static let healthyAfter: TimeInterval = 60

    /// Extra environment, read at each launch (so a key is fetched fresh and never stored).
    private let environment: () -> [String: String]
    /// What particular exit codes mean for this helper: a wait before the next start, and
    /// whether to show it as a problem (a config error) or not (another copy is running).
    struct ExitRule { let note: String; let wait: TimeInterval; let isProblem: Bool }
    private let exitRules: [Int32: ExitRule]
    /// The shortest wait before a restart (the uploader expects about 30 s, like launchd's
    /// ThrottleInterval).
    private let minRestart: TimeInterval
    private var lastExit: (code: Int32, rule: ExitRule)?

    init(name: String, executable: String, arguments: [String], marker: String,
         runtimeDir: String = Paths.data, environment: @escaping () -> [String: String] = { [:] },
         minRestart: TimeInterval = 1, exitRules: [Int32: ExitRule] = [:]) {
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

    var isRunning: Bool { process?.isRunning ?? false }

    /// For the tray: down, or restarting again and again.
    var problem: String? {
        if stopping { return nil }
        if let last = lastExit, !isRunning { return last.rule.isProblem ? "\(name): \(last.rule.note)" : nil }
        if !isRunning { return "\(name) is not running" }
        return backoff.failures >= 3 ? "\(name) keeps exiting (\(backoff.failures) restarts)" : nil
    }

    func start() {
        stopping = false
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
        guard !stopping, !isRunning else { return }
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
            let wait = backoff.failed()
            log.error("could not start: \(error.localizedDescription); retrying in \(Job.describe(wait))")
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.launch() }
            return
        }
        process = p
        logHandle = out
        startedAt = Date()
        lastExit = nil
        do { try String(p.processIdentifier).write(toFile: pidPath, atomically: true, encoding: .utf8) }
        catch { log.warn("cannot write \(pidPath): \(error.localizedDescription); a crash would leave it orphaned") }
        log.info("started (pid \(p.processIdentifier))")
    }

    private func exited(_ proc: Process) {
        guard proc === process else { return }
        process = nil
        try? logHandle?.close()
        logHandle = nil
        try? FileManager.default.removeItem(atPath: pidPath)
        if stopping { return }
        // One that stayed up a minute was healthy, so bring it back promptly; one that dies
        // straight away (no network, port already held) backs off instead of spinning.
        if Date().timeIntervalSince(startedAt) > ManagedHelper.healthyAfter { backoff.succeeded() }
        let code = proc.terminationStatus
        let ran = Job.describe(Date().timeIntervalSince(startedAt))
        let wait: TimeInterval
        if let rule = exitRules[code] {
            lastExit = (code, rule)
            wait = rule.wait
            if rule.isProblem { log.warn("exited \(code) (\(rule.note)) after \(ran); trying again in \(Job.describe(wait))") }
            else { log.info("exited \(code) (\(rule.note)) after \(ran); checking again in \(Job.describe(wait))") }
        } else {
            lastExit = nil
            wait = max(minRestart, backoff.failed())
            log.warn("exited (status \(code)) after \(ran); restarting in \(Job.describe(wait))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.launch() }
    }

    /// SIGTERM, then SIGKILL for it and its children (autossh's ssh) after `grace`. Blocks
    /// the caller, so call it off the main thread except at quit.
    func stop(grace: TimeInterval = 5) {
        stopping = true
        guard let p = process else { return }
        if p.isRunning {
            ChildProcess.stop(p, grace: grace)
            log.info("stopped")
        }
        process = nil
        try? logHandle?.close()
        logHandle = nil
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
        let deadline = Date().addingTimeInterval(3)
        while kill(pid, 0) == 0 && Date() < deadline { usleep(100_000) }
        for p in tree where kill(p, 0) == 0 { kill(p, SIGKILL) }
    }
}
