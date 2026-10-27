import AppKit
import Foundation
import SQLite3

// MARK: - Local SQLite Habit Trial Logger
// @unchecked: every mutable field (db, closed, unwritten) is only touched on `queue`.
final class HabitEventLogger: @unchecked Sendable {
    static let shared = HabitEventLogger()

    /// Written into habit_events.metadata.source so live rows are distinguishable.
    static let liveSource = "solo_mic_live_v2"

    private let dbPath: String
    private let log = Log("Trials")
    private var db: OpaquePointer?
    private var closed = false
    /// Turns whose insert failed (disk full, locked, DB would not open): retried on the
    /// next turn instead of dropped. Lost only if the app quits before the DB recovers.
    private var unwritten: [Turn] = []
    private let queue = DispatchQueue(label: "com.benpollack.habit-logger", qos: .utility)

    private struct Turn {
        let eventId: String, sessionId: String, callApp: String?, callCategory: String, timestamp: String
        let habitType: String, treatmentArm: String, turnDurationSec: Double, wordsSpoken: Int
        let warningFiredAt: Double?, shockFiredAt: Double?, latencyToYieldSec: Double?
        let breached30s: Bool, breached60s: Bool, wasRewarded: Bool, metaJson: String
    }

    /// For the tray: trials are not being saved.
    var problem: String? {
        queue.sync {
            if closed { return nil }
            if db == nil { return "the trial database will not open" }
            return unwritten.isEmpty ? nil : "\(unwritten.count) trial(s) not yet saved"
        }
    }

