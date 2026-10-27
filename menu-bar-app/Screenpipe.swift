import AppKit
import Foundation
import ServiceManagement
import SQLite3
import CoreBluetooth
import CommonCrypto

/// Version of the screenpipe capture engine currently feeding transcriptions.
///
/// Stamped onto every turn so a change of measuring instrument shows up in the analysis
/// instead of silently shifting turn counts and durations mid-experiment.
enum CaptureEnvironment {
    private static let lock = NSLock()
    private static var storedVersion: String?
    private static var storedAppVersion: String?

    static var screenpipeVersion: String? {
        get { lock.lock(); defer { lock.unlock() }; return storedVersion }
        set { lock.lock(); storedVersion = newValue; lock.unlock() }
    }

    static var screenpipeAppVersion: String? {
        get { lock.lock(); defer { lock.unlock() }; return storedAppVersion }
        set { lock.lock(); storedAppVersion = newValue; lock.unlock() }
    }

    /// The experiment phase a turn belongs to: each screenpipe version is its own phase.
    /// scripts/start-capture-phase.py names the GrowthBook phase with the same string.
    static var capturePhase: String? {
        guard let app = screenpipeAppVersion, let engine = screenpipeVersion else { return nil }
        return "screenpipe \(app) / engine \(engine)"
    }
}

// MARK: - screenpipe Update Check

/// screenpipe updates itself (the vendor forces auto-update on), and updates have broken
/// this setup before: 2.7.34 added an account sign-in, and 2.7.116 converted the database
/// and came back with capture off. Each version is also a new phase of the experiment.
/// When the installed version changes, this starts a fresh headless Claude Code session
/// that follows docs/screenpipe-update-runbook.md under the permissions in
/// config/screenpipe-update-agent.json, and logs the run.
final class ScreenpipeUpdateCheck {
    static let shared = ScreenpipeUpdateCheck()

    /// An update swaps the app bundle first, the engine only after a relaunch, and may then
    /// spend minutes converting storage. Act once the version has held still this long.
    static let settleSeconds: TimeInterval = 600
    static let timeoutSeconds: TimeInterval = 1800
    /// Ceiling on what one unattended run may spend.
    static let maxBudgetUSD = "5"

    private let projectDir = "/Users/benpollack/code/learner-desktop"
    private let statePath = NSHomeDirectory() + "/.ai-aggregator/screenpipe-update-check.json"
    /// Optional long-lived token from `claude setup-token`, saved by the owner (chmod 600).
    private let tokenPath = NSHomeDirectory() + "/.ai-aggregator/claude-oauth-token"
    let logDir = NSHomeDirectory() + "/.ai-aggregator/logs/screenpipe-update-checks"
    private var indexPath: String { logDir + "/index.log" }
    private var pending: (version: String, since: Date)?
    private var running: Process?
    private var transcriptHandle: FileHandle?

    var isRunning: Bool { running != nil }

