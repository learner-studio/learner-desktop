import AppKit
import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// Guided enrollment, without a microphone or a real recognizer: aligning what was heard to the
// passage, splitting it into sentences and moving between them, when the reading is done, how
// the words show, and what happens when recognition is not available. The real recognizer and
// real audio are in MediumTests/VoiceEnrollReadingE2ETests.
@Suite("Voice ID guided enrollment (logic)", .tags(.light, .voiceID), .timeLimit(.minutes(1)), .quietLog)
struct VoiceEnrollReadingTests {
    static let passage = ReadingPassage.words.map(ReadingAlignment.key)
    static func reach(_ heard: String, from start: Int = 0) -> Int {
        ReadingAlignment.reach(heard: ReadingAlignment.keys(heard), passage: passage, from: start)
    }
    static func text(_ range: Range<Int>) -> String { ReadingPassage.words[range].joined(separator: " ") }

    /// Stands in for the speech recognizer: tests say what it heard and when a request ends.
    final class FakeRecognizer: ReadingRecognizer, @unchecked Sendable {
        var availability = ReadingTrackingAvailability.available
        private(set) var starts = 0
        private(set) var stops = 0
        private var events: (@MainActor @Sendable (ReadingRecognizerEvent) -> Void)?
        let appended = Locked(0)
        @MainActor func prepare(_ done: @escaping @MainActor @Sendable (ReadingTrackingAvailability) -> Void) { done(availability) }
        @MainActor func start(_ events: @escaping @MainActor @Sendable (ReadingRecognizerEvent) -> Void) { starts += 1; self.events = events }
        func append(_ frames: [SileroVAD.Frame]) { appended.withLock { $0 += frames.count } }
        @MainActor func stop() { stops += 1; events = nil }
        @MainActor func hear(_ text: String) { events?(.transcript(text)) }
        @MainActor func end(_ why: String? = nil) { events?(.ended(why)) }
    }

    @MainActor static func tracker() -> (ReadingTracker, FakeRecognizer) {
        let fake = FakeRecognizer()
        let t = ReadingTracker(recognizer: fake)
        t.restartDelay = 0
        return (t, fake)
    }

    // MARK: The passage

    @Test func thePassageIsTheRainbowPassagesOpeningInTwelveSentences() {
        let words = ReadingPassage.words
        #expect(words.first == "When" && words.last == "physically.")
        #expect((150...200).contains(words.count), "\(words.count) words: about 65 s read aloud")
        let s = ReadingSentences()
        #expect(s.count == 12)
        #expect(s.ranges.first == 0..<17, "\(s.ranges.first!)")
        #expect(Self.text(s.ranges[0]) == "When the sunlight strikes raindrops in the air, they act as a prism and form a rainbow.")
        #expect(Self.text(s.ranges[11]) == "Others have tried to explain the phenomenon physically.")
        // Contiguous, covering every word, each ending a sentence.
        #expect(s.ranges.first?.lowerBound == 0 && s.ranges.last?.upperBound == words.count)
        for (a, b) in zip(s.ranges, s.ranges.dropFirst()) { #expect(a.upperBound == b.lowerBound) }
        #expect(s.ranges.allSatisfy { words[$0.upperBound - 1].hasSuffix(".") })
        // "There is, according to legend," does not end a sentence at its comma.
        #expect(Self.text(s.ranges[3]) == "There is, according to legend, a boiling pot of gold at one end.")
    }

    @Test func sentencesSplitOnStopsQuestionsAndExclamations() {
        let s = ReadingSentences(words: ["Is", "it?", "Yes!", "It", "is.", "\"Done.\"", "tail"])
        #expect(s.ranges == [0..<2, 2..<3, 3..<5, 5..<6, 6..<7])
        #expect(s.index(at: 0) == 0 && s.index(at: 1) == 0 && s.index(at: 2) == 1 && s.index(at: 7) == 5)
    }

    // MARK: Alignment

    @Test func anExactReadingReachesTheEnd() {
        #expect(Self.reach(ReadingPassage.paragraphs.joined(separator: " ")) == Self.passage.count)
        #expect(Self.reach("When the sunlight strikes") == 4)
        #expect(Self.reach("") == 0)
        #expect(ReadingAlignment.key("Sun's") == "suns" && ReadingAlignment.key("super-imposition") == "superimposition")
    }

    @Test func punctuationAndCaseDoNotMatter() {
        #expect(Self.reach("WHEN, the Sunlight... strikes RAINDROPS; in the air") == 8)
        #expect(Self.reach("there's according to legend", from: 51) == 56, "a contraction for 'There is'")
    }

    @Test func skippedWordsDoNotBlockTheRest() {
        // "in the" left out, and later "a" and "prism".
        #expect(Self.reach("When the sunlight strikes raindrops air they act as and form a rainbow") == 17)
        // Started a few words in: all before it count as read.
        #expect(Self.reach("strikes raindrops in the air") == 8)
    }

    @Test func misrecognizedWordsAreToleratedOrSkipped() {
        #expect(Self.reach("when the sun light strikes rain drops in the air they act as a prison and form a rainbow") == 17,
                "split words and a near miss (prison for prism)")
        let norse = Self.passage.firstIndex(of: "norsemen")!
        #expect(Self.reach("the norse men considered the rainbow", from: norse - 1) == norse + 4)
        // A wrong word in the middle ("elephant" for "beautiful") is passed over.
        let rainbowIs = 17
        #expect(Self.reach("the rainbow is a division of white light into many elephant colors", from: rainbowIs) == rainbowIs + 12)
        // Digits for a number word.
        let gold = Self.passage.firstIndex(of: "gold")!
        #expect(Self.reach("gold at 1 end", from: gold) == gold + 4)
    }

