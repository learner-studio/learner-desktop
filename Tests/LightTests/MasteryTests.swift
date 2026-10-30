import AppKit
import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// Mastery notifications (docs/mastery-notifications.md, D2–D6) against an in-process stand-in
// for learner-server: the feed's cursor and dedupe across a restart, feedback that survives
// the server being away, the call hold and summaries, and positive-only wording.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func iso(_ d: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: d)
}

/// A wire notification (fictional concepts).
/// A wire notification (fictional concepts), as the pinned contract shapes it: a gain carries
/// its best earlier reading and a positive delta; a first clear reading has neither.
private func wire(_ run: String, _ concept: String, _ percent: Int, from previous: Int?, at seconds: TimeInterval,
                  kind: String? = nil, quote: String? = nil) -> [String: Any] {
    let delta = previous.map { percent - $0 }.flatMap { $0 > 0 ? $0 : nil }
    return ["runId": run, "conceptId": "c-\(concept)", "conceptName": concept, "percent": percent,
            "previousPercent": previous as Any? ?? NSNull(), "delta": delta as Any? ?? NSNull(), "confidence": "high",
            "kind": kind ?? (previous == nil ? "first_clear" : "gain"), "completedAt": iso(t0.addingTimeInterval(seconds)),
            "quote": quote as Any? ?? NSNull()]
}

/// The stand-in server: what getMasteryNotifications returns, which feedback it accepts.
private final class MasteryServer: @unchecked Sendable {
    let lock = NSLock()
    var notifications: [[String: Any]] = []
    var feedbackStatus = 200
    var masteryStatus = 200
    var baseline: [String: Any] = ["learning": ["have": 12, "need": 40, "daysLeft": 9, "pacePerDay": 3.4],
                                   "coach": ["arms": [["arm": "baseline", "have": 60, "need": 357], ["arm": "pavlok", "have": 20, "need": 357]],
                                             "baselineBreachRate": 0.35, "baselineRateMeasured": true, "pacePerArmPerDay": 11.5,
                                             "daysLeft": 30]]
    lazy var stub = StubTransport { [weak self] seen in
        // A kicked job can still be running after its test ended.
        guard let self else { return StubTransport.status(503) }
        return self.lock.withLock {
            switch seen.path.split(separator: "/").last.map(String.init) {
            case "getMasteryNotifications":
                return masteryStatus == 200 ? StubTransport.json(200, ["data": ["notifications": notifications]]) : StubTransport.status(masteryStatus)
            case "getBaselineStatus": return StubTransport.json(200, ["data": baseline])
            case "recordNotificationFeedback":
                return feedbackStatus == 200 ? StubTransport.json(200, ["data": ["recorded": true, "at": iso(t0)]]) : StubTransport.status(feedbackStatus)
            default: return StubTransport.status(404)
            }
        }
    }

    func calls(_ name: String) -> [[String: Any]] {
        stub.seen.filter { $0.path.hasSuffix("/" + name) }.map { ($0.body?["data"] as? [String: Any]) ?? [:] }
    }
}

/// One install's saved state (defaults and job state); `launch()` is the app starting again.
private final class Install {
    let defaults = ScratchDefaults("mastery")
    let dir = TempDir("mastery")
    let server = MasteryServer()
    var now = t0

    func launch(key: String? = "k", sendAtOnce: Bool = false) -> MasteryFeed {
        let clock = Locked(now)
        return MasteryFeed(rpc: LearnerRPC(baseURL: "https://learner.test/learner-api", transport: server.stub, key: { _ in key }),
                           defaults: defaults, jobName: "mastery-test", stateDir: dir.path, sendFeedbackAtOnce: sendAtOnce,
                           clock: { clock.value })
    }
}

@MainActor
private final class FakeMasteryToast: MasteryToasting {
    var isShowing = false
    var shown: [MasteryToastContent] = []
    var done: ((MasteryAction) -> Void)?

    func show(_ content: MasteryToastContent, done: @escaping @MainActor (MasteryAction) -> Void) {
        isShowing = true
        shown.append(content)
        self.done = done
    }

    func dismiss() { click(.ignored) }

