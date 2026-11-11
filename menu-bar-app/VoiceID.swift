import AppKit
import Foundation
import SherpaOnnx
import SherpaOnnxC

// MARK: - Voice ID: "am I talking?"

// The owner's voice versus anyone else's, from the coach's own microphone frames (no second
// tap): while Silero hears speech, a 1.5 s window is embedded every 0.5 s (3D-Speaker CAM++
// through sherpa-onnx, on its own queue) and scored against a voiceprint enrolled from the
// owner reading a passage aloud (VoiceEnrollReading.swift). Nothing about other speakers: no clustering, no names. No audio
// is kept; the voiceprint is one averaged embedding in Application Support.

enum VoiceID {
    static let sampleRate = 16_000
    static let modelFile = "3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx"
    /// Cosine score at or above which the (smoothed) windows are the owner's voice: the
    /// default of sherpa-onnx's speaker-identification examples
    /// (python-api-examples/speaker-identification*.py, --threshold 0.6).
    static let threshold: Float = 0.6
    static let windowSeconds = 1.5
    static let hopSeconds = 0.5
    /// "Me" is decided on the mean score of this many consecutive speech windows.
    static let smoothingWindows = 2
    /// Silero's speech cut-off per 32 ms frame (the coach's own).
    static let speechProbability: Float = 0.5
    /// A window is speech, and worth the model, when at least this share of it is.
    static let minSpeechFraction = 0.5
    static let enrollSeconds = 60.0
    /// Enrollment speech kept at most (about 11 MB): a reading that never ends cannot grow it.
    static let maxEnrollSeconds = 180.0
    /// Enrollment speech is cut into segments this long (10 from 60 s); a shorter tail of at
    /// least `minSegmentSeconds` is kept as one more.
    static let segmentSeconds = 6.0
    static let minSegmentSeconds = 5.0
    /// Frames further apart than this (the mic stopped: a call, a device switch) start a new window.
    static let gapSeconds = 1.0
    /// A decision older than this (no frames) shows as silence.
    static let staleSeconds = 2.0

    /// The bundled model (Contents/Resources); LEARNER_VOICE_ID_MODEL overrides; from a source
    /// checkout, menu-bar-app/Models (scripts/fetch-voice-id.sh puts it there).
    static var modelURL: URL? {
        if let p = ProcessInfo.processInfo.environment["LEARNER_VOICE_ID_MODEL"] {
            return FileManager.default.fileExists(atPath: p) ? URL(fileURLWithPath: p) : nil
        }
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent(modelFile),
                          URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Models/\(modelFile)")]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var voiceprintURL: URL { URL(fileURLWithPath: Paths.appSupport + "/voice-id/voiceprint.json") }

    static func samples(_ seconds: Double) -> Int { Int(seconds * Double(sampleRate)) }
}

// MARK: - Scoring (pure)

enum VoiceMath {
    /// Cosine similarity; 0 for empty, mismatched or zero vectors.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }

    /// The element-wise mean of equal-length vectors.
    static func mean(_ vs: [[Float]]) -> [Float] {
        guard let first = vs.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vs where v.count == sum.count { for i in v.indices { sum[i] += v[i] } }
        return sum.map { $0 / Float(vs.count) }
    }
}

/// The last 1.5 s of frames, handed out every 0.5 s with the share of it Silero called speech.
struct SlidingWindow {
    struct Window: Equatable {
        let samples: [Float]
        let speechFraction: Double
        var isSpeech: Bool { speechFraction >= VoiceID.minSpeechFraction }
    }
    let size: Int
    let hop: Int
    private(set) var samples: [Float] = []
    /// Per frame still (partly) in the window: its samples left and whether it was speech.
    private var frames: [(count: Int, speech: Bool)] = []
    private var sinceEmit = 0

    init(size: Int = VoiceID.samples(VoiceID.windowSeconds), hop: Int = VoiceID.samples(VoiceID.hopSeconds)) {
        self.size = size
        self.hop = hop
    }

    mutating func add(_ frame: [Float], speech: Bool) -> Window? {
        samples += frame
        frames.append((frame.count, speech))
        sinceEmit += frame.count
        var excess = samples.count - size
        if excess > 0 {
            samples.removeFirst(excess)
            while excess > 0, !frames.isEmpty {
                let take = min(excess, frames[0].count)
                frames[0].count -= take
                excess -= take
                if frames[0].count == 0 { frames.removeFirst() }
            }
        }
        guard samples.count == size, sinceEmit >= hop else { return nil }
        // Keeps the 0.5 s cadence when frames do not divide it; the first fill counts once.
        sinceEmit = (sinceEmit - hop) % hop
        let speech = frames.reduce(0) { $0 + ($1.speech ? $1.count : 0) }
        return Window(samples: samples, speechFraction: Double(speech) / Double(size))
    }

    mutating func reset() {
        samples = []
        frames = []
        sinceEmit = 0
    }
}

enum VoiceDecision: Equatable, Sendable {
    case me(Float)
    case notMe(Float)
    case silence
}

/// "Me" on the mean of the last `count` speech windows' scores; silence clears them, so a
/// new utterance is judged on itself.
struct VoiceSmoother {
    let threshold: Float
    let count: Int
    private(set) var scores: [Float] = []

    init(threshold: Float = VoiceID.threshold, count: Int = VoiceID.smoothingWindows) {
        self.threshold = threshold
        self.count = count
    }

    mutating func add(_ score: Float) -> VoiceDecision {
        scores.append(score)
        if scores.count > count { scores.removeFirst(scores.count - count) }
        let mean = scores.reduce(0, +) / Float(scores.count)
        return mean >= threshold ? .me(mean) : .notMe(mean)
    }

    mutating func silence() -> VoiceDecision {
        scores = []
        return .silence
    }
}

/// Enrollment speech -> segments of `segment` samples; a tail of at least `minimum` is one more.
enum EnrollmentCut {
    static func segments(_ speech: [Float], segment: Int = VoiceID.samples(VoiceID.segmentSeconds),
                         minimum: Int = VoiceID.samples(VoiceID.minSegmentSeconds)) -> [[Float]] {
        guard segment > 0 else { return [] }
        return stride(from: 0, to: speech.count, by: segment).compactMap { start in
            let end = min(start + segment, speech.count)
            return end - start >= minimum ? Array(speech[start..<end]) : nil
        }
    }

