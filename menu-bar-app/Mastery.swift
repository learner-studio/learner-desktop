import AppKit
import Foundation

// Mastery notifications (docs/mastery-notifications.md, D2–D6), one workflow:
//   learner-server getMasteryNotifications(since:) every 5 min -> new gains kept in
//   UserDefaults (the cursor, the run ids seen, the pending toasts) -> on the main thread,
//   one toast, or one summary when more than two wait or a call held them -> the click
//   (or none in 8 s) queued as recordNotificationFeedback and sent by the same job.
// Positive only: a reading that is not above the one before is never shown, and nothing on
// the desktop ever names a drop. Every step is idempotent: a restart resumes from what is
// saved, never shows a toast twice, and resends feedback the server may already have.

// MARK: - Wire shapes

/// One gain: a concept's first clear reading, or a rise of at least +10 (the server's rule).
struct MasteryNotification: Codable, Equatable, Sendable {
    let runId: String
    let conceptId: String
    let conceptName: String
    let percent: Int
    /// The best earlier reading for a gain; nil for a first clear reading (whose own best
    /// earlier reading, which may be higher, is never shown).
    let previousPercent: Int?
    let completedAt: Date
    /// The learner's own words from the reading, when it has some.
    var quote: String? = nil

    /// The toast's line. Gains only, so there is no wording for a drop.
    var line: String {
        previousPercent.map { "▲ \($0)% → \(percent)%" } ?? "First confident reading: \(percent)%"
    }