    static func installedAppVersion() -> String? {
        let plist = URL(fileURLWithPath: "/Applications/screenpipe.app/Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    /// The most recent line of the run index, for the menu.
    var lastRunSummary: String? {
        guard let text = try? String(contentsOfFile: indexPath, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").last.map { String($0.prefix(60)) }
    }

    /// Called with the installed screenpipe version on every status poll.
    func observe(appVersion: String) {
        guard running == nil else { return }
        guard let handled = handledVersion() else {
            // First sighting since this was installed: a baseline, not an update.
            saveHandled(appVersion)
            return
        }
        guard appVersion != handled else {
            pending = nil
            return
        }
        if pending?.version != appVersion {
            pending = (appVersion, Date())
            print("[UpdateCheck] screenpipe \(handled) -> \(appVersion); checking once it has settled")
            fflush(stdout)
            return
        }
        guard let since = pending?.since, Date().timeIntervalSince(since) >= Self.settleSeconds else { return }
        pending = nil
        // Once per version, even if the run fails: a rerun is one menu click away.
        saveHandled(appVersion)
        start(reason: "screenpipe updated from \(handled) to \(appVersion)")
    }

    func start(reason: String) {
        guard running == nil else { return }
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        let stamp = formatter.string(from: Date())
        let transcript = "\(logDir)/\(stamp).jsonl"
        FileManager.default.createFile(atPath: transcript, contents: nil)
        guard let out = FileHandle(forWritingAtPath: transcript) else { return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: NSHomeDirectory() + "/.local/bin/claude")
        p.currentDirectoryURL = URL(fileURLWithPath: projectDir)
        p.arguments = [
            "-p", "\(reason) (detected by Learner Desktop). Follow docs/screenpipe-update-runbook.md "
                + "in this repository exactly and end with the report it describes.",
            "--output-format", "stream-json", "--verbose",
            "--settings", projectDir + "/config/screenpipe-update-agent.json",
            "--max-budget-usd", Self.maxBudgetUSD,
        ]
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "\(home)/.local/bin:\(home)/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        // An interactive `claude auth login` sits in a keychain slot keyed by $USER (a shell
        // without USER saves it elsewhere) and can expire between updates. A long-lived
        // token, when saved, keeps unattended runs from depending on either.
        // Tokens contain no whitespace; a copy across a terminal line wrap adds some.
        if let saved = try? String(contentsOfFile: tokenPath, encoding: .utf8)
            .components(separatedBy: .whitespacesAndNewlines).joined(), !saved.isEmpty {
            env["CLAUDE_CODE_OAUTH_TOKEN"] = saved
        }
        p.environment = env
        p.standardOutput = out
        p.standardError = out
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.finished(proc, stamp: stamp, reason: reason) }
        }
        do {
            try p.run()
        } catch {
            try? out.close()
            print("[UpdateCheck] Could not start claude: \(error.localizedDescription)")
            fflush(stdout)
            appendIndex("\(stamp)  STATUS: NOT STARTED (\(error.localizedDescription))  \(reason)")
            return
        }
        running = p
        transcriptHandle = out
        print("[UpdateCheck] Started a Claude Code session: \(reason). Transcript: \(transcript)")
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeoutSeconds) { [weak self] in
            guard let self = self, self.running === p else { return }
            print("[UpdateCheck] Still running after \(Int(Self.timeoutSeconds / 60)) min; stopping it")
            fflush(stdout)
            p.terminate()
            // Ignoring SIGTERM must not leave a check "running" forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
    }

    private func finished(_ proc: Process, stamp: String, reason: String) {
        running = nil
        try? transcriptHandle?.close()
        transcriptHandle = nil
        // stream-json ends with one "result" event carrying the report, cost and session id.
        let lines = (try? String(contentsOfFile: "\(logDir)/\(stamp).jsonl", encoding: .utf8))?
            .split(separator: "\n") ?? []
        let events = lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let result = events.last { $0["type"] as? String == "result" }
        let session = (result?["session_id"] ?? events.first?["session_id"]) as? String ?? "unknown"
        let cost = (result?["total_cost_usd"] as? NSNumber).map { String(format: "$%.2f", $0.doubleValue) } ?? "$?"
        let report = result?["result"] as? String ?? "No report: claude exited with status \(proc.terminationStatus)."
        let reportPath = "\(logDir)/\(stamp).md"
        try? "# \(reason)\n\nSession: \(session) (`claude --resume \(session)` from the project folder)\nCost: \(cost)\n\n\(report)\n"
            .write(toFile: reportPath, atomically: true, encoding: .utf8)
        let reportLines = report.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let status: String
        if result?["is_error"] as? Bool == true {
            // e.g. "Failed to authenticate: OAuth session expired and could not be refreshed"
            status = "STATUS: RUN FAILED (\((reportLines.first ?? "").prefix(100)))"
        } else {
            // Asked to lead with it, but a session may open with a one-line summary first.
            status = reportLines.first(where: { $0.hasPrefix("STATUS:") }) ?? "STATUS: NO REPORT"
        }
        appendIndex("\(stamp)  \(status)  session \(session)  \(cost)  \(reason)")
        print("[UpdateCheck] Finished (exit \(proc.terminationStatus)): \(status), session \(session), \(cost). Report: \(reportPath)")
        fflush(stdout)
    }

    private func appendIndex(_ line: String) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: indexPath) { fm.createFile(atPath: indexPath, contents: nil) }
        guard let index = FileHandle(forWritingAtPath: indexPath) else { return }
        index.seekToEndOfFile()
        index.write(Data((line + "\n").utf8))
        try? index.close()
    }

    private func handledVersion() -> String? {
        guard let data = FileManager.default.contents(atPath: statePath),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return state["handled_app_version"] as? String
    }

    private func saveHandled(_ version: String) {
        let state = ["handled_app_version": version]
        if let data = try? JSONSerialization.data(withJSONObject: state) {
            FileManager.default.createFile(atPath: statePath, contents: data)
        }
    }
}