    func click(_ action: MasteryAction) {
        isShowing = false
        done?(action)
    }
}

@Suite("Mastery notifications", .tags(.light, .mastery), .quietLog)
struct MasteryFeedTests {
    @Test func gainsOnlyNeverADropOrNoChange() {
        #expect(MasteryNotification.gain(wire("r1", "Recursion", 80, from: 65, at: 0))?.line == "▲ 65% → 80%")
        // A first clear reading whose best earlier reading was higher: shown as a first clear
        // reading, the higher number never.
        let firstAfterLow = MasteryNotification.gain(wire("r1b", "Graphs", 70, from: 75, at: 0, kind: "first_clear"))
        #expect(firstAfterLow?.line == "First clear reading: 70%")
        #expect(MasteryNotification.gain(wire("r2", "Closures", 72, from: nil, at: 0))?.line == "First clear reading: 72%")
        #expect(MasteryNotification.gain(wire("r3", "Monads", 60, from: 75, at: 0, kind: "gain")) == nil, "a drop is never shown")
        #expect(MasteryNotification.gain(wire("r4", "Monads", 75, from: 75, at: 0, kind: "gain")) == nil, "no change is never shown")
        #expect(MasteryNotification.gain(["runId": "r5", "percent": 50]) == nil, "incomplete rows are skipped")
        // Only the two kinds: an unknown kind, or a gain without the reading before it, is not shown.
        #expect(MasteryNotification.gain(wire("r7", "Sets", 80, from: nil, at: 0, kind: "decline")) == nil)
        #expect(MasteryNotification.gain(wire("r8", "Sets", 80, from: nil, at: 0, kind: "gain")) == nil)
        var noKind = wire("r10", "Sets", 80, from: 60, at: 0)
        noKind["kind"] = nil
        #expect(MasteryNotification.gain(noKind) == nil, "a row without a kind is not a gain")
        // Numbers as numbers, ids as numbers too.
        var numeric = wire("r6", "Sets", 81, from: 70, at: 0)
        numeric["runId"] = 6
        numeric["percent"] = 80.6
        #expect(MasteryNotification.gain(numeric)?.runId == "6")
        #expect(MasteryNotification.gain(numeric)?.percent == 81)
    }

    @Test func theFirstRunStartsNowAndARestartNeverShowsAGainTwice() throws {
        let install = Install()
        // Something from before this install: remembered on the first run, never shown.
        install.server.notifications = [wire("old", "History", 90, from: 70, at: -300)]
        let feed = install.launch()
        #expect(describe(feed.runOnce()) == "idle")
        #expect(feed.pending.isEmpty, "the first run starts from now, not from history")
        let first = try #require(install.server.calls("getMasteryNotifications").first)
        #expect(first["since"] as? String == iso(t0.addingTimeInterval(-MasteryFeed.overlap)), "each query reaches back by the overlap")
        #expect(first["limit"] as? Int == MasteryFeed.pageLimit)

        install.server.lock.withLock {
            install.server.notifications = [wire("r2", "Closures", 72, from: nil, at: 120), wire("r1", "Recursion", 80, from: 65, at: 60),
                                            wire("r0", "Monads", 60, from: 75, at: 30, kind: "gain")]
        }
        #expect(describe(feed.runOnce()) == "ok: 2 new")
        #expect(feed.pending.map(\.runId) == ["r1", "r2"], "oldest first, the drop left out")
        #expect(feed.since == t0.addingTimeInterval(120), "the cursor is the newest reading the server sent")
        #expect(feed.baseline?.learning == BaselineStatus.Count(have: 12, need: 40))

        // Shown, then the app restarts and the server sends the same rows again: nothing new.
        feed.take(["r1"])
        let again = install.launch()
        #expect(describe(again.runOnce()) == "idle")
        #expect(again.pending.map(\.runId) == ["r2"], "only the one not shown yet is still waiting")
        let next = try #require(install.server.calls("getMasteryNotifications").last)
        #expect(next["since"] as? String == iso(t0.addingTimeInterval(120 - MasteryFeed.overlap)))
    }

