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

/// The audio engine, owned by one serial queue: every call into AVAudioEngine runs there,
/// never on the main thread. Starting a Bluetooth input waits on the hardware for seconds
/// (10-28: 4.7 s with AirPods), which on the main thread froze the tray menu for as long.
/// AVAudio's Objective-C exceptions are caught here and become failures to retry.
final class MicEngine: @unchecked Sendable {
    enum Opened: Sendable { case listening(String), failed(String) }
    let queue = DispatchQueue(label: "learner.speech.engine", qos: .userInitiated)
    // Only touched on `queue`. Replaced at every close: after a device switch an engine can
    // keep reporting the old input's format (10-28: 48 kHz while AirPods ran at 24 kHz),
    // and tapping it then raises.
    private var engine = AVAudioEngine()
    private var observer: NSObjectProtocol?

    /// On `queue`. `changed` runs when the input device changes under the running engine.
    func open(state: Locked<MicSpeechSource.VADState>, model: MicSpeechSource.VADModel, vad: DispatchQueue, log: Log, changed: @escaping @Sendable () -> Void) -> Opened {
        dispatchPrecondition(condition: .onQueue(queue))
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // Mid-switch (AirPods connecting) the input has no format yet.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            return .failed("no microphone input ready (\(format.sampleRate) Hz, \(format.channelCount) channels)")
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SileroVAD.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else {
            return .failed("cannot convert the microphone's \(format) to 16 kHz")
        }
        let tap = MicSpeechSource.tap(format: format, target: target, converter: converter, state: state, model: model, queue: vad, log: log)
        var startError: Error?
        if let raised = LDCatchException({
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: format, block: tap)
            do { try engine.start() } catch { startError = error }
        }) {
            close()
            return .failed("the microphone refused to start (\(raised.reason ?? raised.name.rawValue))")
        }
        if let startError {
            close()
            return .failed("microphone would not start: \(startError.localizedDescription)")
        }
        // A new input device (AirPods connecting, a mic unplugged) stops the engine and
        // changes the format: start again on the new one.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in changed() }
        return .listening("\(format.sampleRate / 1000) kHz \(format.channelCount)-channel input")
    }

    /// On `queue`: stop and drop the engine; the next open reads the device afresh.
    func close() {
        dispatchPrecondition(condition: .onQueue(queue))
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = nil
        let old = engine
        _ = LDCatchException {
            old.inputNode.removeTap(onBus: 0)
            old.stop()
        }
        engine = AVAudioEngine()
    }
}

/// The owner's speech from the microphone through Silero; other speakers and word counts
/// still from screenpipe (whose own spans for the owner add words but no timing).
@MainActor
final class MicSpeechSource: SpeechSource {
    private let screenpipe: SpeechSource
    private let log = Log("Speech")
    private let mic = MicEngine()
    private let queue = DispatchQueue(label: "learner.speech.vad", qos: .userInitiated)
    private let state = Locked<VADState>(VADState())
    private let model = VADModel()
    private var modelLoaded = false
    private(set) var problem: String?
    private var started = false
    /// The engine is being started on its queue; the result comes back to `opened`.
    private var opening = false
    var isListening: Bool { started }
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

    /// What the main thread reads each second. Small and quick under its lock: the model
    /// runs outside it (`VADModel`), or every coach tick waits on CoreML (10-28: seconds).
    struct VADState {
        var segmenter = VADSegmenter()
        var lastError: String?
        /// Frames the model has scored (the self-test's proof that audio arrives).
        var frames = 0
    }

    /// The Silero model, touched only on the VAD queue (set and reset there too).
    final class VADModel: @unchecked Sendable {
        var vad: SileroVAD?
        init(_ vad: SileroVAD? = nil) { self.vad = vad }
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
        guard !started, !opening else { return true }
        if inCall && inputIsBluetooth() { return false }
        // Loaded once (from disk, on this thread); a reopen only clears its memory of the last audio.
        do {
            let model = self.model
            if !modelLoaded {
                let vad = try SileroVAD()
                queue.async { model.vad = vad }
                modelLoaded = true
            } else {
                queue.async { model.vad?.reset() }
            }
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
        opening = true
        let (mic, state, model, vad, log) = (self.mic, self.state, self.model, self.queue, self.log)
        mic.queue.async {
            let result = mic.open(state: state, model: model, vad: vad, log: log, changed: { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.restart(why: "the audio input changed") } }
            })
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.opened(result) } }
        }
        return true
    }

    /// Back on the main thread with what the engine queue made of an open.
    private func opened(_ result: MicEngine.Opened) {
        opening = false
        switch result {
        case .listening(let input):
            // A Bluetooth call began while it was starting: leave the mic to the call.
            guard wanted, !(inCall && inputIsBluetooth()) else {
                let mic = self.mic
                mic.queue.async { mic.close() }
                return
            }
            started = true
            if stall.since == nil { problem = nil }
            stall.started(frames: framesScored)
            reopen.succeeded()
            log.info("listening on \(input); Silero VAD on device")
        case .failed(let why):
            _ = failed(Date(), why)
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
                                state: Locked<VADState>, model: VADModel, queue: DispatchQueue, log: Log) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
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
                guard let vad = model.vad else { return }
                do {
                    // Inference outside the lock: the main thread never waits on it.
                    let probs = try vad.process(samples)
                    // Frames run back from the newest sample; good to a few ms.
                    let newest = heard.addingTimeInterval(Double(samples.count) / SileroVAD.sampleRate)
                    state.withLock { s in
                        s.frames += probs.count
                        for (i, p) in probs.enumerated() {
                            let at = newest.addingTimeInterval(-Double(probs.count - i) * SileroVAD.frameSeconds)
                            s.segmenter.add(p, at: at)
                        }
                        s.lastError = nil
                    }
                } catch {
                    let why = error.localizedDescription
                    let first = state.withLock { s -> Bool in
                        defer { s.lastError = why }
                        return s.lastError == nil
                    }
                    if first { log.error("speech model failed: \(why)") }
                }
            }
        }
    }

    var framesScored: Int { state.withLock { $0.frames } }

    func stop() {
        guard started else { return }
        started = false
        let mic = self.mic
        mic.queue.async { mic.close() }
    }

    func restart(why: String) {
        log.warn("\(why); restarting the microphone")
        stop()
        // On the engine queue after the close; a failure is logged and retried from `poll`.
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
