import AppKit
import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// Voice ID's logic on synthetic vectors and frames, no model and no microphone: the window
// and hop, smoothing, cosine scoring, enrollment cuts, the voiceprint file, the engine's
// queueing (drop, never queue), what the pill says, and the pill itself. Real embeddings on
// synthesized speech are in MediumTests/VoiceIDModelTests.
@Suite("Voice ID (logic)", .tags(.light, .voiceID), .timeLimit(.minutes(1)), .quietLog)
struct VoiceIDTests {
    static let frame = SileroVAD.frame

    /// `seconds` of 512-sample frames whose samples all equal `value` (the fake embedder's
    /// speaker), each with speech probability `p`.
    static func frames(_ seconds: Double, value: Float, p: Float) -> [SileroVAD.Frame] {
        (0..<Int(seconds * 16_000) / frame).map { _ in SileroVAD.Frame(samples: [Float](repeating: value, count: frame), probability: p) }
    }

    /// Positive samples are "the owner" ([1, 0]), negative ones someone else ([0, 1]). It can
    /// hold each call until released, to show windows are dropped meanwhile.
    final class FakeEmbedder: SpeakerEmbedder, @unchecked Sendable {
        let gate: DispatchSemaphore?
        let calls = Locked(0)
        init(gate: DispatchSemaphore? = nil) { self.gate = gate }
        func embed(_ samples: [Float]) -> [Float] {
            calls.withLock { $0 += 1 }
            gate?.wait()
            let mean = samples.reduce(0, +) / Float(max(1, samples.count))
            return mean > 0 ? [1, 0] : [0, 1]
        }
    }

    // MARK: Pure parts

    @Test func cosineScoresAndNormalizes() {
        #expect(VoiceMath.cosine([1, 0], [1, 0]) == 1)
        #expect(VoiceMath.cosine([1, 0], [0, 1]) == 0)
        #expect(abs(VoiceMath.cosine([1, 1], [2, 2]) - 1) < 1e-6, "scale does not matter")
        #expect(abs(VoiceMath.cosine([1, 0], [-1, 0]) + 1) < 1e-6)
        #expect(VoiceMath.cosine([], []) == 0)
        #expect(VoiceMath.cosine([1, 0], [1, 0, 0]) == 0, "mismatched lengths score 0, not crash")
        #expect(VoiceMath.cosine([0, 0], [1, 0]) == 0)
        let n = VoiceMath.normalized([3, 4])
        #expect(abs(n[0] - 0.6) < 1e-6 && abs(n[1] - 0.8) < 1e-6)
        #expect(VoiceMath.mean([[1, 2], [3, 4]]) == [2, 3])
    }

    @Test func theWindowIsOneAndAHalfSecondsEveryHalfSecond() {
        var w = SlidingWindow()
        #expect(w.size == 24_000 && w.hop == 8_000)
        var emitted: [(at: Int, window: SlidingWindow.Window)] = []
        // 5 s of frames: speech for the first 2 s, then silence.
        for i in 0..<(5 * 16_000 / Self.frame) {
            let speech = i * Self.frame < 2 * 16_000
            if let out = w.add([Float](repeating: speech ? 1 : 0, count: Self.frame), speech: speech) {
                emitted.append(((i + 1) * Self.frame, out))
            }
        }
        // The first once 1.5 s is in, then every 0.5 s (to within a frame).
        let first = try! #require(emitted.first)
        #expect(first.at >= 24_000 && first.at < 24_000 + Self.frame)
        for (a, b) in zip(emitted, emitted.dropFirst()) {
            #expect(abs(b.at - a.at - 8_000) <= Self.frame, "hop \(b.at - a.at)")
        }
        #expect(emitted.count == 7, "\(emitted.count) windows in 5 s")
        #expect(emitted.allSatisfy { $0.window.samples.count == 24_000 })
        // Speech share follows what Silero said about the frames in the window.
        #expect(first.window.speechFraction == 1 && first.window.isSpeech)
        let last = try! #require(emitted.last)
        #expect(last.window.speechFraction == 0 && !last.window.isSpeech)
        let mixed = emitted.first { $0.window.speechFraction > 0 && $0.window.speechFraction < 1 }
        #expect(mixed != nil, "a window straddling speech and silence has a partial share")
        w.reset()
        #expect(w.samples.isEmpty)
    }

