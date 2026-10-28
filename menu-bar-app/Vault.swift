import AppKit
import Foundation
import SQLite3
import CoreBluetooth
import CommonCrypto

// MARK: - AI Vault export

/// Pulls new ChatGPT and Claude conversations into ~/ai-vault-data with the `ai-vault`
/// CLI (the "Export" job: 2 min after launch, then hourly), fills in the ChatGPT voice
/// transcripts ai-vault leaves out (VoiceTranscripts), then kicks the Archive job, which
/// sends what changed to learner-server.
///
/// ai-vault exits 0 even when it failed, so each run's output is read:
///   expired login            that provider is skipped until Sign In Again (VaultSignIn)
///                            or ai-vault's config changes; all expired -> blocked
///   "API request failed: 429" waiting (yellow, not a failure): the login works, the provider
///                            is throttling; retried in 30 min, doubling to 6 h while it lasts,
///                            and the voice step (the same ChatGPT API) is skipped meanwhile
///   stuck, crashed browser,  failed, retried after 15 min doubling to 2 h
///   "✗ Failed:", "Errors: N" (--only-new resumes where a run stopped, so nothing is lost)
///   ai-vault not installed   failed, said so
final class VaultExport: Sendable {
    struct Config: Sendable {
        var jobName = "Export"
        /// How often logins marked expired are tried again on their own.
        var blockedRecheck: TimeInterval = 6 * 3600
        var providers = ["claude", "chatgpt"]
        var cliPath: @Sendable () -> String? = VaultExport.installedCLI
        /// nil: ChildProcess.toolEnvironment (ai-vault's node under nvm on PATH).
        var env: [String: String]?
        var logPath = Paths.logs + "/vault-export.log"
        var loginsPath = Paths.data + "/vault-logins.json"
        var aiVaultConfig = Paths.aiVaultConfig
        var period: TimeInterval = 3600
        var firstRun: TimeInterval = 120
        /// A run that is still printing is left alone; one silent this long is stuck (ai-vault
        /// prints a line per conversation and waits at most ~30 s between them).
        var stallTimeout: TimeInterval = 10 * 60
        var maxRunTime: TimeInterval = 4 * 3600
        var killGrace: TimeInterval = 15
        var rateLimitRetry: TimeInterval = 30 * 60
        var rateLimitMax: TimeInterval = 6 * 3600
        var failureBackoff = Backoff(base: 15 * 60, max: 2 * 3600)
        /// A failing export reaches the tray once it has failed this long (a rate limit or
        /// one stuck run that the next retry gets past does not).
        var problemGrace: TimeInterval = 3600
        /// Left by a crash of this app (parented to launchd): would race the next export.
        var orphanMarkers = ["ai-vault backup", "learner-watcher.js voice-transcripts"]
        /// nil: no voice step.
        var voice: VoiceTranscripts? = VoiceTranscripts()
        /// After every run, finished or not: the archive sends what arrived.
        var afterRun: (@Sendable () -> Void)? = { Archive.shared.job.kick("after export") }
    }

    /// One provider's backup, read from ai-vault's output.
    enum ProviderResult: Equatable {
        case ok(archived: Int?)
        case loginExpired
        case rateLimited
        case failed(String)
    }

    static let loginExpiredPattern = "Authentication failed|cookies appear to be expired|Organization ID not available|API request failed: 40[13]"
    static let rateLimitPattern = "API request failed: 429"
    /// No network (the Mac asleep or offline). ai-vault then also prints "Authentication
    /// failed", which must not read as an expired login: it is checked first and retried.
    /// A page that did not load in time (`page.goto: Timeout 30000ms exceeded`) is the same:
    /// on 10-28 claude.ai was slow, ai-vault also printed "Authentication failed", and the
    /// login was marked expired, which skipped every later Claude export until a sign-in.
    static let offlinePattern = #"net::ERR_[A-Z_]+|ENOTFOUND|EAI_AGAIN|ETIMEDOUT|ECONNREFUSED|ECONNRESET|getaddrinfo|page\.goto: Timeout \d+ms exceeded"#
    static let failedPattern = "Errors: [1-9]|Completed with [1-9][0-9]* errors|✗ Failed:|browser has been closed"

