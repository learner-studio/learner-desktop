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

    private var handledPavlokRequests = Set<String>()

    @objc func receivePavlokTest(_ notification: Notification) {
        guard notification.object as? String == String(ProcessInfo.processInfo.processIdentifier),
              let info = notification.userInfo,
              let id = info["id"] as? String, UUID(uuidString: id) != nil,
              let type = info["type"] as? String, ["vibe", "beep", "zap"].contains(type),
              let level = info["intensity"] as? Int, (1...100).contains(level),
              let sent = info["sent_at"] as? Double, abs(Date().timeIntervalSince1970 - sent) < 30,
              !handledPavlokRequests.contains(id) else { return }
        handledPavlokRequests.insert(id)
        PavlokController.shared.testFire(type: type, operationID: id, intensityOverride: level) { ok, detail in
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.benpollack.pavlok.test-result"), object: id,
                userInfo: ["success": ok, "detail": detail], deliverImmediately: true)
        }
    }

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

        header("Learner Desktop", size: 13)
        statusMenu.addItem(NSMenuItem.separator())

        // --- Speaking Coach ---
        header("Speaking Coach (Talk-Time Monitor)")
        let callSuffix = talkMonitor.activeCallApp.map { " (\($0))" } ?? ""
        if talkMonitor.isAlertActive {
            _ = add("   🚨 Monologue Alert: \(talkMonitor.formattedDuration) continuous speech\(callSuffix)")
            _ = add("   ✕ Dismiss Alert Toast", #selector(dismissToast))
        } else if talkMonitor.isWarningActive {
            _ = add("   ⚠️ Monologue Warning: \(talkMonitor.formattedDuration) continuous speech\(callSuffix)")
        } else if let call = talkMonitor.activeCallApp {
            let title = talkMonitor.activeCallTitle.map { " · \($0)" } ?? ""
            _ = add("   🟢 Status: In call (\(call)\(title)) • Monitoring talk-time")
        } else {
            _ = add(talkMonitor.alertOnlyDuringCalls
                ? "   🟢 Status: Standby (Monitoring for calls • Off-call quiet)"
                : "   🟢 Status: Listening (All speech monitored: >30s warn / >1m alert)")
        }
        if talkMonitor.currentStreak > 0 {
            _ = add("   ↺ Reset Speaking Streak (\(talkMonitor.formattedDuration))", #selector(resetStreakAction))
        }
        statusMenu.addItem(NSMenuItem.separator())

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

        // --- Pavlok (one submenu) ---
        let pavlok = PavlokController.shared
        let pavMenu = NSMenu()
        let pavStatus = add("Connection: \(pavlok.connectionStatusText)", to: pavMenu)
        pavStatus.image = PavlokDogIcon.image(connected: pavlok.isBleConnected, isScanning: pavlok.isBleScanning)
        _ = add(pavlok.isEnabled ? "✓ Wearable Operant Feedback Enabled" : "○ Wearable Feedback Disabled (Safe Default)",
                #selector(togglePavlokEnabled), to: pavMenu)

        let comboMenu = NSMenu()
        let combos = [
            ("both_shock", "Both Shock (Default)", "⚡ Shock (30s: 15%) + ⚡ Shock (60s: 35%)  [Default: Both Shock]"),
            ("vibe_shock", "Vibe (30s) + Shock (60s)", "📳 Vibe (30s: 30%) + ⚡ Shock (60s: 35%)    [Graduated: Vibe then Shock]"),
            ("shock_vibe", "Shock (30s) + Vibe (60s)", "⚡ Shock (30s: 15%) + 📳 Vibe (60s: 60%)    [Inverted: Shock then Vibe]"),
            ("both_vibe", "Both Vibration", "📳 Vibe (30s: 30%) + 📳 Vibe (60s: 60%)    [Gentle: Both Vibration]"),
            ("both_dual", "Dual Shock + Vibe", "⚡📳 Dual Shock + Vibe (Both Thresholds)"),
            ("all_zero", "All 0% (Silent)", "⚪ 0% All Modalities Disabled (Silent / Toast Only)")
        ]
        for (key, summary, label) in combos {
            let isSel = pavlok.presetSummary == summary
            let item = add("\(isSel ? "⦿ " : "○ ")\(label)", #selector(selectCuePreset(_:)), to: comboMenu)
            item.representedObject = key
            item.state = isSel ? .on : .off
        }
        add("🎛️ Cue Preset: \(pavlok.presetSummary)", to: pavMenu).submenu = comboMenu

        // 30s / 60s panels: interactive, non-closing multi-select views.
        let warnView = Pavlok30sSubmenuView()
        let warnParent = add("⏱️ 30s Warning: \(pavlok.warningCueSummary)", to: pavMenu)
        warnView.onStateChanged = { [weak self, weak warnParent] in
            warnParent?.title = "⏱️ 30s Warning: \(PavlokController.shared.warningCueSummary)"
            self?.updateTrayButton()
        }
        let alertView = Pavlok60sSubmenuView()
        let alertParent = add("⏱️ 60s Hard Stop: \(pavlok.alertCueSummary)", to: pavMenu)
        alertView.onStateChanged = { [weak self, weak alertParent] in
            alertParent?.title = "⏱️ 60s Hard Stop: \(PavlokController.shared.alertCueSummary)"
            self?.updateTrayButton()
        }
        for (parent, view) in [(warnParent, warnView as NSView), (alertParent, alertView as NSView)] {
            let sub = NSMenu()
            let holder = NSMenuItem()
            holder.view = view
            sub.addItem(holder)
            parent.isEnabled = true
            parent.submenu = sub
        }
        _ = add(pavlok.rewardGoodBehavior ? "✓ Good Behavior: Reward Vibration on Concise Turns (<30s)" : "○ Good Behavior: Reward Vibration Disabled",
                #selector(toggleGoodBehaviorReward), to: pavMenu)
        pavMenu.addItem(NSMenuItem.separator())
        add("Keep Bluetooth Connected", #selector(togglePavlokConnection), to: pavMenu).state = pavlok.keepConnected ? .on : .off
        _ = add("🔍 Scan & Connect via Bluetooth", #selector(scanPavlokBluetooth), to: pavMenu)
        _ = add(pavlok.apiToken.isEmpty ? "🔑 Configure Cloud Backup Token (Optional)..." : "🔑 Change Cloud Backup Token (Configured)...",
                #selector(promptPavlokToken), to: pavMenu)
        let pavState = !pavlok.isEnabled ? "⚪ Disabled" : (pavlok.isBleConnected ? "🟢 Connected" : "🟡 Not connected")
        let pavParent = NSMenuItem(title: "⚡ Pavlok: \(pavState)", action: nil, keyEquivalent: "")
        pavParent.submenu = pavMenu
        statusMenu.addItem(pavParent)

        // --- Settings ---
        let settings = NSMenu()
        _ = add(talkMonitor.alertOnlyDuringCalls ? "✓ Alert Only During Calls (Off-Call Silent)" : "○ Alert On All Monologues (Any App)",
                #selector(toggleAlertOnlyDuringCalls), to: settings)
        let browserMenu = NSMenu()
        for browser in ChromiumBrowser.all {
            add("\(ChromiumBrowser.selected.id == browser.id ? "✓ " : "   ")\(browser.name)", #selector(selectVaultBrowser(_:)), to: browserMenu).representedObject = browser.id
        }
        add("Sign AI Vault In From", to: settings).submenu = browserMenu
        let armMenu = NSMenu()
        for arm in HabitTreatmentArm.allCases {
            add("\(mode == arm ? "✓ " : "   ")\(arm.displayName)", #selector(selectExperimentArm(_:)), to: armMenu).representedObject = arm.rawValue
        }
        let armParent = add("Select Active Intervention Condition...", to: settings)
        armParent.isEnabled = true
        armParent.submenu = armMenu
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
        _ = runBounded("/bin/launchctl", ["setenv", "SCREENPIPE_SKIP_ONBOARDING", "1"], timeout: 10)
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
            guard let started = processCommandLine(pid, includeEnvironment: true),
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

    // MARK: - Actions
    @objc func dismissToast() {
        MonologueToastController.shared.hide()
        updateTrayButton()
        rebuildMenu()
    }

    @objc func toggleAlertOnlyDuringCalls() {
        talkMonitor.alertOnlyDuringCalls.toggle()
        if talkMonitor.alertOnlyDuringCalls && talkMonitor.activeCallApp == nil {
            MonologueToastController.shared.hide()
        }
        rebuildMenu()
    }

    @objc func resetStreakAction() {
        talkMonitor.resetStreak()
        updateTrayButton()
        rebuildMenu()
    }

    // MARK: - Pavlok Actions
    @objc func togglePavlokConnection() {
        PavlokController.shared.keepConnected.toggle()
        rebuildMenu()
        updateTrayButton()
    }

    @objc func scanPavlokBluetooth() {
        PavlokController.shared.keepConnected = true
        PavlokController.shared.startBleScan(force: true)
        rebuildMenu()
        updateTrayButton()
    }

    @objc func togglePavlokEnabled() {
        PavlokController.shared.isEnabled.toggle()
        updateTrayButton()
        rebuildMenu()
    }

    @objc func selectCuePreset(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        switch key {
        case "both_shock":
            PavlokController.shared.warningShockIntensity = (PavlokController.shared.savedWarningShockIntensity > 0 ? PavlokController.shared.savedWarningShockIntensity : 15)
            PavlokController.shared.warningVibeIntensity = 0
            PavlokController.shared.warningBeepEnabled = false
            PavlokController.shared.alertShockIntensity = (PavlokController.shared.savedAlertShockIntensity > 0 ? PavlokController.shared.savedAlertShockIntensity : 35)
            PavlokController.shared.alertVibeIntensity = 0
        case "vibe_shock":
            PavlokController.shared.warningShockIntensity = 0
            PavlokController.shared.warningVibeIntensity = (PavlokController.shared.savedWarningVibeIntensity > 0 ? PavlokController.shared.savedWarningVibeIntensity : 30)
            PavlokController.shared.warningBeepEnabled = false
            PavlokController.shared.alertShockIntensity = (PavlokController.shared.savedAlertShockIntensity > 0 ? PavlokController.shared.savedAlertShockIntensity : 35)
            PavlokController.shared.alertVibeIntensity = 0
        case "shock_vibe":
            PavlokController.shared.warningShockIntensity = (PavlokController.shared.savedWarningShockIntensity > 0 ? PavlokController.shared.savedWarningShockIntensity : 15)
            PavlokController.shared.warningVibeIntensity = 0
            PavlokController.shared.warningBeepEnabled = false
            PavlokController.shared.alertShockIntensity = 0
            PavlokController.shared.alertVibeIntensity = (PavlokController.shared.savedAlertVibeIntensity > 0 ? PavlokController.shared.savedAlertVibeIntensity : 60)
        case "both_vibe":
            PavlokController.shared.warningShockIntensity = 0
            PavlokController.shared.warningVibeIntensity = (PavlokController.shared.savedWarningVibeIntensity > 0 ? PavlokController.shared.savedWarningVibeIntensity : 30)
            PavlokController.shared.warningBeepEnabled = false
            PavlokController.shared.alertShockIntensity = 0
            PavlokController.shared.alertVibeIntensity = (PavlokController.shared.savedAlertVibeIntensity > 0 ? PavlokController.shared.savedAlertVibeIntensity : 60)
        case "both_dual":
            PavlokController.shared.warningShockIntensity = (PavlokController.shared.savedWarningShockIntensity > 0 ? PavlokController.shared.savedWarningShockIntensity : 15)
            PavlokController.shared.warningVibeIntensity = (PavlokController.shared.savedWarningVibeIntensity > 0 ? PavlokController.shared.savedWarningVibeIntensity : 30)
            PavlokController.shared.alertShockIntensity = (PavlokController.shared.savedAlertShockIntensity > 0 ? PavlokController.shared.savedAlertShockIntensity : 35)
            PavlokController.shared.alertVibeIntensity = (PavlokController.shared.savedAlertVibeIntensity > 0 ? PavlokController.shared.savedAlertVibeIntensity : 60)
        case "all_zero":
            PavlokController.shared.warningShockIntensity = 0
            PavlokController.shared.warningVibeIntensity = 0
            PavlokController.shared.warningBeepEnabled = false
            PavlokController.shared.alertShockIntensity = 0
            PavlokController.shared.alertVibeIntensity = 0
        default:
            break
        }
        rebuildMenu()
        updateTrayButton()
    }

    @objc func toggle30sShockAction() {
        PavlokController.shared.toggle30sShock()
        rebuildMenu()
        updateTrayButton()
    }

    @objc func toggle30sVibeAction() {
        PavlokController.shared.toggle30sVibe()
        rebuildMenu()
        updateTrayButton()
    }

    @objc func toggle30sBeepAction() {
        PavlokController.shared.toggle30sBeep()
        rebuildMenu()
        updateTrayButton()
    }

    @objc func toggle60sShockAction() {
        PavlokController.shared.toggle60sShock()
        rebuildMenu()
        updateTrayButton()
    }

    @objc func toggle60sVibeAction() {
        PavlokController.shared.toggle60sVibe()
        rebuildMenu()
        updateTrayButton()
    }

    @objc func select30sWarningCue(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String {
            PavlokController.shared.warningCue = key
            rebuildMenu()
            updateTrayButton()
        }
    }

    @objc func select30sShockIntensity(_ sender: NSMenuItem) {
        PavlokController.shared.warningShockIntensity = sender.tag
        rebuildMenu()
        updateTrayButton()
    }

    @objc func select30sVibeIntensity(_ sender: NSMenuItem) {
        PavlokController.shared.warningVibeIntensity = sender.tag
        rebuildMenu()
        updateTrayButton()
    }

    @objc func select60sAlertCue(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String {
            PavlokController.shared.alertCue = key
            rebuildMenu()
            updateTrayButton()
        }
    }

    @objc func select60sShockIntensity(_ sender: NSMenuItem) {
        PavlokController.shared.alertShockIntensity = sender.tag
        rebuildMenu()
        updateTrayButton()
    }

    @objc func select60sVibeIntensity(_ sender: NSMenuItem) {
        PavlokController.shared.alertVibeIntensity = sender.tag
        rebuildMenu()
        updateTrayButton()
    }

    @objc func testPavlok30sCue() {
        PavlokController.shared.trigger30sWarning()
    }

    @objc func testPavlok60sCue() {
        PavlokController.shared.trigger60sHardStop()
    }

    @objc func toggleGoodBehaviorReward() {
        PavlokController.shared.rewardGoodBehavior.toggle()
        rebuildMenu()
    }

    @objc func promptPavlokToken() {
        let alert = NSAlert()
        alert.messageText = "Pavlok API Token"
        alert.informativeText = "Enter your Pavlok Personal API token (obtainable from pavlok.com account settings):"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.stringValue = PavlokController.shared.apiToken
        alert.accessoryView = input

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let token = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            PavlokController.shared.apiToken = token
            rebuildMenu()
            updateTrayButton()
        }
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

    @objc func selectExperimentArm(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let arm = HabitTreatmentArm(rawValue: raw) else { return }
        HabitExperimentManager.shared.currentMode = arm
        print("[HabitExperiment] Switched experiment condition to: \(arm.displayName)")
        fflush(stdout)
        rebuildMenu()
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