    /// A run that commits after a newer one (behind the cursor, inside the overlap) is still shown.
    @Test func aLateCommitIsNotMissed() {
        let install = Install()
        let feed = install.launch()
        _ = feed.runOnce()
        install.server.lock.withLock { install.server.notifications = [wire("r2", "Closures", 72, from: nil, at: 120)] }
        _ = feed.runOnce()
        install.server.lock.withLock {
            install.server.notifications = [wire("r2", "Closures", 72, from: nil, at: 120), wire("r1", "Recursion", 80, from: 65, at: 60)]
        }
        #expect(describe(feed.runOnce()) == "ok: 1 new")
        #expect(feed.pending.map(\.runId) == ["r2", "r1"])
    }

    /// A row this app cannot read never moves the cursor or counts as seen.
    @Test func anUnreadableRowDoesNotMoveTheCursor() {
        let install = Install()
        let feed = install.launch()
        _ = feed.runOnce()
        var odd = wire("r9", "Odd", 80, from: 60, at: 500)
        odd["completedAt"] = "yesterday"
        install.server.lock.withLock { install.server.notifications = [odd, wire("r1", "Recursion", 80, from: 65, at: 60)] }
        _ = feed.runOnce()
        #expect(feed.since == t0.addingTimeInterval(60))
        #expect(feed.pending.map(\.runId) == ["r1"])
    }

    /// The app quits (or crashes) with a toast up: at the next launch its runs are reported ignored.
    @Test func aToastUpAtQuitIsReportedIgnored() {
        let install = Install()
        let feed = install.launch()
        _ = feed.runOnce()
        install.server.lock.withLock { install.server.notifications = [wire("r1", "Recursion", 80, from: 65, at: 60)] }
        _ = feed.runOnce()
        feed.take(["r1"])
        #expect(feed.queuedFeedback.isEmpty, "nothing is sent while it is up")
        let again = install.launch()
        #expect(again.queuedFeedback == [.init(runId: "r1", action: .ignored)])
        #expect(again.pending.isEmpty, "and it is not shown again")
        let third = install.launch()
        #expect(third.queuedFeedback.count == 1, "reported once")
        // A click before the quit is what is sent, not ignored.
        third.take(["r5"])
        third.record(["r5"], .nice)
        #expect(install.launch().queuedFeedback.map(\.action) == [.ignored, .nice])
    }

    /// A first run that gets no answer does not count: the next one still starts from now.
    @Test func aFailedFirstRunStillStartsFromNow() {
        let install = Install()
        install.server.masteryStatus = 503
        install.server.notifications = [wire("old", "History", 90, from: 70, at: -300)]
        let feed = install.launch()
        _ = feed.runOnce()
        #expect(feed.since == nil)
        install.server.masteryStatus = 200
        _ = feed.runOnce()
        #expect(feed.pending.isEmpty, "history from before the install is never shown")
        #expect(feed.since == t0, "the cursor starts at now once the first query has an answer")
    }

    /// No device key yet (pairing, a locked Keychain): retried on the backoff, never blocked.
    @Test func noKeyIsRetriedNotBlocked() {
        let install = Install()
        let feed = install.launch(key: nil)
        #expect(describe(feed.runOnce()).hasPrefix("failed: getMasteryNotifications: no device key"))
        #expect(feed.reachable != .offline, "a key problem is not the server being away")
        // And after a real outage, a key problem clears the offline state: the server answered.
        let down = install.launch()
        install.server.masteryStatus = 503
        _ = down.runOnce()
        #expect(down.reachable == .offline)
        install.server.masteryStatus = 401
        _ = down.runOnce()
        #expect(down.reachable == .online)
        install.server.masteryStatus = 404
        _ = down.runOnce()
        #expect(down.reachable == .online, "a refused call is not the server being away")
    }

    /// A click is sent at once (the job is kicked), not 5 minutes later.
    @Test func aClickIsSentAtOnce() async throws {
        let install = Install()
        let feed = install.launch(sendAtOnce: true)
        feed.record(["r1"], .nice)
        for _ in 0..<100 where install.server.calls("recordNotificationFeedback").isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(install.server.calls("recordNotificationFeedback").map { $0["action"] as? String } == ["nice"])
    }