    /// LEARNER_OUTBOX_DB points --drain-outbox at a scratch database; tests pass `path`.
    init(path: String? = nil) {
        let dir = Paths.data
        self.dbPath = path ?? ProcessInfo.processInfo.environment["LEARNER_OUTBOX_DB"] ?? dir + "/behavior_experiments.sqlite"
        let parent = (dbPath as NSString).deletingLastPathComponent
        do { try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true) }
        catch { log.error("cannot create \(parent): \(error.localizedDescription)") }
        openAndInitDb()
    }

    private func openAndInitDb() {
        queue.async { _ = self.openLocked() }
    }

    /// On `queue`. Retried on each turn while it fails.
    private func openLocked() -> Bool {
        if db != nil { return true }
        guard !closed else { return false }
        var handle: OpaquePointer?
        if sqlite3_open(dbPath, &handle) != SQLITE_OK {
            sqlite3_close(handle)
            log.error("cannot open the trial database at \(dbPath); will retry on the next turn")
            return false
        }
        db = handle
        do {
            sqlite3_busy_timeout(self.db, 5000)
            let createSql = """
            CREATE TABLE IF NOT EXISTS habit_events (
                event_id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                call_app TEXT,
                call_category TEXT DEFAULT 'work',
                timestamp TEXT NOT NULL,
                habit_type TEXT NOT NULL,
                treatment_arm TEXT NOT NULL,
                turn_duration_sec REAL NOT NULL,
                words_spoken INTEGER DEFAULT 0,
                warning_fired_at REAL,
                shock_fired_at REAL,
                latency_to_yield_sec REAL,
                breached_30s INTEGER DEFAULT 0,
                breached_60s INTEGER DEFAULT 0,
                was_rewarded INTEGER DEFAULT 0,
                metadata TEXT,
                synced_to_server INTEGER DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_habits_unsynced ON habit_events(synced_to_server);
            """
            if sqlite3_exec(self.db, createSql, nil, nil, nil) != SQLITE_OK {
                log.error("cannot create the habit_events table: \(String(cString: sqlite3_errmsg(db))); will retry on the next turn")
                sqlite3_close(db)
                db = nil
                return false
            }
        }
        return true
    }

    func logTurn(
        occurredAt: Date? = nil,
        habitType: String = "monologue_streak",
        sessionId: String,
        callApp: String?,
        callCategory: String = "work",
        treatmentArm: String,
        turnDurationSec: Double,
        wordsSpoken: Int,
        warningFiredAt: Double?,
        shockFiredAt: Double?,
        latencyToYieldSec: Double?,
        breached30s: Bool,
        breached60s: Bool,
        wasRewarded: Bool,
        metadata: [String: Any] = [:]
    ) {
        // Serialised here: the dictionary is not Sendable, its JSON is.
        let metaJson = HabitEventLogger.metadataJSON(metadata, log: log)
        queue.async {
            guard !self.closed else {
                self.log.warn("dropped a turn logged after shutdown (database closed)")
                return
            }
            // When the app drains a backlog of transcriptions, many turns finish within the
            // same wall-clock second. Stamp the row with when the turn was actually spoken
            // (audio clock where available), not when it happened to be written.
            let turn = Turn(
                eventId: UUID().uuidString.lowercased(), sessionId: sessionId, callApp: callApp, callCategory: callCategory,
                timestamp: ISO8601DateFormatter().string(from: occurredAt ?? Date()), habitType: habitType,
                treatmentArm: treatmentArm, turnDurationSec: turnDurationSec, wordsSpoken: wordsSpoken,
                warningFiredAt: warningFiredAt, shockFiredAt: shockFiredAt, latencyToYieldSec: latencyToYieldSec,
                breached30s: breached30s, breached60s: breached60s, wasRewarded: wasRewarded,
                metaJson: metaJson)
            self.unwritten.append(turn)
            guard self.openLocked() else { return }
            // Oldest first; stop at the first failure and keep the rest for the next turn.
            while let next = self.unwritten.first, self.insert(next) { self.unwritten.removeFirst() }
        }
    }

    static func metadataJSON(_ metadata: [String: Any], log: Log) -> String {
        guard JSONSerialization.isValidJSONObject(metadata),
              let data = try? JSONSerialization.data(withJSONObject: metadata),
              let text = String(data: data, encoding: .utf8) else {
            log.warn("turn metadata is not JSON (\(metadata.keys.sorted().joined(separator: ", "))); saved as {}")
            return "{}"
        }
        return text
    }

    /// On `queue`, with the DB open.
    private func insert(_ t: Turn) -> Bool {
        let sql = """
        INSERT OR IGNORE INTO habit_events (
            event_id, session_id, call_app, call_category, timestamp,
            habit_type, treatment_arm, turn_duration_sec, words_spoken,
            warning_fired_at, shock_fired_at, latency_to_yield_sec,
            breached_30s, breached_60s, was_rewarded, metadata, synced_to_server
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            log.error("insert: prepare failed: \(String(cString: sqlite3_errmsg(db))); will retry")
            return false
        }
        defer { sqlite3_finalize(stmt) }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        func text(_ i: Int32, _ v: String) { sqlite3_bind_text(stmt, i, (v as NSString).utf8String, -1, SQLITE_TRANSIENT) }
        func real(_ i: Int32, _ v: Double?) { if let v = v { sqlite3_bind_double(stmt, i, v) } else { sqlite3_bind_null(stmt, i) } }
        text(1, t.eventId)
        text(2, t.sessionId)
        text(3, t.callApp ?? "Solo Mic")
        text(4, t.callCategory)
        text(5, t.timestamp)
        text(6, t.habitType)
        text(7, t.treatmentArm)
        sqlite3_bind_double(stmt, 8, t.turnDurationSec)
        sqlite3_bind_int(stmt, 9, Int32(t.wordsSpoken))
        real(10, t.warningFiredAt)
        real(11, t.shockFiredAt)
        real(12, t.latencyToYieldSec)
        sqlite3_bind_int(stmt, 13, t.breached30s ? 1 : 0)
        sqlite3_bind_int(stmt, 14, t.breached60s ? 1 : 0)
        sqlite3_bind_int(stmt, 15, t.wasRewarded ? 1 : 0)
        text(16, t.metaJson)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            log.error("insert failed: \(String(cString: sqlite3_errmsg(db))); will retry")
            return false
        }
        log.info("logged \(t.habitType): arm=\(t.treatmentArm), dur=\(String(format: "%.1f", t.turnDurationSec))s, yieldLatency=\(t.latencyToYieldSec.map { String(format: "%.1f", $0) + "s" } ?? "none"), 30s=\(t.breached30s)")
        return true
    }

    /// Block until every queued insert has been written. Used by clean shutdown so the
    /// in-flight turn is on disk before the sync runs and the DB is closed.
    func waitUntilIdle() {
        queue.sync {}
    }

    /// Close the SQLite handle. Further logTurn calls become no-ops rather than crashes.
    func close() {
        queue.sync {
            if !self.unwritten.isEmpty, self.openLocked() {
                while let next = self.unwritten.first, self.insert(next) { self.unwritten.removeFirst() }
            }
            if !self.unwritten.isEmpty { self.log.error("\(self.unwritten.count) trial(s) could not be saved before quit") }
            self.closed = true
            if let db = self.db {
                sqlite3_close(db)
                self.db = nil
                self.log.info("trial database closed")
            }
        }
    }

    /// Unsent rows; 0 (logged) when the database cannot be read. `unsyncedCount()` tells the two apart.
    func getUnsyncedCount() -> Int { unsyncedCount() ?? 0 }

    func unsyncedCount() -> Int? {
        queue.sync { count("SELECT COUNT(*) FROM habit_events WHERE synced_to_server = 0;") }
    }

    /// Rows the server refused (synced_to_server = 2).
    func parkedCount() -> Int {
        queue.sync { count("SELECT COUNT(*) FROM habit_events WHERE synced_to_server = 2;") } ?? 0
    }

    /// On `queue`.
    private func count(_ sql: String) -> Int? {
        guard openLocked(), let db = db else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else {
            log.noisy("cannot count rows: \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Up to `limit` unsent rows as `recordHabitEvents` events (contract/desktop.ts,
    /// DesktopHabitEvent), oldest first. synced_to_server: 0 unsent, 1 sent, 2 parked
    /// (the server rejected the row itself with 422; kept for inspection, never resent).
    /// nil when the database cannot be read (logged): not the same as an empty outbox.
    func unsentEvents(limit: Int) -> [[String: Any]]? {
        var events: [[String: Any]]? = []
        queue.sync {
            guard self.openLocked(), let db = self.db else {
                self.log.noisy("cannot read the outbox: the trial database is not open")
                events = nil
                return
            }
            let sql = """
            SELECT event_id, session_id, call_app, call_category, timestamp, habit_type, treatment_arm,
                   turn_duration_sec, words_spoken, warning_fired_at, shock_fired_at, latency_to_yield_sec,
                   breached_30s, breached_60s, was_rewarded, metadata
            FROM habit_events WHERE synced_to_server = 0 ORDER BY timestamp ASC LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                self.log.noisy("cannot read the outbox: \(String(cString: sqlite3_errmsg(db)))")
                events = nil
                return
            }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            func text(_ i: Int32) -> String? {
                sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, i))
            }
            // Contract `Seconds` is a non-negative number; anything else would get the whole batch a 422.
            func seconds(_ i: Int32) -> Any {
                guard sqlite3_column_type(stmt, i) != SQLITE_NULL else { return NSNull() }
                let v = sqlite3_column_double(stmt, i)
                return v.isFinite && v >= 0 ? v : NSNull()
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                var meta: [String: Any] = [:]
                if let raw = text(15) {
                    if let parsed = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] { meta = parsed }
                    else { self.log.noisy("event \(text(0) ?? "?"): metadata is not a JSON object; sent as {}") }
                }
                events?.append([
                    "eventId": text(0) ?? "",
                    "sessionId": text(1) ?? "",
                    "callApp": text(2) as Any? ?? NSNull(),
                    "callCategory": text(3) as Any? ?? NSNull(),
                    "timestamp": HabitEventLogger.isoWithOffset(text(4) ?? ""),
                    "habitType": text(5) ?? "",
                    "treatmentArm": text(6) as Any? ?? NSNull(),
                    "turnDurationSec": seconds(7),
                    "wordsSpoken": sqlite3_column_type(stmt, 8) == SQLITE_NULL ? NSNull() : Int(sqlite3_column_int(stmt, 8)) as Any,
                    "warningFiredAtSec": seconds(9),
                    "shockFiredAtSec": seconds(10),
                    "latencyToYieldSec": seconds(11),
                    "breached30s": sqlite3_column_int(stmt, 12) != 0,
                    "breached60s": sqlite3_column_int(stmt, 13) != 0,
                    "wasRewarded": sqlite3_column_int(stmt, 14) != 0,
                    "metadata": meta,
                ])
            }
            sqlite3_finalize(stmt)
        }
        return events
    }

    /// Legacy rows hold "YYYY-MM-DD HH:MM:SS" (UTC); the contract wants ISO-8601 with an offset.
    static func isoWithOffset(_ raw: String) -> String {
        if ISO8601DateFormatter().date(from: raw) != nil { return raw }
        let legacy = DateFormatter()
        legacy.locale = Locale(identifier: "en_US_POSIX")
        legacy.timeZone = TimeZone(identifier: "UTC")
        legacy.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return legacy.date(from: raw).map { ISO8601DateFormatter().string(from: $0) } ?? raw
    }

    /// False when the rows could not be updated; the caller must not treat them as sent.
    @discardableResult
    func mark(_ eventIds: [String], as state: Int) -> Bool {
        guard !eventIds.isEmpty else { return true }
        return queue.sync {
            guard self.openLocked(), let db = self.db else {
                self.log.error("cannot mark \(eventIds.count) row(s): the trial database is not open")
                return false
            }
            let placeholders = Array(repeating: "?", count: eventIds.count).joined(separator: ",")
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE habit_events SET synced_to_server = \(state) WHERE event_id IN (\(placeholders));", -1, &stmt, nil) == SQLITE_OK else {
                self.log.error("cannot mark \(eventIds.count) row(s): \(String(cString: sqlite3_errmsg(db)))")
                return false
            }
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (i, id) in eventIds.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
            }
            let done = sqlite3_step(stmt) == SQLITE_DONE
            if !done { self.log.error("cannot mark \(eventIds.count) row(s): \(String(cString: sqlite3_errmsg(db)))") }
            sqlite3_finalize(stmt)
            return done
        }
    }

    func getTotalTrialCount() -> Int {
        queue.sync { count("SELECT COUNT(*) FROM habit_events WHERE habit_type = 'monologue_streak';") } ?? 0
    }
}

