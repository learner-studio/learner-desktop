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
    private var process: Process?
    private var logHandle: FileHandle?
    private var stopping = false
    private(set) var startedAt = Date.distantPast
    private var restartDelay: TimeInterval = 1

    init(name: String, executable: String, arguments: [String], marker: String) {
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.marker = marker
        let runtimeDir = NSHomeDirectory() + "/.ai-aggregator"
        logPath = runtimeDir + "/logs/\(name).log"
        pidPath = runtimeDir + "/\(name).pid"
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func start() {
        stopping = false
        reapOrphan()
        launch()
    }

    func restart() {
        stop()
        start()
    }

    private func launch() {
        guard !stopping, !isRunning else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: logPath) { fm.createFile(atPath: logPath, contents: nil) }
        LogFile.rotate(logPath)
        if !fm.fileExists(atPath: logPath) { fm.createFile(atPath: logPath, contents: nil) }
        let log = FileHandle(forWritingAtPath: logPath)
        log?.seekToEndOfFile()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ai-aggregator")
        if let log = log {
            p.standardOutput = log
            p.standardError = log
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.exited(proc) }
        }
        do {
            try p.run()
        } catch {
            // A missing binary, or one being replaced (bun upgrade): keep trying, backing off.
            try? log?.close()
            restartDelay = min(restartDelay * 2, 60)
            print("[Helpers] Could not start \(name): \(error.localizedDescription); retrying in \(Int(restartDelay))s")
            fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + restartDelay) { [weak self] in
                self?.launch()
            }
            return
        }
        process = p
        logHandle = log
        startedAt = Date()
        try? String(p.processIdentifier).write(toFile: pidPath, atomically: true, encoding: .utf8)
        print("[Helpers] Started \(name) (pid \(p.processIdentifier))")
        fflush(stdout)
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
        restartDelay = Date().timeIntervalSince(startedAt) > 60 ? 1 : min(restartDelay * 2, 60)
        print("[Helpers] \(name) exited (status \(proc.terminationStatus)); restarting in \(Int(restartDelay))s")
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + restartDelay) { [weak self] in
            self?.launch()
        }
    }

    /// SIGTERM, then SIGKILL if it is still running after `timeout`. Blocks the caller.
    func stop(timeout: TimeInterval = 5) {
        stopping = true
        guard let p = process else { return }
        if p.isRunning {
            p.terminate()
            var deadline = Date().addingTimeInterval(timeout)
            while p.isRunning && Date() < deadline { usleep(100_000) }
            if p.isRunning {
                kill(p.processIdentifier, SIGKILL)
                deadline = Date().addingTimeInterval(2)
                while p.isRunning && Date() < deadline { usleep(100_000) }
            }
            print("[Helpers] Stopped \(name)")
            fflush(stdout)
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
        print("[Helpers] Stopping \(name) left over from a previous run (pid \(pid))")
        fflush(stdout)
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(3)
        while kill(pid, 0) == 0 && Date() < deadline { usleep(100_000) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }
}
