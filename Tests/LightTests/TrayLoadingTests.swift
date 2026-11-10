import AppKit
import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// The menu opens from what is already in memory: a line whose data has not arrived says
// "loading…" (never a default that looks like a value: 0 chats, a reachable server, a
// disconnected wristband), shows the value once it comes, even with the menu open, and the
// build never waits on a fetch. 11-10: the owner saw the menu take seconds to appear and
// asked for exactly this.
@MainActor @Suite("Tray menu: loading lines", .tags(.light, .status, .mastery), .timeLimit(.minutes(1)), .quietLog, .serialized)
struct TrayLoadingTests {
    /// A learner-server stand-in for the mastery feed: answers at once, or holds every call
    /// until `release` (a fetch that is slow).
    final class Server: @unchecked Sendable {
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let held: Bool
        init(held: Bool = false) { self.held = held }

        // Captures the semaphores, not the server: a run still in flight may outlive the test.
        lazy var stub = StubTransport { [held, entered, gate] seen in
            if held { entered.signal(); gate.wait() }
            if seen.path.hasSuffix("/getBaselineStatus") {
                return StubTransport.json(200, ["data": ["learning": ["have": 12, "need": 40, "daysLeft": 9],
                                                         "coach": ["arms": [["arm": "baseline", "have": 60, "need": 357]], "daysLeft": 30]]])
            }
            return StubTransport.json(200, ["data": ["notifications": [] as [Any]]])
        }

        func release() { for _ in 0..<8 { gate.signal() } }
    }

    final class Feed {
        let defaults = ScratchDefaults("tray-loading")
        let dir = TempDir("tray-loading")
        let server: Server
        let feed: MasteryFeed
        init(held: Bool = false) {
            server = Server(held: held)
            feed = MasteryFeed(rpc: LearnerRPC(baseURL: "https://learner.test/learner-api", transport: server.stub, key: { _ in "k" }),
                               defaults: defaults, jobName: "tray-loading-\(UUID().uuidString.prefix(6))", stateDir: dir.path,
                               sendFeedbackAtOnce: false)
        }
    }

    /// One tray for the suite: its first build makes the cue panels (~0.3 s, once).
    static let shared: TrayAppManager = {
        let tray = TrayAppManager()
        tray.statusMenu = NSMenu()
        return tray
    }()

    /// The tray as at launch: nothing collected yet, `feed` never run.
    func tray(_ feed: MasteryFeed) -> TrayAppManager {
        let tray = Self.shared
        tray.mastery = feed
        tray.status = AppStatus()
        tray.menuIsOpen = false
        tray.rebuildMenu()
        return tray
    }

