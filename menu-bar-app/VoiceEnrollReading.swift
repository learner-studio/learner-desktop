import AppKit
@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

// MARK: - Guided enrollment: read a passage aloud, followed word by word

// Enrollment reads a fixed passage instead of "talk for a minute": the owner knows what to say
// and when they are done, and every enrollment hears the same range of sounds. Apple's speech
// recognizer, on this Mac only, follows the reading from the coach's own 16 kHz frames (no
// second mic tap) so each word turns green as it is heard. The voiceprint is still made from
// Silero's speech frames, as before; the recognizer only decides when the reading is done.

enum ReadingPassage {
    /// The Rainbow Passage (Grant Fairbanks, Voice and Articulation Drillbook, 2nd ed., p. 127),
    /// public domain per https://www.dialectsarchive.com/the-rainbow-passage . Its opening
    /// paragraph and the start of the next: about 65 s read aloud.
    static let paragraphs = [
        "When the sunlight strikes raindrops in the air, they act as a prism and form a rainbow. "
            + "The rainbow is a division of white light into many beautiful colors. These take the shape "
            + "of a long round arch, with its path high above, and its two ends apparently beyond the "
            + "horizon. There is, according to legend, a boiling pot of gold at one end. People look, but "
            + "no one ever finds it. When a man looks for something beyond his reach, his friends say he "
            + "is looking for the pot of gold at the end of the rainbow.",
        "Throughout the centuries people have explained the rainbow in various ways. Some have accepted "
            + "it as a miracle without physical explanation. To the Hebrews it was a token that there would "
            + "be no more universal floods. The Greeks used to imagine that it was a sign from the gods to "
            + "foretell war or heavy rain. The Norsemen considered the rainbow as a bridge over which the "
            + "gods passed from earth to their home in the sky. Others have tried to explain the phenomenon physically.",
    ]

    /// The words as shown, punctuation attached, in reading order.
    static let words: [String] = paragraphs.flatMap { $0.split(separator: " ").map(String.init) }

    /// Rare words the recognizer is told to expect.
    static let hints = ["Norsemen", "Hebrews", "prism", "raindrops", "phenomenon", "foretell"]
}

// MARK: Alignment (pure)

/// Recognized words against the passage. The recognizer's text is revised as it goes, so each
/// result is aligned afresh from where the current request started; the caller keeps the
/// furthest point ever reached, so green never goes back.
enum ReadingAlignment {
    /// Further than this many words ahead, a heard word is not taken as a skip.
    static let maxSkip = 6

    private static let numbers = ["0": "zero", "1": "one", "2": "two", "3": "three", "4": "four", "5": "five",
                                  "6": "six", "7": "seven", "8": "eight", "9": "nine", "10": "ten", "11": "eleven",
                                  "12": "twelve", "20": "twenty", "100": "hundred",
                                  "1st": "first", "2nd": "second", "3rd": "third"]