    @Test func smoothingDecidesOnTwoWindowsAndSilenceStartsAgain() {
        var s = VoiceSmoother(threshold: 0.6, count: 2)
        func near(_ d: VoiceDecision, _ want: VoiceDecision) -> Bool {
            switch (d, want) {
            case (.me(let a), .me(let b)), (.notMe(let a), .notMe(let b)): return abs(a - b) < 1e-5
            default: return d == want
            }
        }
        #expect(near(s.add(0.8), .me(0.8)))
        // One low window after a high one: the mean (0.55) is below the threshold.
        #expect(near(s.add(0.3), .notMe(0.55)))
        // Only the last two count: 0.3 and 0.95.
        #expect(near(s.add(0.95), .me(0.625)))
        #expect(s.scores.count == 2)
        #expect(s.silence() == .silence)
        #expect(s.scores.isEmpty)
        // After silence, the first window stands on its own.
        #expect(near(s.add(0.4), .notMe(0.4)))
        #expect(VoiceID.threshold == 0.6 && VoiceID.smoothingWindows == 2)
    }

    @Test func enrollmentCutsSpeechIntoFiveToTenSecondSegments() {
        let sixty = [Float](repeating: 0.1, count: 60 * 16_000)
        let cut = EnrollmentCut.segments(sixty)
        #expect(cut.count == 10)
        #expect(cut.allSatisfy { $0.count == 6 * 16_000 })
        // A tail of 5 s or more is one more segment; a shorter one is left out.
        #expect(EnrollmentCut.segments([Float](repeating: 0, count: 17 * 16_000)).map(\.count) == [96_000, 96_000, 80_000])
        #expect(EnrollmentCut.segments([Float](repeating: 0, count: 16 * 16_000)).count == 2)
        #expect(EnrollmentCut.segments([Float](repeating: 0, count: 4 * 16_000)).isEmpty)
        #expect(VoiceID.segmentSeconds >= 5 && VoiceID.segmentSeconds <= 10)
        // Each segment is embedded at the live window's length: its 1.5 s windows, 0.5 s apart.
        var lengths: [Int] = []
        let e = EnrollmentCut.embedding(of: cut[0]) { lengths.append($0.count); return [3, 4] }
        #expect(lengths.count == 10 && lengths.allSatisfy { $0 == 24_000 }, "\(lengths)")
        #expect(abs(e[0] - 0.6) < 1e-6 && abs(e[1] - 0.8) < 1e-6)
    }