    /// One segment's embedding, made the way live windows are: the mean of its 1.5 s windows
    /// (0.5 s apart), each normalized. CAM++ scores between clips of different lengths are not
    /// comparable (measured on `say` voices: a 6 s embedding against 1.5 s windows scored the
    /// same voice about 0.3, against about 0.9 when lengths matched), so the voiceprint is made
    /// at the length it is compared at.
    static func embedding(of segment: [Float], window: Int = VoiceID.samples(VoiceID.windowSeconds),
                          hop: Int = VoiceID.samples(VoiceID.hopSeconds), embed: ([Float]) -> [Float]) -> [Float] {
        guard segment.count >= window else { return embed(segment) }
        let windows = stride(from: 0, through: segment.count - window, by: hop).map { embed(Array(segment[$0..<$0 + window])) }
        let usable = windows.filter { !$0.isEmpty }
        return usable.isEmpty ? [] : VoiceMath.normalized(VoiceMath.mean(usable.map(VoiceMath.normalized)))
    }

    /// The voiceprint: the segments' embeddings, each normalized, averaged, normalized again;
    /// with how well each segment matches it (the calibration note).
    static func voiceprint(_ embeddings: [[Float]], model: String, speechSeconds: Double, at: Date) -> Voiceprint? {
        let usable = embeddings.filter { !$0.isEmpty }
        guard !usable.isEmpty else { return nil }
        let vector = VoiceMath.normalized(VoiceMath.mean(usable.map(VoiceMath.normalized)))
        let scores = usable.map { VoiceMath.cosine($0, vector) }
        let mean = scores.reduce(0, +) / Float(scores.count)
        let note = String(format: "%d segments, %.0f s of speech; each against the voiceprint: min %.2f, mean %.2f (threshold %.2f)",
                          usable.count, speechSeconds, scores.min() ?? 0, mean, VoiceID.threshold)
        // Whole seconds: what the file keeps (ISO 8601).
        let at = Date(timeIntervalSince1970: at.timeIntervalSince1970.rounded(.down))
        return Voiceprint(vector: vector, model: model, enrolledAt: at, segments: usable.count,
                          speechSeconds: speechSeconds, calibration: note)
    }
}

/// The owner's enrolled voice: one L2-normalized embedding, and what made it.
struct Voiceprint: Codable, Equatable, Sendable {
    var vector: [Float]
    var model: String
    var enrolledAt: Date
    var segments: Int
    var speechSeconds: Double
    var calibration: String

    /// nil when there is none, or it is unreadable or from another model.
    static func load(_ url: URL = VoiceID.voiceprintURL, model: String = VoiceID.modelFile) -> Voiceprint? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let print = try? d.decode(Voiceprint.self, from: data), print.model == model, !print.vector.isEmpty else { return nil }
        return print
    }

    func save(_ url: URL = VoiceID.voiceprintURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - The model

protocol SpeakerEmbedder: AnyObject {
    /// One embedding of 16 kHz mono samples; empty when the audio is too short.
    func embed(_ samples: [Float]) -> [Float]
}

/// sherpa-onnx's speaker-embedding extractor on CPU. Not thread-safe: one queue uses it.
final class SherpaSpeakerEmbedder: SpeakerEmbedder {
    private let extractor: SherpaOnnxSpeakerEmbeddingExtractorWrapper

    init(model: URL, threads: Int = 1) throws {
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "\(model.lastPathComponent) not found (run scripts/fetch-voice-id.sh)"])
        }
        // C strings that outlive the call (the wrapper's own helper hands out a temporary's).
        let made = model.path.withCString { path in
            "cpu".withCString { provider in
                var config = SherpaOnnxSpeakerEmbeddingExtractorConfig(model: path, num_threads: Int32(threads), debug: 0, provider: provider)
                return SherpaOnnxSpeakerEmbeddingExtractorWrapper(config: &config)
            }
        }
        guard made.impl != nil else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "sherpa-onnx could not load \(model.lastPathComponent)"])
        }
        extractor = made
    }

    var dimension: Int { extractor.dim }

    func embed(_ samples: [Float]) -> [Float] {
        let stream = extractor.createStream()
        stream.acceptWaveform(samples: samples, sampleRate: VoiceID.sampleRate)
        stream.inputFinished()
        return extractor.compute(stream: stream)
    }
}

// MARK: - Engine (off the main thread)

/// Takes Silero's frames on the VAD queue (cheap: buffer, and at most hand one window over),
/// runs the model on its own queue, and leaves results for the main thread to read. A speech
/// window that arrives while the model is still busy is dropped, never queued: the mic and
/// VAD queues never wait on it.
final class VoiceIDEngine: @unchecked Sendable {
    let queue = DispatchQueue(label: "learner.voiceid", qos: .utility)
    private let log = Log("VoiceID")
    private let makeEmbedder: @Sendable () throws -> SpeakerEmbedder
    private let save: @Sendable (Voiceprint) throws -> Void
    private let modelName: String

    // On `queue` only.
    private var embedder: SpeakerEmbedder?
    private var smoother = VoiceSmoother()
    private var voiceprint: [Float]?

    /// What the VAD queue keeps between batches.
    struct Feed: Sendable {
        var window = SlidingWindow()
        var busy = false
        var lastFrameAt: Date?
        /// Scoring live windows (a voiceprint is set, and the indicator wants them).
        var live = false
        var enrollment: [Float]?
        /// Bumped by every start and cancel: a voiceprint computed for an older round is dropped.
        var enrollRound = 0
        /// nil: until `finishEnrollment` (a guided reading decides when it is done).
        var enrollTarget: Int? = VoiceID.samples(VoiceID.enrollSeconds)
        /// Kept, not listening: the reading ended short of speech and may be read again.
        var enrollPaused = false
    }
    private let feed = Locked(Feed())

    enum EnrollResult: Equatable, Sendable { case done(Voiceprint), failed(String) }

    /// What the main thread reads (at most 4 times a second).
    struct Output: Sendable {
        var decision: VoiceDecision?
        var decidedAt: Date?
        var lastScore: Float?
        var latencyMs: Double?
        var dropped = 0
        var scored = 0
        var problem: String?
        /// 0...1 while enrolling.
        var enrollProgress: Double?
        var enrollResult: EnrollResult?
        /// Speech heard so far this enrollment, and when Silero last called a frame speech.
        var enrollSpeechSeconds = 0.0
        var lastSpeechAt: Date?
    }
    let output = Locked(Output())

