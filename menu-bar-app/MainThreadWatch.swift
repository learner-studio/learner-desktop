import Foundation

/// Notices the main thread stalling (a menu that takes seconds to open, a tray that stops
/// updating) and records what it was doing instead of leaving it to a guess: a stall over
/// `threshold` is logged when it ends, and at most once per `cooldown` a `sample` of the
/// process is saved to logs/main-thread-stall-<time>.txt while it is still stuck (the
/// newest five are kept; `sample` will not overwrite a file).
///
/// `sample` takes seconds to attach under load and so usually records the stall already
/// over; what tells the app's own work from a starved or waiting main thread is the main
/// thread's CPU time, read every check and put beside each stall and each slow menu open.
final class MainThreadWatch: Sendable {
    struct State {
        var ping: TimeInterval?
        var lastSample = -Double.infinity
        var menuOpen = false
        /// The main thread's CPU seconds at each check, the last `kept`.
        var readings: [(at: TimeInterval, cpu: TimeInterval)] = []
        /// Recent late pings: when the main thread stopped answering and when it ran again.
        var blocks: [(from: TimeInterval, to: TimeInterval)] = []
    }
    /// What the main thread did between a click and the menu opening.
    struct Before: Equatable {
        /// CPU seconds it ran (nil before the first reading).
        var cpu: TimeInterval?
        /// The longest stretch of it it did not answer.
        var blocked: TimeInterval
    }
    static let kept = 75
    /// A late ping this long counts as a block in `before` (the log keeps to `threshold`).
    static let noted: TimeInterval = 0.25

    let threshold: TimeInterval
    let cooldown: TimeInterval
    private let state = Locked(State())
    private let log = Log("Stall")
    /// Runs the ping on the main thread; the sampler records the process (both swapped in tests).
    private let onMain: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let sample: @Sendable (String) -> Void
    private let cpu: @Sendable () -> TimeInterval?

    init(threshold: TimeInterval = 1, cooldown: TimeInterval = 600,
         onMain: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = MainThreadWatch.onMainRunLoop,
         sample: @escaping @Sendable (String) -> Void = { _ = ChildProcess.run("/usr/bin/sample", ["\(getpid())", "2", "-file", $0], timeout: 15) },
         cpu: @escaping @Sendable () -> TimeInterval? = MainThreadWatch.mainThreadCPU) {
        self.threshold = threshold
        self.cooldown = cooldown
        self.onMain = onMain
        self.sample = sample
        self.cpu = cpu
    }

    /// The main thread's port, noted from the main thread by `start` (Swift cannot call
    /// pthread_main_thread_np).
    private static let mainPort = Locked<mach_port_t?>(nil)

    /// The main thread's user + system CPU seconds so far (any thread may ask).
    static let mainThreadCPU: @Sendable () -> TimeInterval? = {
        guard let port = mainPort.value else { return nil }
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let t = [info.user_time, info.system_time]
        return t.reduce(0) { $0 + Double($1.seconds) + Double($1.microseconds) / 1_000_000 }
    }

    func start() {
        if Thread.isMainThread { MainThreadWatch.mainPort.value = pthread_mach_thread_np(pthread_self()) }
        let thread = Thread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 0.2)
                check(now: ProcessInfo.processInfo.systemUptime)
            }
        }
        thread.name = "learner.main-thread-watch"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// While a menu is open AppKit's menu loop holds the main thread on purpose: not a stall.
    func menu(open: Bool) {
        state.withLock { s in
            s.menuOpen = open
            s.ping = nil
        }
    }

    /// One look: send a ping if none is out; sample once if the one out is overdue.
    func check(now: TimeInterval) {
        enum Next { case ping, sample(TimeInterval), wait }
        let used = cpu()
        let next: Next = state.withLock { s in
            if let used {
                s.readings.append((now, used))
                if s.readings.count > MainThreadWatch.kept { s.readings.removeFirst(s.readings.count - MainThreadWatch.kept) }
            }
            if s.menuOpen { s.ping = nil; return .wait }
            guard let sent = s.ping else { s.ping = now; return .ping }
            guard now - sent >= threshold, now - s.lastSample >= cooldown else { return .wait }
            s.lastSample = now
            return .sample(now - sent)
        }
        switch next {
        case .ping:
            onMain { [self] in answered(now: ProcessInfo.processInfo.systemUptime) }
        case .sample(let stuck):
            let file = MainThreadWatch.sampleFile(at: Date())
            log.warn("the main thread has not answered for \(String(format: "%.1f", stuck)) s; sampling it to \(file)")
            sample(file)
        case .wait:
            break
        }
    }

    /// Runs `block` on the main run loop in its common modes, which include a menu's event
    /// tracking: an open menu is not a stall (the main dispatch queue can wait it out).
    static let onMainRunLoop: @Sendable (@escaping @Sendable () -> Void) -> Void = { block in
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(main)
    }

    /// A new file per sample; older ones beyond the newest `keep` are removed.
    static func sampleFile(at date: Date, dir: String = Paths.logs, keep: Int = 5) -> String {
        let fm = FileManager.default
        let old = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("main-thread-stall") }.sorted()
        for name in old.dropLast(max(0, keep - 1)) { try? fm.removeItem(atPath: dir + "/" + name) }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        return "\(dir)/main-thread-stall-\(stamp.string(from: date)).txt"
    }

    /// The main thread ran the ping: a late answer is a stall, logged with its length and
    /// how much of it the main thread spent running (the app's own work) rather than waiting.
    func answered(now: TimeInterval) {
        let used = cpu()
        guard let late = state.withLock({ s -> (sent: TimeInterval, ran: TimeInterval?)? in
            defer { s.ping = nil }
            guard let sent = s.ping else { return nil }
            if now - sent >= MainThreadWatch.noted {
                s.blocks.append((sent, now))
                if s.blocks.count > 20 { s.blocks.removeFirst() }
            }
            return (sent, used.flatMap { u in MainThreadWatch.reading(s.readings, atOrBefore: sent).map { u - $0 } })
        }) else { return }
        let (sent, ran) = late
        if now - sent >= threshold {
            log.warn("the main thread was blocked for \(String(format: "%.1f", now - sent)) s\(ran.map { " (\(MainThreadWatch.describe(ran: $0, of: now - sent)))" } ?? "")")
        }
    }

    /// "ran 1.2 s of it: the app's own work", or "ran 0.1 s of it: waiting or starved".
    static func describe(ran: TimeInterval, of span: TimeInterval) -> String {
        "ran \(String(format: "%.1f", ran)) s of it: " + (ran >= span / 2 ? "the app's own work" : "waiting (a lock, I/O, the system) or starved of CPU")
    }

    /// What the main thread did from `click` until `now`. Called on the main thread when the
    /// menu is asked for, before `menu(open:)` (which forgets the ping out).
    func before(click: TimeInterval, now: TimeInterval) -> Before {
        let used = cpu()
        return state.withLock { s in
            var spans = s.blocks
            if let sent = s.ping { spans.append((sent, now)) }
            let blocked = spans.map { max(0, min($0.to, now) - max($0.from, click)) }.max() ?? 0
            let ran = used.flatMap { u in MainThreadWatch.reading(s.readings, atOrBefore: click).map { u - $0 } }
            return Before(cpu: ran.map { max(0, $0) }, blocked: blocked)
        }
    }

    /// The last reading taken at or before `t` (else the first one).
    static func reading(_ readings: [(at: TimeInterval, cpu: TimeInterval)], atOrBefore t: TimeInterval) -> TimeInterval? {
        (readings.last { $0.at <= t } ?? readings.first)?.cpu
    }
}
