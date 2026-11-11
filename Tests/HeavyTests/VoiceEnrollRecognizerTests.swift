import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// Guided enrollment through Apple's real on-device speech recognizer. Speech-recognition
// permission belongs to an app, and a terminal cannot be granted it, so this runs the app
// bundle's own self-test: build-app.sh packages the binary (BUNDLE_ONLY, no install) into
// .build/voice-selftest/, `say` speaks the Rainbow Passage (170 wpm, 16 kHz mono), and
// `open` starts the app with --voice-enroll-selftest: frames -> Silero -> AppleReadingRecognizer
// -> tracker -> sentences -> a CAM++ voiceprint, at real time, reported as JSON and never saved.
// Then the same voice scores as the owner against that voiceprint and another does not.
// Nothing is played aloud and nothing comes from a microphone.
// Skips only when the app's permission is denied. Not yet asked, or restricted: fails with
// what to do and the one command the owner runs once to answer the prompt (the bundle's
// signing identity is stable, so the answer holds across rebuilds).

@Suite("Voice ID guided enrollment (the app's self-test, real on-device SFSpeechRecognizer)", .tags(.heavy, .voiceID),
       .timeLimit(.minutes(6)), .quietLog, .serialized,
       .enabled(if: Live.heavy, "heavy lane: set LEARNER_HEAVY=1"),
       .enabled(if: VoiceID.modelURL != nil, "the speaker model is not fetched: run scripts/fetch-voice-id.sh"))
struct VoiceEnrollRecognizerTests {
    static let owner = "Samantha", other = "Daniel", rate = 170
    static let ownerText = "I think the quarterly numbers look reasonable, but I would like to double check the travel costs before we send the report to the board."
    static let otherText = "The train to the coast leaves at half past nine, so we should pack the car tonight and leave the house by eight tomorrow."
    static let bundleDir = toolsRepoRoot() + "/.build/voice-selftest"
    static let app = bundleDir + "/Learner Desktop.app"
    static var authorizeCommand: String { "open -n -W -a \"\(app)\" --args --voice-enroll-selftest --authorize" }

    /// The app bundle around the binary this lane built (release in scripts/test.sh heavy, else debug).
    static func buildBundle() throws {
        var env = ProcessInfo.processInfo.environment
        env["BUNDLE_ONLY"] = "1"
        env["OUT_DIR"] = bundleDir
        env["LEARNER_BINARY"] = env["LEARNER_RELEASE_BINARY"] ?? toolsRepoRoot() + "/.build/debug/LearnerDesktop"
        try #require(FileManager.default.isExecutableFile(atPath: env["LEARNER_BINARY"]!), "no binary at \(env["LEARNER_BINARY"]!): swift build first")
        try FileManager.default.createDirectory(atPath: bundleDir, withIntermediateDirectories: true)
        let r = ChildProcess.run("/bin/bash", [toolsRepoRoot() + "/scripts/build-app.sh"], timeout: 120, env: env, stderr: true)
        try #require(r.status == 0, "build-app.sh failed: \(r.output.suffix(600))")
    }