    static let shared = VaultExport()

    let config: Config
    // nonisolated(unsafe): assigned once at the end of init (its body needs `self`); only read after.
    nonisolated(unsafe) private(set) var job: Job!
    private let log = Log("Export")
    private struct State {
        var current: Process?
        var quitting = false
        /// provider -> modification time of ai-vault's config when the login was found expired.
        var expired: [String: Double] = [:]
        /// step (a provider, or "voice") -> when its rate limit is over. Set only when the same
        /// run also failed for another reason: that failure retries on the normal backoff, and
        /// the retry leaves the throttled step alone until then.
        var held: [String: Date] = [:]
        var lastRunAt: Date?
        var summary = "not run yet"
        var onFinished: (@MainActor () -> Void)?
    }
    private let state: Locked<State>

    /// Main thread, after each run, so the tray refreshes without waiting for its poll.
    var onFinished: (@MainActor () -> Void)? {
        get { state.value.onFinished }
        set { state.withLock { $0.onFinished = newValue } }
    }

    init(config: Config = Config()) {
        self.config = config
        state = Locked(State(expired: VaultExport.loadLogins(config.loginsPath, log: log)))
        job = Job(config.jobName, period: config.period, firstRun: config.firstRun, backoff: config.failureBackoff,
                  problemGrace: config.problemGrace, blockedRecheck: config.blockedRecheck) { [weak self] _ in self?.runOnce() ?? .idle }
    }

    // MARK: Status for the menu

    /// Providers whose ai-vault login expired: the menu offers Sign In Again for each.
    var expiredLogins: Set<String> { Set(state.value.expired.keys) }
    var lastRun: Date? { state.value.lastRunAt }
    /// e.g. "claude: ok (3 new), chatgpt: login expired, voice: 2 updated (5 messages)".
    var lastSummary: String { state.value.summary }
    var isRunning: Bool { state.value.current != nil }

    // MARK: Triggers

    /// "Pull Latest Chats".
    func runNow() { job.kick("pull latest chats") }

    /// A fresh sign-in clears its error at once, rather than when the next export ends.
    func signedIn(_ provider: String) {
        state.withLock { _ = $0.expired.removeValue(forKey: provider) }
        saveLogins()
        notify()
        job.kick("signed in to \(provider)")
    }

    /// On quit: an export left running would outlive the app and race the next launch's.
    func stopForQuit() {
        let p: Process? = state.withLock {
            $0.quitting = true
            return $0.current
        }
        // Shutdown has seconds, not a grace period.
        if let p = p, p.isRunning {
            log.info("stopping the running export for quit")
            ChildProcess.stop(p, grace: 0)
        }
    }

    // MARK: Run