    @Test func anOfflineServerBacksOffAndShowsNothing() {
        let install = Install()
        install.server.masteryStatus = 503
        let feed = install.launch()
        #expect(describe(feed.runOnce()).hasPrefix("failed: getMasteryNotifications: HTTP 503"))
        #expect(feed.reachable == .offline)
        #expect(feed.pending.isEmpty)
        install.server.masteryStatus = 200
        #expect(!describe(feed.runOnce()).hasPrefix("failed"), "the server back: no failure")
        #expect(feed.reachable == .online)
    }

    @Test func feedbackIsKeptUntilTheServerHasIt() {
        let install = Install()
        let feed = install.launch()
        feed.record(["r1"], .nice)
        feed.record(["r1"], .nice)   // the same click twice is one row
        feed.record(["r2", "r3"], .ignored)
        #expect(feed.queuedFeedback.count == 3)

        install.server.feedbackStatus = 503
        #expect(describe(feed.runOnce()).hasPrefix("failed: recordNotificationFeedback"))
        #expect(feed.queuedFeedback.count == 3, "nothing is lost while the server is away")

        // A restart, and the server is back: every outcome is sent once and the queue empties.
        install.server.feedbackStatus = 200
        let again = install.launch()
        _ = again.runOnce()
        #expect(again.queuedFeedback.isEmpty)
        let sent = install.server.calls("recordNotificationFeedback").suffix(3).map { "\($0["runId"]!) \($0["action"]!)" }
        #expect(sent == ["r1 nice", "r2 ignored", "r3 ignored"])

        // A refused row (the run is not the server's) is dropped, not retried forever.
        again.record(["nope"], .notRight)
        install.server.feedbackStatus = 422
        _ = again.runOnce()
        #expect(again.queuedFeedback.isEmpty)
    }

    @Test func baselineLinesSayHowFarAndNeverADrop() throws {
        let b = try #require(BaselineStatus.parse(MasteryServer().baseline))
        #expect(b.learningLine == "📚 Learning baseline: 12/40 concepts · ~9 days left")
        #expect(b.coachLine == "📊 Coach baseline: baseline 60/357 · pavlok 20/357 · ~30 days left")
        let unknownPace = try #require(BaselineStatus.parse(["learning": ["have": 1, "need": 40, "pacePerDay": 0, "daysLeft": NSNull()],
                                                              "coach": NSNull()]))
        #expect(unknownPace.learningLine.hasSuffix("1/40 concepts · estimating your pace"))
        #expect(unknownPace.coachLine == nil)
        let done = try #require(BaselineStatus.parse(["learning": ["have": 40, "need": 40]]))
        #expect(done.learningLine.contains("✓ set"))
        #expect(BaselineStatus.parse(["learning": ["have": 0, "need": 0]])?.learningLine == "📚 Learning baseline: no concepts yet")
    }

    @Test func openGoesToTheConceptOnTheMap() {
        #expect(MasteryLink.url(web: "https://dev.biztoolz.app/learner/", conceptId: "c 1&x=y+z")?.absoluteString
                == "https://dev.biztoolz.app/learner/osmosis?conceptId=c%201%26x%3Dy%2Bz", "encoded as encodeURIComponent does")
        #expect(MasteryLink.url(web: "https://dev.biztoolz.app/learner/", conceptId: nil)?.absoluteString
                == "https://dev.biztoolz.app/learner/osmosis")
        // Resolved as JavaScript's URL does: without the trailing slash, osmosis replaces "learner".
        #expect(MasteryLink.url(web: "https://dev.biztoolz.app/learner", conceptId: "c1")?.absoluteString
                == "https://dev.biztoolz.app/osmosis?conceptId=c1")
        #expect(MasteryLink.url(web: nil, conceptId: "c1") == nil, "no web published: no made-up link")
        #expect(MasteryLink.url(web: "learner/", conceptId: "c1") == nil, "not an absolute web address: no link")
    }
}