    /// Runs the bundle's self-test through `open` (so it is the app, with the app's permission)
    /// and returns its JSON. A scratch Application Support and data folder: nothing real is touched.
    static func selfTest(_ args: [String], timeout: TimeInterval) throws -> [String: Any] {
        let dir = TempDir("voice-selftest")
        let json = dir.file("result.json"), log = dir.file("log.txt")
        let r = ChildProcess.run("/usr/bin/open", ["-n", "-W", "-o", log, "--stderr", log,
                                                   "--env", "LEARNER_APP_SUPPORT=\(dir.file("app-support"))",
                                                   "--env", "LEARNER_DATA_DIR=\(dir.file("data"))",
                                                   "-a", app, "--args", "--voice-enroll-selftest"] + args + ["--out", json],
                                 timeout: timeout, stderr: true)
        let output = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        try #require(r.status == 0, "open failed: \(r.output) \(output.suffix(400))")
        let data = try #require(FileManager.default.contents(atPath: json), "no result from the self-test; its output: \(output.suffix(800))")
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func speechWav(_ text: String, voice: String, to wav: String) throws {
        let file = wav + ".txt"
        try text.write(toFile: file, atomically: true, encoding: .utf8)
        let r = ChildProcess.run("/usr/bin/say", ["-v", voice, "-r", String(rate), "-f", file, "-o", wav,
                                                  "--file-format=WAVE", "--data-format=LEI16@16000"], timeout: 90, stderr: true)
        try #require(r.ok, "say failed: \(r.output)")
    }

    static func meanScore(_ text: String, voice: String, against print: [Float], model: SherpaSpeakerEmbedder) throws -> (Float, Int) {
        let dir = TempDir("say")
        let wav = dir.file("speech.wav")
        try speechWav(text, voice: voice, to: wav)
        let data = try Data(contentsOf: URL(fileURLWithPath: wav))
        let at = try #require(data.range(of: Data("data".utf8)))
        let samples = data[(at.upperBound + 4)...].withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { Float($0) / 32768 }
        let vad = try SileroVAD()
        var window = SlidingWindow()
        var scores: [Float] = []
        for i in stride(from: 0, to: samples.count, by: 4096) {
            for f in try vad.frames(Array(samples[i..<min(i + 4096, samples.count)])) {
                guard let w = window.add(f.samples, speech: f.probability >= VoiceID.speechProbability), w.isSpeech else { continue }
                scores.append(VoiceMath.cosine(model.embed(w.samples), print))
            }
        }
        return (scores.reduce(0, +) / Float(max(1, scores.count)), scores.count)
    }

    @Test func theAppFollowsTheSpokenPassageWithTheRealRecognizerAndEnrolls() throws {
        try Self.buildBundle()
        let status = try Self.selfTest(["--status"], timeout: 60)
        let auth = status["authorization"] as? String ?? "unknown"
        Swift.print("VOICE-ID self-test: the app's speech-recognition permission is \(auth)")
        if auth == "denied" {
            try Test.cancel(Comment(rawValue: "speech recognition is denied for Learner Desktop (System Settings › Privacy & Security › Speech Recognition)"))
        }
        if auth == "restricted" {
            Issue.record(Comment(rawValue: "speech recognition is restricted on this Mac (a configuration profile or Screen Time limits it): lift the restriction for Learner Desktop, then run once and allow the prompt:\n  \(Self.authorizeCommand)"))
            return
        }
        guard auth == "authorized" else {
            Issue.record(Comment(rawValue: "Learner Desktop has not been asked for speech-recognition permission yet (status: \(auth)). Run once and allow the prompt:\n  \(Self.authorizeCommand)"))
            return
        }

        let dir = TempDir("voice-selftest-audio")
        let wav = dir.file("passage.wav")
        try Self.speechWav(ReadingPassage.paragraphs.joined(separator: "\n\n"), voice: Self.owner, to: wav)
        let r = try Self.selfTest([wav], timeout: 240)
        Swift.print("VOICE-ID self-test result: \(r.filter { $0.key != "voiceprint" })")
        #expect(r["completed"] as? Bool == true, "the passage was not completed: \(r.filter { $0.key != "voiceprint" })")
        #expect(r["exitCode"] as? Int == 0)
        #expect(r["sentencesRead"] as? Int == ReadingSentences().count)
        let words = r["words"] as? Int ?? 0, matched = r["wordsMatched"] as? Int ?? 0
        #expect(words == ReadingPassage.words.count)
        #expect(Double(matched) >= 0.6 * Double(words), "only \(matched) of \(words) words recognized")
        #expect((r["speechSeconds"] as? Double ?? 0) >= ReadingCompletion.minSpeechSeconds)
        #expect(r["trackingFailure"] == nil && r["fellBackToTime"] == nil)

        let vp = try #require(r["voiceprint"] as? [String: Any], "no voiceprint made")
        let vector = try #require(vp["vector"] as? [Double]).map(Float.init)
        let model = try SherpaSpeakerEmbedder(model: try #require(VoiceID.modelURL))
        #expect(model.dimension == vector.count)
        let (same, n1) = try Self.meanScore(Self.ownerText, voice: Self.owner, against: vector, model: model)
        let (other, n2) = try Self.meanScore(Self.otherText, voice: Self.other, against: vector, model: model)
        try #require(n1 >= 4 && n2 >= 4)
        Swift.print(String(format: "VOICE-ID self-test: same voice %.2f, other voice %.2f", same, other))
        #expect(same >= VoiceID.threshold, "same voice scored \(same)")
        #expect(other < VoiceID.threshold, "other voice scored \(other)")
    }
}