    static func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) }
    }

    func titles(_ tray: TrayAppManager) -> [String] { Self.allItems(tray.statusMenu).filter { !$0.isHidden }.map(\.title) }

    func line(_ tray: TrayAppManager, _ prefix: String) -> NSMenuItem? {
        Self.allItems(tray.statusMenu).first { $0.title.hasPrefix(prefix) }
    }

    static let asyncLines = ["📹 Screenpipe:", "🗄️ AI Vault:", "☁️ learner-server:", "   └─ 📤", "   📈 Recorded Trials:",
                             "   📚 Learning baseline:", "   📊 Coach baseline:", "   └─ Last check:"]

    static var collected: AppStatus {
        var s = AppStatus()
        s.loaded = true
        s.capture = .recording
        s.chatgptChats = 3
        s.claudeChats = 4
        s.outboxDepth = 2
        s.trialCount = 9
        s.lastUpdateCheck = "2026-11-10 09:00  STATUS: OK"
        return s
    }

    @Test func everyFetchedLineSaysLoadingUntilItsFirstFetchThenTheValue() throws {
        let f = Feed()
        let tray = tray(f.feed)
        defer { withExtendedLifetime(tray) {} }
        for prefix in Self.asyncLines {
            let item = try #require(line(tray, prefix), "no \(prefix) line")
            #expect(item.title.contains(TrayAppManager.loading), "\(item.title)")
        }
        let before = titles(tray)
        #expect(!before.contains { $0.contains("… checking") || $0.contains("0 Archived") || $0.contains("🟢 reachable") },
                "a default shown as if it were a value: \(before)")
        // The structure the UI tests and the click tests find lines by is all there.
        for title in ["   📥 Pull Latest Chats (Incremental Sweep)", "🎓 Mastery", "Settings", "Troubleshooting", "Quit Learner Desktop"] {
            #expect(before.contains(title), "no \(title)")
        }

        // The first collection and the first mastery run arrive.
        tray.apply(Self.collected)
        _ = f.feed.runOnce()
        tray.rebuildMenu()
        let after = titles(tray)
        for prefix in Self.asyncLines {
            #expect(line(tray, prefix).map { !$0.title.contains(TrayAppManager.loading) } == true, "\(prefix) still loading")
        }
        #expect(after.contains("📹 Screenpipe: 🟢 Recording"))
        #expect(after.contains("🗄️ AI Vault: 7 Archived (ChatGPT 3 · Claude 4)"))
        #expect(after.contains { $0.hasPrefix("☁️ learner-server: ") })
        #expect(after.contains { $0.hasPrefix("   └─ 📤 2 queued | last: ") })
        #expect(after.contains("   📈 Recorded Trials: 9"))
        #expect(after.contains("   📚 Learning baseline: 12/40 concepts · ~9 days left"))
        #expect(after.contains { $0.hasPrefix("   📊 Coach baseline: baseline 60/357") })
        #expect(after.contains("   └─ Last check: 2026-11-10 09:00  STATUS: OK"))
        #expect(f.server.stub.seen.allSatisfy { $0.url.host == "learner.test" }, "a light test reaches only its stand-in")
    }

    /// The menu is open when the data comes: the same lines change in place (no reopen), and
    /// a line that turns out to have nothing to show goes.
    @Test func anOpenMenuShowsTheValueWhenItArrives() throws {
        let f = Feed()
        let tray = tray(f.feed)
        defer { withExtendedLifetime(tray) {} }
        let screenpipe = try #require(line(tray, "📹 Screenpipe:"))
        let vault = try #require(line(tray, "🗄️ AI Vault:"))
        let baseline = try #require(line(tray, "   📚 Learning baseline:"))
        let coach = try #require(line(tray, "   📊 Coach baseline:"))
        tray.menuIsOpen = true
        defer { tray.menuIsOpen = false }
        var status = Self.collected
        status.lastUpdateCheck = nil
        tray.apply(status)
        #expect(screenpipe.title == "📹 Screenpipe: 🟢 Recording")
        #expect(vault.title == "🗄️ AI Vault: 7 Archived (ChatGPT 3 · Claude 4)")
        #expect(line(tray, "   └─ Last check:")?.title == "   └─ Last check: none yet")
        // The mastery feed answers without a coach baseline: learning shows, coach goes.
        f.feed.store(BaselineStatus(learning: .init(have: 12, need: 40), learningDaysLeft: 9))
        tray.refreshOpenMenu()
        #expect(baseline.title == "   📚 Learning baseline: 12/40 concepts · ~9 days left")
        #expect(coach.isHidden)
        // Closed: nothing is touched until the next build.
        tray.menuIsOpen = false
        tray.apply(AppStatus())
        #expect(screenpipe.title == "📹 Screenpipe: 🟢 Recording")
    }

    /// Mastery: loading only before learner-server has said anything since launch; offline
    /// says it is waiting, an answer without a baseline says not available.
    @Test func theMasteryLinesSayLoadingOnlyBeforeTheFirstAnswer() throws {
        let f = Feed(held: true)
        let tray = tray(f.feed)
        defer { withExtendedLifetime(tray) {} }
        #expect(tray.masteryLoading)
        f.feed.job.kick("test")
        #expect(f.server.entered.wait(timeout: .now() + 5) == .success, "the run reached the stand-in")
        f.server.release()
        #expect(waitFor(5) { f.feed.job.hasRun })
        tray.rebuildMenu()
        #expect(!tray.masteryLoading)
        #expect(line(tray, "   📚 Learning baseline:")?.title == "   📚 Learning baseline: 12/40 concepts · ~9 days left")
    }

    /// A first run held back by a failure saved last session is not "loading" (nothing is
    /// fetching for up to 30 min): it says not available yet.
    @Test func aBackedOffFirstRunIsNotLoading() throws {
        let defaults = ScratchDefaults("tray-backoff")
        let dir = TempDir("tray-backoff")
        let name = "tray-backoff-\(UUID().uuidString.prefix(6))"
        let down = StubTransport { _ in StubTransport.status(503) }
        func launch() -> MasteryFeed {
            MasteryFeed(rpc: LearnerRPC(baseURL: "https://learner.test/learner-api", transport: down, key: { _ in "k" }),
                        defaults: defaults, jobName: name, stateDir: dir.path, sendFeedbackAtOnce: false)
        }
        let first = launch()
        first.job.kick("test")
        #expect(waitFor(5) { first.job.snapshot.failures > 0 })
        let relaunched = launch()
        #expect(relaunched.job.snapshot.failures > 0, "the backoff survives the restart")
        #expect(!relaunched.job.hasRun)
        let tray = tray(relaunched)
        defer { withExtendedLifetime(tray) {} }
        tray.rebuildMenu()
        #expect(!tray.masteryLoading)
        #expect(line(tray, "   📚 Learning baseline:")?.title == "   📚 Learning baseline: not available yet")
    }

    /// The build reads only what is in memory: with a mastery fetch stuck in flight (its
    /// stand-in holds the call), rebuilding returns at once and says loading.
    @Test func rebuildingNeverWaitsOnAFetch() throws {
        let f = Feed(held: true)
        let tray = tray(f.feed)   // the first build also makes the cue panels (slow, once)
        defer { withExtendedLifetime(tray) {}; f.server.release() }
        f.feed.job.kick("test")
        #expect(f.server.entered.wait(timeout: .now() + 5) == .success, "the fetch is in flight")
        var slowest: TimeInterval = 0
        for _ in 0..<10 {
            let started = ProcessInfo.processInfo.systemUptime
            tray.rebuildMenu()
            slowest = max(slowest, ProcessInfo.processInfo.systemUptime - started)
        }
        #expect(slowest < 0.1, "a build took \(Int(slowest * 1000)) ms")
        #expect(line(tray, "   📚 Learning baseline:")?.title == "   📚 Learning baseline: \(TrayAppManager.loading)")
        #expect(line(tray, "📹 Screenpipe:")?.title == "📹 Screenpipe: \(TrayAppManager.loading)")
    }

    /// The wristband lines: loading until the radio reports, then what it is doing; with a
    /// cloud token, loading until the relay has answered once.
    @Test func theWristbandSaysLoadingUntilTheRadioAndTheRelayAnswer() {
        typealias L = PavlokController.Link
        #expect(PavlokController.connectionText(L(requested: false)) == "⚪ Disabled (Safe Default)")
        #expect(PavlokController.connectionText(L(requested: true, radioAnswered: false)) == TrayAppManager.loading)
        #expect(PavlokController.summary(L(requested: true, radioAnswered: false), enabled: true) == TrayAppManager.loading)
        #expect(PavlokController.connectionText(L(requested: true, connecting: true, name: "Pavlok 3")) == "🔵 Connecting to Pavlok 3...")
        #expect(PavlokController.connectionText(L(requested: true, scanning: true)) == "🔵 Searching for Bluetooth Wristband...")
        #expect(PavlokController.connectionText(L(requested: true, token: true, cloudAnswered: false)) == "🟡 Cloud relay: \(TrayAppManager.loading)")
        #expect(PavlokController.connectionText(L(requested: true, token: true, online: true)) == "🟡 Online (Cloud Relay Backup • ~400ms)")
        #expect(PavlokController.connectionText(L(requested: true)) == "🔴 Bluetooth Disconnected (Turn on Pavlok)")
        #expect(PavlokController.connectionText(L(requested: true, connected: true, name: "P", battery: 80)).hasPrefix("🟢 Connected (P via Bluetooth • 80% 🔋"))
        #expect(PavlokController.summary(L(requested: true), enabled: true) == "🟡 Not connected")
        #expect(PavlokController.summary(L(requested: true, radioAnswered: false), enabled: false) == "⚪ Disabled")
    }
}

