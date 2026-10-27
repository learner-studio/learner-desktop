import AppKit
import Foundation
import ServiceManagement
import SQLite3
import CoreBluetooth
import CommonCrypto

// MARK: - AI Vault export

/// Pulls new ChatGPT and Claude conversations into ~/ai-vault-data with the `ai-vault`
/// CLI, where the transcript watcher picks them up and archives them on learner-server.
/// Nothing scheduled this before, so nothing new was exported after 2026-09-07. ai-vault
/// logs in with browser cookies that expire. An expired login turns the tray red and the
/// menu offers "Sign In Again", which runs VaultSignIn: the session is taken from Chrome
/// (signing in there first if needed) and handed to `ai-vault setup --cookies-file`.
final class VaultExport {
    static let shared = VaultExport()
    static let interval: TimeInterval = 6 * 3600
    /// A run that is still printing is left alone; one silent this long is stuck (ai-vault
    /// prints a line per conversation and waits at most ~25 s between them).
    static let stallTimeout: TimeInterval = 10 * 60
    static let maxRunTime: TimeInterval = 4 * 3600
    static let killGrace: TimeInterval = 15
    static let rateLimitRetry: TimeInterval = 30 * 60
    /// After a failure (crash, stall, failed fetches): 15 min, doubling up to `interval`.
    static let failureRetryBase: TimeInterval = 15 * 60
    static let providers = ["claude", "chatgpt"]

    private let work = DispatchQueue(label: "com.benpollack.vault-export", qos: .utility)
    private let logPath = NSHomeDirectory() + "/.ai-aggregator/logs/vault-export.log"
    private var nextRun = Date().addingTimeInterval(120)
    private var running = false
    private var rerun = false
    private var failures = 0
    private var current: Process?
    private let currentLock = NSLock()

    static let loginExpiredPattern = "Authentication failed|cookies appear to be expired|Organization ID not available|API request failed: 40[13]"
    static let failedPattern = "Errors: [1-9]|Completed with [1-9][0-9]* errors|✗ Failed:|browser has been closed"
    private(set) var expiredLogins: Set<String> = []
    private(set) var lastRun: Date?
    private(set) var lastSummary = "not run yet"
    /// Main thread, after each run, so the tray refreshes without waiting for the poll.
    var onFinished: (() -> Void)?

    /// Called on the 8 s status poll.
    func tick() {
        guard !running, Date() >= nextRun else { return }
        runNow()
    }

    /// A fresh sign-in clears its error at once, rather than when the next export ends.
    func signedIn(_ provider: String) {
        expiredLogins.remove(provider)
        onFinished?()
        runNow()
    }

    func runNow() {
        // A sign-in during a run must not be lost: run again once this one ends.
        guard !running else { rerun = true; return }
        running = true
        nextRun = Date().addingTimeInterval(VaultExport.interval)
        work.async {
            VaultExport.killOrphans()
            var expired: Set<String> = []
            var notes: [String] = []
            var rateLimited = false
            var failed = false
            for provider in VaultExport.providers {
                let (status, output) = self.backup(provider)
                // ai-vault exits 0 even when its summary lists errors, so read the output.
                if output.range(of: VaultExport.loginExpiredPattern, options: .regularExpression) != nil {
                    expired.insert(provider)
                    notes.append("\(provider): login expired")
                } else if output.contains("API request failed: 429") {
                    rateLimited = true
                    notes.append("\(provider): rate limited, retrying in 30 min")
                } else if status == nil {
                    failed = true
                    notes.append("\(provider): stuck, stopped")
                } else if output.range(of: VaultExport.failedPattern, options: .regularExpression) != nil {
                    failed = true
                    notes.append("\(provider): failed (see vault-export.log)")
                } else {
                    notes.append("\(provider): \(status == 0 ? "ok" : "exit \(status!)")")
                }
            }
            // ai-vault drops ChatGPT voice transcripts; write them back in (see voice-transcripts.ts).
            if !expired.contains("chatgpt") {
                let (status, output) = self.fillVoiceTranscripts()
                if output.contains("stopped: rate-limited") { rateLimited = true }
                else if status != 0 { failed = true; notes.append("voice transcripts: failed (see vault-export.log)") }
                if let m = output.range(of: #"[0-9]+ updated \([0-9]+ messages\)"#, options: .regularExpression), !output[m].hasPrefix("0 ") {
                    notes.append("voice transcripts: \(output[m])")
                }
            }
            DispatchQueue.main.async {
                self.expiredLogins = expired
                self.lastRun = Date()
                self.lastSummary = notes.joined(separator: ", ")
                self.running = false
                // --only-new resumes where a run stopped, so retrying soon loses nothing.
                self.failures = failed ? self.failures + 1 : 0
                if failed {
                    let wait = min(VaultExport.interval, VaultExport.failureRetryBase * pow(2, Double(self.failures - 1)))
                    self.nextRun = min(self.nextRun, Date().addingTimeInterval(wait))
                    notes.append("retrying in \(Int(wait / 60)) min")
                    self.lastSummary = notes.joined(separator: ", ")
                }
                if rateLimited { self.nextRun = min(self.nextRun, Date().addingTimeInterval(VaultExport.rateLimitRetry)) }
                print("[VaultExport] \(self.lastSummary)")
                self.onFinished?()
                if self.rerun { self.rerun = false; self.runNow() }
            }
        }
    }