    /// A word as compared: lower case, letters and digits only ("Sun's" -> "suns",
    /// "super-imposition" -> "superimposition"), and the recognizer's digits spelled out.
    static func key(_ word: String) -> String {
        let k = String(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
        return numbers[k] ?? k
    }

    static func keys(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map { key(String($0)) }.filter { !$0.isEmpty }
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// Same word, allowing small recognition errors: none when either is short ("the" is not
    /// "they"), one edit up to 7 letters ("prison" for "prism"), two beyond.
    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let longest = max(a.count, b.count)
        let allowed = min(a.count, b.count) <= 3 ? 0 : longest <= 7 ? 1 : 2
        return allowed > 0 && distance(a, b) <= allowed
    }

    /// How many heard words, starting at `i`, match the passage word at `j`, and the passage
    /// index after it; nil when they do not. Joining two words on either side covers a split
    /// ("rain drops") and a contraction ("there's" for "there is").
    private static func match(_ heard: [String], _ i: Int, _ passage: [String], _ j: Int) -> (heard: Int, next: Int)? {
        if similar(heard[i], passage[j]) { return (1, j + 1) }
        if i + 1 < heard.count, similar(heard[i] + heard[i + 1], passage[j]) { return (2, j + 1) }
        // Not when the heard word is just the second one ("prism" is not "a prism": the "a"
        // was not heard).
        if j + 1 < passage.count, !similar(heard[i], passage[j + 1]), similar(heard[i], passage[j] + passage[j + 1]) { return (1, j + 2) }
        return nil
    }

    /// The passage index reached after `heard` (keys), read from `start`. Each heard word is
    /// looked for a little ahead, so a skipped or misheard word does not stop the rest; a word
    /// already passed (a repeat) matches nothing ahead and is ignored. A longer jump needs the
    /// next heard word to agree, so a stray "the" or one repeated word cannot race ahead.
    static func reach(heard: [String], passage: [String], from start: Int) -> Int {
        align(heard: heard, passage: passage, from: start).reached
    }

    struct Alignment: Equatable {
        var reached: Int
        /// Passage words recognized.
        var matched: [Int] = []
        /// Passage words passed over where the recognizer heard a word plausibly theirs
        /// (`plausible`): said, but misrecognized. A gap with nothing heard in it, or only
        /// unrelated words ("um", a repeat), was not said.
        var misheard: [Int] = []
    }

    /// `reach`, with which words were matched and which misheard on the way.
    static func align(heard: [String], passage: [String], from start: Int) -> Alignment {
        var pos = min(max(0, start), passage.count)
        var result = Alignment(reached: pos)
        /// Heard words that matched nothing since the last match.
        var unplaced: [String] = []
        var i = 0
        while i < heard.count, pos < passage.count {
            let word = heard[i]
            let before = pos
            let limit = min(passage.count, pos + 1 + maxSkip)
            // A short word ("the", "of") is everywhere: it needs the next heard word to agree
            // before it skips more than one; a longer one, more than two.
            let free = word.count <= 3 ? 1 : 2
            var taken = 1
            for j in pos..<limit {
                guard let m = match(heard, i, passage, j) else { continue }
                if j - pos > free {
                    let after = i + m.heard
                    guard after < heard.count,
                          (m.next..<min(passage.count, m.next + 2)).contains(where: { similar(heard[after], passage[$0]) }) else { continue }
                }
                // A gap word counts as said only for a heard word plausibly it, each used once.
                for gap in pos..<j {
                    if let k = unplaced.firstIndex(where: { plausible($0, passage[gap]) }) {
                        result.misheard.append(gap)
                        unplaced.remove(at: k)
                    }
                }
                unplaced = []
                result.matched.append(contentsOf: j..<m.next)
                pos = m.next
                taken = m.heard
                break
            }
            if pos == before { unplaced.append(word) }
            i += taken
        }
        result.reached = pos
        return result
    }

    /// A heard word that could be `word` misrecognized: within `similar`'s edits plus one, the
    /// same first three letters, or the same consonant sounds. "prison" for "prism" is; "um",
    /// "like" or a repeated earlier word in its place are not.
    static func plausible(_ heard: String, _ word: String) -> Bool {
        guard !heard.isEmpty, !word.isEmpty else { return false }
        if similar(heard, word) { return true }
        let longest = max(heard.count, word.count)
        let allowed = (min(heard.count, word.count) <= 3 ? 0 : longest <= 7 ? 1 : 2) + 1
        if distance(heard, word) <= allowed { return true }
        if heard.count >= 3, word.count >= 3, heard.prefix(3) == word.prefix(3) { return true }
        let a = sound(heard), b = sound(word)
        return a.count >= 2 && a == b
    }

    /// A rough sound key: the first letter, then consonants with like-sounding ones folded
    /// together, vowels and repeats dropped ("Norsemen" and "nor semen" agree).
    static func sound(_ word: String) -> String {
        let w = Array(word.lowercased().replacingOccurrences(of: "ph", with: "f").replacingOccurrences(of: "ck", with: "k"))
        guard let first = w.first else { return "" }
        let fold: [Character: Character] = ["c": "k", "q": "k", "z": "s", "v": "f", "d": "t", "b": "p", "g": "k", "j": "k"]
        var out = String(first)
        var last = fold[first] ?? first
        for c in w.dropFirst() {
            guard !"aeiouyhw".contains(c) else { last = " "; continue }
            let f = fold[c] ?? c
            if f != last { out.append(f) }
            last = f
        }
        return out
    }

    /// The words that count as read: those matched or plausibly misheard, and a short word (3 letters or
    /// fewer) passed over between two matched ones with a third matched beside them.
    /// Recognizers drop "the" and "a"; that is not a word the owner left out. Hearing only every
    /// other word credits nothing: no gap of it is alone.
    static func credited(_ matched: Set<Int>, misheard: Set<Int> = [], passage: [String]) -> Set<Int> {
        var out = matched.union(misheard)
        for i in passage.indices where !out.contains(i) && passage[i].count <= 3
            && matched.contains(i - 1) && matched.contains(i + 1) && (matched.contains(i - 2) || matched.contains(i + 2)) {
            out.insert(i)
        }
        return out
    }
}

// MARK: Sentences (pure)

/// The passage one sentence at a time (as Siri setup and Common Voice show it): word ranges of
/// each sentence, in passage word indices.
struct ReadingSentences: Equatable {
    let ranges: [Range<Int>]