    /// A gain, or nil for anything else (a drop or no change is never shown, whatever the
    /// server sends).
    static func gain(_ o: [String: Any]) -> MasteryNotification? {
        guard let runId = text(o["runId"]), let conceptId = text(o["conceptId"]),
              let percent = number(o["percent"]), let at = MasteryNotification.date(o["completedAt"]) else { return nil }
        // The contract's two kinds (learner-server packages/contract/src/learning/mastery.ts);
        // anything else is not a gain. A first clear reading is shown as such even when its best
        // earlier reading (previousPercent) was higher: that number is never shown.
        let previous: Int?
        switch o["kind"] as? String {
        case "first_clear": previous = nil
        case "gain":
            guard let p = number(o["previousPercent"]), let delta = (o["delta"] as? NSNumber)?.doubleValue, delta > 0,
                  percent > p else { return nil }
            previous = p
        default: return nil
        }
        let quote = text(o["quote"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        return MasteryNotification(runId: runId, conceptId: conceptId,
                                   conceptName: text(o["conceptName"]) ?? conceptId, percent: percent,
                                   previousPercent: previous, completedAt: at, quote: quote?.isEmpty == false ? quote : nil)
    }

    static func text(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        if let n = v as? NSNumber, !MasteryNotification.isBool(n) { return n.stringValue }
        return nil
    }

    static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }

    static func number(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, !MasteryNotification.isBool(n) else { return nil }
        return Int(n.doubleValue.rounded())
    }

    static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// getBaselineStatus: how far each baseline is from enough data.
struct BaselineStatus: Codable, Equatable, Sendable {
    struct Count: Codable, Equatable, Sendable {
        let have: Int
        let need: Int
    }
    struct Arm: Codable, Equatable, Sendable {
        let arm: String
        let count: Count
    }

    var learning: Count?
    var learningDaysLeft: Int?
    var arms: [Arm] = []
    var coachDaysLeft: Int?

    static func parse(_ body: Any?) -> BaselineStatus? {
        guard let o = body as? [String: Any] else { return nil }
        func count(_ v: Any?) -> Count? {
            guard let c = v as? [String: Any], let have = MasteryNotification.number(c["have"]),
                  let need = MasteryNotification.number(c["need"]) else { return nil }
            return Count(have: max(0, have), need: max(0, need))
        }
        func days(_ v: Any?) -> Int? { (v as? NSNumber).map { Int(ceil($0.doubleValue)) } }
        let learning = o["learning"] as? [String: Any]
        let coach = o["coach"] as? [String: Any]
        let arms = (coach?["arms"] as? [[String: Any]] ?? []).compactMap { a -> Arm? in
            guard let name = MasteryNotification.text(a["arm"]), let c = count(a) else { return nil }
            return Arm(arm: name, count: c)
        }
        return BaselineStatus(learning: learning.flatMap(count), learningDaysLeft: days(learning?["daysLeft"]),
                              arms: arms, coachDaysLeft: days(coach?["daysLeft"]))
    }

    static func pace(_ c: Count, _ days: Int?, unit: String) -> String {
        if c.need == 0 { return "no \(unit) yet" }
        if c.have >= c.need { return "✓ set (\(c.have)/\(c.need) \(unit))" }
        return "\(c.have)/\(c.need) \(unit) · " + (days.map { "~\($0) day\($0 == 1 ? "" : "s") left" } ?? "estimating your pace")
    }

    /// The tray's learning baseline line.
    var learningLine: String {
        "📚 Learning baseline: " + (learning.map { BaselineStatus.pace($0, learningDaysLeft, unit: "concepts") } ?? "no concepts yet")
    }

    /// The tray's coach baseline line, from the slowest arm; nil when the server sent no arms.
    var coachLine: String? {
        guard let slowest = arms.min(by: { Double($0.count.have) / Double(max(1, $0.count.need)) < Double($1.count.have) / Double(max(1, $1.count.need)) })
        else { return nil }
        let per = arms.map { "\($0.arm) \($0.count.have)/\($0.count.need)" }.joined(separator: " · ")
        let pace = slowest.count.have >= slowest.count.need ? "✓ set"
            : coachDaysLeft.map { "~\($0) day\($0 == 1 ? "" : "s") left" } ?? "estimating your pace"
        return "📊 Coach baseline: \(per) · \(pace)"
    }
}

/// What a toast's click (or no click) tells the server.
enum MasteryAction: String, Codable, Sendable, CaseIterable {
    case opened, nice
    case notRight = "not_right"
    case ignored
}

/// Where Open goes: `<web>osmosis?conceptId=<id>`, with `<web>` the Learner web root the
/// server advertises (…/learner/). A server that publishes none has no link (as the tray's
/// "Open Learner" line): Open then opens nothing and counts as ignored.
enum MasteryLink {
    /// What JavaScript's encodeURIComponent leaves as is.
    static let uriComponent = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

    static func url(web: String?, conceptId: String?) -> URL? {
        guard var root = web?.trimmingCharacters(in: .whitespaces), !root.isEmpty else { return nil }
        // The web root is a folder (learner-server always sends the trailing slash since 6656a17);
        // without it, URL resolution would replace its last segment.
        if !root.contains("?") && !root.contains("#") && !root.hasSuffix("/") { root += "/" }
        // As the web app builds it: new URL("osmosis?conceptId=" + encodeURIComponent(id), web).
        let query = conceptId.flatMap { $0.addingPercentEncoding(withAllowedCharacters: MasteryLink.uriComponent) }.map { "?conceptId=\($0)" } ?? ""
        guard let base = URL(string: root), ["http", "https"].contains(base.scheme?.lowercased() ?? ""), base.host != nil else { return nil }
        return URL(string: "osmosis" + query, relativeTo: base)?.absoluteURL
    }
}

// MARK: - Feed job

/// The 5-minute job and everything it keeps. Everything mutable is in UserDefaults, read and
/// written under one lock, so the job's queue and the main thread never interleave a change.
final class MasteryFeed: Sendable {
    static let shared = MasteryFeed()

    static let period: TimeInterval = 300
    /// Per page; a backlog (days offline) is read page after page, up to `maxPages` a run.
    static let pageLimit = 50
    static let maxPages = 20
    /// Each query reaches back this far before the cursor (the seen run ids dedupe it), so a
    /// run committed after a newer one, or a server clock behind this Mac's, is not missed.
    static let overlap: TimeInterval = 900
    /// Run ids remembered (beyond the cursor) so a reading at the cursor's own instant is
    /// never shown twice.
    static let seenKept = 3000

    enum Key {
        static let since = "mastery_since"
        static let installedAt = "mastery_installed_at"
        static let seen = "mastery_seen_runs"
        static let pending = "mastery_pending"
        static let feedback = "mastery_feedback"
        static let baseline = "mastery_baseline"
        /// The newest few gains, as the server last listed them (the tray's recent rows).
        static let recent = "mastery_recent"
        /// Runs opened from a tray row: never shown again as a toast, never reported ignored.
        static let openedRuns = "mastery_opened_runs"
        static let holdDuringCalls = "mastery_hold_during_calls"
        /// Run ids on screen now: a quit before their click is sent as `ignored` at next launch.
        static let showing = "mastery_showing"
    }

    struct Feedback: Codable, Equatable, Sendable {
        let runId: String
        let action: MasteryAction
    }

    /// The last answer: nil before the first, false while learner-server does not answer.
    enum Reach: Sendable { case unknown, online, offline }

    let rpc: LearnerRPC
    // nonisolated(unsafe): UserDefaults is thread-safe; every read-modify-write is under `lock`.
    nonisolated(unsafe) private let defaults: UserDefaults
    private let lock = NSLock()
    private let clock: @Sendable () -> Date
    private let reach = Locked(Reach.unknown)
    // nonisolated(unsafe): assigned once at the end of init (its body needs `self`); only read after.
    nonisolated(unsafe) private(set) var job: Job!
    private let log = Log("Mastery")
    /// Whether a click sends its feedback at once (tests send it by running the job).
    private let sendFeedbackAtOnce: Bool

    init(rpc: LearnerRPC = .shared, defaults: UserDefaults = .standard, jobName: String = "Mastery",
         firstRun: TimeInterval = 20, stateDir: String = Job.stateDir, sendFeedbackAtOnce: Bool = true,
         clock: @escaping @Sendable () -> Date = Date.init) {
        self.rpc = rpc
        self.sendFeedbackAtOnce = sendFeedbackAtOnce
        self.defaults = defaults
        self.clock = clock
        job = Job(jobName, period: MasteryFeed.period, firstRun: firstRun, backoff: Backoff(base: 60, max: 1800),
                  problemGrace: 1800, quiet: true, stateDir: stateDir) { [weak self] _ in self?.runOnce() ?? .idle }
        // A toast that was up when the app last quit (or crashed) got no click: ignored.
        lock.withLock {
            let opened = Set(defaults.stringArray(forKey: Key.openedRuns) ?? [])
            let left = (defaults.stringArray(forKey: Key.showing) ?? []).filter { !opened.contains($0) }
            if !left.isEmpty { enqueue(left, .ignored) }
            defaults.removeObject(forKey: Key.showing)
        }
    }

    // MARK: Saved state

    private func decode<T: Decodable>(_ key: String, _ type: T.Type) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func encode<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    /// Gains not shown yet, oldest first.
    var pending: [MasteryNotification] { lock.withLock { decode(Key.pending, [MasteryNotification].self) ?? [] } }
    var since: Date? { lock.withLock { defaults.object(forKey: Key.since) as? Date } }
    var queuedFeedback: [Feedback] { lock.withLock { decode(Key.feedback, [Feedback].self) ?? [] } }
    var baseline: BaselineStatus? { lock.withLock { decode(Key.baseline, BaselineStatus.self) } }
    /// The newest gains or first clear readings, newest first (never a drop: `gain` only).
    var recent: [MasteryNotification] { lock.withLock { decode(Key.recent, [MasteryNotification].self) ?? [] } }
    static let recentShown = 3
    var reachable: Reach { reach.value }

    /// Settings › "Hold while I'm in a call" (on unless switched off).
    var holdDuringCalls: Bool {
        get { defaults.object(forKey: Key.holdDuringCalls) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.holdDuringCalls) }
    }

    /// Moves these from pending to on screen as they are shown: from here on a restart never
    /// shows them, and one that quits before the click reports them ignored.
    func take(_ runIds: [String]) {
        lock.withLock {
            let left = (decode(Key.pending, [MasteryNotification].self) ?? []).filter { !runIds.contains($0.runId) }
            encode(left, Key.pending)
            let showing = defaults.stringArray(forKey: Key.showing) ?? []
            defaults.set(showing + runIds.filter { !showing.contains($0) }, forKey: Key.showing)
        }
    }

    /// A recent-gain row clicked: opens the concept on the Map and, once opened, tells the
    /// server (`opened`, sent at once like a toast's click). The URL, or nil when nothing opened.
    func openRecent(_ runId: String, conceptId: String? = nil, web: String?, open: (URL) -> Bool) -> URL? {
        // The row carries its concept, so a list refreshed while the menu was open still opens it.
        guard let concept = conceptId ?? recent.first(where: { $0.runId == runId })?.conceptId else {
            log.warn("recent gain \(runId) is no longer in the list; nothing opened")
            return nil
        }
        guard let url = MasteryLink.url(web: web, conceptId: concept) else { return nil }
        guard open(url) else {
            log.warn("recent gain \(runId): could not open \(url.absoluteString)")
            return nil
        }
        log.info("recent gain opened: \(runId) -> \(url.absoluteString)")
        lock.withLock {
            defaults.set(Array(((defaults.stringArray(forKey: Key.openedRuns) ?? []) + [runId]).suffix(200)), forKey: Key.openedRuns)
            // Opened already: its toast, if still waiting, is not shown.
            encode((decode(Key.pending, [MasteryNotification].self) ?? []).filter { $0.runId != runId }, Key.pending)
        }
        record([runId], .opened)
        return url
    }

    /// Runs opened from a tray row.
    var openedRuns: Set<String> { lock.withLock { Set(defaults.stringArray(forKey: Key.openedRuns) ?? []) } }

    /// Tests: the recent rows as if fetched.
    func storeRecent(_ rows: [MasteryNotification]?) {
        lock.withLock { if let rows { encode(rows, Key.recent) } else { defaults.removeObject(forKey: Key.recent) } }
    }
    var storedRecent: [MasteryNotification]? { lock.withLock { decode(Key.recent, [MasteryNotification].self) } }

    /// A toast taken down by a call before any click: back to waiting, first in line.
    func putBack(_ ns: [MasteryNotification]) {
        lock.withLock {
            let opened = Set(defaults.stringArray(forKey: Key.openedRuns) ?? [])
            let ns = ns.filter { !opened.contains($0.runId) }   // opened from the tray meanwhile
            let ids = ns.map(\.runId)
            let rest = (decode(Key.pending, [MasteryNotification].self) ?? []).filter { !ids.contains($0.runId) }
            encode(ns + rest, Key.pending)
            defaults.set((defaults.stringArray(forKey: Key.showing) ?? []).filter { !ids.contains($0) }, forKey: Key.showing)
        }
    }

    /// The baseline as last fetched (tests set it).
    func store(_ b: BaselineStatus?) {
        lock.withLock { if let b { encode(b, Key.baseline) } else { defaults.removeObject(forKey: Key.baseline) } }
    }

    /// Queues a toast's outcome and sends it now; kept until the server has it.
    func record(_ runIds: [String], _ action: MasteryAction) {
        lock.withLock {
            // A toast that timed out for a run already opened from the tray: the open stands.
            let opened = action == .ignored ? Set(defaults.stringArray(forKey: Key.openedRuns) ?? []) : []
            enqueue(runIds.filter { !opened.contains($0) }, action)
            defaults.set((defaults.stringArray(forKey: Key.showing) ?? []).filter { !runIds.contains($0) }, forKey: Key.showing)
        }
        if sendFeedbackAtOnce { job.kick("feedback \(action.rawValue)") }
    }

    /// Under `lock`.
    private func enqueue(_ runIds: [String], _ action: MasteryAction) {
        var q = decode(Key.feedback, [Feedback].self) ?? []
        for id in runIds where !q.contains(Feedback(runId: id, action: action)) { q.append(Feedback(runId: id, action: action)) }
        encode(q, Key.feedback)
    }

    // MARK: Run

    /// One run: send queued feedback, fetch new gains, refresh the baselines.
    func runOnce() -> Job.Outcome {
        let feedbackProblem = sendFeedback()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // The first run starts from now, so an install does not replay old history.
        // Where showing starts, kept for good: the install (or, for an install from before this
        // key, its saved cursor) less the reach-back, so a server clock behind this Mac's or a
        // late commit near the install is still shown; nothing older ever is, however many runs
        // reading that window takes.
        let (cursor, installedAt) = lock.withLock { () -> (Date, Date) in
            let since = defaults.object(forKey: Key.since) as? Date
            let installed = defaults.object(forKey: Key.installedAt) as? Date ?? (since ?? clock()).addingTimeInterval(-MasteryFeed.overlap)
            defaults.set(installed, forKey: Key.installedAt)
            // No answer yet (offline, no key at first): the first query that gets one still asks
            // from where showing starts, however long after the install that is.
            return (since ?? installed.addingTimeInterval(MasteryFeed.overlap), installed)
        }
        // Pages: the server returns the OLDEST `limit` after `since` (newest first within the
        // page, a group with one completedAt never split), so each next page starts at the
        // newest reading of the last one, until a page is not full.
        var since = cursor.addingTimeInterval(-MasteryFeed.overlap)
        // A next page starts at the newest row's own completedAt, as the server sent it: never
        // a Date formatted again, so a tie group at a page boundary is never asked for twice.
        var sinceText = iso.string(from: since)
        var added = 0
        for page in 0..<MasteryFeed.maxPages {
            let reply = rpc.call("getMasteryNotifications", ["since": sinceText, "limit": MasteryFeed.pageLimit])
            guard reply.kind == .ok else {
                // Offline is no answer or a server error; any other reply (a key problem, which the
                // learner-server line reports, or a refused call) means it is there. No key:
                // nothing was asked, so nothing is known about the server.
                reach.value = reply.kind == .noKey ? .unknown : reply.status == 0 || reply.status >= 500 ? .offline : .online
                // No key is not a block: pairing or an unlocked Keychain fixes it without a click,
                // so it is retried on the backoff like any other failure. Pages already taken are kept.
                return .failed("getMasteryNotifications: \(reply.describe)\(reply.message.map { " (\($0))" } ?? "")")
            }
            reach.value = .online
            let raw = ((reply.body as? [String: Any])?["notifications"] as? [[String: Any]]) ?? []
            // Only rows this app can read move the cursor or count as seen: an unreadable one is
            // logged and asked for again next time (the overlap), never silently skipped.
            let readable = raw.compactMap { o -> (id: String, at: Date, text: String)? in
                guard let id = MasteryNotification.text(o["runId"]), let text = o["completedAt"] as? String,
                      let at = MasteryNotification.date(text) else { return nil }
                return (id, at, text)
            }
            if readable.count < raw.count { log.warn("\(raw.count - readable.count) notification(s) without a runId or completedAt skipped") }
            let gains = raw.compactMap(MasteryNotification.gain)
            if gains.count < readable.count { log.noisy("\(readable.count - gains.count) reading(s) not shown: not a first clear reading or a gain") }
            let newest = readable.map(\.at).max()
            added += lock.withLock { () -> Int in
                var seen = defaults.stringArray(forKey: Key.seen) ?? []
                var pending = decode(Key.pending, [MasteryNotification].self) ?? []
                let opened = Set(defaults.stringArray(forKey: Key.openedRuns) ?? [])
                let fresh = gains.filter { $0.completedAt > installedAt && !seen.contains($0.runId) && !opened.contains($0.runId) }.sorted { $0.completedAt < $1.completedAt }
                pending += fresh
                for r in readable where !seen.contains(r.id) { seen.append(r.id) }
                seen = Array(seen.suffix(MasteryFeed.seenKept))
                encode(pending, Key.pending)
                defaults.set(seen, forKey: Key.seen)
                let saved = defaults.object(forKey: Key.since) as? Date
                if let n = newest, n > (saved ?? cursor) { defaults.set(n, forKey: Key.since) }
                else if saved == nil { defaults.set(cursor, forKey: Key.since) }
                return fresh.count
            }
            guard raw.count >= MasteryFeed.pageLimit, let n = newest, n > since,
                  let text = readable.first(where: { $0.at == n })?.text else { break }
            if page == MasteryFeed.maxPages - 1 { log.warn("\(MasteryFeed.maxPages) full pages: the rest waits for the next run") }
            since = n
            sinceText = text
        }
        if added > 0 { log.info("\(added) new gain(s) waiting") }
        // The tray's recent rows: the server's newest few, read fresh each run (since null), so
        // they never depend on what this install has seen.
        // A few more than shown, so a row this app drops never leaves a gap.
        let latest = rpc.call("getMasteryNotifications", ["since": NSNull(), "limit": MasteryFeed.recentShown * 4])
        if latest.kind != .ok { log.noisy("recent gains not refreshed: \(latest.describe)") }
        if latest.kind == .ok {
            let rows = (((latest.body as? [String: Any])?["notifications"] as? [[String: Any]]) ?? []).compactMap(MasteryNotification.gain)
            let newest = rows.sorted { ($0.completedAt, $0.runId) > ($1.completedAt, $1.runId) }
            lock.withLock { encode(Array(newest.prefix(MasteryFeed.recentShown)), Key.recent) }
        }
        let status = rpc.call("getBaselineStatus", [:])
        if status.kind == .ok, let b = BaselineStatus.parse(status.body) {
            lock.withLock { encode(b, Key.baseline) }
        }
        if let problem = feedbackProblem { return .failed(problem) }
        return added > 0 ? .ok("\(added) new") : idleOrRecovered(job, "up to date")
    }

    /// Sends queued feedback oldest first. A refused or too-large one is dropped; one the server
    /// cannot take now stays queued, and the rest are still tried (none waits behind it).
    private func sendFeedback() -> String? {
        for f in queuedFeedback {
            let r = rpc.call("recordNotificationFeedback", ["runId": f.runId, "action": f.action.rawValue])
            switch r.kind {
            case .ok:
                if (r.body as? [String: Any])?["recorded"] as? Bool == false {
                    log.warn("feedback \(f.action.rawValue) for run \(f.runId): not one of the learner's live readings; dropped")
                }
            case .rejected, .tooLarge:
                log.warn("feedback \(f.action.rawValue) for run \(f.runId) refused: \(r.message ?? r.describe); dropped")
            case .noKey, .auth, .transient:
                // The server or the key, not this row: the rest would fail the same way.
                return "recordNotificationFeedback: \(r.describe)"
            case .unexpected:
                // A server or proxy that cannot place it (404/405): kept and retried each run, but
                // never fails the run, so gains are not delayed by a backoff on its account.
                log.noisy("feedback \(f.action.rawValue) for run \(f.runId): \(r.describe); kept for the next run")
                continue
            }
            lock.withLock {
                encode((decode(Key.feedback, [Feedback].self) ?? []).filter { $0 != f }, Key.feedback)
            }
        }
        return nil
    }
}

// MARK: - Presenter

/// What one toast shows.
struct MasteryToastContent: Equatable {
    let title: String
    let detail: String
    let link: URL?
    let runIds: [String]
    /// Nice / Not right: for a single gain only.
    let asksFeedback: Bool