// MARK: - Trial outbox

/// Drains habit_events with `recordHabitEvents` (the "Outbox" job, every 8 s) and sends a
/// heartbeat (the "Heartbeat" job, every 5 min). The coaching loop never waits on either.
/// Per reply (same classes as the archive):
///   2xx            rows marked sent (1)
///   400 / 422      batch halved until the refused row is alone, then parked (2)
///   413            batch halved; a lone row that is still too large is parked
///   401 / 403      blocked: "device key refused" until Send Queued Trials Now
///   no key         blocked: "no device key"
///   429/5xx/none   failed: the job backs off 2 s -> 5 min
///   other (404...) failed: retried in 30 min (a server or URL problem, not the rows')
final class OutboxSender: Sendable {
    static let maxBatch = 500

    struct Config: Sendable {
        var jobName = "Outbox"
        var heartbeatJobName = "Heartbeat"
        var period: TimeInterval = 8
        var heartbeatPeriod: TimeInterval = 300
        var heartbeatFirstRun: TimeInterval = 30
        var callTimeout: TimeInterval = 20
        var unexpectedRetry: TimeInterval = 30 * 60
        var problemGrace: TimeInterval = 10 * 60
    }

    static let shared = OutboxSender(logger: .shared, rpc: .shared)

    let logger: HabitEventLogger
    let rpc: LearnerRPC
    let config: Config
    // nonisolated(unsafe): assigned once at the end of init (their bodies need `self`); only read after.
    nonisolated(unsafe) private(set) var job: Job!
    nonisolated(unsafe) private(set) var heartbeatJob: Job!
    private let log = Log("Outbox")

