import AppKit
import CoreAudio
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

    /// The words as compared (`ReadingAlignment.key`), worked out once.
    static let keys: [String] = words.map(ReadingAlignment.key)

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

    /// Edit distance over UTF-8 bytes (keys are lower-case letters and digits: one byte each
    /// for the passage's words). Called for every candidate word: no heap, and it stops as soon
    /// as the distance is past `limit` (returning `limit + 1`).
    static func distance(_ a: String, _ b: String, limit: Int = Int.max - 1) -> Int {
        var a = a, b = b
        return a.withUTF8 { pa in
            b.withUTF8 { pb in
                let n = pa.count, m = pb.count
                if n == 0 { return min(m, limit + 1) }
                if m == 0 { return min(n, limit + 1) }
                if abs(n - m) > limit { return limit + 1 }
                return withUnsafeTemporaryAllocation(of: Int.self, capacity: 2 * (m + 1)) { buf in
                    var prev = 0, cur = m + 1
                    for j in 0...m { buf[prev + j] = j }
                    for i in 1...n {
                        buf[cur] = i
                        var best = i
                        for j in 1...m {
                            let v = Swift.min(buf[prev + j] + 1, buf[cur + j - 1] + 1, buf[prev + j - 1] + (pa[i - 1] == pb[j - 1] ? 0 : 1))
                            buf[cur + j] = v
                            best = Swift.min(best, v)
                        }
                        if best > limit { return limit + 1 }
                        swap(&prev, &cur)
                    }
                    return Swift.min(buf[prev + m], limit + 1)
                }
            }
        }
    }

    /// Same word, allowing small recognition errors: none when either is short ("the" is not
    /// "they"), one edit up to 7 letters ("prison" for "prism"), two beyond.
    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let la = a.utf8.count, lb = b.utf8.count
        let allowed = min(la, lb) <= 3 ? 0 : max(la, lb) <= 7 ? 1 : 2
        // More letters apart than edits allowed: no need to count them.
        return allowed > 0 && abs(la - lb) <= allowed && distance(a, b, limit: allowed) <= allowed
    }

    /// How many heard words, starting at `i`, match the passage word at `j`, and the passage
    /// index after it; nil when they do not. Joining two words on either side covers a split
    /// ("rain drops") and a contraction ("there's" for "there is").
    private static func match(_ heard: [String], _ i: Int, _ passage: [String], _ j: Int) -> (heard: Int, next: Int)? {
        if similar(heard[i], passage[j]) { return (1, j + 1) }
        if i + 1 < heard.count, similar(heard[i] + heard[i + 1], passage[j]) { return (2, j + 1) }
        // Not when the heard word is just the second one ("prism" is not "a prism": the "a"
        // was not heard).
        // At most one edit: a merge of two other words ("Whensunlight") is not "the sunlight".
        if j + 1 < passage.count, !similar(heard[i], passage[j + 1]) {
            let pair = passage[j] + passage[j + 1]
            if heard[i] == pair || (min(heard[i].utf8.count, pair.utf8.count) > 3 && distance(heard[i], pair, limit: 1) <= 1) { return (1, j + 2) }
        }
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
        /// The passage position after each heard word.
        var positions: [Int] = []
        /// The heard word matched last, if any.
        var lastMatchedHeard: Int?
        /// Per heard word: whether it matched a passage word.
        var hits: [Bool] = []
    }

    /// `reach`, with which words were matched and which misheard on the way.
    /// `catchUpTo`: further than the usual few words, up to this passage index, two heard words
    /// in a row that agree with two passage words in a row (one of them longer than 3 letters)
    /// are taken as the reading having got there: words lost in a row (the recognizer dropped
    /// them, or a request began a few words on) do not stop it. The words passed over are not
    /// credited.
    /// `passed`: words the reading already went past (the current sentence so far): a pair that
    /// also agrees with two of those is a re-read, never a catch-up. `strictShort`: after heard
    /// words that placed nowhere (the reading is lost), a short word never skips a word without
    /// the next heard word agreeing (words aligned again and again while lost must not land on a
    /// stray "a" or "and").
    static func align(heard: [String], passage: [String], from start: Int, catchUpTo: Int? = nil,
                      passed: Range<Int>? = nil, strictShort: Bool = false) -> Alignment {
        var pos = min(max(0, start), passage.count)
        var result = Alignment(reached: pos)
        result.hits = Array(repeating: false, count: heard.count)
        /// Heard words that matched nothing since the last match.
        var unplaced: [String] = []
        var i = 0
        while i < heard.count, pos < passage.count {
            let word = heard[i]
            let before = pos
            let limit = min(passage.count, pos + 1 + maxSkip)
            // A short word ("the", "of") is everywhere: it needs the next heard word to agree
            // before it skips more than one; a longer one, more than two.
            // While lost (heard words just before it placed nowhere), a short word does not skip
            // on its own: "a" or "and" from a later sentence must not land here.
            let free = word.utf8.count <= 3 ? (strictShort && !unplaced.isEmpty ? 0 : 1) : 2
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
                result.lastMatchedHeard = i + m.heard - 1
                for h in i..<(i + m.heard) { result.hits[h] = true }
                pos = m.next
                taken = m.heard
                break
            }
            if pos == before, let bound = catchUpTo, i + 1 < heard.count, max(word.count, heard[i + 1].count) > 3,
               limit < bound - 1,
               let j = (limit..<min(bound, passage.count) - 1).first(where: { similar(word, passage[$0]) && similar(heard[i + 1], passage[$0 + 1]) }),
               !(passed ?? 0..<0).contains(where: { $0 + 1 < passage.count && similar(word, passage[$0]) && similar(heard[i + 1], passage[$0 + 1]) }) {
                unplaced = []
                result.matched.append(contentsOf: [j, j + 1])
                result.lastMatchedHeard = i + 1
                result.hits[i] = true
                result.hits[i + 1] = true
                pos = j + 2
                taken = 2
            }
            if pos == before { unplaced.append(word) }
            result.positions.append(contentsOf: Array(repeating: pos, count: taken))
            i += taken
        }
        // Words after the end of the passage stay there.
        result.positions.append(contentsOf: Array(repeating: pos, count: max(0, heard.count - result.positions.count)))
        result.reached = pos
        return result
    }

    /// A heard word that could be `word` misrecognized: within `similar`'s edits plus one, the
    /// same first three letters, or the same consonant sounds. "prison" for "prism" is; "um",
    /// "like" or a repeated earlier word in its place are not.
    static func plausible(_ heard: String, _ word: String) -> Bool {
        guard !heard.isEmpty, !word.isEmpty else { return false }
        if similar(heard, word) { return true }
        let lh = heard.utf8.count, lw = word.utf8.count
        let allowed = (min(lh, lw) <= 3 ? 0 : max(lh, lw) <= 7 ? 1 : 2) + 1
        if abs(lh - lw) <= allowed, distance(heard, word, limit: allowed) <= allowed { return true }
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

    /// The passage's, worked out once.
    static let passage = ReadingSentences()

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

    init(sentences: ReadingSentences = .passage, passage: [String] = ReadingPassage.keys) {
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
        // Mostly the reading is inside the current sentence: nothing to judge.
        if current < sentences.count, sentences.ranges[current].contains(reached) { return nil }
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
    /// This much speech with no result at all: the request is replaced.
    static let quietRequestSeconds = 8.0
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

/// One recognized word and when it was heard, in seconds from the start of the request's audio
/// (0 when the recognizer gives no times, as some partial results do).
struct ReadingSegment: Equatable, Sendable {
    var word: String
    var start: TimeInterval = 0
    var duration: TimeInterval = 0
}

enum ReadingRecognizerEvent: Equatable, Sendable {
    /// The current request's best transcription so far, word by word. The recognizer revises
    /// it as it goes: it merges and splits words, and may start it afresh after a pause.
    case transcript([ReadingSegment])
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
            if let result {
                deliver(.transcript(result.bestTranscription.segments.map {
                    ReadingSegment(word: $0.substring, start: $0.timestamp, duration: $0.duration)
                }))
            }
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
/// minute (or on an error, or when it goes quiet), and the next one is started from where the
/// last left off.
///
/// The recognizer's transcript is not an append-only log: it revises its last words, merges
/// and splits words ("rain drops" -> "raindrops"), drops and adds fillers, sends an empty
/// result now and then, and may begin again from nothing after a pause. Real partial results
/// carry no word times (0 of 219 in the self-test), so each result is compared with the last
/// by a word diff (a longest common subsequence of keys): words it keeps are already followed;
/// only words after the last kept one are new, aligned from where the reading is (never from
/// behind it). Revised words between kept ones only add credit, inside the span they belong
/// to. A result sharing little with the last, on the diagonal, is a fresh transcript: aligned
/// from where it fits best, so a repeated sentence lands on itself, not on the words ahead.
/// After a move back to read a sentence again, every word heard before the move stays old
/// (never credited again) until a fresh transcript arrives.
@MainActor
final class ReadingTracker {
    let recognizer: ReadingRecognizer
    /// What was followed of the reading so far.
    private(set) var follower: ReadingFollower
    private(set) var running = false
    private(set) var restarts = 0
    /// Set when recognition kept failing at once: the reading is no longer followed.
    private(set) var failure: String?
    /// Requests ending this soon after they start count as failing at once.
    static let quickEnd: TimeInterval = 1
    static let maxQuickEnds = 5
    var restartDelay: TimeInterval = 0.25
    var now: () -> Date = Date.init
    /// Seconds of speech heard so far (Silero's, from the controller), or nil (tests that do
    /// not model it). After a move back, a result counts as a fresh transcript only once there
    /// was new speech: the recognizer re-decoding the old audio is not a new reading.
    var speechSeconds: (() -> Double)?
    private var round = 0
    private var startedAt = Date.distantPast
    private var quickEnds = 0
    private let log = Log("VoiceID")
    private let words: [String]

    // Diagnostics (counts only, never the words).
    private(set) var results = 0
    private(set) var lastResultAt: Date?

    init(recognizer: ReadingRecognizer, words: [String] = ReadingPassage.words) {
        self.recognizer = recognizer
        self.words = words
        follower = ReadingFollower(words: words)
    }

    var passage: [String] { follower.passage }
    var sentences: ReadingSentences { follower.sentences }
    var total: Int { follower.total }
    var reached: Int { follower.reached }
    var matched: Set<Int> { follower.matched }
    var misheard: Set<Int> { follower.misheard }
    var transcriptWords: Int { follower.transcriptWords }
    var alignedSinceMove: Int { follower.alignedSinceMove }
    var timedResults: Int { follower.timedResults }
    var freshTranscripts: Int { follower.freshTranscripts }

    func start() {
        follower = ReadingFollower(words: words)
        restarts = 0
        quickEnds = 0
        failure = nil
        results = 0
        lastResultAt = nil
        running = true
        begin()
    }

    func move(to: Int) { follower.move(to: to, speech: speechSeconds?()) }

    func forget(_ range: Range<Int>) { follower.forget(range) }

    func stop() {
        guard running else { return }
        running = false
        round += 1
        recognizer.stop()
    }

    /// Ends the current request and starts another (it went quiet while the owner talks).
    func restartRequest(_ why: String) {
        guard running else { return }
        recognizer.stop()
        restarts += 1
        follower.newRequest()
        log.info("recognition request ended at word \(reached) of \(total) (\(why)); starting another")
        begin()
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
        case .transcript(let segments):
            quickEnds = 0
            results += 1
            lastResultAt = now()
            follower.hear(segments, speech: speechSeconds?())
        case .ended(let why):
            // The next request picks up where this one got to; its words are kept.
            follower.newRequest()
            restarts += 1
            if now().timeIntervalSince(startedAt) < Self.quickEnd { quickEnds += 1 }
            if quickEnds >= Self.maxQuickEnds {
                failure = "speech recognition kept stopping" + (why.map { ": \($0)" } ?? "")
                log.warn("reading not followed any more: \(failure!)")
                stop()
                return
            }
            log.info("recognition request ended at word \(reached) of \(total)\(why.map { " (\($0))" } ?? " (final result)"); starting another")
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

/// The transcript-following state and logic, kept apart from the main-actor tracker: plain
/// values, no actor isolation (per-word closures in a main-actor class are checked on every
/// call, which made following a 180-word transcript several times slower).
struct ReadingFollower {
    let passage: [String]
    let sentences: ReadingSentences
    /// Kept words further than this off the diagonal do not show a continuation.
    static let drift = 4
    /// After a move back, a result counts as a fresh transcript only with this much new speech.
    static let newSpeechSeconds = 1.0

    private(set) var reached = 0
    /// Passage words actually heard (not just passed over), across requests; and those heard
    /// as some other word.
    private(set) var matched = Set<Int>()
    private(set) var misheard = Set<Int>()

    /// A word of the last result: its key, the passage position after it, whether it was heard
    /// before the last move (old: never aligned or credited again), and whether it matched.
    private struct Heard {
        var key: String
        var at: Int
        var old: Bool
        var hit = false
    }
    private var previous: [Heard] = []
    private var keyCache: [String: String] = [:]
    private var speechAtMove: Double?
    /// The words a settle moved past, still expected (see `move`).
    private var pendingTail: [Int] = []

    // Diagnostics (counts only, never the words).
    private(set) var transcriptWords = 0
    private(set) var alignedSinceMove = 0
    private(set) var timedResults = 0
    private(set) var freshTranscripts = 0

    init(words: [String] = ReadingPassage.words) {
        let standard = words == ReadingPassage.words
        passage = standard ? ReadingPassage.keys : words.map(ReadingAlignment.key)
        sentences = standard ? .passage : ReadingSentences(words: words)
    }

    var total: Int { passage.count }

    /// A new request: its transcript starts from nothing.
    mutating func newRequest() {
        previous = []
        speechAtMove = nil
        transcriptWords = 0
        pendingTail = []
    }

    /// Follow the reading from `to`: on past a sentence's missed last words, or back to a
    /// sentence to read once more. Nothing heard so far is aligned or credited again, however
    /// the recognizer revises it. `speech`: seconds of speech so far, when known.
    mutating func move(to: Int, speech: Double?) {
        guard to != reached else { return }
        let back = to < reached
        // On past a sentence's last word or two (the owner paused before them): if those words
        // come next, they belong to that sentence, not the next.
        pendingTail = !back && to - reached <= ReadingCompletion.tailWords ? Array(reached..<min(to, total)) : []
        reached = min(max(0, to), total)
        for i in previous.indices { previous[i].old = true; previous[i].at = reached; previous[i].hit = false }
        alignedSinceMove = 0
        if back { speechAtMove = speech }
    }

    /// A sentence read once more starts from nothing heard.
    mutating func forget(_ range: Range<Int>) {
        matched.subtract(range)
        misheard.subtract(range)
    }

    /// One recognition result. `speech`: seconds of speech so far, when known.
    mutating func hear(_ segments: [ReadingSegment], speech: Double?) {
        if segments.contains(where: { $0.start > 0 }) { timedResults += 1 }
        // Results repeat the whole transcript, a few times a second: keys are kept.
        var keys: [String] = []
        keys.reserveCapacity(segments.count)
        for seg in segments {
            let k: String
            if let c = keyCache[seg.word] { k = c } else { k = ReadingAlignment.key(seg.word); keyCache[seg.word] = k }
            if !k.isEmpty { keys.append(k) }
        }
        // An empty result says nothing: the last one is kept.
        guard !keys.isEmpty else { return }
        transcriptWords = keys.count
        let kept = Self.diff(previous.map(\.key), keys)
        let diagonal = kept.filter { abs($0.a - $0.b) <= Self.drift }.count
        if previous.isEmpty || diagonal * 2 < keys.count {
            // After a move back, the same request's audio before the move is not fresh.
            if !previous.isEmpty, let at = speechAtMove, let heard = speech, heard - at < Self.newSpeechSeconds {
                previous = keys.map { Heard(key: $0, at: reached, old: true) }
                return
            }
            speechAtMove = nil
            fresh(keys)
        } else {
            continuation(keys, kept)
        }
    }

    /// Takes an alignment's words: `reached` on (never back), and only words at or after
    /// `from` credited (a fresh transcript's repeat of words already read adds nothing).
    private mutating func take(_ a: ReadingAlignment.Alignment, creditFrom from: Int = 0) {
        reached = max(reached, a.reached)
        let new = Set(a.matched.filter { $0 >= from }).subtracting(matched)
        alignedSinceMove += new.count
        matched.formUnion(a.matched.filter { $0 >= from })
        misheard.formUnion(a.misheard.filter { $0 >= from })
    }

    /// The longest common subsequence of two key lists, as index pairs in order. The shared
    /// start and end are taken first, so a revision of a few words costs only those words.
    static func diff(_ a: [String], _ b: [String]) -> [(a: Int, b: Int)] {
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        var out = (0..<head).map { (a: $0, b: $0) }
        let n = a.count - head - tail, m = b.count - head - tail
        if n > 0, m > 0 {
            // len[i * (m + 1) + j]: the LCS of a[head + i...] and b[head + j...] (middles only).
            var len = [Int32](repeating: 0, count: (n + 1) * (m + 1))
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    len[i * (m + 1) + j] = a[head + i] == b[head + j] ? len[(i + 1) * (m + 1) + j + 1] + 1
                        : max(len[(i + 1) * (m + 1) + j], len[i * (m + 1) + j + 1])
                }
            }
            var i = 0, j = 0
            while i < n, j < m {
                if a[head + i] == b[head + j] { out.append((head + i, head + j)); i += 1; j += 1 }
                else if len[(i + 1) * (m + 1) + j] >= len[i * (m + 1) + j + 1] { i += 1 } else { j += 1 }
            }
        }
        out += (0..<tail).map { (a: a.count - tail + $0, b: b.count - tail + $0) }
        return out
    }

    /// How far ahead a run of agreeing words may take the reading: to the end of the sentence
    /// after the one `from` is in.
    private func catchUpBound(_ from: Int) -> Int {
        let i = sentences.index(at: from)
        return i + 1 < sentences.count ? sentences.ranges[i + 1].upperBound : total
    }

    /// A transcript begun afresh: aligned from where it fits best, of where the reading is and
    /// the starts of the current and last sentence (a repeat lands on itself); only words from
    /// where the reading is are credited.
    private mutating func fresh(_ all: [String]) {
        freshTranscripts += 1
        // A settled sentence's last words, said after the pause, are its own.
        var peeled = 0
        while peeled < all.count, peeled < pendingTail.count, ReadingAlignment.similar(all[peeled], passage[pendingTail[peeled]]) {
            matched.insert(pendingTail[peeled])
            peeled += 1
        }
        let keys = Array(all[peeled...])
        guard !keys.isEmpty else {
            previous = all.map { Heard(key: $0, at: reached, old: false, hit: true) }
            return
        }
        let i = sentences.index(at: reached)
        var starts = [reached]
        if i < sentences.count { starts.append(sentences.ranges[i].lowerBound) }
        if i > 0 { starts.append(sentences.ranges[i - 1].lowerBound) }
        let candidates = starts.filter { $0 <= reached }.map {
            ReadingAlignment.align(heard: keys, passage: passage, from: $0, catchUpTo: catchUpBound(reached))
        }
        // Most words matched; on a tie, from where the reading is (the first).
        let best = candidates.enumerated().max { a, b in
            a.element.matched.count != b.element.matched.count ? a.element.matched.count < b.element.matched.count : a.offset > b.offset
        }!.element
        take(best, creditFrom: reached)
        if best.hits.contains(true) { pendingTail = [] } else { pendingTail.removeFirst(min(peeled, pendingTail.count)) }
        previous = all[..<peeled].map { Heard(key: $0, at: reached, old: false, hit: true) }
            + keys.indices.map { Heard(key: keys[$0], at: best.positions[$0], old: false, hit: best.hits[$0]) }
    }

    /// The same transcript, revised and grown. Words the diff keeps keep what they matched;
    /// revised words between kept ones may add credit inside their span. Every live word after
    /// the last one that matched is aligned again as a group, from just after it: a word that
    /// could not be placed alone (three words lost before it) is placed once the next word
    /// agrees. Old words (before a move back) and revisions of them stay old.
    private mutating func continuation(_ keys: [String], _ kept: [(a: Int, b: Int)]) {
        var next = [Heard?](repeating: nil, count: keys.count)
        for k in kept { next[k.b] = previous[k.a] }
        let last = kept.last
        // Revisions of an old tail stay old: as many words after the last kept one as old words
        // followed it.
        let oldAfter = last.map { l in previous[(l.a + 1)...].filter(\.old).count } ?? previous.filter(\.old).count
        let tailStart = (last?.b ?? -1) + 1
        let lastOld = last.map { previous[$0.a].old } ?? previous.contains(where: \.old)
        // Revised words between kept ones.
        var b = 0
        while b < tailStart {
            guard next[b] == nil else { b += 1; continue }
            var e = b
            while e < tailStart, next[e] == nil { e += 1 }
            let before = b > 0 ? next[b - 1]! : nil
            let after = next[e]!   // e < tailStart: a kept word
            let from = before?.at ?? 0
            let old = after.old
            var at = [Int](repeating: from, count: e - b)
            var hit = [Bool](repeating: false, count: e - b)
            if !old {
                let a = ReadingAlignment.align(heard: Array(keys[b..<e]), passage: passage, from: from)
                let inside = { (i: Int) in i < after.at && i >= from }
                matched.formUnion(a.matched.filter(inside))
                misheard.formUnion(a.misheard.filter(inside))
                // Each word where it was found, within its span.
                at = a.positions.map { min($0, max(from, after.at - 1)) }
                hit = a.hits
            }
            for i in b..<e { next[i] = Heard(key: keys[i], at: at[i - b], old: old, hit: hit[i - b]) }
            b = e
        }
        let oldEnd = min(lastOld ? tailStart + oldAfter : tailStart, keys.count)
        for i in tailStart..<oldEnd { next[i] = Heard(key: keys[i], at: reached, old: true) }
        // From just after the last live word that matched (or the first live word) to the end.
        let firstLive = next.firstIndex { $0 == nil || !$0!.old } ?? keys.count
        var start = firstLive
        if let lastHit = (firstLive..<keys.count).last(where: { next[$0]?.hit == true }) { start = lastHit + 1 }
        // A settled sentence's last words, said after the pause, are its own.
        while start < keys.count, let t = pendingTail.first, ReadingAlignment.similar(keys[start], passage[t]) {
            matched.insert(t)
            next[start] = Heard(key: keys[start], at: reached, old: false, hit: true)
            pendingTail.removeFirst()
            start += 1
        }
        if start < keys.count {
            let after = start > firstLive ? next[start - 1]!.at : reached
            // Never further back than the words being aligned again could reach.
            let from = min(reached, max(after, reached - (keys.count - start) - 1))
            let (a, _) = group(Array(keys[start...]), from: from)
            // Credit from where the group started: a re-read fills in nothing it did not reach.
            take(a, creditFrom: from)
            if a.hits.contains(true) { pendingTail = [] }
            for (n, i) in (start..<keys.count).enumerated() { next[i] = Heard(key: keys[i], at: a.positions[n], old: false, hit: a.hits[n]) }
        }
        previous = next.map { $0! }
    }

    /// Words aligned again as a group: from `from`, or as the current sentence read again from
    /// its start, whichever places more of them (on a tie, `from`). A re-read lands on the
    /// sentence itself and fills in what it missed; it cannot catch up into the next sentence
    /// on a pair the sentence already had ("the gods", "the rainbow").
    private func group(_ heard: [String], from: Int) -> (ReadingAlignment.Alignment, Int) {
        let i = sentences.index(at: reached)
        let sentenceStart = i < sentences.count ? sentences.ranges[i].lowerBound : reached
        let passed = sentenceStart..<max(sentenceStart, reached)
        let here = ReadingAlignment.align(heard: heard, passage: passage, from: from, catchUpTo: catchUpBound(reached),
                                          passed: passed, strictShort: true)
        guard sentenceStart < from else { return (here, from) }
        let again = ReadingAlignment.align(heard: heard, passage: passage, from: sentenceStart, catchUpTo: catchUpBound(reached),
                                           passed: passed, strictShort: true)
        // A re-read places several words; one stray word ("The") does not make one.
        return again.matched.count >= here.matched.count + 2 ? (again, sentenceStart) : (here, from)
    }
}

// MARK: - Which microphone (for the enrollment window)

/// The default input's name and whether it is Bluetooth: enrollment wants the MacBook's own
/// microphone (a Bluetooth headset switches to call quality when an app listens, and this app
/// leaves it alone).
struct InputDevice: Equatable, Sendable {
    var name: String
    var bluetooth: Bool

    /// The window's live line.
    var line: String {
        bluetooth ? "⚠︎ \(name) is Bluetooth: switch to the MacBook microphone" : "Input now: \(name) ✓"
    }
}

/// Reads the default input on its own queue (Core Audio round trips can take seconds when
/// coreaudiod is busy: never on the main thread, as BluetoothInputWatch), when it changes and
/// every few seconds, and keeps the answer for the main thread. Started on first use.
final class InputDeviceWatch: Sendable {
    static let shared = InputDeviceWatch()
    static let period: TimeInterval = 5

    private let queue = DispatchQueue(label: "learner.input-device", qos: .utility)
    private let state = Locked<InputDevice?>(nil)
    private let read: @Sendable () -> InputDevice?

    init(read: @escaping @Sendable () -> InputDevice? = InputDeviceWatch.defaultInput, listen: Bool = true) {
        self.read = read
        queue.async { [self] in refresh() }
        guard listen else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue) { [weak self] _, _ in
            self?.refresh()
        }
        schedule()
    }

    /// The last answer (nil until the first read is done, or when there is no input).
    var device: InputDevice? { state.value }

    func refresh() { state.value = read() }

    /// Waits until the reads handed to the queue so far are done (tests).
    func settle() { queue.sync {} }

    private func schedule() {
        queue.asyncAfter(deadline: .now() + Self.period) { [weak self] in
            self?.refresh()
            self?.schedule()
        }
    }

    /// A synchronous round trip to coreaudiod: on `queue` only.
    static func defaultInput() -> InputDevice? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        address.mSelector = kAudioObjectPropertyName
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let named = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) } == noErr
        address.mSelector = kAudioDevicePropertyTransportType
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        let typed = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr
        return InputDevice(name: named ? (name?.takeRetainedValue() as String? ?? "Unknown input") : "Unknown input",
                           bluetooth: typed && (transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE))
    }
}