@MainActor
@Suite("Mastery toasts: call hold and summaries", .tags(.light, .mastery), .quietLog)
struct MasteryPresenterTests {
    private func setUp(_ gains: [[String: Any]]) -> (Install, MasteryFeed, FakeMasteryToast, MasteryPresenter, Locked<Bool>, Locked<[URL]>) {
        let install = Install()
        let feed = install.launch()
        _ = feed.runOnce()
        install.server.lock.withLock { install.server.notifications = gains }
        _ = feed.runOnce()
        let toast = FakeMasteryToast()
        let inCall = Locked(false)
        let opened = Locked<[URL]>([])
        let presenter = MasteryPresenter(feed: feed, toast: toast, inCall: { inCall.value },
                                         openURL: { url in opened.withLock { $0.append(url) }; return true },
                                         web: { "https://learner.test/learner/" })
        return (install, feed, toast, presenter, inCall, opened)
    }

    @Test func plansOneToastOrOneSummary() {
        #expect(MasteryPresenter.plan(count: 1, afterCall: false) == .single)
        #expect(MasteryPresenter.plan(count: 2, afterCall: false) == .single)
        #expect(MasteryPresenter.plan(count: 3, afterCall: false) == .summary)
        #expect(MasteryPresenter.plan(count: 1, afterCall: true) == .single)
        #expect(MasteryPresenter.plan(count: 2, afterCall: true) == .summary)
    }

    @Test func aCallHoldsToastsAndItsEndShowsOneSummary() {
        let (_, feed, toast, presenter, inCall, _) = setUp([wire("r1", "Recursion", 80, from: 65, at: 10),
                                                            wire("r2", "Closures", 72, from: nil, at: 20)])
        inCall.value = true
        presenter.tick()
        #expect(toast.shown.isEmpty, "no toast during a call")
        inCall.value = false
        presenter.tick()
        #expect(toast.shown.map(\.title) == ["🎓 Looks like progress on 2 concepts"], "the call's end shows one summary")
        #expect(toast.shown.first?.asksFeedback == false)
        #expect(feed.pending.isEmpty)
        toast.click(.ignored)
        presenter.tick()
        #expect(toast.shown.count == 1, "nothing else to show")
        #expect(feed.queuedFeedback.map(\.action) == [.ignored, .ignored])
    }

    /// A toast up when a call starts is taken down and shown again after the call.
    @Test func aToastUpWhenACallStartsIsTakenDownAndShownAfter() {
        let (_, feed, toast, presenter, inCall, _) = setUp([wire("r1", "Recursion", 80, from: 65, at: 10)])
        presenter.tick()
        #expect(toast.isShowing)
        inCall.value = true
        presenter.tick()
        #expect(!toast.isShowing, "no toast during a call")
        #expect(feed.queuedFeedback.isEmpty, "not counted as ignored")
        #expect(feed.pending.map(\.runId) == ["r1"])
        inCall.value = false
        presenter.tick()
        #expect(toast.shown.count == 2)
        #expect(toast.shown.last?.runIds == ["r1"])
    }

    /// Open with nowhere to go is not reported as opened.
    @Test func openWithNoLinkIsIgnored() {
        let (_, feed, toast, presenter, _, _) = setUp([wire("r1", "Recursion", 80, from: 65, at: 10)])
        presenter.web = { nil }   // the server publishes no web URL: no link at all
        presenter.tick()
        toast.click(.opened)
        #expect(feed.queuedFeedback == [.init(runId: "r1", action: .ignored)])
    }

    /// Gains that arrive after the last in-call look still count as held: one summary.
    @Test func gainsArrivingAsTheCallEndsAreOneSummary() {
        let (install, feed, toast, presenter, inCall, _) = setUp([])
        inCall.value = true
        presenter.tick()
        install.server.lock.withLock {
            install.server.notifications = [wire("r1", "A", 80, from: 65, at: 10), wire("r2", "B", 72, from: nil, at: 20)]
        }
        _ = feed.runOnce()
        inCall.value = false
        presenter.tick()
        #expect(toast.shown.map(\.title) == ["🎓 Looks like progress on 2 concepts"])
    }