    @Test func repeatsAndStrayShortWordsDoNotRaceAhead() {
        #expect(Self.reach("when the sunlight strikes when the sunlight strikes raindrops") == 5)
        // A repeated "the" after "When the sunlight strikes raindrops in the air" finds no "the"
        // within reach; a lone long word far ahead (no second word agreeing) is not taken.
        #expect(Self.reach("when the sunlight strikes raindrops in the air the the the") == 8)
        #expect(Self.reach("when the sunlight strikes raindrops in the air prism") == 8, "a jump over 4 words needs a second word to agree")
        #expect(Self.reach("when the sunlight strikes raindrops in the air prism and") == 14)
    }

    // MARK: The tracker, across partial results and requests

    @MainActor @Test func partialResultsMayReviseWithoutUngreeningWords() {
        let (t, fake) = Self.tracker()
        t.start()
        #expect(fake.starts == 1)
        fake.hear("when the sun")
        #expect(t.reached == 2, "'sun' is not 'sunlight'")
        fake.hear("when the sunlight strikes")
        #expect(t.reached == 4)
        fake.hear("when the sunlight")   // revised to fewer words: nothing goes back
        #expect(t.reached == 4)
        fake.hear("when the sunlight strikes raindrops in")
        #expect(t.reached == 6)
    }

    @MainActor @Test func aRequestThatEndsIsRestartedAndKeepsItsWords() {
        let (t, fake) = Self.tracker()
        t.start()
        fake.hear("when the sunlight strikes raindrops in the air")
        fake.end()
        #expect(t.restarts == 1 && fake.starts == 2, "a new request follows on")
        #expect(t.reached == 8)
        // The new request's text starts where the reading is now.
        fake.hear("they act as a prism")
        #expect(t.reached == 13)
        t.now = { Date().addingTimeInterval(10) }   // ended long after it started: not a failure
        fake.end("No speech detected")
        #expect(t.failure == nil && t.running && t.reached == 13)
        t.stop()
        #expect(!t.running && fake.stops == 1)
    }

    @MainActor @Test func recognitionThatKeepsFailingAtOnceGivesUpAndSaysWhy() {
        let (t, fake) = Self.tracker()
        t.start()
        for _ in 0..<ReadingTracker.maxQuickEnds { fake.end("Siri and Dictation are disabled") }
        #expect(t.failure == "speech recognition kept stopping: Siri and Dictation are disabled")
        #expect(!t.running)
    }

    @MainActor @Test func skippingASentencesMissedTailAlignsOnlyNewWords() {
        let (t, fake) = Self.tracker()
        t.start()
        // Sentence 1 heard but for "a rainbow", then the owner stops.
        fake.hear(Self.text(0..<15))
        #expect(t.reached == 15)
        let s = ReadingSentences()
        #expect(s.settled(reached: 15, quietFor: 1) == 15, "still talking: wait")
        #expect(s.settled(reached: 15, quietFor: 2.5) == 17, "two words left and quiet: the sentence is done")
        #expect(s.settled(reached: 14, quietFor: 9) == 14, "three left: not done")
        #expect(s.settled(reached: 17, quietFor: 9) == 17, "a sentence not begun is not skipped")
        t.move(to: 17)
        #expect(t.reached == 17)
        // The same request goes on: its earlier words are not aligned again.
        fake.hear(Self.text(0..<15) + " the rainbow is a division")
        #expect(t.reached == 22)
    }

