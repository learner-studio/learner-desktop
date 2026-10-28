import Foundation

/// Notices the main thread stalling (a menu that takes seconds to open, a tray that stops
/// updating) and records what it was doing instead of leaving it to a guess: a stall over
/// `threshold` is logged when it ends, and at most once per `cooldown` a `sample` of the
/// process is saved to logs/main-thread-stall.txt while it is still stuck.
final class MainThreadWatch: Sendable {
    struct State { var ping: TimeInterval?; var lastSample = -Double.infinity }

    let threshold: TimeInterval
    let cooldown: TimeInterval
    private let state = Locked(State())
    private let log = Log("Stall")
    /// Runs the ping on the main thread; the sampler records the process (both swapped in tests).
    private let onMain: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let sample: @Sendable (String) -> Void

    init(threshold: TimeInterval = 1, cooldown: TimeInterval = 600,
         onMain: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         sample: @escaping @Sendable (String) -> Void = { _ = ChildProcess.run("/usr/bin/sample", ["\(getpid())", "2", "-file", $0], timeout: 15) }) {
        self.threshold = threshold
        self.cooldown = cooldown
        self.onMain = onMain
        self.sample = sample
    }

    func start() {
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

    /// One look: send a ping if none is out; sample once if the one out is overdue.
    func check(now: TimeInterval) {
        enum Next { case ping, sample(TimeInterval), wait }
        let next: Next = state.withLock { s in
            guard let sent = s.ping else { s.ping = now; return .ping }
            guard now - sent >= threshold, now - s.lastSample >= cooldown else { return .wait }
            s.lastSample = now
            return .sample(now - sent)
        }
        switch next {
        case .ping:
            onMain { [self] in answered(now: ProcessInfo.processInfo.systemUptime) }
        case .sample(let stuck):
            let file = Paths.logs + "/main-thread-stall.txt"
            log.warn("the main thread has not answered for \(String(format: "%.1f", stuck)) s; sampling it to \(file)")
            sample(file)
        case .wait:
            break
        }
    }

    /// The main thread ran the ping: a late answer is a stall, logged with its length.
    func answered(now: TimeInterval) {
        guard let sent = state.withLock({ s -> TimeInterval? in defer { s.ping = nil }; return s.ping }) else { return }
        if now - sent >= threshold { log.warn("the main thread was blocked for \(String(format: "%.1f", now - sent)) s") }
    }
}
