import AppKit
import Foundation
import ServiceManagement
import SQLite3
import CoreBluetooth
import WebKit

// MARK: - Logging

/// Every `print` in the app goes through here (it shadows Swift.print in this module).
/// Lines get a timestamp, and a line that repeats within 10 minutes (numbers ignored) is
/// held back and counted, so a retry loop -- a Bluetooth band out of range, the mic gain
/// guard -- costs one line per 10 minutes instead of thousands. The app's own log file
/// is rotated by AppLog.
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    AppLog.write(items.map { "\($0)" }.joined(separator: separator), terminator: terminator)
}

enum AppLog {
    static let path = NSHomeDirectory() + "/.ai-aggregator/logs/menubar.log"
    static let maxBytes: UInt64 = 10_000_000
    static let repeatWindow: TimeInterval = 600

    private static let lock = NSLock()
    private static var lastSeen: [String: (at: Date, held: Int)] = [:]
    private static var writes = 0
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Send stdout/stderr to the log file (launchd points them there too; this lets the app
    /// rotate it). Not used by the one-shot CLI modes, which print to the terminal.
    static func attachToFile() {
        rotateIfNeeded(force: false)
        freopen(path, "a", stdout)
        freopen(path, "a", stderr)
    }

    static func write(_ line: String, terminator: String) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let key = line.replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
        var text = line
        if let seen = lastSeen[key], now.timeIntervalSince(seen.at) < repeatWindow {
            lastSeen[key] = (seen.at, seen.held + 1)
            return
        } else if let seen = lastSeen[key], seen.held > 0 {
            text += "  [repeated \(seen.held)x in the previous \(Int(repeatWindow / 60)) min]"
        }
        if lastSeen.count > 2000 { lastSeen.removeAll() }
        lastSeen[key] = (now, 0)
        Swift.print("\(stamp.string(from: now)) \(text)", terminator: terminator)
        writes += 1
        if writes % 500 == 0 { rotateIfNeeded(force: false) }
    }

    /// Keep one previous file: menubar.log -> menubar.1.log once it passes maxBytes.
    static func rotateIfNeeded(force: Bool) {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
        guard force || size > maxBytes else { return }
        let old = path.replacingOccurrences(of: ".log", with: ".1.log")
        try? FileManager.default.removeItem(atPath: old)
        try? FileManager.default.moveItem(atPath: path, toPath: old)
        fflush(stdout)
        freopen(path, "a", stdout)
        freopen(path, "a", stderr)
    }

    /// Helper logs (tunnel, watcher): rotate before each launch.
    static func rotate(helperLog: String, maxBytes: UInt64 = 5_000_000) {
        let size = (try? FileManager.default.attributesOfItem(atPath: helperLog)[.size] as? UInt64) ?? 0
        guard size > maxBytes else { return }
        let old = helperLog.replacingOccurrences(of: ".log", with: ".1.log")
        try? FileManager.default.removeItem(atPath: old)
        try? FileManager.default.moveItem(atPath: helperLog, toPath: old)
    }
}

// MARK: - Screenshare-Invisible Floating Monologue Toast Alert
class MonologueToastController: NSObject {
    static let shared = MonologueToastController()

    private var panel: NSPanel?
    private var visualEffect: NSVisualEffectView?
    private var iconLabel: NSTextField?
    private var titleLabel: NSTextField?
    private var timeLabel: NSTextField?
    private var hintLabel: NSTextField?
    private var isShowing = false

    func setupPanel() {
        let width: CGFloat = 340
        let height: CGFloat = 90

        let screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
        let vf = screen.visibleFrame
        let rect = NSRect(
            x: max(20, vf.maxX - width - 24),
            y: max(20, vf.maxY - height - 24),
            width: width,
            height: height
        )

        let p = NSPanel(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        // CRITICAL: NSWindowSharingNone completely hides this window from ScreenCaptureKit,
        // Zoom, Google Meet, Microsoft Teams, Slack, OBS, and QuickTime recordings.
        p.sharingType = .none

        let ve = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        ve.material = .hudWindow
        ve.blendingMode = .behindWindow
        ve.state = .active
        ve.wantsLayer = true
        ve.layer?.cornerRadius = 18
        ve.layer?.masksToBounds = true
        ve.layer?.borderWidth = 1.0
        ve.layer?.borderColor = NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.0, alpha: 0.45).cgColor
        self.visualEffect = ve

        // Alert icon badge
        let icon = NSTextField(labelWithString: "⚠️")
        icon.frame = NSRect(x: 16, y: height - 54, width: 36, height: 36)
        icon.font = NSFont.systemFont(ofSize: 26)
        ve.addSubview(icon)
        self.iconLabel = icon

        // Close button (top right)
        let closeBtn = NSButton(frame: NSRect(x: width - 30, y: height - 28, width: 20, height: 20))
        closeBtn.title = "✕"
        closeBtn.isBordered = false
        closeBtn.bezelStyle = .inline
        closeBtn.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        closeBtn.contentTintColor = NSColor(white: 0.75, alpha: 1.0)
        closeBtn.target = self
        closeBtn.action = #selector(dismiss)
        ve.addSubview(closeBtn)

        // Title
        let title = NSTextField(labelWithString: "Speaking Coach Warning")
        title.frame = NSRect(x: 58, y: height - 30, width: width - 96, height: 18)
        title.font = NSFont.boldSystemFont(ofSize: 13)
        title.textColor = .white
        ve.addSubview(title)
        self.titleLabel = title

        // Time / Message
        let msg = NSTextField(labelWithString: "Speaking continuously for 0:30")
        msg.frame = NSRect(x: 58, y: height - 50, width: width - 74, height: 16)
        msg.font = NSFont.systemFont(ofSize: 12)
        msg.textColor = NSColor(white: 0.95, alpha: 1.0)
        ve.addSubview(msg)
        self.timeLabel = msg

        // Subtitle / Screenshare hint
        let hint = NSTextField(labelWithString: "Hidden from screenshare • Consider wrapping up")
        hint.frame = NSRect(x: 58, y: height - 72, width: width - 74, height: 16)
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = NSColor(white: 0.65, alpha: 1.0)
        ve.addSubview(hint)
        self.hintLabel = hint

        p.contentView = ve
        self.panel = p
    }

    func show(_ duration: TimeInterval, callApp: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.panel == nil {
                self.setupPanel()
            }
            self.updateTime(duration)

            let isAlert = duration >= 60.0
            self.iconLabel?.stringValue = isAlert ? "🚨" : "⚠️"
            let appSuffix = callApp != nil ? " • \(callApp!)" : ""
            self.titleLabel?.stringValue = isAlert ? "Speaking Coach Alert\(appSuffix)" : "Speaking Coach Warning\(appSuffix)"
            self.hintLabel?.stringValue = isAlert
                ? "Hidden from screenshare • Invite others to speak"
                : "Hidden from screenshare • Consider wrapping up"

            if isAlert {
                self.visualEffect?.layer?.borderColor = NSColor(calibratedRed: 1.0, green: 0.25, blue: 0.25, alpha: 0.55).cgColor
            } else {
                self.visualEffect?.layer?.borderColor = NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.0, alpha: 0.45).cgColor
            }

            guard let p = self.panel else { return }

            let screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
            let vf = screen.visibleFrame
            let width = p.frame.width
            let height = p.frame.height
            p.setFrame(
                NSRect(
                    x: max(20, vf.maxX - width - 24),
                    y: max(20, vf.maxY - height - 24),
                    width: width,
                    height: height
                ),
                display: true
            )

            if !self.isShowing {
                self.isShowing = true
                p.alphaValue = 0.0
                p.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    p.animator().alphaValue = 1.0
                }
            }
        }
    }

    func updateTime(_ duration: TimeInterval) {
        let total = max(0, Int(duration))
        let minutes = total / 60
        let seconds = total % 60
        let timeStr = String(format: "%d:%02d", minutes, seconds)
        timeLabel?.stringValue = "Speaking continuously for \(timeStr)"
    }

    @objc func dismiss() {
        hide()
    }

    func hide() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let p = self.panel, self.isShowing else { return }
            self.isShowing = false
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                p.animator().alphaValue = 0.0
            }, completionHandler: {
                p.orderOut(nil)
            })
        }
    }
}