    // MARK: Sentences and completion

    @Test func theSentenceAdvancesOnceTheCurrentOneIsGreen() {
        let s = ReadingSentences()
        #expect(s.index(at: 0) == 0)
        #expect(s.index(at: 16) == 0, "one word left")
        #expect(s.index(at: 17) == 1, "all of sentence 1 green: sentence 2")
        #expect(s.index(at: ReadingPassage.words.count) == 12, "all read")
        #expect(VoiceEnrollPanel.pills(current: 2, count: 5) == "✓ ✓ ● ○ ○")
    }

    @Test func theReadingIsDoneWhenEverySentenceIsReadAndThereWasEnoughSpeech() {
        #expect(ReadingCompletion.verdict(allRead: false, speechSeconds: 90) == .reading)
        #expect(ReadingCompletion.verdict(allRead: true, speechSeconds: 40) == .done)
        #expect(ReadingCompletion.verdict(allRead: true, speechSeconds: 30) == .tooLittleSpeech(30))
        #expect(ReadingCompletion.verdict(allRead: true, speechSeconds: 35) == .done)
        #expect(ReadingCompletion.minSpeechSeconds == 35, "about 5 CAM++ segments")
    }

    // MARK: Rigor: words really heard

    /// A reader: reads the sentence shown (`heardPerSentence[current]`, as the recognizer hears
    /// it), one transcript each, the tracker moved as the controller moves it; at most `rounds`
    /// times the passage's sentences. Returns the state, how often a sentence was asked for
    /// again, and the words matched.
    static func read(_ heardPerSentence: [String], rounds: Int = 1) -> (ReadingState, again: Int, matched: Int) {
        var state = ReadingState()
        var reached = 0
        var matched = Set<Int>(), misheard = Set<Int>()
        var again = 0
        for _ in 0..<(rounds * heardPerSentence.count) where !state.allRead {
            let a = ReadingAlignment.align(heard: ReadingAlignment.keys(heardPerSentence[state.current]), passage: passage, from: reached)
            reached = max(reached, a.reached)
            matched.formUnion(a.matched)
            misheard.formUnion(a.misheard)
            // The controller lets a sentence's missed last words go once the owner stops.
            reached = ReadingSentences().settled(reached: reached, quietFor: 3)
            if let move = state.update(reached: reached, matched: matched, misheard: misheard) {
                if let r = move.forget { again += 1; matched.subtract(r); misheard.subtract(r) }
                reached = move.to
            }
        }
        return (state, again, matched.count)
    }

    static var sentenceTexts: [String] { ReadingSentences().ranges.map(text) }

    @Test func everyOtherWordDoesNotCompleteThePassage() {
        let halves = ReadingSentences().ranges.map { r in r.filter { ($0 - r.lowerBound) % 2 == 0 }.map { ReadingPassage.words[$0] }.joined(separator: " ") }
        // The alignment alone runs to the end on it (one skip at a time is allowed)...
        #expect(Self.reach(halves.joined(separator: " ")) >= Self.passage.count - 1)
        // ...but no sentence counts as read, however often it is "read".
        let (state, again, _) = Self.read(halves, rounds: 3)
        #expect(!state.allRead)
        #expect(state.done.isEmpty, "done: \(state.done.sorted())")
        #expect(state.current == 0 && state.again == 0)
        #expect(again >= 1)
    }

    /// Every other word of each sentence, with `between` said in each gap (nothing when empty)
    /// and each kept word said `times` times.
    static func everyOther(between: [String] = [], times: Int = 1) -> [String] {
        ReadingSentences().ranges.map { r in
            r.filter { ($0 - r.lowerBound) % 2 == 0 }.enumerated().flatMap { (n, i) -> [String] in
                let said = Array(repeating: ReadingPassage.words[i], count: times)
                return between.isEmpty ? said : said + [between[n % between.count]]
            }.joined(separator: " ")
        }
    }