    static func single(_ n: MasteryNotification, link: URL?) -> MasteryToastContent {
        // Tentative: a +10 is often within grader noise (learner-server's replay, S0).
        // A first clear reading is the grader's first confident one, not mastery (a confident 10%
        // is one too): named for what it is, never "you understand".
        MasteryToastContent(title: n.previousPercent == nil ? "🎓 First confident reading of \(n.conceptName)" : "🎓 Looks like you've improved at \(n.conceptName)", detail: n.line + (n.quote.map { " · “\($0)”" } ?? ""),
                            link: link, runIds: [n.runId], asksFeedback: true)
    }

    static func summary(_ ns: [MasteryNotification], link: URL?) -> MasteryToastContent {
        // Concepts, not runs; and neutral, since a first confident reading may sit below an
        // earlier one (learner-server's rule), so not every item is "progress".
        var names: [String] = []
        for n in ns where !names.contains(n.conceptName) { names.append(n.conceptName) }
        let shown = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " +\(names.count - 3) more" : "")
        return MasteryToastContent(title: "🎓 New mastery readings on \(names.count) concept\(names.count == 1 ? "" : "s")", detail: shown,
                                   link: link, runIds: ns.map(\.runId), asksFeedback: false)
    }
}

@MainActor
protocol MasteryToasting: AnyObject {
    var isShowing: Bool { get }
    /// Shows it; `done` is called once, with the click or `.ignored` after the timeout.
    func show(_ content: MasteryToastContent, done: @escaping @MainActor (MasteryAction) -> Void)
    /// Takes it down unclicked (`done(.ignored)`): a call started.
    func dismiss()
}

