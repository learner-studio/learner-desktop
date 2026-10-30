import AppKit
import Foundation
import ServiceManagement

// MARK: - Main Application & Status Bar Manager
@MainActor
final class TrayAppManager: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var statusMenu: NSMenu!
    private var isShuttingDown = false
    nonisolated let log = Log("Tray")
    private var signalSources: [DispatchSourceSignal] = []

    let homeDir = NSHomeDirectory()
    let talkMonitor = SpeakingCoach.shared

    /// Collected off the main thread by the Status job; the tray and menu only read it.
    var status = AppStatus()
    private var trayKind = ""
    private var trayTitle = NSAttributedString()
    private var trayTooltip = ""
    private let stallWatch = MainThreadWatch()
    /// Every link and folder the menu opens goes through here (tests watch it).
    var openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    var cuePanels: [CuePhase: (CueSubmenuView, NSMenu)] = [:]
    private lazy var statusJob = Job("Status", period: 8, backoff: Backoff(base: 8, max: 60), quiet: true) { [weak self] _ in
        guard let self = self else { return .idle }
        let (previous, helpers, uploaderActive, speechProblem) = DispatchQueue.main.sync {
            (self.status, self.uploader.map { [$0] } ?? [], self.uploader != nil,
             (self.talkMonitor.speech as? MicSpeechSource)?.problem)
        }
        let next = StatusProbe.collect(previous: previous, helpers: helpers, appAgentPlist: self.appAgentPlist,
                                       uploaderActive: uploaderActive, extraProblems: speechProblem.map { [Problem(source: "Speech", text: $0)] } ?? [])
        if let appVersion = ScreenpipeUpdateCheck.installedAppVersion() {
            CaptureEnvironment.screenpipeAppVersion = appVersion
        }
        DispatchQueue.main.async {
            self.ensureScreenpipeSkipsSignIn()
            self.apply(next)
        }
        return .ok("collected")
    }

    /// The app's own LaunchAgent. If it is switched off in System Settings -> Login Items,
    /// launchd skips it at login, so a manual start
    /// does not survive the next reboot. Only the owner can re-allow it there.
    let appAgentPlist = NSHomeDirectory() + "/Library/LaunchAgents/com.benpollack.learner-desktop.plist"

    // No SSH tunnel any more: it only carried GrowthBook's UI, whose page then could not
    // reach its API (see GrowthBookLink). Everything goes over HTTPS.

    /// Uploads Codex and Claude Code sessions when learner-server runs on another machine.
    lazy var uploader: ManagedHelper? = CLISessions.helper(key: { LearnerRPC.shared.key() })

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
            source.setEventHandler { [weak self] in
                self?.log.info("received \(sig == SIGTERM ? "SIGTERM" : "SIGINT"); quitting")
                NSApplication.shared.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    var handledPavlokRequests = Set<String>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // First, before anything talks to learner-server: a pairing file the server's installer
        // (or its operator) left pins the server URL and client id and puts the key in the
        // Keychain. Only when one is there, so a normal launch waits for nothing.
        if !Paths.underTest { Pairing.importPayload(transport: URLSessionTransport()) }

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

        uploader?.start()

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
        stallWatch.start()
        talkMonitor.start()
        ChatAndOutboxJobs.install(heartbeat: { [weak self] in self?.heartbeatInput() ?? [:] })
        // The server says where its pieces are; a changed endpointsVersion in a heartbeat
        // reply refetches them, and the uploader follows the topology they report.
        PairingLink.shared.follow(OutboxSender.shared, rpc: .shared) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyTopology() } }
        }
        startMastery()
        Scheduler.start()
        // The cue panels are slow to build (see cuePanel): ready before the first click.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            for phase in CuePhase.allCases { _ = self?.cuePanel(phase) }
        }
    }

    /// Main thread: swap in a fresh status and redraw the tray.
    func apply(_ next: AppStatus) {
        status = next
        updateTrayButton()
    }

    /// Draws from the last status snapshot (no I/O), then refreshes it in the background.
    func menuWillOpen(_ menu: NSMenu) {
        stallWatch.menu(open: true)
        // How long the click waited before AppKit asked for the menu, then the build.
        let waited = NSApp.currentEvent.map { ProcessInfo.processInfo.systemUptime - $0.timestamp } ?? 0
        let started = Date()
        rebuildMenu()
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if ms > 100 || waited > 0.3 { log.warn("menu opened \(Int(waited * 1000)) ms after the click, built in \(ms) ms") }
        statusJob.kick("menu opened")
        PavlokController.shared.updateConnectionStatus()
    }

    func menuDidClose(_ menu: NSMenu) { stallWatch.menu(open: false) }

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
        if let moved = PairingLink.shared.moved {
            add("   ⚠️ learner-server says its API moved to \(moved)")
            _ = add("   Switch to \(URL(string: moved)?.host ?? moved)...", #selector(switchToAdvertisedServer))
        }
        add("   └─ 📤 \(status.outboxDepth) queued | last: \(outbox.lastStatus)")
        if status.archiveParked > 0 { add("   ⚠️ \(status.archiveParked) chat(s) refused by the server (see menubar.log)") }
        add(status.cliSessions.map { "💻 CLI sessions (uploader): \($0)" } ?? "💻 CLI sessions: read by learner-server on this Mac")
        for p in status.problems { add("   \(p.waiting ? "⏳" : "⚠️") \(p.source): \(p.text)") }
        add("   ⚡ Send Queued Trials Now", #selector(triggerHabitSync))
        if status.loginItemBlocked {
            _ = add("   ⚠️ Won't start at login: allow Learner Desktop in Login Items...", #selector(openLoginItemsSettings))
        }
        statusMenu.addItem(NSMenuItem.separator())

        addMasterySection()

        // --- Habit Experiments & GrowthBook ---
        header("📊 Habit Experiments (GrowthBook)")
        let mode = HabitExperimentManager.shared.currentMode
        let assignedArm = HabitExperimentManager.shared.resolveArm(for: talkMonitor.activeSessionId)
        _ = add("   🎯 Condition: \(mode.shortTag) [Active: \(assignedArm)]")
        add("   📈 Recorded Trials: \(status.trialCount)")
        // Links the server advertises; a missing one has no line.
        if let growthbook = GrowthBookLink.current {
            _ = add("   🌐 Open GrowthBook Dashboard (\(growthbook.host ?? growthbook.absoluteString))...", #selector(openGrowthBookDashboard))
        }
        if let web = PairingLink.shared.held?.web, let host = URL(string: web)?.host {
            _ = add("   🌐 Open Learner (\(host))...", #selector(openLearnerWeb))
        }
        statusMenu.addItem(NSMenuItem.separator())

        statusMenu.addItem(pavlokMenuItem())

        // --- Settings ---
        let settings = NSMenu()
        addCoachSettings(to: settings)
        add("\(MasteryFeed.shared.holdDuringCalls ? "✓" : "○") Mastery: Hold While I'm in a Call",
            #selector(toggleMasteryCallHold), to: settings)
        let browserMenu = NSMenu()
        for browser in ChromiumBrowser.all {
            add("\(ChromiumBrowser.selected.id == browser.id ? "✓ " : "   ")\(browser.name)", #selector(selectVaultBrowser(_:)), to: browserMenu).representedObject = browser.id
        }
        add("Sign AI Vault In From", to: settings).submenu = browserMenu
        if let endpoints = PairingLink.shared.held {
            // The server says where it runs: shown, not a choice.
            add(endpoints.uploaderRequired ? "   learner-server runs on another machine (uploader on)" : "   learner-server runs on this Mac (no uploader)",
                to: settings)
        } else {
            add(CLISessions.serverOnThisMac ? "✓ learner-server runs on this Mac (no uploader)" : "○ learner-server runs on another machine (uploader on)",
                #selector(toggleServerOnThisMac), to: settings)
        }
        let settingsParent = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsParent.submenu = settings
        statusMenu.addItem(settingsParent)

        // --- Troubleshooting ---
        let trouble = NSMenu()
        trouble.autoenablesItems = false
        _ = add("Open AI Vault Folder...", #selector(openVaultFolder), to: trouble)
        _ = add("Open Screenpipe Recordings...", #selector(openScreenpipeData), to: trouble)
        _ = add("View App Log...", #selector(openAppLog), to: trouble)
        _ = add("View screenpipe Update Checks...", #selector(openUpdateCheckLogs), to: trouble)
        trouble.addItem(NSMenuItem.separator())
        let checking = ScreenpipeUpdateCheck.shared.isRunning
        _ = add(checking ? "🔄 Update check running..." : "🔄 Run screenpipe Update Check Now",
                checking ? nil : #selector(runScreenpipeUpdateCheck), to: trouble)
        if let last = ScreenpipeUpdateCheck.shared.lastRunSummary {
            _ = add("   └─ Last check: \(last)", to: trouble)
        }
        if uploader != nil { _ = add("Restart CLI Uploader", #selector(restartUploader), to: trouble) }
        let troubleParent = NSMenuItem(title: "Troubleshooting", action: nil, keyEquivalent: "")
        troubleParent.submenu = trouble
        statusMenu.addItem(troubleParent)

        statusMenu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit Learner Desktop", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }

    /// recordAppHeartbeat input (contract/desktop.ts, RecordAppHeartbeatInput).
    nonisolated func heartbeatInput() -> [String: Any] {
        let current = DispatchQueue.main.sync { status }
        return TrayAppManager.heartbeat(
            current, appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            screenpipeVersion: CaptureEnvironment.screenpipeVersion, capturePhase: CaptureEnvironment.capturePhase,
            lastSentAt: OutboxSender.shared.lastSentAt, lastExport: VaultExport.shared.lastRun,
            outboxStatus: OutboxSender.shared.lastStatus,
            pairing: PairingLink.shared.report(apiUrlInUse: LearnerAPI.baseURL, services: [("screenpipe", "http://localhost:3030")]))
    }

    /// recordAppHeartbeat input (contract/desktop.ts, RecordAppHeartbeatInput), from a status
    /// snapshot. Pure, so the light lane checks it against the contract.
    nonisolated static func heartbeat(_ s: AppStatus, appVersion: String, screenpipeVersion: String?, capturePhase: String?,
                          lastSentAt: Date?, lastExport: Date?, outboxStatus: String, pairing: [String: Any]? = nil,
                          clientId: String = LearnerAPI.clientId) -> [String: Any] {
        let captureState: String
        switch s.capture {
        case .recording: captureState = "recording"
        case .degraded: captureState = "paused"
        case .unknown, .stopped: captureState = "stopped"
        }
        let iso = ISO8601DateFormatter()
        return [
            "clientId": clientId,
            "appVersion": appVersion,
            "screenpipeVersion": screenpipeVersion as Any? ?? NSNull(),
            "captureState": captureState,
            "outboxDepth": s.outboxDepth,
            "lastSentAt": lastSentAt.map { iso.string(from: $0) } as Any? ?? NSNull(),
            "lastVaultExportAt": lastExport.map { iso.string(from: $0) } as Any? ?? NSNull(),
            "detail": ["capture": StatusProbe.describe(s.capture), "outboxStatus": outboxStatus,
                       "problems": s.problems.map { "\($0.source): \($0.text)" },
                       "capturePhase": capturePhase as Any? ?? NSNull()],
        ].merging(pairing.map { ["pairing": $0] } ?? [:]) { a, _ in a }
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
        let log = self.log
        DispatchQueue.global(qos: .utility).async {
            guard let started = ChildProcess.commandLine(pid, includeEnvironment: true),
                  !started.contains("SCREENPIPE_SKIP_ONBOARDING=1"),
                  // Signed out, screenpipe never starts its server. One that answers is (or
                  // can be) recording, and quitting it would only drop it to search-only.
                  HTTPProbe.get(StatusProbe.screenpipeURL + "/health").status == 0 else { return }
            log.warn("screenpipe started without SCREENPIPE_SKIP_ONBOARDING, so it is waiting for a sign-in; relaunching it with the flag")
            // A normal quit: screenpipe handles no termination signals, so a signal could
            // leave its database mid-write.
            _ = screenpipe.terminate()
            let deadline = Date().addingTimeInterval(30)
            while kill(pid, 0) == 0 && Date() < deadline { usleep(200_000) }
            if kill(pid, 0) == 0 {
                // Still there: it went to search-only instead of exiting. Reopening is
                // screenpipe's own way back, and resumes recording.
                log.warn("screenpipe did not quit within 30 s; reopening it instead")
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.environment = ["SCREENPIPE_SKIP_ONBOARDING": "1"]
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/screenpipe.app"),
                                               configuration: config) { _, error in
                if let error = error { log.error("screenpipe relaunch failed: \(error.localizedDescription)") }
                else { log.info("screenpipe relaunched with SCREENPIPE_SKIP_ONBOARDING") }
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
        // Each change to the button is a round trip to the menu bar (ControlCenter draws
        // status items): only send what changed.
        let title = NSAttributedString(string: state.title + queued, attributes: [.font: NSFont.systemFont(ofSize: 14)])
        if title != trayTitle { button.attributedTitle = title; trayTitle = title }
        if state.tooltip != trayTooltip { button.toolTip = state.tooltip; trayTooltip = state.tooltip }
    }

    @objc func selectVaultBrowser(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let browser = ChromiumBrowser.all.first(where: { $0.id == id }) else { return }
        ChromiumBrowser.selected = browser
        rebuildMenu()
    }

    @objc func toggleServerOnThisMac() {
        CLISessions.serverOnThisMac.toggle()
        applyTopology()
    }

    /// Runs the CLI uploader exactly when learner-server is on another machine (what the
    /// server reports, else the setting).
    func applyTopology() {
        let needed = !CLISessions.serverOnThisMac
        if needed, uploader == nil {
            uploader = CLISessions.helper(key: { LearnerRPC.shared.key() })
            uploader?.start()
        } else if !needed, let running = uploader {
            uploader = nil
            DispatchQueue.global(qos: .userInitiated).async { running.stop(grace: 5) }
        } else {
            return
        }
        statusJob.kick("uploader \(needed ? "started" : "stopped") for where learner-server runs")
    }

    @objc func openLearnerWeb() {
        guard let web = PairingLink.shared.held?.web, let url = URL(string: web) else { return }
        _ = openURL(url)
    }

    /// learner-server advertises its API at another URL: switching sends the device key there,
    /// so only on the owner's word. Pins it and restarts the app onto it.
    @objc func switchToAdvertisedServer() {
        guard let moved = PairingLink.shared.moved else { return }
        let alert = NSAlert()
        alert.messageText = "Switch learner-server?"
        alert.informativeText = "learner-server now says its API is at\n\(moved)\n\nThis app uses \(LearnerAPI.baseURL). Switching sends this Mac's device key to the new address and restarts Learner Desktop."
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Pairing.pin(apiUrl: moved, clientId: LearnerAPI.clientId)
        log.info("switching learner-server to \(moved) at the owner's word; restarting")
        _ = ChildProcess.run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/com.benpollack.learner-desktop"], timeout: 10)
    }

    @objc func signInToVault(_ sender: NSMenuItem) {
        guard let provider = sender.representedObject as? String else { return }
        VaultSignIn.start(provider)
    }

    @objc func pullVaultChats() {
        VaultExport.shared.runNow()
        rebuildMenu()
    }

    @objc func restartUploader() {
        uploader?.restart()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.statusJob.kick("uploader restarted") }
    }

    @objc func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    @objc func openVaultFolder() {
        _ = openURL(URL(fileURLWithPath: Paths.vault))
    }

    @objc func openScreenpipeData() {
        _ = openURL(URL(fileURLWithPath: homeDir + "/.screenpipe/data"))
    }

    @objc func triggerHabitSync() {
        OutboxSender.shared.sendNow()
        statusJob.kick("send queued trials")
    }

    @objc func openGrowthBookDashboard() {
        guard let url = GrowthBookLink.current else {
            log.warn("no GrowthBook link: learner-server publishes none")
            return
        }
        log.info("opening GrowthBook at \(url.absoluteString)")
        _ = openURL(url)
    }

    @objc func runScreenpipeUpdateCheck() {
        let version = ScreenpipeUpdateCheck.installedAppVersion() ?? "unknown"
        ScreenpipeUpdateCheck.shared.start(reason: "Manual check of screenpipe \(version), requested from the Learner Desktop menu")
    }

    @objc func openUpdateCheckLogs() {
        let dir = ScreenpipeUpdateCheck.shared.logDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        _ = openURL(URL(fileURLWithPath: dir))
    }

    @objc func openAppLog() {
        if !openURL(URL(fileURLWithPath: AppLog.path)) { log.warn("could not open \(AppLog.path)") }
    }

    /// Clean shutdown. Every exit path (menu Quit, SIGTERM from launchctl, Cmd-Q) lands
    /// here. We finalise the in-flight turn, push everything unsynced to Postgres while
    /// close SQLite, and only then let the process exit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isShuttingDown { return .terminateNow }
        isShuttingDown = true

        // Done on the main thread: the app is quitting, so blocking its UI is fine, and it
        // avoids the .terminateLater/reply handshake, which was seen to finish the work and
        // then never exit. What is left unsent stays in SQLite for the next launch.
        Scheduler.stop()
        let (coach, uploader) = (talkMonitor, self.uploader)
        Shutdown.run(TrayAppManager.shutdownSteps(
            // Runs on the calling thread, which is main.
            finishTurn: { MainActor.assumeIsolated { coach.resetStreak() } }, logger: HabitEventLogger.shared,
            drain: { OutboxSender.shared.drain(until: $0) }, stopJobs: { ChatAndOutboxJobs.stopForQuit() },
            stopHelpers: { uploader?.stop(grace: 1.5) }), total: 18)
        return .terminateNow
    }

    /// The quit sequence. Order matters: queued trials are written, then sent, and only then
    /// is the database closed (closing first strands them until the next launch).
    nonisolated static func shutdownSteps(finishTurn: @escaping @Sendable () -> Void, logger: HabitEventLogger,
                                          drain: @escaping @Sendable (Date) -> Int, stopJobs: @escaping @Sendable () -> Void,
                                          stopHelpers: @escaping @Sendable () -> Void) -> [Shutdown.Step] {
        [
            .init(name: "finish the current turn", budget: 2, onCallingThread: true) { _ in finishTurn(); return nil },
            .init(name: "write queued trials", budget: 3) { _ in logger.waitUntilIdle(); return nil },
            .init(name: "send queued trials", budget: 10) { deadline in "\(drain(deadline)) left for next launch" },
            .init(name: "close the trial database", budget: 2) { _ in logger.close(); return nil },
            .init(name: "stop the export and update check", budget: 1) { _ in stopJobs(); return nil },
            .init(name: "stop the helpers", budget: 3) { _ in stopHelpers(); return nil },
        ]
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