// Whose a slow menu open was: the click's wait, the build, the menu reaching the screen,
// and what the main thread did meanwhile.
@Suite("Menu open timing", .tags(.light, .status, .core), .timeLimit(.minutes(1)), .quietLog, .serialized)
struct MenuOpenTimingTests {
    @Test func aSlowOpenSaysWhoseTheWaitWas() {
        let fast = MenuOpenTiming(waited: 0.05, build: 0.003, shown: 0.02, mainCPU: 0.001, mainBlocked: 0)
        #expect(!fast.slow)
        let system = MenuOpenTiming(waited: 3.173, build: 0.004, shown: 0.04, mainCPU: 0.02, mainBlocked: 0)
        #expect(system.slow)
        #expect(system.line == "menu opened 3173 ms after the click (main thread ran 20 ms, longest block 0 ms: not the app: its main thread was free (the system, the menu bar, load)); built in 4 ms, on screen 40 ms later")
        let busy = MenuOpenTiming(waited: 2, build: 0.004, shown: nil, mainCPU: 1.8, mainBlocked: 1.9)
        #expect(busy.line.contains("the app: its main thread was busy") && busy.line.hasSuffix("on screen ? later"))
        let held = MenuOpenTiming(waited: 2, build: 0.004, shown: 0.01, mainCPU: 0.1, mainBlocked: 1.6)
        #expect(held.line.contains("held up (waiting, or starved of CPU)"))
        #expect(MenuOpenTiming(waited: 0.1, build: 0.2, shown: 0, mainCPU: nil, mainBlocked: 0).slow, "a slow build alone")
        #expect(MenuOpenTiming(waited: 0.1, build: 0.01, shown: 0.5, mainCPU: nil, mainBlocked: 0).slow, "slow to reach the screen")
    }

