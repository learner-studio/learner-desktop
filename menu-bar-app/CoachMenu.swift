import AppKit
import Foundation
import ServiceManagement
import SQLite3
import CoreBluetooth
import CommonCrypto

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


// MARK: - Coach and Pavlok menu sections and actions

extension TrayAppManager {
    func addSpeakingCoachSection() {
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
    }

    func pavlokMenuItem() -> NSMenuItem {
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
        return pavParent
    }

    func addCoachSettings(to settings: NSMenu) {
        _ = add(talkMonitor.alertOnlyDuringCalls ? "✓ Alert Only During Calls (Off-Call Silent)" : "○ Alert On All Monologues (Any App)",
                #selector(toggleAlertOnlyDuringCalls), to: settings)
        let mode = HabitExperimentManager.shared.currentMode
        let armMenu = NSMenu()
        for arm in HabitTreatmentArm.allCases {
            add("\(mode == arm ? "✓ " : "   ")\(arm.displayName)", #selector(selectExperimentArm(_:)), to: armMenu).representedObject = arm.rawValue
        }
        let armParent = add("Select Active Intervention Condition...", to: settings)
        armParent.isEnabled = true
        armParent.submenu = armMenu
    }

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

    @objc func selectExperimentArm(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let arm = HabitTreatmentArm(rawValue: raw) else { return }
        HabitExperimentManager.shared.currentMode = arm
        print("[HabitExperiment] Switched experiment condition to: \(arm.displayName)")
        fflush(stdout)
        rebuildMenu()
    }
}