    init(modelName: String = VoiceID.modelFile,
         makeEmbedder: @escaping @Sendable () throws -> SpeakerEmbedder = {
             guard let url = VoiceID.modelURL else {
                 throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "voice model missing (run scripts/fetch-voice-id.sh)"])
             }
             return try SherpaSpeakerEmbedder(model: url)
         },
         save: @escaping @Sendable (Voiceprint) throws -> Void = { try $0.save() }) {
        self.modelName = modelName
        self.makeEmbedder = makeEmbedder
        self.save = save
    }

    /// Sets (or clears) the voiceprint live windows are scored against.
    func use(_ print: Voiceprint?) {
        let vector = print?.vector
        queue.async { self.voiceprint = vector; self.smoother = VoiceSmoother() }
    }

    func setLive(_ on: Bool) {
        feed.withLock { f in
            f.live = on
            f.window.reset()
        }
        if !on { output.withLock { $0.decision = nil; $0.decidedAt = nil } }
    }

    /// Loads the model ahead of the first window (a second or so), on the model queue.
    func warmUp() { queue.async { _ = self.loadedEmbedder() } }

    /// `seconds` of speech, or nil: until `finishEnrollment`.
    func startEnrollment(seconds: Double? = VoiceID.enrollSeconds) {
        feed.withLock { f in
            f.enrollment = []
            f.enrollTarget = seconds.map(VoiceID.samples)
            f.enrollPaused = false
            f.enrollRound += 1
        }
        output.withLock { $0.enrollProgress = 0; $0.enrollResult = nil; $0.enrollSpeechSeconds = 0; $0.lastSpeechAt = nil }
    }

    /// An open-ended enrollment turns time-based (the reading can no longer be followed).
    func setEnrollmentTarget(seconds: Double) {
        feed.withLock { if $0.enrollment != nil { $0.enrollTarget = VoiceID.samples(seconds) } }
    }

    /// Stops taking speech but keeps what was heard (the reading ended short of speech).
    func pauseEnrollment() {
        feed.withLock { if $0.enrollment != nil { $0.enrollPaused = true } }
    }

    /// Listens again, adding to the speech kept; `seconds` as in `startEnrollment`.
    func resumeEnrollment(seconds: Double?) {
        feed.withLock { f in
            guard f.enrollment != nil else { return }
            f.enrollPaused = false
            f.enrollTarget = seconds.map(VoiceID.samples)
        }
    }

    var enrollmentPaused: Bool { feed.withLock { $0.enrollment != nil && $0.enrollPaused } }

    /// The voiceprint from the speech heard so far (the reading is done). False when no
    /// enrollment was listening.
    @discardableResult
    func finishEnrollment() -> Bool {
        let taken: ([Float], Int)? = feed.withLock { f in
            guard let speech = f.enrollment else { return nil }
            f.enrollment = nil
            f.window.reset()
            return (speech, f.enrollRound)
        }
        guard let (speech, round) = taken else { return false }
        output.withLock { $0.enrollProgress = 1 }
        queue.async { self.run(.enroll(speech, round)) }
        return true
    }

    /// Stops listening, and drops a voiceprint already being made: nothing is saved.
    func cancelEnrollment() {
        feed.withLock { $0.enrollment = nil; $0.enrollPaused = false; $0.enrollRound += 1 }
        output.withLock { $0.enrollProgress = nil }
    }

    /// Whether an enrollment is listening or its voiceprint is being made.
    var enrollmentUnderway: Bool { feed.withLock { $0.enrollment != nil } || output.withLock { $0.enrollProgress != nil } }

    /// Listening for enrollment speech (not paused).
    var enrolling: Bool { feed.withLock { $0.enrollment != nil && !$0.enrollPaused } }

    private enum Work: Sendable {
        case score([Float])
        case silence
        case enroll([Float], Int)
    }

    /// On the VAD queue: one batch of Silero's frames. Returns at once.
    func frames(_ frames: [SileroVAD.Frame], now: Date = Date()) {
        var progress: Double?
        var heardSpeech: Double?
        var spoke = false
        let work: [Work] = feed.withLock { f in
            if let last = f.lastFrameAt, now.timeIntervalSince(last) > VoiceID.gapSeconds { f.window.reset() }
            f.lastFrameAt = now
            var work: [Work] = []
            for frame in frames {
                let speech = frame.probability >= VoiceID.speechProbability
                if f.enrollment != nil, f.enrollPaused {
                    continue   // kept for a second reading; neither enrolling nor scoring live
                }
                if f.enrollment != nil {
                    // Only what Silero calls speech: pauses would dilute the voiceprint. Appended in
                    // place (a copy per frame would be megabytes on this queue, under this lock).
                    if speech {
                        spoke = true
                        if f.enrollment!.count < VoiceID.samples(VoiceID.maxEnrollSeconds) { f.enrollment!.append(contentsOf: frame.samples) }
                    }
                    let heard = f.enrollment!.count
                    heardSpeech = Double(heard) / Double(VoiceID.sampleRate)
                    if let target = f.enrollTarget, heard >= target {
                        work.append(.enroll(f.enrollment!, f.enrollRound))
                        f.enrollment = nil
                        f.window.reset()   // live scoring starts afresh, not mid-window from before
                    } else if let target = f.enrollTarget {
                        progress = Double(heard) / Double(target)
                    }
                    continue   // no live scoring while enrolling
                }
                guard f.live, let window = f.window.add(frame.samples, speech: speech) else { continue }
                if !window.isSpeech {
                    work.append(.silence)
                } else if f.busy {
                    work.append(.score([]))   // counted as dropped
                } else {
                    f.busy = true
                    work.append(.score(window.samples))
                }
            }
            return work
        }
        if progress != nil || heardSpeech != nil {
            output.withLock { o in
                if let progress { o.enrollProgress = progress }
                if let heardSpeech { o.enrollSpeechSeconds = heardSpeech }
                if spoke { o.lastSpeechAt = now }
            }
        }
        for w in work {
            if case .score(let s) = w, s.isEmpty {
                output.withLock { $0.dropped += 1 }
                continue
            }
            queue.async { self.run(w) }
        }
    }

    private func loadedEmbedder() -> SpeakerEmbedder? {
        if let e = embedder { return e }
        do {
            let started = Date()
            let e = try makeEmbedder()
            embedder = e
            log.info("speaker model loaded in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            output.withLock { $0.problem = nil }
            return e
        } catch {
            let why = error.localizedDescription
            let first = output.withLock { o -> Bool in
                defer { o.problem = why }
                return o.problem != why
            }
            if first { log.error("speaker model unavailable: \(why)") }
            return nil
        }
    }

    private func run(_ work: Work) {
        switch work {
        case .silence:
            let d = smoother.silence()
            output.withLock { $0.decision = d; $0.decidedAt = Date() }
        case .score(let samples):
            defer { feed.withLock { $0.busy = false } }
            guard let print = voiceprint, let model = loadedEmbedder() else { return }
            let started = Date()
            let embedding = model.embed(samples)
            let ms = Date().timeIntervalSince(started) * 1000
            guard !embedding.isEmpty else { return }
            let score = VoiceMath.cosine(embedding, print)
            let d = smoother.add(score)
            output.withLock { o in
                o.decision = d
                o.decidedAt = Date()
                o.lastScore = score
                o.latencyMs = ms
                o.scored += 1
            }
            let verdict: String
            switch d { case .me(let m): verdict = String(format: "me (mean %.2f)", m)
                       case .notMe(let m): verdict = String(format: "not me (mean %.2f)", m)
                       case .silence: verdict = "silence" }
            log.noisy(String(format: "window score %.2f -> %@ in %.0f ms", score, verdict, ms))
        case .enroll(let speech, let round):
            let current = { self.feed.withLock { $0.enrollRound } == round }
            guard current() else { return }   // cancelled before the model got to it
            let result = enroll(speech, stillWanted: current)
            guard let result else { return }   // cancelled while it was being made: nothing saved
            output.withLock { $0.enrollProgress = nil; $0.enrollResult = result }
        }
    }

    /// On `queue`: the voiceprint from the enrollment speech, saved; live scoring uses it next.
    /// nil when `stillWanted` turns false before the save (the owner cancelled).
    private func enroll(_ speech: [Float], stillWanted: () -> Bool = { true }) -> EnrollResult? {
        guard let model = loadedEmbedder() else {
            return .failed(output.withLock { $0.problem } ?? "the voice model could not be loaded")
        }
        let started = Date()
        let segments = EnrollmentCut.segments(speech)
        let embeddings = segments.map { EnrollmentCut.embedding(of: $0, embed: model.embed) }
        guard let print = EnrollmentCut.voiceprint(embeddings, model: modelName,
                                                   speechSeconds: Double(speech.count) / Double(VoiceID.sampleRate), at: Date()) else {
            return .failed("no usable speech segments")
        }
        guard stillWanted() else {
            log.info("enrollment cancelled while the voiceprint was being made: not saved")
            return nil
        }
        do { try save(print) } catch {
            log.error("voiceprint not saved: \(error.localizedDescription)")
            return .failed("could not save the voiceprint: \(error.localizedDescription)")
        }
        voiceprint = print.vector
        smoother = VoiceSmoother()
        log.info("enrolled: \(print.calibration); \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        return .done(print)
    }

    /// For tests: waits until the model queue has done what was handed to it.
    func drain() { queue.sync {} }

    /// At quit: waits (bounded) for model work already handed to the queue. A model load still
    /// running when the process exits races onnxruntime's static destructors and segfaults.
    @discardableResult
    func waitIdle(timeout: TimeInterval) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }
}