    /// The job body.
    func runOnce() -> Job.Outcome {
        state.withLock { $0.quitting = false }
        for marker in config.orphanMarkers { ChildProcess.killOrphans(matching: marker, log: log) }
        defer { config.afterRun?() }
        guard let cli = config.cliPath() else {
            return finish(["ai-vault CLI not found (install it under nvm: npm i -g ai-vault)"],
                          .failed("ai-vault CLI not found"))
        }
        var notes: [String] = []
        var failed: [String] = []
        var rateLimited: Set<String> = []
        var stillHeld: [String: Date] = [:]
        var ran = 0
        let now = Date()
        /// Whether `step` is still held off by an earlier rate limit (noted, then skipped).
        func heldOff(_ step: String) -> Bool {
            guard let until = state.value.held[step], until > now else { return false }
            stillHeld[step] = until
            notes.append("\(step): rate limited (trying again in \(Job.describe(until.timeIntervalSince(now))))")
            return true
        }
        let configStamp = VaultExport.modified(config.aiVaultConfig)
        // A run while blocked is the periodic re-check: try the expired logins again (a
        // block can be wrong, or fixed outside the app).
        let recheck = job.snapshot.blocked
        if recheck { log.info("re-checking logins marked expired: \(expiredLogins.sorted().joined(separator: ", "))") }
        for provider in config.providers {
            if state.value.quitting { break }
            if !recheck, let stamp = state.value.expired[provider], stamp == configStamp {
                notes.append("\(provider): login expired")
                continue
            }
            if heldOff(provider) { continue }
            ran += 1
            switch backup(cli, provider) {
            case let .ok(archived):
                state.withLock { _ = $0.expired.removeValue(forKey: provider); _ = $0.held.removeValue(forKey: provider) }
                notes.append("\(provider): ok" + (archived.map { $0 > 0 ? " (\($0) new)" : "" } ?? ""))
            case .loginExpired:
                state.withLock { $0.expired[provider] = configStamp }
                notes.append("\(provider): login expired")
            case .rateLimited:
                // A 429 comes after "✓ Authenticated": the login works.
                state.withLock { _ = $0.expired.removeValue(forKey: provider) }
                rateLimited.insert(provider)
                notes.append("\(provider): rate limited")
            case let .failed(why):
                failed.append(provider)
                notes.append("\(provider): \(why)")
            }
        }
        saveLogins()

        // ai-vault drops ChatGPT voice transcripts; write them back in. Not while ChatGPT is
        // throttling: the voice step calls the same API, and would only extend the limit.
        if let voice = config.voice, !rateLimited.contains("chatgpt"), stillHeld["chatgpt"] == nil,
           !state.withLock({ $0.quitting || $0.expired["chatgpt"] != nil }), !heldOff("voice") {
            let v = voice.run(cancelled: { [state] in state.value.quitting })
            switch v.stopped {
            case .rateLimited?: rateLimited.insert("voice")
            case .loginExpired?:
                state.withLock { $0.expired["chatgpt"] = configStamp }
                saveLogins()
            case .unreachable?: failed.append("voice")
            case nil: state.withLock { _ = $0.held.removeValue(forKey: "voice") }
            }
            if v.candidates > 0 || v.stopped != nil { notes.append("voice: \(v.describe)") }
        }

        // Interrupted by quit: not a failure. Leave the saved schedule alone, so the next
        // launch resumes within minutes instead of waiting out a backoff.
        if state.value.quitting {
            log.info("export interrupted by quit; it resumes at the next launch")
            return finish(notes + ["stopped for quit"], .idle)
        }
        let expired = state.value.expired
        let allExpired = config.providers.allSatisfy { expired[$0] != nil }
        if allExpired {
            return finish(notes, .blocked("ai-vault login expired (\(config.providers.joined(separator: ", "))): Sign In Again"))
        }
        // Back to back limits wait longer each time: 30 min, 1 h, 2 h … up to 6 h.
        let streak = job.snapshot.waitingSince == nil ? 0 : job.snapshot.failures
        let wait = min(config.rateLimitRetry * pow(2, Double(min(streak, 10))), config.rateLimitMax)
        if !failed.isEmpty {
            // A crash or an outage is retried on the normal backoff (minutes), not held for a
            // rate limit's hours (10-28: a ChatGPT browser crash alongside voice's 429 waited
            // 6 h and went red); the throttled steps sit that retry out.
            state.withLock { s in for step in rateLimited { s.held[step] = now.addingTimeInterval(wait) } }
            return finish(notes, .failed(notes.joined(separator: ", ")))
        }
        state.withLock { s in for step in rateLimited { s.held[step] = nil } }
        if !rateLimited.isEmpty {
            let text = notes.joined(separator: ", ")
            return finish(notes + ["trying again in \(Job.describe(wait))"], .waiting(text, retryAfter: wait))
        }
        if let until = stillHeld.values.min() {
            // Everything else went through; only a held step is left.
            let left = max(60, until.timeIntervalSince(now))
            return finish(notes, .waiting(notes.joined(separator: ", "), retryAfter: left))
        }
        return finish(notes, .ok(notes.joined(separator: ", ")))
    }