    /// One sender at a time: the job, or the drain at quit (which waits with a deadline).
    private let sendLock = NSLock()
    private struct State {
        var batchLimit = OutboxSender.maxBatch
        var status = "not tried yet"
        var sentAt: Date?
        var heartbeat: (@Sendable () -> [String: Any])?
        var stopOutcome: Job.Outcome = .idle
    }
    private let state = Locked(State())

    init(logger: HabitEventLogger, rpc: LearnerRPC, config: Config = Config()) {
        self.logger = logger
        self.rpc = rpc
        self.config = config
        job = Job(config.jobName, period: config.period, backoff: Backoff(base: 2, max: 300),
                  problemGrace: config.problemGrace, quiet: true) { [weak self] _ in self?.runOnce() ?? .idle }
        heartbeatJob = Job(config.heartbeatJobName, period: config.heartbeatPeriod, firstRun: config.heartbeatFirstRun,
                           backoff: Backoff(base: 60, max: 1800), problemGrace: config.problemGrace,
                           quiet: true) { [weak self] _ in self?.sendHeartbeat() ?? .idle }
    }

    // MARK: Status for the menu

    /// The last thing the outbox did, e.g. "sent 3 (3 accepted, 0 duplicates)".
    var lastStatus: String { state.value.status }
    var lastSentAt: Date? { state.value.sentAt }
    /// No usable device key: missing from the Keychain, or refused by the server.
    var keyProblem: Bool { job.snapshot.blocked || heartbeatJob.snapshot.blocked }
    /// Rows waiting to be sent.
    var depth: Int { logger.getUnsyncedCount() }