    @Test func theVoiceprintIsTheNormalizedMeanOfNormalizedEmbeddings() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let print = try #require(EnrollmentCut.voiceprint([[2, 0], [0, 1], [], [3, 0]], model: "m.onnx", speechSeconds: 18, at: at))
        // [1,0],[0,1],[1,0] -> mean [2/3, 1/3] -> normalized.
        let n = VoiceMath.normalized([2, 1])
        #expect(abs(print.vector[0] - n[0]) < 1e-6 && abs(print.vector[1] - n[1]) < 1e-6)
        #expect(print.segments == 3, "the empty embedding is skipped")
        #expect(print.model == "m.onnx" && print.enrolledAt == at)
        #expect(print.calibration.contains("3 segments") && print.calibration.contains("threshold 0.60"), "\(print.calibration)")
        #expect(EnrollmentCut.voiceprint([[], []], model: "m", speechSeconds: 0, at: at) == nil)
    }

    @Test func theVoiceprintSavesAndLoadsAndRefusesAnotherModel() throws {
        let dir = TempDir("voiceprint")
        let url = URL(fileURLWithPath: dir.file("voice-id/voiceprint.json"))
        let print = Voiceprint(vector: [0.6, 0.8], model: VoiceID.modelFile, enrolledAt: Date(timeIntervalSince1970: 1_800_000_000),
                               segments: 10, speechSeconds: 60, calibration: "note")
        try print.save(url)
        #expect(Voiceprint.load(url) == print)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(Voiceprint.load(url, model: "other.onnx") == nil, "a print from another model does not count")
        try "{not json".write(to: url, atomically: true, encoding: .utf8)
        #expect(Voiceprint.load(url) == nil)
        #expect(Voiceprint.load(URL(fileURLWithPath: dir.file("missing.json"))) == nil)
        // Never in the repo: under Application Support (a scratch folder in tests).
        #expect(VoiceID.voiceprintURL.path.hasPrefix(Paths.appSupport))
        #expect(!VoiceID.voiceprintURL.path.contains("learner-desktop/"))
    }

    @Test func theIndicatorSaysWhatIsHappening() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func state(_ d: VoiceDecision?, at: Date? = now, last: Float? = nil, model: Bool = true, enrolled: Bool = true, mic: Bool = true) -> VoiceIndicatorState {
            var o = VoiceIDEngine.Output()
            o.decision = d
            o.decidedAt = d == nil ? nil : at
            o.lastScore = last
            return .from(modelPresent: model, enrolled: enrolled, micListening: mic, output: o, now: now)
        }
        #expect(state(.me(0.78)).text == "🎙 You're talking · 0.78")
        #expect(state(.me(0.78)).talking)
        #expect(state(.notMe(0.31)).text == "Not you · 0.31")
        #expect(!state(.notMe(0.31)).talking)
        #expect(state(.silence, last: 0.42).text == "Silence · 0.42")
        #expect(state(nil).text == "Silence")
        // A decision older than 2 s (no frames since) is silence.
        #expect(state(.me(0.9), at: now.addingTimeInterval(-3), last: 0.9) == .silence(0.9))
        #expect(state(.me(0.9), mic: false) == .micOff)
        #expect(state(.me(0.9), enrolled: false) == .notEnrolled)
        #expect(state(.me(0.9), model: false) == .modelMissing)
        #expect(VoiceIndicatorState.micOff.text == "Mic paused")
    }

    // MARK: The engine, with a fake model

    @Test func enrollmentTakesOnlySpeechAndMakesAVoiceprint() throws {
        let saved = Locked<Voiceprint?>(nil)
        let engine = VoiceIDEngine(modelName: "fake.onnx", makeEmbedder: { FakeEmbedder() }, save: { p in saved.withLock { $0 = p } })
        engine.startEnrollment(seconds: 12)
        #expect(engine.enrolling)
        // 12 s of the owner's speech with 10 s of silence (someone else's) mixed in: only speech counts.
        for _ in 0..<6 {
            engine.frames(Self.frames(2, value: 0.1, p: 0.9))
            engine.frames(Self.frames(2, value: -0.1, p: 0.1))
        }
        let progress = engine.output.value.enrollProgress ?? 0
        #expect(progress > 0.9, "progress \(progress)")
        engine.frames(Self.frames(0.5, value: 0.1, p: 0.9))
        #expect(!engine.enrolling)
        engine.drain()
        let result = try #require(engine.output.value.enrollResult)
        guard case .done(let print) = result else { Issue.record("enrollment failed: \(result)"); return }
        #expect(print.segments == 2, "12 s of speech in 6 s segments")
        #expect(print.vector == [1, 0])
        #expect(saved.value == print)
    }

    /// Cancel means nothing is saved: before the voiceprint step, and while it is being made
    /// (the model held mid-way). A new round after a cancel still saves.
    @Test func aCancelledEnrollmentNeverSaves() throws {
        let saved = Locked(0)
        let gate = DispatchSemaphore(value: 0)
        let fake = FakeEmbedder(gate: gate)
        let engine = VoiceIDEngine(modelName: "fake.onnx", makeEmbedder: { fake }, save: { _ in saved.withLock { $0 += 1 } })
        // Cancelled while it is being made: the model is mid-way when the owner cancels.
        engine.startEnrollment(seconds: 6)
        engine.frames(Self.frames(6.5, value: 0.1, p: 0.9))
        #expect(!engine.enrolling)
        #expect(waitFor(5) { fake.calls.value > 0 }, "the voiceprint is being made")
        #expect(engine.enrollmentUnderway, "still underway while it is made")
        engine.cancelEnrollment()
        for _ in 0..<64 { gate.signal() }
        engine.drain()
        #expect(saved.value == 0, "a voiceprint made after the cancel is not saved")
        #expect(engine.output.value.enrollResult == nil)
        #expect(!engine.enrollmentUnderway)
        // A fresh round after it saves as usual.
        engine.startEnrollment(seconds: 6)
        engine.frames(Self.frames(6.5, value: 0.1, p: 0.9))
        for _ in 0..<64 { gate.signal() }
        engine.drain()
        #expect(saved.value == 1)
    }

    @Test func liveWindowsAreScoredSmoothedAndSilenceIsSilence() throws {
        let engine = VoiceIDEngine(modelName: "fake.onnx", makeEmbedder: { FakeEmbedder() }, save: { _ in })
        engine.use(Voiceprint(vector: [1, 0], model: "fake.onnx", enrolledAt: Date(), segments: 1, speechSeconds: 6, calibration: ""))
        engine.setLive(true)
        func last(_ batch: [SileroVAD.Frame]) -> VoiceDecision? {
            for f in batch { engine.frames([f]); engine.drain() }
            return engine.output.value.decision
        }
        #expect(last(Self.frames(2, value: 0.1, p: 0.9)) == .me(1))
        // Someone else: the first window averages with the owner's (0.5), still not "me".
        #expect(last(Self.frames(2, value: -0.1, p: 0.9)) == .notMe(0))
        #expect(last(Self.frames(2, value: 0.1, p: 0.1)) == .silence)
        #expect(engine.output.value.scored > 0)
        // Not live: frames are ignored.
        engine.setLive(false)
        #expect(last(Self.frames(2, value: 0.1, p: 0.9)) == nil)
    }

    /// The model queue may be slow; the VAD queue must not wait for it. Windows that arrive
    /// meanwhile are dropped, not queued.
    @Test func aBusyModelDropsWindowsInsteadOfQueueingThem() throws {
        let gate = DispatchSemaphore(value: 0)
        let fake = FakeEmbedder(gate: gate)
        let engine = VoiceIDEngine(modelName: "fake.onnx", makeEmbedder: { fake }, save: { _ in })
        engine.use(Voiceprint(vector: [1, 0], model: "fake.onnx", enrolledAt: Date(), segments: 1, speechSeconds: 6, calibration: ""))
        engine.setLive(true)
        let started = Date()
        for f in Self.frames(4, value: 0.1, p: 0.9) { engine.frames([f]) }
        #expect(Date().timeIntervalSince(started) < 0.5, "feeding waited on the model")
        #expect(engine.output.value.dropped >= 4, "dropped \(engine.output.value.dropped)")
        gate.signal()
        engine.drain()
        #expect(fake.calls.value == 1, "only the first window reached the model")
        // Free again: the next window is scored.
        for f in Self.frames(0.6, value: 0.1, p: 0.9) { engine.frames([f]) }
        gate.signal()
        engine.drain()
        #expect(fake.calls.value == 2)
    }

    @Test func aGapInFramesStartsAFreshWindow() {
        let engine = VoiceIDEngine(modelName: "fake.onnx", makeEmbedder: { FakeEmbedder() }, save: { _ in })
        engine.use(Voiceprint(vector: [1, 0], model: "fake.onnx", enrolledAt: Date(), segments: 1, speechSeconds: 6, calibration: ""))
        engine.setLive(true)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        // 1.2 s of speech, a 5 s gap (the mic was released), then 1.2 s more: no 1.5 s window
        // ever spans the gap.
        for (i, f) in Self.frames(1.2, value: 0.1, p: 0.9).enumerated() { engine.frames([f], now: t0.addingTimeInterval(Double(i) * 0.032)) }
        for (i, f) in Self.frames(1.2, value: 0.1, p: 0.9).enumerated() { engine.frames([f], now: t0.addingTimeInterval(6 + Double(i) * 0.032)) }
        engine.drain()
        #expect(engine.output.value.scored == 0)
    }

    // MARK: The app side

    @MainActor @Test func theStatusLineSaysModelMissingNotEnrolledOrWhen() {
        let d = ScratchDefaults("voice-id")
        let engine = VoiceIDEngine(makeEmbedder: { FakeEmbedder() }, save: { _ in })
        #expect(VoiceIDController(mic: nil, engine: engine, defaults: d, modelPresent: false, voiceprint: nil).statusLine
                == "Model missing: run scripts/fetch-voice-id.sh")
        #expect(VoiceIDController(mic: nil, engine: engine, defaults: d, modelPresent: true, voiceprint: nil).statusLine == "Not enrolled")
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let print = Voiceprint(vector: [1], model: VoiceID.modelFile, enrolledAt: when, segments: 10, speechSeconds: 60, calibration: "")
        let line = VoiceIDController(mic: nil, engine: engine, defaults: d, modelPresent: true, voiceprint: print).statusLine
        #expect(line == "Enrolled " + DateFormatter.localizedString(from: when, dateStyle: .medium, timeStyle: .none))
        // No microphone: enrollment says why instead of starting.
        #expect(VoiceIDController(mic: nil, engine: engine, defaults: d, modelPresent: true, voiceprint: nil).enrollmentBlocker()?.contains("microphone") == true)
        #expect(VoiceIDController(mic: nil, engine: engine, defaults: d, modelPresent: false, voiceprint: nil).enrollmentBlocker()?.contains("fetch-voice-id") == true)
    }

    /// The real pill: never in screen shares, never takes focus or clicks, and clear of the
    /// coach and mastery toasts (both top right).
    @MainActor @Test func thePillIsHiddenFromSharesAndClearOfTheToasts() throws {
        let c = VoiceIndicatorController()
        c.show()
        defer { c.hide() }
        let p = try #require(c.panel)
        #expect(p.sharingType == .none)
        #expect(p.styleMask.contains(.nonactivatingPanel))
        #expect(p.ignoresMouseEvents)
        #expect(!p.canBecomeKey || p.styleMask.contains(.nonactivatingPanel))
        #expect(c.text == "Silence")
        c.update(.me(0.81))
        #expect(c.text == "🎙 You're talking · 0.81")
        let vf = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let pill = NSRect(origin: VoiceIndicatorController.origin(in: vf), size: VoiceIndicatorController.size)
        let toast = NSSize(width: 340, height: 90)
        let coach = NSRect(x: vf.maxX - toast.width - 24, y: vf.maxY - toast.height - 24, width: toast.width, height: toast.height)
        let mastery = NSRect(x: vf.maxX - toast.width - 24, y: vf.maxY - 2 * toast.height - 36, width: toast.width, height: toast.height)
        #expect(vf.contains(pill))
        #expect(!pill.intersects(coach) && !pill.intersects(mastery))
    }
}