/// Shows waiting gains when no call holds them: one at a time, or one summary.
@MainActor
final class MasteryPresenter {
    enum Plan: Equatable { case single, summary }

    /// More than two at once is one summary; after a call, anything more than one is.
    static func plan(count: Int, afterCall: Bool) -> Plan {
        count > 2 || (afterCall && count > 1) ? .summary : .single
    }

    let feed: MasteryFeed
    let toast: MasteryToasting
    var inCall: () -> Bool
    var openURL: (URL) -> Bool
    var web: () -> String?
    private var heldByCall = false
    /// What the toast on screen shows, until its outcome.
    private var onScreen: [MasteryNotification] = []
    private var takenDownByCall = false
    private let log = Log("Mastery")

    init(feed: MasteryFeed, toast: MasteryToasting, inCall: @escaping () -> Bool, openURL: @escaping (URL) -> Bool,
         web: @escaping () -> String? = { PairingLink.shared.held?.web }) {
        self.feed = feed
        self.toast = toast
        self.inCall = inCall
        self.openURL = openURL
        self.web = web
    }

    private func link(_ conceptId: String?) -> URL? {
        MasteryLink.url(web: web(), conceptId: conceptId)
    }

    /// Main thread, every couple of seconds: shows what waits, unless a toast is up or a
    /// call holds it.
    func tick() {
        // Its runs were opened from the tray while it was up: take it down (the open stands;
        // the timeout's `ignored` is not recorded for an opened run).
        if toast.isShowing, !onScreen.isEmpty, onScreen.allSatisfy({ feed.openedRuns.contains($0.runId) }) {
            toast.dismiss()
            return
        }
        if feed.holdDuringCalls && inCall() {
            // No toast during a call, not even one shown just before it started.
            if toast.isShowing {
                takenDownByCall = true
                toast.dismiss()
            }
            if !heldByCall { log.info("call: mastery toasts held") }
            heldByCall = true
            return
        }
        guard !toast.isShowing else { return }
        let waiting = feed.pending
        guard !waiting.isEmpty else { heldByCall = false; return }
        let content: MasteryToastContent
        switch MasteryPresenter.plan(count: waiting.count, afterCall: heldByCall) {
        case .single:
            content = .single(waiting[0], link: link(waiting[0].conceptId))
            onScreen = [waiting[0]]
        case .summary:
            content = .summary(waiting, link: link(nil))
            onScreen = waiting
        }
        heldByCall = false
        feed.take(content.runIds)
        log.info("showing \(content.runIds.count == 1 ? "a toast" : "a summary of \(content.runIds.count)")")
        toast.show(content) { [weak self] action in
            guard let self else { return }
            let shown = self.onScreen
            self.onScreen = []
            if self.takenDownByCall {
                // Not seen long enough to count: shown again after the call.
                self.takenDownByCall = false
                self.feed.putBack(shown)
                return
            }
            var outcome = action
            if action == .opened, !(content.link.map(self.openURL) ?? false) { outcome = .ignored }
            self.log.info("toast outcome: \(outcome.rawValue) (\(content.runIds.joined(separator: ", ")))\(outcome == .opened ? " -> \(content.link?.absoluteString ?? "")" : "")")
            self.feed.record(content.runIds, outcome)
        }
    }
}

