import AppKit
import Foundation
import ServiceManagement
import SQLite3
import CoreBluetooth
import CommonCrypto

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
        // Connected but unusable (discovery stalled) would never reconnect on its own.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self = self, peripheral.state == .connected,
                  self.shockCharacteristic == nil && self.vibeCharacteristic == nil else { return }
            self.dropUnusable(peripheral, "no stimulus characteristics 15 s after connecting")
        }
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChanged?()
        }
    }

    /// Disconnecting hands it to didDisconnectPeripheral, which reconnects with backoff.
    private func dropUnusable(_ peripheral: CBPeripheral, _ why: String) {
        print("[Pavlok BLE] ⚠️ Connected but unusable (\(why)); reconnecting")
        fflush(stdout)
        centralManager?.cancelPeripheralConnection(peripheral)
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
            dropUnusable(peripheral, "service discovery: \(error.localizedDescription)")
            return
        }
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            dropUnusable(peripheral, "characteristic discovery: \(error.localizedDescription)")
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
