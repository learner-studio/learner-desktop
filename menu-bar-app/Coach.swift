import AppKit
import Foundation

// The speaking coach, one workflow:
//   SpeechSource spans -> my turn's streak -> 30 s / 60 s thresholds -> the arm's stimulus
//   -> one habit_events row per turn (HabitEventLogger.logTurn).
// Everything runs on the main thread, ticked once a second by the app's Scheduler (which
// keeps running while a menu is open). Every turn, threshold, stimulus result, reward,
// call change and session change is logged under [Coach] / [Experiment].

// MARK: - Toast

/// The visual cue every arm gets, baseline included: the arms differ only in what they
/// add on top of it.
protocol CoachToast: AnyObject {
    func show(streak: TimeInterval, callApp: String?)
    func hide()
}

/// A floating panel that screen sharing and recording cannot see (sharingType = .none).
final class MonologueToastController: NSObject, CoachToast {
    static let shared = MonologueToastController()

    private var panel: NSPanel?
    private var frame: NSVisualEffectView?
    private let icon = NSTextField(labelWithString: "⚠️")
    private let title = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private(set) var isShowing = false
    private let size = NSSize(width: 340, height: 90)

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        // Hidden from ScreenCaptureKit, Zoom, Meet, Teams, Slack, OBS and QuickTime.
        p.sharingType = .none

        let ve = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        ve.material = .hudWindow
        ve.blendingMode = .behindWindow
        ve.state = .active
        ve.wantsLayer = true
        ve.layer?.cornerRadius = 18
        ve.layer?.masksToBounds = true
        ve.layer?.borderWidth = 1
        let w = size.width, h = size.height
        icon.frame = NSRect(x: 16, y: h - 54, width: 36, height: 36)
        icon.font = .systemFont(ofSize: 26)
        title.frame = NSRect(x: 58, y: h - 30, width: w - 96, height: 18)
        title.font = .boldSystemFont(ofSize: 13)
        title.textColor = .white
        time.frame = NSRect(x: 58, y: h - 50, width: w - 74, height: 16)
        time.font = .systemFont(ofSize: 12)
        time.textColor = NSColor(white: 0.95, alpha: 1)
        hint.frame = NSRect(x: 58, y: h - 72, width: w - 74, height: 16)
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = NSColor(white: 0.65, alpha: 1)
        let close = NSButton(frame: NSRect(x: w - 30, y: h - 28, width: 20, height: 20))
        close.title = "✕"
        close.isBordered = false
        close.bezelStyle = .inline
        close.font = .systemFont(ofSize: 11, weight: .bold)
        close.contentTintColor = NSColor(white: 0.75, alpha: 1)
        close.target = self
        close.action = #selector(hide)
        [icon, title, time, hint, close].forEach(ve.addSubview)
        p.contentView = ve
        frame = ve
        return p
    }

    func show(streak: TimeInterval, callApp: String?) {
        let p = panel ?? makePanel()
        panel = p
        let alert = streak >= CuePhase.hardStop.seconds
        let total = max(0, Int(streak))
        icon.stringValue = alert ? "🚨" : "⚠️"
        title.stringValue = "Speaking Coach \(alert ? "Alert" : "Warning")" + (callApp.map { " • \($0)" } ?? "")
        time.stringValue = String(format: "Speaking continuously for %d:%02d", total / 60, total % 60)
        hint.stringValue = "Hidden from screenshare • " + (alert ? "Invite others to speak" : "Consider wrapping up")
        frame?.layer?.borderColor = (alert ? NSColor(calibratedRed: 1, green: 0.25, blue: 0.25, alpha: 0.55)
                                           : NSColor(calibratedRed: 1, green: 0.75, blue: 0, alpha: 0.45)).cgColor
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        p.setFrameOrigin(NSPoint(x: max(20, vf.maxX - size.width - 24), y: max(20, vf.maxY - size.height - 24)))
        guard !isShowing else { return }
        isShowing = true
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; p.animator().alphaValue = 1 }
    }

    @objc func hide() {
        guard let p = panel, isShowing else { return }
        isShowing = false
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
    }
}

// MARK: - Treatment

/// What a threshold fires on top of the toast.
enum Stimulus: Equatable {
    case sound(String)
    case wearable(Modality, Int)