// MARK: - Toast

/// The coach toast's panel (MonologueToastController), with Open, Nice and Not right.
@MainActor
final class MasteryToastController: NSObject, MasteryToasting {
    static let shared = MasteryToastController()
    /// No click in this long is `ignored`.
    var timeout: TimeInterval = 8

    private(set) var panel: NSPanel?
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var feedbackButtons: [NSButton] = []
    private var openButton: NSButton?
    private(set) var isShowing = false
    private var done: (@MainActor (MasteryAction) -> Void)?
    private var timer: Timer?
    private let size = NSSize(width: 340, height: 90)

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        // Hidden from screen sharing and recording.
        p.sharingType = .none

        let ve = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        ve.material = .hudWindow
        ve.blendingMode = .behindWindow
        ve.state = .active
        ve.wantsLayer = true
        ve.layer?.cornerRadius = 18
        ve.layer?.masksToBounds = true
        ve.layer?.borderWidth = 1
        ve.layer?.borderColor = NSColor(calibratedRed: 0.3, green: 0.8, blue: 0.45, alpha: 0.5).cgColor
        let w = size.width, h = size.height
        title.frame = NSRect(x: 16, y: h - 30, width: w - 32, height: 18)
        title.font = .boldSystemFont(ofSize: 13)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        detail.frame = NSRect(x: 16, y: h - 50, width: w - 32, height: 16)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = NSColor(white: 0.9, alpha: 1)
        detail.lineBreakMode = .byTruncatingTail
        func button(_ label: String, _ x: CGFloat, _ action: Selector) -> NSButton {
            let b = NSButton(frame: NSRect(x: x, y: 10, width: 96, height: 24))
            b.title = label
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.target = self
            b.action = action
            ve.addSubview(b)
            return b
        }
        openButton = button("Open", 16, #selector(openClicked))
        feedbackButtons = [button("Nice", 122, #selector(niceClicked)), button("Not right", 228, #selector(notRightClicked))]
        [title, detail].forEach(ve.addSubview)
        p.contentView = ve
        return p
    }

    func show(_ content: MasteryToastContent, done: @escaping @MainActor (MasteryAction) -> Void) {
        let p = panel ?? makePanel()
        panel = p
        title.stringValue = content.title
        detail.stringValue = content.detail
        feedbackButtons.forEach { $0.isHidden = !content.asksFeedback }
        // Nowhere to open (no web URL published): no Open, so no click is ever lost as ignored.
        openButton?.isHidden = content.link == nil
        self.done = done
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        // Below the coach toast's spot, so the two never cover each other.
        p.setFrameOrigin(NSPoint(x: max(20, vf.maxX - size.width - 24), y: max(20, vf.maxY - 2 * size.height - 36)))
        isShowing = true
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; p.animator().alphaValue = 1 }
        timer?.invalidate()
        let t = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(.ignored) }
        }
        // Common modes: it also runs while the tray menu is open.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func dismiss() { finish(.ignored) }