    /// The real panel: one outcome per toast, the click or the timeout, whichever is first.
    @Test func theToastReportsOnceAndTimesOutAsIgnored() {
        let c = MasteryToastController()
        #expect(c.timeout == 8, "no click within 8 s is ignored")
        c.timeout = 0.1
        var outcomes: [MasteryAction] = []
        let content = MasteryToastContent.single(MasteryNotification.gain(wire("r1", "A", 80, from: 65, at: 0))!, link: nil)
        c.show(content) { outcomes.append($0) }
        #expect(c.isShowing)
        #expect(c.panel?.sharingType == NSWindow.SharingType.none)
        #expect(c.panel?.styleMask.contains(.nonactivatingPanel) == true)
        #expect(c.panel?.frame.size == NSSize(width: 340, height: 90))
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        #expect(outcomes == [.ignored])
        c.show(content) { outcomes.append($0) }
        c.openClicked()
        c.niceClicked()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        #expect(outcomes == [.ignored, .opened], "the first click wins; the timer never adds a second outcome")
        c.panel?.orderOut(nil)
    }

    /// The tray: the mastery section right after the learner-server lines, and the setting.
    @Test func theTrayHasTheMasterySectionAfterTheServerLines() throws {
        let tray = TrayAppManager()
        tray.statusMenu = NSMenu()
        tray.rebuildMenu()
        defer { withExtendedLifetime(tray) {} }
        let titles = tray.statusMenu.items.map(\.title)
        let server = try #require(titles.firstIndex { $0.hasPrefix("☁️ learner-server") })
        let mastery = try #require(titles.firstIndex(of: "🎓 Mastery"))
        #expect(mastery > server)
        #expect(!titles[server..<mastery].contains("📊 Habit Experiments (GrowthBook)"), "between the server lines and GrowthBook")
        let section = titles[(mastery + 1)...].prefix { !$0.isEmpty }
        #expect(section.contains { $0.contains("Learning baseline") }, "\(section)")
        #expect(section.contains("   ⏳ waiting for learner-server") == (MasteryFeed.shared.reachable == .offline), "\(section)")
        let settings = try #require(tray.statusMenu.items.first { $0.title == "Settings" }?.submenu)
        #expect(settings.items.contains { $0.title.hasSuffix("Mastery: Hold While I'm in a Call") })
    }

    /// The coach baseline line, at the end of the Speaking Coach section.
    @Test func theCoachBaselineLineIsUnderSpeakingCoach() throws {
        let feed = MasteryFeed.shared
        let saved = feed.baseline
        defer { feed.store(saved) }
        feed.store(BaselineStatus.parse(MasteryServer().baseline))
        let tray = TrayAppManager()
        tray.statusMenu = NSMenu()
        tray.rebuildMenu()
        defer { withExtendedLifetime(tray) {} }
        let titles = tray.statusMenu.items.map(\.title)
        let coach = try #require(titles.firstIndex(of: "Speaking Coach (Talk-Time Monitor)"))
        let section = titles[(coach + 1)...].prefix { !$0.isEmpty }
        #expect(section.last == "   📊 Coach baseline: baseline 60/357 · pavlok 20/357 · ~30 days left", "\(section)")
        #expect(section.count < titles.count - coach - 1, "the coach section ends before the rest of the menu")
    }

    @Test func holdingCanBeSwitchedOff() {
        let (_, feed, toast, presenter, inCall, _) = setUp([wire("r1", "Recursion", 80, from: 65, at: 10)])
        feed.holdDuringCalls = false
        inCall.value = true
        presenter.tick()
        #expect(toast.shown.map(\.title) == ["🎓 Looks like you've improved at Recursion"])
    }

    @Test func twoAreShownOneAtATimeAndMoreAreOneSummary() {
        let (_, feed, toast, presenter, _, opened) = setUp([wire("r1", "Recursion", 80, from: 65, at: 10, quote: "a function that calls itself"),
                                                            wire("r2", "Closures", 72, from: nil, at: 20)])
        presenter.tick()
        presenter.tick()   // the first is still up: nothing more
        #expect(toast.shown.map(\.detail) == ["▲ 65% → 80% · “a function that calls itself”"])
        toast.click(.opened)
        #expect(opened.value.map(\.absoluteString) == ["https://learner.test/learner/osmosis?conceptId=c-Recursion"])
        presenter.tick()
        #expect(toast.shown.map(\.detail) == ["▲ 65% → 80% · “a function that calls itself”", "First clear reading: 72%"])
        toast.click(.notRight)
        #expect(feed.queuedFeedback == [.init(runId: "r1", action: .opened), .init(runId: "r2", action: .notRight)])

        let (_, _, many, manyPresenter, _, _) = setUp((1...4).map { wire("m\($0)", "Concept \($0)", 70 + $0, from: nil, at: Double($0)) })
        manyPresenter.tick()
        #expect(many.shown.map(\.title) == ["🎓 Looks like progress on 4 concepts"])
        #expect(many.shown.first?.detail == "Concept 1, Concept 2, Concept 3 +1 more")
    }

