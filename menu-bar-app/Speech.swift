@preconcurrency import AVFoundation
import CoreAudio
import ObjCCatch
import CoreML
import Foundation

// MARK: - On-device speech detection (Silero VAD)

// The coach used to learn the owner was speaking from screenpipe's transcripts: 5-15 s late.
// Here the microphone goes straight to Silero VAD (v6, Core ML, MIT; ~1 % of a core), which
// says "speaking" about 0.3 s after speech starts. screenpipe still supplies who else is
// talking and how many words were said, but no longer the timing of the owner's own turn.

/// Silero VAD v6 on Core ML: 32 ms frames (512 samples at 16 kHz, plus 64 of context),
/// with its LSTM state carried from frame to frame.
// @unchecked: used only inside MicSpeechSource's Locked state (one thread at a time).
final class SileroVAD: @unchecked Sendable {
    static let sampleRate = 16_000.0
    static let frame = 512
    static let context = 64
    static var frameSeconds: Double { Double(frame) / sampleRate }

    /// The bundled model (Contents/Resources/silero-vad.mlmodelc); LEARNER_VAD_MODEL
    /// overrides; from a source checkout, menu-bar-app/Models.
    static var modelURL: URL? {
        if let p = ProcessInfo.processInfo.environment["LEARNER_VAD_MODEL"] { return URL(fileURLWithPath: p) }
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("silero-vad.mlmodelc"),
                          URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Models/silero-vad.mlmodelc")]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private let model: MLModel
    private var hidden: MLMultiArray
    private var cell: MLMultiArray
    private var tail = [Float](repeating: 0, count: SileroVAD.context)
    private var pending: [Float] = []

    init(url: URL? = SileroVAD.modelURL) throws {
        guard let url = url else { throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "silero-vad.mlmodelc not found"]) }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly   // a tiny model: the CPU is fastest and steadiest
        model = try MLModel(contentsOf: url, configuration: config)
        hidden = try MLMultiArray(shape: [1, 128], dataType: .float32)
        cell = try MLMultiArray(shape: [1, 128], dataType: .float32)
        reset()
    }

    func reset() {
        for i in 0..<128 { hidden[i] = 0; cell[i] = 0 }
        tail = [Float](repeating: 0, count: SileroVAD.context)
        pending = []
    }

    /// Feeds 16 kHz mono samples; returns the speech probability of each whole frame they
    /// complete (leftover samples wait for the next call).
    func process(_ samples: [Float]) throws -> [Float] {
        pending += samples
        var out: [Float] = []
        while pending.count >= SileroVAD.frame {
            let frame = Array(pending.prefix(SileroVAD.frame))
            pending.removeFirst(SileroVAD.frame)
            let input = try MLMultiArray(shape: [1, NSNumber(value: SileroVAD.context + SileroVAD.frame)], dataType: .float32)
            for (i, v) in (tail + frame).enumerated() { input[i] = NSNumber(value: v) }
            let r = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "audio_input": input, "hidden_state": hidden, "cell_state": cell]))
            guard let p = r.featureValue(for: "vad_output")?.multiArrayValue,
                  let h = r.featureValue(for: "new_hidden_state")?.multiArrayValue,
                  let c = r.featureValue(for: "new_cell_state")?.multiArrayValue else {
                throw CocoaError(.coderValueNotFound, userInfo: [NSLocalizedDescriptionKey: "unexpected Silero outputs"])
            }
            hidden = h
            cell = c
            tail = Array(frame.suffix(SileroVAD.context))
            out.append(p[0].floatValue)
        }
        return out
    }
}

/// Frame probabilities -> spans of the owner's speech. Speech counts once the last second
/// holds at least 256 ms of speech frames (the rule benchmarked at F1 0.93, onset ~0.3 s);
/// from then on every speech frame extends the span, which starts at the first speech frame
/// of that second. Pure, so it is tested exactly.
/// The microphone watchdog's rule: frames must keep moving while the mic runs. Silent past
/// `first` seconds, restart; while it stays silent, restart again after doubling waits (up to
/// `cap`), so a mic that never comes back is not restarted in a loop.
struct StallWatch {
    enum Verdict: Equatable { case flowing, waiting, restart(silentFor: TimeInterval) }
    let first: TimeInterval
    let cap: TimeInterval
    private(set) var since: Date?
    private var lastFrames = 0
    private var nextRestart: TimeInterval = 0
    private var wait: TimeInterval = 0