    private func finish(_ notes: [String], _ outcome: Job.Outcome) -> Job.Outcome {
        let text = notes.joined(separator: ", ")
        state.withLock {
            $0.summary = text
            $0.lastRunAt = Date()
        }
        notify()
        return outcome
    }

    private func notify() {
        guard let done = onFinished else { return }
        DispatchQueue.main.async { done() }
    }

    /// `ai-vault backup <provider> --only-new`, streamed to vault-export.log, bounded by the
    /// stall watchdog and the run limit, and stoppable at quit.
    func backup(_ cli: String, _ provider: String) -> ProviderResult {
        var args = ["backup", provider, "--only-new", "--skip-media", "-y"]
        if provider == "chatgpt" { args.append("--random-delay") }
        let r = ChildProcess.run(cli, args, timeout: config.maxRunTime, stallTimeout: config.stallTimeout,
                                 env: config.env ?? ChildProcess.toolEnvironment, stderr: true, logFile: config.logPath,
                                 grace: config.killGrace,
                                 onStart: { [state] p in state.withLock { $0.current = p } })
        state.withLock { $0.current = nil }
        let result = VaultExport.classify(status: r.status, stopped: r.stopped, output: r.output)
        switch result {
        case .ok: break
        case .loginExpired: log.warn("\(provider): login expired")
        case .rateLimited: log.warn("\(provider): rate limited (429)")
        case let .failed(why): log.warn("\(provider): \(why)")
        }
        return result
    }

    /// What one ai-vault run's output means. ai-vault exits 0 even when its summary lists
    /// errors, so the output decides; the exit status only when the output says nothing.
    static func classify(status: Int32?, stopped: String?, output: String) -> ProviderResult {
        func has(_ pattern: String) -> Bool { output.range(of: pattern, options: .regularExpression) != nil }
        if has(offlinePattern) { return .failed("offline (\(output.range(of: offlinePattern, options: .regularExpression).map { String(output[$0]) } ?? "network"))") }
        if has(loginExpiredPattern) { return .loginExpired }
        if output.contains(rateLimitPattern) { return .rateLimited }
        if let why = stopped {
            return .failed(why.hasPrefix("could not start") ? "ai-vault \(why)" : "stuck, stopped (\(why))")
        }
        if output.contains("browser has been closed") { return .failed("browser crashed (see vault-export.log)") }
        if has(failedPattern) { return .failed("failed (see vault-export.log)") }
        if let s = status, s != 0 { return .failed("exit \(s) (see vault-export.log)") }
        let archived = output.range(of: #"Archived: ([0-9]+)"#, options: .regularExpression)
            .flatMap { Int(output[$0].dropFirst("Archived: ".count)) }
        return .ok(archived: archived)
    }

    // MARK: Helpers

    /// ai-vault is installed under nvm; the newest node version that has it.
    static func installedCLI() -> String? {
        let root = NSHomeDirectory() + "/.nvm/versions/node"
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted().reversed()
        return versions.map { "\(root)/\($0)/bin/ai-vault" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Kept for VaultSignIn.
    static func cliPath() -> String? { installedCLI() }

    static func modified(_ path: String) -> Double {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    }

    private static func loadLogins(_ path: String, log: Log) -> [String: Double] {
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        guard let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Double] else {
            log.warn("\(path) is unreadable; ignoring it")
            return [:]
        }
        return saved
    }

    private func saveLogins() {
        let snapshot = state.value.expired
        do {
            let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: config.loginsPath), options: .atomic)
        } catch {
            log.warn("cannot save \(config.loginsPath): \(error.localizedDescription)")
        }
    }
}

// MARK: - AI Vault sign-in