// MARK: - What the indicator shows (pure)

enum VoiceIndicatorState: Equatable {
    case me(Float)
    case notMe(Float)
    case silence(Float?)
    case micOff
    case notEnrolled
    case modelMissing

    var text: String {
        let score = { (s: Float) in String(format: " · %.2f", s) }
        switch self {
        case .me(let s): return "🎙 You're talking" + score(s)
        case .notMe(let s): return "Not you" + score(s)
        case .silence(let s): return "Silence" + (s.map(score) ?? "")
        case .micOff: return "Mic paused"
        case .notEnrolled: return "Enroll your voice first"
        case .modelMissing: return "Voice model missing"
        }
    }

    var talking: Bool { if case .me = self { return true } else { return false } }

    static func from(modelPresent: Bool, enrolled: Bool, micListening: Bool,
                     output: VoiceIDEngine.Output, now: Date) -> VoiceIndicatorState {
        guard modelPresent else { return .modelMissing }
        guard enrolled else { return .notEnrolled }
        guard micListening else { return .micOff }
        guard let d = output.decision, let at = output.decidedAt, now.timeIntervalSince(at) <= VoiceID.staleSeconds else {
            return .silence(output.lastScore)
        }
        switch d {
        case .me(let s): return .me(s)
        case .notMe(let s): return .notMe(s)
        case .silence: return .silence(output.lastScore)
        }
    }
}

// MARK: - Indicator pill

/// A small floating pill, in the coach toast's style: non-activating, never in screen shares
/// (sharingType = .none), clicks pass through. Bottom right, clear of the coach and mastery
/// toasts (top right).
@MainActor
final class VoiceIndicatorController {
    static let size = NSSize(width: 230, height: 34)
    private(set) var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    private(set) var state: VoiceIndicatorState?
    var isShowing: Bool { panel?.isVisible == true }

    private func makePanel() -> NSPanel {
        let size = Self.size
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        // Hidden from ScreenCaptureKit, Zoom, Meet, Teams, Slack, OBS and QuickTime.
        p.sharingType = .none
        let ve = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        ve.material = .hudWindow
        ve.blendingMode = .behindWindow
        ve.state = .active
        ve.wantsLayer = true
        ve.layer?.cornerRadius = size.height / 2
        ve.layer?.masksToBounds = true
        ve.layer?.borderWidth = 1
        dot.frame = NSRect(x: 14, y: (size.height - 10) / 2, width: 10, height: 10)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        label.frame = NSRect(x: 32, y: (size.height - 18) / 2, width: size.width - 44, height: 18)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        [dot, label].forEach(ve.addSubview)
        p.contentView = ve
        return p
    }

    static func origin(in visible: NSRect) -> NSPoint {
        NSPoint(x: max(visible.minX + 20, visible.maxX - size.width - 24), y: visible.minY + 24)
    }

    func show() {
        let p = panel ?? makePanel()
        panel = p
        if state == nil { update(.silence(nil)) }
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        p.setFrameOrigin(Self.origin(in: vf))
        p.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    var text: String { label.stringValue }

    func update(_ next: VoiceIndicatorState) {
        guard next != state else { return }
        state = next
        let green = NSColor(calibratedRed: 0.25, green: 0.85, blue: 0.4, alpha: 1)
        let grey = NSColor(white: 0.7, alpha: 1)
        label.stringValue = next.text
        label.textColor = next.talking ? green : grey
        dot.layer?.backgroundColor = (next.talking ? green : NSColor(white: 0.5, alpha: 1)).cgColor
        (panel?.contentView as? NSVisualEffectView)?.layer?.borderColor =
            (next.talking ? green.withAlphaComponent(0.6) : NSColor(white: 1, alpha: 0.15)).cgColor
    }
}

// MARK: - Enrollment panel

/// "Read this aloud", one sentence at a time: the sentence large, each word green once heard and
/// the next one bold and underlined, a pill per sentence (✓ when done), progress, a status
/// line and Start/Cancel. Without tracking, the whole passage shows plain and progress counts
/// 60 s of speech, with the reason on the status line.
@MainActor
final class VoiceEnrollPanel: NSObject, NSWindowDelegate {
    static let size = NSSize(width: 560, height: 420)
    static let sentenceFont = NSFont.systemFont(ofSize: 22)
    static let passageFont = NSFont.systemFont(ofSize: 14)
    private(set) var window: NSPanel?
    private let message = NSTextField(wrappingLabelWithString: "")
    private let steps = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let passage = NSTextView()
    private let progress = NSProgressIndicator()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "Start", target: nil, action: nil)
    var onStart: (() -> Void)?
    var onCancel: (() -> Void)?
    private var running = false
    let words: [String]
    let paragraphs: [String]
    let sentences: ReadingSentences

