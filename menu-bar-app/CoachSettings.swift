import Foundation
import CommonCrypto

// The speaking coach's settings and the experiment's arms. Everything the user can switch
// lives in CoachSettings (UserDefaults, every change logged); the 30 s warning and the 60 s
// hard stop are two values of one CuePhase, never two copies of the same code.

// MARK: - Stimuli

/// A stimulus the wristband can deliver.
enum Modality: String, CaseIterable {
    case zap, vibe, beep

    var label: String {
        switch self {
        case .zap: return "⚡ Zap"
        case .vibe: return "📳 Vibration"
        case .beep: return "🔔 Beep"
        }
    }
}

/// The two thresholds of a monologue: a warning at 30 s and a hard stop at 60 s.
enum CuePhase: String, CaseIterable {
    case warning, hardStop

    var seconds: TimeInterval { self == .warning ? 30 : 60 }
    /// habit_events metadata name.
    var threshold: String { self == .warning ? "30s_warning" : "60s_hard_stop" }
    var title: String { self == .warning ? "30s Warning" : "60s Hard Stop" }
    /// Prefix of the UserDefaults keys ("pavlok_warning_shock_intensity", "pavlok_alert_...").
    fileprivate var keyPrefix: String { self == .warning ? "warning" : "alert" }
    /// Wristband modalities this phase can use; the beep is a warning-only chime.
    var modalities: [Modality] { self == .warning ? [.zap, .vibe, .beep] : [.zap, .vibe] }
    /// Levels the menu offers, and the level a modality comes back at when switched on.
    func choices(_ m: Modality) -> [Int] {
        switch (self, m) {
        case (.warning, .zap): return [0, 10, 15, 20, 25, 30]
        case (.warning, _): return [0, 20, 30, 50, 70]
        case (.hardStop, .zap): return [0, 15, 25, 35, 50, 70, 100]
        case (.hardStop, _): return [0, 30, 60, 80, 100]
        }
    }
    func defaultLevel(_ m: Modality) -> Int {
        switch (self, m) {
        case (.warning, .zap): return 15
        case (.warning, _): return 30
        case (.hardStop, .zap): return 35
        case (.hardStop, _): return 60
        }
    }
    /// Fixed vibration of the haptic_vibe arm, and the macOS sound of the caw_audio arm.
    var armVibe: Int { self == .warning ? 35 : 80 }
    var armSound: String { self == .warning ? "Frog" : "Sosumi" }
}

/// What one phase fires on the wristband in the pavlok_shock arm (0 = off).
struct CueLevels: Equatable {
    var zap: Int
    var vibe: Int
    var beep: Bool

    func level(_ m: Modality) -> Int {
        switch m {
        case .zap: return zap
        case .vibe: return vibe
        case .beep: return beep ? 1 : 0
        }
    }

    var active: Set<Modality> { Set(Modality.allCases.filter { level($0) > 0 }) }

    var summary: String {
        var parts: [String] = []
        if zap > 0 { parts.append("⚡ Shock \(zap)%") }
        if vibe > 0 { parts.append("📳 Vibe \(vibe)%") }
        if beep { parts.append("🔔 Beep") }
        return parts.isEmpty ? "⚪ 0% (Silent / Toast Only)" : parts.joined(separator: " + ")
    }
}

/// One-click cue combinations. The same table drives applying a preset and naming the
/// current settings, so the two cannot disagree.
struct CuePreset {
    let key: String
    let name: String
    let warning: Set<Modality>
    let hardStop: Set<Modality>

    func modalities(_ phase: CuePhase) -> Set<Modality> { phase == .warning ? warning : hardStop }