/// Signs ai-vault back in from your own browser (Settings → Sign AI Vault In From; Brave by
/// default), where 1Password and passkeys work; an embedded web view gets neither. The
/// provider's cookies are read from that browser's cookie store and handed to
/// `ai-vault setup <provider> --cookies-file` (a 0600 file, deleted straight after).
/// If the browser already holds a new session, nothing opens. Otherwise the sign-in page
/// opens there and the cookie store is watched until a new session appears.
@MainActor
final class VaultSignIn {
    struct Site { let url: String; let domain: String; let session: [String] }

    nonisolated static let sites: [String: Site] = [
        "chatgpt": Site(url: "https://chatgpt.com/auth/login", domain: "chatgpt.com",
                        session: ["__Secure-next-auth.session-token", "__Secure-next-auth.session-token.0"]),
        "claude": Site(url: "https://claude.ai/login", domain: "claude.ai", session: ["sessionKey"]),
    ]
    static let pollInterval: TimeInterval = 3
    static let waitLimit: TimeInterval = 10 * 60
    private static var active: [String: VaultSignIn] = [:]
    nonisolated private static let log = Log("SignIn")

    static func isWaiting(_ provider: String) -> Bool { active[provider]?.openedBrowser == true }

    static func start(_ provider: String) {
        guard active[provider] == nil, let site = sites[provider] else { return }
        let s = VaultSignIn(provider: provider, site: site)
        active[provider] = s
        log.info("\(provider): checking \(s.browser.name)'s session")
        s.check()
    }

    private let provider: String
    private let site: Site
    private let browser = ChromiumBrowser.selected
    private let deadline = Date().addingTimeInterval(VaultSignIn.waitLimit)
    private var triedSession: String?
    private var openedBrowser = false
    private var busy = false
    private var timer: Timer?

    private init(provider: String, site: Site) {
        self.provider = provider
        self.site = site
        // ai-vault saves whatever it is given, so the session it already has (the one that
        // expired) counts as tried; the browser then has to come up with a new one.
        triedSession = VaultSignIn.savedSession(provider, site: site)
    }

    private static func savedSession(_ provider: String, site: Site) -> String? {
        guard let data = FileManager.default.contents(atPath: Paths.aiVaultConfig) else { return nil }
        guard let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            log.warn("~/.ai-vault/config.json is not JSON")
            return nil
        }
        guard
              let providers = config["providers"] as? [String: Any],
              let entry = providers[provider] as? [String: Any],
              let cookies = entry["cookies"] as? [String: Any] else { return nil }
        return site.session.lazy.compactMap { cookies[$0] as? String }.first
    }

    private func check() {
        guard !busy else { return }
        busy = true
        let (provider, site, tried, browser) = (self.provider, self.site, triedSession, self.browser)
        DispatchQueue.global(qos: .userInitiated).async {
            let cookies = BrowserCookies.read(browser, domain: site.domain)
            let session = site.session.lazy.compactMap { cookies[$0] }.first
            // Try each session value once; a refused one is not retried until it changes.
            let result = session.flatMap { $0 == tried ? nil : VaultSignIn.runSetup(provider, cookies: cookies) }
            DispatchQueue.main.async { self.checked(session: session, result: result) }
        }
    }

    private func checked(session: String?, result: (ok: Bool, detail: String)?) {
        busy = false
        if let session = session { triedSession = session }
        if let result = result, result.ok {
            VaultSignIn.log.info("\(provider): ai-vault accepted \(browser.name)'s session; exporting")
            stop()
            VaultExport.shared.signedIn(provider)
            return
        }
        if let result = result { VaultSignIn.log.warn("\(provider): ai-vault setup failed: \(result.detail)") }
        if Date() > deadline {
            VaultSignIn.log.warn("\(provider): no new session in \(browser.name) after \(Int(VaultSignIn.waitLimit / 60)) min; stopped watching")
            stop()
            return
        }
        guard !openedBrowser else { return }
        openedBrowser = true
        browser.open(site.url)
        VaultSignIn.log.info("\(provider): opened the sign-in page in \(browser.name)")
        timer = Timer.scheduledTimer(withTimeInterval: VaultSignIn.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        VaultSignIn.active[provider] = nil
    }

    /// `ai-vault setup <provider> --cookies-file <0600 file>`; the file is removed afterwards.
    nonisolated static func runSetup(_ provider: String, cookies: [String: String]) -> (ok: Bool, detail: String) {
        guard sites[provider] != nil, let cli = VaultExport.cliPath() else { return (false, "ai-vault CLI not found") }
        let path = Paths.data + "/ai-vault-cookies-\(provider).json"
        guard let data = try? JSONSerialization.data(withJSONObject: cookies),
              FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            log.error("\(provider): could not write the cookies file \(path)")
            return (false, "could not write the cookies file")
        }
        defer {
            do { try FileManager.default.removeItem(atPath: path) }
            catch { log.error("could not remove \(path): \(error.localizedDescription)") }
        }
        let r = ChildProcess.run(cli, ["setup", provider, "--cookies-file", path], timeout: 90, env: ChildProcess.toolEnvironment, stderr: true)
        guard let status = r.status else { return (false, "ai-vault setup did not finish in 90 s") }
        let ok = status == 0 && r.output.contains("Configuration saved")
        let last = r.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
        return (ok, ok ? "ok" : String((last ?? "exit \(status)").prefix(160)))
    }
}

