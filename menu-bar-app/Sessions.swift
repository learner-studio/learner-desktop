import AppKit
import Foundation
import ServiceManagement
import SQLite3
import CoreBluetooth
import CommonCrypto

// MARK: - CLI sessions (Codex, Claude Code)

/// Codex and Claude Code sessions reach learner-server through learner-server's own
/// uploader (`clients/uploader`, run with bun), the same code on every machine. Two setups:
///
/// - learner-server runs on this Mac: it reads ~/.codex/sessions and ~/.claude/projects
///   itself, and the app runs nothing (Settings → "learner-server runs on this Mac").
/// - learner-server runs elsewhere (today): the app runs the uploader as a helper
///   (`--watch`), with the device key in its environment from the Keychain, never on disk,
///   and shows its health from the uploader's own status.json.
enum CLISessions {
    static let log = Log("Sessions")
    static let defaultsKey = "learner_server_on_this_mac"
    static let interval: TimeInterval = 30
    private static let env = ProcessInfo.processInfo.environment

    /// Where learner-server is checked out (LEARNER_SERVER_REPO overrides).
    static let repo = env["LEARNER_SERVER_REPO"] ?? NSHomeDirectory() + "/code/learner-server"
    static var entry: String { repo + "/clients/uploader/src/index.ts" }
    /// The uploader's state folder (its own LEARNER_UPLOAD_STATE_DIR, else ~/.learner/uploader).
    static let stateDir = env["LEARNER_UPLOAD_STATE_DIR"] ?? NSHomeDirectory() + "/.learner/uploader"
    static var statusPath: String { stateDir + "/status.json" }

    static var serverOnThisMac: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
            log.info("learner-server runs on this Mac: \(newValue) (the uploader \(newValue ? "is not needed" : "runs here"))")
        }
    }

    /// The uploader's exit codes (clients/uploader): 2 = its config is incomplete, 3 = another
    /// uploader already holds the lock (a manual run, say): not a fault, check again later.
    static let exitRules: [Int32: ManagedHelper.ExitRule] = [
        2: .init(note: "uploader config error (serverUrl, clientId or key missing)", wait: 300, isProblem: true),
        3: .init(note: "another uploader is already running", wait: 300, isProblem: false),
    ]

    /// The uploader helper, or nil when learner-server runs on this Mac.
    static func helper(key: @escaping @Sendable () -> String?) -> ManagedHelper? {
        guard !serverOnThisMac else { return nil }
        return ManagedHelper(
            name: "uploader", executable: NSHomeDirectory() + "/.bun/bin/bun",
            arguments: [entry, "--watch", "--interval", String(Int(interval))],
            marker: "clients/uploader/src/index.ts",
            environment: {
                var e = ["LEARNER_URL": LearnerAPI.baseURL, "LEARNER_CLIENT_ID": LearnerAPI.clientId]
                if let k = key() { e["LEARNER_API_KEY"] = k } else { log.warn("no device key in the Keychain; the uploader will report a config error") }
                return e
            },
            minRestart: 30, exitRules: exitRules)
    }

    // MARK: Status

    /// The uploader's status.json (learner-server clients/uploader, version 1).
    struct Status {
        var state: String
        var pid: Int32?
        var lastSuccessAt: Date?
        var nextRunAt: Date?
        var files = 0
        var pendingFiles = 0
        var pendingBytes = 0
        var diverged = 0
        var failed = 0
        var lastError: String?
    }

    static func readStatus(_ path: String = statusPath) -> Status? {
        guard let data = FileManager.default.contents(atPath: path),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let date = { (k: String) in (j[k] as? String).flatMap { iso.date(from: $0) ?? plain.date(from: $0) } }
        return Status(state: j["state"] as? String ?? "unknown", pid: (j["pid"] as? NSNumber).map { $0.int32Value },
                      lastSuccessAt: date("lastSuccessAt"), nextRunAt: date("nextRunAt"),
                      files: j["files"] as? Int ?? 0, pendingFiles: j["pendingFiles"] as? Int ?? 0,
                      pendingBytes: j["pendingBytes"] as? Int ?? 0, diverged: (j["diverged"] as? [Any])?.count ?? 0,
                      failed: (j["failed"] as? [Any])?.count ?? 0, lastError: j["lastError"] as? String)
    }

    /// Unhealthy (learner-server's rules): state auth-error or error, nextRunAt more than
    /// twice the interval in the past, or its pid not alive. Per-file divergences are listed
    /// in the menu, not outages.
    static func problem(_ s: Status?, now: Date = Date(), alive: (Int32) -> Bool = { kill($0, 0) == 0 }) -> String? {
        guard let s = s else { return "no status yet (not run)" }
        if s.state == "auth-error" { return "the server refused the device key" + (s.lastError.map { ": \($0)" } ?? "") }
        if s.state == "error" { return "error" + (s.lastError.map { ": \($0)" } ?? "") }
        if let pid = s.pid, !alive(pid) { return "not running (last pass \(s.lastSuccessAt.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? "never"))" }
        if let next = s.nextRunAt, now.timeIntervalSince(next) > 2 * interval { return "stalled: next pass was due \(Job.describe(now.timeIntervalSince(next))) ago" }
        return nil
    }

    /// The menu line.
    static func summary(_ s: Status?) -> String {
        guard let s = s else { return "not run yet" }
        var parts = ["\(s.files) files", s.state]
        if s.pendingFiles > 0 { parts.append("\(s.pendingFiles) pending (\(ByteCountFormatter.string(fromByteCount: Int64(s.pendingBytes), countStyle: .file)))") }
        if s.diverged > 0 { parts.append("\(s.diverged) diverged") }
        if s.failed > 0 { parts.append("\(s.failed) failed") }
        if let t = s.lastSuccessAt { parts.append("last \(DateFormatter.localizedString(from: t, dateStyle: .none, timeStyle: .short))") }
        return parts.joined(separator: " · ")
    }
}
