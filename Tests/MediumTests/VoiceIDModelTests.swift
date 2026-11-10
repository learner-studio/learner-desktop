import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// Voice ID's model on real (synthesized) audio: sherpa-onnx's CAM++ speaker embeddings on
// speech made with macOS `say` (fictional text), the frames cut by the real Silero VAD as the
// microphone path does. Enrolled on one synthetic voice, the same voice saying something else
// must score above the threshold and a different voice below it. Nothing from a microphone.
// Medium: `say` is a child process, and the models cost a second or two to load. Skipped
// when scripts/fetch-voice-id.sh has not been run. Serialized: `say` fails when run concurrently.
@Suite("Voice ID model (sherpa-onnx, synthesized voices)", .tags(.medium, .voiceID), .timeLimit(.minutes(2)), .quietLog, .serialized,
       .enabled(if: VoiceID.modelURL != nil, "the speaker model is not fetched: run scripts/fetch-voice-id.sh"))
struct VoiceIDModelTests {
    static let owner = "Samantha"
    static let other = "Daniel"

    static let enrollText = """
        Good morning everyone. Before we start, I want to walk through where the garden project stands and what is left \
        for the next two weeks. The raised beds on the north side are finished, and the soil arrived on Tuesday. \
        We still need someone to build the trellis for the beans, and the watering schedule has to be agreed before the \
        weather turns warm. I spoke with the hardware shop about the timber, and they can deliver on Friday afternoon if \
        we confirm the order by Wednesday. The budget is fine for now, although the irrigation parts cost more than we \
        expected. My suggestion is that we split into two small groups. One group takes the trellis and the paths, and the \
        other group takes the seedlings and the labels. If anyone has a strong preference, tell me after this meeting and \
        I will sort it out. One more thing about the shed. The lock is broken again, so please do not leave tools inside \
        overnight until the new lock is fitted. I will ask the caretaker to look at it tomorrow morning. Finally, thank \
        you all for the work on the compost area. It looks much better than it did last month, and the neighbours have \
        noticed too. Let us keep the momentum going, and we can review progress at the same time next week. \
        To recap the plan, the beds are done, the soil is here, the timber comes on Friday, and the trellis and seedlings \
        are the next two jobs. Please keep the shed empty at night, and bring gloves on Saturday.
        """
    static let ownerText = "I think the quarterly numbers look reasonable, but I would like to double check the travel costs before we send the report to the board."
    static let otherText = "The train to the coast leaves at half past nine, so we should pack the car tonight and leave the house by eight tomorrow."

    /// 16 kHz mono samples of `text` in `voice`.
    static func speech(_ text: String, voice: String) throws -> [Float] {
        let dir = TempDir("say")
        let wav = dir.file("speech.wav")
        let r = ChildProcess.run("/usr/bin/say", ["-v", voice, "-r", "180", "-o", wav, "--file-format=WAVE", "--data-format=LEI16@16000", text],
                                 timeout: 60, stderr: true)
        try #require(r.ok, "say failed: \(r.output)")
        let data = try Data(contentsOf: URL(fileURLWithPath: wav))
        let at = try #require(data.range(of: Data("data".utf8)))
        let pcm = data[(at.upperBound + 4)...].withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        return pcm.map { Float($0) / 32768 }
    }

    /// The frames the microphone path would hand Voice ID: Silero's, in 4096-sample buffers.
    static func frames(_ samples: [Float]) throws -> [SileroVAD.Frame] {
        let vad = try SileroVAD()
        var out: [SileroVAD.Frame] = []
        for i in stride(from: 0, to: samples.count, by: 4096) {
            out += try vad.frames(Array(samples[i..<min(i + 4096, samples.count)]))
        }
        return out
    }

