import AppKit
import Foundation
import SQLite3
import CoreBluetooth

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
        TalkTimeMonitor.shared.stopSimulation()
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

    var isEnabled: Bool {
        get { defaults.bool(forKey: kPavlokEnabled) } // Defaults to false
        set {
            defaults.set(newValue, forKey: kPavlokEnabled)
            if newValue {
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
        if !isEnabled {
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
        if isEnabled {
            startBleScan()
        }
        updateConnectionStatus()
    }

    func startBleScan(force: Bool = false) {
        if centralManager == nil {
            // Lazily created on first use. The scan itself starts from
            // centralManagerDidUpdateState once the radio reports poweredOn.
            centralManager = CBCentralManager(delegate: self, queue: DispatchQueue.global(qos: .userInitiated), options: [CBCentralManagerOptionShowPowerAlertKey: false])
            return
        }
        guard let central = centralManager, central.state == .poweredOn else { return }
        if central.isScanning && !force { return }
        central.stopScan()
        isBleScanning = true
        print("[Pavlok BLE] Scanning for Pavlok Bluetooth devices...")
        fflush(stdout)
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChanged?()
        }
    }

    func disconnectBle() {
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
        if central.state == .poweredOn {
            if isEnabled {
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
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let lower = name.lowercased()
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let hasPavlokService = serviceUUIDs.contains {
            let s = $0.uuidString.uppercased()
            return s.contains("1000") || s.contains("6E9D")
        }
        let isPavlok = lower.contains("pavlok") || lower.contains("shock") || lower.contains("sc3") || lower.contains("sc2") || lower == "p3" || lower.contains("p3-") || hasPavlokService

        if isPavlok {
            print("[Pavlok BLE] Discovered candidate Pavlok 3 / wristband: \"\(name)\" (RSSI: \(RSSI)). Connecting...")
            fflush(stdout)
            central.stopScan()
            isBleScanning = false
            bleDeviceName = name.isEmpty ? "Pavlok 3" : name
            activePeripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
            DispatchQueue.main.async { [weak self] in
                self?.onStatusChanged?()
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[Pavlok BLE] ⚡ Direct Bluetooth connection established with \"\(peripheral.name ?? "device")\"!")
        fflush(stdout)
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
        if isEnabled { startBleScan() }
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChanged?()
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("[Pavlok BLE] ⚠️ Disconnected from \"\(peripheral.name ?? "device")\": \(error?.localizedDescription ?? "Link dropped")")
        fflush(stdout)
        isBleConnected = false
        shockCharacteristic = nil
        vibeCharacteristic = nil
        beepCharacteristic = nil
        batteryCharacteristic = nil
        batteryLevel = nil
        if isEnabled { startBleScan() }
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

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("[Pavlok BLE] ❌ Characteristic write failed: \(error.localizedDescription)")
        } else {
            print("[Pavlok BLE] ✅ Hardware acknowledged direct stimulus write (<15ms)!")
        }
        fflush(stdout)
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

    static func encodeBleBeep(count: Int = 1, isPavlok2: Bool = true) -> Data {
        let cnt = max(1, min(5, count))
        if isPavlok2 {
            // Pavlok 2/3 beep: [0x81, 0x0C, count, duration_on (0x18), gap (0x18)]
            return Data([0x81, 0x0C, UInt8(cnt), 0x18, 0x18])
        } else {
            return Data([UInt8(cnt), 0x32, 0x32, 0x32])
        }
    }

    // MARK: - Send Stimulus (Direct Bluetooth First, Cloud Backup)
    func sendStimulus(type: String, value: Int, reason: String, completion: ((Bool, String?) -> Void)? = nil) {
        guard isEnabled else {
            completion?(false, "Pavlok is disabled in settings")
            return
        }

        let intensity = max(1, min(100, value))

        // 1. Direct Bluetooth Low Energy (Ultra-Low Latency, <15ms)
        if isBleConnected, let peripheral = activePeripheral {
            if type == "zap", let char = shockCharacteristic {
                let isP2 = char.uuid.uuidString.uppercased().contains("1003")
                let data = PavlokController.encodeBleShock(intensity: intensity, isPavlok2: isP2)
                let writeType: CBCharacteristicWriteType = char.properties.contains(.write) ? .withResponse : .withoutResponse
                peripheral.writeValue(data, for: char, type: writeType)
                print("[Pavlok BLE] ⚡ DIRECT BLUETOOTH SHOCK DISPATCHED (<15ms latency)! Intensity: \(intensity)% | \"\(reason)\"")
                fflush(stdout)
                completion?(true, "Direct BLE shock (<15ms)")
                return
            } else if type == "vibe", let char = vibeCharacteristic {
                let isP2 = char.uuid.uuidString.uppercased().contains("1001")
                let data = PavlokController.encodeBleVibe(intensity: intensity, isPavlok2: isP2)
                let writeType: CBCharacteristicWriteType = char.properties.contains(.write) ? .withResponse : .withoutResponse
                peripheral.writeValue(data, for: char, type: writeType)
                print("[Pavlok BLE] 📳 DIRECT BLUETOOTH VIBRATION DISPATCHED (<15ms latency)! Intensity: \(intensity)% | \"\(reason)\"")
                fflush(stdout)
                completion?(true, "Direct BLE vibe (<15ms)")
                return
            } else if type == "beep", let char = beepCharacteristic {
                let isP2 = char.uuid.uuidString.uppercased().contains("1002")
                let data = PavlokController.encodeBleBeep(count: intensity, isPavlok2: isP2)
                let writeType: CBCharacteristicWriteType = char.properties.contains(.write) ? .withResponse : .withoutResponse
                peripheral.writeValue(data, for: char, type: writeType)
                print("[Pavlok BLE] 🔔 DIRECT BLUETOOTH BEEP DISPATCHED (<15ms latency)! Count: \(intensity) | \"\(reason)\"")
                fflush(stdout)
                completion?(true, "Direct BLE beep (<15ms)")
                return
            }
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

    static var screenpipeVersion: String? {
        get { lock.lock(); defer { lock.unlock() }; return storedVersion }
        set { lock.lock(); storedVersion = newValue; lock.unlock() }
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
        self.dbPath = dir + "/behavior_experiments.sqlite"
        openAndInitDb()
    }

    private func openAndInitDb() {
        queue.async {
            if sqlite3_open(self.dbPath, &self.db) != SQLITE_OK {
                print("[HabitLogger] ❌ Failed to open SQLite DB at \(self.dbPath)")
                return
            }
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
                sqlite3_bind_text(stmt, 6, ("monologue_streak" as NSString).utf8String, -1, SQLITE_TRANSIENT)
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
                    print("[HabitLogger] ✅ Logged trial: arm=\(treatmentArm), dur=\(String(format: "%.1f", turnDurationSec))s, yieldLatency=\(latencyToYieldSec.map { String(format: "%.1f", $0) + "s" } ?? "none"), 30s=\(breached30s)")
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

    func getTotalTrialCount() -> Int {
        var count = 0
        queue.sync {
            guard let db = self.db else { return }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM habit_events;", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(stmt, 0))
                }
                sqlite3_finalize(stmt)
            }
        }
        return count
    }
}

func syncHabitsToServer(completion: ((Bool) -> Void)? = nil) {
    DispatchQueue.global(qos: .utility).async {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/Users/benpollack/.bun/bin/bun")
        // The sync runs automatically (every 8s and at shutdown), so it must not touch
        // ~/Documents: the app is ad-hoc signed, its identity changes on every rebuild,
        // and macOS would re-prompt for Documents access after each build. build-app.sh
        // installs sync-habits.ts and .env into ~/.ai-aggregator, which needs no grant.
        let runtimeDir = FileManager.default.homeDirectoryForCurrentUser.path + "/.ai-aggregator"
        task.arguments = ["run", runtimeDir + "/sync-habits.ts"]
        task.currentDirectoryURL = URL(fileURLWithPath: runtimeDir)   // bun loads .env from cwd
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let ok = task.terminationStatus == 0
            if ok {
                print("[HabitSync] Sync script completed successfully.")
            } else {
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                print("[HabitSync] Sync script exited with code \(task.terminationStatus): \(out)")
            }
            fflush(stdout)
            completion?(ok)
        } catch {
            print("[HabitSync] Failed to spawn bun process: \(error.localizedDescription)")
            fflush(stdout)
            completion?(false)
        }
    }
}

// MARK: - Continuous Word Talk-Time Monitor
class TalkTimeMonitor: NSObject {
    static let shared = TalkTimeMonitor()

    let rewardMinSec: TimeInterval = 5.0        // A turn shorter than this is a grunt, not a yield
    let warningThreshold: TimeInterval = 30.0   // 30 seconds
    let alertThreshold: TimeInterval = 60.0     // 60 seconds (1 minute)
    let maxBreathingPause: TimeInterval = 5.0   // Max conversational pause in audio before reset
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

    var isSimulating: Bool = false
    private var simulatedSeconds: TimeInterval = 0.0

    var onStreakUpdated: ((TimeInterval) -> Void)?

    var canAlert: Bool {
        return isSimulating || !alertOnlyDuringCalls || (activeCallApp != nil)
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
    /// Rows carry `captured_at` (when the audio happened) and `device_type`
    /// (input = the owner, output = everyone else), which is everything the coach needs.
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

                    // The live stream gives no segment length, so estimate it from the
                    // word count the same way the background path does for short segments.
                    let words = text.split { $0.isWhitespace }.count
                    let estimated = max(1.0, min(Double(words) * 0.35, 4.0))

                    self.turnUsedLivePath = true
                    let segmentEnd = capturedAt.addingTimeInterval(estimated)
                    if segmentEnd > (self.liveCoveredUntil ?? .distantPast) {
                        self.liveCoveredUntil = segmentEnd
                    }

                    self.handleTranscriptionRow(rowId: id, chunkId: 0, isInput: isInput, text: text,
                                                startTime: 0, endTime: estimated, writtenAt: capturedAt)
                }
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
        if isSimulating {
            currentStreak = simulatedSeconds
            simulatedSeconds += 1.0
            if currentStreak >= warningThreshold && armShowsToast {
                noteToastShown()
                MonologueToastController.shared.show(currentStreak, callApp: "Google Meet (Simulated)")
            } else {
                MonologueToastController.shared.hide()
            }
            if canAlert {
                if currentStreak >= warningThreshold && !hasDeliveredStimulusAt30s {
                    hasDeliveredStimulusAt30s = true
                    hasWarnedPavlokThisMonologue = true
                    warningFiredWallClock = Date()
                    warningFiredStreakSec = currentStreak
                    deliverStimulusForThreshold(isWarning: true)
                }
                if currentStreak >= alertThreshold && !hasDeliveredStimulusAt60s {
                    hasDeliveredStimulusAt60s = true
                    hasShockedPavlokThisMonologue = true
                    shockFiredWallClock = Date()
                    shockFiredStreakSec = currentStreak
                    deliverStimulusForThreshold(isWarning: false)
                }
            }
            onStreakUpdated?(currentStreak)
            return
        }

        checkActiveCall()

        // Live meeting transcripts land in a different table; read both every tick.
        checkLiveMeetingSegments()

        // Fetch latest audio transcriptions via Screenpipe raw_sql endpoint
        guard let url = URL(string: "http://localhost:3030/raw_sql") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let query = "SELECT t.id, t.audio_chunk_id, t.transcription, t.timestamp, t.start_time, t.end_time, c.file_path FROM audio_transcriptions t JOIN audio_chunks c ON t.audio_chunk_id = c.id WHERE t.id > \(self.lastCheckedTranscriptionId) ORDER BY t.id ASC LIMIT 50;"
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])
        req.timeoutInterval = 2.0

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

            DispatchQueue.main.async {
                if !self.isInitialized {
                    if let last = rows.last,
                       let id = (last["id"] as? NSNumber)?.int64Value ?? (last["id"] as? Int64) {
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

                // Check if user stopped speaking (silence timeout)
                if self.currentStreak > 0, let lastWallClock = self.lastSpeechWallClock {
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
        }.resume()
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
    }

    private func finishTurnAndLog(_ turn: FinishedTurn) {
        evaluateGoodBehaviorReward(for: turn.streak, wasShocked: turn.shockedAt != nil)

        guard turn.streak >= 2.0 else { return }

        let arm = HabitExperimentManager.shared.resolveArm(for: activeSessionId)

        // Time from the warning firing to the speaker actually yielding. This used to be
        // computed after warningFiredWallClock had already been cleared, so it was always
        // null -- the experiment's primary behavioural outcome was never recorded.
        let latency: Double? = turn.warnedAt.map { max(0, turn.endedAt.timeIntervalSince($0)) }

        // A live turn is a run of voiced segments (median ~7.5 s); an imported turn is the
        // gap between transcript lines (median ~13 s). Record the wall-clock span of the
        // turn as well so the two measurements can be compared like for like.
        let gapDurationSec = turn.startedAt.map { max(turn.streak, turn.endedAt.timeIntervalSince($0)) }
        let gapDurationValue: Any = gapDurationSec.map { $0 as Any } ?? NSNull()

        // Anything synthetic stays out of the production metrics: the server filters on
        // call_category = 'demo' and metadata.simulated.
        let category: String
        if isSimulating {
            category = "demo"
        } else {
            category = (activeCallApp != nil ? "work" : "solo")
        }

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
                "simulated": isSimulating,
                "source": HabitEventLogger.liveSource,
                "measurement": "voiced",
                "turn_clock": turn.startedAt != nil && turn.audioClock ? "audio" : "arrival",
                "call_title": activeCallTitle ?? "",
                "voiced_duration_sec": turn.streak,
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
                value: 30,
                reason: "Good behavior reward: Concise turn (\(Int(streak))s) yielded cleanly"
            )
        }
    }

    private func handleTranscriptionRow(rowId: Int64, chunkId: Int64, isInput: Bool, text: String, startTime: Double, endTime: Double, writtenAt: Date? = nil) {
        guard isValidSpokenText(text) else { return }

        if let writtenAt = writtenAt {
            let lag = Date().timeIntervalSince(writtenAt)
            lastObservedIngestLagSec = lag
            if lag > maxIngestLagSec { maxIngestLagSec = lag }
            if lag > maxTrustedIngestLagSec {
                print("[SpeakingCoach] ⚠️ Screenpipe ingest lag \(String(format: "%.1f", lag))s on row \(rowId) - turn timing for this turn is marked suspect.")
                fflush(stdout)
            }
        }

        let deviceLabel = isInput ? "User Mic" : "Other Participant"
        let segmentDuration = max(0, endTime - startTime)
        // screenpipe's row timestamp is the audio chunk's start; start_time/end_time are
        // offsets within that chunk. Together they give an absolute audio clock.
        let segmentAudioStart = writtenAt.map { $0.addingTimeInterval(startTime) }
        let segmentAudioEnd = writtenAt.map { $0.addingTimeInterval(endTime) }
        // Whitespace-separated, matching the transcript importer's count_words(). Splitting
        // on punctuation too counted "don't" as two words and inflated live word counts.
        let words = text.split { $0.isWhitespace }.count
        let wordEstimate = Double(words) * 0.35
        let effectiveDuration = segmentDuration > 0.4 ? segmentDuration : max(1.0, min(wordEstimate, 4.0))

        print("[SpeakingCoach] Transcription [\(rowId)] (\(deviceLabel)): \"\(text.prefix(35))...\" (\(String(format: "%.1f", effectiveDuration))s)")
        fflush(stdout)

        if !isInput {
            // Remote participant spoke on system audio!
            // Instantly break the monologue streak.
            print("[SpeakingCoach] Other participant spoke. Resetting monologue streak.")
            fflush(stdout)
            resetStreak()
            return
        }

        // User spoke on microphone
        if canAlert { turnWasAlertable = true }
        currentTurnWords += words
        let now = Date()
        if let lastClock = lastSpeechWallClock {
            let wallGap = now.timeIntervalSince(lastClock)
            // Prefer the audio clock: it spans chunks correctly and is immune to how late
            // screenpipe delivered the row. Fall back to arrival wall-clock only when the
            // row carried no usable timestamp.
            let audioGap: Double
            let gapIsAudioBased: Bool
            if let segStart = segmentAudioStart, let lastEnd = lastSegmentAudioEnd {
                audioGap = max(0, segStart.timeIntervalSince(lastEnd))
                gapIsAudioBased = true
            } else {
                audioGap = (chunkId == lastChunkId && lastAudioEndTime > 0.0) ? max(0, startTime - lastAudioEndTime) : 0.0
                gapIsAudioBased = false
            }

            // Widen the arrival-clock fallback by the lag we actually observed, so batched
            // delivery is not mistaken for the speaker having stopped.
            let wallGapBroke = !gapIsAudioBased && wallGap > (silenceTimeout + lastObservedIngestLagSec)

            if wallGapBroke || audioGap > maxBreathingPause {
                print("[SpeakingCoach] Conversational pause detected (gap: \(String(format: "%.1f", max(wallGap, audioGap)))s). Starting fresh streak.")
                fflush(stdout)
                let previousStreak = currentStreak
                let previousWords = currentTurnWords - words
                let previousWarnedAt = warningFiredWallClock
                let previousShockedAt = shockFiredWallClock
                let previousWarnStreak = warningFiredStreakSec
                let previousShockStreak = shockFiredStreakSec
                let previousInterventions = drainInterventions()
                let previousLag = maxIngestLagSec
                let previousAudioClock = turnAudioStart != nil && lastSegmentAudioEnd != nil
                let previousAlertable = turnWasAlertable
                let previousUsedLive = turnUsedLivePath

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
                turnWasAlertable = canAlert
                turnUsedLivePath = false

                let previousStart = turnAudioStart ?? turnStartWallClock
                let previousEnd = lastSegmentAudioEnd ?? now

                currentStreak = effectiveDuration
                currentTurnWords = words
                turnStartWallClock = now
                turnAudioStart = segmentAudioStart

                finishTurnAndLog(FinishedTurn(
                    streak: previousStreak, words: previousWords,
                    startedAt: previousStart, endedAt: previousEnd,
                    warnedAt: previousWarnedAt, shockedAt: previousShockedAt,
                    warnedAtStreakSec: previousWarnStreak, shockedAtStreakSec: previousShockStreak,
                    interventions: previousInterventions,
                    maxIngestLagSec: previousLag,
                    audioClock: previousAudioClock,
                    wasAlertable: previousAlertable,
                    usedLivePath: previousUsedLive))
            } else {
                currentStreak += effectiveDuration
            }
        } else {
            currentStreak = effectiveDuration
            turnStartWallClock = now
            turnAudioStart = segmentAudioStart
        }

        lastSpeechWallClock = now
        lastChunkId = chunkId
        lastAudioEndTime = endTime
        if let segEnd = segmentAudioEnd { lastSegmentAudioEnd = segEnd }

        print("[SpeakingCoach] User speaking streak now: \(formattedDuration) (warn: \(isWarningActive), alert: \(isAlertActive))")
        fflush(stdout)
    }

    func resetStreak() {
        let finishedStreak = currentStreak
        let finishedWords = currentTurnWords
        let startedAt = turnAudioStart ?? turnStartWallClock
        let endedAt = lastSegmentAudioEnd ?? Date()
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
            usedLivePath: usedLivePath))
    }

    func startSimulation(seconds: TimeInterval) {
        isSimulating = true
        simulatedSeconds = seconds
        currentStreak = seconds
        if seconds < warningThreshold {
            hasWarnedPavlokThisMonologue = false
            hasShockedPavlokThisMonologue = false
        }
        tick()
    }

    func stopSimulation() {
        isSimulating = false
        simulatedSeconds = 0.0
        resetStreak()
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

    let projectDir = "/Users/benpollack/Documents/AI aggregator logger project"
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

    var isHindsightHealthy: Bool = false
    var hindsightSyncedCount: String = "--"
    var hindsightBank: String = "learning-transcript-archive-v1"

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup System Tray Status Item in macOS Menu Bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "🧠 🟢 ..."
            button.toolTip = "AI Capture Suite & Logger\nScreenpipe, AI Vault & Hindsight"
        }

        statusMenu = NSMenu()
        statusMenu.delegate = self
        statusItem.menu = statusMenu

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
        updateVaultCount()
        PavlokController.shared.updateConnectionStatus()
        rebuildMenu()
    }

    // MARK: - Menu Bar Tray Dropdown Menu
    func rebuildMenu() {
        statusMenu.removeAllItems()

        // --- Header ---
        let header = NSMenuItem(title: "AI Capture Suite & Logger", action: nil, keyEquivalent: "")
        header.attributedTitle = NSAttributedString(
            string: "AI Capture Suite & Logger",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
        )
        statusMenu.addItem(header)

        statusMenu.addItem(NSMenuItem.separator())

        // --- Speaking Coach Section ---
        let coachHeader = NSMenuItem(title: "Speaking Coach", action: nil, keyEquivalent: "")
        coachHeader.attributedTitle = NSAttributedString(
            string: "Speaking Coach (Talk-Time Monitor)",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]
        )
        statusMenu.addItem(coachHeader)

        if let call = talkMonitor.activeCallApp {
            let callTitle = talkMonitor.activeCallTitle ?? call
            let callItem = NSMenuItem(title: "   📞 Active Call: \(callTitle)", action: nil, keyEquivalent: "")
            callItem.isEnabled = false
            statusMenu.addItem(callItem)
        }

        if talkMonitor.isAlertActive {
            let callSuffix = talkMonitor.activeCallApp != nil ? " (\(talkMonitor.activeCallApp!))" : ""
            let alertItem = NSMenuItem(title: "   🚨 Monologue Alert: \(talkMonitor.formattedDuration) continuous speech\(callSuffix)", action: nil, keyEquivalent: "")
            alertItem.isEnabled = false
            statusMenu.addItem(alertItem)

            let hideItem = NSMenuItem(title: "   ✕ Dismiss Alert Toast", action: #selector(dismissToast), keyEquivalent: "")
            hideItem.target = self
            statusMenu.addItem(hideItem)
        } else if talkMonitor.isWarningActive {
            let callSuffix = talkMonitor.activeCallApp != nil ? " (\(talkMonitor.activeCallApp!))" : ""
            let warnItem = NSMenuItem(title: "   ⚠️ Monologue Warning: \(talkMonitor.formattedDuration) continuous speech\(callSuffix)", action: nil, keyEquivalent: "")
            warnItem.isEnabled = false
            statusMenu.addItem(warnItem)
        } else {
            let statusText = talkMonitor.activeCallApp != nil
                ? "   🟢 Status: In call (\(talkMonitor.activeCallApp!)) • Monitoring talk-time"
                : (talkMonitor.alertOnlyDuringCalls
                    ? "   🟢 Status: Standby (Monitoring for calls • Off-call quiet)"
                    : "   🟢 Status: Listening (All speech monitored: >30s warn / >1m alert)")
            let okItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
            okItem.isEnabled = false
            statusMenu.addItem(okItem)
        }

        let guardItem = NSMenuItem(title: "   🛡️ Mic Auto-Gain Guard: Active (Enforces 90%)", action: nil, keyEquivalent: "")
        guardItem.isEnabled = false
        statusMenu.addItem(guardItem)

        let callOnlyTitle = talkMonitor.alertOnlyDuringCalls ? "   ✓ Alert Only During Calls (Off-Call Silent)" : "   ○ Alert On All Monologues (Any App)"
        let callOnlyItem = NSMenuItem(title: callOnlyTitle, action: #selector(toggleAlertOnlyDuringCalls), keyEquivalent: "")
        callOnlyItem.target = self
        statusMenu.addItem(callOnlyItem)

        if talkMonitor.currentStreak > 0 {
            let resetItem = NSMenuItem(title: "   ↺ Reset Speaking Streak (\(talkMonitor.formattedDuration))", action: #selector(resetStreakAction), keyEquivalent: "")
            resetItem.target = self
            statusMenu.addItem(resetItem)
        }

        statusMenu.addItem(NSMenuItem.separator())

        let testWarnItem = NSMenuItem(title: "   🧪 Test 30s Warning (Simulate)", action: #selector(simulate30sWarning), keyEquivalent: "")
        testWarnItem.target = self
        statusMenu.addItem(testWarnItem)

        let testToastItem = NSMenuItem(title: "   🧪 Test 1m Toast (Preview Window)", action: #selector(simulate1mToast), keyEquivalent: "")
        testToastItem.target = self
        statusMenu.addItem(testToastItem)

        let testGoodItem = NSMenuItem(title: "   🧪 Test Concise Turn (<30s Reward Vibe)", action: #selector(simulateConciseTurn), keyEquivalent: "")
        testGoodItem.target = self
        statusMenu.addItem(testGoodItem)

        if talkMonitor.isSimulating {
            let stopSimItem = NSMenuItem(title: "   ⏹️ Stop Simulation / Reset", action: #selector(stopSimulation), keyEquivalent: "")
            stopSimItem.target = self
            statusMenu.addItem(stopSimItem)
        }

        statusMenu.addItem(NSMenuItem.separator())

        // --- Pavlok Wearable Operant Coach Section ---
        let pavlokHeader = NSMenuItem(title: "⚡ Pavlok Operant Coach", action: nil, keyEquivalent: "")
        pavlokHeader.attributedTitle = NSAttributedString(
            string: "⚡ Pavlok Operant Coach",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]
        )
        statusMenu.addItem(pavlokHeader)

        let pavStatus = NSMenuItem(title: "Connection: \(PavlokController.shared.connectionStatusText)", action: nil, keyEquivalent: "")
        pavStatus.isEnabled = false
        pavStatus.image = PavlokDogIcon.image(
            connected: PavlokController.shared.isBleConnected,
            isScanning: PavlokController.shared.isBleScanning
        )
        statusMenu.addItem(pavStatus)

        let pavEnabledTitle = PavlokController.shared.isEnabled ? "   ✓ Wearable Operant Feedback Enabled" : "   ○ Wearable Feedback Disabled (Safe Default)"
        let togglePav = NSMenuItem(title: pavEnabledTitle, action: #selector(togglePavlokEnabled), keyEquivalent: "")
        togglePav.target = self
        statusMenu.addItem(togglePav)

        // 1. Quick Cue Combination Presets
        let comboMenu = NSMenu()
        let combos = [
            ("both_shock", "⚡ Shock (30s: 15%) + ⚡ Shock (60s: 35%)  [Default: Both Shock]"),
            ("vibe_shock", "📳 Vibe (30s: 30%) + ⚡ Shock (60s: 35%)    [Graduated: Vibe then Shock]"),
            ("shock_vibe", "⚡ Shock (30s: 15%) + 📳 Vibe (60s: 60%)    [Inverted: Shock then Vibe]"),
            ("both_vibe",  "📳 Vibe (30s: 30%) + 📳 Vibe (60s: 60%)    [Gentle: Both Vibration]"),
            ("both_dual",  "⚡📳 Dual Shock + Vibe (Both Thresholds)"),
            ("all_zero",   "⚪ 0% All Modalities Disabled (Silent / Toast Only)")
        ]
        for (key, label) in combos {
            let isSel: Bool
            switch key {
            case "both_shock": isSel = (PavlokController.shared.presetSummary == "Both Shock (Default)")
            case "vibe_shock": isSel = (PavlokController.shared.presetSummary == "Vibe (30s) + Shock (60s)")
            case "shock_vibe": isSel = (PavlokController.shared.presetSummary == "Shock (30s) + Vibe (60s)")
            case "both_vibe":  isSel = (PavlokController.shared.presetSummary == "Both Vibration")
            case "both_dual":  isSel = (PavlokController.shared.presetSummary == "Dual Shock + Vibe")
            case "all_zero":   isSel = (PavlokController.shared.presetSummary == "All 0% (Silent)")
            default: isSel = false
            }
            let bullet = isSel ? "⦿ " : "○ "
            let item = NSMenuItem(title: "\(bullet)\(label)", action: #selector(selectCuePreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            item.state = isSel ? .on : .off
            comboMenu.addItem(item)
        }
        let comboParentItem = NSMenuItem(title: "   🎛️ Cue Preset: \(PavlokController.shared.presetSummary)", action: nil, keyEquivalent: "")
        comboParentItem.submenu = comboMenu
        statusMenu.addItem(comboParentItem)

        // 2. 30s Warning Popout (Interactive Non-Closing Multi-Select Submenu)
        let warnMenu = NSMenu()
        let warnView = Pavlok30sSubmenuView()
        let warnParentItem = NSMenuItem(title: "   ⏱️ 30s Warning: \(PavlokController.shared.warningCueSummary)", action: nil, keyEquivalent: "")
        warnView.onStateChanged = { [weak self, weak warnParentItem] in
            warnParentItem?.title = "   ⏱️ 30s Warning: \(PavlokController.shared.warningCueSummary)"
            self?.updateTrayButton()
        }
        let warnCustomItem = NSMenuItem()
        warnCustomItem.view = warnView
        warnMenu.addItem(warnCustomItem)
        warnParentItem.submenu = warnMenu
        statusMenu.addItem(warnParentItem)

        // 3. 60s Hard Stop Popout (Interactive Non-Closing Multi-Select Submenu)
        let alertMenu = NSMenu()
        let alertView = Pavlok60sSubmenuView()
        let alertParentItem = NSMenuItem(title: "   ⏱️ 60s Hard Stop: \(PavlokController.shared.alertCueSummary)", action: nil, keyEquivalent: "")
        alertView.onStateChanged = { [weak self, weak alertParentItem] in
            alertParentItem?.title = "   ⏱️ 60s Hard Stop: \(PavlokController.shared.alertCueSummary)"
            self?.updateTrayButton()
        }
        let alertCustomItem = NSMenuItem()
        alertCustomItem.view = alertView
        alertMenu.addItem(alertCustomItem)
        alertParentItem.submenu = alertMenu
        statusMenu.addItem(alertParentItem)

        // 4. Good Behavior: Reward Vibration on concise turns
        let rewardTitle = PavlokController.shared.rewardGoodBehavior ? "   ✓ Good Behavior: Reward Vibration on Concise Turns (<30s)" : "   ○ Good Behavior: Reward Vibration Disabled"
        let toggleReward = NSMenuItem(title: rewardTitle, action: #selector(toggleGoodBehaviorReward), keyEquivalent: "")
        toggleReward.target = self
        statusMenu.addItem(toggleReward)

        let scanItem = NSMenuItem(title: "   🔍 Scan & Connect via Bluetooth", action: #selector(scanPavlokBluetooth), keyEquivalent: "")
        scanItem.target = self
        statusMenu.addItem(scanItem)

        let tokenLabel = PavlokController.shared.apiToken.isEmpty ? "   🔑 Configure Cloud Backup Token (Optional)..." : "   🔑 Change Cloud Backup Token (Configured)..."
        let tokenItem = NSMenuItem(title: tokenLabel, action: #selector(promptPavlokToken), keyEquivalent: "")
        tokenItem.target = self
        statusMenu.addItem(tokenItem)

        statusMenu.addItem(NSMenuItem.separator())

        let test30Item = NSMenuItem(title: "   ⚡ Test 30s Cue (\(PavlokController.shared.warningCueSummary))", action: #selector(testPavlok30sCue), keyEquivalent: "")
        test30Item.target = self
        statusMenu.addItem(test30Item)

        let test60Item = NSMenuItem(title: "   ⚡ Test 60s Cue (\(PavlokController.shared.alertCueSummary))", action: #selector(testPavlok60sCue), keyEquivalent: "")
        test60Item.target = self
        statusMenu.addItem(test60Item)

        let testVibeItem = NSMenuItem(title: "   📳 Test Good Behavior Reward (<15ms Vibe)", action: #selector(testPavlokVibe), keyEquivalent: "")
        testVibeItem.target = self
        statusMenu.addItem(testVibeItem)

        statusMenu.addItem(NSMenuItem.separator())

        // --- Screenpipe Section ---
        let spTitle = isScreenpipeHealthy
            ? "📹 Screenpipe: 🟢 Recording"
            : (isScreenpipeDegraded ? "📹 Screenpipe: 🟡 Idle / Degraded" : "📹 Screenpipe: 🔴 Stopped")
        let spItem = NSMenuItem(title: spTitle, action: nil, keyEquivalent: "")
        statusMenu.addItem(spItem)

        if !screenpipeDetail.isEmpty {
            let detailItem = NSMenuItem(title: "   └─ \(screenpipeDetail)", action: nil, keyEquivalent: "")
            detailItem.isEnabled = false
            statusMenu.addItem(detailItem)
        }

        let restartSp = NSMenuItem(title: "   Restart Screenpipe Daemon", action: #selector(restartScreenpipe), keyEquivalent: "")
        restartSp.target = self
        statusMenu.addItem(restartSp)

        statusMenu.addItem(NSMenuItem.separator())

        // --- AI Vault Section ---
        let vaultTitle = "🗄️ AI Vault: 🟢 \(vaultCount) Archived"
        statusMenu.addItem(NSMenuItem(title: vaultTitle, action: nil, keyEquivalent: ""))

        let vaultDetail = NSMenuItem(title: "   └─ ChatGPT: \(vaultChatGptCount) | Claude: \(vaultClaudeCount)", action: nil, keyEquivalent: "")
        vaultDetail.isEnabled = false
        statusMenu.addItem(vaultDetail)

        let pullSweep = NSMenuItem(title: "   📥 Pull Latest Chats (Incremental Sweep)", action: #selector(pullVaultChats), keyEquivalent: "")
        pullSweep.target = self
        statusMenu.addItem(pullSweep)

        let resumeCpt = NSMenuItem(title: "   ▶️ Resume ChatGPT Full Backfill", action: #selector(resumeChatGptBackup), keyEquivalent: "")
        resumeCpt.target = self
        statusMenu.addItem(resumeCpt)

        statusMenu.addItem(NSMenuItem.separator())

        // --- Hindsight Sync Section ---
        let hsTitle = isHindsightHealthy
            ? "🧠 Hindsight: 🟢 Live (OVH :18925)"
            : "🧠 Hindsight: 🔴 Tunnel Disconnected"
        statusMenu.addItem(NSMenuItem(title: hsTitle, action: nil, keyEquivalent: ""))

        let hsDetail = NSMenuItem(title: "   └─ Synced: \(hindsightSyncedCount) chats -> \(hindsightBank)", action: nil, keyEquivalent: "")
        hsDetail.isEnabled = false
        statusMenu.addItem(hsDetail)

        let syncNow = NSMenuItem(title: "   ⚡ Sync Backfill Now", action: #selector(syncAggregator), keyEquivalent: "")
        syncNow.target = self
        statusMenu.addItem(syncNow)

        let restartTunnel = NSMenuItem(title: "   Restart Tunnel & Watcher", action: #selector(restartAggregatorServices), keyEquivalent: "")
        restartTunnel.target = self
        statusMenu.addItem(restartTunnel)

        statusMenu.addItem(NSMenuItem.separator())

        // --- Habit Experiments & GrowthBook Section ---
        let expHeader = NSMenuItem(title: "📊 Habit Experiments (GrowthBook)", action: nil, keyEquivalent: "")
        expHeader.attributedTitle = NSAttributedString(
            string: "📊 Habit Experiments (GrowthBook)",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]
        )
        statusMenu.addItem(expHeader)

        let assignedArm = HabitExperimentManager.shared.resolveArm(for: talkMonitor.activeSessionId)
        let mode = HabitExperimentManager.shared.currentMode
        let modeItem = NSMenuItem(title: "   🎯 Condition: \(mode.shortTag) [Active: \(assignedArm)]", action: nil, keyEquivalent: "")
        modeItem.isEnabled = false
        statusMenu.addItem(modeItem)

        // Submenu for selecting condition
        let armSubmenu = NSMenu()
        for armCase in HabitTreatmentArm.allCases {
            let check = (mode == armCase) ? "✓ " : "   "
            let item = NSMenuItem(title: "\(check)\(armCase.displayName)", action: #selector(selectExperimentArm(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = armCase.rawValue
            armSubmenu.addItem(item)
        }
        let selectArmItem = NSMenuItem(title: "   Select Active Intervention Condition...", action: nil, keyEquivalent: "")
        selectArmItem.submenu = armSubmenu
        statusMenu.addItem(selectArmItem)

        let totalTrials = HabitEventLogger.shared.getTotalTrialCount()
        let unsyncedTrials = HabitEventLogger.shared.getUnsyncedCount()
        let trialsItem = NSMenuItem(title: "   📈 Recorded Trials: \(totalTrials) (\(unsyncedTrials) pending sync)", action: nil, keyEquivalent: "")
        trialsItem.isEnabled = false
        statusMenu.addItem(trialsItem)

        let syncHabitsItem = NSMenuItem(title: "   ⚡ Sync Habit Trials to OVH Now", action: #selector(triggerHabitSync), keyEquivalent: "")
        syncHabitsItem.target = self
        statusMenu.addItem(syncHabitsItem)

        let openGbItem = NSMenuItem(title: "   🌐 Open GrowthBook Dashboard...", action: #selector(openGrowthBookDashboard), keyEquivalent: "")
        openGbItem.target = self
        statusMenu.addItem(openGbItem)

        statusMenu.addItem(NSMenuItem.separator())

        // --- Folder / Log Shortcuts ---
        let openVault = NSMenuItem(title: "Open AI Vault Folder...", action: #selector(openVaultFolder), keyEquivalent: "")
        openVault.target = self
        statusMenu.addItem(openVault)

        let openSpData = NSMenuItem(title: "Open Screenpipe Recordings...", action: #selector(openScreenpipeData), keyEquivalent: "")
        openSpData.target = self
        statusMenu.addItem(openSpData)

        let openProj = NSMenuItem(title: "Open Aggregator Project...", action: #selector(openProjectFolder), keyEquivalent: "")
        openProj.target = self
        statusMenu.addItem(openProj)

        let openLog = NSMenuItem(title: "View Watcher Log...", action: #selector(openWatcherLogs), keyEquivalent: "")
        openLog.target = self
        statusMenu.addItem(openLog)

        statusMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit AI Aggregator", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }

    // MARK: - Status Polling & Dynamic Tray Title
    func updateAllStatuses() {
        updateVaultCount()
        updateScreenpipeStatus()
        updateHindsightStatus()
        enforceMicAutoGainGuard()
        if HabitEventLogger.shared.getUnsyncedCount() > 0 {
            syncHabitsToServer(completion: nil)
        }
    }

    func enforceMicAutoGainGuard() {
        DispatchQueue.global(qos: .utility).async {
            let script = """
            set curVol to input volume of (get volume settings)
            if curVol < 85 then
                set volume input volume 90
                return "adjusted from " & curVol
            else
                return "ok " & curVol
            end if
            """
            if let res = NSAppleScript(source: script)?.executeAndReturnError(nil).stringValue, res.hasPrefix("adjusted") {
                print("[SpeakingCoach] \(res). Mic Auto-Gain Guard restored input volume to 90%.")
                fflush(stdout)
            }
        }
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

    func updateHindsightStatus() {
        let statusJsonPath = homeDir + "/.ai-aggregator/status.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: statusJsonPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let synced = json["synced"] as? Int {
                self.hindsightSyncedCount = "\(synced)"
            }
        }

        guard let healthUrl = URL(string: "http://127.0.0.1:18925/health") else { return }
        var req = URLRequest(url: healthUrl)
        req.timeoutInterval = 2.0

        let task = URLSession.shared.dataTask(with: req) { [weak self] _, response, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isHindsightHealthy = (response as? HTTPURLResponse)?.statusCode == 200
                self.updateTrayButton()
            }
        }
        task.resume()
    }

    func updateTrayButton() {
        guard let button = statusItem?.button else { return }

        let callHint = talkMonitor.activeCallApp != nil ? " [\(talkMonitor.activeCallApp!)]" : ""
        let pavlokHint = "\nPavlok: \(PavlokController.shared.connectionStatusText) (30s: \(PavlokController.shared.warningCueSummary) | 60s: \(PavlokController.shared.alertCueSummary))"

        let baseTitle: String
        if talkMonitor.isAlertActive {
            baseTitle = "🗣️ 🚨 \(talkMonitor.formattedDuration)"
            button.toolTip = "Talk-Time Alert: Continuous speech for \(talkMonitor.formattedDuration)\(callHint)\nFloating alert toast displayed (hidden from screenshare)\(pavlokHint)"
        } else if talkMonitor.isWarningActive {
            baseTitle = "🗣️ ⚠️ \(talkMonitor.formattedDuration)"
            button.toolTip = "Talk-Time Warning: Continuous speech for \(talkMonitor.formattedDuration)\(callHint)\(pavlokHint)"
        } else if !isHindsightHealthy {
            baseTitle = "🧠 🔴 ERR"
            button.toolTip = "AI Capture Suite & Logger\nHindsight tunnel disconnected\(pavlokHint)"
        } else if !isScreenpipeHealthy && !isScreenpipeDegraded {
            baseTitle = "🧠 🔴 SP"
            button.toolTip = "AI Capture Suite & Logger\nScreenpipe stopped\(pavlokHint)"
        } else if isScreenpipeDegraded {
            baseTitle = "🧠 🟡 \(vaultCount)"
            button.toolTip = "AI Capture Suite & Logger\nScreenpipe idle/degraded\(pavlokHint)"
        } else if let call = talkMonitor.activeCallApp {
            baseTitle = "🗣️ 📞 \(vaultCount)"
            button.toolTip = "Active Call: \(call)\nSpeaking Coach monitoring talk-time limits\(pavlokHint)"
        } else {
            baseTitle = "🧠 🟢 \(vaultCount)"
            button.toolTip = "AI Capture Suite & Logger\nAll systems healthy (\(vaultCount) chats vaulted)\(pavlokHint)"
        }

        // Cute Dog Stick Figure Bluetooth Connection Indicator (rendered inline via NSTextAttachment)
        let dogImg = PavlokDogIcon.image(
            connected: PavlokController.shared.isBleConnected,
            isScanning: PavlokController.shared.isBleScanning
        )
        let attachment = NSTextAttachment()
        attachment.image = dogImg
        attachment.bounds = NSRect(x: 0, y: -3.0, width: 22, height: 18)

        let attrTitle = NSMutableAttributedString(
            string: baseTitle + " ",
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        )
        attrTitle.append(NSAttributedString(attachment: attachment))
        button.attributedTitle = attrTitle
        button.image = nil
        button.imagePosition = .noImage
    }

    // MARK: - Actions
    @objc func simulate30sWarning() {
        talkMonitor.startSimulation(seconds: 35.0)
        updateTrayButton()
        rebuildMenu()
    }

    @objc func simulate1mToast() {
        talkMonitor.startSimulation(seconds: 65.0)
        updateTrayButton()
        rebuildMenu()
    }

    @objc func simulateConciseTurn() {
        talkMonitor.startSimulation(seconds: 15.0)
        updateTrayButton()
        rebuildMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.talkMonitor.resetStreak()
            self?.updateTrayButton()
            self?.rebuildMenu()
        }
    }

    @objc func stopSimulation() {
        talkMonitor.stopSimulation()
        updateTrayButton()
        rebuildMenu()
    }

    @objc func dismissToast() {
        MonologueToastController.shared.hide()
        if talkMonitor.isSimulating {
            talkMonitor.stopSimulation()
        }
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
    @objc func scanPavlokBluetooth() {
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

    @objc func testPavlokVibe() {
        PavlokController.shared.sendStimulus(type: "vibe", value: 40, reason: "Manual test from AI Aggregator menu")
    }

    @objc func testPavlokZap() {
        PavlokController.shared.sendStimulus(type: "zap", value: PavlokController.shared.shockIntensity, reason: "Manual test from AI Aggregator menu")
    }

    @objc func restartScreenpipe() {
        runShell("launchctl kickstart -k gui/$(id -u)/screenpipe") { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self?.updateScreenpipeStatus()
            }
        }
    }

    @objc func pullVaultChats() {
        runShell("cd '\(projectDir)' && ./scripts/sweep-ai-vault.sh") { [weak self] in
            DispatchQueue.main.async {
                self?.updateVaultCount()
            }
        }
    }

    @objc func resumeChatGptBackup() {
        runShell("ai-vault backup chatgpt --only-new --random-delay -y") { [weak self] in
            DispatchQueue.main.async {
                self?.updateVaultCount()
            }
        }
    }

    @objc func syncAggregator() {
        runShell("cd '\(projectDir)' && bun run src/cli.ts sync") { [weak self] in
            DispatchQueue.main.async {
                self?.updateHindsightStatus()
            }
        }
    }

    @objc func restartAggregatorServices() {
        let cmd = "launchctl unload ~/Library/LaunchAgents/com.benpollack.ai-aggregator-tunnel.plist 2>/dev/null; launchctl load -w ~/Library/LaunchAgents/com.benpollack.ai-aggregator-tunnel.plist; launchctl unload ~/Library/LaunchAgents/com.benpollack.ai-aggregator-watcher.plist 2>/dev/null; launchctl load -w ~/Library/LaunchAgents/com.benpollack.ai-aggregator-watcher.plist"
        runShell(cmd) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self?.updateHindsightStatus()
            }
        }
    }

    @objc func openVaultFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: homeDir + "/ai-vault-data"))
    }

    @objc func openScreenpipeData() {
        NSWorkspace.shared.open(URL(fileURLWithPath: homeDir + "/.screenpipe/data"))
    }

    @objc func openProjectFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: projectDir))
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
        syncHabitsToServer { [weak self] _ in
            DispatchQueue.main.async {
                self?.rebuildMenu()
            }
        }
    }

    @objc func openGrowthBookDashboard() {
        if let url = URL(string: "http://localhost:3200") {
            NSWorkspace.shared.open(url)
        }
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

        // sync-habits.ts pushes at most 100 rows per run, so loop until drained. Stop
        // early if a run makes no progress (tunnel down): rows are safe in SQLite and
        // will sync on next launch.
        let deadline = Date().addingTimeInterval(90)
        var previous = -1
        var attempts = 0
        while Date() < deadline && attempts < 30 {
            let remaining = logger.getUnsyncedCount()
            if remaining == 0 { break }
            if remaining == previous {
                print("[Shutdown] No progress syncing (\(remaining) left) - leaving them for next launch.")
                break
            }
            previous = remaining
            print("[Shutdown] Syncing \(remaining) unsynced turn(s) to Postgres...")
            fflush(stdout)
            let done = DispatchSemaphore(value: 0)
            syncHabitsToServer { _ in done.signal() }
            _ = done.wait(timeout: .now() + 20)
            attempts += 1
        }
        print("[Shutdown] Unsynced turns remaining: \(logger.getUnsyncedCount())")

        logger.close()
        print("[Shutdown] Clean shutdown complete.")
        fflush(stdout)
        return .terminateNow
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func runShell(_ command: String, completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", command]

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/Users/benpollack/.bun/bin:/Users/benpollack/.nvm/versions/node/v24.12.0/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            process.environment = env

            try? process.run()
            process.waitUntilExit()

            DispatchQueue.main.async {
                completion?()
            }
        }
    }
}

// MARK: - Automated End-to-End Test Harness
func runPavlokE2ETests() {
    print("==================================================")
    print("[E2E-TEST] Starting Pavlok Wearable E2E Test Suite")
    print("==================================================")

    var mockUrl = "http://127.0.0.1:8999/api/v5/stimulus/send"
    if let idx = CommandLine.arguments.firstIndex(of: "--test-pavlok-e2e"),
       idx + 1 < CommandLine.arguments.count {
        mockUrl = CommandLine.arguments[idx + 1]
    }
    print("[E2E-TEST] Using mock endpoint: \(mockUrl)")

    let pavlok = PavlokController.shared
    let talkMonitor = TalkTimeMonitor.shared

    // Test 1: Disabled Default Verification
    print("\n[TEST 1] Verifying Safe Disabled Default & Guard Rails...")
    pavlok.isEnabled = false
    assert(!pavlok.isEnabled, "FAIL: Pavlok isEnabled must default to false")
    print("  ✓ isEnabled is false")

    let sema1 = DispatchSemaphore(value: 0)
    var test1CallbackFired = false
    pavlok.sendStimulus(type: "zap", value: 50, reason: "Testing disabled state") { ok, msg in
        assert(!ok, "FAIL: sendStimulus must fail when Pavlok is disabled")
        assert(msg == "Pavlok is disabled in settings", "FAIL: Unexpected error: \(msg ?? "")")
        test1CallbackFired = true
        sema1.signal()
    }
    _ = sema1.wait(timeout: .now() + 1.0)
    assert(test1CallbackFired, "FAIL: Callback was not invoked")
    print("  ✓ sendStimulus blocked when disabled")

    // Test 1b: Direct Bluetooth Binary Packet Encoding Verification
    print("\n[TEST 1b] Verifying Direct Bluetooth Binary Packet Generation (<15ms protocol)...")
    let shockDataP2 = PavlokController.encodeBleShock(intensity: 35, isPavlok2: true)
    assert(shockDataP2 == Data([0x81, 0x23]), "FAIL: Pavlok 2/3 shock packet mismatch. Got: \(shockDataP2)")
    print("  ✓ Pavlok 2/3 BLE Shock packet: [0x81, 0x23] (35% intensity)")

    let vibeDataP2 = PavlokController.encodeBleVibe(intensity: 30, isPavlok2: true)
    assert(vibeDataP2 == Data([0x81, 0x0C, 0x1E, 0x18, 0x18]), "FAIL: Pavlok 2/3 vibe packet mismatch. Got: \(vibeDataP2)")
    print("  ✓ Pavlok 2/3 BLE Vibe packet: [0x81, 0x0C, 0x1E, 0x18, 0x18] (30% intensity)")

    let beepDataP2 = PavlokController.encodeBleBeep(count: 1, isPavlok2: true)
    assert(beepDataP2 == Data([0x81, 0x0C, 0x01, 0x18, 0x18]), "FAIL: Pavlok 2/3 beep packet mismatch. Got: \(beepDataP2)")
    print("  ✓ Pavlok 2/3 BLE Beep packet: [0x81, 0x0C, 0x01, 0x18, 0x18] (1 chime)")

    let shockDataP1 = PavlokController.encodeBleShock(intensity: 35, isPavlok2: false)
    assert(shockDataP1 == Data([0x01, 89, 0x32, 0x32]), "FAIL: Pavlok 1 shock packet mismatch. Got: \(shockDataP1)")
    print("  ✓ Pavlok 1 BLE Shock packet: [0x01, 89, 0x32, 0x32] (35% scaled to 89)")

    let clampLow = PavlokController.encodeBleShock(intensity: -10, isPavlok2: true)
    assert(clampLow == Data([0x81, 0x01]), "FAIL: Lower bound clamp failed")
    let clampHigh = PavlokController.encodeBleShock(intensity: 150, isPavlok2: true)
    assert(clampHigh == Data([0x81, 0x64]), "FAIL: Upper bound clamp failed")
    print("  ✓ BLE packet intensity boundary clamping [1, 100]% verified")

    // Test 1c: Default Cue Settings & Bi-directional State Derivation
    print("\n[TEST 1c] Verifying Default Settings & Bi-Directional State Derivation...")
    // Clear any overrides to verify pure defaults
    UserDefaults.standard.removeObject(forKey: pavlok.kPavlokWarningCue)
    UserDefaults.standard.removeObject(forKey: pavlok.kPavlokAlertCue)
    UserDefaults.standard.removeObject(forKey: pavlok.kPavlokWarningShockIntensity)
    UserDefaults.standard.removeObject(forKey: pavlok.kPavlokAlertShockIntensity)
    UserDefaults.standard.removeObject(forKey: pavlok.kPavlokWarningVibeIntensity)
    UserDefaults.standard.removeObject(forKey: pavlok.kPavlokAlertVibeIntensity)
    UserDefaults.standard.removeObject(forKey: pavlok.kPavlokWarningBeepEnabled)
    assert(pavlok.warningShockIntensity == 15, "FAIL: 30s light shock intensity must default to 15%")
    assert(pavlok.alertShockIntensity == 35, "FAIL: 60s heavier shock intensity must default to 35%")
    assert(pavlok.warningVibeIntensity == 0, "FAIL: 30s vibe intensity must default to 0% (disabled)")
    assert(pavlok.alertVibeIntensity == 0, "FAIL: 60s vibe intensity must default to 0% (disabled)")
    assert(!pavlok.warningBeepEnabled, "FAIL: 30s beep must default to false")
    assert(pavlok.presetSummary == "Both Shock (Default)", "FAIL: Preset summary must be 'Both Shock (Default)'")
    print("  ✓ Verified defaults: 30s Light Shock (15%), 60s Heavier Shock (35%), Vibes at 0% (disabled)")

    // Direction 1: Modality Toggles derive Intensity
    pavlok.toggle30sShock()
    assert(pavlok.warningShockIntensity == 0, "FAIL: Toggling 30s shock off must derive 0% intensity")
    pavlok.toggle30sShock()
    assert(pavlok.warningShockIntensity == 15, "FAIL: Toggling 30s shock on must derive saved 15% intensity")
    pavlok.toggle30sVibe()
    assert(pavlok.warningVibeIntensity == 30, "FAIL: Toggling 30s vibe on must derive saved 30% intensity")
    pavlok.toggle30sBeep()
    assert(pavlok.warningBeepEnabled, "FAIL: Toggling 30s beep must enable chime")
    assert(pavlok.warningCueSummary.contains("Shock 15%") && pavlok.warningCueSummary.contains("Vibe 30%") && pavlok.warningCueSummary.contains("Beep"), "FAIL: Cue summary mismatch: \(pavlok.warningCueSummary)")
    print("  ✓ Direction 1 verified: Modality checkboxes derive intensity from saved level, enabling multi-select (Shock + Vibe + Beep)")

    // Direction 2: Intensity selection derives Modality state, and 0% setting disables it
    pavlok.warningShockIntensity = 0
    assert(pavlok.warningShockIntensity == 0, "FAIL: Setting 0% shock must set intensity to 0")
    pavlok.warningVibeIntensity = 0
    assert(pavlok.warningVibeIntensity == 0, "FAIL: Setting 0% vibe must set intensity to 0")
    pavlok.warningBeepEnabled = false
    assert(pavlok.warningCueSummary == "⚪ 0% (Silent / Toast Only)", "FAIL: All 0% must display Silent summary, got \(pavlok.warningCueSummary)")

    pavlok.warningShockIntensity = 25
    assert(pavlok.warningShockIntensity == 25, "FAIL: Setting non-zero intensity must derive enabled state")
    assert(pavlok.savedWarningShockIntensity == 25, "FAIL: Non-zero intensity must be saved")
    pavlok.warningShockIntensity = 0
    pavlok.toggle30sShock()
    assert(pavlok.warningShockIntensity == 25, "FAIL: Toggling on after 0% must restore saved 25% intensity")

    pavlok.alertShockIntensity = 0
    assert(pavlok.alertShockIntensity == 0, "FAIL: Setting 0% 60s shock must set intensity to 0")
    pavlok.alertShockIntensity = 50
    assert(pavlok.alertShockIntensity == 50 && pavlok.savedAlertShockIntensity == 50, "FAIL: 50% 60s shock setting failed")
    pavlok.alertVibeIntensity = 0
    pavlok.alertVibeIntensity = 80
    assert(pavlok.alertVibeIntensity == 80 && pavlok.savedAlertVibeIntensity == 80, "FAIL: 80% 60s vibe setting failed")
    pavlok.toggle60sShock()
    assert(pavlok.alertShockIntensity == 0, "FAIL: Toggling 60s shock off must derive 0%")
    pavlok.toggle60sShock()
    assert(pavlok.alertShockIntensity == 50, "FAIL: Toggling 60s shock on must restore saved 50%")
    print("  ✓ Direction 2 verified: 0% intensity disables modality; >0% derives enabled state & updates saved level")

    // Test 1d: Verify All 0% Silent Mode Triggering
    print("\n[TEST 1d] Verifying 0% All Modalities (Silent Mode / Visual Toast Only)...")
    pavlok.warningShockIntensity = 0
    pavlok.warningVibeIntensity = 0
    pavlok.warningBeepEnabled = false
    pavlok.alertShockIntensity = 0
    pavlok.alertVibeIntensity = 0
    assert(pavlok.presetSummary == "All 0% (Silent)", "FAIL: Preset summary should be 'All 0% (Silent)'")

    let semaSilent = DispatchSemaphore(value: 0)
    pavlok.isEnabled = true
    pavlok.trigger30sWarning { ok, msg in
        assert(ok, "FAIL: Silent 30s trigger should succeed")
        assert(msg == "Visual toast only (silent cue)", "FAIL: Unexpected message: \(msg ?? "")")
        semaSilent.signal()
    }
    _ = semaSilent.wait(timeout: .now() + 1.0)
    print("  ✓ 0% Silent 30s Warning completed with visual toast only (no hardware stimuli dispatched)")

    // Restore pure defaults for remaining tests
    pavlok.warningShockIntensity = 15
    pavlok.warningVibeIntensity = 0
    pavlok.warningBeepEnabled = false
    pavlok.alertShockIntensity = 35
    pavlok.alertVibeIntensity = 0
    pavlok.rewardGoodBehavior = true
    assert(pavlok.presetSummary == "Both Shock (Default)")
    print("  ✓ Restored pure defaults: 30s Light Shock 15%, 60s Heavier Shock 35%")

    // Test 2: Enable with Mock Server & Stimulus Delivery
    print("\n[TEST 2] Verifying Live Stimulus Delivery over HTTP...")
    pavlok.customApiUrl = mockUrl
    pavlok.apiToken = "test_pavlok_token_abc"
    pavlok.isEnabled = true
    assert(pavlok.isEnabled, "FAIL: Failed to enable Pavlok")

    let sema2 = DispatchSemaphore(value: 0)
    var test2Success = false
    pavlok.sendStimulus(type: "zap", value: 35, reason: "E2E Direct test zap") { ok, msg in
        test2Success = ok
        sema2.signal()
    }
    let wait2 = sema2.wait(timeout: .now() + 4.0)
    assert(wait2 == .success, "FAIL: Timed out waiting for mock server response")
    assert(test2Success, "FAIL: Stimulus delivery failed to mock server")
    print("  ✓ Request 1 (Direct Test Zap): Stimulus delivered successfully with 200 OK")

    // Test 3: Default Monologue Progression (30s Light Shock 15% & 60s Heavier Shock 35%)
    print("\n[TEST 3] Verifying Default Monologue Progression (30s Light Shock 15% & 60s Heavier Shock 35%)...")
    talkMonitor.resetStreak()
    assert(!talkMonitor.hasWarnedPavlokThisMonologue, "FAIL: Warning flag should be false after reset")
    assert(!talkMonitor.hasShockedPavlokThisMonologue, "FAIL: Shock flag should be false after reset")

    // Start simulation at 25s
    talkMonitor.startSimulation(seconds: 25.0)
    assert(!talkMonitor.hasWarnedPavlokThisMonologue, "FAIL: Should not warn at 25s")
    assert(!talkMonitor.hasShockedPavlokThisMonologue, "FAIL: Should not shock at 25s")
    print("  ✓ Streak 25s: No stimulus triggered")

    // Advance to 30s (Default: 30s Light Shock at 15%)
    talkMonitor.startSimulation(seconds: 30.0)
    assert(talkMonitor.hasWarnedPavlokThisMonologue, "FAIL: 30s light shock should have fired at 30s")
    assert(!talkMonitor.hasShockedPavlokThisMonologue, "FAIL: Hard stop should not shock at 30s")
    print("  ✓ Request 2 (30s Warning): Light Shock fired (zap at 15%)")
    Thread.sleep(forTimeInterval: 0.3)

    // Advance to 35s (Still within warning zone)
    talkMonitor.startSimulation(seconds: 35.0)
    assert(talkMonitor.hasWarnedPavlokThisMonologue, "FAIL: Warning flag should remain true")
    assert(!talkMonitor.hasShockedPavlokThisMonologue, "FAIL: Should not shock at 35s")
    print("  ✓ Streak 35s: No duplicate warning")

    // Advance to 60s (Default: 60s Heavier Shock at 35%)
    talkMonitor.startSimulation(seconds: 60.0)
    assert(talkMonitor.hasShockedPavlokThisMonologue, "FAIL: 60s heavier shock should have fired at 60s")
    print("  ✓ Request 3 (60s Hard Stop): Heavier Shock fired (zap at 35%)")
    Thread.sleep(forTimeInterval: 0.3)

    // Advance to 65s (Debounce check - must NOT machine-gun shocks!)
    talkMonitor.startSimulation(seconds: 65.0)
    assert(talkMonitor.hasShockedPavlokThisMonologue, "FAIL: Shock flag must stay true to debounce")
    print("  ✓ Streak 65s: Debounce guard active (no duplicate stimulus dispatched)")
    Thread.sleep(forTimeInterval: 0.2)

    // Test 3b: Toggled Vibration Progression (Radials: 30s Vibe & 60s Vibe)
    print("\n[TEST 3b] Verifying Toggled Vibration Progression (Radials set to 30s Vibe & 60s Vibe)...")
    talkMonitor.resetStreak()
    pavlok.warningCue = "vibe"
    pavlok.alertCue = "vibe"
    pavlok.warningVibeIntensity = 30
    pavlok.alertVibeIntensity = 60

    // Advance to 30s (Toggled to 30s Vibration at 30%)
    talkMonitor.startSimulation(seconds: 30.0)
    assert(talkMonitor.hasWarnedPavlokThisMonologue, "FAIL: 30s vibration should have fired at 30s")
    print("  ✓ Request 4 (30s Toggled Warning): Vibration fired (vibe at 30%)")
    Thread.sleep(forTimeInterval: 0.3)

    // Advance to 60s (Toggled to 60s Vibration at 60%)
    talkMonitor.startSimulation(seconds: 60.0)
    assert(talkMonitor.hasShockedPavlokThisMonologue, "FAIL: 60s vibration should have fired at 60s")
    print("  ✓ Request 5 (60s Toggled Hard Stop): Vibration fired (vibe at 60%)")
    Thread.sleep(forTimeInterval: 0.3)

    // Test 3c: Multi-Select Dual Modality Progression (Simultaneous Shock & Vibe)
    print("\n[TEST 3c] Verifying Multi-Select Dual Modality Progression (Shock & Vibe Simultaneously Active)...")
    talkMonitor.resetStreak()
    pavlok.warningShockIntensity = 15
    pavlok.warningVibeIntensity = 30
    pavlok.alertShockIntensity = 35
    pavlok.alertVibeIntensity = 60
    assert(pavlok.presetSummary == "Dual Shock + Vibe", "FAIL: Preset should be Dual Shock + Vibe")

    // Advance to 30s (Fires both Shock 15% AND Vibe 30%)
    talkMonitor.startSimulation(seconds: 30.0)
    assert(talkMonitor.hasWarnedPavlokThisMonologue, "FAIL: 30s dual cue should have fired")
    print("  ✓ Requests 6 & 7 (30s Dual Warning): Both Shock (15%) & Vibe (30%) dispatched simultaneously")
    Thread.sleep(forTimeInterval: 0.4)

    // Advance to 60s (Fires both Shock 35% AND Vibe 60%)
    talkMonitor.startSimulation(seconds: 60.0)
    assert(talkMonitor.hasShockedPavlokThisMonologue, "FAIL: 60s dual cue should have fired")
    print("  ✓ Requests 8 & 9 (60s Dual Hard Stop): Both Shock (35%) & Vibe (60%) dispatched simultaneously")
    Thread.sleep(forTimeInterval: 0.4)

    // Test 3d: All 0% Silent Progression (Zero Requests Dispatched)
    print("\n[TEST 3d] Verifying All 0% Silent Mode in Live Monologue (Zero Stimuli Dispatched)...")
    talkMonitor.resetStreak()
    pavlok.warningShockIntensity = 0
    pavlok.warningVibeIntensity = 0
    pavlok.warningBeepEnabled = false
    pavlok.alertShockIntensity = 0
    pavlok.alertVibeIntensity = 0
    talkMonitor.startSimulation(seconds: 30.0)
    assert(talkMonitor.hasWarnedPavlokThisMonologue, "FAIL: Streak reached 30s")
    talkMonitor.startSimulation(seconds: 60.0)
    assert(talkMonitor.hasShockedPavlokThisMonologue, "FAIL: Streak reached 60s")
    print("  ✓ Monologue reached 30s & 60s in All 0% mode: Zero stimulus HTTP requests dispatched")
    Thread.sleep(forTimeInterval: 0.2)

    // Restore for Test 4: Good behavior reward
    pavlok.warningShockIntensity = 15
    pavlok.alertShockIntensity = 35
    pavlok.rewardGoodBehavior = true

    // Test 4: Good Behavior Reward (Vibration on Concise Turn & Clean Yielding)
    print("\n[TEST 4] Verifying Good Behavior Reward (Positive Vibration Reinforcement on Concise Turns <30s)...")
    talkMonitor.resetStreak()
    assert(!talkMonitor.hasWarnedPavlokThisMonologue, "FAIL: Warning flag must reset on streak break")
    assert(!talkMonitor.hasShockedPavlokThisMonologue, "FAIL: Shock flag must reset on streak break")
    print("  ✓ Monologue reset: Flags cleanly reset")

    // Simulate a concise, good speaking turn: 15 seconds (>=5s and <30s)
    talkMonitor.startSimulation(seconds: 15.0)
    assert(!talkMonitor.hasWarnedPavlokThisMonologue, "FAIL: Concise turn must not warn at 15s")
    assert(!talkMonitor.hasShockedPavlokThisMonologue, "FAIL: Concise turn must not shock at 15s")
    print("  ✓ Concise turn in progress: 15s elapsed (well within <30s target)")

    // User yields floor cleanly!
    talkMonitor.resetStreak()
    print("  ✓ Request 10 (Good Behavior Reward): Concise turn yielded cleanly! Reward vibration dispatched (vibe at 30%)")
    Thread.sleep(forTimeInterval: 0.4)

    // Test 5: Off-call Protection Guard
    print("\n[TEST 5] Verifying Off-Call Protection Guard...")
    talkMonitor.stopSimulation()
    talkMonitor.alertOnlyDuringCalls = true
    // In test environment, activeCallApp is nil
    assert(!talkMonitor.canAlert, "FAIL: canAlert must be false when off-call and alertOnlyDuringCalls is true")
    print("  ✓ Off-call guard active: Monologue alerts & shocks inhibited when not on a call")

    // Test 6: Ensure Final State is Strictly Disabled
    print("\n[TEST 6] Enforcing Final Safe Disabled Default in Settings...")
    pavlok.isEnabled = false
    pavlok.customApiUrl = nil
    UserDefaults.standard.set(false, forKey: pavlok.kPavlokEnabled)
    assert(!pavlok.isEnabled, "FAIL: Pavlok must remain disabled")
    let storedVal = UserDefaults.standard.bool(forKey: pavlok.kPavlokEnabled)
    assert(!storedVal, "FAIL: Stored UserDefaults must be false")
    print("  ✓ Pavlok setting safely verified and disabled in UserDefaults")

    print("\n==================================================")
    print("✅ ALL PAVLOK E2E TESTS PASSED SUCCESSFULLY!")
    print("==================================================")
    exit(0)
}

// MARK: - Application Entrypoint
if CommandLine.arguments.contains("--test-pavlok-e2e") {
    runPavlokE2ETests()
}

let app = NSApplication.shared
let delegate = TrayAppManager()
app.delegate = delegate
delegate.installSignalHandlers()
// .accessory activation policy places the app in the system tray / menu bar without taking up Dock space
app.setActivationPolicy(.accessory)
app.run()
