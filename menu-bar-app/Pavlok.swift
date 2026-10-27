import AppKit
import Foundation
import CoreBluetooth

// The Pavlok wristband: direct Bluetooth first (an acknowledged write, <15 ms), the Pavlok
// cloud relay as a fallback for automatic cues. Every send reports a typed result and
// leaves two audit rows (requested, result) in habit_events as habit_type
// "pavlok_intervention".

// MARK: - Stimulus results

enum Transport: String {
    /// Direct Bluetooth write, acknowledged by the wristband.
    case ble
    /// Pavlok cloud relay (HTTP).
    case cloud
    /// A macOS sound on this Mac.
    case sound
    /// The on-screen toast.
    case screen
    /// Nothing was sent.
    case none

    var label: String {
        switch self {
        case .ble: return "Direct Bluetooth"
        case .cloud: return "Pavlok Cloud"
        case .sound: return "Mac sound"
        case .screen: return "Screen"
        case .none: return "not sent"
        }
    }
}

struct StimulusResult {
    let delivered: Bool
    let transport: Transport
    let detail: String

    /// The wristband itself confirmed it (the cloud only confirms it accepted the request).
    var acknowledged: Bool { delivered && transport == .ble }

    static func notSent(_ why: String) -> StimulusResult { StimulusResult(delivered: false, transport: .none, detail: why) }
}

/// Who a stimulus is for, for the audit row.
struct StimulusContext {
    let sessionId: String
    let arm: String
    let callApp: String?
    /// A human pressed a test button: Bluetooth only, allowed while only "keep connected" is on.
    let manual: Bool
    var operationId = UUID().uuidString.lowercased()
}

/// A wristband the coach can cue. Completion always comes, on the main thread.
protocol Wearable: AnyObject {
    /// Stimuli are switched on in settings.
    var isEnabled: Bool { get }
    func send(_ modality: Modality, intensity: Int, reason: String, context: StimulusContext,
              completion: @escaping (StimulusResult) -> Void)
}

// MARK: - Packets

/// The Pavlok Bluetooth protocol: which characteristic is which, and what to write.
enum PavlokPacket {
    static let service = CBUUID(string: "156E1000-A300-4FEA-897B-86F698D74461")

    /// The stimulus a characteristic carries: Pavlok 2/3 (…1003/1001/1002) or Pavlok 1.
    static func modality(of uuid: String) -> Modality? {
        let u = uuid.uppercased()
        if u.contains("1003") || u.contains("6E9D7A34") { return .zap }
        if u.contains("1001") || u.contains("7ECA7033") { return .vibe }
        if u.contains("1002") || u.contains("EFD6FD9D") { return .beep }
        return nil
    }

    static func isBattery(_ uuid: String) -> Bool { uuid.uppercased().contains("2A19") }

    /// Pavlok 2/3 characteristics carry the 100x short ids; anything else is a Pavlok 1.
    static func isPavlok2(_ uuid: String, _ m: Modality) -> Bool {
        uuid.uppercased().contains(["zap": "1003", "vibe": "1001", "beep": "1002"][m.rawValue]!)
    }

    /// One pulse at `intensity` (clamped to 1-100: 0 never reaches here, it means off).
    static func encode(_ m: Modality, intensity: Int, pavlok2: Bool = true) -> Data {
        let v = UInt8(max(1, min(100, intensity)))
        guard pavlok2 else {
            // Pavlok 1: [count, level 0-255, on, off]
            return Data([0x01, UInt8((Double(v) * 2.55).rounded()), 0x32, 0x32])
        }
        switch m {
        case .zap: return Data([0x81, v])
        // Vibration and beep share a layout: one pulse, level, ~0.65 s on, ~0.65 s gap
        // (see ztrayl3/PyPav2, beep()).
        case .vibe, .beep: return Data([0x81, 0x0C, v, 0x18, 0x18])
        }
    }

    /// The discovery filter: a name or an advertised service that looks like a Pavlok.
    static func looksLikePavlok(name: String, services: [String]) -> Bool {
        let n = name.lowercased()
        return ["pavlok", "shock", "sc3", "sc2", "p3-"].contains(where: n.contains) || n == "p3"
            || services.contains { $0.uppercased().contains("1000") || $0.uppercased().contains("6E9D") }
    }
}

