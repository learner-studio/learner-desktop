import AVFoundation
import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// The on-device speech detector's logic: the segmenter that turns frame probabilities into
// spans, and screenpipe's late spans. The model itself, on real (synthesized) audio, is in
// MediumTests/SpeechModelTests: `say` and Core ML cost seconds each.
@MainActor
@Suite("Speech detection (segmenter)", .tags(.light, .coach), .timeLimit(.minutes(1)), .quietLog)
struct SpeechTests {
    @Test func theSegmenterNeeds256MsOfSpeechAndIgnoresBlips() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let f = SileroVAD.frameSeconds
        var seg = VADSegmenter()
        // A 5-frame blip (160 ms) in silence: never speech.
        for i in 0..<40 { seg.add(i >= 10 && i < 15 ? 0.9 : 0.05, at: t0.addingTimeInterval(Double(i) * f)) }
        #expect(seg.take() == nil)
        // Steady speech from frame 40: speech once 8 frames are in (256 ms), starting at frame 40.
        for i in 40..<47 { seg.add(0.9, at: t0.addingTimeInterval(Double(i) * f)) }
        #expect(seg.take() == nil)
        seg.add(0.9, at: t0.addingTimeInterval(47 * f))
        let first = seg.take()
        #expect(first.map { abs($0.start.timeIntervalSince(t0) - 40 * f) < 0.001 } == true)
        // Continuing speech extends it. After a short pause the speaker carrying on is the
        // same speech (the last second still holds 256 ms of it); after a full second of
        // silence a blip is not.
        for i in 48..<60 { seg.add(0.9, at: t0.addingTimeInterval(Double(i) * f)) }
        #expect(seg.take().map { abs($0.end.timeIntervalSince(t0) - 60 * f) < 0.001 } == true)
        for i in 60..<100 { seg.add(0.05, at: t0.addingTimeInterval(Double(i) * f)) }
        for i in 100..<105 { seg.add(0.9, at: t0.addingTimeInterval(Double(i) * f)) }
        #expect(seg.take() == nil)
    }

    @Test func screenpipesLateSpansAddWordsButNoTiming() {
        let rig = CoachRig(mode: .baseline)
        rig.say(0, 8, words: 0)
        let streak = rig.coach.currentStreak
        // screenpipe's late span for the same speech: words only.
        var late = SpeechSpan(speaker: .me, start: rig.t0.addingTimeInterval(-3), end: rig.t0.addingTimeInterval(12), words: 21,
                              audioClock: true, capturedAt: rig.t0, path: "background", label: "late")
        late.wordsOnly = true
        rig.speech.queued.append(late)
        rig.coach.tick()
        #expect(rig.coach.currentStreak == streak, "a words-only span changed the turn's timing")
        // And one arriving after the turn ended does not start a phantom turn.
        rig.now = rig.t0.addingTimeInterval(60)
        rig.coach.tick()
        var orphan = late
        orphan.wordsOnly = true
        rig.speech.queued.append(orphan)
        rig.coach.tick()
        #expect(rig.coach.currentStreak == 0)
    }
}