// MARK: - Pavlok Wearable Shock & Haptic Controller (Direct Bluetooth LE + Cloud Relay)
class PavlokController: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = PavlokController()

    private let defaults = UserDefaults.standard
    let kPavlokEnabled = "pavlok_shock_enabled"
    let kPavlokToken = "pavlok_api_token"
    let kPavlokIntensity = "pavlok_shock_intensity"
    let kPavlokWarningCue = "pavlok_warning_cue"
    let kPavlokAlertCue = "pavlok_alert_cue"
    let kPavlokWarningShockIntensity = "pavlok_warning_shock_intensity"
    let kPavlokSavedWarningShockIntensity = "pavlok_saved_warning_shock_intensity"
    let kPavlokWarningVibeIntensity = "pavlok_warning_vibe_intensity"
    let kPavlokSavedWarningVibeIntensity = "pavlok_saved_warning_vibe_intensity"
    let kPavlokAlertShockIntensity = "pavlok_alert_shock_intensity"
    let kPavlokSavedAlertShockIntensity = "pavlok_saved_alert_shock_intensity"
    let kPavlokAlertVibeIntensity = "pavlok_alert_vibe_intensity"
    let kPavlokSavedAlertVibeIntensity = "pavlok_saved_alert_vibe_intensity"
    let kPavlokWarningBeepEnabled = "pavlok_warning_beep_enabled"
    let kPavlokRewardGoodBehavior = "pavlok_reward_good_behavior"
    let kPavlokCustomApiUrl = "pavlok_custom_api_url"
    // Manual bench-test intensities. Deliberately separate from the warning/alert keys
    // above: those are the experiment's stimuli and changing them mid-trial would
    // silently change the treatment. These only ever fire when a human asks them to.
    let kPavlokTestVibeIntensity = "pavlok_test_vibe_intensity"
    let kPavlokTestBeepIntensity = "pavlok_test_beep_intensity"
    let kPavlokTestZapIntensity = "pavlok_test_zap_intensity"

    var keepConnected: Bool {
        get { defaults.bool(forKey: "pavlok_keep_connected") }
        set {
            defaults.set(newValue, forKey: "pavlok_keep_connected")
            if connectionRequested { startBleScan(force: true) } else { disconnectBle() }
            onStatusChanged?()
        }
    }
    var connectionRequested: Bool { isEnabled || keepConnected }
    var canTestFire: Bool { connectionRequested }
    private var reconnectWork: DispatchWorkItem?
    private let lastDeviceKey = "pavlok_last_device_id"

    private func scheduleReconnect() {
        reconnectWork?.cancel()
        guard connectionRequested else { return }
        let work = DispatchWorkItem { [weak self] in self?.startBleScan(force: true) }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: kPavlokEnabled) } // Defaults to false
        set {
            defaults.set(newValue, forKey: kPavlokEnabled)
            if connectionRequested {
                startBleScan(force: true)
            } else {
                disconnectBle()
            }
            updateConnectionStatus()
            onStatusChanged?()
        }
    }

    var apiToken: String {
        get { defaults.string(forKey: kPavlokToken) ?? "" }
        set {
            defaults.set(newValue, forKey: kPavlokToken)
            updateConnectionStatus()
            onStatusChanged?()
        }
    }

    // --- 30s Warning Alert Modalities & Intensities ---

    var savedWarningShockIntensity: Int {
        get {
            let val = defaults.integer(forKey: kPavlokSavedWarningShockIntensity)
            return val > 0 ? val : 15
        }
        set { defaults.set(newValue, forKey: kPavlokSavedWarningShockIntensity) }
    }

    // Active 30s Shock Intensity: 0 means disabled/unselected; >0 means enabled/selected
    var warningShockIntensity: Int {
        get {
            if defaults.object(forKey: kPavlokWarningShockIntensity) == nil { return 15 } // 15% default
            return defaults.integer(forKey: kPavlokWarningShockIntensity)
        }
        set {
            let clamped = max(0, min(100, newValue))
            defaults.set(clamped, forKey: kPavlokWarningShockIntensity)
            if clamped > 0 { savedWarningShockIntensity = clamped }
            onStatusChanged?()
        }
    }

    var savedWarningVibeIntensity: Int {
        get {
            let val = defaults.integer(forKey: kPavlokSavedWarningVibeIntensity)
            return val > 0 ? val : 30
        }
        set { defaults.set(newValue, forKey: kPavlokSavedWarningVibeIntensity) }
    }

    // Active 30s Vibe Intensity: 0 means disabled/unselected (default 0); >0 means enabled/selected
    var warningVibeIntensity: Int {
        get {
            return defaults.integer(forKey: kPavlokWarningVibeIntensity)
        }
        set {
            let clamped = max(0, min(100, newValue))
            defaults.set(clamped, forKey: kPavlokWarningVibeIntensity)
            if clamped > 0 { savedWarningVibeIntensity = clamped }
            onStatusChanged?()
        }
    }

    var warningBeepEnabled: Bool {
        get { defaults.bool(forKey: kPavlokWarningBeepEnabled) }
        set {
            defaults.set(newValue, forKey: kPavlokWarningBeepEnabled)
            onStatusChanged?()
        }
    }

    // --- 60s Hard Stop Alert Modalities & Intensities ---

    var savedAlertShockIntensity: Int {
        get {
            let val = defaults.integer(forKey: kPavlokSavedAlertShockIntensity)
            if val > 0 { return val }
            let legacy = defaults.integer(forKey: kPavlokIntensity)
            return legacy > 0 ? legacy : 35
        }
        set { defaults.set(newValue, forKey: kPavlokSavedAlertShockIntensity) }
    }

    // Active 60s Shock Intensity: 0 means disabled/unselected; >0 means enabled/selected
    var alertShockIntensity: Int {
        get {
            if defaults.object(forKey: kPavlokAlertShockIntensity) == nil {
                let legacy = defaults.integer(forKey: kPavlokIntensity)
                return legacy > 0 ? legacy : 35 // 35% default
            }
            return defaults.integer(forKey: kPavlokAlertShockIntensity)
        }
        set {
            let clamped = max(0, min(100, newValue))
            defaults.set(clamped, forKey: kPavlokAlertShockIntensity)
            defaults.set(clamped, forKey: kPavlokIntensity)
            if clamped > 0 { savedAlertShockIntensity = clamped }
            onStatusChanged?()
        }
    }

    var savedAlertVibeIntensity: Int {
        get {
            let val = defaults.integer(forKey: kPavlokSavedAlertVibeIntensity)
            return val > 0 ? val : 60
        }
        set { defaults.set(newValue, forKey: kPavlokSavedAlertVibeIntensity) }
    }

    // Active 60s Vibe Intensity: 0 means disabled/unselected (default 0); >0 means enabled/selected
    var alertVibeIntensity: Int {
        get {
            return defaults.integer(forKey: kPavlokAlertVibeIntensity)
        }
        set {
            let clamped = max(0, min(100, newValue))
            defaults.set(clamped, forKey: kPavlokAlertVibeIntensity)
            if clamped > 0 { savedAlertVibeIntensity = clamped }
            onStatusChanged?()
        }
    }

    // --- Manual Test-Fire Intensities (bench check that the wristband is alive) ---
    //
    // Each modality carries its own persisted 0-100% level. They are read only by
    // testFire(type:) below, which is only ever reached from a human clicking a menu
    // item or running --pavlok-test-fire; nothing automatic touches them.

    var testVibeIntensity: Int {
        get {
            if defaults.object(forKey: kPavlokTestVibeIntensity) == nil { return 40 }
            return max(0, min(100, defaults.integer(forKey: kPavlokTestVibeIntensity)))
        }
        set {
            defaults.set(max(0, min(100, newValue)), forKey: kPavlokTestVibeIntensity)
            onStatusChanged?()
        }
    }

    var testBeepIntensity: Int {
        get {
            if defaults.object(forKey: kPavlokTestBeepIntensity) == nil { return 40 }
            return max(0, min(100, defaults.integer(forKey: kPavlokTestBeepIntensity)))
        }
        set {
            defaults.set(max(0, min(100, newValue)), forKey: kPavlokTestBeepIntensity)
            onStatusChanged?()
        }
    }

    var testZapIntensity: Int {
        get {
            // Low by default. This one hurts, and the first thing a new user does with a
            // test button is press it.
            if defaults.object(forKey: kPavlokTestZapIntensity) == nil { return 10 }
            return max(0, min(100, defaults.integer(forKey: kPavlokTestZapIntensity)))
        }
        set {
            defaults.set(max(0, min(100, newValue)), forKey: kPavlokTestZapIntensity)
            onStatusChanged?()
        }
    }

    func testIntensity(for type: String) -> Int {
        switch type {
        case "vibe": return testVibeIntensity
        case "beep": return testBeepIntensity
        case "zap": return testZapIntensity
        default: return 0
        }
    }

    func setTestIntensity(_ value: Int, for type: String) {
        switch type {
        case "vibe": testVibeIntensity = value
        case "beep": testBeepIntensity = value
        case "zap": testZapIntensity = value
        default: break
        }
    }

    static func testFireLabel(for type: String) -> String {
        switch type {
        case "vibe": return "📳 Vibration"
        case "beep": return "🔔 Beep"
        case "zap": return "⚡ Zap"
        default: return type
        }
    }

    /// Outcome of the most recent manual test fire, for display in the menu. Held in
    /// memory only -- a stale "delivered" line from three days ago is worse than none.
    struct TestFireResult {
        let type: String
        let intensity: Int
        let success: Bool
        let detail: String
        let at: Date

        var transport: String {
            if detail.contains("BLE") { return "Direct Bluetooth" }
            if detail.hasPrefix("HTTP") { return "Pavlok Cloud" }
            return "not sent"
        }

        var menuLine: String {
            let stamp = TestFireResult.stampFormatter.string(from: at)
            let mark = success ? "✅" : "❌"
            let label = PavlokController.testFireLabel(for: type)
            return "\(mark) \(label) \(intensity)% • \(transport) • \(detail) • \(stamp)"
        }

        private static let stampFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            return f
        }()
    }

    private(set) var isTestFiring = false
    private(set) var lastTestFire: TestFireResult?

    var lastTestFireSummary: String {
        guard let r = lastTestFire else { return "no test fired yet this session" }
        return r.menuLine
    }

    var testFireSummary: String {
        func part(_ emoji: String, _ level: Int) -> String {
            return level > 0 ? "\(emoji) \(level)%" : "\(emoji) off"
        }
        return [part("📳", testVibeIntensity), part("🔔", testBeepIntensity), part("⚡", testZapIntensity)]
            .joined(separator: " • ")
    }

    func interventionAudit(type: String, intensity: Int, reason: String,
                                   id: String, manual: Bool) -> (String, Bool?, String?) -> Void {
        let session = manual ? "manual_test_" + id : TalkTimeMonitor.shared.activeSessionId
        let arm = manual ? "manual_test" : HabitExperimentManager.shared.resolveArm(for: session)
        let callApp = manual ? "Manual device test" : TalkTimeMonitor.shared.activeCallApp
        let started = Date()
        return { phase, success, detail in
            let acknowledged = success == true && detail == "BLE acknowledged by wristband"
            HabitEventLogger.shared.logTurn(
                habitType: "pavlok_intervention", sessionId: session, callApp: callApp,
                callCategory: manual ? "device_test" : "work", treatmentArm: arm,
                turnDurationSec: 0, wordsSpoken: 0, warningFiredAt: nil,
                shockFiredAt: nil, latencyToYieldSec: nil, breached30s: false,
                breached60s: false, wasRewarded: false,
                metadata: [
                    "source": "pavlok_controller_v1", "operation_id": id,
                    "manual_test": manual, "phase": phase, "modality": type,
                    "intensity_percent": intensity, "reason": reason,
                    "requested_at": ISO8601DateFormatter().string(from: started),
                    "elapsed_ms": Date().timeIntervalSince(started) * 1000,
                    "success": success as Any? ?? NSNull(),
                    "device_acknowledged": acknowledged,
                    "detail": detail as Any? ?? NSNull(),
                    "device_name": self.bleDeviceName as Any? ?? NSNull(),
                    "device_id": self.activePeripheral?.identifier.uuidString as Any? ?? NSNull(),
                    "battery_percent": self.batteryLevel as Any? ?? NSNull(),
                    "bluetooth_connected": self.isBleConnected,
                    "transport": (detail?.contains("BLE") == true ? "bluetooth" :
                        (detail?.hasPrefix("HTTP") == true ? "cloud" : "none"))
                ])
            // Persist before handing completion back or exiting a headless test.
            HabitEventLogger.shared.waitUntilIdle()
        }
    }

    /// Fire one stimulus at its configured test intensity, right now, because a human
    /// asked. Reports back on the main thread so the caller can put the outcome on screen.
    func testFire(type: String, operationID: String? = nil, intensityOverride: Int? = nil, completion: ((Bool, String) -> Void)? = nil) {
        let auditID = operationID ?? UUID().uuidString.lowercased()
        let audit = interventionAudit(type: type, intensity: intensityOverride ?? testIntensity(for: type),
                                      reason: "Manual test fire", id: auditID, manual: true)
        audit("requested", nil, nil)
        guard !isTestFiring else {
            audit("result", false, "A test is already in progress")
            completion?(false, "A test is already in progress")
            return
        }
        let intensity = max(0, min(100, intensityOverride ?? testIntensity(for: type)))
        let label = PavlokController.testFireLabel(for: type)

        func finish(_ ok: Bool, _ detail: String) {
            audit("result", ok, detail)
            let result = TestFireResult(type: type, intensity: intensity, success: ok,
                                        detail: detail, at: Date())
            DispatchQueue.main.async {
                self.isTestFiring = false
                self.lastTestFire = result
                print("[Pavlok TestFire] \(result.menuLine)")
                fflush(stdout)
                completion?(ok, detail)
                self.onStatusChanged?()
            }
        }

        guard canTestFire else {
            finish(false, "Bluetooth connection is switched off")
            return
        }
        guard intensity > 0 else {
            // 0% is "off" everywhere else in this controller; sendStimulus would clamp it
            // up to 1% and buzz the wrist anyway.
            finish(false, "\(label) intensity is 0%")
            return
        }

        isTestFiring = true
        onStatusChanged?()
        if !isBleConnected && !isBleScanning {
            startBleScan(force: true)
        }
        // Wait for the selected characteristic, not merely the connection callback.
        // Common modes keep discovery/test feedback moving while an NSMenu is open.
        let deadline = Date().addingTimeInterval(15)
        let timer = Timer(timeInterval: 0.15, repeats: true) { timer in
            guard self.canTestFire else {
                timer.invalidate()
                finish(false, "Bluetooth connection is switched off")
                return
            }
            if self.isReadyForStimulus(type) {
                timer.invalidate()
                self.sendStimulus(type: type, value: intensity,
                                  reason: "Manual test fire from Learner Desktop menu", allowCloud: false, auditID: auditID) { ok, msg in
                    finish(ok, msg ?? "no response")
                }
            } else if Date() >= deadline {
                timer.invalidate()
                finish(false, "Bluetooth connection not ready; reconnecting in background.")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    func isReadyForStimulus(_ type: String) -> Bool {
        guard isBleConnected else { return false }
        switch type {
        case "vibe": return vibeCharacteristic != nil
        case "beep": return beepCharacteristic != nil
        case "zap": return shockCharacteristic != nil
        default: return false
        }
    }

    // Backward-compatibility bridge for existing references to shockIntensity
    var shockIntensity: Int {
        get { alertShockIntensity }
        set { alertShockIntensity = newValue }
    }

    // Backward-compatibility computed bridges for cue string identifiers
    var warningCue: String {
        get {
            if warningShockIntensity > 0 && warningVibeIntensity > 0 { return "both" }
            if warningShockIntensity > 0 { return "shock" }
            if warningVibeIntensity > 0 { return "vibe" }
            if warningBeepEnabled { return "beep" }
            return "none"
        }
        set {
            switch newValue {
            case "shock":
                warningShockIntensity = (savedWarningShockIntensity > 0 ? savedWarningShockIntensity : 15)
                warningVibeIntensity = 0
                warningBeepEnabled = false
            case "vibe":
                warningShockIntensity = 0
                warningVibeIntensity = (savedWarningVibeIntensity > 0 ? savedWarningVibeIntensity : 30)
                warningBeepEnabled = false
            case "both":
                warningShockIntensity = (savedWarningShockIntensity > 0 ? savedWarningShockIntensity : 15)
                warningVibeIntensity = (savedWarningVibeIntensity > 0 ? savedWarningVibeIntensity : 30)
                warningBeepEnabled = false
            case "beep":
                warningShockIntensity = 0
                warningVibeIntensity = 0
                warningBeepEnabled = true
            case "none":
                warningShockIntensity = 0
                warningVibeIntensity = 0
                warningBeepEnabled = false
            default:
                break
            }
        }
    }

    var alertCue: String {
        get {
            if alertShockIntensity > 0 && alertVibeIntensity > 0 { return "both" }
            if alertShockIntensity > 0 { return "shock" }
            if alertVibeIntensity > 0 { return "vibe" }
            return "none"
        }
        set {
            switch newValue {
            case "shock":
                alertShockIntensity = (savedAlertShockIntensity > 0 ? savedAlertShockIntensity : 35)
                alertVibeIntensity = 0
            case "vibe":
                alertShockIntensity = 0
                alertVibeIntensity = (savedAlertVibeIntensity > 0 ? savedAlertVibeIntensity : 60)
            case "both":
                alertShockIntensity = (savedAlertShockIntensity > 0 ? savedAlertShockIntensity : 35)
                alertVibeIntensity = (savedAlertVibeIntensity > 0 ? savedAlertVibeIntensity : 60)
            case "none":
                alertShockIntensity = 0
                alertVibeIntensity = 0
            default:
                break
            }
        }
    }

    // Multi-Select Modality Toggles (Direction: Selection -> Intensity)
    func toggle30sShock() {
        if warningShockIntensity > 0 {
            warningShockIntensity = 0
        } else {
            warningShockIntensity = (savedWarningShockIntensity > 0 ? savedWarningShockIntensity : 15)
        }
    }

    func toggle30sVibe() {
        if warningVibeIntensity > 0 {
            warningVibeIntensity = 0
        } else {
            warningVibeIntensity = (savedWarningVibeIntensity > 0 ? savedWarningVibeIntensity : 30)
        }
    }

    func toggle30sBeep() {
        warningBeepEnabled.toggle()
    }

    func toggle60sShock() {
        if alertShockIntensity > 0 {
            alertShockIntensity = 0
        } else {
            alertShockIntensity = (savedAlertShockIntensity > 0 ? savedAlertShockIntensity : 35)
        }
    }

    func toggle60sVibe() {
        if alertVibeIntensity > 0 {
            alertVibeIntensity = 0
        } else {
            alertVibeIntensity = (savedAlertVibeIntensity > 0 ? savedAlertVibeIntensity : 60)
        }
    }

    let rewardVibeIntensity = 30

    // Good behavior: deliver gentle vibration reward when yielding floor under 30s
    var rewardGoodBehavior: Bool {
        get {
            if defaults.object(forKey: kPavlokRewardGoodBehavior) == nil { return true }
            return defaults.bool(forKey: kPavlokRewardGoodBehavior)
        }
        set {
            defaults.set(newValue, forKey: kPavlokRewardGoodBehavior)
            onStatusChanged?()
        }
    }

    // Backward-compatibility bridge
    var vibrateOnWarning: Bool {
        get { warningVibeIntensity > 0 }
        set { if newValue { toggle30sVibe() } else { warningVibeIntensity = 0 } }
    }

    // Descriptive UI summaries derived directly from multi-select intensities
    var warningCueSummary: String {
        var parts: [String] = []
        if warningShockIntensity > 0 {
            parts.append("⚡ Shock \(warningShockIntensity)%")
        }
        if warningVibeIntensity > 0 {
            parts.append("📳 Vibe \(warningVibeIntensity)%")
        }
        if warningBeepEnabled {
            parts.append("🔔 Beep")
        }
        if parts.isEmpty {
            return "⚪ 0% (Silent / Toast Only)"
        }
        return parts.joined(separator: " + ")
    }

    var alertCueSummary: String {
        var parts: [String] = []
        if alertShockIntensity > 0 {
            parts.append("⚡ Shock \(alertShockIntensity)%")
        }
        if alertVibeIntensity > 0 {
            parts.append("📳 Vibe \(alertVibeIntensity)%")
        }
        if parts.isEmpty {
            return "⚪ 0% (Silent / Toast Only)"
        }
        return parts.joined(separator: " + ")
    }

    var presetSummary: String {
        let warnShock = warningShockIntensity > 0
        let warnVibe = warningVibeIntensity > 0
        let alertShock = alertShockIntensity > 0
        let alertVibe = alertVibeIntensity > 0

        if warnShock && !warnVibe && alertShock && !alertVibe {
            return "Both Shock (Default)"
        } else if !warnShock && warnVibe && !alertShock && alertVibe {
            return "Both Vibration"
        } else if !warnShock && warnVibe && alertShock && !alertVibe {
            return "Vibe (30s) + Shock (60s)"
        } else if warnShock && !warnVibe && !alertShock && alertVibe {
            return "Shock (30s) + Vibe (60s)"
        } else if (warnShock || warnVibe) && (alertShock || alertVibe) && (warnShock && warnVibe || alertShock && alertVibe) {
            return "Dual Shock + Vibe"
        } else if !warnShock && !warnVibe && !alertShock && !alertVibe {
            return "All 0% (Silent)"
        } else {
            return "Custom Multi-Select"
        }
    }

    var customApiUrl: String? {
        get { defaults.string(forKey: kPavlokCustomApiUrl) }
        set {
            defaults.set(newValue, forKey: kPavlokCustomApiUrl)
            updateConnectionStatus()
        }
    }

    var stimulusEndpoint: String {
        return customApiUrl ?? "https://api.pavlok.com/api/v5/stimulus/send"
    }

    var userEndpoint: String {
        if let custom = customApiUrl {
            return custom.replacingOccurrences(of: "/stimulus/send", with: "/user/")
        }
        return "https://api.pavlok.com/api/v5/user/"
    }

    /// Log every advertising peripheral the discovery filter rejects. Off by default --
    /// at a busy desk this is dozens of lines a second -- and turned on by
    /// `--pavlok-test-fire ... --trace-ble` when a connection will not come up.
    static var traceBleDiscovery = false
    private var tracedPeripherals = Set<UUID>()

    // CoreBluetooth Low Energy State
    private var centralManager: CBCentralManager?
    private(set) var activePeripheral: CBPeripheral?
    private(set) var shockCharacteristic: CBCharacteristic?
    private(set) var vibeCharacteristic: CBCharacteristic?
    private(set) var beepCharacteristic: CBCharacteristic?
    private(set) var batteryCharacteristic: CBCharacteristic?
    private(set) var batteryLevel: Int?

    private(set) var isBleConnected: Bool = false
    private(set) var isBleScanning: Bool = false
    private(set) var bleDeviceName: String?
    private(set) var isOnline: Bool = false

    var onStatusChanged: (() -> Void)?

    var connectionStatusText: String {
        if !connectionRequested {
            return "⚪ Disabled (Safe Default)"
        }
        if isBleConnected {
            let dev = bleDeviceName ?? "Pavlok 3"
            let batt = batteryLevel.map { " • \($0)% 🔋" } ?? ""
            return "🟢 Connected (\(dev) via Bluetooth\(batt) • <15ms)"
        }
        if isBleScanning {
            return "🔵 Searching for Bluetooth Wristband..."
        }
        if !apiToken.isEmpty && isOnline {
            return "🟡 Online (Cloud Relay Backup • ~400ms)"
        }
        if !apiToken.isEmpty {
            return "🟡 Cloud Configured (Bluetooth Disconnected)"
        }
        return "🔴 Bluetooth Disconnected (Turn on Pavlok)"
    }

    override init() {
        super.init()
        if defaults.object(forKey: kPavlokEnabled) == nil {
            defaults.set(false, forKey: kPavlokEnabled)
        }
        // Bluetooth is only touched once Pavlok is actually enabled. Creating a
        // CBCentralManager is what triggers macOS's "would like to use Bluetooth" prompt,
        // and with an ad-hoc-signed binary that prompt returned after every rebuild --
        // for a feature that was switched off.
        if connectionRequested {
            startBleScan()
        }
        updateConnectionStatus()
    }

    func startBleScan(force: Bool = false) {
        guard connectionRequested else { return }
        if let peripheral = activePeripheral,
           peripheral.state == .connected || peripheral.state == .connecting { return }
        reconnectWork?.cancel()
        if centralManager == nil {
            // Lazily created on first use. The scan itself starts from
            // centralManagerDidUpdateState once the radio reports poweredOn.
            centralManager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
            return
        }
        guard let central = centralManager, central.state == .poweredOn else { return }
        if central.isScanning && !force { return }
        central.stopScan()
        isBleScanning = true
        print("[Pavlok BLE] Scanning for Pavlok Bluetooth devices...")
        fflush(stdout)
        let service = CBUUID(string: "156E1000-A300-4FEA-897B-86F698D74461")
        if let connected = central.retrieveConnectedPeripherals(withServices: [service]).first {
            centralManager(central, didDiscover: connected,
                           advertisementData: [CBAdvertisementDataServiceUUIDsKey: [service]], rssi: 0)
            return
        }
        if let stored = defaults.string(forKey: lastDeviceKey), let id = UUID(uuidString: stored),
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            print("[Pavlok BLE] Reconnecting to remembered wristband \(id)")
            centralManager(central, didDiscover: known,
                           advertisementData: [CBAdvertisementDataServiceUUIDsKey: [service]], rssi: 0)
            return
        }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChanged?()
        }
    }

    func disconnectBle() {
        reconnectWork?.cancel()
        failPendingWrites("BLE disconnected")
        centralManager?.stopScan()
        if let p = activePeripheral {
            centralManager?.cancelPeripheralConnection(p)
        }
        isBleConnected = false
        activePeripheral = nil
        shockCharacteristic = nil
        vibeCharacteristic = nil
        beepCharacteristic = nil
        batteryCharacteristic = nil
        batteryLevel = nil
        isBleScanning = false
        updateConnectionStatus()
    }

    func updateConnectionStatus() {
        if !isEnabled {
            isOnline = false
            onStatusChanged?()
            return
        }

        if apiToken.isEmpty {
            isOnline = false
            onStatusChanged?()
            return
        }

        guard let url = URL(string: userEndpoint) else { return }
        var req = URLRequest(url: url)
        req.setValue(apiToken, forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 3.0

        URLSession.shared.dataTask(with: req) { [weak self] _, resp, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isOnline = (resp as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? false
                self.onStatusChanged?()
            }
        }.resume()
    }

    // MARK: - CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Without this line an unauthorised or powered-off radio is indistinguishable
        // from a wristband that is simply out of range: both just never connect.
        let described: String
        switch central.state {
        case .poweredOn: described = "poweredOn"
        case .poweredOff: described = "poweredOff (turn Bluetooth on)"
        case .unauthorized: described = "unauthorized (grant Bluetooth in System Settings > Privacy & Security)"
        case .unsupported: described = "unsupported"
        case .resetting: described = "resetting"
        case .unknown: described = "unknown"
        @unknown default: described = "state \(central.state.rawValue)"
        }
        // A poweredOn radio with no TCC grant still scans -- it just never reports
        // anything -- so the authorisation has to be logged separately from the state.
        let auth: String
        switch CBCentralManager.authorization {
        case .allowedAlways: auth = "allowed"
        case .denied: auth = "DENIED in System Settings > Privacy & Security > Bluetooth"
        case .restricted: auth = "restricted by policy"
        case .notDetermined: auth = "not yet granted (macOS will prompt on first scan)"
        @unknown default: auth = "unknown"
        }
        print("[Pavlok BLE] Radio state: \(described) • permission: \(auth)")
        fflush(stdout)

        if central.state == .poweredOn {
            if connectionRequested {
                startBleScan(force: true)
            }
        } else {
            isBleConnected = false
            isBleScanning = false
            activePeripheral = nil
            shockCharacteristic = nil
            vibeCharacteristic = nil
            beepCharacteristic = nil
            batteryCharacteristic = nil
            batteryLevel = nil
            updateConnectionStatus()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard connectionRequested else { return }
        if let active = activePeripheral, active !== peripheral,
           active.state == .connected || active.state == .connecting { return }
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let lower = name.lowercased()
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let hasPavlokService = serviceUUIDs.contains {
            let s = $0.uuidString.uppercased()
            return s.contains("1000") || s.contains("6E9D")
        }
        let isPavlok = lower.contains("pavlok") || lower.contains("shock") || lower.contains("sc3") || lower.contains("sc2") || lower == "p3" || lower.contains("p3-") || hasPavlokService

        if PavlokController.traceBleDiscovery && !isPavlok && !tracedPeripherals.contains(peripheral.identifier) {
            // "It never connects" has two very different causes: the band is asleep and
            // advertising nothing, or it is advertising under a name this filter does not
            // recognise. Only the trace tells them apart.
            tracedPeripherals.insert(peripheral.identifier)
            let services = serviceUUIDs.map { $0.uuidString }.joined(separator: ",")
            print("[Pavlok BLE][trace] ignored \"\(name.isEmpty ? "(no name)" : name)\" \(peripheral.identifier) RSSI \(RSSI) services [\(services)]")
            fflush(stdout)
        }

        if isPavlok {
            print("[Pavlok BLE] Discovered candidate Pavlok 3 / wristband: \"\(name)\" (RSSI: \(RSSI)). Connecting...")
            fflush(stdout)
            central.stopScan()
            isBleScanning = false
            bleDeviceName = name.isEmpty ? "Pavlok 3" : name
            activePeripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self, weak peripheral] in
                guard let self = self, let peripheral = peripheral,
                      self.activePeripheral === peripheral, peripheral.state == .connecting else { return }
                print("[Pavlok BLE] Connection attempt timed out; retrying")
                central.cancelPeripheralConnection(peripheral)
                self.scheduleReconnect()
            }
            DispatchQueue.main.async { [weak self] in
                self?.onStatusChanged?()
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[Pavlok BLE] ⚡ Direct Bluetooth connection established with \"\(peripheral.name ?? "device")\"!")
        fflush(stdout)
        guard connectionRequested else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        defaults.set(peripheral.identifier.uuidString, forKey: lastDeviceKey)
        isBleConnected = true
        isBleScanning = false
        peripheral.delegate = self
        peripheral.discoverServices(nil)
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChanged?()
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("[Pavlok BLE] ❌ Failed to connect: \(error?.localizedDescription ?? "Unknown")")
        fflush(stdout)
        isBleConnected = false
        scheduleReconnect()
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChanged?()
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("[Pavlok BLE] ⚠️ Disconnected from \"\(peripheral.name ?? "device")\": \(error?.localizedDescription ?? "Link dropped")")
        fflush(stdout)
        failPendingWrites("BLE disconnected")
        isBleConnected = false
        shockCharacteristic = nil
        vibeCharacteristic = nil
        beepCharacteristic = nil
        batteryCharacteristic = nil
        batteryLevel = nil
        scheduleReconnect()
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChanged?()
        }
    }

    // MARK: - CBPeripheralDelegate
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("[Pavlok BLE] ⚠️ Service discovery error: \(error.localizedDescription)")
            return
        }
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            print("[Pavlok BLE] ⚠️ Characteristic discovery error: \(error.localizedDescription)")
            return
        }
        for char in service.characteristics ?? [] {
            let u = char.uuid.uuidString.uppercased()
            if u.contains("1003") || u.contains("6E9D7A34") {
                shockCharacteristic = char
                print("[Pavlok BLE] ✅ Found Shock characteristic: \(char.uuid)")
            }
            if u.contains("1001") || u.contains("7ECA7033") {
                vibeCharacteristic = char
                print("[Pavlok BLE] ✅ Found Vibrate characteristic: \(char.uuid)")
            }
            if u.contains("1002") || u.contains("EFD6FD9D") {
                beepCharacteristic = char
                print("[Pavlok BLE] ✅ Found Beep characteristic: \(char.uuid)")
            }
            if u.contains("2A19") {
                batteryCharacteristic = char
                print("[Pavlok BLE] ✅ Found Battery Level characteristic: \(char.uuid)")
                peripheral.readValue(for: char)
                if char.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: char)
                }
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChanged?()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let u = characteristic.uuid.uuidString.uppercased()
        if u.contains("2A19"), let data = characteristic.value, !data.isEmpty {
            let level = Int(data[0])
            self.batteryLevel = level
            print("[Pavlok BLE] 🔋 Pavlok 3 battery level: \(level)%")
            fflush(stdout)
            DispatchQueue.main.async { [weak self] in
                self?.onStatusChanged?()
            }
        }
    }

    private var pendingWrites: [CBUUID: (id: UUID, completion: (Bool, String?) -> Void)] = [:]

    private func failPendingWrites(_ detail: String) {
        let writes = pendingWrites.values.map { $0.completion }
        pendingWrites.removeAll()
        for completion in writes { completion(false, detail) }
    }

    private func writeStimulus(_ data: Data, to characteristic: CBCharacteristic,
                               on peripheral: CBPeripheral, completion: ((Bool, String?) -> Void)?) {
        let key = characteristic.uuid
        guard pendingWrites[key] == nil else {
            completion?(false, "BLE stimulus still awaiting acknowledgement")
            return
        }
        guard characteristic.properties.contains(.write) else {
            // A test cannot verify delivery without a device acknowledgement.
            completion?(false, "BLE characteristic does not support acknowledged writes")
            return
        }
        let id = UUID()
        pendingWrites[key] = (id, completion ?? { _, _ in })
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, self.pendingWrites[key]?.id == id else { return }
            self.failPendingWrites("BLE acknowledgement timed out")
            self.disconnectBle()
            self.scheduleReconnect()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === activePeripheral,
              let pending = pendingWrites.removeValue(forKey: characteristic.uuid) else { return }
        let detail = error.map { "BLE write failed: \($0.localizedDescription)" } ?? "BLE acknowledged by wristband"
        print("[Pavlok BLE] \(detail)")
        fflush(stdout)
        pending.completion(error == nil, detail)
    }

    // MARK: - Binary BLE Stimulus Encoder
    static func encodeBleShock(intensity: Int, isPavlok2: Bool = true) -> Data {
        let val = max(1, min(100, intensity))
        if isPavlok2 {
            // Pavlok 2/3: [0x81, level]
            return Data([0x81, UInt8(val)])
        } else {
            // Pavlok 1: [count, level, duration_on, duration_off]
            let lvl = UInt8(floor(Double(val) * 2.55))
            return Data([0x01, lvl, 0x32, 0x32])
        }
    }

    static func encodeBleVibe(intensity: Int, isPavlok2: Bool = true) -> Data {
        let val = max(1, min(100, intensity))
        if isPavlok2 {
            // Pavlok 2/3: [0x81, 0x0C, level, duration_on (0x18 ~0.65s), gap (0x18 ~0.65s)]
            return Data([0x81, 0x0C, UInt8(val), 0x18, 0x18])
        } else {
            let lvl = UInt8(floor(Double(val) * 2.55))
            return Data([0x01, lvl, 0x32, 0x32])
        }
    }

    // Pavlok 2/3 shares the vibration packet layout: byte 2 is intensity,
    // while byte 0 requests a single pulse. See ztrayl3/PyPav2, beep().
    static func encodeBleBeep(intensity: Int = 1, isPavlok2: Bool = true) -> Data {
        return encodeBleVibe(intensity: intensity, isPavlok2: isPavlok2)
    }

    // MARK: - Send Stimulus (Direct Bluetooth First, Cloud Backup)
    func sendStimulus(type: String, value: Int, reason: String, allowCloud: Bool = true, auditID: String? = nil, completion: ((Bool, String?) -> Void)? = nil) {
        let audit = interventionAudit(type: type, intensity: value, reason: reason,
                                      id: auditID ?? UUID().uuidString.lowercased(), manual: auditID != nil)
        audit("dispatch_requested", nil, nil)
        let callerCompletion = completion
        let completion: ((Bool, String?) -> Void)? = { ok, detail in
            audit("transport_result", ok, detail)
            callerCompletion?(ok, detail)
        }
        guard isEnabled || (!allowCloud && keepConnected) else {
            completion?(false, "Pavlok is disabled in settings")
            return
        }

        let intensity = max(1, min(100, value))

        // 1. Direct Bluetooth Low Energy (Ultra-Low Latency, <15ms)
        if isBleConnected, let peripheral = activePeripheral {
            if type == "zap", let char = shockCharacteristic {
                let isP2 = char.uuid.uuidString.uppercased().contains("1003")
                let data = PavlokController.encodeBleShock(intensity: intensity, isPavlok2: isP2)
                writeStimulus(data, to: char, on: peripheral, completion: completion)
                print("[Pavlok BLE] ⚡ DIRECT BLUETOOTH SHOCK DISPATCHED (<15ms latency)! Intensity: \(intensity)% | \"\(reason)\"")
                fflush(stdout)
                return
            } else if type == "vibe", let char = vibeCharacteristic {
                let isP2 = char.uuid.uuidString.uppercased().contains("1001")
                let data = PavlokController.encodeBleVibe(intensity: intensity, isPavlok2: isP2)
                writeStimulus(data, to: char, on: peripheral, completion: completion)
                print("[Pavlok BLE] 📳 DIRECT BLUETOOTH VIBRATION DISPATCHED (<15ms latency)! Intensity: \(intensity)% | \"\(reason)\"")
                fflush(stdout)
                return
            } else if type == "beep", let char = beepCharacteristic {
                let isP2 = char.uuid.uuidString.uppercased().contains("1002")
                let data = PavlokController.encodeBleBeep(intensity: intensity, isPavlok2: isP2)
                writeStimulus(data, to: char, on: peripheral, completion: completion)
                print("[Pavlok BLE] 🔔 DIRECT BLUETOOTH BEEP DISPATCHED (<15ms latency)! Intensity: \(intensity)% | \"\(reason)\"")
                fflush(stdout)
                return
            }
        }

        guard allowCloud else {
            completion?(false, "BLE disconnected or stimulus unavailable")
            return
        }

        // 2. Cloud Relay Fallback (if Bluetooth is not currently connected)
        if !apiToken.isEmpty {
            print("[Pavlok] ⚠️ Direct Bluetooth not connected. Routing through Pavlok Cloud API fallback (~400ms latency)...")
            fflush(stdout)

            let endpoint = stimulusEndpoint
            guard let url = URL(string: endpoint) else {
                completion?(false, "Invalid URL")
                return
            }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue(apiToken, forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any] = [
                "stimulus": [
                    "stimulusType": type,
                    "stimulusValue": intensity,
                    "reason": reason
                ]
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            req.timeoutInterval = 4.0

            URLSession.shared.dataTask(with: req) { data, resp, err in
                if let err = err {
                    print("[Pavlok Cloud] ❌ Failed to send stimulus: \(err.localizedDescription)")
                    fflush(stdout)
                    completion?(false, err.localizedDescription)
                    return
                }
                if let http = resp as? HTTPURLResponse {
                    let ok = (200...299).contains(http.statusCode)
                    if ok {
                        print("[Pavlok Cloud] ✅ \(type.uppercased()) stimulus delivered via Cloud! (HTTP \(http.statusCode))")
                    } else {
                        let respText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        print("[Pavlok Cloud] ❌ Server returned HTTP \(http.statusCode): \(respText)")
                    }
                    fflush(stdout)
                    completion?(ok, "HTTP \(http.statusCode)")
                }
            }.resume()
            return
        }

        print("[Pavlok] ⚠️ Cannot send \(type): Bluetooth wristband not connected and no Cloud API backup token configured.")
        fflush(stdout)
        completion?(false, "Bluetooth disconnected & no API token")
    }

    func trigger30sWarning(completion: ((Bool, String?) -> Void)? = nil) {
        guard isEnabled else {
            completion?(false, "Pavlok is disabled in settings")
            return
        }

        var anyDispatched = false
        if warningShockIntensity > 0 {
            sendStimulus(type: "zap", value: warningShockIntensity, reason: "30s monologue pre-warning light shock", completion: completion)
            anyDispatched = true
        }
        if warningVibeIntensity > 0 {
            sendStimulus(type: "vibe", value: warningVibeIntensity, reason: "30s monologue pre-warning vibration", completion: (anyDispatched ? nil : completion))
            anyDispatched = true
        }
        if warningBeepEnabled {
            sendStimulus(type: "beep", value: 1, reason: "30s monologue warning chime", completion: (anyDispatched ? nil : completion))
            anyDispatched = true
        }

        if !anyDispatched {
            completion?(true, "Visual toast only (silent cue)")
        }
    }

    func trigger60sHardStop(completion: ((Bool, String?) -> Void)? = nil) {
        guard isEnabled else {
            completion?(false, "Pavlok is disabled in settings")
            return
        }

        var anyDispatched = false
        if alertShockIntensity > 0 {
            sendStimulus(type: "zap", value: alertShockIntensity, reason: "1-minute monologue hard stop heavier shock", completion: completion)
            anyDispatched = true
        }
        if alertVibeIntensity > 0 {
            sendStimulus(type: "vibe", value: alertVibeIntensity, reason: "1-minute monologue hard stop vibration", completion: (anyDispatched ? nil : completion))
            anyDispatched = true
        }

        if !anyDispatched {
            completion?(true, "Visual toast only (silent cue)")
        }
    }
}

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