    /// A sentence ends at a word ending in . ? or ! (a trailing quote or bracket allowed).
    init(words: [String] = ReadingPassage.words) {
        var out: [Range<Int>] = []
        var start = 0
        for (i, w) in words.enumerated() {
            let end = w.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]"))
            if let last = end.last, ".?!".contains(last) {
                out.append(start..<(i + 1))
                start = i + 1
            }
        }
        if start < words.count { out.append(start..<words.count) }
        ranges = out
    }

    var count: Int { ranges.count }

    /// The sentence being read when `reached` words are green; `count` once all are.
    func index(at reached: Int) -> Int {
        ranges.firstIndex { reached < $0.upperBound } ?? count
    }

    /// `reached`, or the end of the current sentence when only its last word or two are
    /// missing and the owner has stopped talking: a word the recognizer missed does not hold
    /// back the next sentence (which is not shown until this one is done).
    func settled(reached: Int, quietFor: TimeInterval) -> Int {
        let i = index(at: reached)
        guard i < count, reached > ranges[i].lowerBound else { return reached }
        let left = ranges[i].upperBound - reached
        return left <= ReadingCompletion.tailWords && quietFor >= ReadingCompletion.tailQuietSeconds ? ranges[i].upperBound : reached
    }
}

// MARK: Which sentences are read (pure)

/// Sentence by sentence, with rigor: the alignment may run past words it never heard (so one
/// missed word does not stop the reading), but a sentence only counts as read when most of its
/// words were really heard, and the passage when most of all of them were. Otherwise that one
/// sentence is asked for once more.
struct ReadingState: Equatable {
    static let sentenceShare = 0.8
    static let passageShare = 0.85

    let sentences: ReadingSentences
    let passage: [String]
    private(set) var done = Set<Int>()
    /// The sentence asked for once more, if any.
    private(set) var again: Int?

    init(sentences: ReadingSentences = ReadingSentences(), passage: [String] = ReadingPassage.words.map(ReadingAlignment.key)) {
        self.sentences = sentences
        self.passage = passage
    }

    /// The first sentence not read yet; `sentences.count` once all are.
    var current: Int { (0..<sentences.count).first { !done.contains($0) } ?? sentences.count }
    var allRead: Bool { current == sentences.count }

    static func share(_ range: Range<Int>, _ credited: Set<Int>) -> Double {
        range.isEmpty ? 1 : Double(range.filter(credited.contains).count) / Double(range.count)
    }

    /// At least `share` of the words, rounded down to whole words: 6 of an 8-word sentence at
    /// 80 % (one misheard and one dropped "the" is still a reading), never 4.
    static func enough(_ range: Range<Int>, _ credited: Set<Int>, _ share: Double) -> Bool {
        range.filter(credited.contains).count >= Int((Double(range.count) * share).rounded(.down))
    }

    /// Where the reading must be followed from, and the sentence whose words are forgotten
    /// because it is read once more (it must pass on that reading alone, not with half of it
    /// from each).
    struct Move: Equatable {
        var to: Int
        var forget: Range<Int>?
    }

