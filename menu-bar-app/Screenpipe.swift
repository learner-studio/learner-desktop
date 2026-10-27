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
/// When the installed version changes (and has held still for `settleSeconds`), the
/// "UpdateCheck" job starts a fresh headless Claude Code session that follows
/// docs/screenpipe-update-runbook.md under the permissions in
/// config/screenpipe-update-agent.json, bounded by ChildProcess (30 min, then SIGTERM and
/// SIGKILL), and logs the run: a transcript, a report and a line in index.log.
final class ScreenpipeUpdateCheck {
    struct Config {
        var jobName = "UpdateCheck"
        /// How often the installed version is read.
        var period: TimeInterval = 60
        var firstRun: TimeInterval = 30
        /// An update swaps the app bundle first, the engine only after a relaunch, and may then
        /// spend minutes converting storage. Act once the version has held still this long.
        var settleSeconds: TimeInterval = 600
        var timeout: TimeInterval = 1800
        var killGrace: TimeInterval = 10
        /// Ceiling on what one unattended run may spend.
        var maxBudgetUSD = "5"
        var projectDir = "/Users/benpollack/code/learner-desktop"
        var claudePath = NSHomeDirectory() + "/.local/bin/claude"
        var statePath = Paths.data + "/screenpipe-update-check.json"
        /// Optional long-lived token from `claude setup-token`, saved by the owner (chmod 600).
        var tokenPath = Paths.data + "/claude-oauth-token"
        var logDir = Paths.logs + "/screenpipe-update-checks"
        /// Transcripts and reports kept (oldest removed first).
        var keepRuns = 30
        var installedVersion: () -> String? = ScreenpipeUpdateCheck.installedAppVersion
        /// In every run's command line: finds a run orphaned by a crash of this app.
        var orphanMarker = "docs/screenpipe-update-runbook.md"
    }

    enum Decision: Equatable {
        /// First sighting since this was installed: remembered, not a run.
        case baseline(String)
        /// Changed, waiting for it to settle.
        case waiting(String)
        case run(reason: String)
        case nothing
    }

    static let shared = ScreenpipeUpdateCheck()

    let config: Config
    private(set) var job: Job!
    private let log = Log("UpdateCheck")
    private let lock = NSLock()
    private var pending: (version: String, since: Date)?
    private var manualReason: String?
    private var current: Process?
    private var orphansChecked = false

    init(config: Config = Config()) {
        self.config = config
        job = Job(config.jobName, period: config.period, firstRun: config.firstRun,
                  backoff: Backoff(base: 600, max: 6 * 3600), quiet: true) { [weak self] _ in self?.runOnce() ?? .idle }
    }

    var logDir: String { config.logDir }
    var isRunning: Bool { lock.withLock { current != nil || manualReason != nil } }
    private var indexPath: String { config.logDir + "/index.log" }