    /// The watch reads the main thread's CPU each check: a stall says how much of it the main
    /// thread ran, and a click is told what the main thread did since.
    @Test func theWatchSaysWhatTheMainThreadDidBeforeTheClick() {
        let cpu = Locked<TimeInterval>(10)
        let watch = MainThreadWatch(threshold: 1, cooldown: 600, onMain: { _ in }, sample: { _ in }, cpu: { cpu.value })
        let lines = capturingLog {
            watch.check(now: 100)            // reading 10 s; ping out
            cpu.value = 11.5
            watch.answered(now: 102)         // 2 s late, 1.5 s of it running: the app's work
            cpu.value = 11.6
            watch.check(now: 103)            // reading 11.6; a new ping out
            cpu.value = 11.65
            watch.check(now: 104.5)          // still out: main has not answered for 1.5 s
        }
        #expect(lines.contains { $0.contains("[Stall] the main thread was blocked for 2.0 s (ran 1.5 s of it: the app's own work)") }, "\(lines)")
        // A click at 103.5, the menu asked for at 104.6: the ping out since 103 held it 1.1 s.
        cpu.value = 11.7
        let before = watch.before(click: 103.5, now: 104.6)
        #expect(abs(before.blocked - 1.1) < 0.001)
        #expect(abs((before.cpu ?? -1) - 0.1) < 0.001, "CPU since the reading at 103: \(String(describing: before.cpu))")
        // An earlier stall that ended before the click does not count against it.
        let quiet = MainThreadWatch(threshold: 1, onMain: { _ in }, sample: { _ in }, cpu: { 1 })
        quiet.check(now: 10)
        quiet.answered(now: 12)
        #expect(quiet.before(click: 13, now: 13.2).blocked == 0)
        #expect(MainThreadWatch.describe(ran: 0.1, of: 2).hasSuffix("waiting (a lock, I/O, the system) or starved of CPU"))
    }

    /// A job says when its first run has finished (the menu's loading lines wait for it), and
    /// its saved state is on disk by the time the run shows as done.
    /// A job's first run since launch is what `hasRun` reports, and its outcome is on disk by then.
    @Test func aJobSaysWhenItHasRunAndItsStateIsSavedFirst() {
        let dir = TempDir("jobs")
        defer { dir.cleanup() }
        let gate = DispatchSemaphore(value: 0)
        let name = "hasrun-\(UUID().uuidString.prefix(6))"
        let job = Job(name, period: 3600, backoff: Backoff(base: 600, max: 600, jitter: 0), stateDir: dir.path) { _ in
            gate.wait()
            return .ok("done")
        }
        #expect(!job.hasRun)
        job.kick("test")
        usleep(100_000)
        #expect(!job.hasRun, "still running")
        gate.signal()
        #expect(waitFor(5) { job.hasRun && job.snapshot.lastRun != nil })
        let saved = Job(name, period: 3600, backoff: Backoff(base: 600, max: 600, jitter: 0), stateDir: dir.path) { _ in .idle }
        #expect(saved.snapshot.summary == "done")
        #expect(abs((saved.snapshot.lastRun ?? .distantPast).timeIntervalSince(job.snapshot.lastRun ?? .distantFuture)) < 0.01)
        #expect(!saved.hasRun, "a new launch has not run yet")
    }
}