    /// Judges the sentences the reading has got past. Returns where to follow the reading from
    /// when it must move (back to a sentence to read once more, or on to the first sentence not
    /// read after one was), else nil.
    mutating func update(reached: Int, matched: Set<Int>, misheard: Set<Int> = []) -> Move? {
        let credited = ReadingAlignment.credited(matched, misheard: misheard, passage: passage)
        while current < sentences.count {
            let i = current, r = sentences.ranges[i]
            guard reached >= r.upperBound else { break }
            guard Self.enough(r, credited, Self.sentenceShare) else {
                again = i
                return Move(to: r.lowerBound, forget: r)
            }
            done.insert(i)
            if again == i { again = nil }
        }
        if allRead {
            let all = 0..<passage.count
            guard !Self.enough(all, credited, Self.passageShare),
                  let weakest = sentences.ranges.indices.min(by: { Self.share(sentences.ranges[$0], credited) < Self.share(sentences.ranges[$1], credited) })
            else { return nil }
            done.remove(weakest)
            again = weakest
            return Move(to: sentences.ranges[weakest].lowerBound, forget: sentences.ranges[weakest])
        }
        // After a sentence read once more, on to the first one not read yet.
        let next = sentences.ranges[current].lowerBound
        return reached < next ? Move(to: next) : nil
    }
}

// MARK: Completion (pure)

enum ReadingVerdict: Equatable {
    case reading
    case done
    /// The passage is read but Silero heard fewer seconds of speech than a voiceprint needs.
    case tooLittleSpeech(Double)
}

enum ReadingCompletion {
    /// About 5 CAM++ segments of 6 s, plus slack.
    static let minSpeechSeconds = 35.0
    /// A sentence's last words may be missed by the recognizer once the owner has stopped talking.
    static let tailWords = 2
    static let tailQuietSeconds = 2.0
    /// This much speech with no word recognized: recognition is not hearing the owner.
    static let silentRecognizerSeconds = 20.0

    static func verdict(allRead: Bool, speechSeconds: Double) -> ReadingVerdict {
        guard allRead else { return .reading }
        return speechSeconds >= minSpeechSeconds ? .done : .tooLittleSpeech(speechSeconds)
    }
}

// MARK: How each word shows (pure)

enum WordStyle: Equatable {
    /// Heard: fully green.
    case read
    /// Passed over without being heard: a dim green.
    case skipped
    case next, unread
    /// Not followed (no tracking): plain text.
    case plain

    static func styles(count: Int, reached: Int, tracking: Bool) -> [WordStyle] {
        guard tracking else { return Array(repeating: .plain, count: count) }
        return (0..<count).map { $0 < reached ? .read : $0 == reached ? .next : .unread }
    }

    /// Passage words `range`, `reached` and `matched` in passage indices.
    static func styles(range: Range<Int>, reached: Int, matched: Set<Int>) -> [WordStyle] {
        range.map { $0 < reached ? (matched.contains($0) ? .read : .skipped) : $0 == reached ? .next : .unread }
    }
}

// MARK: The recognizer

enum ReadingTrackingAvailability: Equatable, Sendable {
    case available
    case unavailable(String)

    enum Auth: Sendable { case authorized, denied, restricted, notDetermined }

    /// Why the reading cannot be followed, or `.available`. On-device only: audio never leaves
    /// the Mac, so a recognizer that would need Apple's servers counts as unavailable.
    static func from(hasUsageText: Bool, auth: Auth, recognizerExists: Bool, onDevice: Bool, isAvailable: Bool) -> Self {
        guard hasUsageText else { return .unavailable("this build has no speech-recognition permission text (run the app bundle from scripts/build-app.sh)") }
        switch auth {
        case .denied: return .unavailable("speech recognition is turned off for Learner Desktop (System Settings › Privacy & Security › Speech Recognition)")
        case .restricted: return .unavailable("speech recognition is restricted on this Mac")
        case .notDetermined: return .unavailable("speech recognition permission was not given")
        case .authorized: break
        }
        guard recognizerExists else { return .unavailable("this Mac has no English speech recognizer") }
        guard onDevice else { return .unavailable("on-device English recognition is not installed (System Settings › Keyboard › Dictation), and audio is never sent off this Mac") }
        guard isAvailable else { return .unavailable("the speech recognizer is busy or unavailable right now") }
        return .available
    }
}

enum ReadingRecognizerEvent: Equatable, Sendable {
    /// The current request's whole best transcription so far (it may revise earlier words).
    case transcript(String)
    /// The request ended (they last about a minute) or failed; nil when it simply finished.
    case ended(String?)
}

