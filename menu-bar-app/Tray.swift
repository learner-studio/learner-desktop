import AppKit
import Foundation
import ServiceManagement
import SQLite3
import CoreBluetooth
import CommonCrypto

// MARK: - Main Application & Status Bar Manager
class TrayAppManager: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var statusMenu: NSMenu!
    var backgroundTimer: Timer?
    var speechTimer: Timer?
    private var isShuttingDown = false
    private var signalSources: [DispatchSourceSignal] = []

    let homeDir = NSHomeDirectory()
    let talkMonitor = TalkTimeMonitor.shared

    // Cached states
    var screenpipeHealth: String = "Checking..."
    var screenpipeDetail: String = ""
    var isScreenpipeHealthy: Bool = false
    var isScreenpipeDegraded: Bool = false

    var vaultCount: Int = 0
    var vaultChatGptCount: Int = 0
    var vaultClaudeCount: Int = 0

    /// learner-server answers GET /api/health (public; no key involved).
    var isServerReachable: Bool = false
    /// A watcher problem that has lasted (from its status.json), or nil when it is sending.
    var watcherProblem: String?
    var watcherParked = 0
    static let watcherProblemGrace: TimeInterval = 10 * 60
    /// The watcher sweeps hourly; no status update for this long means it is not working.
    static let watcherStaleAfter: TimeInterval = 150 * 60

    /// The app's own LaunchAgent. If it is switched off in System Settings -> Login Items,
    /// launchd skips it at login -- and the tunnel and watcher with it -- so a manual start
    /// does not survive the next reboot. Only the owner can re-allow it there.
    let appAgentPlist = NSHomeDirectory() + "/Library/LaunchAgents/com.benpollack.learner-desktop.plist"
    var needsLoginApproval = false

    // Helpers the app runs itself, from its own bundle (see ManagedHelper).
    lazy var tunnel = ManagedHelper(
        name: "tunnel", executable: "/bin/bash",
        arguments: [URL(fileURLWithPath: Bundle.main.resourcePath ?? "").appendingPathComponent("tunnel.sh").path],
        marker: "3200:127.0.0.1:3200")
    lazy var watcher = ManagedHelper(
        name: "watcher", executable: "/Users/benpollack/.bun/bin/bun",
        arguments: [URL(fileURLWithPath: Bundle.main.resourcePath ?? "").appendingPathComponent("learner-watcher.js").path,
                    "watch"],
        marker: "learner-watcher.js")

    /// launchctl bootout / kickstart -k and stop-capture.sh deliver SIGTERM. Route it
    /// through NSApplication.terminate so it takes the same clean path as menu Quit
    /// instead of killing the process mid-write.
    ///
    /// Called from the entrypoint BEFORE app.run(): a SIGTERM that lands in the window
    /// between process start and applicationDidFinishLaunching would otherwise take the
    /// default action (instant kill, no flush). A DispatchSource registered early simply
    /// queues the event until the run loop starts.
    func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApplication.shared.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    var handledPavlokRequests = Set<String>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(receivePavlokTest(_:)),
            name: Notification.Name("com.benpollack.pavlok.test-request"), object: nil)

        // Setup System Tray Status Item in macOS Menu Bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "🧠 🟢 ..."
            button.toolTip = "Learner Desktop\nScreenpipe, AI Vault & learner-server"
        }

        statusMenu = NSMenu()
        statusMenu.delegate = self
        statusItem.menu = statusMenu

        setScreenpipeSkipFlag()

        // Tunnel first: the watcher's startup health check goes through it.
        tunnel.start()
        watcher.start()

        VaultExport.shared.onFinished = { [weak self] in self?.updateTrayButton() }
        rebuildMenu()
        updateAllStatuses()

        talkMonitor.onStreakUpdated = { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateTrayButton()
            }
        }

        PavlokController.shared.onStatusChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.updateTrayButton()
            }
        }

        // Poll speech & monologue detection every 1.0 second
        speechTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.talkMonitor.tick()
        }

        // Poll background server statuses every 8.0 seconds
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
            self?.updateAllStatuses()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        var mark = Date()
        func timed(_ step: String) {
            let ms = Int(Date().timeIntervalSince(mark) * 1000)
            if ms > 150 { print("[Menu] slow open: \(step) took \(ms) ms") }
            mark = Date()
        }
        updateVaultCount(); timed("updateVaultCount")
        PavlokController.shared.updateConnectionStatus(); timed("Pavlok status")
        rebuildMenu(); timed("rebuildMenu")
    }

    // MARK: - Menu Bar Tray Dropdown Menu
    func rebuildMenu() {
        statusMenu.removeAllItems()

        header("Learner Desktop", size: 13)
        statusMenu.addItem(NSMenuItem.separator())

        addSpeakingCoachSection()

        // --- Capture, chats, server ---
        let spState = isScreenpipeHealthy ? "🟢 Recording" : (isScreenpipeDegraded ? "🟡 Idle / Degraded" : "🔴 Stopped")
        statusMenu.addItem(NSMenuItem(title: "📹 Screenpipe: \(spState)" + (screenpipeDetail.isEmpty ? "" : " — \(screenpipeDetail)"), action: nil, keyEquivalent: ""))

        statusMenu.addItem(NSMenuItem(title: "🗄️ AI Vault: 🟢 \(vaultCount) Archived (ChatGPT \(vaultChatGptCount) · Claude \(vaultClaudeCount))", action: nil, keyEquivalent: ""))
        let export = VaultExport.shared
        _ = add("   └─ Last export: " + (export.lastRun.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) + " — " } ?? "") + export.lastSummary)
        for provider in export.expiredLogins.sorted() {
            if VaultSignIn.isWaiting(provider) {
                _ = add("   ⏳ \(provider): sign in in \(ChromiumBrowser.selected.name); the app picks it up from there")
            } else {
                add("   ⚠️ \(provider) login expired — Sign In Again...", #selector(signInToVault(_:))).representedObject = provider
            }
        }
        _ = add("   📥 Pull Latest Chats (Incremental Sweep)", #selector(pullVaultChats))

        let outbox = OutboxSender.shared
        let serverState = !isServerReachable ? "🔴 unreachable" : outbox.keyProblem ? "🔑 no working device key" : "🟢 reachable"
        statusMenu.addItem(NSMenuItem(title: "☁️ learner-server: \(serverState)", action: nil, keyEquivalent: ""))
        _ = add("   └─ 📤 \(HabitEventLogger.shared.getUnsyncedCount()) queued | last: \(outbox.lastStatus)"
            + " | Tunnel \(tunnel.isRunning ? "🟢" : "🔴") | Watcher \(watcher.isRunning ? (watcherProblem == nil ? "🟢" : "🔴") : "🔴")")
        if let problem = watcherProblem { _ = add("   ⚠️ Chats not sending: \(problem)") }
        if watcherParked > 0 { _ = add("   ⚠️ \(watcherParked) chat(s) refused by the server (see watcher log)") }
        _ = add("   ⚡ Send Queued Trials Now", #selector(triggerHabitSync))
        if needsLoginApproval {
            _ = add("   ⚠️ Won't start at login: allow Learner Desktop in Login Items...", #selector(openLoginItemsSettings))
        }
        statusMenu.addItem(NSMenuItem.separator())

        // --- Habit Experiments & GrowthBook ---
        header("📊 Habit Experiments (GrowthBook)")
        let mode = HabitExperimentManager.shared.currentMode
        let assignedArm = HabitExperimentManager.shared.resolveArm(for: talkMonitor.activeSessionId)
        _ = add("   🎯 Condition: \(mode.shortTag) [Active: \(assignedArm)]")
        _ = add("   📈 Recorded Trials: \(HabitEventLogger.shared.getTotalTrialCount())")
        _ = add("   🌐 Open GrowthBook Dashboard...", #selector(openGrowthBookDashboard))
        statusMenu.addItem(NSMenuItem.separator())

        statusMenu.addItem(pavlokMenuItem())

        // --- Settings ---
        let settings = NSMenu()
        addCoachSettings(to: settings)
        let browserMenu = NSMenu()
        for browser in ChromiumBrowser.all {
            add("\(ChromiumBrowser.selected.id == browser.id ? "✓ " : "   ")\(browser.name)", #selector(selectVaultBrowser(_:)), to: browserMenu).representedObject = browser.id
        }
        add("Sign AI Vault In From", to: settings).submenu = browserMenu
        let settingsParent = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsParent.submenu = settings
        statusMenu.addItem(settingsParent)

        // --- Troubleshooting ---
        let trouble = NSMenu()
        trouble.autoenablesItems = false
        _ = add("Open AI Vault Folder...", #selector(openVaultFolder), to: trouble)
        _ = add("Open Screenpipe Recordings...", #selector(openScreenpipeData), to: trouble)
        _ = add("View Watcher Log...", #selector(openWatcherLogs), to: trouble)
        _ = add("View screenpipe Update Checks...", #selector(openUpdateCheckLogs), to: trouble)
        trouble.addItem(NSMenuItem.separator())
        let checking = ScreenpipeUpdateCheck.shared.isRunning
        _ = add(checking ? "🔄 Update check running..." : "🔄 Run screenpipe Update Check Now",
                checking ? nil : #selector(runScreenpipeUpdateCheck), to: trouble)
        if let last = ScreenpipeUpdateCheck.shared.lastRunSummary {
            _ = add("   └─ Last check: \(last)", to: trouble)
        }
        _ = add("Restart Tunnel & Watcher", #selector(restartAggregatorServices), to: trouble)
        let troubleParent = NSMenuItem(title: "Troubleshooting", action: nil, keyEquivalent: "")
        troubleParent.submenu = trouble
        statusMenu.addItem(troubleParent)

        statusMenu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit Learner Desktop", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }

    // MARK: - Status Polling & Dynamic Tray Title
    func updateAllStatuses() {
        updateVaultCount()
        updateScreenpipeStatus()
        updateServerStatus()
        updateLoginItemApproval()
        ensureScreenpipeSkipsSignIn()
        if let appVersion = ScreenpipeUpdateCheck.installedAppVersion() {
            CaptureEnvironment.screenpipeAppVersion = appVersion
            ScreenpipeUpdateCheck.shared.observe(appVersion: appVersion)
        }
        VaultExport.shared.tick()
        updateWatcherStatus()
        OutboxSender.shared.tick(heartbeat: { [weak self] in self?.heartbeatInput() ?? [:] })
    }

    /// Reads ~/.ai-aggregator/status.json, which the watcher writes after each sweep and
    /// while sending keeps failing.
    func updateWatcherStatus() {
        let path = NSHomeDirectory() + "/.ai-aggregator/status.json"
        guard watcher.isRunning,
              let data = FileManager.default.contents(atPath: path),
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            watcherProblem = nil
            return
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = { (key: String) in (status[key] as? String).flatMap { iso.date(from: $0) } }
        watcherParked = status["failed"] as? Int ?? 0
        let started = watcher.startedAt
        if let problem = status["problem"] as? String, let since = date("problemSince"),
           Date().timeIntervalSince(since) > TrayAppManager.watcherProblemGrace {
            watcherProblem = "\(problem) since \(DateFormatter.localizedString(from: since, dateStyle: .none, timeStyle: .short))"
        } else if Date().timeIntervalSince(max(date("lastUpdated") ?? .distantPast, started)) > TrayAppManager.watcherStaleAfter {
            watcherProblem = "no sweep since \(date("lastUpdated").map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "start")"
        } else {
            watcherProblem = nil
        }
    }

    /// recordAppHeartbeat input (contract/desktop.ts, RecordAppHeartbeatInput).
    func heartbeatInput() -> [String: Any] {
        let captureState = isScreenpipeHealthy ? "recording" : (isScreenpipeDegraded ? "paused" : "stopped")
        let iso = ISO8601DateFormatter()
        return [
            "clientId": LearnerAPI.clientId,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            "screenpipeVersion": CaptureEnvironment.screenpipeVersion as Any? ?? NSNull(),
            "captureState": captureState,
            "outboxDepth": HabitEventLogger.shared.getUnsyncedCount(),
            "lastSentAt": OutboxSender.shared.lastSentAt.map { iso.string(from: $0) } as Any? ?? NSNull(),
            "lastVaultExportAt": lastVaultExport().map { iso.string(from: $0) } as Any? ?? NSNull(),
            "detail": ["screenpipeDetail": screenpipeDetail, "outboxStatus": OutboxSender.shared.lastStatus,
                       "capturePhase": CaptureEnvironment.capturePhase as Any? ?? NSNull()],
        ]
    }

    /// Newest conversation.md under ~/ai-vault-data: when ai-vault last exported anything.
    /// Lets the server tell "nothing exported" from "sync broken".
    func lastVaultExport() -> Date? {
        let fm = FileManager.default
        var newest: Date?
        for provider in ["chatgpt", "claude", "gemini"] {
            let dir = homeDir + "/ai-vault-data/\(provider)/conversations"
            for convo in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                if let m = (try? fm.attributesOfItem(atPath: "\(dir)/\(convo)/conversation.md"))?[.modificationDate] as? Date,
                   m > (newest ?? .distantPast) { newest = m }
            }
        }
        return newest
    }

    func updateVaultCount() {
        let fm = FileManager.default
        let chatgptPath = homeDir + "/ai-vault-data/chatgpt/conversations"
        let claudePath = homeDir + "/ai-vault-data/claude/conversations"

        vaultChatGptCount = (try? fm.contentsOfDirectory(atPath: chatgptPath).filter { !$0.hasPrefix(".") }.count) ?? 0
        vaultClaudeCount = (try? fm.contentsOfDirectory(atPath: claudePath).filter { !$0.hasPrefix(".") }.count) ?? 0
        vaultCount = vaultChatGptCount + vaultClaudeCount
        updateTrayButton()
    }

    func updateScreenpipeStatus() {
        guard let url = URL(string: "http://localhost:3030/health") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2.0

        let task = URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.isScreenpipeHealthy = false
                    self.isScreenpipeDegraded = false
                    self.screenpipeDetail = "Port 3030 closed"
                    self.updateTrayButton()
                    return
                }

                if let reportedVersion = json["version"] as? String {
                    CaptureEnvironment.screenpipeVersion = reportedVersion
                }

                let status = json["status"] as? String ?? "unknown"
                let frameStatus = json["frame_status"] as? String ?? "unknown"
                let audioStatus = json["audio_status"] as? String ?? "unknown"

                if let captureStatus = json["capture_status"] as? [String: Any],
                   let activeDevices = captureStatus["active_audio_devices"] as? Int,
                   activeDevices == 0 {
                    self.ensureAudioDevicesActive()
                }

                if status == "healthy" || (frameStatus == "ok" && audioStatus == "ok") {
                    self.isScreenpipeHealthy = true
                    self.isScreenpipeDegraded = false
                    self.screenpipeDetail = "Vision: OK | Audio: OK"
                } else {
                    self.isScreenpipeHealthy = false
                    self.isScreenpipeDegraded = true
                    self.screenpipeDetail = "Vision: \(frameStatus) | Audio: \(audioStatus)"
                }
                self.updateTrayButton()
            }
        }
        task.resume()
    }

    func ensureAudioDevicesActive() {
        guard let url = URL(string: "http://localhost:3030/audio/device/start") else { return }
        for dev in ["MacBook Pro Microphone (input)", "System Audio (output)"] {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["device_name": dev])
            URLSession.shared.dataTask(with: req).resume()
        }
    }

    func updateServerStatus() {
        guard let healthUrl = URL(string: LearnerAPI.baseURL + "/api/health") else { return }
        var req = URLRequest(url: healthUrl)
        req.timeoutInterval = 2.0

        let task = URLSession.shared.dataTask(with: req) { [weak self] _, response, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isServerReachable = (response as? HTTPURLResponse)?.statusCode == 200
                self.updateTrayButton()
            }
        }
        task.resume()
    }

    // MARK: - screenpipe sign-in flag

    /// screenpipe skips its account check when SCREENPIPE_SKIP_ONBOARDING is in its
    /// environment. A separate com.screenpipe.env LaunchAgent used to set it at login, until
    /// macOS switched that agent off in Login Items ("launchctl"): after the 2026-10-11
    /// reboot screenpipe started signed out and recorded nothing for ten days. Setting it
    /// in launchd's user environment covers every screenpipe launched from now on.
    func setScreenpipeSkipFlag() {
        _ = ChildProcess.run("/bin/launchctl", ["setenv", "SCREENPIPE_SKIP_ONBOARDING", "1"], timeout: 10)
    }

    /// The screenpipe process last checked for the flag, so each launch is checked once.
    private var screenpipeFlagCheckedPid: pid_t = 0

    /// At login screenpipe can start before this app has set the flag. Such a screenpipe
    /// waits for a sign-in and never records, so quit it and start it again with the flag.
    func ensureScreenpipeSkipsSignIn() {
        guard let screenpipe = NSRunningApplication.runningApplications(withBundleIdentifier: "screenpi.pe").first,
              screenpipe.processIdentifier != screenpipeFlagCheckedPid else { return }
        let pid = screenpipe.processIdentifier
        screenpipeFlagCheckedPid = pid
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let started = ChildProcess.commandLine(pid, includeEnvironment: true),
                  !started.contains("SCREENPIPE_SKIP_ONBOARDING=1"),
                  // Signed out, screenpipe never starts its server. One that answers is (or
                  // can be) recording, and quitting it would only drop it to search-only.
                  self?.screenpipeServerResponds() == false else { return }
            print("[Screenpipe] Started without SCREENPIPE_SKIP_ONBOARDING, so it is waiting for a sign-in; relaunching it with the flag")
            fflush(stdout)
            // A normal quit: screenpipe handles no termination signals, so a signal could
            // leave its database mid-write.
            _ = screenpipe.terminate()
            let deadline = Date().addingTimeInterval(30)
            while kill(pid, 0) == 0 && Date() < deadline { usleep(200_000) }
            if kill(pid, 0) == 0 {
                // Still there: it went to search-only instead of exiting. Reopening is
                // screenpipe's own way back, and resumes recording.
                print("[Screenpipe] Did not quit within 30s; reopening it instead")
                fflush(stdout)
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.environment = ["SCREENPIPE_SKIP_ONBOARDING": "1"]
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/screenpipe.app"),
                                               configuration: config) { _, error in
                print(error.map { "[Screenpipe] Relaunch failed: \($0.localizedDescription)" }
                      ?? "[Screenpipe] Relaunched with SCREENPIPE_SKIP_ONBOARDING")
                fflush(stdout)
            }
        }
    }

    /// Whether screenpipe's local server answers at all (degraded still counts). Blocking;
    /// call off the main thread.
    func screenpipeServerResponds() -> Bool {
        guard let url = URL(string: "http://localhost:3030/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2.0
        let done = DispatchSemaphore(value: 0)
        var answered = false
        URLSession.shared.dataTask(with: req) { _, response, _ in
            answered = response != nil
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 3)
        return answered
    }

    func updateLoginItemApproval() {
        let plist = URL(fileURLWithPath: appAgentPlist)
        // statusForLegacyPlist is a synchronous XPC round trip; keep it off the main thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let blocked = SMAppService.statusForLegacyPlist(at: plist) == .requiresApproval
            DispatchQueue.main.async {
                guard let self = self, blocked != self.needsLoginApproval else { return }
                if blocked {
                    print("[LoginItem] Learner Desktop is switched off in Login Items; it will not start at login.")
                } else {
                    print("[LoginItem] Learner Desktop is allowed in Login Items; it will start at login.")
                }
                fflush(stdout)
                self.needsLoginApproval = blocked
                self.updateTrayButton()
            }
        }
    }

    func updateTrayButton() {
        guard let button = statusItem?.button else { return }

        let callHint = talkMonitor.activeCallApp != nil ? " [\(talkMonitor.activeCallApp!)]" : ""

        let baseTitle: String
        if talkMonitor.isAlertActive {
            baseTitle = "🗣️ 🚨 \(talkMonitor.formattedDuration)"
            button.toolTip = "Talk-Time Alert: Continuous speech for \(talkMonitor.formattedDuration)\(callHint)\nFloating alert toast displayed (hidden from screenshare)"
        } else if talkMonitor.isWarningActive {
            baseTitle = "🗣️ ⚠️ \(talkMonitor.formattedDuration)"
            button.toolTip = "Talk-Time Warning: Continuous speech for \(talkMonitor.formattedDuration)\(callHint)"
        } else if needsLoginApproval {
            baseTitle = "🧠 🔴 LOGIN"
            button.toolTip = "Learner Desktop\nSwitched off in Login Items: it will not start at login, and neither will the tunnel or watcher"
        } else if OutboxSender.shared.keyProblem {
            baseTitle = "🧠 🔑"
            button.toolTip = "Learner Desktop\nNo working learner-server device key (Keychain: learner-server / ben-mbp); trials queue locally"
        } else if !isServerReachable {
            baseTitle = "🧠 🔴 ERR"
            button.toolTip = "Learner Desktop\nlearner-server unreachable; trials queue locally"
        } else if !isScreenpipeHealthy && !isScreenpipeDegraded {
            baseTitle = "🧠 🔴 SP"
            button.toolTip = "Learner Desktop\nScreenpipe stopped"
        } else if !VaultExport.shared.expiredLogins.isEmpty {
            baseTitle = "🧠 🔴 VAULT"
            button.toolTip = "Learner Desktop\nAI Vault login expired (\(VaultExport.shared.expiredLogins.sorted().joined(separator: ", "))): no new chats are exported.\nOpen the menu and choose Sign In Again."
        } else if let problem = HabitEventLogger.shared.problem {
            baseTitle = "🧠 🔴 DB"
            button.toolTip = "Learner Desktop\nHabit trials are not being saved: \(problem)"
        } else if let problem = watcherProblem {
            baseTitle = "🧠 🔴 SYNC"
            button.toolTip = "Learner Desktop\nChats are not reaching learner-server: \(problem).\nSee View Watcher Log in Troubleshooting."
        } else if isScreenpipeDegraded {
            baseTitle = "🧠 🟡 \(vaultCount)"
            button.toolTip = "Learner Desktop\nScreenpipe idle/degraded"
        } else if let call = talkMonitor.activeCallApp {
            baseTitle = "🗣️ 📞 \(vaultCount)"
            button.toolTip = "Active Call: \(call)\nSpeaking Coach monitoring talk-time limits"
        } else {
            baseTitle = "🧠 🟢 \(vaultCount)"
            button.toolTip = "Learner Desktop\nAll systems healthy (\(vaultCount) chats vaulted)"
        }

        let queued = HabitEventLogger.shared.getUnsyncedCount()
        let attrTitle = NSMutableAttributedString(
            string: baseTitle + (queued > 0 ? " 📤\(queued)" : ""),
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        )
        button.attributedTitle = attrTitle
        button.image = nil
        button.imagePosition = .noImage
    }

    @objc func selectVaultBrowser(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let browser = ChromiumBrowser.all.first(where: { $0.id == id }) else { return }
        ChromiumBrowser.selected = browser
        rebuildMenu()
    }

    @objc func signInToVault(_ sender: NSMenuItem) {
        guard let provider = sender.representedObject as? String else { return }
        VaultSignIn.start(provider)
    }

    @objc func pullVaultChats() {
        VaultExport.shared.runNow()
        rebuildMenu()
    }

    @objc func restartAggregatorServices() {
        tunnel.restart()
        watcher.restart()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.updateServerStatus()
        }
    }

    @objc func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    @objc func openVaultFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: homeDir + "/ai-vault-data"))
    }

    @objc func openScreenpipeData() {
        NSWorkspace.shared.open(URL(fileURLWithPath: homeDir + "/.screenpipe/data"))
    }

    @objc func triggerHabitSync() {
        OutboxSender.shared.sendNow()
        updateAllStatuses()
    }

    @objc func openGrowthBookDashboard() {
        if let url = URL(string: "http://localhost:3200") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func runScreenpipeUpdateCheck() {
        let version = ScreenpipeUpdateCheck.installedAppVersion() ?? "unknown"
        ScreenpipeUpdateCheck.shared.start(reason: "Manual check of screenpipe \(version), requested from the Learner Desktop menu")
    }

    @objc func openUpdateCheckLogs() {
        let dir = ScreenpipeUpdateCheck.shared.logDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }

    @objc func openWatcherLogs() {
        NSWorkspace.shared.open(URL(fileURLWithPath: homeDir + "/.ai-aggregator/logs/watcher.log"))
    }

    /// Clean shutdown. Every exit path (menu Quit, SIGTERM from launchctl, Cmd-Q) lands
    /// here. We finalise the in-flight turn, push everything unsynced to Postgres while
    /// the tunnel is still up, close SQLite, and only then let the process exit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isShuttingDown { return .terminateNow }
        isShuttingDown = true

        // Stop generating new work first.
        speechTimer?.invalidate()
        backgroundTimer?.invalidate()

        // Done synchronously on the main thread and bounded to ~90s. The app is quitting,
        // so blocking its UI is fine, and this avoids the .terminateLater/reply handshake,
        // which was observed to complete the work and then never actually exit.
        print("[Shutdown] Finalising in-flight turn...")
        fflush(stdout)
        talkMonitor.resetStreak()

        let logger = HabitEventLogger.shared
        logger.waitUntilIdle()

        // Send what's queued while we can; whatever fails stays in SQLite for next launch.
        // Bounded so Quit cannot hang (launchd SIGKILLs after 20s anyway).
        print("[Shutdown] Sending \(logger.getUnsyncedCount()) queued turn(s) to learner-server...")
        fflush(stdout)
        let remaining = OutboxSender.shared.drain(until: Date().addingTimeInterval(15))
        print("[Shutdown] Unsynced turns remaining: \(remaining)")

        logger.close()

        print("[Shutdown] Stopping watcher and tunnel...")
        fflush(stdout)
        watcher.stop()
        tunnel.stop()
        VaultExport.shared.stopForQuit()
        print("[Shutdown] Clean shutdown complete.")
        fflush(stdout)
        return .terminateNow
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

}

// MARK: - Menu building

extension TrayAppManager {
    /// A menu line; without an action it is a disabled (status) line.
    @discardableResult
    func add(_ title: String, _ action: Selector? = nil, to menu: NSMenu? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        if action != nil { item.target = self } else { item.isEnabled = false }
        (menu ?? statusMenu).addItem(item)
        return item
    }

    func header(_ title: String, size: CGFloat = 12) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: size)])
        statusMenu.addItem(item)
    }
}
