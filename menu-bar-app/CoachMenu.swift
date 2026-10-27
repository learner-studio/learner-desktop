import AppKit
import Foundation

// The coach's and the wristband's parts of the tray menu.

// MARK: - Cue panel

/// One phase's wristband cues (30 s warning or 60 s hard stop): a checkbox and a level
/// picker per modality. A view inside a menu item, so the menu stays open while you click.
final class CueSubmenuView: NSView {
    let phase: CuePhase
    let settings: CoachSettings
    private var rows: [(modality: Modality, box: NSButton, picker: NSSegmentedControl?)] = []
    var onChange: (() -> Void)?

    private static let names: [Modality: String] = [.zap: "⚡ Electric Shock", .vibe: "📳 Haptic Vibration",
                                                    .beep: "🔔 Audio Chime on Wristband (Beep)"]

    init(phase: CuePhase, settings: CoachSettings = .shared) {
        self.phase = phase
        self.settings = settings
        let width: CGFloat = 340
        let height = CGFloat(52 + phase.modalities.reduce(0) { $0 + ($1 == .beep ? 28 : 62) })
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        var y = height - 30
        let title = NSTextField(labelWithString: "\(phase.title) Modalities (Multi-Select)")
        title.font = .boldSystemFont(ofSize: 11)
        title.textColor = .secondaryLabelColor
        title.frame = NSRect(x: 16, y: y, width: width - 32, height: 16)
        addSubview(title)
        y -= 26
        for m in phase.modalities {
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
            box.frame = NSRect(x: 16, y: y, width: width - 32, height: 20)
            box.font = .systemFont(ofSize: 13, weight: .medium)
            addSubview(box)
            y -= 28
            var picker: NSSegmentedControl?
            if m != .beep {
                let labels = phase.choices(m).map { $0 == 0 ? "0% Off" : "\($0)%\($0 == phase.defaultLevel(m) ? " ★" : "")" }
                let seg = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: self, action: #selector(picked(_:)))
                seg.frame = NSRect(x: 16, y: y, width: width - 32, height: 24)
                seg.segmentDistribution = .fillEqually
                seg.controlSize = .small
                seg.font = .systemFont(ofSize: 10)
                addSubview(seg)
                picker = seg
                y -= 34
            }
            rows.append((m, box, picker))
        }
        let tip = NSTextField(labelWithString: "💡 Multi-select active • Click outside to close")
        tip.font = .systemFont(ofSize: 10)
        tip.textColor = .tertiaryLabelColor
        tip.alignment = .center
        tip.frame = NSRect(x: 16, y: 8, width: width - 32, height: 14)
        addSubview(tip)
        sync()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func sync() {
        let levels = settings.levels(phase)
        for row in rows {
            let level = levels.level(row.modality)
            row.box.state = level > 0 ? .on : .off
            let state = row.modality == .beep ? (level > 0 ? "Active" : "Off") : (level > 0 ? "Active: \(level)%" : "0% / Disabled")
            row.box.title = "\(CueSubmenuView.names[row.modality]!) (\(state))"
            row.picker?.selectedSegment = phase.choices(row.modality).firstIndex(of: level) ?? 0
        }
    }

    @objc private func toggled(_ sender: NSButton) {
        guard let m = rows.first(where: { $0.box === sender })?.modality else { return }
        settings.toggle(m, for: phase)
        sync()
        onChange?()
    }

    @objc private func picked(_ sender: NSSegmentedControl) {
        guard let m = rows.first(where: { $0.picker === sender })?.modality, sender.selectedSegment >= 0 else { return }
        settings.setLevel(m, phase.choices(m)[sender.selectedSegment], for: phase)
        sync()
        onChange?()
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



// MARK: - Coach and Pavlok menu sections and actions

extension TrayAppManager {
    func addSpeakingCoachSection() {
        let coach = talkMonitor
        header("Speaking Coach (Talk-Time Monitor)")
        let callSuffix = coach.activeCallApp.map { " (\($0))" } ?? ""
        if coach.isAlertActive {
            add("   🚨 Monologue Alert: \(coach.formattedDuration) continuous speech\(callSuffix)")
            add("   ✕ Dismiss Alert Toast", #selector(dismissToast))
        } else if coach.isWarningActive {
            add("   ⚠️ Monologue Warning: \(coach.formattedDuration) continuous speech\(callSuffix)")
        } else if let call = coach.activeCallApp {
            add("   🟢 Status: In call (\(call)\(coach.activeCallTitle.map { " · \($0)" } ?? "")) • Monitoring talk-time")
        } else {
            add(coach.alertOnlyDuringCalls
                ? "   🟢 Status: Standby (Monitoring for calls • Off-call quiet)"
                : "   🟢 Status: Listening (All speech monitored: >30s warn / >1m alert)")
        }
        if coach.currentStreak > 0 {
            add("   ↺ Reset Speaking Streak (\(coach.formattedDuration))", #selector(resetStreakAction))
        }
        statusMenu.addItem(NSMenuItem.separator())
    }

    func pavlokMenuItem() -> NSMenuItem {
        let pavlok = PavlokController.shared
        let settings = CoachSettings.shared
        let menu = NSMenu()
        add("Connection: \(pavlok.connectionStatusText)", to: menu).image =
            PavlokDogIcon.image(connected: pavlok.isBleConnected, isScanning: pavlok.isBleScanning)
        add(settings.wearableEnabled ? "✓ Wearable Operant Feedback Enabled" : "○ Wearable Feedback Disabled (Safe Default)",
            #selector(togglePavlokEnabled), to: menu)

        let presets = NSMenu()
        let current = settings.matchingPreset?.key
        for p in CuePreset.all {
            func describe(_ phase: CuePhase) -> String {
                let on = phase.modalities.filter { p.modalities(phase).contains($0) }
                return on.isEmpty ? "⚪ off" : on.map { "\($0 == .zap ? "⚡ Shock" : "📳 Vibe") \(settings.savedLevel($0, phase))%" }.joined(separator: " + ")
            }
            let item = add("\(p.key == current ? "⦿" : "○") \(p.name): 30s \(describe(.warning)) • 60s \(describe(.hardStop))",
                           #selector(selectCuePreset(_:)), to: presets)
            item.representedObject = p.key
            item.state = p.key == current ? .on : .off
        }
        add("🎛️ Cue Preset: \(settings.presetName)", to: menu).submenu = presets

        for phase in CuePhase.allCases {
            let view = CueSubmenuView(phase: phase, settings: settings)
            let parent = add("⏱️ \(phase.title): \(settings.levels(phase).summary)", to: menu)
            view.onChange = { [weak self, weak parent] in
                parent?.title = "⏱️ \(phase.title): \(settings.levels(phase).summary)"
                self?.updateTrayButton()
            }
            let sub = NSMenu()
            let holder = NSMenuItem()
            holder.view = view
            sub.addItem(holder)
            parent.isEnabled = true
            parent.submenu = sub
        }
        add(settings.rewardGoodBehavior ? "✓ Good Behavior: Reward Vibration on Concise Turns (<30s, wristband arms)"
                                        : "○ Good Behavior: Reward Vibration Disabled",
            #selector(toggleGoodBehaviorReward), to: menu)
        menu.addItem(NSMenuItem.separator())
        add("Keep Bluetooth Connected", #selector(togglePavlokConnection), to: menu).state = settings.keepConnected ? .on : .off
        add("🔍 Scan & Connect via Bluetooth", #selector(scanPavlokBluetooth), to: menu)
        add(settings.apiToken.isEmpty ? "🔑 Configure Cloud Backup Token (Optional)..." : "🔑 Change Cloud Backup Token (Configured)...",
            #selector(promptPavlokToken), to: menu)
        let state = !settings.wearableEnabled ? "⚪ Disabled" : (pavlok.isBleConnected ? "🟢 Connected" : "🟡 Not connected")
        let parent = NSMenuItem(title: "⚡ Pavlok: \(state)", action: nil, keyEquivalent: "")
        parent.submenu = menu
        return parent
    }

    func addCoachSettings(to settings: NSMenu) {
        add(talkMonitor.alertOnlyDuringCalls ? "✓ Alert Only During Calls (Off-Call Silent)" : "○ Alert On All Monologues (Any App)",
            #selector(toggleAlertOnlyDuringCalls), to: settings)
        let mode = HabitExperimentManager.shared.currentMode
        let modes = NSMenu()
        for m in AssignmentMode.allCases {
            add("\(mode == m ? "✓ " : "   ")\(m.displayName)", #selector(selectExperimentArm(_:)), to: modes).representedObject = m.rawValue
        }
        let parent = add("Select Active Intervention Condition...", to: settings)
        parent.isEnabled = true
        parent.submenu = modes
    }

    /// A test fire forwarded by `--pavlok-test-fire` (this process holds the link).
    @objc func receivePavlokTest(_ notification: Notification) {
        guard let request = PavlokTestRequest(object: notification.object, userInfo: notification.userInfo,
                                              pid: ProcessInfo.processInfo.processIdentifier),
              handledPavlokRequests.insert(request.id).inserted else { return }
        PavlokController.shared.testFire(request.modality, intensity: request.intensity, operationId: request.id) { fired in
            DistributedNotificationCenter.default().postNotificationName(
                PavlokTestRequest.resultName, object: request.id,
                userInfo: ["success": fired.result.delivered, "detail": fired.result.detail, "line": fired.line],
                deliverImmediately: true)
        }
    }

    // MARK: Actions

    @objc func dismissToast() {
        MonologueToastController.shared.hide()
        updateTrayButton()
        rebuildMenu()
    }

    @objc func toggleAlertOnlyDuringCalls() {
        talkMonitor.alertOnlyDuringCalls.toggle()
        talkMonitor.evaluate()
        rebuildMenu()
    }

    @objc func resetStreakAction() {
        talkMonitor.resetStreak()
        updateTrayButton()
        rebuildMenu()
    }

    @objc func togglePavlokConnection() {
        CoachSettings.shared.keepConnected.toggle()
        rebuildMenu()
    }

    @objc func scanPavlokBluetooth() {
        CoachSettings.shared.keepConnected = true
        PavlokController.shared.startBleScan(force: true)
        rebuildMenu()
    }

    @objc func togglePavlokEnabled() {
        CoachSettings.shared.wearableEnabled.toggle()
        rebuildMenu()
    }

    @objc func selectCuePreset(_ sender: NSMenuItem) {
        guard let preset = CuePreset.all.first(where: { $0.key == sender.representedObject as? String }) else { return }
        CoachSettings.shared.apply(preset)
        rebuildMenu()
        updateTrayButton()
    }

    @objc func toggleGoodBehaviorReward() {
        CoachSettings.shared.rewardGoodBehavior.toggle()
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
        input.stringValue = CoachSettings.shared.apiToken
        alert.accessoryView = input
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        CoachSettings.shared.apiToken = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        rebuildMenu()
        updateTrayButton()
    }

    @objc func selectExperimentArm(_ sender: NSMenuItem) {
        guard let mode = (sender.representedObject as? String).flatMap(AssignmentMode.init) else { return }
        HabitExperimentManager.shared.currentMode = mode
        rebuildMenu()
    }
}