    static let all: [CuePreset] = [
        CuePreset(key: "both_shock", name: "Both Shock (Default)", warning: [.zap], hardStop: [.zap]),
        CuePreset(key: "vibe_shock", name: "Vibe (30s) + Shock (60s)", warning: [.vibe], hardStop: [.zap]),
        CuePreset(key: "shock_vibe", name: "Shock (30s) + Vibe (60s)", warning: [.zap], hardStop: [.vibe]),
        CuePreset(key: "both_vibe", name: "Both Vibration", warning: [.vibe], hardStop: [.vibe]),
        CuePreset(key: "both_dual", name: "Dual Shock + Vibe", warning: [.zap, .vibe], hardStop: [.zap, .vibe]),
        CuePreset(key: "all_zero", name: "All 0% (Silent)", warning: [], hardStop: []),
    ]
    static let customName = "Custom Multi-Select"
}

// MARK: - Experiment arms

/// The arms of the cluster-randomized trial: the only values written to
/// habit_events.treatment_arm.
enum TreatmentArm: String, CaseIterable, CustomStringConvertible {
    case baseline
    case cawAudio = "caw_audio"
    case pavlokShock = "pavlok_shock"
    case hapticVibe = "haptic_vibe"

    var description: String { rawValue }

    var displayName: String {
        switch self {
        case .baseline: return "🔵 Baseline Control (Silent / Observational)"
        case .cawAudio: return "🔔 Audio Chime (CAW Warning)"
        case .pavlokShock: return "⚡ Pavlok Physical Shock"
        case .hapticVibe: return "📳 Pavlok Haptic Vibration"
        }
    }

    var shortTag: String {
        switch self {
        case .baseline: return "Baseline"
        case .cawAudio: return "CAW Audio"
        case .pavlokShock: return "Pavlok Shock"
        case .hapticVibe: return "Haptic Vibe"
        }
    }

    /// The good-behaviour vibration is part of the wristband treatment. The baseline and
    /// audio arms never touch the wristband, so they never get it either.
    var rewardsConciseTurns: Bool { self == .pavlokShock || self == .hapticVibe }

    /// A session's arm under cluster randomization: SHA-256 of the session id, so the same
    /// session lands in the same arm in every process (String.hashValue is reseeded per
    /// launch, which moved sessions between arms across restarts).
    static func assigned(to sessionId: String) -> TreatmentArm {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let bytes = Array(sessionId.utf8)
        CC_SHA256(bytes, CC_LONG(bytes.count), &digest)
        let n = digest.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return allCases[Int(n % UInt64(allCases.count))]
    }
}

/// How sessions get their arm: randomized per session, or one arm fixed by hand.
enum AssignmentMode: String, CaseIterable {
    case clusterRandomized = "cluster_randomized"
    case baseline
    case cawAudio = "caw_audio"
    case pavlokShock = "pavlok_shock"
    case hapticVibe = "haptic_vibe"

    var fixedArm: TreatmentArm? { TreatmentArm(rawValue: rawValue) }
    var displayName: String { fixedArm?.displayName ?? "🎲 Randomized per Meeting (Cluster Trial)" }
    var shortTag: String { fixedArm?.shortTag ?? "Randomized" }
}

/// Resolves a session's arm from the assignment mode.
@MainActor
final class HabitExperimentManager {
    static let shared = HabitExperimentManager(settings: .shared)
    let settings: CoachSettings

    init(settings: CoachSettings) { self.settings = settings }

    var currentMode: AssignmentMode {
        get { settings.assignmentMode }
        set { settings.assignmentMode = newValue }
    }

    func resolveArm(for sessionId: String) -> TreatmentArm {
        currentMode.fixedArm ?? TreatmentArm.assigned(to: sessionId)
    }
}

// MARK: - Settings store

/// The coach's and the wristband's settings, in UserDefaults. Every change is logged and
/// announced to observers (the wristband reconnects, the tray redraws).
@MainActor
final class CoachSettings {
    static let shared = CoachSettings(defaults: .standard)