// "Enroll My Voice…" from the tray: the window opens and stays open while the app is not the
// active one (11-11: it vanished as the menu closed, and on a click on another screen), and an
// existing voiceprint is only replaced on the owner's word.
@MainActor
@Suite("Voice ID enrollment window", .tags(.light, .voiceID), .timeLimit(.minutes(1)), .quietLog, .serialized)
struct VoiceEnrollWindowTests {
    static func controller(voiceprint: Voiceprint?) -> VoiceIDController {
        _ = NSApplication.shared   // NSApp, which the window and alert use, whichever test runs first
        return VoiceIDController(mic: nil, engine: VoiceIDEngine(modelName: "fake.onnx", makeEmbedder: { VoiceIDTests.FakeEmbedder() }, save: { _ in }),
                          defaults: ScratchDefaults("voice-enroll"), modelPresent: true, voiceprint: voiceprint)
    }

    static let enrolled = Voiceprint(vector: [1, 0], model: "fake.onnx", enrolledAt: Date(timeIntervalSince1970: 1_800_000_000),
                                     segments: 8, speechSeconds: 60, calibration: "test")

    @Test func theWindowOpensAndStaysUpWhenTheAppIsNotActive() throws {
        let c = Self.controller(voiceprint: nil)
        var asked = 0
        c.confirmReplace = { _ in asked += 1; return true }
        c.showEnrollment()
        let w = try #require(c.panel?.window)
        defer { w.orderOut(nil) }
        #expect(asked == 0, "nothing to replace: no question")
        #expect(w.isVisible)
        #expect(w.hidesOnDeactivate == false, "a menu-bar app is rarely active: the window must not hide with it")
        #expect(w.collectionBehavior.contains(.moveToActiveSpace))
    }

