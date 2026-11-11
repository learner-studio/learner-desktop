import AppKit
import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// Guided enrollment end to end, but for the recognizer: the Rainbow Passage spoken by `say`
// (170 wpm, 16 kHz mono) -> the real Silero VAD -> a stand-in recognizer that hears the
// passage's words as the audio reaches them -> alignment -> sentence by sentence -> the real
// CAM++ voiceprint, saved; then the same voice scores as the owner and another does not.
// The real SFSpeechRecognizer runs the same path in HeavyTests/VoiceEnrollRecognizerTests.
// Medium: `say` and the models are real; no speech-recognition permission is needed.
@MainActor
@Suite("Voice ID guided enrollment (say + VAD + CAM++, timed stand-in recognizer)", .tags(.medium, .voiceID), .timeLimit(.minutes(2)),
       .quietLog, .serialized, .enabled(if: VoiceID.modelURL != nil, "the speaker model is not fetched: run scripts/fetch-voice-id.sh"))
struct VoiceEnrollReadingE2ETests {
    /// Hears the passage's words in step with the audio appended (a little behind it, as a
    /// recognizer is), loses two words, and ends its request every 50 s of audio as Apple's
    /// requests end after about a minute.
    final class TimedRecognizer: ReadingRecognizer, @unchecked Sendable {
        let words: [String]
        /// Samples from the first to the last spoken one, over which the words are spread.
        let speechStart: Int, speechEnd: Int
        /// Word indices never "heard": a sentence's last word and the passage's last.
        let missed: Set<Int>
        static let lag = 8_000, requestSamples = 50 * 16_000
        private let consumed = Locked(0)
        private var events: (@MainActor @Sendable (ReadingRecognizerEvent) -> Void)?
        private var requestFrom = 0, requestWordFrom = 0
        private(set) var starts = 0

        init(words: [String], speechStart: Int, speechEnd: Int, missed: Set<Int>) {
            self.words = words
            self.speechStart = speechStart
            self.speechEnd = speechEnd
            self.missed = missed
        }

        @MainActor func prepare(_ done: @escaping @MainActor @Sendable (ReadingTrackingAvailability) -> Void) { done(.available) }
        @MainActor func start(_ events: @escaping @MainActor @Sendable (ReadingRecognizerEvent) -> Void) {
            starts += 1
            self.events = events
            requestFrom = consumed.value
            requestWordFrom = heardWords(at: requestFrom)
        }
        func append(_ frames: [SileroVAD.Frame]) { consumed.withLock { $0 += frames.reduce(0) { $0 + $1.samples.count } } }
        @MainActor func stop() { events = nil }

        private func heardWords(at sample: Int) -> Int {
            let at = sample - Self.lag - speechStart
            guard at > 0 else { return 0 }
            return min(words.count, words.count * at / max(1, speechEnd - speechStart))
        }

        /// What a recognizer would have said by now (called each tick on the main thread).
        @MainActor func pump() {
            guard let events else { return }
            let now = consumed.value
            let upTo = heardWords(at: now)
            let text = (requestWordFrom..<max(requestWordFrom, upTo)).filter { !missed.contains($0) }.map { words[$0] }.joined(separator: " ")
            if !text.isEmpty { events(.transcript(text)) }
            if now - requestFrom >= Self.requestSamples { events(.ended(nil)) }
        }
    }

    static let rate = 170

    static func speech(_ text: String, voice: String) throws -> [Float] {
        let dir = TempDir("say")
        let file = dir.file("text.txt"), wav = dir.file("speech.wav")
        try text.write(toFile: file, atomically: true, encoding: .utf8)
        let r = ChildProcess.run("/usr/bin/say", ["-v", voice, "-r", String(rate), "-f", file, "-o", wav,
                                                  "--file-format=WAVE", "--data-format=LEI16@16000"], timeout: 90, stderr: true)
        try #require(r.ok, "say failed: \(r.output)")
        let data = try Data(contentsOf: URL(fileURLWithPath: wav))
        let at = try #require(data.range(of: Data("data".utf8)))
        return data[(at.upperBound + 4)...].withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { Float($0) / 32768 }
    }