    enum Key: String, CaseIterable {
        case wearableEnabled = "pavlok_shock_enabled"
        case keepConnected = "pavlok_keep_connected"
        case apiToken = "pavlok_api_token"
        case rewardGoodBehavior = "pavlok_reward_good_behavior"
        case warningBeep = "pavlok_warning_beep_enabled"
        case alertOnlyDuringCalls = "coach_alert_only_during_calls"
        case assignmentMode = "habit_experiment_mode"
        case lastDeviceId = "pavlok_last_device_id"
        case session = "coach_session"
        case cueLevels = "cue_levels"
    }

    let defaults: UserDefaults
    private let log = Log("Coach")
    private var observers: [(Key) -> Void] = []

    /// The reward is a fixed, gentle vibration.
    let rewardVibe = 30

    init(defaults: UserDefaults) { self.defaults = defaults }

    /// Called on every change, with the key that changed.
    func observe(_ observer: @escaping (Key) -> Void) { observers.append(observer) }

    private func changed(_ key: Key, _ what: String, logger: Log? = nil) {
        (logger ?? log).info("setting: \(what)")
        observers.forEach { $0(key) }
    }

    private func bool(_ key: Key, default value: Bool) -> Bool {
        defaults.object(forKey: key.rawValue) == nil ? value : defaults.bool(forKey: key.rawValue)
    }

    private func setBool(_ key: Key, _ value: Bool, _ name: String, default d: Bool) {
        guard bool(key, default: d) != value else { return }
        defaults.set(value, forKey: key.rawValue)
        changed(key, "\(name) = \(value ? "on" : "off")")
    }

    // MARK: Switches

    /// Wristband stimuli on/off. Off by default: nothing touches Bluetooth until it is on.
    var wearableEnabled: Bool {
        get { bool(.wearableEnabled, default: false) }
        set { setBool(.wearableEnabled, newValue, "wristband feedback", default: false) }
    }

    /// Hold the Bluetooth link even while stimuli are off (for bench tests).
    var keepConnected: Bool {
        get { bool(.keepConnected, default: false) }
        set { setBool(.keepConnected, newValue, "keep Bluetooth connected", default: false) }
    }

    var rewardGoodBehavior: Bool {
        get { bool(.rewardGoodBehavior, default: true) }
        set { setBool(.rewardGoodBehavior, newValue, "good-behaviour reward", default: true) }
    }

    /// Cues only fire during a detected call.
    var alertOnlyDuringCalls: Bool {
        get { bool(.alertOnlyDuringCalls, default: true) }
        set { setBool(.alertOnlyDuringCalls, newValue, "alert only during calls", default: true) }
    }

    /// Pavlok cloud relay token (the fallback when Bluetooth is down).
    var apiToken: String {
        get { defaults.string(forKey: Key.apiToken.rawValue) ?? "" }
        set {
            guard newValue != apiToken else { return }
            defaults.set(newValue, forKey: Key.apiToken.rawValue)
            changed(.apiToken, "cloud token \(newValue.isEmpty ? "cleared" : "set")")
        }
    }

    var assignmentMode: AssignmentMode {
        get { defaults.string(forKey: Key.assignmentMode.rawValue).flatMap(AssignmentMode.init) ?? .clusterRandomized }
        set {
            guard newValue != assignmentMode else { return }
            defaults.set(newValue.rawValue, forKey: Key.assignmentMode.rawValue)
            changed(.assignmentMode, "assignment mode = \(newValue.rawValue)", logger: Log("Experiment"))
        }
    }

    /// The wristband last connected, tried first on the next connect.
    var lastDeviceId: UUID? {
        get { defaults.string(forKey: Key.lastDeviceId.rawValue).flatMap(UUID.init) }
        set { defaults.set(newValue?.uuidString, forKey: Key.lastDeviceId.rawValue) }
    }

    // MARK: Cue levels

    private func key(_ m: Modality, _ phase: CuePhase, saved: Bool = false) -> String {
        if m == .beep { return Key.warningBeep.rawValue }
        return "pavlok_\(saved ? "saved_" : "")\(phase.keyPrefix)_\(m == .zap ? "shock" : "vibe")_intensity"
    }