    @Test func anEnrolledVoiceIsReplacedOnlyOnTheOwnersWord() throws {
        let kept = Self.controller(voiceprint: Self.enrolled)
        var shownTo: [Voiceprint] = []
        kept.confirmReplace = { shownTo.append($0); return false }
        kept.showEnrollment()
        #expect(shownTo == [Self.enrolled], "asked once, about the saved voiceprint")
        #expect(kept.panel?.window?.isVisible != true, "kept: no enrollment window")
        #expect(kept.voiceprint == Self.enrolled)

        let replaced = Self.controller(voiceprint: Self.enrolled)
        replaced.confirmReplace = { _ in true }
        replaced.showEnrollment()
        let w = try #require(replaced.panel?.window)
        defer { w.orderOut(nil) }
        #expect(w.isVisible, "replace: the enrollment window opens")
        // Chosen again while it is open: brought forward, not asked again.
        var askedAgain = 0
        replaced.confirmReplace = { _ in askedAgain += 1; return false }
        replaced.showEnrollment()
        #expect(askedAgain == 0)
        #expect(w.isVisible, "a Cancel elsewhere never closes the open window")
    }

    @Test func aBluetoothMicSaysWhatToDo() {
        let mic = MicSpeechSource(screenpipe: SilentSpeech())
        mic.inputIsBluetooth = { true }
        let c = VoiceIDController(mic: mic, engine: VoiceIDEngine(modelName: "fake.onnx", makeEmbedder: { VoiceIDTests.FakeEmbedder() }, save: { _ in }),
                                  defaults: ScratchDefaults("voice-enroll"), modelPresent: true, voiceprint: nil)
        #expect(c.enrollmentBlocker()?.contains("Bluetooth headset") == true)
        #expect(c.enrollmentBlocker()?.contains("Sound › Input") == true)
    }
}

@MainActor
private final class SilentSpeech: SpeechSource {
    func poll(now: Date, deliver: @escaping @MainActor ([SpeechSpan]) -> Void) {}
}
