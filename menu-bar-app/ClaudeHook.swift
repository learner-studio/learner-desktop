import Foundation

// MARK: - Claude Code hook

/// Learner's live hook in every Claude Code session on this Mac.
///
/// Claude Code reads its hooks from ~/.claude/settings.json, and so does the Code tab of the
/// Claude desktop app (it runs the same Claude Code), so one user-level install covers both.
/// A chat in the Claude desktop app or on claude.ai runs no hooks at all: those reach
/// learner-server afterwards, through the chat archive (Vault, Archive).
///
/// The hook and its installer are learner-server's own code (`clients/hook`), run with bun
/// from the same checkout as the uploader. This job runs the installer, pointed at the
/// paired server and at the Keychain lookup for the device key (the key itself is never
/// passed, written or logged), and then the installer's `--check`, which asks the server
/// with that key. It runs at launch and every few hours, so a settings file that lost the
/// hook, or a server that moved, is put right without anyone noticing.
final class ClaudeHook: Sendable {
    struct Config: Sendable {
        var jobName = "ClaudeHook"
        var period: TimeInterval = 6 * 3600
        var firstRun: TimeInterval = 20
        /// The learner-server checkout (the uploader's).
        var repo = CLISessions.repo
        var bun = NSHomeDirectory() + "/.bun/bin/bun"
        var git = "/usr/bin/git"
        var serverURL: @Sendable () -> String = { LearnerAPI.baseURL }
        var clientId: @Sendable () -> String = { LearnerAPI.clientId }
        /// Whether this Mac holds a device key; unpaired, there is nothing to wire yet.
        var paired: @Sendable () -> Bool = { LearnerRPC.shared.key() != nil }
        /// Added to the installer's environment (tests: a scratch ~/.claude).
        var environment: [String: String] = [:]
        var timeout: TimeInterval = 60
        /// A checkout from before the installer existed is brought up to date once
        /// (fast-forward only, and only when it has no local changes).
        var updateCheckout = true
    }

    /// The installer's `--check` report.
    struct Check: Equatable {
        var ok = false
        var installed = false
        var permissions = false
        var config = "missing"
        var server = "unreachable"
        var catalogParts = 0
        var catalogPartsNeeded: Int?
    }

    static let shared = ClaudeHook()
    /// The most catalog companions the installer accepts.
    static let maxCatalogParts = 12

    let config: Config
    // nonisolated(unsafe): assigned once at the end of init (its body needs `self`); only read after.
    nonisolated(unsafe) private(set) var job: Job!
    private let log = Log("ClaudeHook")

    init(config: Config = Config()) {
        self.config = config
        job = Job(config.jobName, period: config.period, firstRun: config.firstRun, backoff: Backoff(base: 300, max: 3600),
                  problemGrace: 900) { [weak self] _ in self?.runOnce() ?? .idle }
    }

    var installer: String { config.repo + "/clients/hook/src/install.ts" }

    /// How the hook reads the device key: the same Keychain lookup the app uses.
    static func keyCommand(clientId: String) -> [String] {
        ["/usr/bin/security", "find-generic-password", "-s", Pairing.keychainService, "-a", clientId, "-w"]
    }