    @Test func theSpokenPassageEnrollsSentenceBySentence() async throws {
        let url = try #require(VoiceID.modelURL)
        _ = NSApplication.shared
        let samples = try Self.speech(ReadingPassage.paragraphs.joined(separator: "\n\n"), voice: VoiceIDModelTests.owner)
            + [Float](repeating: 0, count: 3 * 16_000)   // the owner stops
        let frames = try VoiceIDModelTests.frames(samples)
        let spoken = frames.indices.filter { frames[$0].probability >= VoiceID.speechProbability }
        let first = try #require(spoken.first) * SileroVAD.frame, last = (try #require(spoken.last) + 1) * SileroVAD.frame
        let sentences = ReadingSentences()
        let missed: Set<Int> = [sentences.ranges[3].upperBound - 1, ReadingPassage.words.count - 1]
        let fake = TimedRecognizer(words: ReadingPassage.words, speechStart: first, speechEnd: last, missed: missed)

        let dir = TempDir("voiceprint")
        let file = URL(fileURLWithPath: dir.file("voiceprint.json"))
        let engine = VoiceIDEngine(makeEmbedder: { try SherpaSpeakerEmbedder(model: url) }, save: { try $0.save(file) })
        let c = VoiceIDController(mic: nil, engine: engine, defaults: ScratchDefaults("voice-e2e"), modelPresent: true,
                                  voiceprint: nil, recognizer: fake)
        c.tracker.restartDelay = 0
        let t0 = Date()
        var clock = t0
        c.now = { clock }

        c.startReading(.available)
        #expect(c.readingMode == .tracked)
        var seen: [Int] = []
        // As the mic path feeds it: Silero's frames to the engine and the recognizer, in batches.
        for start in stride(from: 0, to: frames.count, by: 8) {
            let batch = Array(frames[start..<min(start + 8, frames.count)])
            clock = t0.addingTimeInterval(Double(start + batch.count) * SileroVAD.frameSeconds)
            engine.frames(batch, now: clock)
            fake.append(batch)
            fake.pump()
            c.tick()
            let i = c.reading.current   // the sentence shown: read only once most of it was heard
            if seen.last != i { seen.append(i) }
        }
        let speechSeconds = engine.output.value.enrollSpeechSeconds
        Swift.print(String(format: "VOICE-ID guided: %.1f s of audio, %.1f s of speech, %d recognizer requests, sentences %@",
                           Double(samples.count) / 16_000, speechSeconds, fake.starts, seen.map(String.init).joined(separator: " ")))
        #expect(seen == Array(0...sentences.count), "every sentence in turn, then done: \(seen)")
        #expect(fake.starts >= 2, "a request ended and the next one picked up")
        #expect(speechSeconds >= ReadingCompletion.minSpeechSeconds, "only \(speechSeconds) s of speech at \(Self.rate) wpm")
        #expect(!engine.enrolling, "the reading finished (reached \(c.tracker.reached) of \(c.tracker.total))")
        engine.drain()
        c.tick()
        let print = try #require(c.voiceprint, "no voiceprint: \(String(describing: engine.output.value.enrollResult))")
        #expect(Voiceprint.load(file) == print)
        Swift.print("VOICE-ID guided enrollment: \(print.calibration)")

        let model = try SherpaSpeakerEmbedder(model: url)
        let same = VoiceIDModelTests.scores(try VoiceIDModelTests.frames(try Self.speech(VoiceIDModelTests.ownerText, voice: VoiceIDModelTests.owner)),
                                            against: print.vector, model: model)
        let other = VoiceIDModelTests.scores(try VoiceIDModelTests.frames(try Self.speech(VoiceIDModelTests.otherText, voice: VoiceIDModelTests.other)),
                                             against: print.vector, model: model)
        try #require(same.count >= 4 && other.count >= 4)
        let mean = { (xs: [(score: Float, ms: Double)]) in xs.reduce(0) { $0 + $1.score } / Float(xs.count) }
        Swift.print(String(format: "VOICE-ID guided: same voice %.2f, other voice %.2f", mean(same), mean(other)))
        #expect(mean(same) >= VoiceID.threshold, "same voice scored \(mean(same))")
        #expect(mean(other) < VoiceID.threshold, "other voice scored \(mean(other))")
    }
}