    /// habit_events metadata.treatment_settings.cue_30 / cue_60 part.
    var tag: String {
        switch self {
        case .sound(let name): return "macos_\(name)"
        case .wearable(.beep, _): return "beep"
        case .wearable(let m, let level): return "\(m.rawValue)_\(level)"
        }
    }
}

/// The treatment a turn was given: the arm and every configurable factor. Assignment and
/// configuration are distinct; these switches are not randomized.
struct TreatmentSettings: Equatable {
    let assignmentMode: AssignmentMode
    let arm: TreatmentArm
    let wearableEnabled: Bool
    let warning: CueLevels
    let hardStop: CueLevels
    let rewardSetting: Bool
    let rewardVibe: Int
    let onlyDuringCalls: Bool
    let cue30: String
    let cue60: String

    var rewardEnabled: Bool { rewardSetting && wearableEnabled && arm.rewardsConciseTurns }

    var dictionary: [String: Any] {
        ["assignment_mode": assignmentMode.rawValue, "arm": arm.rawValue, "wearable_enabled": wearableEnabled,
         "warning_shock_percent": warning.zap, "warning_vibe_percent": warning.vibe,
         "warning_beep_enabled": warning.beep,
         "hard_stop_shock_percent": hardStop.zap, "hard_stop_vibe_percent": hardStop.vibe,
         "reward_enabled": rewardEnabled, "reward_setting_enabled": rewardSetting,
         "reward_in_arm": arm.rewardsConciseTurns, "reward_vibe_percent": rewardVibe,
         "reward_min_sec": SpeakingCoach.rewardMinSec, "reward_max_exclusive_sec": CuePhase.warning.seconds,
         "warning_sec": CuePhase.warning.seconds, "hard_stop_sec": CuePhase.hardStop.seconds,
         "only_during_calls": onlyDuringCalls, "cue_30": cue30, "cue_60": cue60]
    }
}

// MARK: - Coach

/// Tray.swift still names the coach TalkTimeMonitor.
typealias TalkTimeMonitor = SpeakingCoach

final class SpeakingCoach {
    static let shared: SpeakingCoach = {
        let api = ScreenpipeAPI.shared
        return SpeakingCoach(settings: .shared, speech: ScreenpipeSpeechSource(api: api),
                             calls: ScreenpipeCallSource(api: api), wearable: PavlokController.shared,
                             toast: MonologueToastController.shared, logger: .shared)
    }()

    /// A turn shorter than this is a grunt, not a yield.
    static let rewardMinSec: TimeInterval = 5
    /// Turns shorter than this are not written.
    static let minTurnSec: TimeInterval = 2
    /// Longest pause inside one turn (a 10 s chunk plus Whisper's margin).
    static let silenceTimeout: TimeInterval = 14
    /// Above this arrival lag the turn's timing is marked suspect.
    static let maxTrustedIngestLagSec: TimeInterval = 10
    /// A failing call poll ends the call only after this long without an answer.
    var callOutageGrace: TimeInterval = 120
    /// A turn's row waits at most this long for its stimulus and reward results.
    var resultTimeout: TimeInterval = 10

    let settings: CoachSettings
    let experiment: HabitExperimentManager
    let speech: SpeechSource
    let calls: CallSource
    let wearable: Wearable
    let toast: CoachToast
    let logger: HabitEventLogger
    let clock: () -> Date
    /// Plays a named macOS sound (falling back to the system beep); true if the named one played.
    let playSound: (String) -> Bool
    private let log = Log("Coach")
    private let experimentLog = Log("Experiment")

    /// The tray redraws on this.
    var onStreakUpdated: ((TimeInterval) -> Void)?

    // Session and call
    private(set) var activeSessionId: String
    private(set) var call: CallState?
    private var lastCallAnswer: Date
    var activeCallApp: String? { call?.app }
    var activeCallTitle: String? { call?.title }
    var arm: TreatmentArm { experiment.resolveArm(for: activeSessionId) }

    // The turn in progress (mine), and what it left behind
    private var turn: Turn?
    private var turnCount = 0
    private(set) var currentStreak: TimeInterval = 0
    /// Rows from before the last turn boundary are late arrivals from the previous floor
    /// holder; they must not reopen an ended turn.
    private var lastTurnBoundaryAt: Date?
    /// A transcription cannot arrive before its chunk closes, so silence is only real once
    /// the delivery lag has been waited out as well.
    private var lastObservedLag: TimeInterval = 0
    private var started = false