    /// What the text view holds: one sentence (tracked) or the whole passage (not tracked).
    enum Display: Equatable { case sentence(Int), passage }
    private(set) var display = Display.sentence(0)
    /// The shown words' ranges in the text view, and their styles.
    private var ranges: [NSRange] = []
    private(set) var wordStyles: [WordStyle] = []
    /// Why the reading is not followed this round, or nil.
    private(set) var trackingNote: String?

    init(words: [String] = ReadingPassage.words, paragraphs: [String] = ReadingPassage.paragraphs) {
        self.words = words
        self.paragraphs = paragraphs
        sentences = ReadingSentences(words: words)
        super.init()
    }

    var statusText: String { status.stringValue }
    var stepsText: String { steps.stringValue }
    var progressValue: Double { progress.doubleValue }
    var buttonTitle: String { button.title }
    var passageText: String { passage.string }

    /// `underway`: an enrollment is already running, so its progress stays (no second Start).
    func show(underway: Bool = false) {
        let w = window ?? make()
        window = w
        if !underway { ready() }
        w.center()
        NSApp.activate()
        // Front even when activation is refused (macOS's cooperative activation).
        w.orderFrontRegardless()
        w.makeKey()
    }

    private func make() -> NSPanel {
        let size = Self.size
        let w = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .utilityWindow],
                        backing: .buffered, defer: false)
        w.title = "Enroll My Voice"
        w.isReleasedWhenClosed = false
        w.level = .floating
        // A menu-bar app is rarely the active app: an NSPanel's default hides it whenever the app
        // is not, so it vanished as the menu closed or on a click on another screen (11-11).
        w.hidesOnDeactivate = false
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        w.delegate = self
        let v = NSView(frame: NSRect(origin: .zero, size: size))
        let inner = size.width - 40
        message.frame = NSRect(x: 20, y: 366, width: inner, height: 44)
        message.font = .systemFont(ofSize: 12)
        steps.frame = NSRect(x: 20, y: 340, width: inner, height: 20)
        steps.font = .systemFont(ofSize: 13, weight: .medium)
        steps.textColor = .secondaryLabelColor
        steps.lineBreakMode = .byTruncatingTail
        scroll.frame = NSRect(x: 20, y: 134, width: inner, height: 200)
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        passage.frame = NSRect(origin: .zero, size: scroll.contentSize)
        passage.autoresizingMask = [.width]
        passage.isEditable = false
        passage.isSelectable = false
        passage.textContainerInset = NSSize(width: 12, height: 14)
        passage.drawsBackground = true
        passage.backgroundColor = .textBackgroundColor
        scroll.documentView = passage
        progress.frame = NSRect(x: 20, y: 108, width: inner, height: 16)
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        status.frame = NSRect(x: 20, y: 46, width: inner, height: 54)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        button.frame = NSRect(x: size.width - 150, y: 10, width: 132, height: 28)
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(clicked)
        [message, steps, scroll, progress, status, button].forEach(v.addSubview)
        w.contentView = v
        return w
    }

    private func ready() {
        running = false
        trackingNote = nil
        message.stringValue = "Press Start, then read each sentence aloud at your normal pace. Words turn green as they are heard; the next sentence follows. Recognition runs on this Mac only; nothing is recorded, only a voiceprint is kept."
        show(.start)
        progress.doubleValue = 0
        status.stringValue = "Press Start when you are ready."
        button.title = "Start"
    }

    /// Asking for speech-recognition permission (the first time, macOS asks the owner).
    func preparing() { status.stringValue = "Getting speech recognition ready…" }

    /// Where a tracked reading is, in passage word indices.
    struct Snapshot: Equatable {
        var reached: Int
        /// Words actually heard (the others passed over show dim).
        var matched: Set<Int>
        /// The sentence shown (the first not read); `count` once all are.
        var current: Int
        var done: Set<Int>
        /// The current sentence is asked for once more.
        var again = false

        static let start = Snapshot(reached: 0, matched: [], current: 0, done: [])

        /// Every word up to `reached` heard, every sentence before it read.
        static func heard(upTo reached: Int, sentences: ReadingSentences) -> Snapshot {
            let current = sentences.index(at: reached)
            return Snapshot(reached: reached, matched: Set(0..<reached), current: current, done: Set(0..<current))
        }
    }

    /// Tracked: `reached` words of the passage are green.
    func reading(reached: Int, speechSeconds: Double, waitingForMic: Bool) {
        reading(.heard(upTo: reached, sentences: sentences), speechSeconds: speechSeconds, waitingForMic: waitingForMic)
    }

    func reading(_ at: Snapshot, speechSeconds: Double, waitingForMic: Bool) {
        trackingNote = nil
        show(at)
        progress.doubleValue = sentences.count == 0 ? 0 : Double(at.done.count) / Double(sentences.count)
        let i = min(at.current, sentences.count - 1)
        let speech = "\(Int(speechSeconds)) s of speech (\(Int(ReadingCompletion.minSpeechSeconds)) s needed)"
        status.stringValue = waitingForMic ? "Waiting for the microphone…"
            : at.again ? "Not all of sentence \(i + 1) was heard: read it once more, clearly. · \(speech)"
            : "Read on… sentence \(i + 1) of \(sentences.count) · \(speech)"
    }

    /// Not tracked: the whole passage to read, plain; progress is time-based.
    func untracked(_ why: String) {
        trackingNote = why
        setDisplay(.passage)
        setStyles(WordStyle.styles(count: words.count, reached: 0, tracking: false))
        steps.stringValue = ""
        message.stringValue = "Read the passage aloud at your normal pace (or keep talking) until the bar is full. Only your speech counts; pauses are skipped. Nothing is recorded, only a voiceprint is kept."
        listening(progress.doubleValue, waitingForMic: false)
    }

    func listening(_ fraction: Double, waitingForMic: Bool) {
        progress.doubleValue = fraction
        let line = waitingForMic ? "Waiting for the microphone…"
            : "Listening… \(Int(fraction * VoiceID.enrollSeconds)) of \(Int(VoiceID.enrollSeconds)) s of speech"
        status.stringValue = trackingNote.map { "Reading tracking isn't available: \($0). \(line)" } ?? line
    }

    func computing() { status.stringValue = "Making your voiceprint…"; progress.doubleValue = 1 }

    /// The passage is read, but too little of it was speech for a voiceprint. The speech is kept
    /// (`running` stays: closing the window still discards it); reading again adds to it.
    func needsMoreSpeech(_ seconds: Double) {
        button.title = "Read It Again"
        status.stringValue = "You reached the end, but only \(Int(seconds)) s of speech were heard (\(Int(ReadingCompletion.minSpeechSeconds)) s needed). Read it again from the first sentence: what was heard is kept and added to."
    }

    func finished(_ result: VoiceIDEngine.EnrollResult) {
        running = false
        button.title = "Close"
        switch result {
        case .done(let print):
            status.stringValue = "Done: enrolled from \(print.segments) segments, \(Int(print.speechSeconds)) s of speech."
            message.stringValue = "Your voiceprint is saved. Turn on \"Show 'Am I Talking?' Indicator\" in the 🎙 Voice ID menu to try it."
        case .failed(let why):
            progress.doubleValue = 0
            status.stringValue = "Not enrolled."
            message.stringValue = "Enrollment failed: \(why)"
        }
    }

    func failed(_ why: String) { finished(.failed(why)) }

    /// Start was pressed but cannot begin yet (a Bluetooth mic, no mic): the window stays ready
    /// with Start, says why, and the controller starts on its own once the cause clears.
    func blocked(_ why: String) {
        running = false
        show(.start)
        progress.doubleValue = 0
        button.title = "Start"
        status.stringValue = "Waiting to start: \(why)"
    }

    /// The current sentence, its words styled, and the pills. Once all are read the last
    /// sentence stays, green.
    private func show(_ at: Snapshot) {
        guard sentences.count > 0 else { return }
        let i = at.current
        let shown = min(i, sentences.count - 1)
        setDisplay(.sentence(shown))
        setStyles(WordStyle.styles(range: sentences.ranges[shown], reached: at.reached, matched: at.matched))
        steps.stringValue = Self.pills(current: i, done: at.done, count: sentences.count)
            + "   " + (i < sentences.count ? "Sentence \(i + 1) of \(sentences.count)" : "All \(sentences.count) sentences read")
    }

    /// ✓ per finished sentence, ● the current one, ○ those to come.
    nonisolated static func pills(current: Int, count: Int) -> String {
        pills(current: current, done: Set(0..<current), count: count)
    }

    nonisolated static func pills(current: Int, done: Set<Int>, count: Int) -> String {
        (0..<count).map { $0 == current ? "●" : done.contains($0) ? "✓" : "○" }.joined(separator: " ")
    }

    private func setDisplay(_ next: Display) {
        guard next != display || ranges.isEmpty, let storage = passage.textStorage else { return }
        display = next
        let shownWords: [String]
        let text: String
        let font: NSFont
        switch next {
        case .sentence(let i):
            shownWords = Array(words[sentences.ranges[i]])
            text = shownWords.joined(separator: " ")
            font = Self.sentenceFont
        case .passage:
            shownWords = words
            text = paragraphs.joined(separator: "\n\n")
            font = Self.passageFont
        }
        let ns = text as NSString
        var at = 0
        ranges = shownWords.map { w in
            let r = ns.range(of: w, range: NSRange(location: at, length: ns.length - at))
            if r.location != NSNotFound { at = r.location + r.length }
            return r
        }
        let para = NSMutableParagraphStyle()
        para.lineSpacing = next == .passage ? 4 : 8
        storage.setAttributedString(NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: para,
                                                                                  .foregroundColor: NSColor.labelColor]))
        wordStyles = []
    }

    private func setStyles(_ next: [WordStyle]) {
        guard next != wordStyles, let storage = passage.textStorage else { return }
        wordStyles = next
        let base = display == .passage ? Self.passageFont : Self.sentenceFont
        storage.beginEditing()
        for (r, style) in zip(ranges, next) where r.location != NSNotFound {
            storage.removeAttribute(.underlineStyle, range: r)
            storage.addAttributes(Self.attributes(style, base: base), range: r)
        }
        storage.endEditing()
        if let n = next.firstIndex(of: .next), ranges[n].location != NSNotFound { passage.scrollRangeToVisible(ranges[n]) }
    }

    static func attributes(_ style: WordStyle, base: NSFont) -> [NSAttributedString.Key: Any] {
        switch style {
        case .read: return [.foregroundColor: NSColor.systemGreen, .font: base]
        case .skipped: return [.foregroundColor: NSColor.systemGreen.withAlphaComponent(0.4), .font: base]
        case .next: return [.foregroundColor: NSColor.labelColor, .font: NSFont.boldSystemFont(ofSize: base.pointSize),
                            .underlineStyle: NSUnderlineStyle.single.rawValue]
        case .unread: return [.foregroundColor: NSColor.tertiaryLabelColor, .font: base]
        case .plain: return [.foregroundColor: NSColor.labelColor, .font: base]
        }
    }

    /// The colour shown word `i` (of those shown) is drawn in (tests).
    func color(ofWord i: Int) -> NSColor? {
        guard ranges.indices.contains(i), ranges[i].location != NSNotFound, let storage = passage.textStorage,
              ranges[i].location < storage.length else { return nil }
        return storage.attribute(.foregroundColor, at: ranges[i].location, effectiveRange: nil) as? NSColor
    }

    @objc private func clicked() {
        switch button.title {
        case "Start", "Read It Again":
            running = true
            button.title = "Cancel"
            status.stringValue = "Listening…"
            onStart?()
        case "Cancel":
            onCancel?()
            ready()
        default:
            window?.close()
        }
    }

    /// For tests: the button, as the owner would press it.
    func press() { clicked() }

    func windowWillClose(_ notification: Notification) {
        if running { running = false; onCancel?() }
    }
}

