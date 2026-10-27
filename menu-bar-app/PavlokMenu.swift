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