    init(settings: CoachSettings, experiment: HabitExperimentManager? = nil, speech: SpeechSource,
         calls: CallSource, wearable: Wearable, toast: CoachToast, logger: HabitEventLogger,
         clock: @escaping () -> Date = Date.init,
         playSound: @escaping (String) -> Bool = { name in
             let played = NSSound(named: name)?.play() ?? false
             if !played { NSSound.beep() }
             return played
         }) {
        self.settings = settings
        self.experiment = experiment ?? HabitExperimentManager(settings: settings)
        self.speech = speech
        self.calls = calls
        self.wearable = wearable
        self.toast = toast
        self.logger = logger
        self.clock = clock
        self.playSound = playSound
        lastCallAnswer = clock()
        if let saved = settings.session {
            activeSessionId = saved.id
            call = saved.callApp.map { CallState(app: $0, title: saved.callTitle) }
        } else {
            activeSessionId = SpeakingCoach.newSessionId(for: nil)
            settings.session = CoachSettings.Session(id: activeSessionId)
        }
    }

    /// Ticks the coach once a second on the app's clock. Call once, at launch.
    func start() {
        guard !started else { return }
        started = true
        Scheduler.every(1, "coach") { [weak self] in self?.tick() }
        log.info("started: session \(activeSessionId)\(call.map { " (call: \($0.app))" } ?? ""), arm \(arm), assignment \(experiment.currentMode.rawValue), alert only during calls: \(settings.alertOnlyDuringCalls)")
    }

    // MARK: Status

    var alertOnlyDuringCalls: Bool {
        get { settings.alertOnlyDuringCalls }
        set { settings.alertOnlyDuringCalls = newValue }
    }