    @Test func everyOtherWordWithFillersOrRepeatsDoesNotCompleteIt() {
        for (name, heard) in [("fillers", Self.everyOther(between: ["um", "uh", "like", "so", "you know", "er"])),
                              ("each said twice", Self.everyOther(times: 2)),
                              ("each said twice with fillers", Self.everyOther(between: ["um"], times: 2))] {
            let (state, _, _) = Self.read(heard, rounds: 3)
            #expect(!state.allRead, "\(name) completed the passage")
            #expect(state.done.isEmpty, "\(name): sentences \(state.done.sorted()) counted as read")
        }
        // Not credited as said: unrelated words, or a repeat, in a gap.
        let fill = ReadingAlignment.align(heard: ReadingAlignment.keys("when um sunlight uh raindrops"), passage: Self.passage, from: 0)
        #expect(fill.reached == 5 && fill.misheard.isEmpty)
        let twice = ReadingAlignment.align(heard: ReadingAlignment.keys("when when sunlight sunlight raindrops"), passage: Self.passage, from: 0)
        #expect(twice.reached == 5 && twice.misheard.isEmpty)
    }

    @Test func aRealMishearingStillCounts() {
        #expect(ReadingAlignment.plausible("prison", "prism"))
        #expect(ReadingAlignment.plausible("norse", "norsemen") && ReadingAlignment.plausible("hebrew", "hebrews"))
        #expect(!ReadingAlignment.plausible("um", "the") && !ReadingAlignment.plausible("like", "strikes") && !ReadingAlignment.plausible("so", "sky"))
        #expect(!ReadingAlignment.plausible("when", "the"), "a repeat is not the word skipped")
        // "prism" heard as "prisoner" (too far to match), between recognized words: said.
        let a = ReadingAlignment.align(heard: ReadingAlignment.keys("they act as a prisoner and form"), passage: Self.passage, from: 8)
        #expect(a.reached == 15 && a.misheard == [12] && !a.matched.contains(12))
    }

    @Test func aSentenceReadAgainMustPassOnItsOwn() {
        // Half of sentence 1, then the other half: neither reading alone is enough.
        let r = ReadingSentences().ranges[0]
        let first = r.filter { ($0 - r.lowerBound) % 2 == 0 }.map { ReadingPassage.words[$0] }.joined(separator: " ")
        let second = r.filter { ($0 - r.lowerBound) % 2 == 1 }.map { ReadingPassage.words[$0] }.joined(separator: " ")
        var state = ReadingState()
        var matched = Set<Int>()
        let a1 = ReadingAlignment.align(heard: ReadingAlignment.keys(first), passage: Self.passage, from: 0)
        matched.formUnion(a1.matched)
        let move = state.update(reached: a1.reached, matched: matched)
        #expect(move == .init(to: 0, forget: r))
        matched.subtract(r)
        let a2 = ReadingAlignment.align(heard: ReadingAlignment.keys(second), passage: Self.passage, from: 0)
        matched.formUnion(a2.matched)
        let settled = ReadingSentences().settled(reached: a2.reached, quietFor: 3)
        _ = state.update(reached: settled, matched: matched)
        #expect(!state.done.contains(0), "two halves on two readings do not make one")
    }

    @Test func realisticRecognitionErrorsStillCompleteIt() {
        // Every "the" and "a" dropped, and one word in nine heard as junk.
        var n = 0
        let rough = ReadingSentences().ranges.map { r in
            r.compactMap { i -> String? in
                let w = ReadingPassage.words[i]
                if ["the", "a"].contains(ReadingAlignment.key(w)) { return nil }
                n += 1
                return n % 9 == 0 ? "umbrella" : w
            }.joined(separator: " ")
        }
        let (state, again, matched) = Self.read(rough)
        #expect(state.allRead, "stuck at sentence \(state.current + 1) (asked again \(again) times)")
        #expect(again == 0)
        #expect(Double(matched) < 0.85 * Double(Self.passage.count), "the drops are real: \(matched) of \(Self.passage.count) matched")
        // A clean reading completes with nothing asked again.
        let clean = Self.read(Self.sentenceTexts)
        #expect(clean.0.allRead && clean.again == 0 && clean.matched == Self.passage.count)
    }

