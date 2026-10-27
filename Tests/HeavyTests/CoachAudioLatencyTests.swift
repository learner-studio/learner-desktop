import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// Audio -> screenpipe's configured speech-to-text -> the coach -> the warning, timed.
// Synthesized speech (macOS `say`) is cut into 2.25 s chunks and uploaded on a real-time
// schedule to screenpipe's /v1/audio/transcriptions; each answer becomes a live-meeting
// span, as the live transcript table would deliver it. Nothing is played aloud and no
// screenpipe setting or table is touched. This measures upload STT plus the coach, not
// screenpipe's capture pipeline -- the baseline a sub-second on-device detector must beat.

private let env = ProcessInfo.processInfo.environment
private let screenpipe = URL(string: env["SCREENPIPE_API"] ?? "http://localhost:3030")!

private let passage = """
    I would like to explain the plan for our next project in a little more detail. The first step is to \
    understand what people need from the product and what gets in their way today. We can start with a few \
    conversations and then compare the answers. After that we should choose one small problem that we can \
    solve and measure clearly. I think the team will work better if everyone knows what a successful result \
    looks like before we begin. We also need time to check the details and make sure that the changes do what \
    we intended. When the first version is ready we can ask people to try it and tell us where they get \
    confused. We should listen carefully to those comments instead of assuming that our original plan was \
    right about everything. Some improvements may be simple while others will need more thought.
    """

/// 16 kHz mono 16-bit samples of `passage` spoken at about `wpm` words a minute.
private func speech(wpm: Int, dir: String) throws -> [Int16] {
    let text = dir + "/passage.txt", wav = dir + "/speech-\(wpm).wav"
    try passage.write(toFile: text, atomically: true, encoding: .utf8)
    let r = ChildProcess.run("/usr/bin/say", ["-r", String(wpm), "-f", text, "-o", wav, "--file-format=WAVE", "--data-format=LEI16@16000"], timeout: 60, stderr: true)
    guard r.ok, let data = FileManager.default.contents(atPath: wav), let range = data.range(of: Data("data".utf8)) else {
        throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "say failed: \(r.output)"])
    }
    let pcm = data[(range.upperBound + 4)...]
    return pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
}

private func wavFile(_ samples: ArraySlice<Int16>) -> Data {
    func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    let bytes = UInt32(samples.count * 2)
    var d = Data("RIFF".utf8) + le(36 + bytes) + Data("WAVEfmt ".utf8)
    d += le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1)) + le(UInt32(16000)) + le(UInt32(32000)) + le(UInt16(2)) + le(UInt16(16))
    d += Data("data".utf8) + le(bytes)
    samples.withUnsafeBytes { d.append(contentsOf: $0) }
    return d
}

private func transcribe(_ wav: Data) async throws -> String {
    let boundary = "coach" + UUID().uuidString
    var req = URLRequest(url: screenpipe.appendingPathComponent("v1/audio/transcriptions"))
    req.httpMethod = "POST"
    req.timeoutInterval = 25
    req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    if let key = env["SCREENPIPE_LOCAL_API_KEY"] { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
    var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"chunk.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
    body += wav + Data("\r\n--\(boundary)--\r\n".utf8)
    let (data, _) = try await URLSession.shared.upload(for: req, from: body)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["text"] as? String ?? ""
}

/// Delivers the spans the test pushes.
final class PushedSpeech: SpeechSource {
    var queued: [SpeechSpan] = []
    func poll(now: Date, deliver: @escaping ([SpeechSpan]) -> Void) {
        let q = queued
        queued = []
        deliver(q)
    }
}

final class NoCalls: CallSource {
    func poll(deliver: @escaping (CallPoll) -> Void) { deliver(.answered(CallState(app: "Audio benchmark", title: nil))) }
}

@Suite("Coach, heavy: audio to warning latency",
       .enabled(if: env["LEARNER_HEAVY"] == "1", "heavy lane: set LEARNER_HEAVY=1"),
       .enabled(if: env["LEARNER_HEAVY_AUDIO"] == "1", "runs screenpipe's STT for ~80 s: set LEARNER_HEAVY_AUDIO=1"),
       .serialized)
struct CoachAudioLatencyTests {
    @MainActor
    @Test(arguments: [120, 200])
    func theWarningFollowsThirtySecondsOfSpeechWithinSixSeconds(wpm: Int) async throws {
        let dir = NSTemporaryDirectory() + "coach-audio-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let samples = try speech(wpm: wpm, dir: dir)
        #expect(samples.count > 34 * 16000, "the passage is shorter than the threshold at \(wpm) wpm")

        let pushed = PushedSpeech()
        let toast = TimedToast()
        let settings = CoachSettings(defaults: ScratchDefaults("coach-audio"))
        settings.assignmentMode = .baseline
        let (logger, _) = heavyLogger()
        let coach = SpeakingCoach(settings: settings, speech: pushed, calls: NoCalls(), wearable: SilentWearable(),
                                  toast: toast, logger: logger)
        coach.tick()

        let chunk = 36000   // 2.25 s: screenpipe's 2 s minimum plus its 750 ms flush cadence
        let origin = Date().addingTimeInterval(1)
        var stt: [Double] = []
        for (i, start) in stride(from: 0, to: min(samples.count, 36 * 16000), by: chunk).enumerated() where toast.firstShown == nil {
            let end = min(start + chunk, samples.count)
            let due = origin.addingTimeInterval(Double(end) / 16000)
            if due > Date() { try await Task.sleep(nanoseconds: UInt64(due.timeIntervalSinceNow * 1e9)) }
            let sent = Date()
            let text = try await transcribe(wavFile(samples[start..<end]))
            stt.append(Date().timeIntervalSince(sent))
            let at = origin.addingTimeInterval(Double(start) / 16000)
            guard ScreenpipeSpeechSource.isSpeech(text) else { continue }
            pushed.queued.append(SpeechSpan(speaker: .me, start: at, end: at, words: ScreenpipeSpeechSource.words(text),
                                            audioClock: true, capturedAt: at, path: "live_meeting", label: "chunk \(i)"))
            coach.tick()
        }
        let shown = try #require(toast.firstShown, "no warning; STT seconds per chunk: \(stt)")
        let delay = shown.timeIntervalSince(origin.addingTimeInterval(30))
        Log("Coach").info("audio benchmark \(wpm) wpm: warning \(String(format: "%.2f", delay)) s after 30 s of audio; median STT \(String(format: "%.2f", stt.sorted()[stt.count / 2])) s")
        #expect(delay >= 0, "warned early")
        #expect(delay < 6, "warning came \(delay) s after the 30 s mark")
        coach.resetStreak()
        logger.close()
    }
}
