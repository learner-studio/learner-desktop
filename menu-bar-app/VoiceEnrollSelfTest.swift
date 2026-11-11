import AppKit
@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

// MARK: - Guided enrollment self-test (the real recognizer, inside the app bundle)

// `learner-desktop --voice-enroll-selftest <wav> [--out <json>]` reads a recording through the
// same path as an enrollment, at real time: frames -> Silero -> AppleReadingRecognizer ->
// tracker -> sentences -> a CAM++ voiceprint, which is reported and never saved (the owner's
// voiceprint is not touched). No microphone. Speech-recognition permission belongs to the
// app, so run it as the app, through `open` (a binary started from a terminal is the
// terminal's, which cannot be granted it):
//   open -n -W -a "Learner Desktop.app" --args --voice-enroll-selftest /path/passage.wav --out /tmp/result.json
// `--voice-enroll-selftest --status` reports the permission without asking; `--authorize`
// asks once (the owner answers the prompt) and reports.
// Exit: 0 the passage was read and a voiceprint made; 1 not; 2 recognition unavailable
// (denied, restricted, not on device); 3 permission not answered; 4 bad input.

@MainActor
func runVoiceEnrollSelfTestCLI(_ args: [String]) -> Never {
    let after = { (flag: String) -> String? in
        args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }
    let out = after("--out")
    func finish(_ result: [String: Any], _ code: Int32) -> Never {
        var r = result
        r["exitCode"] = code
        let data = (try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        if let out { try? data.write(to: URL(fileURLWithPath: out), options: .atomic) }
        print(String(decoding: data, as: UTF8.self))
        exit(code)
    }
    NSApplication.shared.setActivationPolicy(.accessory)
    let status = { VoiceEnrollSelfTest.name(SFSpeechRecognizer.authorizationStatus()) }
    if args.contains("--status") { finish(["authorization": status()], 0) }
    if args.contains("--authorize") {
        SFSpeechRecognizer.requestAuthorization { s in
            DispatchQueue.main.async { finish(["authorization": VoiceEnrollSelfTest.name(s)], s == .authorized ? 0 : 2) }
        }
        RunLoop.main.run()
        exit(3)
    }
    guard let wav = after("--voice-enroll-selftest"), !wav.hasPrefix("--") else {
        finish(["error": "usage: --voice-enroll-selftest <wav> [--out <json>] | --status | --authorize"], 4)
    }
    let test = VoiceEnrollSelfTest(finish: finish)
    do { try test.load(wav) } catch { finish(["error": "could not read \(wav): \(error.localizedDescription)"], 4) }
    test.run()
    RunLoop.main.run()
    exit(1)
}

@MainActor
final class VoiceEnrollSelfTest {
    private let finish: ([String: Any], Int32) -> Never
    private var frames: [SileroVAD.Frame] = []
    private var audioSeconds = 0.0
    private let recognizer = AppleReadingRecognizer()
    private var controller: VoiceIDController?
    private var timer: Timer?
    private var fed = 0
    private var started = Date()
    /// After the audio: how long to wait for the last results and the voiceprint.
    static let settleSeconds = 20.0
    static let permissionSeconds = 120.0

    init(finish: @escaping ([String: Any], Int32) -> Never) { self.finish = finish }

    nonisolated static func name(_ s: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    /// Any WAV, as 16 kHz mono, cut by Silero into the frames the mic path hands Voice ID.
    func load(_ path: String) throws {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(VoiceID.sampleRate), channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(file.length) * target.sampleRate / file.processingFormat.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw CocoaError(.fileReadCorruptFile) }
        let given = Locked(false)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if given.withLock({ g in defer { g = true }; return g }) { status.pointee = .endOfStream; return nil }
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        let samples = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        audioSeconds = Double(samples.count) / Double(VoiceID.sampleRate)
        let vad = try SileroVAD()
        for i in stride(from: 0, to: samples.count, by: 4096) { frames += try vad.frames(Array(samples[i..<min(i + 4096, samples.count)])) }
    }

    func run() {
        var answered = false
        // Asks for permission the first time (the app has the usage text); the owner answers.
        Timer.scheduledTimer(withTimeInterval: Self.permissionSeconds, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard !answered else { return }
                self.finish(["authorization": Self.name(SFSpeechRecognizer.authorizationStatus()),
                             "error": "speech-recognition permission was not answered in \(Int(Self.permissionSeconds)) s"], 3)
            }
        }
        recognizer.prepare { availability in
            answered = true
            guard case .available = availability else {
                guard case .unavailable(let why) = availability else { return }
                self.finish(["authorization": Self.name(SFSpeechRecognizer.authorizationStatus()), "completed": false, "unavailable": why], 2)
            }
            self.start()
        }
    }

    private func start() {
        // Never saved: the owner's voiceprint stays as it is.
        let engine = VoiceIDEngine(save: { _ in })
        let c = VoiceIDController(mic: nil, engine: engine, defaults: UserDefaults(suiteName: "learner-voice-selftest") ?? .standard,
                                  modelPresent: VoiceID.modelURL != nil, voiceprint: nil, recognizer: recognizer)
        controller = c
        c.startReading(.available)
        started = Date()
        // As the mic path delivers it, in real time: 8 Silero frames (256 ms) per batch.
        let batch = 8
        let t = Timer(timeInterval: Double(batch) * SileroVAD.frameSeconds, repeats: true) { _ in
            MainActor.assumeIsolated { self.step(batch) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func step(_ batch: Int) {
        guard let c = controller else { return }
        if fed < frames.count {
            let slice = Array(frames[fed..<min(fed + batch, frames.count)])
            fed += slice.count
            c.engine.frames(slice)
            recognizer.append(slice)
        }
        c.tick()
        let fedAll = fed >= frames.count
        let waited = Date().timeIntervalSince(started) - audioSeconds
        let settled = !c.engine.enrollmentUnderway || c.engine.enrollmentPaused || c.readingMode != .tracked
        if fedAll, settled || waited > Self.settleSeconds { report(c) }
    }

    private func report(_ c: VoiceIDController) -> Never {
        timer?.invalidate()
        c.tracker.stop()
        if c.engine.enrollmentUnderway, !c.engine.enrollmentPaused { _ = c.engine.waitIdle(timeout: 30) }
        c.tick()
        let out = c.engine.output.value
        let snap = c.readingSnapshot
        var r: [String: Any] = [
            "authorization": Self.name(SFSpeechRecognizer.authorizationStatus()),
            "audioSeconds": (audioSeconds * 10).rounded() / 10,
            "speechSeconds": (out.enrollSpeechSeconds * 10).rounded() / 10,
            "sentences": c.sentences.count,
            "sentencesRead": snap.done.count,
            "words": c.tracker.total,
            "wordsMatched": c.tracker.matched.count,
            "wordsMisheard": c.tracker.misheard.count,
            "wordsCredited": ReadingAlignment.credited(c.tracker.matched, misheard: c.tracker.misheard, passage: c.tracker.passage).count,
            "reached": c.tracker.reached,
            "recognizerRestarts": c.tracker.restarts,
        ]
        if let f = c.tracker.failure { r["trackingFailure"] = f }
        if case .untracked(let why) = c.readingMode { r["fellBackToTime"] = why }
        if c.engine.enrollmentPaused { r["tooLittleSpeech"] = true }
        if let print = c.voiceprint {
            r["voiceprint"] = ["segments": print.segments, "speechSeconds": print.speechSeconds, "calibration": print.calibration,
                               "vector": print.vector.map(Double.init)]
        }
        let completed = c.reading.allRead && c.voiceprint != nil
        r["completed"] = completed
        finish(r, completed ? 0 : 1)
    }
}