// MARK: - Cloud relay

/// POST to Pavlok's stimulus API. Every outcome, including a response that is neither an
/// error nor HTTP, completes exactly once.
struct PavlokCloud {
    var endpoint = URL(string: "https://api.pavlok.com/api/v5/stimulus/send")!
    var userEndpoint = URL(string: "https://api.pavlok.com/api/v5/user/")!
    var timeout: TimeInterval = 4

    func send(_ m: Modality, intensity: Int, reason: String, token: String,
              completion: @escaping (StimulusResult) -> Void) {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject:
            ["stimulus": ["stimulusType": m.rawValue, "stimulusValue": intensity, "reason": reason]])
        req.timeoutInterval = timeout
        URLSession.shared.dataTask(with: req) { data, response, error in
            let result: StimulusResult
            if let error = error {
                result = StimulusResult(delivered: false, transport: .cloud, detail: "cloud: \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse {
                let body = data.flatMap { String(data: $0, encoding: .utf8) }.map { " \($0.prefix(120))" } ?? ""
                let ok = (200...299).contains(http.statusCode)
                result = StimulusResult(delivered: ok, transport: .cloud, detail: "HTTP \(http.statusCode)\(ok ? "" : body)")
            } else {
                result = StimulusResult(delivered: false, transport: .cloud, detail: "cloud: no HTTP response")
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    /// Whether the token is accepted (for the menu's status line).
    func check(token: String, completion: @escaping (Bool) -> Void) {
        var req = URLRequest(url: userEndpoint)
        req.setValue(token, forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 3
        URLSession.shared.dataTask(with: req) { _, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? false
            DispatchQueue.main.async { completion(ok) }
        }.resume()
    }
}

// MARK: - Controller

final class PavlokController: NSObject, Wearable, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = PavlokController(settings: .shared, logger: .shared)

    /// Consecutive failed connects to the remembered wristband before scanning afresh.
    static let rememberedAttempts = 3
    static let connectTimeout: TimeInterval = 20
    static let ackTimeout: TimeInterval = 5

    let settings: CoachSettings
    let logger: HabitEventLogger
    var cloud = PavlokCloud()
    private let log = Log("Pavlok")

    /// The tray redraws on this (main thread).
    var onStatusChanged: (() -> Void)?

    /// Log every advertising peripheral the discovery filter rejects (`--trace-ble`).
    static var traceBleDiscovery = false
    private var traced = Set<UUID>()

    // Link state
    private var central: CBCentralManager?
    private(set) var peripheral: CBPeripheral?
    private var characteristics: [Modality: CBCharacteristic] = [:]
    private(set) var batteryLevel: Int?
    private(set) var isBleConnected = false
    private(set) var isBleScanning = false
    private(set) var bleDeviceName: String?
    /// The cloud relay accepts the token.
    private(set) var isOnline = false
    private var reconnect = Backoff(base: 2, max: 60)
    private var reconnectWork: DispatchWorkItem?
    /// Consecutive connects that never became usable.
    private var failedConnects = 0
    private var pendingWrites: [CBUUID: (id: UUID, completion: (StimulusResult) -> Void)] = [:]
    /// The headless test fire holds the link without touching the saved settings.
    var holdConnection = false {
        didSet { applyConnectionWish() }
    }
    private(set) var isTestFiring = false

    var isEnabled: Bool { settings.wearableEnabled }
    var connectionRequested: Bool { settings.wearableEnabled || settings.keepConnected || holdConnection }

    init(settings: CoachSettings, logger: HabitEventLogger) {
        self.settings = settings
        self.logger = logger
        super.init()
        settings.observe { [weak self] key in
            guard let self = self else { return }
            switch key {
            case .wearableEnabled, .keepConnected: self.applyConnectionWish()
            case .apiToken: self.updateConnectionStatus()
            default: self.statusChanged()
            }
        }
        // Creating a CBCentralManager is what raises macOS's Bluetooth prompt, so nothing
        // touches Bluetooth until the feature is on.
        if connectionRequested { startBleScan() }
    }

    private func statusChanged() { onStatusChanged?() }

    private func applyConnectionWish() {
        if connectionRequested { startBleScan(force: true) } else { disconnectBle() }
        updateConnectionStatus()
    }

    var connectionStatusText: String {
        if !connectionRequested { return "⚪ Disabled (Safe Default)" }
        if isBleConnected {
            let battery = batteryLevel.map { " • \($0)% 🔋" } ?? ""
            return "🟢 Connected (\(bleDeviceName ?? "Pavlok 3") via Bluetooth\(battery) • <15ms)"
        }
        if isBleScanning { return "🔵 Searching for Bluetooth Wristband..." }
        if !settings.apiToken.isEmpty { return isOnline ? "🟡 Online (Cloud Relay Backup • ~400ms)" : "🟡 Cloud Configured (Bluetooth Disconnected)" }
        return "🔴 Bluetooth Disconnected (Turn on Pavlok)"
    }

    /// Re-checks the cloud token (menu open, token change).
    func updateConnectionStatus() {
        guard isEnabled, !settings.apiToken.isEmpty else {
            isOnline = false
            statusChanged()
            return
        }
        cloud.check(token: settings.apiToken) { [weak self] ok in
            guard let self = self else { return }
            if ok != self.isOnline { self.log.info("cloud relay \(ok ? "accepts" : "rejects") the token") }
            self.isOnline = ok
            self.statusChanged()
        }
    }

    // MARK: Connecting

    func startBleScan(force: Bool = false) {
        guard connectionRequested else { return }
        if let p = peripheral, p.state == .connected || p.state == .connecting { return }
        reconnectWork?.cancel()
        guard let central = central else {
            // The scan starts from centralManagerDidUpdateState once the radio is on.
            central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
            return
        }
        guard central.state == .poweredOn, force || !central.isScanning else { return }
        central.stopScan()
        if let connected = central.retrieveConnectedPeripherals(withServices: [PavlokPacket.service]).first {
            connect(connected, name: connected.name ?? "", why: "already connected to macOS")
        } else if failedConnects < PavlokController.rememberedAttempts, let id = settings.lastDeviceId,
                  let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known, name: known.name ?? "", why: "remembered wristband \(id)")
        } else {
            if failedConnects >= PavlokController.rememberedAttempts {
                log.warn("\(failedConnects) connects failed in a row; scanning for any wristband instead of the remembered one")
            } else {
                log.info("scanning for a Pavlok")
            }
            isBleScanning = true
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
        statusChanged()
    }

    private func connect(_ p: CBPeripheral, name: String, why: String) {
        guard let central = central else { return }
        log.info("connecting to \"\(name.isEmpty ? "Pavlok" : name)\" (\(why))")
        central.stopScan()
        isBleScanning = false
        bleDeviceName = name.isEmpty ? "Pavlok 3" : name
        peripheral = p
        p.delegate = self
        central.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        DispatchQueue.main.asyncAfter(deadline: .now() + PavlokController.connectTimeout) { [weak self, weak p] in
            guard let self = self, let p = p, self.peripheral === p, p.state == .connecting else { return }
            central.cancelPeripheralConnection(p)
            self.connectFailed("no connection after \(Int(PavlokController.connectTimeout)) s")
        }
        statusChanged()
    }

    /// Forget the link's characteristics and state (it dropped, failed or was switched off).
    private func clearLink() {
        isBleConnected = false
        isBleScanning = false
        peripheral = nil
        characteristics = [:]
        batteryLevel = nil
    }

    private func connectFailed(_ why: String) {
        failedConnects += 1
        log.warn("connect failed (\(failedConnects) in a row): \(why)")
        clearLink()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectWork?.cancel()
        statusChanged()
        guard connectionRequested else { return }
        let wait = reconnect.failed()
        log.noisy("reconnecting in \(Job.describe(wait)) (attempt \(reconnect.failures))")
        let work = DispatchWorkItem { [weak self] in self?.startBleScan(force: true) }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    func disconnectBle() {
        reconnectWork?.cancel()
        failPendingWrites("Bluetooth disconnected")
        central?.stopScan()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        if isBleConnected || isBleScanning { log.info("Bluetooth link closed (switched off)") }
        clearLink()
        statusChanged()
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // An unauthorised or powered-off radio otherwise looks exactly like a band out of range.
        let state: String
        switch central.state {
        case .poweredOn: state = "poweredOn"
        case .poweredOff: state = "poweredOff (turn Bluetooth on)"
        case .unauthorized: state = "unauthorized (grant Bluetooth in System Settings > Privacy & Security)"
        case .unsupported: state = "unsupported"
        case .resetting: state = "resetting"
        case .unknown: state = "unknown"
        @unknown default: state = "state \(central.state.rawValue)"
        }
        let auth: String
        switch CBCentralManager.authorization {
        case .allowedAlways: auth = "allowed"
        case .denied: auth = "DENIED in System Settings > Privacy & Security > Bluetooth"
        case .restricted: auth = "restricted by policy"
        case .notDetermined: auth = "not yet granted (macOS will prompt on first scan)"
        @unknown default: auth = "unknown"
        }
        log.info("radio state: \(state) • permission: \(auth)")
        if central.state == .poweredOn {
            startBleScan(force: true)
        } else {
            failPendingWrites("Bluetooth radio \(state)")
            clearLink()
            statusChanged()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        guard connectionRequested, self.peripheral == nil || self.peripheral?.state == .disconnected else { return }
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let services = ((advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []).map(\.uuidString)
        guard PavlokPacket.looksLikePavlok(name: name, services: services) else {
            // "It never connects": a sleeping band advertises nothing; a renamed one is
            // filtered out here. Only the trace tells them apart.
            if PavlokController.traceBleDiscovery, traced.insert(peripheral.identifier).inserted {
                log.info("trace: ignored \"\(name.isEmpty ? "(no name)" : name)\" \(peripheral.identifier) RSSI \(rssi) services [\(services.joined(separator: ","))]")
            }
            return
        }
        connect(peripheral, name: name, why: "discovered, RSSI \(rssi)")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard connectionRequested else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        log.info("connected to \"\(peripheral.name ?? "wristband")\"; discovering services")
        settings.lastDeviceId = peripheral.identifier
        isBleConnected = true
        isBleScanning = false
        peripheral.discoverServices(nil)
        // Connected but unusable (discovery stalled) would never recover on its own.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self = self, self.peripheral === peripheral, peripheral.state == .connected,
                  self.characteristics[.zap] == nil, self.characteristics[.vibe] == nil else { return }
            self.dropUnusable(peripheral, "no stimulus characteristics 15 s after connecting")
        }
        statusChanged()
    }

    /// Disconnecting hands it to didDisconnectPeripheral, which counts the failure and reconnects.
    private func dropUnusable(_ p: CBPeripheral, _ why: String) {
        log.warn("connected but unusable (\(why)); reconnecting")
        central?.cancelPeripheralConnection(p)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectFailed(error?.localizedDescription ?? "unknown error")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        failPendingWrites("Bluetooth disconnected")
        let wasUsable = !characteristics.isEmpty
        let why = error?.localizedDescription ?? "link dropped"
        if wasUsable {
            log.warn("disconnected from \"\(peripheral.name ?? "wristband")\": \(why)")
            clearLink()
            scheduleReconnect()
        } else {
            connectFailed("disconnected before it was usable: \(why)")
        }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error { return dropUnusable(peripheral, "service discovery: \(error.localizedDescription)") }
        for service in peripheral.services ?? [] { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error { return dropUnusable(peripheral, "characteristic discovery: \(error.localizedDescription)") }
        let wasUsable = !characteristics.isEmpty
        for c in service.characteristics ?? [] {
            if let m = PavlokPacket.modality(of: c.uuid.uuidString) {
                characteristics[m] = c
                log.info("found \(m.rawValue) characteristic \(c.uuid)")
            } else if PavlokPacket.isBattery(c.uuid.uuidString) {
                peripheral.readValue(for: c)
                if c.properties.contains(.notify) { peripheral.setNotifyValue(true, for: c) }
            }
        }
        if !wasUsable && !characteristics.isEmpty {
            failedConnects = 0
            reconnect.succeeded()
            log.info("ready: \(characteristics.keys.map(\.rawValue).sorted().joined(separator: ", "))")
        }
        statusChanged()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard PavlokPacket.isBattery(characteristic.uuid.uuidString), let data = characteristic.value, let level = data.first else { return }
        if batteryLevel != Int(level) { log.info("battery \(level)%") }
        batteryLevel = Int(level)
        statusChanged()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, let pending = pendingWrites.removeValue(forKey: characteristic.uuid) else { return }
        pending.completion(StimulusResult(delivered: error == nil, transport: .ble,
            detail: error.map { "BLE write failed: \($0.localizedDescription)" } ?? "BLE acknowledged by wristband"))
    }

    func isReady(for m: Modality) -> Bool { isBleConnected && characteristics[m] != nil }

    private func failPendingWrites(_ why: String) {
        let waiting = pendingWrites.values.map(\.completion)
        pendingWrites.removeAll()
        waiting.forEach { $0(StimulusResult(delivered: false, transport: .ble, detail: why)) }
    }

    /// An acknowledged write: only the wristband's ack counts as delivered.
    private func write(_ data: Data, to c: CBCharacteristic, on p: CBPeripheral, completion: @escaping (StimulusResult) -> Void) {
        guard pendingWrites[c.uuid] == nil else {
            return completion(StimulusResult(delivered: false, transport: .ble, detail: "previous BLE stimulus still awaiting acknowledgement"))
        }
        guard c.properties.contains(.write) else {
            return completion(StimulusResult(delivered: false, transport: .ble, detail: "BLE characteristic does not support acknowledged writes"))
        }
        let id = UUID()
        pendingWrites[c.uuid] = (id, completion)
        p.writeValue(data, for: c, type: .withResponse)
        DispatchQueue.main.asyncAfter(deadline: .now() + PavlokController.ackTimeout) { [weak self] in
            guard let self = self, self.pendingWrites[c.uuid]?.id == id else { return }
            self.log.warn("no acknowledgement within \(Int(PavlokController.ackTimeout)) s; dropping the link")
            self.failPendingWrites("BLE acknowledgement timed out")
            self.disconnectBle()
            self.scheduleReconnect()
        }
    }

    // MARK: Sending

    func send(_ m: Modality, intensity: Int, reason: String, context: StimulusContext,
              completion: @escaping (StimulusResult) -> Void) {
        let level = max(1, min(100, intensity))
        audit(m, level, reason, context, phase: "requested", result: nil)
        let started = Date()
        let finish: (StimulusResult) -> Void = { [weak self] result in
            guard let self = self else { return }
            self.audit(m, level, reason, context, phase: "result", result: result, started: started)
            let line = "\(m.rawValue) \(level)% \(result.delivered ? "delivered" : "FAILED") via \(result.transport.rawValue): \(result.detail) (\(reason))"
            if result.delivered { self.log.info(line) } else { self.log.warn(line) }
            completion(result)
        }
        guard context.manual ? connectionRequested : isEnabled else { return finish(.notSent("Pavlok is disabled in settings")) }
        if isBleConnected, let p = peripheral, let c = characteristics[m] {
            return write(PavlokPacket.encode(m, intensity: level, pavlok2: PavlokPacket.isPavlok2(c.uuid.uuidString, m)), to: c, on: p, completion: finish)
        }
        // A bench test is about the Bluetooth link; the cloud would hide a dead one.
        guard !context.manual else { return finish(.notSent("Bluetooth not connected or no \(m.rawValue) characteristic")) }
        guard !settings.apiToken.isEmpty else { return finish(.notSent("Bluetooth disconnected and no cloud token")) }
        cloud.send(m, intensity: level, reason: reason, token: settings.apiToken, completion: finish)
    }

    /// One habit_events row per phase of a send. Queued, never waited on here.
    private func audit(_ m: Modality, _ level: Int, _ reason: String, _ context: StimulusContext,
                       phase: String, result: StimulusResult?, started: Date = Date()) {
        logger.logTurn(
            habitType: "pavlok_intervention", sessionId: context.sessionId, callApp: context.callApp,
            callCategory: context.manual ? "device_test" : "work", treatmentArm: context.arm,
            turnDurationSec: 0, wordsSpoken: 0, warningFiredAt: nil, shockFiredAt: nil,
            latencyToYieldSec: nil, breached30s: false, breached60s: false, wasRewarded: false,
            metadata: [
                "source": "pavlok_controller_v2", "operation_id": context.operationId,
                "manual_test": context.manual, "phase": phase, "modality": m.rawValue,
                "intensity_percent": level, "reason": reason,
                "requested_at": ISO8601DateFormatter().string(from: started),
                "elapsed_ms": Date().timeIntervalSince(started) * 1000,
                "success": result.map { $0.delivered as Any } ?? NSNull(),
                "device_acknowledged": result?.acknowledged ?? false,
                "detail": result.map { $0.detail as Any } ?? NSNull(),
                "transport": result?.transport.rawValue ?? NSNull(),
                "device_name": bleDeviceName as Any? ?? NSNull(),
                "device_id": peripheral?.identifier.uuidString as Any? ?? NSNull(),
                "battery_percent": batteryLevel as Any? ?? NSNull(),
                "bluetooth_connected": isBleConnected,
            ])
    }

    // MARK: Manual test fire

    struct TestFireResult {
        let modality: Modality
        let intensity: Int
        let result: StimulusResult
        let at: Date

        var line: String {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            return "\(result.delivered ? "✅" : "❌") \(modality.label) \(intensity)% • \(result.transport.label) • \(result.detail) • \(f.string(from: at))"
        }
    }

    /// Fires one stimulus because a human asked (the --pavlok-test-fire command or the
    /// resident request it forwards). Waits up to `wait` for the link; Bluetooth only.
    func testFire(_ m: Modality, intensity: Int, operationId: String = UUID().uuidString.lowercased(),
                  wait: TimeInterval = 15, completion: @escaping (TestFireResult) -> Void) {
        let context = StimulusContext(sessionId: "manual_test_" + operationId, arm: "manual_test",
                                      callApp: "Manual device test", manual: true, operationId: operationId)
        func finish(_ r: StimulusResult) {
            isTestFiring = false
            let fired = TestFireResult(modality: m, intensity: intensity, result: r, at: Date())
            log.info("test fire: \(fired.line)")
            completion(fired)
            statusChanged()
        }
        guard !isTestFiring else {
            return completion(TestFireResult(modality: m, intensity: intensity, result: .notSent("a test is already in progress"), at: Date()))
        }
        guard connectionRequested else { return finish(.notSent("Bluetooth connection is switched off")) }
        // 0% means off everywhere; send() would clamp it up to 1% and buzz the wrist anyway.
        guard intensity > 0 else { return finish(.notSent("\(m.label) intensity is 0%")) }
        isTestFiring = true
        statusChanged()
        startBleScan(force: !isBleConnected && !isBleScanning)
        // Wait for the characteristic, not merely the connection. .common keeps it running
        // while a menu is open.
        let deadline = Date().addingTimeInterval(wait)
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] timer in
            guard let self = self else { return timer.invalidate() }
            if !self.connectionRequested {
                timer.invalidate()
                finish(.notSent("Bluetooth connection is switched off"))
            } else if self.isReady(for: m) {
                timer.invalidate()
                self.send(m, intensity: intensity, reason: "Manual test fire", context: context, completion: finish)
            } else if Date() >= deadline {
                timer.invalidate()
                finish(.notSent("Bluetooth not ready after \(Int(wait)) s; still reconnecting in the background"))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}

// MARK: - Test-fire requests

/// `--pavlok-test-fire <vibe|beep|zap> [intensity 1-100] [--wait seconds] [--trace-ble]`
struct PavlokTestFireArgs: Equatable {
    var modality: Modality
    var intensity: Int?
    var wait: TimeInterval = 15
    var traceBle = false

    static let usage = """
        usage: --pavlok-test-fire <vibe|beep|zap> [intensity 1-100] [--wait seconds] [--trace-ble]
               the intensity applies to this shot only; the saved test level is left alone
               --wait       how long to look for the wristband (default 15 s, at most 300)
               --trace-ble  log every advertising peripheral the filter rejects

        """

    /// nil when the arguments are not valid (the caller prints the usage and exits 2).
    static func parse(_ args: [String]) -> PavlokTestFireArgs? {
        guard let i = args.firstIndex(of: "--pavlok-test-fire"), i + 1 < args.count,
              let m = Modality(rawValue: args[i + 1].lowercased()) else { return nil }
        var parsed = PavlokTestFireArgs(modality: m)
        if i + 2 < args.count, !args[i + 2].hasPrefix("--") {
            guard let level = Int(args[i + 2]), (1...100).contains(level) else { return nil }
            parsed.intensity = level
        }
        if let w = args.firstIndex(of: "--wait") {
            guard w + 1 < args.count, let s = Double(args[w + 1]), s > 0, s <= 300 else { return nil }
            parsed.wait = s
        }
        parsed.traceBle = args.contains("--trace-ble")
        return parsed
    }
}

/// A test fire the CLI forwards to the running app (which holds the Bluetooth link), as a
/// distributed notification. Only fresh, well-formed requests addressed to this process count.
struct PavlokTestRequest {
    static let requestName = Notification.Name("com.benpollack.pavlok.test-request")
    static let resultName = Notification.Name("com.benpollack.pavlok.test-result")

    let id: String
    let modality: Modality
    let intensity: Int

    init?(object: Any?, userInfo: [AnyHashable: Any]?, pid: Int32, now: Date = Date()) {
        guard object as? String == String(pid), let info = userInfo,
              let id = info["id"] as? String, UUID(uuidString: id) != nil,
              let m = (info["type"] as? String).flatMap(Modality.init),
              let level = info["intensity"] as? Int, (1...100).contains(level),
              let sent = info["sent_at"] as? Double, abs(now.timeIntervalSince1970 - sent) < 30 else { return nil }
        self.id = id
        modality = m
        intensity = level
    }
}

// MARK: - Headless test fire

/// `--pavlok-test-fire`: fires one stimulus and exits. Through the running app when there
/// is one (it holds the link), else by connecting itself. Saved settings are never changed.
func runPavlokTestFireCLI() {
    guard let args = PavlokTestFireArgs.parse(CommandLine.arguments) else {
        FileHandle.standardError.write(Data(PavlokTestFireArgs.usage.utf8))
        exit(2)
    }
    PavlokController.traceBleDiscovery = args.traceBle
    let log = Log("Pavlok")
    // The evidence goes to the app log, next to a fire from the menu; the verdict also
    // reaches the terminal through a descriptor saved before the redirect.
    let terminal = dup(STDOUT_FILENO)
    try? FileManager.default.createDirectory(atPath: (AppLog.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    freopen(AppLog.path, "a", stdout)
    func verdict(_ line: String) {
        log.info(line)
        var bytes = Array(("[Pavlok TestFire] " + line + "\n").utf8)
        if terminal >= 0 { _ = write(terminal, &bytes, bytes.count) }
    }
    let level = args.intensity ?? CoachSettings.shared.testLevel(args.modality)
    guard level > 0 else { verdict("FAILED: the saved \(args.modality.rawValue) test level is 0% (off)"); exit(1) }

    if let bundleID = Bundle.main.bundleIdentifier,
       let resident = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
        let id = UUID().uuidString.lowercased()
        let center = DistributedNotificationCenter.default()
        let observer = center.addObserver(forName: PavlokTestRequest.resultName, object: id, queue: .main) { note in
            let ok = note.userInfo?["success"] as? Bool ?? false
            verdict("\(ok ? "DELIVERED" : "FAILED"): \(note.userInfo?["line"] as? String ?? "no result") • through the running app")
            exit(ok ? 0 : 1)
        }
        _ = observer
        verdict("requested \(args.modality.rawValue) at \(level)% through the running app")
        center.postNotificationName(PavlokTestRequest.requestName, object: String(resident.processIdentifier),
            userInfo: ["id": id, "type": args.modality.rawValue, "intensity": level, "sent_at": Date().timeIntervalSince1970],
            deliverImmediately: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + args.wait + 10) {
            verdict("OUTCOME UNKNOWN: the running app did not reply; not retrying")
            exit(1)
        }
        RunLoop.main.run()
    }

    // Without a window App Nap throttles this process, and CoreBluetooth callbacks then
    // arrive late or never -- which looks exactly like a band that is not there.
    let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Pavlok headless test fire")
    func done(_ code: Int32) -> Never {
        HabitEventLogger.shared.close()
        ProcessInfo.processInfo.endActivity(activity)
        exit(code)
    }
    let pavlok = PavlokController.shared
    verdict("requested \(args.modality.label) at \(level)% (headless)")
    pavlok.holdConnection = true
    pavlok.testFire(args.modality, intensity: level, wait: args.wait) { fired in
        verdict("\(fired.result.delivered ? "DELIVERED" : "FAILED"): \(fired.line)")
        done(fired.result.delivered ? 0 : 1)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + args.wait + 20) {
        verdict("FAILED: no outcome after \(Int(args.wait + 20)) s")
        done(1)
    }
    RunLoop.main.run()
}