    @Test func aSentenceHeardTooThinlyIsAskedForOnceMoreThenTheReadingGoesOn() {
        var state = ReadingState()
        let s = ReadingSentences()
        let r0 = s.ranges[0], r1 = s.ranges[1]
        // Sentence 1 passed, but only 10 of its 17 words heard: back to its start.
        #expect(state.update(reached: r0.upperBound, matched: Set(r0.lowerBound..<(r0.lowerBound + 10))) == .init(to: r0.lowerBound, forget: r0))
        #expect(state.again == 0 && state.current == 0)
        // Read once more, fully: done, and on.
        #expect(state.update(reached: r0.upperBound, matched: Set(r0)) == nil)
        #expect(state.done == [0] && state.again == nil && state.current == 1)
        #expect(state.update(reached: r1.upperBound, matched: Set(r0).union(r1)) == nil)
        #expect(state.done == [0, 1])
        // A short word dropped among heard ones counts (recognizers drop them); a long one does
        // not, nor every other word.
        #expect(ReadingAlignment.credited([0, 2, 3], passage: Self.passage) == [0, 1, 2, 3], "When _the_ sunlight strikes")
        #expect(ReadingAlignment.credited([1, 3, 4], passage: Self.passage) == [1, 3, 4], "'sunlight' is not credited")
        #expect(ReadingAlignment.credited([0, 2, 4], passage: Self.passage) == [0, 2, 4], "every other word credits nothing")
        // A word heard as something else was said: it counts, but is not shown as recognized.
        let a = ReadingAlignment.align(heard: ReadingAlignment.keys("when the sunlight stroked raindrops"), passage: Self.passage, from: 0)
        #expect(a.reached == 5 && a.matched == [0, 1, 2, 4] && a.misheard == [3])
        let skipped = ReadingAlignment.align(heard: ReadingAlignment.keys("when the sunlight raindrops"), passage: Self.passage, from: 0)
        #expect(skipped.reached == 5 && skipped.misheard.isEmpty, "nothing heard in the gap: not said")
    }

    @Test func thePassageAsAWholeMustBeMostlyHeard() {
        // Every sentence at 80 % or more, but under 85 % overall: the weakest is read once more.
        let s = ReadingSentences()
        var heard = Set<Int>()
        for r in s.ranges {
            let keep = Int((Double(r.count) * 0.8).rounded(.up))
            heard.formUnion(r.lowerBound..<(r.lowerBound + keep))
        }
        let credited = ReadingAlignment.credited(heard, passage: Self.passage)
        try? #require(Double(credited.count) / Double(Self.passage.count) < ReadingState.passageShare)
        var state = ReadingState()
        let move = state.update(reached: Self.passage.count, matched: heard)
        let weakest = try? #require(state.again)
        #expect(move == .init(to: s.ranges[weakest ?? 0].lowerBound, forget: s.ranges[weakest ?? 0]))
        #expect(!state.allRead && state.done.count == s.count - 1)
    }

    // MARK: Availability

    @Test func trackingIsOnlyAvailableOnDeviceAndWithPermission() {
        typealias A = ReadingTrackingAvailability
        func a(text: Bool = true, _ auth: A.Auth = .authorized, exists: Bool = true, onDevice: Bool = true, available: Bool = true) -> A {
            .from(hasUsageText: text, auth: auth, recognizerExists: exists, onDevice: onDevice, isAvailable: available)
        }
        #expect(a() == .available)
        guard case .unavailable(let denied) = a(.denied) else { Issue.record("denied was available"); return }
        #expect(denied.contains("turned off") && denied.contains("Speech Recognition"))
        #expect(a(.restricted) != .available && a(.notDetermined) != .available)
        guard case .unavailable(let remote) = a(onDevice: false) else { Issue.record("server recognition was allowed"); return }
        #expect(remote.contains("on-device") && remote.contains("never sent"))
        #expect(a(exists: false) != .available && a(available: false) != .available)
        guard case .unavailable(let noText) = a(text: false) else { Issue.record("no usage text was available"); return }
        #expect(noText.contains("permission text"))
    }
}

// The window and the controller with a fake recognizer: colours, sentences, completion and
// the fallback, as the owner would see them.
@MainActor
@Suite("Voice ID guided enrollment window", .tags(.light, .voiceID), .timeLimit(.minutes(1)), .quietLog, .serialized)
struct VoiceEnrollReadingWindowTests {
    typealias Fake = VoiceEnrollReadingTests.FakeRecognizer

    static func frames(_ seconds: Double, p: Float = 0.9) -> [SileroVAD.Frame] { VoiceIDTests.frames(seconds, value: 0.1, p: p) }

    static func controller(_ fake: Fake, saved: Locked<Int> = Locked(0), savedPrints: Locked<[Voiceprint]> = Locked([])) -> VoiceIDController {
        _ = NSApplication.shared
        let engine = VoiceIDEngine(modelName: "fake.onnx", makeEmbedder: { VoiceIDTests.FakeEmbedder() },
                                   save: { p in saved.withLock { $0 += 1 }; savedPrints.withLock { $0.append(p) } })
        let c = VoiceIDController(mic: nil, engine: engine, defaults: ScratchDefaults("voice-reading"), modelPresent: true,
                                  voiceprint: nil, recognizer: fake)
        c.tracker.restartDelay = 0
        c.blocker = { nil }
        return c
    }