/// What follows the reading; a fake in tests. `append` is called on the VAD queue.
protocol ReadingRecognizer: AnyObject, Sendable {
    /// Asks for permission on first use; answers on the main thread.
    @MainActor func prepare(_ done: @escaping @MainActor @Sendable (ReadingTrackingAvailability) -> Void)
    /// Starts a new request (ending any current one); events arrive on the main thread.
    @MainActor func start(_ events: @escaping @MainActor @Sendable (ReadingRecognizerEvent) -> Void)
    func append(_ frames: [SileroVAD.Frame])
    @MainActor func stop()
}

/// SFSpeechRecognizer on device, fed the coach's own 16 kHz frames as PCM buffers.
final class AppleReadingRecognizer: ReadingRecognizer, @unchecked Sendable {
    private let lock = NSLock()
    // Under `lock`.
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(VoiceID.sampleRate), channels: 1, interleaved: false)
    /// False only for the heavy test, which runs where permission is already granted but has
    /// no Info.plist of its own.
    private let requireUsageText: Bool

    init(requireUsageText: Bool = true) { self.requireUsageText = requireUsageText }

    @MainActor func prepare(_ done: @escaping @MainActor @Sendable (ReadingTrackingAvailability) -> Void) {
        // Without the Info.plist text, asking for permission kills the process (TCC): it is only
        // ever asked for with the text present.
        let bundled = Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
        let hasText = bundled || !requireUsageText
        let answer: @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void = { status in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { done(self.availability(hasText: hasText, status: status)) }
            }
        }
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined, bundled { SFSpeechRecognizer.requestAuthorization(answer) } else { answer(status) }
    }

    @MainActor private func availability(hasText: Bool, status: SFSpeechRecognizerAuthorizationStatus) -> ReadingTrackingAvailability {
        let auth: ReadingTrackingAvailability.Auth
        switch status {
        case .authorized: auth = .authorized
        case .denied: auth = .denied
        case .restricted: auth = .restricted
        default: auth = .notDetermined
        }
        let r = auth == .authorized ? SFSpeechRecognizer(locale: Locale(identifier: "en-US")) : nil
        lock.withLock { recognizer = r }
        return .from(hasUsageText: hasText, auth: auth, recognizerExists: r != nil,
                     onDevice: r?.supportsOnDeviceRecognition ?? false, isAvailable: r?.isAvailable ?? false)
    }

    @MainActor func start(_ events: @escaping @MainActor @Sendable (ReadingRecognizerEvent) -> Void) {
        let deliver: @Sendable (ReadingRecognizerEvent) -> Void = { e in
            DispatchQueue.main.async { MainActor.assumeIsolated { events(e) } }
        }
        // Speech is never called under `lock`: its handler takes the lock, and might be called
        // before recognitionTask returns.
        let (old, recognizer, g) = lock.withLock { () -> ((SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?), SFSpeechRecognizer?, Int) in
            generation += 1
            defer { request = nil; task = nil }
            return ((request, task), self.recognizer, generation)
        }
        Self.end(old)
        guard let recognizer, recognizer.supportsOnDeviceRecognition else { deliver(.ended("no on-device recognizer")); return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.contextualStrings = ReadingPassage.hints
        let ended = Locked(false)
        // Set before the task exists, so audio appended meanwhile is not lost.
        lock.withLock { if generation == g { request = req } }
        let t = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self, self.lock.withLock({ self.generation == g }) else { return }
            if let result { deliver(.transcript(result.bestTranscription.formattedString)) }
            guard error != nil || result?.isFinal == true else { return }
            // Only one end per request, though an error may follow a final result.
            guard ended.withLock({ e in defer { e = true }; return !e }) else { return }
            deliver(.ended(error?.localizedDescription))
        }
        let stale = lock.withLock { () -> Bool in
            guard generation == g else { return true }
            task = t
            return false
        }
        if stale { Self.end((req, t)) }   // stopped while it was being made
    }

    func append(_ frames: [SileroVAD.Frame]) {
        // Appending to a request that just ended is harmless (it ignores it).
        guard let request = lock.withLock({ self.request }), let format else { return }
        let count = frames.reduce(0) { $0 + $1.samples.count }
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let out = buffer.floatChannelData?[0] else { return }
        var at = 0
        for f in frames {
            f.samples.withUnsafeBufferPointer { out.advanced(by: at).update(from: $0.baseAddress!, count: $0.count) }
            at += f.samples.count
        }
        buffer.frameLength = AVAudioFrameCount(count)
        request.append(buffer)
    }

    @MainActor func stop() {
        let old = lock.withLock { () -> (SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?) in
            generation += 1
            defer { request = nil; task = nil }
            return (request, task)
        }
        Self.end(old)
    }

    /// Ends a request (outside `lock`); its late callbacks are dropped by the generation check.
    private static func end(_ old: (SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?)) {
        old.0?.endAudio()
        old.1?.cancel()
    }
}