    @objc func openClicked() { finish(.opened) }
    @objc func niceClicked() { finish(.nice) }
    @objc func notRightClicked() { finish(.notRight) }

    /// Once per toast: the first click or the timeout.
    func finish(_ action: MasteryAction) {
        guard isShowing, let p = panel else { return }
        isShowing = false
        timer?.invalidate()
        timer = nil
        let report = done
        done = nil
        report?(action)
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in MainActor.assumeIsolated { if self?.isShowing == false { self?.panel?.orderOut(nil) } } })
    }
}

// MARK: - Tray

/// A recent-gain row: the concept, the gain (never a drop), and how long ago.
enum MasteryTrayRow {
    static func title(_ n: MasteryNotification, now: Date) -> String {
        let change = n.previousPercent.map { "▲ \($0)% → \(n.percent)%" } ?? "first confident reading \(n.percent)%"
        return "🎓 \(n.conceptName): \(change) · \(ago(now.timeIntervalSince(n.completedAt)))"
    }

    static func ago(_ s: TimeInterval) -> String {
        switch max(0, s) {
        case ..<90: return "just now"
        case ..<5400: return "\(Int((s / 60).rounded())) min ago"
        case ..<(36 * 3600): return "\(Int((s / 3600).rounded())) h ago"
        default: return "\(Int((s / 86400).rounded())) d ago"
        }
    }
}