    @Test func wordsAreGreyUntilReadGreenOnceReadAndTheNextIsMarked() throws {
        let panel = VoiceEnrollPanel()
        panel.show()
        defer { panel.window?.orderOut(nil) }
        #expect(panel.display == .sentence(0))
        #expect(panel.passageText == "When the sunlight strikes raindrops in the air, they act as a prism and form a rainbow.")
        #expect(panel.wordStyles.first == .next && panel.wordStyles.dropFirst().allSatisfy { $0 == .unread })
        panel.reading(reached: 3, speechSeconds: 2, waitingForMic: false)
        #expect(panel.wordStyles.prefix(4) == [.read, .read, .read, .next])
        #expect(panel.wordStyles.dropFirst(4).allSatisfy { $0 == .unread })
        #expect(panel.color(ofWord: 0) == .systemGreen)
        #expect(panel.color(ofWord: 5) == .tertiaryLabelColor)
        #expect(panel.progressValue == 0, "progress counts sentences read")
        #expect(panel.stepsText.hasPrefix("● ○") && panel.stepsText.contains("Sentence 1 of 12"))
        // Sentence 1 all green: sentence 2 shows, sentence 1 ticked.
        panel.reading(reached: 17, speechSeconds: 6, waitingForMic: false)
        #expect(panel.display == .sentence(1))
        #expect(panel.passageText == "The rainbow is a division of white light into many beautiful colors.")
        #expect(panel.wordStyles.first == .next)
        #expect(panel.stepsText.hasPrefix("✓ ● ○") && panel.stepsText.contains("Sentence 2 of 12"))
        #expect(abs(panel.progressValue - 1.0 / 12) < 1e-9)
        #expect(panel.statusText.contains("sentence 2 of 12"))
        // All read: the last sentence stays, all green.
        panel.reading(reached: ReadingPassage.words.count, speechSeconds: 50, waitingForMic: false)
        #expect(panel.display == .sentence(11) && panel.wordStyles.allSatisfy { $0 == .read })
        #expect(panel.stepsText.contains("All 12 sentences read") && !panel.stepsText.contains("○"))
    }

    @Test func aGuidedReadingWithEnoughSpeechEnrolls() throws {
        let fake = Fake()
        let saved = Locked(0)
        let c = Self.controller(fake, saved: saved)
        c.showEnrollment()
        defer { c.panel?.window?.orderOut(nil) }
        let panel = try #require(c.panel)
        panel.press()   // Start: the fake answers "available" at once
        #expect(c.readingMode == .tracked && c.engine.enrolling && fake.starts == 1)
        let s = ReadingSentences()
        var shown: [Int] = []
        for (i, r) in s.ranges.enumerated() {
            c.engine.frames(Self.frames(4.5))
            fake.hear(VoiceEnrollReadingTests.text(0..<r.upperBound))
            c.tick()
            if i < s.count - 1 { shown.append(s.index(at: c.tracker.reached)) }
        }
        #expect(shown == Array(1..<12), "each sentence followed by the next: \(shown)")
        #expect(!c.engine.enrolling, "every word green and 54 s of speech: done")
        c.engine.drain()
        c.tick()
        #expect(saved.value == 1)
        #expect(c.voiceprint != nil && c.readingMode == .off)
        #expect(panel.buttonTitle == "Close" && panel.statusText.hasPrefix("Done"))
        #expect(fake.stops >= 1, "recognition stops once the reading is done")
    }