    /// The heartbeat's recordAppHeartbeat input (contract RecordAppHeartbeatInput), built
    /// only when a heartbeat is due. The tray provides it.
    func setHeartbeatInput(_ input: @escaping @Sendable () -> [String: Any]) { state.withLock { $0.heartbeat = input } }

    // MARK: Triggers

    /// "Send Queued Trials Now": re-reads the key and clears a block.
    func sendNow() {
        rpc.forgetKey()
        job.kick("send now")
        if heartbeatJob.snapshot.blocked { heartbeatJob.kick("send now") }
    }

    // MARK: Sending

    enum Step: Equatable {
        case empty
        case sent(Int)
        case parked(String)
        case halved
        case stop(String)
    }

    /// The job body: send until the outbox is empty or a send fails.
    func runOnce() -> Job.Outcome {
        sendLock.lock()
        defer { sendLock.unlock() }
        var sent = 0
        var parked = 0
        while true {
            switch sendBatch(timeout: config.callTimeout) {
            case .empty:
                guard sent + parked > 0 else { return idleOrRecovered(job, "outbox empty") }
                return .ok("sent \(sent)" + (parked > 0 ? ", parked \(parked)" : ""))
            case let .sent(n): sent += n
            case .parked: parked += 1
            case .halved: continue
            case .stop: return state.value.stopOutcome
            }
        }
    }