    private func backup(_ provider: String) -> (Int32?, String) {
        guard let cli = VaultExport.cliPath() else { return (127, "ai-vault CLI not found") }
        var args = ["backup", provider, "--only-new", "--skip-media", "-y"]
        if provider == "chatgpt" { args.append("--random-delay") }
        return runLogged(cli, args, label: provider)
    }

    /// `learner-watcher voice-transcripts`, through the app's bundled watcher script.
    private func fillVoiceTranscripts() -> (Int32?, String) {
        let script = URL(fileURLWithPath: Bundle.main.resourcePath ?? "").appendingPathComponent("learner-watcher.js").path
        return runLogged(NSHomeDirectory() + "/.bun/bin/bun", [script, "voice-transcripts"], label: "voice-transcripts")
    }

    /// Runs a command, streaming its output to vault-export.log. Returns the exit status
    /// (nil when it was stopped as stuck) and the output, for the outcome checks.
    private func runLogged(_ executable: String, _ args: [String], label: String) -> (Int32?, String) {
        LogFile.rotate(logPath)
        if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
        let log = FileHandle(forWritingAtPath: logPath)
        log?.seekToEndOfFile()
        log?.write(Data("=== \(Date()) \(label)\n".utf8))
        defer { try? log?.close() }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        // ai-vault's node (and the browser it drives) sit beside the CLI under nvm.
        env["PATH"] = ((VaultExport.cliPath() ?? "/usr/bin/x") as NSString).deletingLastPathComponent + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        var data = Data()
        var lastOutput = Date()
        let reader = DispatchQueue(label: "vault-export-read")
        out.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { h.readabilityHandler = nil; return }
            reader.sync {
                data.append(chunk)
                lastOutput = Date()
                log?.write(chunk)
            }
        }
        guard (try? p.run()) != nil else { return (126, "could not start \(label)") }
        setCurrent(p)
        defer { setCurrent(nil) }
        let started = Date()
        var stuck: String?
        while p.isRunning {
            usleep(500_000)
            let silent = Date().timeIntervalSince(reader.sync { lastOutput })
            if silent > VaultExport.stallTimeout { stuck = "no output for \(Int(silent / 60)) min" }
            else if Date().timeIntervalSince(started) > VaultExport.maxRunTime { stuck = "running over \(Int(VaultExport.maxRunTime / 3600)) h" }
            if let why = stuck {
                print("[VaultExport] \(label): \(why); stopping it")
                VaultExport.stop(p)
                break
            }
        }
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        let text = reader.sync { String(data: data, encoding: .utf8) ?? "" }
        if let why = stuck { log?.write(Data("\n=== stopped: \(why)\n".utf8)) }
        return (stuck == nil ? p.terminationStatus : nil, text)
    }

    private func setCurrent(_ p: Process?) {
        currentLock.lock(); current = p; currentLock.unlock()
    }

    /// On quit: an export left running would outlive the app and race the next launch's.
    func stopForQuit() {
        currentLock.lock(); let p = current; currentLock.unlock()
        // Shutdown has seconds, not a grace period.
        if let p = p, p.isRunning { VaultExport.stop(p, grace: 0) }
    }

    /// SIGTERM, then SIGKILL for it and its children (the browser) after a grace period.
    /// ai-vault can sit in its own SIGTERM handler forever once its browser has died.
    static func stop(_ p: Process, grace: TimeInterval = killGrace) {
        let pid = p.processIdentifier
        let tree = [pid] + descendants(of: pid)
        p.terminate()
        let deadline = Date().addingTimeInterval(grace)
        while p.isRunning && Date() < deadline { usleep(200_000) }
        for child in tree where kill(child, 0) == 0 { kill(child, SIGKILL) }
    }

    private static func descendants(of pid: pid_t) -> [pid_t] {
        let kids = ChildProcess.run("/usr/bin/pgrep", ["-P", String(pid)], timeout: 5).output.split(separator: "\n").compactMap { pid_t($0) }
        return kids + kids.flatMap { descendants(of: $0) }
    }

    /// An export orphaned by a crash of this app (now parented to launchd) would run
    /// alongside the next one and trip ChatGPT's rate limit.
    private static func killOrphans() {
        for line in ChildProcess.run("/bin/ps", ["-axo", "pid=,ppid=,command="], timeout: 5).output.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, f[1] == "1", let pid = pid_t(f[0]),
                  f[2].contains("ai-vault backup") || f[2].contains("learner-watcher.js voice-transcripts") else { continue }
            print("[VaultExport] stopping an export left over from an earlier launch (pid \(pid))")
            kill(pid, SIGKILL)
        }
    }

    /// ai-vault is installed under nvm; pick the newest node version that has it.
    static func cliPath() -> String? {
        let root = NSHomeDirectory() + "/.nvm/versions/node"
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted().reversed()
        return versions.map { "\(root)/\($0)/bin/ai-vault" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - AI Vault sign-in

/// Signs ai-vault back in from your own browser (Settings → Sign AI Vault In From; Brave by
/// default), where 1Password and passkeys work; an embedded web view gets neither. The
/// provider's cookies are read from that browser's cookie store and handed to
/// `ai-vault setup <provider> --cookies-file` (a 0600 file, deleted straight after).
/// If the browser already holds a new session, nothing opens. Otherwise the sign-in page
/// opens there and the cookie store is watched until a new session appears.
final class VaultSignIn {
    struct Site { let url: String; let domain: String; let session: [String] }

    static let sites: [String: Site] = [
        "chatgpt": Site(url: "https://chatgpt.com/auth/login", domain: "chatgpt.com",
                        session: ["__Secure-next-auth.session-token", "__Secure-next-auth.session-token.0"]),
        "claude": Site(url: "https://claude.ai/login", domain: "claude.ai", session: ["sessionKey"]),
    ]
    static let pollInterval: TimeInterval = 3
    static let waitLimit: TimeInterval = 10 * 60
    private static var active: [String: VaultSignIn] = [:]

    static func isWaiting(_ provider: String) -> Bool { active[provider]?.openedBrowser == true }

    static func start(_ provider: String) {
        guard active[provider] == nil, let site = sites[provider] else { return }
        let s = VaultSignIn(provider: provider, site: site)
        active[provider] = s
        print("[VaultSignIn] \(provider): checking \(s.browser.name)'s session")
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
        guard let data = FileManager.default.contents(atPath: NSHomeDirectory() + "/.ai-vault/config.json"),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
            print("[VaultSignIn] \(provider): ai-vault accepted \(browser.name)'s session; exporting")
            stop()
            VaultExport.shared.signedIn(provider)
            return
        }
        if let result = result { print("[VaultSignIn] \(provider): ai-vault setup failed: \(result.detail)") }
        if Date() > deadline {
            print("[VaultSignIn] \(provider): no new session in \(browser.name) after \(Int(VaultSignIn.waitLimit / 60)) min; stopped watching")
            stop()
            return
        }
        guard !openedBrowser else { return }
        openedBrowser = true
        browser.open(site.url)
        print("[VaultSignIn] \(provider): opened the sign-in page in \(browser.name)")
        timer = Timer.scheduledTimer(withTimeInterval: VaultSignIn.pollInterval, repeats: true) { [weak self] _ in self?.check() }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        VaultSignIn.active[provider] = nil
    }

    /// `ai-vault setup <provider> --cookies-file <0600 file>`; the file is removed afterwards.
    static func runSetup(_ provider: String, cookies: [String: String]) -> (ok: Bool, detail: String) {
        guard sites[provider] != nil, let cli = VaultExport.cliPath() else { return (false, "ai-vault CLI not found") }
        let path = NSHomeDirectory() + "/.ai-aggregator/ai-vault-cookies-\(provider).json"
        guard let data = try? JSONSerialization.data(withJSONObject: cookies),
              FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            return (false, "could not write the cookies file")
        }
        defer { try? FileManager.default.removeItem(atPath: path) }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (cli as NSString).deletingLastPathComponent + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        let r = ChildProcess.run(cli, ["setup", provider, "--cookies-file", path], timeout: 90, env: env, stderr: true)
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
    private static var keys: [String: [UInt8]] = [:]

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
        if let key = keys[browser.id] { return key }
        // Long enough to answer the Keychain prompt, but never forever.
        let r = ChildProcess.run("/usr/bin/security", ["find-generic-password", "-w", "-s", browser.keychainService, "-a", browser.keychainAccount], timeout: 120)
        let password = r.output.trimmingCharacters(in: .newlines)
        guard r.status == 0, !password.isEmpty else {
            print("[VaultSignIn] could not read \(browser.keychainService) from the Keychain")
            return nil
        }
        let salt = Array("saltysalt".utf8)
        var derived = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        guard CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count, salt, salt.count,
                                   CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &derived, derived.count) == kCCSuccess else {
            return nil
        }
        keys[browser.id] = derived
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
        print("usage: --browser-cookie-check <brave|chrome> <domain>")
        exit(2)
    }
    let cookies = BrowserCookies.read(browser, domain: args[idx + 2])
    for (name, value) in cookies.sorted(by: { $0.key < $1.key }) { print("\(name)\t\(value.count) chars") }
    exit(cookies.isEmpty ? 1 : 0)
}