    @Test func tooLittleSpeechIsKeptAndAReadingAgainAddsToIt() throws {
        let fake = Fake()
        let saved = Locked<[Voiceprint]>([])
        let c = Self.controller(fake, savedPrints: saved)
        c.showEnrollment()
        defer { c.panel?.window?.orderOut(nil) }
        let panel = try #require(c.panel)
        panel.press()
        c.engine.frames(Self.frames(20.1))
        fake.hear(ReadingPassage.paragraphs.joined(separator: " "))
        c.tick()
        #expect(saved.value.isEmpty, "nothing is made from 20 s")
        #expect(c.engine.enrollmentPaused && !c.engine.enrolling, "kept, not listening")
        #expect(panel.buttonTitle == "Read It Again")
        #expect(panel.statusText.contains("20 s of speech") && panel.statusText.contains("35 s needed") && panel.statusText.contains("kept"))
        // Frames meanwhile (someone else talking) are not taken.
        c.engine.frames(Self.frames(5))
        #expect(c.engine.output.value.enrollSpeechSeconds < 20.2)
        // Again, from sentence 1, adding to the 20 s.
        panel.press()
        #expect(c.tracker.reached == 0 && c.engine.enrolling && fake.starts == 2)
        #expect(panel.display == .sentence(0) && panel.stepsText.hasPrefix("● ○"))
        c.engine.frames(Self.frames(20.1))
        fake.hear(ReadingPassage.paragraphs.joined(separator: " "))
        c.tick()
        c.engine.drain()
        c.tick()
        let print = try #require(saved.value.first, "enrolled from both readings")
        #expect(abs(print.speechSeconds - 40.2) < 0.2, "\(print.speechSeconds) s")
    }

    @Test func closingTheWindowAfterTooLittleSpeechDiscardsIt() throws {
        let fake = Fake()
        let c = Self.controller(fake)
        c.showEnrollment()
        let panel = try #require(c.panel)
        panel.press()
        c.engine.frames(Self.frames(10))
        fake.hear(ReadingPassage.paragraphs.joined(separator: " "))
        c.tick()
        #expect(c.engine.enrollmentPaused)
        panel.window?.close()
        #expect(!c.engine.enrollmentUnderway, "closed: the kept speech is dropped")
    }

    @Test func aRecognizerThatHearsNothingFallsBackToTime() throws {
        let fake = Fake()
        let c = Self.controller(fake)
        c.showEnrollment()
        defer { c.panel?.window?.orderOut(nil) }
        let panel = try #require(c.panel)
        panel.press()
        c.engine.frames(Self.frames(19))
        c.tick()
        #expect(c.readingMode == .tracked, "under 20 s: still waiting for words")
        c.engine.frames(Self.frames(1.5))
        c.tick()
        #expect(c.readingMode == .untracked("no words were recognized in 20 s of speech"))
        #expect(!c.tracker.running && fake.stops >= 1)
        #expect(panel.display == .passage && panel.statusText.contains("no words were recognized"))
        c.engine.frames(Self.frames(40))
        #expect(!c.engine.enrolling, "60 s in all: done on time")
        c.engine.drain()
    }

    @Test func aReadingThatStopsMovingFallsBackToTime() throws {
        let fake = Fake()
        let c = Self.controller(fake)
        c.showEnrollment()
        defer { c.panel?.window?.orderOut(nil) }
        let panel = try #require(c.panel)
        panel.press()
        c.engine.frames(Self.frames(3))
        fake.hear("when the sunlight")
        c.tick()
        #expect(c.tracker.reached == 3)
        // 19 s more with nothing new: still waiting.
        for _ in 0..<19 { c.engine.frames(Self.frames(1)); fake.hear("when the sunlight"); c.tick() }
        #expect(c.readingMode == .tracked)
        // A word moves it on: the 20 s count again from here.
        fake.hear("when the sunlight strikes")
        c.engine.frames(Self.frames(1))
        c.tick()
        for _ in 0..<15 { c.engine.frames(Self.frames(1)); c.tick() }
        #expect(c.readingMode == .tracked, "15 s since the last word")
        for _ in 0..<6 { c.engine.frames(Self.frames(1)); c.tick() }
        #expect(c.readingMode == .untracked("the reading stopped moving: no words were recognized in 20 s of speech"))
        #expect(panel.display == .passage && panel.statusText.contains("stopped moving"))
        #expect(c.engine.enrolling, "the speech so far still counts")
        c.engine.frames(Self.frames(30))
        #expect(!c.engine.enrolling, "60 s in all: done on time")
        c.engine.drain()
    }

    @Test func enrollmentSpeechIsCappedAtThreeMinutes() throws {
        let engine = VoiceIDEngine(modelName: "fake.onnx", makeEmbedder: { VoiceIDTests.FakeEmbedder() }, save: { _ in })
        engine.startEnrollment(seconds: nil)
        for _ in 0..<10 { engine.frames(Self.frames(20)) }
        #expect(engine.enrolling, "open-ended: still listening")
        let heard = engine.output.value.enrollSpeechSeconds
        #expect(heard <= VoiceID.maxEnrollSeconds + 0.1 && heard >= VoiceID.maxEnrollSeconds - 0.1, "\(heard) s kept of 200")
        #expect(VoiceID.maxEnrollSeconds == 180)
        #expect(engine.finishEnrollment())
        engine.drain()
        guard case .done(let print)? = engine.output.value.enrollResult else { Issue.record("no voiceprint"); return }
        #expect(print.segments == 30)
    }