/// A Chromium browser whose cookie store VaultSignIn can read. Brave and Chrome share the
/// store format and differ only in where it lives and which Keychain item holds its key.
struct ChromiumBrowser {
    let id: String
    let name: String
    let bundleId: String
    let dataDir: String
    let keychainService: String
    let keychainAccount: String

    static let all = [
        ChromiumBrowser(id: "brave", name: "Brave", bundleId: "com.brave.Browser",
                        dataDir: "BraveSoftware/Brave-Browser", keychainService: "Brave Safe Storage", keychainAccount: "Brave"),
        ChromiumBrowser(id: "chrome", name: "Chrome", bundleId: "com.google.Chrome",
                        dataDir: "Google/Chrome", keychainService: "Chrome Safe Storage", keychainAccount: "Chrome"),
    ]
    static let defaultsKey = "vault_sign_in_browser"

    static var selected: ChromiumBrowser {
        get { all.first { $0.id == UserDefaults.standard.string(forKey: defaultsKey) } ?? all[0] }
        set { UserDefaults.standard.set(newValue.id, forKey: defaultsKey) }
    }

    func open(_ url: String) {
        guard let url = URL(string: url) else { return }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            NSWorkspace.shared.open(url)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config)
    }
}

/// Reads one site's cookies from a Chromium browser's on-disk store. Values are AES-128-CBC
/// encrypted with a key derived from the browser's "… Safe Storage" Keychain item; macOS
/// asks once for access (choose Always Allow). Store version 24 and later prefix each
/// plaintext with a 32-byte SHA-256 of the host. Of all profiles, the one whose cookies
/// were used last wins.
enum BrowserCookies {
    private static let keys = Locked<[String: [UInt8]]>([:])