// The microphone watchdog: a stalled mic (frames stop moving) is restarted after 10 s, then
// after doubling waits while it stays silent, never in a tight loop; audio flowing again resets it.
@Suite("Microphone watchdog", .tags(.light, .coach))
struct StallWatchTests {
    @Test func aStalledMicIsRestartedWithBackoffAndResetByAudio() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var w = StallWatch()
        w.started(frames: 100)
        #expect(w.check(frames: 131, now: t0) == .flowing)
        #expect(w.check(frames: 131, now: t0.addingTimeInterval(1)) == .waiting)
        #expect(w.check(frames: 131, now: t0.addingTimeInterval(10)) == .waiting)
        #expect(w.check(frames: 131, now: t0.addingTimeInterval(12)) == .restart(silentFor: 11))
        // Still silent: not again at 12 s or 20 s, but after a 20 s wait (31+ s), then 40 s more.
        #expect(w.check(frames: 131, now: t0.addingTimeInterval(20)) == .waiting)
        #expect(w.check(frames: 131, now: t0.addingTimeInterval(32)) == .waiting)
        #expect(w.check(frames: 131, now: t0.addingTimeInterval(33)) == .restart(silentFor: 32))
        #expect(w.check(frames: 131, now: t0.addingTimeInterval(72)) == .waiting)
        #expect(w.check(frames: 131, now: t0.addingTimeInterval(74)) == .restart(silentFor: 73))
        // Waits stop growing at the cap.
        var capped = StallWatch(first: 10, cap: 30)
        _ = capped.check(frames: 0, now: t0)
        var restarts: [TimeInterval] = []
        for s in stride(from: 1.0, through: 200, by: 1) {
            if case .restart(let silent) = capped.check(frames: 0, now: t0.addingTimeInterval(s)) { restarts.append(silent) }
        }
        #expect(restarts.count >= 6, "\(restarts)")
        #expect(zip(restarts, restarts.dropFirst()).allSatisfy { $1 - $0 <= 31 }, "\(restarts)")
        // Audio again: reset, and the next stall waits the first 10 s again.
        #expect(w.check(frames: 140, now: t0.addingTimeInterval(80)) == .flowing)
        #expect(w.since == nil)
        #expect(w.check(frames: 140, now: t0.addingTimeInterval(81)) == .waiting)
        #expect(w.check(frames: 140, now: t0.addingTimeInterval(90)) == .waiting)
        #expect(w.check(frames: 140, now: t0.addingTimeInterval(92)) == .restart(silentFor: 11))
    }
}

// Who holds the microphone: during a call on a Bluetooth input (AirPods) Learner leaves it
// to the call app; otherwise a mic that is not running (a failed restart mid-switch, as on
// 10-27) is opened again once its retry is due, never left off for good.
@MainActor
@Suite("Microphone hand-off", .tags(.light, .coach))
struct MicHandOffTests {
    @Test func theMicIsLeftToABluetoothCallAndReopenedOtherwise() {
        typealias M = MicSpeechSource
        // Running: released only for a call on Bluetooth.
        #expect(M.decide(running: true, wanted: true, inCall: true, bluetooth: true, retryDue: true) == .release)
        #expect(M.decide(running: true, wanted: true, inCall: true, bluetooth: false, retryDue: true) == .none)
        #expect(M.decide(running: true, wanted: true, inCall: false, bluetooth: false, retryDue: true) == .none)
        // Not running: reopened when wanted and due, not during a Bluetooth call.
        #expect(M.decide(running: false, wanted: true, inCall: false, bluetooth: false, retryDue: true) == .open)
        #expect(M.decide(running: false, wanted: true, inCall: true, bluetooth: false, retryDue: true) == .open)
        #expect(M.decide(running: false, wanted: true, inCall: true, bluetooth: true, retryDue: true) == .none)
        #expect(M.decide(running: false, wanted: true, inCall: false, bluetooth: false, retryDue: false) == .none)
        #expect(M.decide(running: false, wanted: false, inCall: false, bluetooth: false, retryDue: true) == .none)
    }

    @Test func startingDuringABluetoothCallDoesNotTouchTheMic() {
        let mic = MicSpeechSource(screenpipe: QuietSpeech())
        mic.inCall = true
        mic.inputIsBluetooth = { true }
        #expect(mic.start() == false)
        #expect(mic.problem == nil, "leaving the mic to a call is not a problem")
        var heard: [SpeechSpan] = []
        mic.poll(now: Date()) { heard += $0 }
        #expect(mic.framesScored == 0)
        #expect(heard.isEmpty)
    }
}

@MainActor
private final class QuietSpeech: SpeechSource {
    func poll(now: Date, deliver: @escaping @MainActor ([SpeechSpan]) -> Void) {}
}