    func levels(_ phase: CuePhase) -> CueLevels {
        func active(_ m: Modality) -> Int {
            let k = key(m, phase)
            // Out of the box the shock is on at its default level and the vibration is off.
            if defaults.object(forKey: k) == nil { return m == .zap ? phase.defaultLevel(.zap) : 0 }
            return max(0, min(100, defaults.integer(forKey: k)))
        }
        return CueLevels(zap: active(.zap), vibe: active(.vibe),
                         beep: phase == .warning && defaults.bool(forKey: Key.warningBeep.rawValue))
    }

    /// The level a modality returns at when switched back on: the last non-zero one.
    func savedLevel(_ m: Modality, _ phase: CuePhase) -> Int {
        let v = defaults.integer(forKey: key(m, phase, saved: true))
        return v > 0 ? v : phase.defaultLevel(m)
    }

    /// Sets one modality of one phase (0 = off; the beep is on for any value > 0).
    func setLevel(_ m: Modality, _ value: Int, for phase: CuePhase) {
        guard phase.modalities.contains(m) else { return }
        let v = max(0, min(100, value))
        guard levels(phase).level(m) != (m == .beep ? min(v, 1) : v) else { return }
        if m == .beep {
            defaults.set(v > 0, forKey: key(m, phase))
        } else {
            defaults.set(v, forKey: key(m, phase))
            if v > 0 { defaults.set(v, forKey: key(m, phase, saved: true)) }
        }
        changed(.cueLevels, "\(phase.title) \(m.rawValue) = \(m == .beep ? (v > 0 ? "on" : "off") : "\(v)%")")
    }

    /// Switches a modality off, or back on at its saved level.
    func toggle(_ m: Modality, for phase: CuePhase) {
        let on = levels(phase).level(m) > 0
        setLevel(m, on ? 0 : (m == .beep ? 1 : savedLevel(m, phase)), for: phase)
    }

    func apply(_ preset: CuePreset) {
        log.info("setting: cue preset \(preset.key)")
        for phase in CuePhase.allCases {
            for m in phase.modalities {
                let on = preset.modalities(phase).contains(m)
                setLevel(m, on ? (m == .beep ? 1 : savedLevel(m, phase)) : 0, for: phase)
            }
        }
    }

    /// The preset the current levels match exactly, if any.
    var matchingPreset: CuePreset? {
        CuePreset.all.first { p in CuePhase.allCases.allSatisfy { levels($0).active == p.modalities($0) } }
    }

    var presetName: String { matchingPreset?.name ?? CuePreset.customName }

    // MARK: Bench test levels

    /// Level of a manual test fire. Separate from the cue levels, which are the trial's
    /// treatment; the zap starts low because the first thing anyone does is press it.
    func testLevel(_ m: Modality) -> Int {
        let k = "pavlok_test_\(m.rawValue)_intensity"
        if defaults.object(forKey: k) == nil { return m == .zap ? 10 : 40 }
        return max(0, min(100, defaults.integer(forKey: k)))
    }

    // MARK: Session

    /// The coaching session (one per call, one per stretch of solo speech) survives a
    /// restart, so a relaunch mid-meeting keeps the meeting's id and therefore its arm.
    struct Session: Equatable {
        var id: String
        var callApp: String?
        var callTitle: String?
    }

    var session: Session? {
        get {
            guard let d = defaults.dictionary(forKey: Key.session.rawValue), let id = d["id"] as? String else { return nil }
            return Session(id: id, callApp: d["app"] as? String, callTitle: d["title"] as? String)
        }
        set {
            guard let s = newValue else { defaults.removeObject(forKey: Key.session.rawValue); return }
            var d: [String: Any] = ["id": s.id]
            d["app"] = s.callApp
            d["title"] = s.callTitle
            defaults.set(d, forKey: Key.session.rawValue)
        }
    }
}