    static func read(_ browser: ChromiumBrowser, domain: String) -> [String: String] {
        let root = NSHomeDirectory() + "/Library/Application Support/" + browser.dataDir
        let profiles = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [])
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
        var best: (lastUsed: Int64, cookies: [String: String]) = (0, [:])
        for profile in profiles {
            let found = read(db: "\(root)/\(profile)/Cookies", domain: domain, browser: browser)
            if found.lastUsed > best.lastUsed { best = found }
        }
        return best.cookies
    }

    private static func read(db path: String, domain: String, browser: ChromiumBrowser) -> (lastUsed: Int64, cookies: [String: String]) {
        guard FileManager.default.fileExists(atPath: path) else { return (0, [:]) }
        var db: OpaquePointer?
        // immutable: the browser holds the store open; read it without taking a lock.
        let uri = "file:" + path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! + "?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return (0, [:])
        }
        defer { sqlite3_close(db) }
        var version = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'version'", -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW, let v = sqlite3_column_text(stmt, 0) {
            version = Int(String(cString: v)) ?? 0
        }
        sqlite3_finalize(stmt)
        stmt = nil
        let sql = "SELECT name, value, encrypted_value, last_access_utc FROM cookies WHERE host_key = ?1 OR host_key LIKE '%.' || ?1 ORDER BY last_access_utc"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, [:]) }
        defer { sqlite3_finalize(stmt) }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, (domain as NSString).utf8String, -1, SQLITE_TRANSIENT)
        var cookies: [String: String] = [:]
        var lastUsed: Int64 = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 0))
            var value = String(cString: sqlite3_column_text(stmt, 1))
            let count = Int(sqlite3_column_bytes(stmt, 2))
            if value.isEmpty, count > 0, let blob = sqlite3_column_blob(stmt, 2) {
                let bytes = [UInt8](UnsafeRawBufferPointer(start: blob, count: count))
                guard let plain = decrypt(bytes, dropHostHash: version >= 24, browser: browser) else { continue }
                value = plain
            }
            // Rows come oldest first, so a newer duplicate (another host spelling) wins.
            cookies[name] = value
            lastUsed = max(lastUsed, sqlite3_column_int64(stmt, 3))
        }
        return (lastUsed, cookies)
    }

    private static func decrypt(_ data: [UInt8], dropHostHash: Bool, browser: ChromiumBrowser) -> String? {
        guard data.count > 3, data[0...2] == [0x76, 0x31, 0x30] /* "v10" */, let key = safeStorageKey(browser) else { return nil }
        let body = Array(data[3...])
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var out = [UInt8](repeating: 0, count: body.count + kCCBlockSizeAES128)
        var outCount = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, body, body.count, &out, out.count, &outCount)
        guard status == kCCSuccess else { return nil }
        let plain = out.prefix(outCount).dropFirst(dropHostHash ? 32 : 0)
        return String(bytes: plain, encoding: .utf8)
    }

    /// Asked through /usr/bin/security so an Always Allow survives rebuilds of this app.
    private static func safeStorageKey(_ browser: ChromiumBrowser) -> [UInt8]? {
        if let key = keys.value[browser.id] { return key }
        // Long enough to answer the Keychain prompt, but never forever.
        let r = ChildProcess.run("/usr/bin/security", ["find-generic-password", "-w", "-s", browser.keychainService, "-a", browser.keychainAccount], timeout: 120)
        let password = r.output.trimmingCharacters(in: .newlines)
        guard r.status == 0, !password.isEmpty else {
            Log("SignIn").warn("could not read \(browser.keychainService) from the Keychain: \(r.stopped ?? "security exit \(r.status.map(String.init) ?? "?")")")
            return nil
        }
        let salt = Array("saltysalt".utf8)
        var derived = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        guard CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count, salt, salt.count,
                                   CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &derived, derived.count) == kCCSuccess else {
            Log("SignIn").error("could not derive the \(browser.name) cookie key")
            return nil
        }
        keys.withLock { $0[browser.id] = derived }
        return derived
    }
}

/// `--browser-cookie-check <brave|chrome> <domain>` lists which cookies the browser holds
/// for a site, with value lengths only, then exits: a check that the store can be read
/// and decrypted.
func runBrowserCookieCheckCLI() {
    let args = CommandLine.arguments
    guard let idx = args.firstIndex(of: "--browser-cookie-check"), idx + 2 < args.count,
          let browser = ChromiumBrowser.all.first(where: { $0.id == args[idx + 1] }) else {
        FileHandle.standardError.write(Data("usage: --browser-cookie-check <brave|chrome> <domain>\n".utf8))
        exit(2)
    }
    let cookies = BrowserCookies.read(browser, domain: args[idx + 2])
    for (name, value) in cookies.sorted(by: { $0.key < $1.key }) {
        FileHandle.standardOutput.write(Data("\(name)\t\(value.count) chars\n".utf8))
    }
    exit(cookies.isEmpty ? 1 : 0)
}