// MARK: The tracker (main thread)

/// The furthest passage word heard, across recognition requests: a request ends after about a
/// minute (or on an error), and the next one is started from where the last left off.
@MainActor
final class ReadingTracker {
    let recognizer: ReadingRecognizer
    let passage: [String]
    private(set) var reached = 0
    /// Passage words actually heard (not just passed over), across requests; and those heard
    /// as some other word.
    private(set) var matched = Set<Int>()
    private(set) var misheard = Set<Int>()
    private(set) var running = false
    private(set) var restarts = 0
    /// Set when recognition kept failing at once: the reading is no longer followed.
    private(set) var failure: String?
    /// Requests ending this soon after they start count as failing at once.
    static let quickEnd: TimeInterval = 1
    static let maxQuickEnds = 5
    var restartDelay: TimeInterval = 0.25
    var now: () -> Date = Date.init
    private var base = 0
    /// Words of the current request's transcript already accounted for by a `skip`.
    private var offset = 0
    private var lastHeard = 0
    private var round = 0
    private var startedAt = Date.distantPast
    private var quickEnds = 0
    private let log = Log("VoiceID")

    init(recognizer: ReadingRecognizer, words: [String] = ReadingPassage.words) {
        self.recognizer = recognizer
        passage = words.map(ReadingAlignment.key)
    }

    var total: Int { passage.count }

    func start() {
        reached = 0
        matched = []
        misheard = []
        base = 0
        offset = 0
        lastHeard = 0
        restarts = 0
        quickEnds = 0
        failure = nil
        running = true
        begin()
    }

    /// Follow the reading from `to`: on past a sentence's missed last words, or back to a
    /// sentence to read once more. What this request already heard is not aligned again.
    func move(to: Int) {
        guard to != reached else { return }
        reached = min(max(0, to), total)
        base = reached
        offset = lastHeard
    }

    /// A sentence read once more starts from nothing heard.
    func forget(_ range: Range<Int>) {
        matched.subtract(range)
        misheard.subtract(range)
    }

    func stop() {
        guard running else { return }
        running = false
        round += 1
        recognizer.stop()
    }

    private func begin() {
        round += 1
        let r = round
        startedAt = now()
        recognizer.start { [weak self] event in self?.handle(event, round: r) }
    }

    func handle(_ event: ReadingRecognizerEvent, round r: Int) {
        guard running, r == round else { return }
        switch event {
        case .transcript(let text):
            quickEnds = 0
            let heard = ReadingAlignment.keys(text)
            lastHeard = heard.count
            let fresh = Array(heard.dropFirst(min(offset, heard.count)))
            let a = ReadingAlignment.align(heard: fresh, passage: passage, from: base)
            reached = max(reached, a.reached)
            matched.formUnion(a.matched)
            misheard.formUnion(a.misheard)
        case .ended(let why):
            // The next request picks up where this one got to; its words are kept.
            base = reached
            offset = 0
            lastHeard = 0
            restarts += 1
            if now().timeIntervalSince(startedAt) < Self.quickEnd { quickEnds += 1 }
            if quickEnds >= Self.maxQuickEnds {
                failure = "speech recognition kept stopping" + (why.map { ": \($0)" } ?? "")
                log.warn("reading not followed any more: \(failure!)")
                stop()
                return
            }
            log.info("recognition request ended at word \(reached) of \(total)\(why.map { " (\($0))" } ?? ""); starting another")
            if restartDelay <= 0 { begin(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + restartDelay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.running, self.round == r else { return }
                    self.begin()
                }
            }
        }
    }
}
