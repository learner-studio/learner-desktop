import AVFoundation
import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// The on-device speech detector on real audio: Silero VAD on Core ML, fed speech synthesized
// with macOS `say` (fictional text); nothing is recorded from a microphone. Medium: each
// `say` is a real child process, and the model costs seconds to load (loaded once here).
// Serialized: `say` fails when run concurrently.
@Suite("Speech model (Silero, synthesized audio)", .tags(.medium, .coach), .timeLimit(.minutes(1)), .quietLog, .serialized)
struct SpeechModelTests {
    nonisolated(unsafe) private static var loaded: SileroVAD?
    /// The one model for the suite (Core ML load is the expensive part); `detect` resets it.
    static func model() throws -> SileroVAD {
        if let m = loaded { return m }
        let m = try SileroVAD()
        loaded = m
        return m
    }

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
        let vad = try model()
        vad.reset()
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


    // The microphone callback runs on AVAudio's real-time thread, never main. Driven from a
    // background queue with 48 kHz speech (the Mac's input rate): it must not trap (a
    // main-actor closure there crashed the app on 10-27), and its 48 -> 16 kHz conversion
    // must still hear speech. In this serialized suite: `say` fails when run concurrently.
    /// Speech through the real callback, from a mono file and from a 16-channel input whose
    /// voice is only on channel 3 (as CI's BlackHole 16ch delivered it, 11-12).
    @Test(arguments: [1, 16] as [AVAudioChannelCount])
    func theTapRunsOffTheMainThreadAndHearsSpeech(channels: AVAudioChannelCount) throws {
        let dir = TempDir("mic")
        let wav = dir.file("speech48k.wav")
        let r = ChildProcess.run("/usr/bin/say", ["-r", "180", "-o", wav, "--file-format=WAVE", "--data-format=LEF32@48000",
                                                  "We should look at the plan for next week and decide who does what."], timeout: 60, stderr: true)
        try #require(r.ok, "say failed: \(r.output)")
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: wav))
        let fileFormat = file.processingFormat
        let format = try #require(channels == 1 ? fileFormat
            : AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fileFormat.sampleRate, interleaved: false,
                            channelLayout: try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)))))
        let mono = try #require(MicMono(from: format))
        let state = Locked<MicSpeechSource.VADState>(MicSpeechSource.VADState())
        let model = MicSpeechSource.VADModel(try SileroVAD())
        let queue = DispatchQueue(label: "test.vad")
        let tap = MicSpeechSource.tap(format: format, mono: mono, state: state, model: model, queue: queue, log: Log("Test"))
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async {
            while file.framePosition < file.length {
                guard let read = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: 4800) else { break }
                try? file.read(into: read, frameCount: 4800)
                var buffer = read
                if channels > 1, let wide = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: read.frameLength) {
                    // Silence everywhere but channel 3.
                    wide.frameLength = read.frameLength
                    for c in 0..<Int(channels) { wide.floatChannelData![c].update(repeating: 0, count: Int(read.frameLength)) }
                    wide.floatChannelData![2].update(from: read.floatChannelData![0], count: Int(read.frameLength))
                    buffer = wide
                }
                tap(buffer, AVAudioTime(hostTime: mach_absolute_time()))
            }
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 30) == .success)
        queue.sync {}
        #expect(state.withLock { $0.segmenter.take() } != nil, "no speech heard through the callback")
    }
}
