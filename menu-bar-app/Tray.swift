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
    private var isShuttingDown = false
    let log = Log("Tray")
    private var signalSources: [DispatchSourceSignal] = []

    let homeDir = NSHomeDirectory()
    let talkMonitor = TalkTimeMonitor.shared

    /// Collected off the main thread by the Status job; the tray and menu only read it.
    var status = AppStatus()
    private var trayKind = ""
    private lazy var statusJob = Job("Status", period: 8, backoff: Backoff(base: 8, max: 60), quiet: true) { [weak self] _ in
        guard let self = self else { return .idle }
        let previous = DispatchQueue.main.sync { self.status }
        let next = StatusProbe.collect(previous: previous, helpers: [self.tunnel, self.watcher], appAgentPlist: self.appAgentPlist)
        self.ensureScreenpipeSkipsSignIn()
        if let appVersion = ScreenpipeUpdateCheck.installedAppVersion() {
            CaptureEnvironment.screenpipeAppVersion = appVersion
            DispatchQueue.main.async { ScreenpipeUpdateCheck.shared.observe(appVersion: appVersion) }
        }
        DispatchQueue.main.async { self.apply(next) }
        return .ok("collected")
    }

    /// The app's own LaunchAgent. If it is switched off in System Settings -> Login Items,
    /// launchd skips it at login -- and the tunnel and watcher with it -- so a manual start
    /// does not survive the next reboot. Only the owner can re-allow it there.
    let appAgentPlist = NSHomeDirectory() + "/Library/LaunchAgents/com.benpollack.learner-desktop.plist"

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

        VaultExport.shared.onFinished = { [weak self] in self?.statusJob.kick("export finished") }
        rebuildMenu()

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

        _ = statusJob
        Scheduler.every(1, "coach") { [weak self] in self?.talkMonitor.tick() }
        Scheduler.every(8, "export+outbox") { [weak self] in
            VaultExport.shared.tick()
            OutboxSender.shared.tick(heartbeat: { self?.heartbeatInput() ?? [:] })
        }
        Scheduler.start()
    }

    /// Main thread: swap in a fresh status and redraw the tray.
    func apply(_ next: AppStatus) {
        status = next
        updateTrayButton()
    }

    /// Draws from the last status snapshot (no I/O), then refreshes it in the background.
    func menuWillOpen(_ menu: NSMenu) {
        let started = Date()
        rebuildMenu()
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if ms > 100 { log.warn("menu took \(ms) ms to build") }
        statusJob.kick("menu opened")
        PavlokController.shared.updateConnectionStatus()
    }

    // MARK: - Menu Bar Tray Dropdown Menu
    func rebuildMenu() {
        statusMenu.removeAllItems()

        header("Learner Desktop", size: 13)
        statusMenu.addItem(NSMenuItem.separator())

        addSpeakingCoachSection()

        // --- Capture, chats, server ---
        let capture: String
        switch status.capture {
        case .unknown: capture = "… checking"
        case .recording: capture = "🟢 Recording"
        case let .degraded(why): capture = "🟡 Degraded — \(why)"
        case let .stopped(why): capture = "🔴 Stopped — \(why)"
        }
        add("📹 Screenpipe: \(capture)")
        add("🗄️ AI Vault: \(status.chats) Archived (ChatGPT \(status.chatgptChats) · Claude \(status.claudeChats))")
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
        let serverState = !status.serverReachable ? "🔴 unreachable" : outbox.keyProblem ? "🔑 no working device key" : "🟢 reachable"
        add("☁️ learner-server: \(serverState)")
        add("   └─ 📤 \(status.outboxDepth) queued | last: \(outbox.lastStatus)"
            + " | Tunnel \(tunnel.isRunning ? "🟢" : "🔴") | Watcher \(watcher.isRunning ? "🟢" : "🔴")")
        for p in status.problems { add("   ⚠️ \(p.source): \(p.text)") }
        add("   ⚡ Send Queued Trials Now", #selector(triggerHabitSync))
        if status.loginItemBlocked {
            _ = add("   ⚠️ Won't start at login: allow Learner Desktop in Login Items...", #selector(openLoginItemsSettings))
        }
        statusMenu.addItem(NSMenuItem.separator())

        // --- Habit Experiments & GrowthBook ---
        header("📊 Habit Experiments (GrowthBook)")
        let mode = HabitExperimentManager.shared.currentMode
        let assignedArm = HabitExperimentManager.shared.resolveArm(for: talkMonitor.activeSessionId)
        _ = add("   🎯 Condition: \(mode.shortTag) [Active: \(assignedArm)]")
        add("   📈 Recorded Trials: \(status.trialCount)")
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

    /// recordAppHeartbeat input (contract/desktop.ts, RecordAppHeartbeatInput).
    func heartbeatInput() -> [String: Any] {
        let current = DispatchQueue.main.sync { status }
        let captureState: String
        switch current.capture {
        case .recording: captureState = "recording"
        case .degraded: captureState = "paused"
        default: captureState = "stopped"
        }
        let iso = ISO8601DateFormatter()
        return [
            "clientId": LearnerAPI.clientId,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            "screenpipeVersion": CaptureEnvironment.screenpipeVersion as Any? ?? NSNull(),
            "captureState": captureState,
            "outboxDepth": current.outboxDepth,
            "lastSentAt": OutboxSender.shared.lastSentAt.map { iso.string(from: $0) } as Any? ?? NSNull(),
            "lastVaultExportAt": lastVaultExport().map { iso.string(from: $0) } as Any? ?? NSNull(),
            "detail": ["capture": StatusProbe.describe(current.capture), "outboxStatus": OutboxSender.shared.lastStatus,
                       "problems": current.problems.map { "\($0.source): \($0.text)" },
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
                  HTTPProbe.get(StatusProbe.screenpipeURL + "/health").status == 0 else { return }
            self?.log.warn("screenpipe started without SCREENPIPE_SKIP_ONBOARDING, so it is waiting for a sign-in; relaunching it with the flag")
            // A normal quit: screenpipe handles no termination signals, so a signal could
            // leave its database mid-write.
            _ = screenpipe.terminate()
            let deadline = Date().addingTimeInterval(30)
            while kill(pid, 0) == 0 && Date() < deadline { usleep(200_000) }
            if kill(pid, 0) == 0 {
                // Still there: it went to search-only instead of exiting. Reopening is
                // screenpipe's own way back, and resumes recording.
                self?.log.warn("screenpipe did not quit within 30 s; reopening it instead")
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.environment = ["SCREENPIPE_SKIP_ONBOARDING": "1"]
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/screenpipe.app"),
                                               configuration: config) { _, error in
                if let error = error { self?.log.error("screenpipe relaunch failed: \(error.localizedDescription)") }
                else { self?.log.info("screenpipe relaunched with SCREENPIPE_SKIP_ONBOARDING") }
            }
        }
    }

    /// Cheap (no I/O): called on every coach update and every status swap.
    func updateTrayButton() {
        guard let button = statusItem?.button else { return }
        let coach = CoachLive(alert: talkMonitor.isAlertActive, warning: talkMonitor.isWarningActive,
                              duration: talkMonitor.formattedDuration, call: talkMonitor.activeCallApp)
        let state = TrayState.make(status, coach: coach)
        if state.kind != trayKind {
            log.info("\(trayKind.isEmpty ? "start" : trayKind) -> \(state.kind): \(state.tooltip.replacingOccurrences(of: "\n", with: " / "))")
            trayKind = state.kind
        }
        let queued = status.outboxDepth > 0 ? " 📤\(status.outboxDepth)" : ""
        button.attributedTitle = NSAttributedString(string: state.title + queued, attributes: [.font: NSFont.systemFont(ofSize: 14)])
        button.toolTip = state.tooltip
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.statusJob.kick("helpers restarted") }
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
        statusJob.kick("send queued trials")
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
        Scheduler.stop()

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
