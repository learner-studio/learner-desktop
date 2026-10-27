import AppKit
import Foundation
import ServiceManagement
import SQLite3
import CoreBluetooth
import CommonCrypto

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
    /// Last /meetings poll that answered; a failed poll says nothing about the call.
    private var lastCallPollOK = Date()
    static let callPollOutageEndsCall: TimeInterval = 120
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
        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self = self else { return }
            var newApp: String?
            var newTitle: String?
            if let data = data, (response as? HTTPURLResponse)?.statusCode == 200,
               let meetings = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                self.lastCallPollOK = Date()
                if let active = meetings.first(where: { ($0["meeting_end"] as? String) == nil }) {
                    newApp = active["meeting_app"] as? String
                    newTitle = active["title"] as? String
                }
            } else if Date().timeIntervalSince(self.lastCallPollOK) < TalkTimeMonitor.callPollOutageEndsCall {
                // A timeout or screenpipe restart: keep the call as it is rather than splitting it.
                return
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