    init(first: TimeInterval = 10, cap: TimeInterval = 600) { self.first = first; self.cap = cap }

    /// After (re)starting the engine: frames are counted from here.
    mutating func started(frames: Int) { lastFrames = frames }

    mutating func check(frames: Int, now: Date) -> Verdict {
        if frames != lastFrames {
            lastFrames = frames
            since = nil
            return .flowing
        }
        guard let since = since else {
            self.since = now
            wait = first
            nextRestart = first
            return .waiting
        }
        let silent = now.timeIntervalSince(since)
        guard silent > nextRestart else { return .waiting }
        wait = min(wait * 2, cap)
        nextRestart = silent + wait
        return .restart(silentFor: silent)
    }
}

struct VADSegmenter {
    var threshold: Float = 0.5
    var minSpeechFrames = 8          // 8 × 32 ms = 256 ms
    var windowFrames = 31            // ~1 s
    /// Silence that ends a segment (the coach's own gap rule still decides turns).
    var releaseFrames = 16           // ~0.5 s

    private var recent: [(at: Date, speech: Bool)] = []
    private var active = false
    private var segmentStart: Date?
    private var lastSpeechEnd: Date?
    private var silentFrames = 0
    /// Speech since the last `take()`.
    private var newStart: Date?
    private var newEnd: Date?

    /// One frame's probability, the frame starting at `at`.
    mutating func add(_ probability: Float, at: Date) {
        let speech = probability >= threshold
        recent.append((at, speech))
        if recent.count > windowFrames { recent.removeFirst(recent.count - windowFrames) }
        let end = at.addingTimeInterval(SileroVAD.frameSeconds)
        if !active {
            guard recent.filter(\.speech).count >= minSpeechFrames,
                  let first = recent.first(where: \.speech) else { return }
            active = true
            segmentStart = first.at
            newStart = first.at
        }
        if speech {
            silentFrames = 0
            lastSpeechEnd = end
            newStart = newStart ?? end.addingTimeInterval(-SileroVAD.frameSeconds)
            newEnd = end
        } else {
            silentFrames += 1
            if silentFrames >= releaseFrames { active = false; segmentStart = nil }
        }
    }

    /// The speech heard since the last call, as one span (start, end), or nil.
    mutating func take() -> (start: Date, end: Date)? {
        defer { newStart = nil; newEnd = nil }
        guard let s = newStart, let e = newEnd, e > s else { return nil }
        return (s, e)
    }
}