    /// Every speech window's score against `print`, with how long each embedding took.
    static func scores(_ frames: [SileroVAD.Frame], against print: [Float], model: SherpaSpeakerEmbedder) -> [(score: Float, ms: Double)] {
        var window = SlidingWindow()
        var out: [(Float, Double)] = []
        for f in frames {
            guard let w = window.add(f.samples, speech: f.probability >= VoiceID.speechProbability), w.isSpeech else { continue }
            let started = Date()
            let e = model.embed(w.samples)
            out.append((VoiceMath.cosine(e, print), Date().timeIntervalSince(started) * 1000))
        }
        return out
    }

    @Test func enrolledOnOneVoiceItKnowsThatVoiceAndNotAnother() throws {
        let url = try #require(VoiceID.modelURL)
        // Enrollment through the engine, exactly as the app runs it (frames on one thread, the
        // model on its queue), with the real model; saved to a scratch file.
        let dir = TempDir("voiceprint")
        let file = URL(fileURLWithPath: dir.file("voiceprint.json"))
        let engine = VoiceIDEngine(makeEmbedder: { try SherpaSpeakerEmbedder(model: url) }, save: { try $0.save(file) })
        engine.startEnrollment()
        let enrollFrames = try Self.frames(try Self.speech(Self.enrollText, voice: Self.owner))
        for batch in stride(from: 0, to: enrollFrames.count, by: 8) { engine.frames(Array(enrollFrames[batch..<min(batch + 8, enrollFrames.count)])) }
        #expect(!engine.enrolling, "the enrollment text held under \(VoiceID.enrollSeconds) s of speech (progress \(engine.output.value.enrollProgress ?? 0))")
        engine.drain()
        let result = try #require(engine.output.value.enrollResult)
        guard case .done(let print) = result else { Issue.record("enrollment failed: \(result)"); return }
        #expect(print.segments == 10)
        #expect(Voiceprint.load(file) == print)
        #expect(abs(print.vector.reduce(0) { $0 + $1 * $1 } - 1) < 1e-3, "the voiceprint is L2-normalized")
        Swift.print("VOICE-ID enrollment: \(print.calibration)")

        let model = try SherpaSpeakerEmbedder(model: url)
        #expect(model.dimension == print.vector.count)
        let same = Self.scores(try Self.frames(try Self.speech(Self.ownerText, voice: Self.owner)), against: print.vector, model: model)
        let other = Self.scores(try Self.frames(try Self.speech(Self.otherText, voice: Self.other)), against: print.vector, model: model)
        try #require(same.count >= 4 && other.count >= 4, "too few speech windows: \(same.count) / \(other.count)")
        let fmt = { (xs: [(score: Float, ms: Double)]) in xs.map { String(format: "%.2f", $0.score) }.joined(separator: " ") }
        Swift.print("VOICE-ID same voice (\(Self.owner)): \(fmt(same))")
        Swift.print("VOICE-ID other voice (\(Self.other)): \(fmt(other))")

        // Decided as the app decides: smoothed over 2 windows.
        func meShare(_ xs: [(score: Float, ms: Double)]) -> Double {
            var s = VoiceSmoother()
            let me = xs.filter { if case .me = s.add($0.score) { return true } else { return false } }.count
            return Double(me) / Double(xs.count)
        }
        let mean = { (xs: [(score: Float, ms: Double)]) in xs.reduce(0) { $0 + $1.score } / Float(xs.count) }
        #expect(mean(same) >= VoiceID.threshold, "same voice scored \(mean(same))")
        #expect(mean(other) < VoiceID.threshold, "other voice scored \(mean(other))")
        #expect(meShare(same) >= 0.8, "same voice: 'me' on \(Int(meShare(same) * 100)) % of windows")
        #expect(meShare(other) <= 0.2, "other voice: 'me' on \(Int(meShare(other) * 100)) % of windows")

        // Each 1.5 s window must embed well inside its 0.5 s hop (else windows are dropped).
        let times = (same + other).map(\.ms).sorted()
        let median = times[times.count / 2]
        Swift.print(String(format: "VOICE-ID embedding per 1.5 s window: median %.1f ms, max %.1f ms over %d windows", median, times.last!, times.count))
        #expect(median < 250, "median embedding \(median) ms")
    }
}
