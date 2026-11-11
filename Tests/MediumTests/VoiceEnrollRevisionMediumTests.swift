import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// The light lane's simulated recognizer revisions (LightTests/VoiceEnrollRevisionTests), at
// full size: 300 seeded readings with fresh transcripts after pauses and 300 without. None may
// stall, and the tracker may never run ahead of the words read. Medium: about 50 s in a debug
// build. The simulator is the light lane's, repeated here (a test target cannot import another).
@MainActor
@Suite("Voice ID guided enrollment (300 simulated readings each way)", .tags(.medium, .voiceID), .timeLimit(.minutes(2)), .quietLog)
struct VoiceEnrollRevisionMediumTests {
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

    // MARK: Words lost in a row (the recognizer dropped them)

    /// The whole passage read with `k` words from `p` lost, results growing `step` words at a
    /// time. `reachedEnd`: the tracker followed to the last word (it caught up after the gap).
    /// `completed`: the owner, reading what the window shows (a sentence asked for again is read
    /// again; a pause at each sentence's end), finished the enrollment.
    static func dropped(_ k: Int, at p: Int, step: Int) -> (reachedEnd: Bool, completed: Bool) {
        let (t, f, st0) = setup()
        var st = st0
        var tr: [String] = []
        var lost = Set(p..<(p + k))
        var w = 0, reachedEnd = false, said = 0
        while !st.allRead, said < 6 * P.count {
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

    /// Every position, 2 to 6 words lost in a row, results growing 1 or 3 words at a time.
    @Test func wordsLostInARowNeverStallItAnywhere() {
        let failures = Self.sweep(2...6, steps: [1, 3], positions: stride(from: 1, to: Self.P.count - 1, by: 1))
        #expect(failures.isEmpty, "\(failures.joined(separator: "; "))")
    }

    @Test func threeHundredReadingsEachWayNeverStallOrRunAhead() {
        Self.expectNoStalls(seeds: 1...300)
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

}