// MARK: - The app's Voice ID

/// Main-thread side: the setting, the voiceprint, the mic subscription, the pill and the panel.
/// Frames are only taken while the pill shows or an enrollment runs (otherwise the VAD path is
/// exactly as before).
@MainActor
final class VoiceIDController {
    static let shared = VoiceIDController(mic: SpeakingCoach.shared.speech as? MicSpeechSource)
    nonisolated static let indicatorKey = "voiceIDIndicatorShown"

    let engine: VoiceIDEngine
    let indicator = VoiceIndicatorController()
    private weak var mic: MicSpeechSource?
    private let defaults: UserDefaults
    private(set) var voiceprint: Voiceprint?
    let modelPresent: Bool
    private var timer: Timer?
    private var listening = false
    private(set) var panel: VoiceEnrollPanel?
    private let log = Log("VoiceID")
    /// Follows the reading during enrollment, from the same frames.
    let tracker: ReadingTracker
    let sentences = ReadingSentences()
    /// Which sentences are read, with rigor (most of each really heard).
    private(set) var reading = ReadingState()
    /// Speech heard when the reading last moved on (or started): 20 s more with no word
    /// advancing means recognition is not following the owner.
    private var speechAtLastAdvance = 0.0
    private var lastProgress: (reached: Int, heard: Int) = (0, 0)