    @Test func wordsPassedOverShowDimAndOnlyHeardOnesFullyGreen() throws {
        let panel = VoiceEnrollPanel()
        panel.show()
        defer { panel.window?.orderOut(nil) }
        let s = ReadingSentences()
        // Words 0-5 passed, 1 and 3 never heard; sentence 1 asked for once more.
        panel.reading(.init(reached: 6, matched: [0, 2, 4, 5], current: 0, done: [], again: true), speechSeconds: 4, waitingForMic: false)
        #expect(panel.wordStyles.prefix(7) == [.read, .skipped, .read, .skipped, .read, .read, .next])
        #expect(panel.color(ofWord: 0) == .systemGreen)
        #expect(panel.color(ofWord: 1) == NSColor.systemGreen.withAlphaComponent(0.4))
        #expect(panel.statusText.hasPrefix("Not all of sentence 1 was heard: read it once more"))
        // Pills follow the sentences actually read, not just the position.
        panel.reading(.init(reached: s.ranges[1].lowerBound, matched: Set(0..<17), current: 1, done: [0, 2], again: false),
                      speechSeconds: 9, waitingForMic: false)
        #expect(panel.stepsText.hasPrefix("✓ ● ✓ ○"))
    }

    @Test func withoutPermissionThePassageShowsAndProgressIsTimeBased() throws {
        let fake = Fake()
        fake.availability = .from(hasUsageText: true, auth: .denied, recognizerExists: true, onDevice: true, isAvailable: true)
        let saved = Locked(0)
        let c = Self.controller(fake, saved: saved)
        c.showEnrollment()
        defer { c.panel?.window?.orderOut(nil) }
        let panel = try #require(c.panel)
        panel.press()
        guard case .untracked(let why) = c.readingMode else { Issue.record("tracked without permission"); return }
        #expect(why.contains("turned off"))
        #expect(fake.starts == 0, "no recognition request without permission")
        #expect(panel.display == .passage)
        #expect(panel.passageText.hasPrefix("When the sunlight") && panel.passageText.hasSuffix("physically."))
        #expect(panel.wordStyles.allSatisfy { $0 == .plain })
        #expect(panel.statusText.hasPrefix("Reading tracking isn't available: speech recognition is turned off"))
        // The old rule: 60 s of speech.
        c.engine.frames(Self.frames(30.1))
        c.tick()
        #expect(abs(panel.progressValue - 0.5) < 0.02)
        #expect(panel.statusText.hasPrefix("Reading tracking isn't available"), "the reason stays: \(panel.statusText)")
        panel.listening(0.5, waitingForMic: false)
        #expect(panel.statusText.contains("isn't available") && panel.statusText.contains("30 of 60 s"))
        c.engine.frames(Self.frames(31))
        c.engine.drain()
        c.tick()
        #expect(saved.value == 1)
    }

    @Test func recognitionThatGivesUpMidwayFallsBackToTime() throws {
        let fake = Fake()
        let c = Self.controller(fake)
        c.showEnrollment()
        defer { c.panel?.window?.orderOut(nil) }
        let panel = try #require(c.panel)
        panel.press()
        c.engine.frames(Self.frames(10))
        fake.hear("when the sunlight strikes")
        for _ in 0..<ReadingTracker.maxQuickEnds { fake.end("busy") }
        c.tick()
        #expect(c.readingMode == .untracked("speech recognition kept stopping: busy"))
        #expect(panel.display == .passage && panel.statusText.contains("isn't available"))
        #expect(c.engine.enrolling, "the speech so far still counts")
        c.engine.frames(Self.frames(51))
        #expect(!c.engine.enrolling, "60 s in all: done")
        c.engine.drain()
    }

    @Test func cancelStopsFollowingTheReading() throws {
        let fake = Fake()
        let c = Self.controller(fake)
        c.showEnrollment()
        defer { c.panel?.window?.orderOut(nil) }
        let panel = try #require(c.panel)
        panel.press()
        fake.hear("when the sunlight")
        panel.press()   // Cancel
        #expect(!c.tracker.running && !c.engine.enrollmentUnderway && c.readingMode == .off)
        #expect(panel.buttonTitle == "Start" && panel.display == .sentence(0))
    }
}