// MARK: - Habit Experiment Manager (Cluster Randomized Trial)
enum HabitTreatmentArm: String, CaseIterable {
    /// The only arm keys ever written to habit_events.treatment_arm.
    static let experimentArms = ["baseline", "caw_audio", "pavlok_shock", "haptic_vibe"]

    case clusterRandomized = "cluster_randomized"
    case baseline = "baseline"
    case cawAudio = "caw_audio"
    case pavlokShock = "pavlok_shock"
    case hapticVibe = "haptic_vibe"

    var displayName: String {
        switch self {
        case .clusterRandomized: return "🎲 Randomized per Meeting (Cluster Trial)"
        case .baseline: return "🔵 Baseline Control (Silent / Observational)"
        case .cawAudio: return "🔔 Audio Chime (CAW Warning)"
        case .pavlokShock: return "⚡ Pavlok Physical Shock"
        case .hapticVibe: return "📳 Pavlok Haptic Vibration"
        }
    }

    var shortTag: String {
        switch self {
        case .clusterRandomized: return "Randomized"
        case .baseline: return "Baseline"
        case .cawAudio: return "CAW Audio"
        case .pavlokShock: return "Pavlok Shock"
        case .hapticVibe: return "Haptic Vibe"
        }
    }
}

class HabitExperimentManager {
    static let shared = HabitExperimentManager()
    private let defaults = UserDefaults.standard
    private let kExperimentMode = "habit_experiment_mode"

    var currentMode: HabitTreatmentArm {
        get {
            if let saved = defaults.string(forKey: kExperimentMode),
               let arm = HabitTreatmentArm(rawValue: saved) {
                return arm
            }
            return .clusterRandomized
        }
        set {
            defaults.set(newValue.rawValue, forKey: kExperimentMode)
        }
    }

    func resolveArm(for sessionId: String) -> String {
        switch currentMode {
        case .clusterRandomized:
            let arms = HabitTreatmentArm.experimentArms
            let hash = abs(sessionId.hashValue)
            return arms[hash % arms.count]
        case .baseline:
            return "baseline"
        case .cawAudio:
            return "caw_audio"
        case .pavlokShock:
            return "pavlok_shock"
        case .hapticVibe:
            return "haptic_vibe"
        }
    }
}

// MARK: - Local SQLite Habit Trial Logger
class HabitEventLogger {
    static let shared = HabitEventLogger()

    /// Written into habit_events.metadata.source so live rows are distinguishable.
    static let liveSource = "solo_mic_live_v2"