    /// Nothing the desktop shows for mastery names a drop.
    @Test func noWordingForADrop() {
        let (_, _, toast, presenter, _, _) = setUp([wire("r1", "A", 80, from: 65, at: 1), wire("r0", "B", 50, from: 90, at: 2, kind: "gain"),
                                                    wire("r2", "C", 60, from: 70, at: 3, kind: "first_clear")])
        presenter.tick()
        let b = BaselineStatus.parse(MasteryServer().baseline)!
        let text = (toast.shown.flatMap { [$0.title, $0.detail] } + [b.learningLine, b.coachLine ?? ""]).joined(separator: " ")
        for word in ["▼", "down", "drop", "lost", "decline", "-"] { #expect(!text.contains(word), "'\(word)' in: \(text)") }
        #expect(toast.shown.count == 1, "the drop was never queued")
        #expect(!text.contains("70"), "a first clear reading's higher earlier best is never shown")
    }
}

/// The desktop's requests and the stand-in's replies match learner-server's pinned contract
/// (contract/contract.json at contract/PINNED_COMMIT), so the tests above prove the real wire.
@Suite("Mastery wire matches the pinned contract", .tags(.light, .mastery), .quietLog)
struct MasteryContractTests {
    static func output(_ name: String) -> [String: Any] { (Schema.rpc[name] as! [String: Any])["output"] as! [String: Any] }

    @Test func requestsMatchTheInputs() throws {
        let install = Install()
        let feed = install.launch()
        _ = feed.runOnce()
        feed.record(["r1"], .notRight)
        _ = feed.runOnce()
        for name in ["getMasteryNotifications", "getBaselineStatus", "recordNotificationFeedback"] {
            let sent = install.server.stub.seen.filter { $0.path.hasSuffix("/" + name) }
            try #require(!sent.isEmpty, "\(name) was not called")
            for s in sent { #expect(Schema.validate(try Schema.wire(s), Schema.input(name)) == [], "\(name)") }
        }
        let first = try #require(install.server.calls("getMasteryNotifications").first)
        #expect((first["limit"] as? Int).map { (1...100).contains($0) } == true)
    }

    @Test func theStandInsRepliesMatchTheOutputs() {
        let server = MasteryServer()
        let notes: [String: Any] = ["notifications": [wire("r1", "A", 80, from: 65, at: 1, quote: "q"), wire("r2", "B", 70, from: nil, at: 2),
                                                      wire("r3", "C", 60, from: 75, at: 3, kind: "first_clear")]]
        #expect(Schema.validate(notes, Self.output("getMasteryNotifications")) == [])
        #expect(Schema.validate(server.baseline, Self.output("getBaselineStatus")) == [])
        #expect(Schema.validate(["learning": ["have": 0, "need": 0, "pacePerDay": 0, "daysLeft": NSNull()], "coach": NSNull()],
                                Self.output("getBaselineStatus")) == [])
        #expect(Schema.validate(["recorded": true, "at": iso(t0)], Self.output("recordNotificationFeedback")) == [])
    }

    @Test func thePinIsTheCommitWithTheMasteryRPCs() throws {
        let pin = try String(contentsOfFile: Vault.repo + "/contract/PINNED_COMMIT", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect("02fec3f400a652c19521364efe7372fd61667f07".hasPrefix(pin))
        for name in ["getMasteryNotifications", "getBaselineStatus", "recordNotificationFeedback"] {
            #expect((Schema.rpc[name] as? [String: Any])?["client"] as? String == "desktop", "\(name) is not a desktop RPC")
        }
    }
}