    enum ReadingMode: Equatable { case off, tracked, untracked(String) }
    private(set) var readingMode = ReadingMode.off
    /// Bumped by every Start and Cancel: a permission answer for an older Start is ignored.
    private var attempt = 0
    /// Start was pressed but blocked: begins by itself once the blocker clears, window open.
    private(set) var startWhenReady = false
    var now: () -> Date = Date.init

    init(mic: MicSpeechSource?, engine: VoiceIDEngine = VoiceIDEngine(), defaults: UserDefaults = .standard,
         modelPresent: Bool = VoiceID.modelURL != nil, voiceprint: Voiceprint? = Voiceprint.load(),
         recognizer: ReadingRecognizer = AppleReadingRecognizer()) {
        self.mic = mic
        self.engine = engine
        self.defaults = defaults
        self.modelPresent = modelPresent
        self.voiceprint = voiceprint
        tracker = ReadingTracker(recognizer: recognizer)
        engine.use(voiceprint)
    }

    var indicatorShown: Bool { defaults.bool(forKey: Self.indicatorKey) }

    /// The tray's status line.
    var statusLine: String {
        if !modelPresent { return "Model missing: run scripts/fetch-voice-id.sh" }
        guard let print = voiceprint else { return "Not enrolled" }
        return "Enrolled " + DateFormatter.localizedString(from: print.enrolledAt, dateStyle: .medium, timeStyle: .none)
    }

    /// At launch: the pill comes back if it was on.
    func start() {
        if indicatorShown { apply() }
    }

    func setIndicator(_ on: Bool) {
        defaults.set(on, forKey: Self.indicatorKey)
        log.info("indicator \(on ? "shown" : "hidden")")
        apply()
    }

    private func apply() {
        if indicatorShown { indicator.show() } else { indicator.hide() }
        engine.setLive(indicatorShown && voiceprint != nil)
        // A start waiting on the mic keeps the 4-a-second tick that notices it is usable.
        listen(indicatorShown || engine.enrolling || startWhenReady)
    }

    /// Subscribes to (or leaves) the mic's frames, and runs the 4-a-second redraw meanwhile.
    private func listen(_ on: Bool) {
        guard on != listening else { return }
        listening = on
        if on {
            let engine = self.engine
            let recognizer = tracker.recognizer
            // The recognizer drops frames unless a reading is being followed.
            mic?.listen { frames in engine.frames(frames); recognizer.append(frames) }
            if modelPresent { engine.warmUp() }
            let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            // Common modes: it also runs while the tray menu is open.
            RunLoop.main.add(t, forMode: .common)
            timer = t
            tick()
        } else {
            mic?.listen(nil)
            timer?.invalidate()
            timer = nil
        }
    }

    /// Main thread, at most 4 times a second: the pill and the enrollment panel.
    func tick() {
        // Pressed Start while blocked: begin once the cause clears, if the window is still open.
        if startWhenReady {
            if panel?.window?.isVisible != true { startWhenReady = false; apply() }
            else if (blocker ?? enrollmentBlocker)() == nil {
                log.info("enrollment starting: the microphone is usable now")
                beginEnrollment()
            }
        }
        let out = engine.output.value
        let micOn = mic?.isListening ?? false
        if indicatorShown {
            indicator.update(.from(modelPresent: modelPresent, enrolled: voiceprint != nil, micListening: micOn, output: out, now: Date()))
        }
        if let result = out.enrollResult {
            engine.output.withLock { $0.enrollResult = nil }
            if case .done(let print) = result { voiceprint = print }
            readingMode = .off
            panel?.finished(result)
            apply()
        } else if readingMode == .tracked, engine.enrolling {
            followReading(out, micOn: micOn)
        } else if engine.enrollmentPaused {
            // Kept for "Read It Again": the panel says so already.
        } else if let p = out.enrollProgress {
            if p >= 1 || (p > 0 && !engine.enrolling) { panel?.computing() } else { panel?.listening(p, waitingForMic: !micOn) }
        }
    }

    // MARK: Enrollment

    /// Asks before an enrollment replaces the saved voiceprint (tests answer for the owner).
    var confirmReplace: @MainActor (Voiceprint) -> Bool = { existing in
        let alert = NSAlert()
        alert.messageText = "A voice is already enrolled"
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        alert.informativeText = "This Mac has a voiceprint from \(f.string(from: existing.enrolledAt)) "
            + "(\(existing.segments) segments, \(Int(existing.speechSeconds)) s of speech). Enrolling again replaces it."
        alert.addButton(withTitle: "Replace It")
        alert.addButton(withTitle: "Cancel")
        // Like the enrollment window: an inactive menu-bar app would hide it, and a hidden modal
        // alert blocks the whole app with no Dock icon to bring it back.
        alert.window.hidesOnDeactivate = false
        alert.window.level = .floating
        NSApp.activate()
        alert.window.orderFrontRegardless()
        return alert.runModal() == .alertFirstButtonReturn
    }

    func showEnrollment() {
        // Already open: bring it forward (its own Start is the decision; no second question).
        if let w = panel?.window, w.isVisible {
            NSApp.activate()
            w.orderFrontRegardless()
            return
        }
        let underway = engine.enrollmentUnderway
        if !underway, let existing = voiceprint {
            guard confirmReplace(existing) else {
                log.info("enrollment not started: the owner kept the voiceprint from \(existing.enrolledAt)")
                return
            }
            log.info("enrolling again: the owner chose to replace the voiceprint from \(existing.enrolledAt)")
        }
        log.info(underway ? "enrollment window shown (enrollment under way)" : "enrollment window shown")
        let p = panel ?? VoiceEnrollPanel()
        panel = p
        p.onStart = { [weak self] in self?.beginEnrollment() }
        p.onCancel = { [weak self] in self?.cancelEnrollment() }
        p.show(underway: underway)
    }

    /// Tests stand in for the microphone check (they have no microphone).
    var blocker: (@MainActor () -> String?)?