    /// The installer's arguments. They name how to read the key, never the key.
    static func installArguments(installer: String, bun: String, serverURL: String, clientId: String, catalogParts: Int? = nil) -> [String] {
        let command = (try? JSONSerialization.data(withJSONObject: keyCommand(clientId: clientId), options: [.withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        return [installer, "--bun", bun, "--server-url", serverURL, "--key-command-json", command]
            + (catalogParts.map { ["--catalog-parts", String($0)] } ?? [])
    }

    /// The report: the last line of output that is a JSON object (bun may print before it).
    static func parseCheck(_ output: String) -> Check? {
        for line in output.split(separator: "\n").reversed() {
            guard let j = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], j["ok"] is Bool else { continue }
            return Check(ok: j["ok"] as? Bool ?? false, installed: j["installed"] as? Bool ?? false,
                         permissions: j["permissions"] as? Bool ?? false, config: j["config"] as? String ?? "missing",
                         server: j["server"] as? String ?? "unreachable", catalogParts: j["catalogParts"] as? Int ?? 0,
                         catalogPartsNeeded: j["catalogPartsNeeded"] as? Int)
        }
        return nil
    }

    /// What a check means for the tray. Refused or keyless needs the owner (blocked); the
    /// rest is retried.
    static func outcome(_ check: Check?) -> Job.Outcome {
        guard let c = check else { return .failed("the hook check printed no report") }
        if c.ok { return .ok("wired into Claude Code (\(c.catalogParts) catalog parts)") }
        if c.server == "no credential" { return .blocked("the Claude Code hook cannot read the device key (Keychain \(Pairing.keychainService))") }
        if c.server.hasPrefix("refused") {
            return .blocked("learner-server refused the device key for the Claude Code hook (\(c.server)); the server may be older than this app")
        }
        if c.server != "ok" { return .failed("the Claude Code hook cannot reach learner-server (\(c.server))") }
        if !c.installed || !c.permissions { return .failed("the hook is not fully wired in ~/.claude/settings.json") }
        if c.config != "ok" { return .failed("the hook's config (~/.claude/learning-hook.json) is \(c.config)") }
        return .failed("the hook carries \(c.catalogParts) catalog parts; the server needs \(c.catalogPartsNeeded.map(String.init) ?? "more")")
    }

    /// The last line a program printed, short enough for a tray tooltip.
    static func lastLine(_ r: ChildProcess.Result) -> String {
        if let why = r.stopped { return why }
        let line = r.output.split(separator: "\n").last.map(String.init) ?? "exit \(r.status.map(String.init) ?? "?")"
        return String(line.prefix(200))
    }

    private var environment: [String: String] { ChildProcess.toolEnvironment.merging(config.environment) { _, new in new } }

    private func install(catalogParts: Int? = nil) -> ChildProcess.Result {
        ChildProcess.run(config.bun, Self.installArguments(installer: installer, bun: config.bun, serverURL: config.serverURL(),
                                                           clientId: config.clientId(), catalogParts: catalogParts),
                         timeout: config.timeout, env: environment, stderr: true)
    }

    private func check() -> Check? {
        Self.parseCheck(ChildProcess.run(config.bun, [installer, "--check"], timeout: config.timeout, env: environment).output)
    }

    /// Brings a checkout without the installer up to date. nil when the installer is there
    /// afterwards, else why not.
    private func update() -> String? {
        let status = ChildProcess.run(config.git, ["-C", config.repo, "status", "--porcelain", "--untracked-files=no"], timeout: 30, env: environment)
        guard status.ok else { return "git status failed" }
        guard status.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "it has local changes" }
        let pull = ChildProcess.run(config.git, ["-C", config.repo, "pull", "--ff-only"], timeout: 180, env: environment, stderr: true)
        guard pull.ok else { return "git pull --ff-only failed: \(Self.lastLine(pull))" }
        let deps = ChildProcess.run(config.bun, ["install", "--cwd", config.repo, "--frozen-lockfile"], timeout: 600, env: environment, stderr: true)
        guard deps.ok else { return "bun install failed: \(Self.lastLine(deps))" }
        guard FileManager.default.fileExists(atPath: installer) else { return "its newest commit has no installer" }
        log.info("updated the learner-server checkout to get the hook installer")
        return nil
    }

    func runOnce() -> Job.Outcome {
        let fm = FileManager.default
        // No checkout or no bun: the uploader already says so; nothing to add here.
        guard fm.fileExists(atPath: config.repo + "/clients"), fm.isExecutableFile(atPath: config.bun) else {
            return idleOrRecovered(job, "no learner-server checkout on this Mac")
        }
        guard config.paired() else { return idleOrRecovered(job, "not paired yet") }
        if !fm.fileExists(atPath: installer) {
            guard config.updateCheckout else { return .blocked("the learner-server checkout (\(config.repo)) has no hook installer; update it with git pull") }
            if let why = update() { return .blocked("the learner-server checkout (\(config.repo)) has no hook installer and was not updated: \(why)") }
        }
        let first = install()
        guard first.ok else { return .failed("the hook installer failed: \(Self.lastLine(first))") }
        var report = check()
        // The server's catalog outgrew the companions that carry it: install as many as it needs.
        if let c = report, !c.ok, c.server == "ok", let needed = c.catalogPartsNeeded, needed > c.catalogParts, needed <= Self.maxCatalogParts {
            let again = install(catalogParts: needed)
            guard again.ok else { return .failed("the hook installer failed: \(Self.lastLine(again))") }
            report = check()
        }
        return Self.outcome(report)
    }
}