/// The owner's speech from the microphone through Silero; other speakers and word counts
/// still from screenpipe (whose own spans for the owner add words but no timing).
@MainActor
final class MicSpeechSource: SpeechSource {
    private let screenpipe: SpeechSource
    private let log = Log("Speech")
    /// Replaced on every restart: after a device switch an engine can keep reporting the old
    /// input's format (10-28: 48 kHz while AirPods ran at 24 kHz), and tapping it then raises.
    private var engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "learner.speech.vad", qos: .userInitiated)
    private let state = Locked<VADState>(VADState())
    private(set) var problem: String?
    private var started = false
    private var configObserver: NSObjectProtocol?
    private var stall = StallWatch()
    /// The coach wants the mic (it called `start()`), and nothing permanent stops it (no
    /// permission, no model). While wanted and not running, opening is retried with backoff.
    private var wanted = false
    private var reopen = Backoff(base: 5, max: 300)
    private var retryAt = Date.distantPast
    /// A call is on (the coach says so). During a call on a Bluetooth input (AirPods) the
    /// mic is left to the call app: a second app on it keeps the headset in call mode and
    /// trips its switching. The coach times the owner from screenpipe meanwhile.
    var inCall = false
    private var heldForCall = false
    var inputIsBluetooth: () -> Bool = { MicSpeechSource.defaultInputIsBluetooth() }

    struct VADState {
        var segmenter = VADSegmenter()
        var vad: SileroVAD?
        var lastError: String?
        /// Frames the model has scored (the self-test's proof that audio arrives).
        var frames = 0
    }

    init(screenpipe: SpeechSource) { self.screenpipe = screenpipe }

    /// Starts the microphone (macOS asks the owner once). False when it cannot: the coach
    /// then keeps working from screenpipe alone, `problem` says why, and polls retry it.
    @discardableResult
    func start() -> Bool {
        wanted = true
        return open(now: Date())
    }

    private func open(now: Date) -> Bool {
        guard !started else { return true }
        if inCall && inputIsBluetooth() { return false }
        do {
            let vad = try SileroVAD()
            state.withLock { $0.vad = vad }
        } catch {
            problem = "speech model unavailable: \(error.localizedDescription)"
            log.error(problem!)
            wanted = false
            return false
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            problem = "microphone access denied (System Settings → Privacy & Security → Microphone)"
            log.warn("\(problem!); timing your speech from screenpipe instead")
            wanted = false
            return false
        case .notDetermined:
            problem = "waiting for microphone permission (answer the macOS prompt); timing from screenpipe until then"
            log.info("asking for microphone permission; timing your speech from screenpipe until it is granted")
            wanted = false
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    if granted { self.start() } else { self.problem = "microphone access denied"; self.log.warn("microphone access denied") }
                }
            }
            return false
        default: break
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // Mid-switch (AirPods connecting) the input has no format yet, and installing a tap
        // on it raises an Objective-C exception that Swift cannot catch: on 10-27 one left
        // the mic off, silently, for good. Not ready: say so and try again shortly.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            return failed(now, "no microphone input ready (\(format.sampleRate) Hz, \(format.channelCount) channels)")
        }
        input.removeTap(onBus: 0)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SileroVAD.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else {
            return failed(now, "cannot convert the microphone's \(format) to 16 kHz")
        }
        // AVAudioEngine raises Objective-C exceptions (a tap whose format no longer matches the
        // device): caught here, they are a failure to retry on a fresh engine. Uncaught, one
        // unwound through the app's clock on 10-28 and stopped it, and the mic, for good.
        let tap = MicSpeechSource.tap(format: format, target: target, converter: converter, state: state, queue: queue, log: log)
        var startError: Error?
        if let raised = LDCatchException({
            input.installTap(onBus: 0, bufferSize: 4096, format: format, block: tap)
            do { try engine.start() } catch { startError = error }
        }) {
            engine = AVAudioEngine()
            return failed(now, "the microphone refused to start (\(raised.reason ?? raised.name.rawValue))")
        }
        // A new input device (AirPods connecting, a mic unplugged) stops the engine and
        // changes the format: start again on the new one.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart(why: "the audio input changed") }
        }
        do {
            if let startError { throw startError }
            started = true
            if stall.since == nil { problem = nil }
            stall.started(frames: framesScored)
            reopen.succeeded()
            log.info("listening on \(format.sampleRate / 1000) kHz \(format.channelCount)-channel input; Silero VAD on device")
            return true
        } catch {
            if let o = configObserver { NotificationCenter.default.removeObserver(o) }
            configObserver = nil
            engine = AVAudioEngine()
            return failed(now, "microphone would not start: \(error.localizedDescription)")
        }
    }

    /// A failure that may pass (a device mid-switch): logged, and retried with backoff.
    private func failed(_ now: Date, _ why: String) -> Bool {
        let wait = reopen.failed()
        retryAt = now.addingTimeInterval(wait)
        problem = why
        log.warn("\(why); trying again in \(Job.describe(wait))")
        return false
    }

    enum MicAction: Equatable { case none, open, release }

    /// What the mic should do on this poll.
    nonisolated static func decide(running: Bool, wanted: Bool, inCall: Bool, bluetooth: Bool, retryDue: Bool) -> MicAction {
        let leaveToCall = inCall && bluetooth
        if running { return leaveToCall ? .release : .none }
        return wanted && !leaveToCall && retryDue ? .open : .none
    }

    private func manage(now: Date) {
        let bluetooth = inCall && inputIsBluetooth()
        switch MicSpeechSource.decide(running: started, wanted: wanted, inCall: inCall, bluetooth: bluetooth, retryDue: now >= retryAt) {
        case .none: break
        case .release:
            log.info("a call is on with a Bluetooth microphone: leaving it to the call, timing from screenpipe until it ends")
            stop()
            stall = StallWatch()
            heldForCall = true
        case .open:
            if heldForCall { log.info(inCall ? "the call moved off Bluetooth: taking the microphone back" : "call over: taking the microphone back") }
            heldForCall = false
            _ = open(now: now)
        }
    }

    /// Whether the system's default input is Bluetooth (AirPods and other headsets).
    nonisolated static func defaultInputIsBluetooth() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return false }
        address.mSelector = kAudioDevicePropertyTransportType
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// The microphone callback. Built outside the main actor on purpose: AVAudio calls it on
    /// its real-time thread, and a main-actor closure there is a Swift 6 isolation trap
    /// (the app crashed on 10-27 exactly so).
    nonisolated static func tap(format: AVAudioFormat, target: AVAudioFormat, converter: AVAudioConverter,
                                state: Locked<VADState>, queue: DispatchQueue, log: Log) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            // When this buffer's first sample was heard.
            let heard = Date().addingTimeInterval(-Double(buffer.frameLength) / format.sampleRate)
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * SileroVAD.sampleRate / format.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            // The converter asks for input synchronously, once per buffer.
            final class Once: @unchecked Sendable { var fed = false }
            let once = Once()
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if once.fed { status.pointee = .noDataNow; return nil }
                once.fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let data = out.floatChannelData else { return }
            let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
            queue.async {
                state.withLock { s in
                    guard let vad = s.vad else { return }
                    do {
                        let probs = try vad.process(samples)
                        s.frames += probs.count
                        // Frames run back from the newest sample; good to a few ms.
                        let newest = heard.addingTimeInterval(Double(samples.count) / SileroVAD.sampleRate)
                        for (i, p) in probs.enumerated() {
                            let at = newest.addingTimeInterval(-Double(probs.count - i) * SileroVAD.frameSeconds)
                            s.segmenter.add(p, at: at)
                        }
                        s.lastError = nil
                    } catch {
                        if s.lastError == nil { log.error("speech model failed: \(error.localizedDescription)") }
                        s.lastError = error.localizedDescription
                    }
                }
            }
        }
    }

    var framesScored: Int { state.withLock { $0.frames } }

    func stop() {
        guard started else { return }
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
        _ = LDCatchException {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        started = false
    }

    func restart(why: String) {
        log.warn("\(why); restarting the microphone")
        stop()
        engine = AVAudioEngine()
        // A failure is logged by `open` and retried from `poll`.
        _ = open(now: Date())
    }

    /// Called each poll: frames must keep arriving while the microphone runs.
    private func watchdog(now: Date) {
        switch stall.check(frames: framesScored, now: now) {
        case .flowing:
            if problem?.hasPrefix("no audio") == true { problem = nil; log.info("audio arriving again") }
        case .waiting:
            break
        case .restart(let silentFor):
            problem = "no audio from the microphone for \(Job.describe(silentFor))"
            restart(why: problem!)
        }
    }

    func poll(now: Date, deliver: @escaping @MainActor ([SpeechSpan]) -> Void) {
        let mine: [SpeechSpan] = state.withLock { s in
            guard let span = s.segmenter.take() else { return [] }
            return [SpeechSpan(speaker: .me, start: span.start, end: span.end, words: 0, audioClock: true,
                               capturedAt: span.start, path: "silero_vad", label: "silero \(String(format: "%.1f", span.end.timeIntervalSince(span.start))) s")]
        }
        manage(now: now)
        guard started else { return screenpipe.poll(now: now, deliver: deliver) }
        watchdog(now: now)
        if !mine.isEmpty { deliver(mine) }
        screenpipe.poll(now: now) { spans in
            // screenpipe's spans for the owner only add their words now; Silero times the turn.
            deliver(spans.map { span in
                guard span.speaker == .me else { return span }
                var words = span
                words.wordsOnly = true
                return words
            })
        }
    }
}
