import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// How a real SFSpeechRecognizer's partial results behave, simulated: the transcript grows word
// by word, its last 1-3 words are revised (a provisional wrong word, then the right one), an
// earlier word now and then gains an "s", fillers come and go, a result may be empty, and after
// a pause it may start afresh. The tracker must follow every word read, never run ahead of the
// reading, and a sentence read again must pass on its new reading alone. (11-12: the first
// real reading stalled at sentence 2; a review then found 62 of 300 simulated readings stalled.)
@MainActor
@Suite("Voice ID guided enrollment (recognizer revisions)", .tags(.light, .voiceID), .timeLimit(.minutes(1)), .quietLog)
struct VoiceEnrollRevisionTests {
    struct LCG: RandomNumberGenerator {
        var s: UInt64
        mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s }
    }

    final class Fake: ReadingRecognizer, @unchecked Sendable {
        private var events: (@MainActor @Sendable (ReadingRecognizerEvent) -> Void)?
        @MainActor func prepare(_ done: @escaping @MainActor @Sendable (ReadingTrackingAvailability) -> Void) { done(.available) }
        @MainActor func start(_ events: @escaping @MainActor @Sendable (ReadingRecognizerEvent) -> Void) { self.events = events }
        func append(_ frames: [SileroVAD.Frame]) {}
        @MainActor func stop() { events = nil }
        @MainActor func hear(_ words: [String], times: [Double]? = nil) {
            events?(.transcript(words.enumerated().map { ReadingSegment(word: $1, start: times?[$0] ?? 0) }))
        }
        @MainActor func end() { events?(.ended(nil)) }
    }

    static let P = ReadingPassage.words
    static let sentences = ReadingSentences()

    static func setup() -> (ReadingTracker, Fake, ReadingState) {
        let f = Fake()
        let t = ReadingTracker(recognizer: f)
        t.restartDelay = 0
        t.start()
        return (t, f, ReadingState())
    }

    /// As the controller does after each result: judge sentences, move when told.
    static func follow(_ t: ReadingTracker, _ st: inout ReadingState) {
        if let m = st.update(reached: t.reached, matched: t.matched, misheard: t.misheard) {
            if let r = m.forget { t.forget(r) }
            t.move(to: m.to)
        }
    }

    static func credited(_ t: ReadingTracker, _ r: Range<Int>) -> Int {
        ReadingAlignment.credited(t.matched, misheard: t.misheard, passage: t.passage).intersection(Set(r)).count
    }

    /// One simulated reading of the whole passage. Returns whether it completed, and the
    /// furthest the tracker ever ran ahead of the words actually read.
    static func read(seed: UInt64, fresh: Bool) -> (completed: Bool, ahead: Int) {
        var g = LCG(s: seed)
        let (t, f, st0) = setup()
        var st = st0
        var tr: [String] = []
        var ahead = 0
        for i in P.indices {
            tr.append(P[i])
            var shown = tr
            let r = Int.random(in: 0..<10, using: &g)
            if r < 6, shown.count > 3 { let k = shown.count - Int.random(in: 1...3, using: &g); shown[k] = "uh" + shown[k] }
            else if r == 6, shown.count > 8 { let k = Int.random(in: 0..<(shown.count - 4), using: &g); shown[k] += "s" }
            else if r == 7, shown.count > 2 { shown.append("um") }
            else if r == 8 { f.hear([]); follow(t, &st) }
            f.hear(shown); follow(t, &st)
            f.hear(tr); follow(t, &st)
            ahead = max(ahead, t.reached - (i + 1))
            if fresh, P[i].hasSuffix("."), Bool.random(using: &g) { tr = [] }
        }
        // The owner stops: a missed last word or two goes.
        let s = sentences.settled(reached: t.reached, quietFor: 3)
        if s > t.reached { t.move(to: s) }
        follow(t, &st)
        return (st.allRead, ahead)
    }

    /// 60 readings each way here; MediumTests/VoiceEnrollRevisionMediumTests runs 300 each.
    @Test func randomizedReadingsNeverStallOrRunAhead() {
        Self.expectNoStalls(seeds: 1...60)
    }

    static func expectNoStalls(seeds: ClosedRange<UInt64>) {
        let n = seeds.count
        for fresh in [false, true] {
            var stalls: [UInt64] = [], aheadSeeds: [UInt64] = []
            for seed in seeds {
                let r = Self.read(seed: seed, fresh: fresh)
                if !r.completed { stalls.append(seed) }
                if r.ahead > 0 { aheadSeeds.append(seed) }
            }
            #expect(stalls.isEmpty, "fresh transcripts \(fresh): \(stalls.count) of \(n) stalled (seeds \(stalls.prefix(8)))")
            #expect(aheadSeeds.isEmpty, "fresh transcripts \(fresh): \(aheadSeeds.count) of \(n) ran ahead of the reading (seeds \(aheadSeeds.prefix(8)))")
        }
    }

    // MARK: Words lost in a row (the recognizer dropped them)

    /// The passage read with `k` words from `p` lost, results growing `step` words at a time,
    /// up to the sentence after the gap. `reachedEnd`: the tracker followed to the last word (it caught up after the gap).
    /// `completed`: the owner, reading what the window shows (a sentence asked for again is read
    /// again; a pause at each sentence's end), finished the enrollment.
    static func dropped(_ k: Int, at p: Int, step: Int) -> (reachedEnd: Bool, completed: Bool) {
        let (t, f, st0) = setup()
        var st = st0
        var tr: [String] = []
        var lost = Set(p..<(p + k))
        var w = 0, reachedEnd = false, said = 0
        // Once the sentence after the lost words is read, the tracker has caught up: the rest is
        // a clean reading (tested on its own), so the run stops there.
        let caughtUp = min(sentences.index(at: min(p + k, P.count - 1)) + 2, sentences.count)
        while !st.allRead, said < 6 * P.count {
            if st.current >= caughtUp, st.done.isSuperset(of: 0..<caughtUp) { return (true, true) }
            let shown = sentences.ranges[min(st.current, sentences.count - 1)]
            if !shown.contains(w) { w = shown.lowerBound }   // asked again, or on to the next
            if lost.remove(w) == nil { tr.append(P[w]); said += 1 }
            w += 1
            let atEnd = w == shown.upperBound
            if tr.count % step == 0 || atEnd { f.hear(tr); follow(t, &st) }
            if t.reached >= P.count { reachedEnd = true }
            if atEnd, st.current < sentences.count, sentences.ranges[st.current] == shown {
                // The owner pauses at the sentence's end: a missed last word or two goes.
                let s = sentences.settled(reached: t.reached, quietFor: 3)
                if s > t.reached { t.move(to: s) }
                follow(t, &st)
                if st.current < sentences.count, sentences.ranges[st.current] == shown, t.reached < shown.upperBound, st.again == nil {
                    w = shown.lowerBound   // not taken: the owner reads it again
                }
            }
        }
        return (reachedEnd || st.allRead, st.allRead)
    }

    static func sweep(_ ks: ClosedRange<Int>, steps: [Int], positions: StrideTo<Int>) -> [String] {
        var failures: [String] = []
        for k in ks {
            for step in steps {
                var notEnd: [Int] = [], notDone: [Int] = []
                for p in positions where p + k < P.count {
                    let r = dropped(k, at: p, step: step)
                    if !r.reachedEnd { notEnd.append(p) }
                    if !r.completed { notDone.append(p) }
                }
                if !notEnd.isEmpty || !notDone.isEmpty {
                    failures.append("\(k) lost, \(step) per result: tracker stuck at \(notEnd.count) positions \(notEnd.prefix(6)), enrollment not finished at \(notDone.count) \(notDone.prefix(6))")
                }
            }
        }
        return failures
    }

    /// 11-12 review: three words lost in a row stalled the tracker for good at 170 of 171
    /// positions. Sampled here; MediumTests runs every position, 2-6 words, 1 or 3 per result.
    @Test func threeWordsLostInARowNeverStallIt() {
        let failures = Self.sweep(3...3, steps: [1], positions: stride(from: 1, to: Self.P.count - 4, by: 6))
        #expect(failures.isEmpty, "\(failures)")
    }

    /// After sentence 2 is asked for again, the recognizer re-decodes the same audio: its first
    /// words gone, the garbled ones now right. That shares little with the last result, but it
    /// is not a new reading: with no new speech since the move, it credits nothing.
    @Test func reDecodedOldAudioAfterAMoveBackIsNotANewReading() {
        let r = Self.sentences.ranges[1]
        let bad = r.enumerated().map { $0.offset % 2 == 0 ? Self.P[$0.element] : "mumble" }
        let first = Array(Self.P[0..<17]) + bad + ["These", "take"]   // two words on: the reading has moved on
        let (t, f, st0) = Self.setup()
        var st = st0
        var speech = 20.0
        t.speechSeconds = { speech }
        f.hear(Array(Self.P[0..<17])); Self.follow(t, &st)
        f.hear(first); Self.follow(t, &st)
        #expect(st.again == 1 && t.reached == r.lowerBound)
        speech += 0.4   // a breath, not a reading
        let redecoded = Array(Self.P[6..<r.upperBound]) + ["These", "take"]
        f.hear(redecoded); Self.follow(t, &st)
        #expect(!st.done.contains(1), "the old audio, re-decoded, passed sentence 2")
        #expect(Self.credited(t, r) == 0)
        // Read again, with new speech: it passes.
        speech += 4
        f.hear(Array(Self.P[r])); Self.follow(t, &st)
        #expect(st.done.contains(1))
    }

    // 11-12 review (h5, h9): a sentence re-read must land on itself; while lost, stray short
    // words must not be credited; a sentence's last words said after a pause stay its own.

    /// Sentence heard but for its last 3 words; the owner reads it again from its start and
    /// reads on. The re-read fills in the sentence: no catch-up into the next one on a pair it
    /// shares ("the gods", "the rainbow"), no sentence asked for again.
    @Test func aSentenceReadAgainLandsOnItselfNotTheNextOne() {
        for s in 0..<(Self.sentences.count - 1) {
            let rg = Self.sentences.ranges[s]
            let (t, f, st0) = Self.setup()
            var st = st0
            var tr: [String] = []
            for i in 0..<(rg.upperBound - 3) { tr.append(Self.P[i]); f.hear(tr); Self.follow(t, &st) }
            #expect(t.reached == rg.upperBound - 3, "sentence \(s + 1): waits for its last words")
            var jumped = false
            for i in Array(rg) + Array(rg.upperBound..<Self.P.count) {
                tr.append(Self.P[i])
                let before = t.reached
                f.hear(tr); Self.follow(t, &st)
                if t.reached < before || t.reached > before + 3 { jumped = true }
            }
            #expect(!jumped, "sentence \(s + 1): the re-read jumped ahead or was sent back")
            #expect(st.allRead, "sentence \(s + 1): not completed (at \(t.reached), current \(st.current + 1))")
        }
    }

    /// The start of a sentence read (k words), then the owner reads on from one or two sentences
    /// later (11-12 review, h4: sentence 1 read to word 10, then sentence 3 on: "a", "and", "a"
    /// at 11, 13, 15 were picked up from the later reading and sentence 1 passed with 10 of 17
    /// said). No sentence may pass with fewer of its words said than the 80 % it needs.
    @Test func whileLostStrayShortWordsAreNotCredited() {
        var cheats: [String] = []
        // (sentence, words of it read, sentences jumped): the review's cases and a few like them.
        let cases = [(0, 10, 2), (0, 11, 2), (0, 11, 1), (2, 12, 2), (5, 13, 2), (9, 10, 2)]
        for (s, k, jump) in cases {
            let rg = Self.sentences.ranges[s]
            do {
                do {
                    for step in [1, 2] {
                        for settle in [false, true] {
                            let said = Array(rg.lowerBound..<(rg.lowerBound + k)) + Array(Self.sentences.ranges[s + jump].lowerBound..<Self.P.count)
                            let (t, f, st0) = Self.setup()
                            var st = st0
                            var tr: [String] = []
                            for (n, i) in said.enumerated() {
                                tr.append(Self.P[i])
                                guard n % step == step - 1 || n == said.count - 1 else { continue }
                                f.hear(tr); Self.follow(t, &st)
                                if settle {
                                    let to = Self.sentences.settled(reached: t.reached, quietFor: 5)
                                    if to > t.reached { t.move(to: to); f.hear(tr); Self.follow(t, &st) }
                                }
                            }
                            let truth = ReadingAlignment.credited(Set(said), passage: t.passage)
                            let need = Int((Double(rg.count) * ReadingState.sentenceShare).rounded(.down))
                            if st.done.contains(s), rg.filter(truth.contains).count < need {
                                cheats.append("s\(s + 1) k\(k) +\(jump) step \(step) settle \(settle)")
                            }
                        }
                    }
                }
            }
        }
        #expect(cheats.isEmpty, "sentences passed without being read: \(cheats.count), e.g. \(cheats.prefix(6))")
    }

    /// The owner pauses before a sentence's last one or two words (the reading settles on past
    /// them), then says them: they are that sentence's, not the next one's.
    @Test func lastWordsSaidAfterAPauseStayInTheirSentence() {
        for s in 0..<(Self.sentences.count - 1) {
            for left in [1, 2] {
                let rg = Self.sentences.ranges[s], next = Self.sentences.ranges[s + 1]
                let (t, f, st0) = Self.setup()
                var st = st0
                var tr: [String] = []
                for i in 0..<(rg.upperBound - left) { tr.append(Self.P[i]); f.hear(tr); Self.follow(t, &st) }
                let settled = Self.sentences.settled(reached: t.reached, quietFor: 2.5)
                if settled > t.reached { t.move(to: settled); f.hear(tr); Self.follow(t, &st) }
                let before = t.matched
                for i in (rg.upperBound - left)..<rg.upperBound { tr.append(Self.P[i]); f.hear(tr); Self.follow(t, &st) }
                let landed = t.matched.subtracting(before)
                #expect(landed.isSubset(of: Set(rg)), "sentence \(s + 1), \(left) left: landed at \(landed.sorted())")
                for i in next { tr.append(Self.P[i]); f.hear(tr); Self.follow(t, &st) }
                #expect(st.done.contains(s + 1), "sentence \(s + 2) not done after reading it")
                #expect(next.allSatisfy { t.matched.contains($0) }, "sentence \(s + 2) not all heard")
            }
        }
    }

    @Test func aRevisedFirstWordOrAnEmptyResultDoesNotRunAhead() {
        for n in 10...Self.P.count {
            let (t, f, st0) = Self.setup()
            var st = st0
            var tr = Array(Self.P[0..<n])
            f.hear(tr); Self.follow(t, &st)
            let reached = t.reached, matched = t.matched
            tr[0] = "Whens"
            f.hear(tr); Self.follow(t, &st)
            f.hear([]); Self.follow(t, &st)
            f.hear(tr); Self.follow(t, &st)
            #expect(t.reached == reached, "n=\(n): \(reached) -> \(t.reached)")
            #expect(t.matched.subtracting(matched).isEmpty, "n=\(n): words credited that were never read")
        }
    }

    @Test func aSentenceRepeatedAfterAPauseDoesNotRunAhead() {
        for k in 0..<(Self.sentences.count - 1) {
            let (t, f, st0) = Self.setup()
            var st = st0
            let r = Self.sentences.ranges[k]
            f.hear(Array(Self.P[0..<r.upperBound])); Self.follow(t, &st)
            let reached = t.reached, matched = t.matched
            f.hear(Array(Self.P[r])); Self.follow(t, &st)   // afresh: the same sentence again
            #expect(t.reached == reached, "sentence \(k + 1) repeated: \(reached) -> \(t.reached)")
            #expect(t.matched.subtracting(matched).isEmpty, "sentence \(k + 1) repeated: unread words credited")
            // Then the next sentence, in the same fresh transcript: followed.
            let next = Self.sentences.ranges[k + 1]
            f.hear(Array(Self.P[r]) + Array(Self.P[next])); Self.follow(t, &st)
            #expect(t.reached == next.upperBound, "sentence \(k + 2) after the repeat: reached \(t.reached)")
        }
    }

    /// Sentence 2 heard too thinly: asked for again. Whatever the recognizer then sends about
    /// that first reading (a timed final result, a revision of its last words), it must be read
    /// again to pass.
    @Test func aSentenceAskedForAgainPassesOnlyOnItsNewReading() {
        let r = Self.sentences.ranges[1]
        let bad = r.enumerated().map { $0.offset % 2 == 0 ? Self.P[$0.element] : "mumble" }
        let first = Array(Self.P[0..<17]) + bad + ["These", "take"]   // two words on: the reading has moved on
        for variant in ["timed final", "tail revised"] {
            let (t, f, st0) = Self.setup()
            var st = st0
            f.hear(Array(Self.P[0..<17])); Self.follow(t, &st)
            f.hear(first); Self.follow(t, &st)
            #expect(st.again == 1 && t.reached == r.lowerBound, "\(variant): sentence 2 asked for again")
            if variant == "timed final" {
                f.hear(first, times: first.indices.map { 0.3 + Double($0) * 0.4 }); Self.follow(t, &st)
            } else {
                var rev = first
                rev[rev.count - 3] = "x"
                f.hear(rev); Self.follow(t, &st)
                rev[rev.count - 3] = first[first.count - 3]
                f.hear(rev); Self.follow(t, &st)
            }
            #expect(!st.done.contains(1), "\(variant): sentence 2 passed without being read again")
            #expect(Self.credited(t, r) <= 1, "\(variant): \(Self.credited(t, r)) old words credited to the new reading")
            // Read again, properly: it passes.
            f.hear(first + Array(Self.P[r])); Self.follow(t, &st)
            #expect(st.done.contains(1), "\(variant): the new reading passes")
        }
    }
}