    private let dbPath: String
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.benpollack.habit-logger", qos: .utility)

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = home + "/.ai-aggregator"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // LEARNER_OUTBOX_DB points tests (--drain-outbox) at a scratch database.
        self.dbPath = ProcessInfo.processInfo.environment["LEARNER_OUTBOX_DB"] ?? dir + "/behavior_experiments.sqlite"
        openAndInitDb()
    }

    private func openAndInitDb() {
        queue.async {
            if sqlite3_open(self.dbPath, &self.db) != SQLITE_OK {
                print("[HabitLogger] ❌ Failed to open SQLite DB at \(self.dbPath)")
                return
            }
            sqlite3_busy_timeout(self.db, 5000)
            let createSql = """
            CREATE TABLE IF NOT EXISTS habit_events (
                event_id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                call_app TEXT,
                call_category TEXT DEFAULT 'work',
                timestamp TEXT NOT NULL,
                habit_type TEXT NOT NULL,
                treatment_arm TEXT NOT NULL,
                turn_duration_sec REAL NOT NULL,
                words_spoken INTEGER DEFAULT 0,
                warning_fired_at REAL,
                shock_fired_at REAL,
                latency_to_yield_sec REAL,
                breached_30s INTEGER DEFAULT 0,
                breached_60s INTEGER DEFAULT 0,
                was_rewarded INTEGER DEFAULT 0,
                metadata TEXT,
                synced_to_server INTEGER DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_habits_unsynced ON habit_events(synced_to_server);
            """
            if sqlite3_exec(self.db, createSql, nil, nil, nil) != SQLITE_OK {
                print("[HabitLogger] ❌ Failed to initialize schema")
            }
        }
    }

    func logTurn(
        occurredAt: Date? = nil,
        habitType: String = "monologue_streak",
        sessionId: String,
        callApp: String?,
        callCategory: String = "work",
        treatmentArm: String,
        turnDurationSec: Double,
        wordsSpoken: Int,
        warningFiredAt: Double?,
        shockFiredAt: Double?,
        latencyToYieldSec: Double?,
        breached30s: Bool,
        breached60s: Bool,
        wasRewarded: Bool,
        metadata: [String: Any] = [:]
    ) {
        queue.async {
            guard let db = self.db else {
                print("[HabitLogger] Dropped a turn logged after shutdown (DB closed).")
                return
            }
            let eventId = UUID().uuidString.lowercased()
            // When the app drains a backlog of transcriptions, many turns finish within the
            // same wall-clock second. Stamp the row with when the turn was actually spoken
            // (audio clock where available), not when it happened to be written.
            let isoTimestamp = ISO8601DateFormatter().string(from: occurredAt ?? Date())
            let metaJson = (try? JSONSerialization.data(withJSONObject: metadata)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

            let sql = """
            INSERT INTO habit_events (
                event_id, session_id, call_app, call_category, timestamp,
                habit_type, treatment_arm, turn_duration_sec, words_spoken,
                warning_fired_at, shock_fired_at, latency_to_yield_sec,
                breached_30s, breached_60s, was_rewarded, metadata, synced_to_server
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0);
            """

            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(stmt, 1, (eventId as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, (sessionId as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, ((callApp ?? "Solo Mic") as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, (callCategory as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 5, (isoTimestamp as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 6, (habitType as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 7, (treatmentArm as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 8, turnDurationSec)
                sqlite3_bind_int(stmt, 9, Int32(wordsSpoken))

                if let w = warningFiredAt {
                    sqlite3_bind_double(stmt, 10, w)
                } else {
                    sqlite3_bind_null(stmt, 10)
                }

                if let s = shockFiredAt {
                    sqlite3_bind_double(stmt, 11, s)
                } else {
                    sqlite3_bind_null(stmt, 11)
                }

                if let l = latencyToYieldSec {
                    sqlite3_bind_double(stmt, 12, l)
                } else {
                    sqlite3_bind_null(stmt, 12)
                }

                sqlite3_bind_int(stmt, 13, breached30s ? 1 : 0)
                sqlite3_bind_int(stmt, 14, breached60s ? 1 : 0)
                sqlite3_bind_int(stmt, 15, wasRewarded ? 1 : 0)
                sqlite3_bind_text(stmt, 16, (metaJson as NSString).utf8String, -1, SQLITE_TRANSIENT)

                if sqlite3_step(stmt) == SQLITE_DONE {
                    print("[HabitLogger] ✅ Logged \(habitType): arm=\(treatmentArm), dur=\(String(format: "%.1f", turnDurationSec))s, yieldLatency=\(latencyToYieldSec.map { String(format: "%.1f", $0) + "s" } ?? "none"), 30s=\(breached30s)")
                } else {
                    print("[HabitLogger] ❌ sqlite3_step failed: \(String(cString: sqlite3_errmsg(db)))")
                }
                sqlite3_finalize(stmt)
            } else {
                print("[HabitLogger] ❌ sqlite3_prepare_v2 failed: \(String(cString: sqlite3_errmsg(db)))")
            }
            fflush(stdout)
        }
    }

    /// Block until every queued insert has been written. Used by clean shutdown so the
    /// in-flight turn is on disk before the sync runs and the DB is closed.
    func waitUntilIdle() {
        queue.sync {}
    }

    /// Close the SQLite handle. Further logTurn calls become no-ops rather than crashes.
    func close() {
        queue.sync {
            if let db = self.db {
                sqlite3_close(db)
                self.db = nil
                print("[HabitLogger] SQLite closed cleanly.")
                fflush(stdout)
            }
        }
    }

    func getUnsyncedCount() -> Int {
        var count = 0
        queue.sync {
            guard let db = self.db else { return }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM habit_events WHERE synced_to_server = 0;", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(stmt, 0))
                }
                sqlite3_finalize(stmt)
            }
        }
        return count
    }

    /// Up to `limit` unsent rows as `recordHabitEvents` events (contract/desktop.ts,
    /// DesktopHabitEvent), oldest first. synced_to_server: 0 unsent, 1 sent, 2 parked
    /// (the server rejected the row itself with 422; kept for inspection, never resent).
    func unsentEvents(limit: Int) -> [[String: Any]] {
        var events: [[String: Any]] = []
        queue.sync {
            guard let db = self.db else { return }
            let sql = """
            SELECT event_id, session_id, call_app, call_category, timestamp, habit_type, treatment_arm,
                   turn_duration_sec, words_spoken, warning_fired_at, shock_fired_at, latency_to_yield_sec,
                   breached_30s, breached_60s, was_rewarded, metadata
            FROM habit_events WHERE synced_to_server = 0 ORDER BY timestamp ASC LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            func text(_ i: Int32) -> String? {
                sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, i))
            }
            // Contract `Seconds` is a non-negative number; anything else would get the whole batch a 422.
            func seconds(_ i: Int32) -> Any {
                guard sqlite3_column_type(stmt, i) != SQLITE_NULL else { return NSNull() }
                let v = sqlite3_column_double(stmt, i)
                return v.isFinite && v >= 0 ? v : NSNull()
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let meta = text(15).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
                events.append([
                    "eventId": text(0) ?? "",
                    "sessionId": text(1) ?? "",
                    "callApp": text(2) as Any? ?? NSNull(),
                    "callCategory": text(3) as Any? ?? NSNull(),
                    "timestamp": HabitEventLogger.isoWithOffset(text(4) ?? ""),
                    "habitType": text(5) ?? "",
                    "treatmentArm": text(6) as Any? ?? NSNull(),
                    "turnDurationSec": seconds(7),
                    "wordsSpoken": sqlite3_column_type(stmt, 8) == SQLITE_NULL ? NSNull() : Int(sqlite3_column_int(stmt, 8)) as Any,
                    "warningFiredAtSec": seconds(9),
                    "shockFiredAtSec": seconds(10),
                    "latencyToYieldSec": seconds(11),
                    "breached30s": sqlite3_column_int(stmt, 12) != 0,
                    "breached60s": sqlite3_column_int(stmt, 13) != 0,
                    "wasRewarded": sqlite3_column_int(stmt, 14) != 0,
                    "metadata": meta,
                ])
            }
            sqlite3_finalize(stmt)
        }
        return events
    }

    /// Legacy rows hold "YYYY-MM-DD HH:MM:SS" (UTC); the contract wants ISO-8601 with an offset.
    static func isoWithOffset(_ raw: String) -> String {
        if ISO8601DateFormatter().date(from: raw) != nil { return raw }
        let legacy = DateFormatter()
        legacy.locale = Locale(identifier: "en_US_POSIX")
        legacy.timeZone = TimeZone(identifier: "UTC")
        legacy.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return legacy.date(from: raw).map { ISO8601DateFormatter().string(from: $0) } ?? raw
    }

    func mark(_ eventIds: [String], as state: Int) {
        guard !eventIds.isEmpty else { return }
        queue.sync {
            guard let db = self.db else { return }
            let placeholders = Array(repeating: "?", count: eventIds.count).joined(separator: ",")
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE habit_events SET synced_to_server = \(state) WHERE event_id IN (\(placeholders));", -1, &stmt, nil) == SQLITE_OK else { return }
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (i, id) in eventIds.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
            }
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    func getTotalTrialCount() -> Int {
        var count = 0
        queue.sync {
            guard let db = self.db else { return }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM habit_events WHERE habit_type = 'monologue_streak';", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(stmt, 0))
                }
                sqlite3_finalize(stmt)
            }
        }
        return count
    }
}

// MARK: - learner-server API

/// HTTPS RPC to learner-server (spec: learner-server docs/learner-desktop-api.md; wire
/// shapes pinned in contract/). The app no longer writes into Postgres or Hindsight
/// over the SSH tunnel: rows wait in the local SQLite outbox and go out from here.
enum LearnerAPI {
    static let baseURL = ProcessInfo.processInfo.environment["LEARNER_API_URL"] ?? "https://dev.biztoolz.app/learner-api"
    static let clientId = "ben-mbp"

    /// The device key: LEARNER_API_KEY (tests), else the Keychain item the operator
    /// stored with `security add-generic-password -s learner-server -a ben-mbp`. Read
    /// through /usr/bin/security, which that item trusts, so a rebuilt app is not prompted.
    static func deviceKey() -> String? {
        if let k = ProcessInfo.processInfo.environment["LEARNER_API_KEY"], !k.isEmpty { return k }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "learner-server", "-a", clientId, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return p.terminationStatus == 0 && !key.isEmpty ? key : nil
    }

    /// POST {"data": input} to /rpc/<name>. Status 0 means no response at all.
    static func call(_ name: String, _ input: [String: Any], key: String, timeout: TimeInterval = 20) -> (status: Int, body: Any?) {
        guard let url = URL(string: "\(baseURL)/rpc/\(name)"),
              let body = try? JSONSerialization.data(withJSONObject: ["data": input]) else { return (0, nil) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.httpBody = body
        var result: (Int, Any?) = (0, nil)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, response, _ in
            result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data.flatMap { try? JSONSerialization.jsonObject(with: $0) })
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 5)
        return result
    }
}

/// Drains the habit_events outbox with `recordHabitEvents` and sends a heartbeat every
/// 5 minutes. The coaching loop never waits on it. Error handling per the spec: 422
/// rejects a batch, so it is halved until the bad row is alone and parked; 401/403 is a
/// key problem (🔑) and pauses sending; 413 halves the batch; 429/5xx/no answer backs
/// off from 2 s to 5 min with jitter. Any non-2xx is a failure.
final class OutboxSender {
    static let shared = OutboxSender()
    static let maxBatch = 500

    private let work = DispatchQueue(label: "com.benpollack.learner-outbox", qos: .utility)
    private var cachedKey: String?
    private var batchLimit = maxBatch
    private var backoff: TimeInterval = 2
    private var nextAttempt = Date.distantPast
    private var lastHeartbeat = Date.distantPast
    private var running = false

    /// No usable device key: missing from the Keychain, or refused by the server.
    private(set) var keyProblem = false
    private(set) var lastSentAt: Date?
    private(set) var lastStatus = "not tried yet"

    /// Called on the 8 s status poll; drains in the background.
    func tick(heartbeat: @escaping () -> [String: Any]) {
        work.async {
            guard !self.running else { return }
            self.running = true
            defer { self.running = false }
            while self.sendOneBatch() == .more {}
            self.sendHeartbeatIfDue(heartbeat())
        }
    }

    /// Send everything now, blocking, until the outbox is empty, sending fails or
    /// `deadline` passes. Used at quit and by --drain-outbox.
    @discardableResult
    func drain(until deadline: Date) -> Int {
        work.sync {
            nextAttempt = .distantPast
            while Date() < deadline, sendOneBatch() == .more {}
        }
        return HabitEventLogger.shared.getUnsyncedCount()
    }

    func sendNow() {
        work.async { self.nextAttempt = .distantPast; self.keyProblem = false; self.cachedKey = nil }
    }

    private enum Step { case more, idle, failed }

    private func key() -> String? {
        if cachedKey == nil { cachedKey = LearnerAPI.deviceKey() }
        keyProblem = cachedKey == nil
        return cachedKey
    }

    private func sendOneBatch() -> Step {
        guard Date() >= nextAttempt else { return .idle }
        let logger = HabitEventLogger.shared
        let events = logger.unsentEvents(limit: batchLimit)
        guard !events.isEmpty else { batchLimit = OutboxSender.maxBatch; return .idle }
        guard let key = key() else { lastStatus = "no device key"; nextAttempt = Date().addingTimeInterval(300); return .failed }
        let ids = events.compactMap { $0["eventId"] as? String }
        let (status, body) = LearnerAPI.call("recordHabitEvents", ["clientId": LearnerAPI.clientId, "events": events], key: key)
        switch status {
        case 200..<300:
            logger.mark(ids, as: 1)
            lastSentAt = Date()
            backoff = 2
            lastStatus = "sent \(ids.count) (\((body as? [String: Any])?["accepted"] ?? "?") accepted, \((body as? [String: Any])?["duplicates"] ?? "?") duplicates)"
            log(lastStatus)
            return .more
        case 422:
            if ids.count > 1 {
                batchLimit = max(1, ids.count / 2)
                return .more
            }
            logger.mark(ids, as: 2)
            lastStatus = "parked event \(ids[0]): \((body as? [String: Any])?["message"] ?? "rejected")"
            log(lastStatus)
            return .more
        case 401, 403:
            keyProblem = true
            cachedKey = nil
            nextAttempt = Date().addingTimeInterval(300)
            lastStatus = "device key refused (\(status))"
        case 413:
            batchLimit = max(1, ids.count / 2)
            return .more
        default:
            nextAttempt = Date().addingTimeInterval(backoff * Double.random(in: 0.5...1.0))
            backoff = min(backoff * 2, 300)
            lastStatus = status == 0 ? "server unreachable" : "server error \(status)"
        }
        log(lastStatus)
        return .failed
    }

    private func sendHeartbeatIfDue(_ input: [String: Any]) {
        guard Date().timeIntervalSince(lastHeartbeat) >= 300, let key = key() else { return }
        lastHeartbeat = Date()
        let (status, _) = LearnerAPI.call("recordAppHeartbeat", input, key: key)
        if status == 401 || status == 403 { keyProblem = true; cachedKey = nil }
        if !(200..<300).contains(status) { log("heartbeat failed (\(status))") }
    }

    private func log(_ message: String) {
        print("[Outbox] \(message)")
        fflush(stdout)
    }
}

// MARK: - Bundled Helpers (SSH tunnel, transcript watcher)

/// A helper process the app runs for as long as it is running. The SSH tunnel and the
/// transcript watcher used to be separate /bin/bash LaunchAgents, which Login Items lists
/// as "bash" from an unknown developer; once switched off there, launchd silently stopped
/// starting them at login (ten days down after the 2026-10-11 reboot). As children of the
/// app they share its one Login Items entry and start, stop and restart with it.
final class ManagedHelper {
    let name: String
    private let executable: String
    private let arguments: [String]
    /// Part of the helper's command line, to recognise an orphan from a crashed run.
    private let marker: String
    private let logPath: String
    private let pidPath: String
    private var process: Process?
    private var logHandle: FileHandle?
    private var stopping = false
    private var startedAt = Date.distantPast
    private var restartDelay: TimeInterval = 1

    init(name: String, executable: String, arguments: [String], marker: String) {
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.marker = marker
        let runtimeDir = NSHomeDirectory() + "/.ai-aggregator"
        logPath = runtimeDir + "/logs/\(name).log"
        pidPath = runtimeDir + "/\(name).pid"
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func start() {
        stopping = false
        reapOrphan()
        launch()
    }

    func restart() {
        stop()
        start()
    }

    private func launch() {
        guard !stopping, !isRunning else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: logPath) { fm.createFile(atPath: logPath, contents: nil) }
        AppLog.rotate(helperLog: logPath)
        if !fm.fileExists(atPath: logPath) { fm.createFile(atPath: logPath, contents: nil) }
        let log = FileHandle(forWritingAtPath: logPath)
        log?.seekToEndOfFile()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ai-aggregator")
        if let log = log {
            p.standardOutput = log
            p.standardError = log
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.exited(proc) }
        }
        do {
            try p.run()
        } catch {
            // Only a missing or non-executable binary gets here; retrying would not help.
            try? log?.close()
            print("[Helpers] Could not start \(name): \(error.localizedDescription)")
            fflush(stdout)
            return
        }
        process = p
        logHandle = log
        startedAt = Date()
        try? String(p.processIdentifier).write(toFile: pidPath, atomically: true, encoding: .utf8)
        print("[Helpers] Started \(name) (pid \(p.processIdentifier))")
        fflush(stdout)
    }

    private func exited(_ proc: Process) {
        guard proc === process else { return }
        process = nil
        try? logHandle?.close()
        logHandle = nil
        try? FileManager.default.removeItem(atPath: pidPath)
        if stopping { return }
        // One that stayed up a minute was healthy, so bring it back promptly; one that dies
        // straight away (no network, port already held) backs off instead of spinning.
        restartDelay = Date().timeIntervalSince(startedAt) > 60 ? 1 : min(restartDelay * 2, 60)
        print("[Helpers] \(name) exited (status \(proc.terminationStatus)); restarting in \(Int(restartDelay))s")
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + restartDelay) { [weak self] in
            self?.launch()
        }
    }

    /// SIGTERM, then SIGKILL if it is still running after `timeout`. Blocks the caller.
    func stop(timeout: TimeInterval = 5) {
        stopping = true
        guard let p = process else { return }
        if p.isRunning {
            p.terminate()
            var deadline = Date().addingTimeInterval(timeout)
            while p.isRunning && Date() < deadline { usleep(100_000) }
            if p.isRunning {
                kill(p.processIdentifier, SIGKILL)
                deadline = Date().addingTimeInterval(2)
                while p.isRunning && Date() < deadline { usleep(100_000) }
            }
            print("[Helpers] Stopped \(name)")
            fflush(stdout)
        }
        process = nil
        try? logHandle?.close()
        logHandle = nil
        try? FileManager.default.removeItem(atPath: pidPath)
    }

    /// macOS has no parent-death signal, so a crashed or force-killed app leaves its
    /// helpers running and holding the forwarded ports. The pid file lets the next launch
    /// stop them first -- but only if that pid still belongs to one (pids are reused).
    private func reapOrphan() {
        defer { try? FileManager.default.removeItem(atPath: pidPath) }
        guard let text = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1,
              let command = processCommandLine(pid), command.contains(marker) else { return }
        print("[Helpers] Stopping \(name) left over from a previous run (pid \(pid))")
        fflush(stdout)
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(3)
        while kill(pid, 0) == 0 && Date() < deadline { usleep(100_000) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }
}

/// A process's command line, optionally followed by the environment it was started with
/// (readable for the current user's own processes).
func processCommandLine(_ pid: pid_t, includeEnvironment: Bool = false) -> String? {
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = (includeEnvironment ? ["-wwE"] : []) + ["-p", String(pid), "-o", "command="]
    let out = Pipe()
    ps.standardOutput = out
    ps.standardError = FileHandle.nullDevice
    guard (try? ps.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    ps.waitUntilExit()
    return ps.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
}

// MARK: - AI Vault export

/// Pulls new ChatGPT and Claude conversations into ~/ai-vault-data with the `ai-vault`
/// CLI, where the transcript watcher picks them up and archives them on learner-server.
/// Nothing scheduled this before, so nothing new was exported after 2026-09-07. ai-vault
/// logs in with browser cookies that expire. An expired login turns the tray red and the
/// menu offers "Sign In Again", which opens VaultSignIn: a normal sign-in page inside the
/// app whose session cookies are handed to `ai-vault setup --cookies-file`.
final class VaultExport {
    static let shared = VaultExport()
    static let interval: TimeInterval = 6 * 3600
    static let perProviderTimeout: TimeInterval = 30 * 60
    static let providers = ["claude", "chatgpt"]

    private let work = DispatchQueue(label: "com.benpollack.vault-export", qos: .utility)
    private let logPath = NSHomeDirectory() + "/.ai-aggregator/logs/vault-export.log"
    private var nextRun = Date().addingTimeInterval(120)
    private var running = false
    private var rerun = false

    static let loginExpiredPattern = "Authentication failed|cookies appear to be expired|Organization ID not available|API request failed: 40[13]"
    static let failedPattern = "Errors: [1-9]|Completed with [1-9][0-9]* errors"
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
            var expired: Set<String> = []
            var notes: [String] = []
            for provider in VaultExport.providers {
                let (status, output) = self.backup(provider)
                // ai-vault exits 0 even when its summary lists errors, so read the output.
                if output.range(of: VaultExport.loginExpiredPattern, options: .regularExpression) != nil {
                    expired.insert(provider)
                    notes.append("\(provider): login expired")
                } else if status == nil {
                    notes.append("\(provider): timed out")
                } else if output.range(of: VaultExport.failedPattern, options: .regularExpression) != nil {
                    notes.append("\(provider): failed (see vault-export.log)")
                } else {
                    notes.append("\(provider): \(status == 0 ? "ok" : "exit \(status!)")")
                }
            }
            DispatchQueue.main.async {
                self.expiredLogins = expired
                self.lastRun = Date()
                self.lastSummary = notes.joined(separator: ", ")
                self.running = false
                print("[VaultExport] \(self.lastSummary)")
                self.onFinished?()
                if self.rerun { self.rerun = false; self.runNow() }
            }
        }
    }

    /// Runs one provider's backup, appending its output to vault-export.log. Returns the
    /// exit status (nil on timeout) and the output, for the auth check.
    private func backup(_ provider: String) -> (Int32?, String) {
        guard let cli = VaultExport.cliPath() else { return (127, "ai-vault CLI not found") }
        AppLog.rotate(helperLog: logPath)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        var args = ["backup", provider, "--only-new", "--skip-media", "-y"]
        if provider == "chatgpt" { args.append("--random-delay") }
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (cli as NSString).deletingLastPathComponent + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        var data = Data()
        let reader = DispatchQueue(label: "vault-export-read")
        out.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            reader.sync { data.append(chunk) }
        }
        guard (try? p.run()) != nil else { return (126, "could not start ai-vault") }
        let deadline = Date().addingTimeInterval(VaultExport.perProviderTimeout)
        while p.isRunning && Date() < deadline { usleep(500_000) }
        let timedOut = p.isRunning
        if timedOut { p.terminate() }
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        let text = reader.sync { String(data: data, encoding: .utf8) ?? "" }
        if let h = FileHandle(forWritingAtPath: logPath) ?? {
            FileManager.default.createFile(atPath: logPath, contents: nil)
            return FileHandle(forWritingAtPath: logPath)
        }() {
            h.seekToEndOfFile()
            h.write(Data("=== \(Date()) \(provider)\(timedOut ? " (timed out)" : "")\n\(text)\n".utf8))
            try? h.close()
        }
        return (timedOut ? nil : p.terminationStatus, text)
    }

    /// ai-vault is installed under nvm; pick the newest node version that has it.
    static func cliPath() -> String? {
        let root = NSHomeDirectory() + "/.nvm/versions/node"
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted().reversed()
        return versions.map { "\(root)/\($0)/bin/ai-vault" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - AI Vault sign-in

/// Signs ai-vault back in without Terminal or developer tools. `ai-vault setup` only
/// asks for cookie values to be pasted by hand; instead this window shows the provider's
/// own sign-in page, and once its session cookie appears the cookies go to
/// `ai-vault setup <provider> --cookies-file` (a 0600 file, deleted straight after).
/// On success the window closes and an export runs. The web view keeps its own
/// persistent store, so a later re-sign-in is often a single click.
final class VaultSignIn: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    struct Site { let url: String; let domain: String; let session: [String] }

    static let sites: [String: Site] = [
        "chatgpt": Site(url: "https://chatgpt.com/auth/login", domain: "chatgpt.com",
                        session: ["__Secure-next-auth.session-token", "__Secure-next-auth.session-token.0"]),
        "claude": Site(url: "https://claude.ai/login", domain: "claude.ai", session: ["sessionKey"]),
    ]
    private static var open: [String: VaultSignIn] = [:]

    static func show(_ provider: String) {
        NSApp.activate(ignoringOtherApps: true)
        if let existing = open[provider] { existing.window.makeKeyAndOrderFront(nil); return }
        guard let site = sites[provider] else { return }
        let s = VaultSignIn(provider: provider, site: site)
        open[provider] = s
        s.window.makeKeyAndOrderFront(nil)
    }

    private let provider: String
    private let site: Site
    private let window: NSWindow
    private let webView: WKWebView
    private let status = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var triedSession: String?
    private var saving = false
    private var connected = false
    private var popups: [NSWindow] = []

    private init(provider: String, site: Site) {
        self.provider = provider
        self.site = site
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        // Some sign-in providers refuse embedded browsers by user agent.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Sign in to \(provider == "chatgpt" ? "ChatGPT" : "Claude") for AI Vault"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        status.stringValue = "Sign in below. This window closes by itself once AI Vault is connected."
        status.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [status, webView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 0, right: 0)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        window.contentView = stack

        webView.navigationDelegate = self
        webView.uiDelegate = self
        if let url = URL(string: site.url) { webView.load(URLRequest(url: url)) }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.checkCookies() }
        print("[VaultSignIn] opened \(provider)")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { checkCookies() }

    /// "Continue with Google" and similar open a popup that reports back to the page; a
    /// web view without this silently drops the click.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.customUserAgent = webView.customUserAgent
        popup.uiDelegate = self
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.title = window.title
        w.contentView = popup
        w.center()
        w.makeKeyAndOrderFront(nil)
        popups.append(w)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        popups.filter { $0.contentView === webView }.forEach { $0.close() }
        popups.removeAll { $0.contentView === webView }
    }

    private func checkCookies() {
        guard !saving, !connected else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self, !self.saving, !self.connected else { return }
            let mine = cookies.filter { $0.domain.hasSuffix(self.site.domain) }
            // Try each new session value once; a refused one is not retried until it changes.
            guard let session = mine.first(where: { self.site.session.contains($0.name) })?.value,
                  session != self.triedSession else { return }
            self.triedSession = session
            self.save(mine)
        }
    }

    private func save(_ cookies: [HTTPCookie]) {
        saving = true
        status.stringValue = "Signed in. Connecting AI Vault…"
        let provider = self.provider
        let values = Dictionary(cookies.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
        DispatchQueue.global(qos: .userInitiated).async {
            let result = VaultSignIn.runSetup(provider, cookies: values)
            DispatchQueue.main.async {
                self.saving = false
                if result.ok {
                    self.connected = true
                    self.timer?.invalidate()
                    print("[VaultSignIn] \(provider): ai-vault accepted the session; exporting")
                    self.status.stringValue = "Connected. Exporting your chats…"
                    VaultExport.shared.signedIn(provider)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.window.close() }
                } else {
                    print("[VaultSignIn] \(provider): ai-vault setup failed: \(result.detail)")
                    self.status.stringValue = "AI Vault could not use this sign-in (\(result.detail)). Sign out and in again below."
                }
            }
        }
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
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["setup", provider, "--cookies-file", path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (cli as NSString).deletingLastPathComponent + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        guard (try? p.run()) != nil else { return (false, "could not start ai-vault") }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        let ok = p.terminationStatus == 0 && text.contains("Configuration saved")
        let last = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
        return (ok, ok ? "ok" : String((last ?? "exit \(p.terminationStatus)").prefix(160)))
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        popups.forEach { $0.close() }
        popups.removeAll()
        VaultSignIn.open[provider] = nil
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

// MARK: - Continuous Word Talk-Time Monitor
class TalkTimeMonitor: NSObject {
    static let shared = TalkTimeMonitor()

    let rewardMinSec: TimeInterval = 5.0        // A turn shorter than this is a grunt, not a yield
    let warningThreshold: TimeInterval = 30.0   // 30 seconds
    let alertThreshold: TimeInterval = 60.0     // 60 seconds (1 minute)
    let silenceTimeout: TimeInterval = 14.0     // Max silence timeout (10s chunk + Whisper margin)
    // Above this arrival lag, screenpipe was batching and the turn's wall-clock timing
    // (and therefore any latency-to-yield derived from it) cannot be trusted.
    let maxTrustedIngestLagSec: TimeInterval = 10.0
    var alertOnlyDuringCalls: Bool = true       // Only pop up floating toast during active calls

    private var lastCheckedTranscriptionId: Int64 = 0
    private var isInitialized = false
    // Live meeting transcription is a SEPARATE screenpipe pipeline. While a meeting
    // stream is active screenpipe sets background_suppressed, so audio_transcriptions
    // (the table below) receives nothing until the meeting ends and reconciliation
    // back-fills it. Polling only that table left the coach blind during meetings --
    // exactly when it is supposed to fire. So we read the live table too.
    private var lastCheckedLiveSegmentId: Int64 = 0
    private var liveIsInitialized = false
    // Audio already accounted for via the live path. The post-meeting back-fill
    // replays the same speech into audio_transcriptions; without this the whole
    // meeting would be counted twice.
    private var liveCoveredUntil: Date?
    private var turnUsedLivePath = false

    private(set) var currentStreak: TimeInterval = 0.0
    private var lastSpeechWallClock: Date?
    // Start of the current turn, used to derive a transcript-gap-comparable duration.
    private var turnStartWallClock: Date?
    private var lastChunkId: Int64 = 0
    private var lastAudioEndTime: Double = 0.0
    private var lastTurnBoundaryAt: Date?
    private(set) var activeCallApp: String?
    private(set) var activeCallTitle: String?
    private(set) var activeSessionId: String = "solo_" + UUID().uuidString.prefix(8).lowercased()

    // Pavlok debouncing flags
    private(set) var hasWarnedPavlokThisMonologue: Bool = false
    private(set) var hasShockedPavlokThisMonologue: Bool = false
    private var hasDeliveredStimulusAt30s: Bool = false
    private var hasDeliveredStimulusAt60s: Bool = false
    private var currentTurnWords: Int = 0
    private var warningFiredWallClock: Date?
    private var shockFiredWallClock: Date?
    // Streak length when each stimulus actually fired (not the threshold constant).
    private var warningFiredStreakSec: Double?
    private var shockFiredStreakSec: Double?
    // Per-turn record of every intervention attempt and whether it was confirmed delivered.
    private var interventionLog: [[String: Any]] = []
    private let interventionLock = NSLock()
    private var toastLoggedThisTurn = false
    // Was the intervention able to fire at any point during this turn? A turn where it
    // could not (solo speech, with alertOnlyDuringCalls on) is not an experimental unit:
    // no cue can be delivered, so it cannot respond to treatment, and counting it only
    // dilutes the arms. Tracked rather than derived from call_category so it stays correct
    // if "Alert Only During Calls" is ever turned off.
    private var turnWasAlertable = false
    private var turnTreatmentSettings: [String: Any]?
    private var turnSettingsChanged = false

    /// Assignment and configurable factors are distinct: these switches are not randomized.
    private func treatmentSettings() -> [String: Any] {
        let p = PavlokController.shared
        let arm = HabitExperimentManager.shared.resolveArm(for: activeSessionId)
        func cue(_ warning: Bool) -> String {
            if arm == "baseline" { return "toast_only" }
            if arm == "caw_audio" { return warning ? "toast+macos_Frog" : "toast+macos_Sosumi" }
            if !p.isEnabled { return "toast_only" }
            if arm == "haptic_vibe" { return warning ? "toast+vibe_35" : "toast+vibe_80" }
            var parts = ["toast"]
            let zap = warning ? p.warningShockIntensity : p.alertShockIntensity
            let vibe = warning ? p.warningVibeIntensity : p.alertVibeIntensity
            if zap > 0 { parts.append("zap_\(zap)") }
            if vibe > 0 { parts.append("vibe_\(vibe)") }
            if warning && p.warningBeepEnabled { parts.append("beep") }
            return parts.count == 1 ? "toast_only" : parts.joined(separator: "+")
        }
        return ["assignment_mode": HabitExperimentManager.shared.currentMode.rawValue,
                "arm": arm, "wearable_enabled": p.isEnabled,
                "warning_shock_percent": p.warningShockIntensity,
                "warning_vibe_percent": p.warningVibeIntensity,
                "warning_beep_enabled": p.warningBeepEnabled,
                "hard_stop_shock_percent": p.alertShockIntensity,
                "hard_stop_vibe_percent": p.alertVibeIntensity,
                "reward_enabled": p.rewardGoodBehavior && p.isEnabled,
                "reward_setting_enabled": p.rewardGoodBehavior,
                "reward_vibe_percent": p.rewardVibeIntensity,
                "reward_min_sec": rewardMinSec, "reward_max_exclusive_sec": warningThreshold,
                "warning_sec": warningThreshold, "hard_stop_sec": alertThreshold,
                "only_during_calls": alertOnlyDuringCalls,
                "cue_30": cue(true), "cue_60": cue(false)]
    }

    private func settingsKey(_ settings: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    // Screenpipe writes transcriptions in batches; when it lags, several segments arrive
    // with one arrival time and the wall-clock turn timing below is distorted. Track the
    // worst lag seen in a turn so affected rows are identifiable instead of silently wrong.
    private var maxIngestLagSec: Double = 0.0
    private var lastObservedIngestLagSec: Double = 0.0
    // Absolute audio-clock positions, derived from screenpipe's chunk timestamp plus the
    // segment's offset within that chunk. Turn boundaries are measured on this timeline,
    // not on when rows happened to arrive, so batch delivery cannot distort them.
    private var turnAudioStart: Date?
    private var lastSegmentAudioEnd: Date?
    // screenpipe emits both "…T16:10:12-04:00" and "…T15:12:11.241-04:00"; a formatter
    // configured for one returns nil for the other, which silently drops the audio clock.
    private static let plainDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parseScreenpipeDate(_ value: String) -> Date? {
        return fractionalDateFormatter.date(from: value) ?? plainDateFormatter.date(from: value)
    }

    var onStreakUpdated: ((TimeInterval) -> Void)?

    var canAlert: Bool {
        return !alertOnlyDuringCalls || (activeCallApp != nil)
    }

    /// The visual toast is the common floor across every arm, including baseline. The
    /// arms differ only in the stimulus added on top of it (audio, shock, vibe), so the
    /// experiment measures what each adds over the visual cue -- and the tool keeps
    /// working in every meeting. Briefly gated to non-baseline arms in Sept 2026; that
    /// silenced 25% of meetings for a purer control, which was the wrong trade.
    var armShowsToast: Bool {
        return true
    }

    private func recordIntervention(_ entry: [String: Any]) {
        interventionLock.lock()
        interventionLog.append(entry)
        interventionLock.unlock()
    }

    private func drainInterventions() -> [[String: Any]] {
        interventionLock.lock()
        let drained = interventionLog
        interventionLog = []
        interventionLock.unlock()
        return drained
    }

    private func noteToastShown() {
        guard !toastLoggedThisTurn else { return }
        toastLoggedThisTurn = true
        recordIntervention([
            "modality": "toast",
            "arm": HabitExperimentManager.shared.resolveArm(for: activeSessionId),
            "threshold": currentStreak >= alertThreshold ? "60s_hard_stop" : "30s_warning",
            "streak_sec_at_fire": currentStreak,
            "fired_at": ISO8601DateFormatter().string(from: Date()),
            "delivered": true,
            "detail": "visual panel shown"
        ])
    }

    var isWarningActive: Bool {
        return canAlert && currentStreak >= warningThreshold && currentStreak < alertThreshold
    }

    var isAlertActive: Bool {
        return canAlert && currentStreak >= alertThreshold
    }

    var formattedDuration: String {
        let total = max(0, Int(currentStreak))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    override init() {
        super.init()
        initLastCheckedId()
    }

    private func initLastCheckedId() {
        guard let url = URL(string: "http://localhost:3030/raw_sql") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let sql = "SELECT COALESCE(MAX(id), 0) as max_id FROM audio_transcriptions LIMIT 1;"
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["query": sql])
        req.timeoutInterval = 2.0

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let first = rows.first,
                  let maxId = (first["max_id"] as? NSNumber)?.int64Value ?? (first["max_id"] as? Int64) else { return }
            self.lastCheckedTranscriptionId = maxId
            self.isInitialized = true
            print("[SpeakingCoach] Connected to Screenpipe raw_sql (lastCheckedTranscriptionId: \(maxId))")
            fflush(stdout)
        }.resume()
    }

    func isValidSpokenText(_ raw: String) -> Bool {
        var text = raw
        text = text.replacingOccurrences(of: "\\[.*?\\]", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\(.*?\\)", with: "", options: .regularExpression)

        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.contains("sous-titrage") || lower.contains("subtitles by") || lower.contains("transcription by") || lower.contains("s.t.o.s") {
            return false
        }

        let words = text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return words.count >= 2
    }

    /// Poll screenpipe's live meeting transcript stream.
    ///
    /// Rows carry the capture start `captured_at` and `device_type`
    /// (input = the owner, output = everyone else), but no exact spoken-word end time.
    /// This path is also markedly faster than the background one: measured
    /// created_at - captured_at is ~2.4s, against 5-12s for chunked background STT.
    func checkLiveMeetingSegments() {
        guard let url = URL(string: "http://localhost:3030/raw_sql") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Until the watermark is set, ask only for MAX(id). Selecting `id > 0 ORDER BY id
        // ASC LIMIT 50` returns the OLDEST rows, which would walk the coach forward through
        // the entire history of past meetings one page at a time.
        let query = self.liveIsInitialized
            ? "SELECT id, device_type, transcript, captured_at FROM meeting_transcript_segments WHERE id > \(self.lastCheckedLiveSegmentId) ORDER BY id ASC LIMIT 50;"
            : "SELECT COALESCE(MAX(id), 0) AS id FROM meeting_transcript_segments LIMIT 1;"
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])
        req.timeoutInterval = 2.0

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

            DispatchQueue.main.async {
                // First poll only establishes the watermark; never replay history.
                if !self.liveIsInitialized {
                    if let first = rows.first,
                       let id = (first["id"] as? NSNumber)?.int64Value ?? (first["id"] as? Int64) {
                        self.lastCheckedLiveSegmentId = id
                        print("[SpeakingCoach] Live meeting transcript stream connected (lastCheckedLiveSegmentId: \(id))")
                        fflush(stdout)
                    }
                    self.liveIsInitialized = true
                    return
                }

                for row in rows {
                    guard let id = (row["id"] as? NSNumber)?.int64Value ?? (row["id"] as? Int64),
                          id > self.lastCheckedLiveSegmentId else { continue }
                    self.lastCheckedLiveSegmentId = max(self.lastCheckedLiveSegmentId, id)

                    let text = row["transcript"] as? String ?? ""
                    let isInput = (row["device_type"] as? String)?.lowercased() == "input"
                    guard let capturedAt = (row["captured_at"] as? String)
                        .flatMap({ TalkTimeMonitor.parseScreenpipeDate($0) }) else { continue }

                    // The live schema exposes capture START, not word-end timestamps.
                    // Use this confirmed audio point conservatively; never turn a word
                    // count into seconds or extend the turn into unobserved silence.
                    if capturedAt > (self.liveCoveredUntil ?? .distantPast) {
                        self.liveCoveredUntil = capturedAt
                    }
                    self.handleTranscriptionRow(rowId: id, chunkId: 0, isInput: isInput, text: text,
                                                startTime: 0, endTime: 0, writtenAt: capturedAt,
                                                usedLivePath: true)
                }
                self.updatePresentation()
            }
        }.resume()
    }

    func checkActiveCall() {
        guard let url = URL(string: "http://localhost:3030/meetings") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2.0
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self else { return }
            var newApp: String?
            var newTitle: String?
            if let data = data,
               let meetings = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let active = meetings.first(where: { ($0["meeting_end"] as? String) == nil }) {
                newApp = active["meeting_app"] as? String
                newTitle = active["title"] as? String
            }
            if newApp != self.activeCallApp {
                if let app = newApp {
                    let sanitized = app.lowercased().replacingOccurrences(of: " ", with: "_")
                    self.activeSessionId = "call_\(sanitized)_\(UUID().uuidString.prefix(8).lowercased())"
                    print("[SpeakingCoach] Active call detected: \(app) (\(newTitle ?? "")) -> Session: \(self.activeSessionId)")
                } else if self.activeCallApp != nil {
                    self.activeSessionId = "solo_\(UUID().uuidString.prefix(8).lowercased())"
                    print("[SpeakingCoach] Call ended")
                }
                fflush(stdout)
            }
            self.activeCallApp = newApp
            self.activeCallTitle = newTitle
        }.resume()
    }

    private func deliverStimulusForThreshold(isWarning: Bool) {
        let arm = HabitExperimentManager.shared.resolveArm(for: activeSessionId)
        let threshold = isWarning ? "30s_warning" : "60s_hard_stop"
        let streakAtFire = currentStreak
        print("[SpeakingCoach] Stimulus trigger (\(isWarning ? "30s warning" : "60s hard stop")) under arm: \(arm)")
        fflush(stdout)

        // Record what was attempted AND what the device/sound actually reported back, so a
        // failed dispatch is not indistinguishable from a delivered stimulus in the data.
        let record: (String, Bool?, String?) -> Void = { [weak self] modality, delivered, detail in
            guard let self = self else { return }
            self.recordIntervention([
                "modality": modality,
                "arm": arm,
                "threshold": threshold,
                "streak_sec_at_fire": streakAtFire,
                "fired_at": ISO8601DateFormatter().string(from: Date()),
                "delivered": delivered as Any? ?? NSNull(),
                "detail": detail as Any? ?? NSNull()
            ])
        }

        switch arm {
        case "caw_audio":
            let soundName = isWarning ? "Frog" : "Sosumi"
            let played = NSSound(named: soundName)?.play() ?? false
            if !played {
                NSSound.beep()
            }
            record(played ? "caw_audio" : "system_beep_fallback", true,
                   played ? soundName : "named sound unavailable, fell back to NSSound.beep()")
        case "pavlok_shock":
            if isWarning {
                PavlokController.shared.trigger30sWarning { ok, msg in record("pavlok_zap", ok, msg) }
            } else {
                PavlokController.shared.trigger60sHardStop { ok, msg in record("pavlok_zap", ok, msg) }
            }
        case "haptic_vibe":
            if isWarning {
                PavlokController.shared.sendStimulus(type: "vibe", value: 35, reason: "30s monologue warning vibe") { ok, msg in
                    record("pavlok_vibe", ok, msg)
                }
            } else {
                PavlokController.shared.sendStimulus(type: "vibe", value: 80, reason: "60s monologue hard stop vibe") { ok, msg in
                    record("pavlok_vibe", ok, msg)
                }
            }
        case "baseline":
            // Control arm: silent / observational baseline.
            record("none", nil, "control arm: no stimulus by design")
        default:
            if isWarning {
                PavlokController.shared.trigger30sWarning { ok, msg in record("pavlok_zap", ok, msg) }
            } else {
                PavlokController.shared.trigger60sHardStop { ok, msg in record("pavlok_zap", ok, msg) }
            }
        }
    }

    func tick() {
        updatePresentation()
        checkActiveCall()

        // Live meeting transcripts land in a different table; read both every tick.
        checkLiveMeetingSegments()

        // Fetch latest audio transcriptions via Screenpipe raw_sql endpoint
        guard let url = URL(string: "http://localhost:3030/raw_sql") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Same rule as the live poll: until the watermark is set, ask only for MAX(id). The
        // ascending page returns the OLDEST rows, and initialising from its last row (id 51)
        // replayed weeks of history as live speech whenever screenpipe came up after the coach.
        let query = self.isInitialized
            ? "SELECT t.id, t.audio_chunk_id, t.transcription, t.timestamp, t.start_time, t.end_time, c.file_path FROM audio_transcriptions t JOIN audio_chunks c ON t.audio_chunk_id = c.id WHERE t.id > \(self.lastCheckedTranscriptionId) ORDER BY t.id ASC LIMIT 50;"
            : "SELECT COALESCE(MAX(id), 0) AS id FROM audio_transcriptions LIMIT 1;"
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])
        req.timeoutInterval = 2.0

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

            DispatchQueue.main.async {
                if !self.isInitialized {
                    if let first = rows.first,
                       let id = (first["id"] as? NSNumber)?.int64Value ?? (first["id"] as? Int64) {
                        self.lastCheckedTranscriptionId = id
                        self.isInitialized = true
                        print("[SpeakingCoach] Connected to Screenpipe raw_sql (lastCheckedTranscriptionId: \(id))")
                        fflush(stdout)
                    }
                    return
                }

                for row in rows {
                    guard let id = (row["id"] as? NSNumber)?.int64Value ?? (row["id"] as? Int64),
                          id > self.lastCheckedTranscriptionId else { continue }

                    self.lastCheckedTranscriptionId = max(self.lastCheckedTranscriptionId, id)

                    let chunkId = (row["audio_chunk_id"] as? NSNumber)?.int64Value ?? 0
                    let filePath = row["file_path"] as? String ?? ""
                    let isInput = filePath.contains("input") || filePath.contains("Microphone")
                    let text = row["transcription"] as? String ?? ""
                    let startTime = (row["start_time"] as? NSNumber)?.doubleValue ?? 0.0
                    let endTime = (row["end_time"] as? NSNumber)?.doubleValue ?? 0.0
                    let writtenAt = (row["timestamp"] as? String).flatMap { TalkTimeMonitor.parseScreenpipeDate($0) }

                    // When a meeting ends, screenpipe back-fills audio_transcriptions with
                    // the same speech the live stream already delivered. Drop anything at or
                    // before the live watermark so a meeting is not counted twice.
                    if let covered = self.liveCoveredUntil, let audioStart = writtenAt?.addingTimeInterval(startTime),
                       audioStart <= covered {
                        continue
                    }

                    self.handleTranscriptionRow(rowId: id, chunkId: chunkId, isInput: isInput, text: text, startTime: startTime, endTime: endTime, writtenAt: writtenAt)
                }

                self.updatePresentation()
            }
        }.resume()
    }

    /// A timer can expire a turn, but only confirmed audio advances its clock.
    /// Calling this from the live callback avoids depending on background SQL.
    private func updatePresentation() {
        if let initial = turnTreatmentSettings, settingsKey(initial) != settingsKey(treatmentSettings()) {
            turnSettingsChanged = true
        }
        // Check if user stopped speaking (silence timeout)
        if let lastWallClock = self.lastSpeechWallClock {
            let elapsed = Date().timeIntervalSince(lastWallClock)
            // A transcription cannot arrive until its chunk closes, so silence is
            // only real once we have waited out the delivery lag as well.
            if elapsed > self.silenceTimeout + self.lastObservedIngestLagSec {
                print("[SpeakingCoach] Silence detected (\(Int(elapsed))s since last spoken word). Resetting monologue streak.")
                fflush(stdout)
                self.resetStreak()
            }
        }

        // Show toast only when in alert/warning threshold AND canAlert is enabled
        if self.canAlert && self.currentStreak >= self.warningThreshold && self.armShowsToast {
            self.noteToastShown()
            MonologueToastController.shared.show(self.currentStreak, callApp: self.activeCallApp)
        } else {
            MonologueToastController.shared.hide()
        }

        // Stimulus trigger (debounced one-shot per monologue streak)
        if self.canAlert {
            if self.currentStreak >= self.warningThreshold && !self.hasDeliveredStimulusAt30s {
                self.hasDeliveredStimulusAt30s = true
                self.hasWarnedPavlokThisMonologue = true
                self.warningFiredWallClock = Date()
                self.warningFiredStreakSec = self.currentStreak
                self.deliverStimulusForThreshold(isWarning: true)
            }
            if self.currentStreak >= self.alertThreshold && !self.hasDeliveredStimulusAt60s {
                self.hasDeliveredStimulusAt60s = true
                self.hasShockedPavlokThisMonologue = true
                self.shockFiredWallClock = Date()
                self.shockFiredStreakSec = self.currentStreak
                self.deliverStimulusForThreshold(isWarning: false)
            }
        }

        self.onStreakUpdated?(self.currentStreak)
    }

    /// Everything about a finished turn, captured before the live counters are cleared.
    private struct FinishedTurn {
        let streak: TimeInterval
        let words: Int
        let startedAt: Date?
        let endedAt: Date
        let warnedAt: Date?
        let shockedAt: Date?
        let warnedAtStreakSec: Double?
        let shockedAtStreakSec: Double?
        let interventions: [[String: Any]]
        let maxIngestLagSec: Double
        let audioClock: Bool
        let wasAlertable: Bool
        let usedLivePath: Bool
        let settings: [String: Any]
        let settingsChanged: Bool
    }

    private func finishTurnAndLog(_ turn: FinishedTurn) {
        evaluateGoodBehaviorReward(for: turn.streak, wasShocked: turn.shockedAt != nil)

        guard turn.streak >= 2.0 else { return }

        let arm = HabitExperimentManager.shared.resolveArm(for: activeSessionId)

        // Time from the warning firing to the speaker actually yielding. This used to be
        // computed after warningFiredWallClock had already been cleared, so it was always
        // null -- the experiment's primary behavioural outcome was never recorded.
        let latency: Double? = turn.warnedAt.flatMap { fired in
            let elapsed = turn.endedAt.timeIntervalSince(fired)
            return elapsed > 0 ? elapsed : nil
        }

        // First-to-last confirmed speech: internal pauses count, trailing silence does
        // not. Version the measurement so historical word-estimated turns stay distinct.
        let gapDurationSec = turn.startedAt.map { max(turn.streak, turn.endedAt.timeIntervalSince($0)) }
        let gapDurationValue: Any = gapDurationSec.map { $0 as Any } ?? NSNull()

        let category = activeCallApp != nil ? "work" : "solo"

        let confirmedDelivery = turn.interventions.contains { ($0["delivered"] as? Bool) == true }

        HabitEventLogger.shared.logTurn(
            occurredAt: turn.startedAt,
            sessionId: activeSessionId,
            callApp: activeCallApp,
            callCategory: category,
            treatmentArm: arm,
            turnDurationSec: turn.streak,
            wordsSpoken: turn.words,
            // The streak length when the stimulus actually fired, not the threshold constant.
            warningFiredAt: turn.warnedAtStreakSec,
            shockFiredAt: turn.shockedAtStreakSec,
            latencyToYieldSec: latency,
            breached30s: turn.streak > warningThreshold,
            breached60s: turn.streak > alertThreshold,
            wasRewarded: (turn.streak >= rewardMinSec && turn.streak < warningThreshold),
            metadata: [
                // GrowthBook's exposure query still filters on metadata.simulated = false.
                "simulated": false,
                "source": HabitEventLogger.liveSource,
                "measurement": "turn_gap",
                "timing_version": "confirmed_speech_span_v1",
                "design_version": "speech_coach_settings_v1",
                "treatment_settings": turn.settings,
                "settings_changed_during_turn": turn.settingsChanged,
                "reward_eligible": turn.streak >= rewardMinSec && turn.streak < warningThreshold && turn.shockedAt == nil,
                "reward_requested": canAlert && PavlokController.shared.isEnabled && PavlokController.shared.rewardGoodBehavior && turn.streak >= rewardMinSec && turn.streak < warningThreshold && turn.shockedAt == nil,
                "yield_latency_observed": latency != nil,

                "duration_basis": "first_to_last_confirmed_speech",
                "live_timestamp_precision": turn.usedLivePath ? "segment_start" : "segment_end",
                "turn_clock": turn.startedAt != nil && turn.audioClock ? "audio" : "arrival",
                "call_title": activeCallTitle ?? "",
                "gap_duration_sec": gapDurationValue,
                // Confirmation of what actually fired, per modality, including failures.
                "interventions": turn.interventions,
                "intervention_confirmed": confirmedDelivery,
                // False => the intervention could not fire, so this turn is not an
                // experimental unit. The analysis layer filters on this.
                "experiment_eligible": turn.wasAlertable,
                // Which screenpipe pipeline measured this turn. The live meeting stream is
                // ~2.4s behind the audio; chunked background STT is 5-12s.
                "transcription_path": turn.usedLivePath ? "live_meeting" : "background",
                // Screenpipe batch delivery distorts wall-clock turn timing; surface it.
                "screenpipe_version": CaptureEnvironment.screenpipeVersion as Any? ?? NSNull(),
                "screenpipe_app_version": CaptureEnvironment.screenpipeAppVersion as Any? ?? NSNull(),
                // A new screenpipe version is a new experiment phase; never pool across them.
                "capture_phase": CaptureEnvironment.capturePhase as Any? ?? NSNull(),
                "ingest_lag_sec_max": turn.maxIngestLagSec,
                "data_quality": turn.maxIngestLagSec > maxTrustedIngestLagSec ? "suspect_ingest_lag" : "ok",
                "toast_shown": turn.interventions.contains { ($0["modality"] as? String) == "toast" }
            ]
        )
    }

    private func evaluateGoodBehaviorReward(for streak: TimeInterval, wasShocked: Bool) {
        guard canAlert && PavlokController.shared.isEnabled && PavlokController.shared.rewardGoodBehavior else { return }
        if streak >= rewardMinSec && streak < warningThreshold && !wasShocked {
            print("[SpeakingCoach] 🌟 GOOD BEHAVIOR DETECTED! Concise turn of \(String(format: "%.1f", streak))s yielded cleanly without monologuing. Triggering reward vibration...")
            fflush(stdout)
            PavlokController.shared.sendStimulus(
                type: "vibe",
                value: PavlokController.shared.rewardVibeIntensity,
                reason: "Good behavior reward: Concise turn (\(Int(streak))s) yielded cleanly"
            )
        }
    }

    private func handleTranscriptionRow(rowId: Int64, chunkId: Int64, isInput: Bool, text: String, startTime: Double, endTime: Double, writtenAt: Date? = nil, usedLivePath: Bool = false) {
        guard isValidSpokenText(text) else { return }
        let now = Date()
        let segmentAudioStart = writtenAt.map { $0.addingTimeInterval(startTime) }
        let segmentAudioEnd = writtenAt.map { $0.addingTimeInterval(max(startTime, endTime)) }
        let speechStart = segmentAudioStart ?? now
        let speechEnd = segmentAudioEnd ?? now

        // Late rows from the previous floor holder must not reopen an ended turn.
        if let boundary = lastTurnBoundaryAt, speechStart <= boundary { return }
        if !isInput {
            // A detected handoff ends the turn at the last confirmed mic word,
            // or earlier if speech overlapped. The wait before the reply is excluded.
            print("[SpeakingCoach] Other participant spoke. Resetting monologue streak.")
            fflush(stdout)
            resetStreak(endedAt: speechStart)
            return
        }

        // Breathing pauses remain inside a turn. Long silence abandons it; neither
        // that trailing silence nor the delay waiting for ASR is added to its length.
        if let lastEnd = lastSegmentAudioEnd, speechStart.timeIntervalSince(lastEnd) > silenceTimeout {
            print("[SpeakingCoach] Long speech gap detected. Starting fresh turn.")
            resetStreak()
        } else if segmentAudioStart == nil, let received = lastSpeechWallClock,
                  now.timeIntervalSince(received) > silenceTimeout + max(0, lastObservedIngestLagSec) {
            resetStreak()
        }

        if turnStartWallClock == nil {
            turnTreatmentSettings = treatmentSettings()
            turnStartWallClock = now
            turnAudioStart = segmentAudioStart
        }
        if canAlert { turnWasAlertable = true }
        turnUsedLivePath = turnUsedLivePath || usedLivePath
        currentTurnWords += text.split { $0.isWhitespace }.count
        lastSpeechWallClock = now
        lastChunkId = chunkId
        lastAudioEndTime = endTime
        lastSegmentAudioEnd = max(lastSegmentAudioEnd ?? speechEnd, speechEnd)

        let firstSpeech = turnAudioStart ?? turnStartWallClock ?? now
        currentStreak = max(0, (lastSegmentAudioEnd ?? now).timeIntervalSince(firstSpeech))
        if let writtenAt = writtenAt {
            let lag = max(0, now.timeIntervalSince(writtenAt))
            lastObservedIngestLagSec = lag
            maxIngestLagSec = max(maxIngestLagSec, lag)
            if lag > maxTrustedIngestLagSec {
                print("[SpeakingCoach] Screenpipe ingest lag \(String(format: "%.1f", lag))s on row \(rowId) - turn timing is marked suspect.")
            }
        }
        print("[SpeakingCoach] Transcription [\(rowId)] (User Mic): \"\(text.prefix(35))...\" (confirmed turn span \(String(format: "%.1f", currentStreak))s)")
        print("[SpeakingCoach] User speaking streak now: \(formattedDuration) (warn: \(isWarningActive), alert: \(isAlertActive))")
        fflush(stdout)
    }

    func resetStreak(endedAt requestedEnd: Date? = nil) {
        let finishedSettings = turnTreatmentSettings ?? treatmentSettings()
        let settingsChanged = turnSettingsChanged || settingsKey(finishedSettings) != settingsKey(treatmentSettings())
        turnSettingsChanged = false
        turnTreatmentSettings = nil
        let finishedWords = currentTurnWords
        let startedAt = turnAudioStart ?? turnStartWallClock
        let confirmedEnd = lastSegmentAudioEnd ?? Date()
        let endedAt = requestedEnd.map { min($0, confirmedEnd) } ?? confirmedEnd
        let finishedStreak = startedAt.map { max(0, endedAt.timeIntervalSince($0)) } ?? currentStreak
        if let boundary = requestedEnd ?? lastSegmentAudioEnd {
            lastTurnBoundaryAt = max(lastTurnBoundaryAt ?? boundary, boundary)
        }
        let warnedAt = warningFiredWallClock
        let shockedAt = shockFiredWallClock
        let warnedAtStreak = warningFiredStreakSec
        let shockedAtStreak = shockFiredStreakSec
        let interventions = drainInterventions()
        let turnLag = maxIngestLagSec
        let audioClock = turnAudioStart != nil && lastSegmentAudioEnd != nil
        let wasAlertable = turnWasAlertable
        let usedLivePath = turnUsedLivePath

        currentStreak = 0.0
        currentTurnWords = 0
        lastSpeechWallClock = nil
        turnStartWallClock = nil
        turnAudioStart = nil
        lastSegmentAudioEnd = nil
        lastChunkId = 0
        lastAudioEndTime = 0.0
        hasWarnedPavlokThisMonologue = false
        hasShockedPavlokThisMonologue = false
        hasDeliveredStimulusAt30s = false
        hasDeliveredStimulusAt60s = false
        warningFiredWallClock = nil
        shockFiredWallClock = nil
        warningFiredStreakSec = nil
        shockFiredStreakSec = nil
        toastLoggedThisTurn = false
        maxIngestLagSec = 0.0
        turnWasAlertable = false
        turnUsedLivePath = false
        MonologueToastController.shared.hide()
        onStreakUpdated?(0.0)

        finishTurnAndLog(FinishedTurn(
            streak: finishedStreak, words: finishedWords,
            startedAt: startedAt, endedAt: endedAt,
            warnedAt: warnedAt, shockedAt: shockedAt,
            warnedAtStreakSec: warnedAtStreak, shockedAtStreakSec: shockedAtStreak,
            interventions: interventions,
            maxIngestLagSec: turnLag,
            audioClock: audioClock,
            wasAlertable: wasAlertable,
            usedLivePath: usedLivePath, settings: finishedSettings, settingsChanged: settingsChanged))
    }

}

// MARK: - Interactive Non-Closing Multi-Select Submenu Views
class Pavlok30sSubmenuView: NSView {
    let shockCheckbox: NSButton
    let shockSegment: NSSegmentedControl
    let vibeCheckbox: NSButton
    let vibeSegment: NSSegmentedControl
    let beepCheckbox: NSButton

    let shockLevels = [0, 10, 15, 20, 25, 30]
    let vibeLevels = [0, 20, 30, 50, 70]

    var onStateChanged: (() -> Void)?

    init() {
        self.shockCheckbox = NSButton(checkboxWithTitle: "⚡ Electric Shock", target: nil, action: nil)
        self.shockSegment = NSSegmentedControl(labels: ["0% Off", "10%", "15% ★", "20%", "25%", "30%"], trackingMode: .selectOne, target: nil, action: nil)
        self.vibeCheckbox = NSButton(checkboxWithTitle: "📳 Haptic Vibration", target: nil, action: nil)
        self.vibeSegment = NSSegmentedControl(labels: ["0% Off", "20%", "30% ★", "50%", "70%"], trackingMode: .selectOne, target: nil, action: nil)
        self.beepCheckbox = NSButton(checkboxWithTitle: "🔔 Audio Chime on Wristband (Beep)", target: nil, action: nil)

        super.init(frame: NSRect(x: 0, y: 0, width: 330, height: 216))

        setupViews()
        syncFromModel()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupViews() {
        var y: CGFloat = 186

        let titleLabel = NSTextField(labelWithString: "30s Warning Modalities (Multi-Select)")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 11)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.frame = NSRect(x: 16, y: y, width: 298, height: 16)
        addSubview(titleLabel)
        y -= 26

        shockCheckbox.frame = NSRect(x: 16, y: y, width: 298, height: 20)
        shockCheckbox.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        shockCheckbox.target = self
        shockCheckbox.action = #selector(shockCheckboxClicked(_:))
        addSubview(shockCheckbox)
        y -= 28

        shockSegment.frame = NSRect(x: 16, y: y, width: 298, height: 24)
        shockSegment.segmentDistribution = .fillEqually
        shockSegment.controlSize = .small
        shockSegment.font = NSFont.systemFont(ofSize: 10)
        shockSegment.target = self
        shockSegment.action = #selector(shockSegmentChanged(_:))
        addSubview(shockSegment)
        y -= 34

        vibeCheckbox.frame = NSRect(x: 16, y: y, width: 298, height: 20)
        vibeCheckbox.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        vibeCheckbox.target = self
        vibeCheckbox.action = #selector(vibeCheckboxClicked(_:))
        addSubview(vibeCheckbox)
        y -= 28

        vibeSegment.frame = NSRect(x: 16, y: y, width: 298, height: 24)
        vibeSegment.segmentDistribution = .fillEqually
        vibeSegment.controlSize = .small
        vibeSegment.font = NSFont.systemFont(ofSize: 10)
        vibeSegment.target = self
        vibeSegment.action = #selector(vibeSegmentChanged(_:))
        addSubview(vibeSegment)
        y -= 32

        beepCheckbox.frame = NSRect(x: 16, y: y, width: 298, height: 20)
        beepCheckbox.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        beepCheckbox.target = self
        beepCheckbox.action = #selector(beepCheckboxClicked(_:))
        addSubview(beepCheckbox)
        y -= 24

        let tipLabel = NSTextField(labelWithString: "💡 Multi-select active • Click outside to close")
        tipLabel.font = NSFont.systemFont(ofSize: 10)
        tipLabel.textColor = .tertiaryLabelColor
        tipLabel.alignment = .center
        tipLabel.frame = NSRect(x: 16, y: y, width: 298, height: 14)
        addSubview(tipLabel)
    }

    func syncFromModel() {
        let p = PavlokController.shared
        let isShock = p.warningShockIntensity > 0
        shockCheckbox.state = isShock ? .on : .off
        shockCheckbox.title = isShock ? "⚡ Electric Shock (Active: \(p.warningShockIntensity)%)" : "⚡ Electric Shock (0% / Disabled)"
        if let idx = shockLevels.firstIndex(of: p.warningShockIntensity) {
            shockSegment.selectedSegment = idx
        } else {
            shockSegment.selectedSegment = 0
        }

        let isVibe = p.warningVibeIntensity > 0
        vibeCheckbox.state = isVibe ? .on : .off
        vibeCheckbox.title = isVibe ? "📳 Haptic Vibration (Active: \(p.warningVibeIntensity)%)" : "📳 Haptic Vibration (0% / Disabled)"
        if let idx = vibeLevels.firstIndex(of: p.warningVibeIntensity) {
            vibeSegment.selectedSegment = idx
        } else {
            vibeSegment.selectedSegment = 0
        }

        beepCheckbox.state = p.warningBeepEnabled ? .on : .off
        beepCheckbox.title = p.warningBeepEnabled ? "🔔 Audio Chime on Wristband (Active)" : "🔔 Audio Chime on Wristband (Off)"
    }

    @objc func shockCheckboxClicked(_ sender: NSButton) {
        PavlokController.shared.toggle30sShock()
        syncFromModel()
        onStateChanged?()
    }

    @objc func shockSegmentChanged(_ sender: NSSegmentedControl) {
        let idx = sender.selectedSegment
        guard idx >= 0 && idx < shockLevels.count else { return }
        PavlokController.shared.warningShockIntensity = shockLevels[idx]
        syncFromModel()
        onStateChanged?()
    }

    @objc func vibeCheckboxClicked(_ sender: NSButton) {
        PavlokController.shared.toggle30sVibe()
        syncFromModel()
        onStateChanged?()
    }

    @objc func vibeSegmentChanged(_ sender: NSSegmentedControl) {
        let idx = sender.selectedSegment
        guard idx >= 0 && idx < vibeLevels.count else { return }
        PavlokController.shared.warningVibeIntensity = vibeLevels[idx]
        syncFromModel()
        onStateChanged?()
    }

    @objc func beepCheckboxClicked(_ sender: NSButton) {
        PavlokController.shared.toggle30sBeep()
        syncFromModel()
        onStateChanged?()
    }
}

class Pavlok60sSubmenuView: NSView {
    let shockCheckbox: NSButton
    let shockSegment: NSSegmentedControl
    let vibeCheckbox: NSButton
    let vibeSegment: NSSegmentedControl

    let shockLevels = [0, 15, 25, 35, 50, 70, 100]
    let vibeLevels = [0, 30, 60, 80, 100]

    var onStateChanged: (() -> Void)?

    init() {
        self.shockCheckbox = NSButton(checkboxWithTitle: "⚡ Electric Shock", target: nil, action: nil)
        self.shockSegment = NSSegmentedControl(labels: ["0% Off", "15%", "25%", "35% ★", "50%", "70%", "100%"], trackingMode: .selectOne, target: nil, action: nil)
        self.vibeCheckbox = NSButton(checkboxWithTitle: "📳 Haptic Vibration", target: nil, action: nil)
        self.vibeSegment = NSSegmentedControl(labels: ["0% Off", "30%", "60% ★", "80%", "100%"], trackingMode: .selectOne, target: nil, action: nil)

        super.init(frame: NSRect(x: 0, y: 0, width: 350, height: 184))

        setupViews()
        syncFromModel()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupViews() {
        var y: CGFloat = 154

        let titleLabel = NSTextField(labelWithString: "60s Hard Stop Modalities (Multi-Select)")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 11)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.frame = NSRect(x: 16, y: y, width: 318, height: 16)
        addSubview(titleLabel)
        y -= 26

        shockCheckbox.frame = NSRect(x: 16, y: y, width: 318, height: 20)
        shockCheckbox.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        shockCheckbox.target = self
        shockCheckbox.action = #selector(shockCheckboxClicked(_:))
        addSubview(shockCheckbox)
        y -= 28

        shockSegment.frame = NSRect(x: 16, y: y, width: 318, height: 24)
        shockSegment.segmentDistribution = .fillEqually
        shockSegment.controlSize = .small
        shockSegment.font = NSFont.systemFont(ofSize: 10)
        shockSegment.target = self
        shockSegment.action = #selector(shockSegmentChanged(_:))
        addSubview(shockSegment)
        y -= 34

        vibeCheckbox.frame = NSRect(x: 16, y: y, width: 318, height: 20)
        vibeCheckbox.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        vibeCheckbox.target = self
        vibeCheckbox.action = #selector(vibeCheckboxClicked(_:))
        addSubview(vibeCheckbox)
        y -= 28

        vibeSegment.frame = NSRect(x: 16, y: y, width: 318, height: 24)
        vibeSegment.segmentDistribution = .fillEqually
        vibeSegment.controlSize = .small
        vibeSegment.font = NSFont.systemFont(ofSize: 10)
        vibeSegment.target = self
        vibeSegment.action = #selector(vibeSegmentChanged(_:))
        addSubview(vibeSegment)
        y -= 26

        let tipLabel = NSTextField(labelWithString: "💡 Multi-select active • Click outside to close")
        tipLabel.font = NSFont.systemFont(ofSize: 10)
        tipLabel.textColor = .tertiaryLabelColor
        tipLabel.alignment = .center
        tipLabel.frame = NSRect(x: 16, y: y, width: 318, height: 14)
        addSubview(tipLabel)
    }

    func syncFromModel() {
        let p = PavlokController.shared
        let isShock = p.alertShockIntensity > 0
        shockCheckbox.state = isShock ? .on : .off
        shockCheckbox.title = isShock ? "⚡ Electric Shock (Active: \(p.alertShockIntensity)%)" : "⚡ Electric Shock (0% / Disabled)"
        if let idx = shockLevels.firstIndex(of: p.alertShockIntensity) {
            shockSegment.selectedSegment = idx
        } else {
            shockSegment.selectedSegment = 0
        }

        let isVibe = p.alertVibeIntensity > 0
        vibeCheckbox.state = isVibe ? .on : .off
        vibeCheckbox.title = isVibe ? "📳 Haptic Vibration (Active: \(p.alertVibeIntensity)%)" : "📳 Haptic Vibration (0% / Disabled)"
        if let idx = vibeLevels.firstIndex(of: p.alertVibeIntensity) {
            vibeSegment.selectedSegment = idx
        } else {
            vibeSegment.selectedSegment = 0
        }
    }

    @objc func shockCheckboxClicked(_ sender: NSButton) {
        PavlokController.shared.toggle60sShock()
        syncFromModel()
        onStateChanged?()
    }

    @objc func shockSegmentChanged(_ sender: NSSegmentedControl) {
        let idx = sender.selectedSegment
        guard idx >= 0 && idx < shockLevels.count else { return }
        PavlokController.shared.alertShockIntensity = shockLevels[idx]
        syncFromModel()
        onStateChanged?()
    }

    @objc func vibeCheckboxClicked(_ sender: NSButton) {
        PavlokController.shared.toggle60sVibe()
        syncFromModel()
        onStateChanged?()
    }

    @objc func vibeSegmentChanged(_ sender: NSSegmentedControl) {
        let idx = sender.selectedSegment
        guard idx >= 0 && idx < vibeLevels.count else { return }
        PavlokController.shared.alertVibeIntensity = vibeLevels[idx]
        syncFromModel()
        onStateChanged?()
    }
}

/// Bench test panel: one intensity slider and one fire button per modality, plus a
/// live result line. Lives in a view-based menu item so the menu stays open -- the
/// whole point is to press, feel the wrist, adjust, press again.
// MARK: - Cute Dog Stick Figure Bluetooth Connection Icon
class PavlokDogIcon {
    private static let connectedImage: NSImage = {
        let img = buildImage(connected: true, isScanning: false)
        img.isTemplate = false
        return img
    }()

    private static let disconnectedImage: NSImage = {
        let img = buildImage(connected: false, isScanning: false)
        img.isTemplate = false
        return img
    }()

    private static let scanningImage: NSImage = {
        let img = buildImage(connected: false, isScanning: true)
        img.isTemplate = false
        return img
    }()

    static func image(connected: Bool, isScanning: Bool = false) -> NSImage {
        if connected {
            return connectedImage
        } else if isScanning {
            return scanningImage
        } else {
            return disconnectedImage
        }
    }

    private static func buildImage(connected: Bool, isScanning: Bool) -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            let strokeColor = NSColor.controlTextColor
            strokeColor.setStroke()
            strokeColor.setFill()

            // --- Dog Stick Figure Geometry ---
            let body = NSBezierPath()
            body.lineWidth = 1.6
            body.lineCapStyle = .round
            body.lineJoinStyle = .round

            // Horizontal Torso
            body.move(to: NSPoint(x: 6.5, y: 7.0))
            body.line(to: NSPoint(x: 14.5, y: 7.0))

            // Neck connecting torso to head
            body.move(to: NSPoint(x: 14.5, y: 7.0))
            body.line(to: NSPoint(x: 15.5, y: 10.5))

            // Perky happy stick tail
            body.move(to: NSPoint(x: 6.5, y: 7.0))
            body.curve(to: NSPoint(x: 3.5, y: 13.0),
                       controlPoint1: NSPoint(x: 5.2, y: 8.5),
                       controlPoint2: NSPoint(x: 4.2, y: 11.2))

            // Hind Legs (2 stick legs with tiny paw touches)
            body.move(to: NSPoint(x: 6.5, y: 7.0))
            body.line(to: NSPoint(x: 5.5, y: 2.0))
            body.line(to: NSPoint(x: 4.5, y: 2.0)) // back paw

            body.move(to: NSPoint(x: 8.2, y: 7.0))
            body.line(to: NSPoint(x: 7.5, y: 2.0))
            body.line(to: NSPoint(x: 6.8, y: 2.0))

            // Front Legs (2 stick legs with tiny paw touches)
            body.move(to: NSPoint(x: 13.0, y: 7.0))
            body.line(to: NSPoint(x: 13.0, y: 2.0))
            body.line(to: NSPoint(x: 13.8, y: 2.0))

            body.move(to: NSPoint(x: 14.5, y: 7.0))
            body.line(to: NSPoint(x: 15.0, y: 2.0))
            body.line(to: NSPoint(x: 16.0, y: 2.0)) // front paw

            body.stroke()

            // Head Outline
            let headRect = NSRect(x: 13.5, y: 8.5, width: 6.8, height: 6.2)
            let head = NSBezierPath(ovalIn: headRect)
            head.lineWidth = 1.4
            head.stroke()

            // Cute Floppy Puppy Ear
            let ear = NSBezierPath()
            ear.lineWidth = 1.6
            ear.lineCapStyle = .round
            ear.move(to: NSPoint(x: 14.6, y: 13.8))
            ear.curve(to: NSPoint(x: 12.0, y: 9.0),
                      controlPoint1: NSPoint(x: 12.8, y: 13.5),
                      controlPoint2: NSPoint(x: 11.8, y: 11.0))
            ear.stroke()

            // Cute Snout / Nose dot
            let noseRect = NSRect(x: 19.5, y: 11.0, width: 1.6, height: 1.6)
            let nose = NSBezierPath(ovalIn: noseRect)
            nose.fill()

            // Cute Eye dot
            let eyeRect = NSRect(x: 16.5, y: 11.8, width: 1.2, height: 1.2)
            let eye = NSBezierPath(ovalIn: eyeRect)
            eye.fill()

            if connected {
                // Connected variation: clean stick figure dog without disconnect overlay!
            } else if isScanning {
                // Scanning: cute sniffing / searching dots near snout in cyan
                NSColor.systemCyan.setFill()
                let d1 = NSBezierPath(ovalIn: NSRect(x: 21.0, y: 12.0, width: 1.6, height: 1.6))
                let d2 = NSBezierPath(ovalIn: NSRect(x: 21.0, y: 9.0, width: 1.4, height: 1.4))
                d1.fill()
                d2.fill()
            } else {
                // Disconnected variation: Cutout gap + Red disconnect slash overlay across the dog
                ctx.saveGState()
                ctx.setBlendMode(.clear)
                ctx.setLineWidth(3.6)
                ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: 2.5, y: 15.5))
                ctx.addLine(to: CGPoint(x: 19.5, y: 1.5))
                ctx.strokePath()
                ctx.restoreGState()

                let slash = NSBezierPath()
                slash.lineWidth = 2.0
                slash.lineCapStyle = .round
                slash.move(to: NSPoint(x: 2.5, y: 15.5))
                slash.line(to: NSPoint(x: 19.5, y: 1.5))
                NSColor.systemRed.setStroke()
                slash.stroke()
            }

            return true
        }
        return img
    }
}

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
                    "watch", "--no-initial-sync"],
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
            add("   ⚠️ \(provider) login expired — Sign In Again...", #selector(signInToVault(_:))).representedObject = provider
        }
        _ = add("   📥 Pull Latest Chats (Incremental Sweep)", #selector(pullVaultChats))

        let outbox = OutboxSender.shared
        let serverState = !isServerReachable ? "🔴 unreachable" : outbox.keyProblem ? "🔑 no working device key" : "🟢 reachable"
        statusMenu.addItem(NSMenuItem(title: "☁️ learner-server: \(serverState)", action: nil, keyEquivalent: ""))
        _ = add("   └─ 📤 \(HabitEventLogger.shared.getUnsyncedCount()) queued | last: \(outbox.lastStatus)"
            + " | Tunnel \(tunnel.isRunning ? "🟢" : "🔴") | Watcher \(watcher.isRunning ? "🟢" : "🔴")")
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
        OutboxSender.shared.tick(heartbeat: { [weak self] in self?.heartbeatInput() ?? [:] })
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
        let setenv = Process()
        setenv.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        setenv.arguments = ["setenv", "SCREENPIPE_SKIP_ONBOARDING", "1"]
        try? setenv.run()
        setenv.waitUntilExit()
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

    @objc func signInToVault(_ sender: NSMenuItem) {
        guard let provider = sender.representedObject as? String else { return }
        VaultSignIn.show(provider)
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
        print("[Shutdown] Clean shutdown complete.")
        fflush(stdout)
        return .terminateNow
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

}

// MARK: - Headless Test Fire
//
// `--pavlok-test-fire <vibe|beep|zap> [intensity]` fires one stimulus and exits, so the
// wristband can be exercised from a terminal or a script without opening the menu.
// It borrows the feature for the length of one shot: whatever `pavlok_shock_enabled`
// and the test intensities were before the process started, they are that again after.
func runPavlokTestFireCLI() {
    let args = CommandLine.arguments
    guard let idx = args.firstIndex(of: "--pavlok-test-fire") else { return }

    let usage = "usage: --pavlok-test-fire <vibe|beep|zap> [intensity 1-100] [--wait seconds] [--trace-ble]\n" +
                "       the intensity argument applies to this shot only; the saved level is left alone\n" +
                "       --wait     how long to look for the wristband (default 15s)\n" +
                "       --trace-ble  log every advertising peripheral the filter rejects\n"
    let type = (idx + 1 < args.count) ? args[idx + 1].lowercased() : ""
    guard ["vibe", "beep", "zap"].contains(type) else {
        FileHandle.standardError.write(Data(usage.utf8))
        exit(2)
    }
    var override: Int? = nil
    if idx + 2 < args.count, !args[idx + 2].hasPrefix("--") {
        guard let parsed = Int(args[idx + 2]), parsed >= 1, parsed <= 100 else {
            FileHandle.standardError.write(Data(usage.utf8))
            exit(2)
        }
        override = parsed
    }

    PavlokController.traceBleDiscovery = args.contains("--trace-ble")
    var connectWait: TimeInterval = 15.0
    if let w = args.firstIndex(of: "--wait") {
        guard w + 1 < args.count else {
            FileHandle.standardError.write(Data(usage.utf8))
            exit(2)
        }
        guard let seconds = Double(args[w + 1]), seconds > 0, seconds <= 300 else {
            FileHandle.standardError.write(Data(usage.utf8))
            exit(2)
        }
        connectWait = seconds
    }

    // Everything the controller prints goes to the log the LaunchAgent writes, so a fire
    // from the terminal leaves its record next to one from the menu. The one-line verdict
    // still reaches the terminal, through a descriptor saved before the redirect.
    let terminalOut = dup(STDOUT_FILENO)
    let logDir = NSHomeDirectory() + "/.ai-aggregator/logs"
    try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    freopen(logDir + "/menubar.log", "a", stdout)
    setvbuf(stdout, nil, _IOLBF, 0)

    func verdict(_ line: String) {
        print(line)
        fflush(stdout)
        if terminalOut >= 0 {
            var bytes = Array((line + "\n").utf8)
            _ = write(terminalOut, &bytes, bytes.count)
        }
    }

    if let bundleID = Bundle.main.bundleIdentifier,
       let resident = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
        let id = UUID().uuidString.lowercased()
        let level = override ?? UserDefaults.standard.object(forKey: "pavlok_test_\(type)_intensity") as? Int
            ?? (type == "zap" ? 10 : 40)
        guard (1...100).contains(level) else { verdict("[Pavlok TestFire] FAILED: intensity is off"); exit(1) }
        let center = DistributedNotificationCenter.default()
        let observer = center.addObserver(forName: Notification.Name("com.benpollack.pavlok.test-result"),
                                           object: id, queue: .main) { note in
            let ok = note.userInfo?["success"] as? Bool ?? false
            let detail = note.userInfo?["detail"] as? String ?? "No result"
            verdict("[Pavlok TestFire] \(ok ? "DELIVERED" : "FAILED"): \(type) \(level)% • \(detail) • resident connection retained")
            exit(ok ? 0 : 1)
        }
        _ = observer
        verdict("[Pavlok TestFire] requested \(type) at \(level)% through resident app")
        center.postNotificationName(Notification.Name("com.benpollack.pavlok.test-request"),
            object: String(resident.processIdentifier),
            userInfo: ["id": id, "type": type, "intensity": level, "sent_at": Date().timeIntervalSince1970],
            deliverImmediately: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
            verdict("[Pavlok TestFire] OUTCOME UNKNOWN: resident did not reply; not retrying")
            exit(1)
        }
        RunLoop.main.run()
        return
    }

    // This process has no window and is never frontmost, so App Nap throttles it -- and a
    // throttled process gets its CoreBluetooth discovery callbacks delivered late or not
    // at all, which looks exactly like a wristband that is not there.
    let activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .idleSystemSleepDisabled],
        reason: "Pavlok headless test fire")

    let testKey = "pavlok_test_\(type)_intensity"
    let originalIntensity = UserDefaults.standard.object(forKey: testKey)
    let originalEnabled = UserDefaults.standard.object(forKey: "pavlok_shock_enabled")
    let pavlok = PavlokController.shared
    let wasEnabled = pavlok.isEnabled
    let savedIntensity = pavlok.testIntensity(for: type)
    if let level = override { pavlok.setTestIntensity(level, for: type) }

    func restoreAndExit(_ code: Int32) -> Never {
        pavlok.setTestIntensity(savedIntensity, for: type)
        if !wasEnabled { pavlok.isEnabled = false }
        if let originalIntensity = originalIntensity {
            UserDefaults.standard.set(originalIntensity, forKey: testKey)
        } else {
            UserDefaults.standard.removeObject(forKey: testKey)
        }
        if originalEnabled == nil { UserDefaults.standard.removeObject(forKey: pavlok.kPavlokEnabled) }
        UserDefaults.standard.synchronize()
        ProcessInfo.processInfo.endActivity(activity)
        exit(code)
    }

    let level = pavlok.testIntensity(for: type)
    let operationID = UUID().uuidString.lowercased()
    let connectionAudit = pavlok.interventionAudit(type: type, intensity: level,
        reason: "Headless manual test", id: operationID, manual: true)
    connectionAudit("connection_requested", nil, nil)
    verdict("[Pavlok TestFire] requested \(PavlokController.testFireLabel(for: type)) at \(level)% (headless)")

    // Enabling is what creates the CBCentralManager and starts the scan; there is no
    // other way to reach the radio, and it is put back the way it was on the way out.
    pavlok.isEnabled = true

    let connectDeadline = Date().addingTimeInterval(connectWait)
    DispatchQueue.global(qos: .userInitiated).async {
        while !pavlok.isReadyForStimulus(type) && Date() < connectDeadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        DispatchQueue.main.async {
            if pavlok.isReadyForStimulus(type) {
                verdict("[Pavlok TestFire] transport: direct Bluetooth to \(pavlok.bleDeviceName ?? "wristband")")

            } else {
                verdict("[Pavlok TestFire] transport: Bluetooth not ready; cloud is excluded from connection tests")
            }
            pavlok.testFire(type: type, operationID: operationID) { ok, detail in
                verdict("[Pavlok TestFire] \(ok ? "DELIVERED" : "FAILED"): \(pavlok.lastTestFireSummary)")
                if !ok { verdict("[Pavlok TestFire] reason: \(detail)") }
                // A .withoutResponse BLE write is queued, not sent, when writeValue returns.
                // Tearing the process down immediately can drop it on the floor.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    restoreAndExit(ok ? 0 : 1)
                }
            }
        }
    }

    // Nothing here should ever take this long; exit rather than hang a script forever.
    let watchdog = connectWait + 20.0
    DispatchQueue.main.asyncAfter(deadline: .now() + watchdog) {
        connectionAudit("result", false, "Headless test watchdog timed out")
        verdict("[Pavlok TestFire] FAILED: timed out after \(Int(watchdog))s")
        restoreAndExit(1)
    }

    RunLoop.main.run()
}

// MARK: - Application Entrypoint

if CommandLine.arguments.contains("--pavlok-test-fire") {
    runPavlokTestFireCLI()
}

// `--drain-outbox` sends the outbox once (LEARNER_API_URL / LEARNER_API_KEY /
// LEARNER_OUTBOX_DB override the defaults) and exits 0 when it is empty.
if CommandLine.arguments.contains("--drain-outbox") {
    let left = OutboxSender.shared.drain(until: Date().addingTimeInterval(120))
    print("[Outbox] drain finished: \(left) unsent, last status: \(OutboxSender.shared.lastStatus)")
    HabitEventLogger.shared.close()
    exit(left == 0 ? 0 : 1)
}

let app = NSApplication.shared
let delegate = TrayAppManager()
app.delegate = delegate
AppLog.attachToFile()
delegate.installSignalHandlers()
// .accessory activation policy places the app in the system tray / menu bar without taking up Dock space
app.setActivationPolicy(.accessory)
app.run()