extension TrayAppManager {
    /// "🎓 Mastery", after the learner-server lines: the learning baseline, or why it is missing.
    func addMasterySection() {
        let feed = mastery
        header("🎓 Mastery")
        if feed.reachable == .offline { add("   ⏳ waiting for learner-server") }
        add("   " + (feed.baseline?.learningLine ?? "📚 Learning baseline: not available yet"))
        let waiting = feed.pending.count
        if waiting > 0 { add("   ⏸ \(waiting) reading\(waiting == 1 ? "" : "s") to show\(feed.holdDuringCalls && talkMonitor.activeCallApp != nil ? " after the call" : "")") }
        // Recent gains: each opens the concept on the Map (and tells the server it was opened).
        let web = masteryWeb()
        for gain in feed.recent {
            let item = add("   \(MasteryTrayRow.title(gain, now: Date()))\(web == nil ? "" : "...")",
                           web == nil ? nil : #selector(openRecentGain(_:)))
            item.representedObject = [gain.runId, gain.conceptId]
        }
        statusMenu.addItem(NSMenuItem.separator())
    }

    @objc func openRecentGain(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [String], ids.count == 2 else { return }
        _ = mastery.openRecent(ids[0], conceptId: ids[1], web: masteryWeb(), open: openURL)
    }

    /// The feed job is made here (the Scheduler ticks it); the presenter looks every 2 s.
    func startMastery() {
        let presenter = MasteryPresenter(feed: .shared, toast: MasteryToastController.shared,
                                         inCall: { [weak self] in self?.talkMonitor.activeCallApp != nil },
                                         openURL: { [weak self] in self?.openURL($0) ?? false })
        Scheduler.every(2, "mastery") { presenter.tick() }
    }

    @objc func toggleMasteryCallHold() {
        mastery.holdDuringCalls.toggle()
        rebuildMenu()
    }
}