    /// Cues may fire now: during a call, or anywhere when "alert only during calls" is off.
    var canAlert: Bool { !settings.alertOnlyDuringCalls || call != nil }
    var isWarningActive: Bool { canAlert && currentStreak >= CuePhase.warning.seconds && currentStreak < CuePhase.hardStop.seconds }
    var isAlertActive: Bool { canAlert && currentStreak >= CuePhase.hardStop.seconds }
    var formattedDuration: String {
        let total = max(0, Int(currentStreak))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: The loop

    func tick() {
        speech.poll(now: clock()) { [weak self] spans in
            guard let self = self, !spans.isEmpty else { return }
            spans.forEach(self.hear)
            self.evaluate()
        }
        calls.poll { [weak self] in self?.callPolled($0) }
        evaluate()
    }

    /// One stretch of speech from the source.
    func hear(_ span: SpeechSpan) {
        let now = clock()
        if let boundary = lastTurnBoundaryAt, span.start <= boundary { return }
        guard span.speaker == .me else {
            // A handoff ends my turn at my last confirmed word, or earlier if we overlapped;
            // the wait before the reply is not part of it.
            if turn != nil { endTurn(at: span.start, why: "someone else spoke", natural: true) }
            lastTurnBoundaryAt = max(lastTurnBoundaryAt ?? span.start, span.start)
            return
        }
        // Breathing pauses stay inside a turn; a long gap starts a new one.
        if let t = turn, span.start.timeIntervalSince(t.lastEnd) > SpeakingCoach.silenceTimeout {
            endTurn(at: nil, why: "gap of \(Int(span.start.timeIntervalSince(t.lastEnd))) s", natural: true)
        }
        let t: Turn
        if let current = turn {
            t = current
        } else {
            turnCount += 1
            t = Turn(number: turnCount, start: span.start, settings: treatmentSettings())
            turn = t
            log.info("turn \(t.number) started (\(span.path))")
        }
        t.alertable = t.alertable || canAlert
        t.paths.insert(span.path)
        t.audioClock = t.audioClock && span.audioClock
        t.words += span.words
        t.lastHeard = now
        t.lastEnd = max(t.lastEnd, span.end)
        currentStreak = max(0, t.lastEnd.timeIntervalSince(t.start))
        let lag = max(0, now.timeIntervalSince(span.capturedAt))
        lastObservedLag = lag
        t.maxLag = max(t.maxLag, lag)
        if lag > SpeakingCoach.maxTrustedIngestLagSec {
            log.warn("ingest lag \(String(format: "%.1f", lag)) s on \(span.label); turn \(t.number) timing marked suspect")
        }
        log.info("heard \(span.label): turn \(t.number) at \(String(format: "%.1f", currentStreak)) s")
    }

    /// Silence, the toast and the thresholds, against the current streak.
    func evaluate() {
        let now = clock()
        if let t = turn {
            if t.settings != treatmentSettings() { t.settingsChanged = true }
            let quiet = now.timeIntervalSince(t.lastHeard)
            if quiet > SpeakingCoach.silenceTimeout + lastObservedLag {
                endTurn(at: nil, why: "silent for \(Int(quiet)) s", natural: true)
            }
        }
        if let t = turn, canAlert, currentStreak >= CuePhase.warning.seconds {
            if !t.toastShown {
                t.toastShown = true
                record(t, .warning, modality: "toast", streak: currentStreak, delivered: true, transport: .screen, detail: "visual panel shown")
            }
            toast.show(streak: currentStreak, callApp: activeCallApp)
            for phase in CuePhase.allCases where currentStreak >= phase.seconds && t.fired[phase] == nil {
                fire(phase, t)
            }
        } else {
            toast.hide()
        }
        onStreakUpdated?(currentStreak)
    }

    // MARK: Stimuli

    /// What `arm` fires at `phase`, on top of the toast.
    func stimuli(_ arm: TreatmentArm, _ phase: CuePhase) -> [Stimulus] {
        switch arm {
        case .baseline: return []
        case .cawAudio: return [.sound(phase.armSound)]
        case .hapticVibe: return wearable.isEnabled ? [.wearable(.vibe, phase.armVibe)] : []
        case .pavlokShock:
            guard wearable.isEnabled else { return [] }
            let levels = settings.levels(phase)
            return phase.modalities.filter { levels.level($0) > 0 }.map { .wearable($0, levels.level($0)) }
        }
    }

    func treatmentSettings() -> TreatmentSettings {
        let arm = self.arm
        func cue(_ phase: CuePhase) -> String {
            let s = stimuli(arm, phase)
            return s.isEmpty ? "toast_only" : (["toast"] + s.map(\.tag)).joined(separator: "+")
        }
        return TreatmentSettings(assignmentMode: experiment.currentMode, arm: arm, wearableEnabled: wearable.isEnabled,
                                 warning: settings.levels(.warning), hardStop: settings.levels(.hardStop),
                                 rewardSetting: settings.rewardGoodBehavior, rewardVibe: settings.rewardVibe,
                                 onlyDuringCalls: settings.alertOnlyDuringCalls, cue30: cue(.warning), cue60: cue(.hardStop))
    }

    private func context() -> StimulusContext {
        StimulusContext(sessionId: activeSessionId, arm: arm.rawValue, callApp: activeCallApp, manual: false)
    }

    private func fire(_ phase: CuePhase, _ t: Turn) {
        let streak = currentStreak
        let arm = self.arm
        t.fired[phase] = (clock(), streak)
        let plan = stimuli(arm, phase)
        log.info("turn \(t.number): \(phase.title) at \(String(format: "%.1f", streak)) s, arm \(arm): \(plan.isEmpty ? "toast only" : plan.map(\.tag).joined(separator: " + "))")
        if plan.isEmpty {
            record(t, phase, modality: "none", streak: streak, delivered: nil, transport: .none,
                   detail: arm == .baseline ? "control arm: no stimulus by design"
                         : wearable.isEnabled ? "no wristband cue configured for this phase" : "wristband feedback is off")
        }
        for stimulus in plan {
            switch stimulus {
            case .sound(let name):
                let played = playSound(name)
                record(t, phase, modality: played ? "caw_audio" : "system_beep_fallback", streak: streak, delivered: true,
                       transport: .sound, detail: played ? name : "named sound unavailable, fell back to NSSound.beep()")
            case .wearable(let m, let level):
                t.pending += 1
                wearable.send(m, intensity: level, reason: "\(phase.title) after \(Int(streak)) s of monologue", context: context()) { [weak self] r in
                    self?.record(t, phase, modality: "pavlok_\(m.rawValue)", streak: streak, delivered: r.delivered,
                                 transport: r.transport, detail: r.detail, intensity: level)
                    t.pending -= 1
                    self?.write(t)
                }
            }
        }
    }

    /// The one audit path for everything a turn fired: one entry per modality, with what
    /// the device or the Mac reported back.
    private func record(_ t: Turn, _ phase: CuePhase, modality: String, streak: TimeInterval, delivered: Bool?,
                        transport: Transport, detail: String, intensity: Int? = nil) {
        var entry: [String: Any] = [
            "modality": modality, "arm": arm.rawValue, "threshold": phase.threshold,
            "streak_sec_at_fire": streak, "fired_at": ISO8601DateFormatter().string(from: clock()),
            "delivered": delivered as Any? ?? NSNull(), "transport": transport.rawValue, "detail": detail]
        entry["intensity_percent"] = intensity
        t.interventions.append(entry)
        if delivered == false { log.warn("turn \(t.number): \(modality) not delivered: \(detail)") }
    }

    // MARK: Ending a turn

    /// Ends the turn by hand (menu) or at quit: no reward, and the row is written at once.
    func resetStreak() {
        endTurn(at: nil, why: "ended by hand or at quit", natural: false)
    }

    private func endTurn(at requested: Date?, why: String, natural: Bool) {
        guard let t = turn else { return }
        let endedAt = requested.map { min($0, t.lastEnd) } ?? t.lastEnd
        let streak = max(0, endedAt.timeIntervalSince(t.start))
        lastTurnBoundaryAt = max(lastTurnBoundaryAt ?? endedAt, requested ?? t.lastEnd)
        turn = nil
        currentStreak = 0
        toast.hide()
        onStreakUpdated?(0)
        if t.settings != treatmentSettings() { t.settingsChanged = true }

        let arm = self.arm
        let eligible = streak >= SpeakingCoach.rewardMinSec && streak < CuePhase.warning.seconds && t.fired[.hardStop] == nil
        let requestReward = eligible && natural && t.alertable && treatmentSettings().rewardEnabled
        t.finished = Turn.Finished(endedAt: endedAt, streak: streak, why: why, sessionId: activeSessionId, arm: arm,
                                   callApp: activeCallApp, callTitle: activeCallTitle,
                                   rewardEligible: eligible, rewardRequested: requestReward)
        log.info("turn \(t.number) ended (\(why)): \(String(format: "%.1f", streak)) s, \(t.words) words, arm \(arm)")
        if requestReward {
            t.pending += 1
            wearable.send(.vibe, intensity: settings.rewardVibe,
                          reason: "Good behavior reward: concise turn (\(Int(streak)) s) yielded cleanly", context: context()) { [weak self] r in
                t.reward = r
                self?.log.info("turn \(t.number): reward vibration \(r.delivered ? "delivered" : "NOT delivered") via \(r.transport.rawValue): \(r.detail)")
                t.pending -= 1
                self?.write(t)
            }
        } else if eligible {
            log.info("turn \(t.number): concise turn, no reward (\(natural ? "arm \(arm) or settings give none" : why))")
        }
        write(t, force: !natural)
        if !t.written {
            DispatchQueue.main.asyncAfter(deadline: .now() + resultTimeout) { [weak self] in
                guard let self = self, !t.written else { return }
                self.log.warn("turn \(t.number): \(t.pending) stimulus result(s) never came; writing the row without them")
                self.write(t, force: true)
            }
        }
    }

    /// Writes the turn's row once it has ended and every result is in (or `force`).
    private func write(_ t: Turn, force: Bool = false) {
        guard let f = t.finished, !t.written, force || t.pending == 0 else { return }
        t.written = true
        guard f.streak >= SpeakingCoach.minTurnSec else { return }
        // Seconds from the warning firing to the speaker yielding: the primary outcome.
        let latency = t.fired[.warning].flatMap { fired -> Double? in
            let s = f.endedAt.timeIntervalSince(fired.at)
            return s > 0 ? s : nil
        }
        let live = t.paths.contains("live_meeting")
        let path = live ? "live_meeting" : t.paths.sorted().first ?? "background"
        logger.logTurn(
            occurredAt: t.start, sessionId: f.sessionId, callApp: f.callApp,
            callCategory: f.callApp != nil ? "work" : "solo", treatmentArm: f.arm.rawValue,
            turnDurationSec: f.streak, wordsSpoken: t.words,
            // The streak when each cue actually fired, not the threshold constant.
            warningFiredAt: t.fired[.warning]?.streak, shockFiredAt: t.fired[.hardStop]?.streak,
            latencyToYieldSec: latency,
            breached30s: f.streak > CuePhase.warning.seconds, breached60s: f.streak > CuePhase.hardStop.seconds,
            wasRewarded: t.reward?.delivered ?? false,
            metadata: [
                // GrowthBook's exposure query filters on simulated = false and this design version.
                "simulated": false,
                "source": HabitEventLogger.liveSource,
                "measurement": "turn_gap",
                "timing_version": "confirmed_speech_span_v1",
                "design_version": "speech_coach_settings_v1",
                "treatment_settings": t.settings.dictionary,
                "settings_changed_during_turn": t.settingsChanged,
                "reward_eligible": f.rewardEligible,
                "reward_requested": f.rewardRequested,
                "reward_result": t.reward.map { ["delivered": $0.delivered, "transport": $0.transport.rawValue, "detail": $0.detail] as Any } ?? NSNull(),
                "yield_latency_observed": latency != nil,
                "end_reason": f.why,
                "duration_basis": "first_to_last_confirmed_speech",
                "live_timestamp_precision": live ? "segment_start" : "segment_end",
                "turn_clock": t.audioClock ? "audio" : "arrival",
                "call_title": f.callTitle ?? "",
                "gap_duration_sec": f.streak,
                // Per modality, including failures: a failed dispatch is not a delivered cue.
                "interventions": t.interventions,
                "intervention_confirmed": t.interventions.contains { $0["delivered"] as? Bool == true },
                // False: no cue could fire in this turn, so it is not an experimental unit.
                "experiment_eligible": t.alertable,
                "transcription_path": path,
                "screenpipe_version": CaptureEnvironment.screenpipeVersion as Any? ?? NSNull(),
                "screenpipe_app_version": CaptureEnvironment.screenpipeAppVersion as Any? ?? NSNull(),
                // A new screenpipe version is a new experiment phase; never pool across them.
                "capture_phase": CaptureEnvironment.capturePhase as Any? ?? NSNull(),
                "ingest_lag_sec_max": t.maxLag,
                "data_quality": t.maxLag > SpeakingCoach.maxTrustedIngestLagSec ? "suspect_ingest_lag" : "ok",
                "toast_shown": t.toastShown,
            ])
    }

    // MARK: Calls and sessions

    private func callPolled(_ poll: CallPoll) {
        let now = clock()
        switch poll {
        case .answered(let state):
            lastCallAnswer = now
            setCall(state)
        case .failed(let why):
            // A timeout or a screenpipe restart must not split one meeting into two sessions.
            guard call != nil, now.timeIntervalSince(lastCallAnswer) >= callOutageGrace else { return }
            log.warn("no answer about the call for \(Int(now.timeIntervalSince(lastCallAnswer))) s (\(why)); treating it as over")
            setCall(nil)
        }
    }

    private func setCall(_ state: CallState?) {
        guard state != call else { return }
        if state?.app != call?.app {
            activeSessionId = SpeakingCoach.newSessionId(for: state?.app)
            if let s = state {
                log.info("call started: \(s.app)\(s.title.map { " (\($0))" } ?? "")")
            } else {
                log.info("call ended (\(call?.app ?? "?"))")
            }
            experimentLog.info("session \(activeSessionId): arm \(arm) (\(experiment.currentMode.rawValue))")
        }
        call = state
        settings.session = CoachSettings.Session(id: activeSessionId, callApp: state?.app, callTitle: state?.title)
    }

    static func newSessionId(for app: String?) -> String {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return app.map { "call_\($0.lowercased().replacingOccurrences(of: " ", with: "_"))_\(suffix)" } ?? "solo_\(suffix)"
    }

    // MARK: Turn record

    /// One turn of mine: live counters while it runs, then the results that complete its
    /// row (stimulus acknowledgements and the reward can arrive after it ended).
    private final class Turn {
        struct Finished {
            let endedAt: Date
            let streak: TimeInterval
            let why: String
            let sessionId: String
            let arm: TreatmentArm
            let callApp: String?
            let callTitle: String?
            let rewardEligible: Bool
            let rewardRequested: Bool
        }

        let number: Int
        let start: Date
        let settings: TreatmentSettings
        var lastEnd: Date
        var lastHeard = Date.distantPast
        var words = 0
        var paths = Set<String>()
        var audioClock = true
        var maxLag: TimeInterval = 0
        var alertable = false
        var settingsChanged = false
        var toastShown = false
        var fired: [CuePhase: (at: Date, streak: TimeInterval)] = [:]
        var interventions: [[String: Any]] = []
        var pending = 0
        var reward: StimulusResult?
        var finished: Finished?
        var written = false

        init(number: Int, start: Date, settings: TreatmentSettings) {
            self.number = number
            self.start = start
            self.lastEnd = start
            self.settings = settings
        }
    }
}
