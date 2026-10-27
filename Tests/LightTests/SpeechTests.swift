import AVFoundation
import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// The on-device speech detector: Silero VAD on Core ML, the segmenter that turns its frame
// probabilities into spans, and the whole chain into the coach. Audio is synthesized with
// macOS `say` (fictional text); nothing is recorded from a microphone.
@MainActor
@Suite("Speech detection (Silero)", .tags(.light, .coach), .timeLimit(.minutes(1)), .quietLog, .serialized)
struct SpeechTests {
    /// 16 kHz mono samples of `text` spoken by `say`, after `leadIn` seconds of silence.
    static func speech(_ text: String, wpm: Int = 180, leadIn: Double = 0) throws -> [Float] {
        let dir = TempDir("say")
        let wav = dir.file("speech.wav")
        let r = ChildProcess.run("/usr/bin/say", ["-r", String(wpm), "-o", wav, "--file-format=WAVE", "--data-format=LEI16@16000", text], timeout: 60, stderr: true)
        try #require(r.ok, "say failed: \(r.output)")
        let data = try Data(contentsOf: URL(fileURLWithPath: wav))
        let at = try #require(data.range(of: Data("data".utf8)))
        let pcm = data[(at.upperBound + 4)...].withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        return [Float](repeating: 0, count: Int(leadIn * SileroVAD.sampleRate)) + pcm.map { Float($0) / 32768 }
    }

    /// Runs `samples` through Silero and the segmenter as if heard from `start`, in 4096-sample
    /// buffers; returns the spans `take()` hands out after each buffer.
    static func detect(_ samples: [Float], from start: Date) throws -> [(start: Date, end: Date, at: Date)] {
        let vad = try SileroVAD()
        var seg = VADSegmenter()
        var spans: [(Date, Date, Date)] = []
        var frame = 0
        for i in stride(from: 0, to: samples.count, by: 4096) {
            for p in try vad.process(Array(samples[i..<min(i + 4096, samples.count)])) {
                seg.add(p, at: start.addingTimeInterval(Double(frame) * SileroVAD.frameSeconds))
                frame += 1
            }
            let heard = start.addingTimeInterval(Double(min(i + 4096, samples.count)) / SileroVAD.sampleRate)
            if let s = seg.take() { spans.append((s.start, s.end, heard)) }
        }
        return spans
    }

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

    @Test func theModelHearsSpeechWithinASecondAndNotSilence() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let silent = try Self.detect([Float](repeating: 0, count: 3 * 16000), from: t0)
        #expect(silent.isEmpty, "speech found in silence")
        let samples = try Self.speech("We should look at the plan for next week and decide who does what.", leadIn: 2)
        let spans = try Self.detect(samples, from: t0)
        let first = try #require(spans.first, "no speech detected")
        #expect(first.start.timeIntervalSince(t0) >= 1.9, "speech before it started")
        // Reported (handed out) within a second of the speech starting.
        #expect(first.at.timeIntervalSince(t0) - 2 <= 1.0, "detected \(first.at.timeIntervalSince(t0) - 2) s after onset")
    }

    @Test func thirtySecondsOfSpeechThroughSileroBringsTheWarning() throws {
        let rig = CoachRig(mode: .baseline)
        let text = Array(repeating: "I want to walk through the whole plan for the next project in detail before anyone else speaks.", count: 8)
            .joined(separator: " ")
        let samples = try Self.speech(text, wpm: 190, leadIn: 1)
        try #require(Double(samples.count) / 16000 > 33, "the passage is too short")
        for span in try Self.detect(samples, from: rig.t0) {
            rig.speech.queued.append(SpeechSpan(speaker: .me, start: span.start, end: span.end, words: 0, audioClock: true,
                                                capturedAt: span.start, path: "silero_vad", label: "silero"))
            rig.now = span.at
            rig.coach.tick()
        }
        #expect(rig.toast.shows > 0, "no 30 s warning after \(Double(samples.count) / 16000) s of speech")
        #expect(rig.coach.currentStreak >= 30)
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

    // The microphone callback runs on AVAudio's real-time thread, never main. Driven from a
    // background queue with 48 kHz speech (the Mac's input rate): it must not trap (a
    // main-actor closure there crashed the app on 10-27), and its 48 -> 16 kHz conversion
    // must still hear speech. In this serialized suite: `say` fails when run concurrently.
    @Test func theTapRunsOffTheMainThreadAndHearsSpeech() throws {
        let dir = TempDir("mic")
        let wav = dir.file("speech48k.wav")
        let r = ChildProcess.run("/usr/bin/say", ["-r", "180", "-o", wav, "--file-format=WAVE", "--data-format=LEF32@48000",
                                                  "We should look at the plan for next week and decide who does what."], timeout: 60, stderr: true)
        try #require(r.ok, "say failed: \(r.output)")
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: wav))
        let format = file.processingFormat
        let target = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SileroVAD.sampleRate, channels: 1, interleaved: false))
        let converter = try #require(AVAudioConverter(from: format, to: target))
        let state = Locked<MicSpeechSource.VADState>(MicSpeechSource.VADState(vad: try SileroVAD()))
        let queue = DispatchQueue(label: "test.vad")
        let tap = MicSpeechSource.tap(format: format, target: target, converter: converter, state: state, queue: queue, log: Log("Test"))
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async {
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800) else { break }
                try? file.read(into: buffer, frameCount: 4800)
                tap(buffer, AVAudioTime(hostTime: mach_absolute_time()))
            }
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 30) == .success)
        queue.sync {}
        #expect(state.withLock { $0.segmenter.take() } != nil, "no speech heard through the callback")
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