    /// Why enrollment cannot start now, or nil.
    func enrollmentBlocker() -> String? {
        if !modelPresent { return "the voice model is missing (run scripts/fetch-voice-id.sh, then rebuild the app)" }
        guard let mic else { return "the microphone is not available" }
        if mic.inputIsBluetooth() {
            return "your microphone is a Bluetooth headset, which this app leaves alone: choose the MacBook's microphone (or a wired one) in System Settings › Sound › Input, then try again"
        }
        if !mic.isListening { return "the microphone is not available" + (mic.problem.map { ": \($0)" } ?? " (it is not running)") }
        return nil
    }

    private func beginEnrollment() {
        attempt += 1
        if let why = (blocker ?? enrollmentBlocker)() {
            if !startWhenReady { log.warn("enrollment waiting to start: \(why)") }
            startWhenReady = true
            panel?.blocked(why)
            apply()
            return
        }
        startWhenReady = false
        let mine = attempt
        panel?.preparing()
        tracker.recognizer.prepare { [weak self] availability in
            guard let self, self.attempt == mine else { return }   // cancelled while macOS asked
            self.startReading(availability)
        }
    }

    /// Listening starts: followed word by word when recognition is available, else on 60 s of
    /// speech as before, saying why on the status line.
    func startReading(_ availability: ReadingTrackingAvailability) {
        // "Read It Again": the speech heard last time is kept and added to.
        let again = engine.enrollmentPaused
        switch availability {
        case .available:
            log.info("enrollment \(again ? "resumed" : "started"): following the reading on device")
            readingMode = .tracked
            if again { engine.resumeEnrollment(seconds: nil) } else { engine.startEnrollment(seconds: nil) }
            reading = ReadingState(sentences: sentences, passage: tracker.passage)
            speechAtLastAdvance = engine.output.value.enrollSpeechSeconds
            lastProgress = (0, 0)
            tracker.start()
            panel?.reading(.start, speechSeconds: engine.output.value.enrollSpeechSeconds, waitingForMic: false)
        case .unavailable(let why):
            log.warn("enrollment \(again ? "resumed" : "started") without reading tracking: \(why)")
            readingMode = .untracked(why)
            if again { engine.resumeEnrollment(seconds: VoiceID.enrollSeconds) } else { engine.startEnrollment() }
            panel?.untracked(why)
        }
        listen(true)
    }

    /// Where the reading is, for the panel and the self-test.
    var readingSnapshot: VoiceEnrollPanel.Snapshot {
        .init(reached: tracker.reached, matched: tracker.matched, current: reading.current, done: reading.done,
              again: reading.again != nil && reading.again == reading.current)
    }

    /// Tick, while a tracked reading listens: colours, and done (or too little speech).
    private func followReading(_ out: VoiceIDEngine.Output, micOn: Bool) {
        // Recognition gave up, or hears nothing while Silero hears the owner: the speech so far
        // still counts, toward 60 s.
        let progress = (reached: tracker.reached, heard: tracker.matched.count + tracker.misheard.count)
        if progress != lastProgress {
            lastProgress = progress
            speechAtLastAdvance = out.enrollSpeechSeconds
        }
        let stuck = out.enrollSpeechSeconds - speechAtLastAdvance >= ReadingCompletion.silentRecognizerSeconds
        let silent = "no words were recognized in \(Int(ReadingCompletion.silentRecognizerSeconds)) s of speech"
        if let why = tracker.failure ?? (stuck ? (progress == (0, 0) ? silent : "the reading stopped moving: " + silent) : nil) {
            log.warn("reading not followed any more: \(why)")
            tracker.stop()
            readingMode = .untracked(why)
            engine.setEnrollmentTarget(seconds: VoiceID.enrollSeconds)
            panel?.untracked(why)
            return
        }
        let quiet = out.lastSpeechAt.map { now().timeIntervalSince($0) } ?? .infinity
        // A sentence whose last word or two the recognizer missed is done once the owner stops.
        let settled = sentences.settled(reached: tracker.reached, quietFor: quiet)
        if settled > tracker.reached { tracker.move(to: settled) }
        // Back to a sentence not heard well enough, or on past one read once more.
        if let move = reading.update(reached: tracker.reached, matched: tracker.matched, misheard: tracker.misheard) {
            if let r = move.forget {
                log.info("sentence \(reading.current + 1) asked for once more (too few of its words heard)")
                tracker.forget(r)
            }
            tracker.move(to: move.to)
        }
        switch ReadingCompletion.verdict(allRead: reading.allRead, speechSeconds: out.enrollSpeechSeconds) {
        case .reading:
            panel?.reading(readingSnapshot, speechSeconds: out.enrollSpeechSeconds, waitingForMic: !micOn)
        case .done:
            log.info(String(format: "reading done (%d of %d words heard, %.0f s of speech): making the voiceprint",
                            tracker.matched.count, tracker.total, out.enrollSpeechSeconds))
            tracker.stop()
            panel?.reading(readingSnapshot, speechSeconds: out.enrollSpeechSeconds, waitingForMic: false)
            engine.finishEnrollment()
            panel?.computing()
        case .tooLittleSpeech(let seconds):
            log.warn(String(format: "reading done but only %.0f s of speech: kept, to read again", seconds))
            tracker.stop()
            readingMode = .off
            engine.pauseEnrollment()
            panel?.reading(readingSnapshot, speechSeconds: seconds, waitingForMic: false)
            panel?.needsMoreSpeech(seconds)
            apply()
        }
    }

    private func cancelEnrollment() {
        startWhenReady = false
        attempt += 1
        tracker.stop()
        readingMode = .off
        guard engine.enrollmentUnderway else { return }
        log.info("enrollment cancelled")
        engine.cancelEnrollment()
        apply()
    }
}

// MARK: - Tray

extension TrayAppManager {
    func voiceIDMenuItem() -> NSMenuItem {
        let voice = VoiceIDController.shared
        let menu = NSMenu()
        live(to: menu) { _ in "Status: \(voice.statusLine)" }
        add("Enroll My Voice…", #selector(enrollVoice), to: menu)
        add("\(voice.indicatorShown ? "✓" : "○") Show 'Am I Talking?' Indicator", #selector(toggleVoiceIndicator), to: menu)
        let parent = NSMenuItem(title: "🎙 Voice ID", action: nil, keyEquivalent: "")
        parent.submenu = menu
        return parent
    }

    @objc func enrollVoice() { VoiceIDController.shared.showEnrollment() }

    @objc func toggleVoiceIndicator() {
        let voice = VoiceIDController.shared
        voice.setIndicator(!voice.indicatorShown)
    }
}