    static func installedAppVersion() -> String? {
        let plist = URL(fileURLWithPath: "/Applications/screenpipe.app/Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    /// The most recent line of the run index, for the menu.
    var lastRunSummary: String? {
        for path in [indexPath, indexPath.replacingOccurrences(of: ".log", with: ".1.log")] {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            if let last = text.split(separator: "\n").last { return String(last.prefix(60)) }
        }
        return nil
    }

    /// The tray's poll used to drive this; the job reads the version itself now. A tick
    /// that is not due does nothing.
    func observe(appVersion: String) { job.tick() }

    /// "Run screenpipe Update Check Now".
    func start(reason: String) {
        lock.withLock { manualReason = reason }
        job.kick("requested from the menu")
    }

    /// On quit: a session left running would outlive the app.
    func stopForQuit() {
        if let p = lock.withLock({ current }), p.isRunning {
            log.info("stopping the running check for quit")
            ChildProcess.stop(p, grace: 0)
        }
    }

    /// Whether `version` calls for a run. Remembers the version it acts on (once per
    /// version, even if the run fails: a rerun is one menu click away).
    func decide(version: String?, now: Date = Date()) -> Decision {
        guard let version = version else { return .nothing }
        guard let handled = handledVersion() else {
            saveHandled(version)
            return .baseline(version)
        }
        guard version != handled else {
            lock.withLock { pending = nil }
            return .nothing
        }
        let since: Date = lock.withLock {
            if pending?.version != version {
                pending = (version, now)
                log.info("screenpipe \(handled) -> \(version); checking once it has settled")
            }
            return pending?.since ?? now
        }
        guard now.timeIntervalSince(since) >= config.settleSeconds else { return .waiting(version) }
        lock.withLock { pending = nil }
        saveHandled(version)
        return .run(reason: "screenpipe updated from \(handled) to \(version)")
    }

    /// The job body.
    func runOnce() -> Job.Outcome {
        if !lock.withLock({ orphansChecked }) {
            ChildProcess.killOrphans(matching: config.orphanMarker, log: log)
            lock.withLock { orphansChecked = true }
        }
        let manual: String? = lock.withLock {
            defer { manualReason = nil }
            return manualReason
        }
        if let reason = manual { return run(reason: reason) }
        switch decide(version: config.installedVersion()) {
        case let .run(reason): return run(reason: reason)
        case let .baseline(v):
            log.info("screenpipe \(v) noted as the baseline")
            return .idle
        case .waiting, .nothing: return .idle
        }
    }

    /// One headless Claude Code session, bounded, logged.
    func run(reason: String) -> Job.Outcome {
        let fm = FileManager.default
        do { try fm.createDirectory(atPath: config.logDir, withIntermediateDirectories: true) } catch {
            log.error("cannot create \(config.logDir): \(error.localizedDescription)")
            return .failed("cannot create the log folder")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        let stamp = formatter.string(from: Date())
        let transcript = "\(config.logDir)/\(stamp).jsonl"

        var env = ChildProcess.toolEnvironment
        // An interactive `claude auth login` sits in a keychain slot keyed by $USER (a shell
        // without USER saves it elsewhere) and can expire between updates. A long-lived
        // token, when saved, keeps unattended runs from depending on either. Tokens contain
        // no whitespace; a copy across a terminal line wrap adds some.
        if fm.fileExists(atPath: config.tokenPath) {
            do {
                let token = try String(contentsOfFile: config.tokenPath, encoding: .utf8)
                    .components(separatedBy: .whitespacesAndNewlines).joined()
                if !token.isEmpty { env["CLAUDE_CODE_OAUTH_TOKEN"] = token }
            } catch {
                log.warn("cannot read the saved Claude token file: \(error.localizedDescription)")
            }
        }
        let args = [
            "-p", "\(reason) (detected by Learner Desktop). Follow docs/screenpipe-update-runbook.md "
                + "in this repository exactly and end with the report it describes.",
            "--output-format", "stream-json", "--verbose",
            "--settings", config.projectDir + "/config/screenpipe-update-agent.json",
            "--max-budget-usd", config.maxBudgetUSD,
        ]
        log.info("starting a Claude Code session: \(reason). Transcript: \(transcript)")
        // ChildProcess has no working directory: sh changes into the project and execs claude.
        let r = ChildProcess.run("/bin/sh", ["-c", "cd \"$0\" && exec \"$@\"", config.projectDir, config.claudePath] + args,
                                 timeout: config.timeout, env: env, stderr: true, logFile: transcript, grace: config.killGrace,
                                 onStart: { [weak self] p in self?.lock.withLock { self?.current = p } })
        lock.withLock { current = nil }
        let outcome = finished(r, stamp: stamp, reason: reason)
        prune()
        return outcome
    }

    private func finished(_ r: ChildProcess.Result, stamp: String, reason: String) -> Job.Outcome {
        // stream-json ends with one "result" event carrying the report, cost and session id.
        let events = r.output.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let result = events.last { $0["type"] as? String == "result" }
        let session = (result?["session_id"] ?? events.first?["session_id"]) as? String ?? "unknown"
        let cost = (result?["total_cost_usd"] as? NSNumber).map { String(format: "$%.2f", $0.doubleValue) } ?? "$?"
        let exit = r.stopped ?? "exit \(r.status.map(String.init) ?? "?")"
        let report = result?["result"] as? String ?? "No report: claude \(exit)."
        let reportPath = "\(config.logDir)/\(stamp).md"
        do {
            try "# \(reason)\n\nSession: \(session) (`claude --resume \(session)` from the project folder)\nCost: \(cost)\n\n\(report)\n"
                .write(toFile: reportPath, atomically: true, encoding: .utf8)
        } catch {
            log.error("cannot write \(reportPath): \(error.localizedDescription)")
        }
        let reportLines = report.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let status: String
        if let stopped = r.stopped {
            status = "STATUS: RUN FAILED (\(stopped))"
        } else if result?["is_error"] as? Bool == true {
            // e.g. "Failed to authenticate: OAuth session expired and could not be refreshed"
            status = "STATUS: RUN FAILED (\((reportLines.first ?? "").prefix(100)))"
        } else {
            // Asked to lead with it, but a session may open with a one-line summary first.
            status = reportLines.first(where: { $0.hasPrefix("STATUS:") }) ?? "STATUS: NO REPORT"
        }
        LogFile.append(indexPath, "\(stamp)  \(status)  session \(session)  \(cost)  \(reason)\n")
        log.info("finished (\(exit)): \(status), session \(session), \(cost). Report: \(reportPath)")
        if status.hasPrefix("STATUS: RUN FAILED") || status == "STATUS: NO REPORT" { return .failed(status) }
        return .ok(status)
    }

    /// Keeps the newest `keepRuns` transcripts and reports.
    private func prune() {
        let fm = FileManager.default
        let names: [String]
        do { names = try fm.contentsOfDirectory(atPath: config.logDir) } catch {
            log.warn("cannot list \(config.logDir): \(error.localizedDescription)")
            return
        }
        let stamps = Set(names.filter { $0.hasSuffix(".jsonl") || $0.hasSuffix(".md") }
            .map { ($0 as NSString).deletingPathExtension }).sorted()
        for old in stamps.dropLast(config.keepRuns) {
            for ext in ["jsonl", "md"] where fm.fileExists(atPath: "\(config.logDir)/\(old).\(ext)") {
                do { try fm.removeItem(atPath: "\(config.logDir)/\(old).\(ext)") }
                catch { log.warn("cannot remove the old run \(old).\(ext): \(error.localizedDescription)") }
            }
        }
    }

    private func handledVersion() -> String? {
        guard let data = FileManager.default.contents(atPath: config.statePath) else { return nil }
        guard let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            log.warn("\(config.statePath) is unreadable; treating this version as the baseline")
            return nil
        }
        return state["handled_app_version"] as? String
    }

    private func saveHandled(_ version: String) {
        do {
            let data = try JSONSerialization.data(withJSONObject: ["handled_app_version": version])
            try data.write(to: URL(fileURLWithPath: config.statePath), options: .atomic)
        } catch {
            log.error("cannot save \(config.statePath): \(error.localizedDescription)")
        }
    }
}