    /// Send everything now, blocking, until the outbox is empty, sending fails or
    /// `deadline` passes; no single call runs past the deadline. Used at quit and by
    /// --drain-outbox. Returns the rows still unsent.
    @discardableResult
    func drain(until deadline: Date) -> Int {
        guard sendLock.lock(before: deadline) else {
            log.warn("drain: a send was still running at the deadline")
            return logger.getUnsyncedCount()
        }
        defer { sendLock.unlock() }
        loop: while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0.05 else {
                log.warn("drain: out of time")
                break
            }
            switch sendBatch(timeout: min(config.callTimeout, left)) {
            case .empty: break loop
            case .sent, .parked, .halved: continue
            case let .stop(why):
                log.warn("drain stopped: \(why)")
                break loop
            }
        }
        return logger.getUnsyncedCount()
    }

    /// One recordHabitEvents call for the oldest unsent rows. Caller holds `sendLock`.
    func sendBatch(timeout: TimeInterval) -> Step {
        let limit = state.value.batchLimit
        guard let events = logger.unsentEvents(limit: limit) else {
            return stop(.failed("cannot read the trial database"), "cannot read the trial database")
        }
        guard !events.isEmpty else {
            state.withLock { $0.batchLimit = OutboxSender.maxBatch }
            return .empty
        }
        let ids = events.compactMap { $0["eventId"] as? String }
        let r = rpc.call("recordHabitEvents", ["clientId": rpc.clientId, "events": events], timeout: timeout)
        switch r.kind {
        case .ok:
            // The server dedupes by eventId, so a resend after a failed mark is harmless,
            // but it must back off rather than resend in a tight loop.
            guard logger.mark(ids, as: 1) else {
                return stop(.failed("could not update the local outbox database"), "could not update the local outbox database")
            }
            let body = r.body as? [String: Any]
            let note = "sent \(ids.count) (\(body?["accepted"] ?? "?") accepted, \(body?["duplicates"] ?? "?") duplicates)"
            state.withLock { $0.sentAt = Date(); $0.status = note }
            log.noisy(note)
            return .sent(ids.count)
        case .rejected, .tooLarge:
            if ids.count > 1 {
                state.withLock { $0.batchLimit = max(1, ids.count / 2) }
                log.info("\(r.describe) for a batch of \(ids.count); halving it to find the refused row")
                return .halved
            }
            guard logger.mark(ids, as: 2) else {
                return stop(.failed("could not update the local outbox database"), "could not update the local outbox database")
            }
            let why = r.kind == .tooLarge ? "too large (413)" : "refused (\(r.describe)\(r.message.map { ": \($0)" } ?? ""))"
            let note = "parked event \(ids.first ?? "?"): \(why)"
            state.withLock { $0.batchLimit = OutboxSender.maxBatch; $0.status = note }
            log.warn("\(note); kept locally, not resent")
            return .parked(ids.first ?? "?")
        case .auth:
            return stop(.blocked("device key refused (\(r.describe)): fix Keychain item learner-server / ben-mbp, then Send Queued Trials Now"),
                        "device key refused (\(r.describe))")
        case .noKey:
            return stop(.blocked("no device key: add Keychain item learner-server / ben-mbp, then Send Queued Trials Now"), "no device key")
        case .transient:
            let note = r.status == 0 ? "server unreachable: \(r.error ?? "no answer")" : "server error \(r.status)"
            return stop(.failed(note), note)
        case .unexpected:
            let note = "unexpected \(r.describe) from \(rpc.baseURL)"
            return stop(.failed(note, retryAfter: config.unexpectedRetry), note)
        }
    }

    private func stop(_ outcome: Job.Outcome, _ note: String) -> Step {
        state.withLock {
            $0.status = note
            $0.stopOutcome = outcome
        }
        return .stop(note)
    }

    /// The Heartbeat job body.
    func sendHeartbeat() -> Job.Outcome {
        guard let build = state.value.heartbeat else { return .idle }
        let r = rpc.call("recordAppHeartbeat", build(), timeout: config.callTimeout)
        switch r.kind {
        case .ok: return .ok("sent")
        case .auth: return .blocked("device key refused (\(r.describe))")
        case .noKey: return .blocked("no device key")
        case .transient: return .failed(r.status == 0 ? "server unreachable: \(r.error ?? "no answer")" : "server error \(r.status)")
        case .rejected, .tooLarge, .unexpected:
            // A refused heartbeat is the app's bug or the server's; resending it soon won't help.
            return .failed("heartbeat refused (\(r.describe)\(r.message.map { ": \($0)" } ?? ""))", retryAfter: config.unexpectedRetry)
        }
    }
}

