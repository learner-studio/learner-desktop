import AppKit
import Foundation
import ServiceManagement
import SQLite3
import CoreBluetooth
import CommonCrypto

// MARK: - Local SQLite Habit Trial Logger
class HabitEventLogger {
    static let shared = HabitEventLogger()

    /// Written into habit_events.metadata.source so live rows are distinguishable.
    static let liveSource = "solo_mic_live_v2"

    private let dbPath: String
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

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = home + "/.ai-aggregator"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // LEARNER_OUTBOX_DB points tests (--drain-outbox) at a scratch database.
        self.dbPath = ProcessInfo.processInfo.environment["LEARNER_OUTBOX_DB"] ?? dir + "/behavior_experiments.sqlite"
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
            print("[HabitLogger] ❌ Failed to open SQLite DB at \(dbPath); will retry on the next turn")
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
                print("[HabitLogger] ❌ Failed to initialize schema; will retry on the next turn")
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
        queue.async {
            guard !self.closed else {
                print("[HabitLogger] Dropped a turn logged after shutdown (DB closed).")
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
                metaJson: (try? JSONSerialization.data(withJSONObject: metadata)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
            self.unwritten.append(turn)
            guard self.openLocked() else { return }
            // Oldest first; stop at the first failure and keep the rest for the next turn.
            while let next = self.unwritten.first, self.insert(next) { self.unwritten.removeFirst() }
            fflush(stdout)
        }
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
            print("[HabitLogger] ❌ sqlite3_prepare_v2 failed: \(String(cString: sqlite3_errmsg(db))); will retry")
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
            print("[HabitLogger] ❌ sqlite3_step failed: \(String(cString: sqlite3_errmsg(db))); will retry")
            return false
        }
        print("[HabitLogger] ✅ Logged \(t.habitType): arm=\(t.treatmentArm), dur=\(String(format: "%.1f", t.turnDurationSec))s, yieldLatency=\(t.latencyToYieldSec.map { String(format: "%.1f", $0) + "s" } ?? "none"), 30s=\(t.breached30s)")
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
            if !self.unwritten.isEmpty { print("[HabitLogger] ❌ \(self.unwritten.count) trial(s) could not be saved before quit") }
            self.closed = true
            if let db = self.db {
                sqlite3_close(db)
                self.db = nil
                print("[HabitLogger] SQLite closed cleanly.")
                fflush(stdout)
            }
        }
    }

    func getUnsyncedCount() -> Int {
        var count = 0
        queue.sync {
            guard let db = self.db else { return }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM habit_events WHERE synced_to_server = 0;", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(stmt, 0))
                }
                sqlite3_finalize(stmt)
            }
        }
        return count
    }

    /// Up to `limit` unsent rows as `recordHabitEvents` events (contract/desktop.ts,
    /// DesktopHabitEvent), oldest first. synced_to_server: 0 unsent, 1 sent, 2 parked
    /// (the server rejected the row itself with 422; kept for inspection, never resent).
    func unsentEvents(limit: Int) -> [[String: Any]] {
        var events: [[String: Any]] = []
        queue.sync {
            guard let db = self.db else { return }
            let sql = """
            SELECT event_id, session_id, call_app, call_category, timestamp, habit_type, treatment_arm,
                   turn_duration_sec, words_spoken, warning_fired_at, shock_fired_at, latency_to_yield_sec,
                   breached_30s, breached_60s, was_rewarded, metadata
            FROM habit_events WHERE synced_to_server = 0 ORDER BY timestamp ASC LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
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
                let meta = text(15).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
                events.append([
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
            guard let db = self.db else { return false }
            let placeholders = Array(repeating: "?", count: eventIds.count).joined(separator: ",")
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE habit_events SET synced_to_server = \(state) WHERE event_id IN (\(placeholders));", -1, &stmt, nil) == SQLITE_OK else { return false }
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (i, id) in eventIds.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
            }
            let done = sqlite3_step(stmt) == SQLITE_DONE
            sqlite3_finalize(stmt)
            return done
        }
    }

    func getTotalTrialCount() -> Int {
        var count = 0
        queue.sync {
            guard let db = self.db else { return }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM habit_events WHERE habit_type = 'monologue_streak';", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(stmt, 0))
                }
                sqlite3_finalize(stmt)
            }
        }
        return count
    }
}

// MARK: - learner-server API

/// HTTPS RPC to learner-server (spec: learner-server docs/learner-desktop-api.md; wire
/// shapes pinned in contract/). The app no longer writes into Postgres or Hindsight
/// over the SSH tunnel: rows wait in the local SQLite outbox and go out from here.
enum LearnerAPI {
    static let baseURL = ProcessInfo.processInfo.environment["LEARNER_API_URL"] ?? "https://dev.biztoolz.app/learner-api"
    static let clientId = "ben-mbp"

    /// The device key: LEARNER_API_KEY (tests), else the Keychain item the operator
    /// stored with `security add-generic-password -s learner-server -a ben-mbp`. Read
    /// through /usr/bin/security, which that item trusts, so a rebuilt app is not prompted.
    static func deviceKey() -> String? {
        if let k = ProcessInfo.processInfo.environment["LEARNER_API_KEY"], !k.isEmpty { return k }
        // Bounded: a locked keychain's prompt would otherwise stall the outbox queue.
        let r = runBounded("/usr/bin/security", ["find-generic-password", "-s", "learner-server", "-a", clientId, "-w"], timeout: 10)
        let key = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && !key.isEmpty ? key : nil
    }

    /// POST {"data": input} to /rpc/<name>. Status 0 means no response at all.
    static func call(_ name: String, _ input: [String: Any], key: String, timeout: TimeInterval = 20) -> (status: Int, body: Any?) {
        guard let url = URL(string: "\(baseURL)/rpc/\(name)"),
              let body = try? JSONSerialization.data(withJSONObject: ["data": input]) else { return (0, nil) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.httpBody = body
        var result: (Int, Any?) = (0, nil)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, response, _ in
            result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data.flatMap { try? JSONSerialization.jsonObject(with: $0) })
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 5)
        return result
    }
}

/// Drains the habit_events outbox with `recordHabitEvents` and sends a heartbeat every
/// 5 minutes. The coaching loop never waits on it. Error handling per the spec: 422
/// rejects a batch, so it is halved until the bad row is alone and parked; 401/403 is a
/// key problem (🔑) and pauses sending; 413 halves the batch; 429/5xx/no answer backs
/// off from 2 s to 5 min with jitter. Any non-2xx is a failure.
final class OutboxSender {
    static let shared = OutboxSender()
    static let maxBatch = 500

    private let work = DispatchQueue(label: "com.benpollack.learner-outbox", qos: .utility)
    private var cachedKey: String?
    private var batchLimit = maxBatch
    private var backoff: TimeInterval = 2
    private var nextAttempt = Date.distantPast
    private var lastHeartbeat = Date.distantPast
    private var running = false

    /// No usable device key: missing from the Keychain, or refused by the server.
    private(set) var keyProblem = false
    private(set) var lastSentAt: Date?
    private(set) var lastStatus = "not tried yet"

    /// Called on the 8 s status poll; drains in the background.
    func tick(heartbeat: @escaping () -> [String: Any]) {
        work.async {
            guard !self.running else { return }
            self.running = true
            defer { self.running = false }
            while self.sendOneBatch() == .more {}
            self.sendHeartbeatIfDue(heartbeat())
        }
    }

    /// Send everything now, blocking, until the outbox is empty, sending fails or
    /// `deadline` passes. Used at quit and by --drain-outbox.
    @discardableResult
    func drain(until deadline: Date) -> Int {
        work.sync {
            nextAttempt = .distantPast
            while Date() < deadline, sendOneBatch() == .more {}
        }
        return HabitEventLogger.shared.getUnsyncedCount()
    }

    func sendNow() {
        work.async { self.nextAttempt = .distantPast; self.keyProblem = false; self.cachedKey = nil }
    }

    private enum Step { case more, idle, failed }

    private func key() -> String? {
        if cachedKey == nil { cachedKey = LearnerAPI.deviceKey() }
        keyProblem = cachedKey == nil
        return cachedKey
    }

    private func sendOneBatch() -> Step {
        guard Date() >= nextAttempt else { return .idle }
        let logger = HabitEventLogger.shared
        let events = logger.unsentEvents(limit: batchLimit)
        guard !events.isEmpty else { batchLimit = OutboxSender.maxBatch; return .idle }
        guard let key = key() else { lastStatus = "no device key"; nextAttempt = Date().addingTimeInterval(300); return .failed }
        let ids = events.compactMap { $0["eventId"] as? String }
        let (status, body) = LearnerAPI.call("recordHabitEvents", ["clientId": LearnerAPI.clientId, "events": events], key: key)
        switch status {
        case 200..<300:
            // The server dedupes by eventId, so a resend after a failed mark is harmless,
            // but it must back off rather than resend in a tight loop.
            guard logger.mark(ids, as: 1) else { return markFailed() }
            lastSentAt = Date()
            backoff = 2
            lastStatus = "sent \(ids.count) (\((body as? [String: Any])?["accepted"] ?? "?") accepted, \((body as? [String: Any])?["duplicates"] ?? "?") duplicates)"
            log(lastStatus)
            return .more
        case 422:
            if ids.count > 1 {
                batchLimit = max(1, ids.count / 2)
                return .more
            }
            guard logger.mark(ids, as: 2) else { return markFailed() }
            lastStatus = "parked event \(ids[0]): \((body as? [String: Any])?["message"] ?? "rejected")"
            log(lastStatus)
            return .more
        case 401, 403:
            keyProblem = true
            cachedKey = nil
            nextAttempt = Date().addingTimeInterval(300)
            lastStatus = "device key refused (\(status))"
        case 413:
            if ids.count > 1 {
                batchLimit = max(1, ids.count / 2)
                return .more
            }
            // One event too large on its own will never fit: park it like a 422.
            guard logger.mark(ids, as: 2) else { return markFailed() }
            lastStatus = "parked event \(ids[0]): too large (413)"
            log(lastStatus)
            return .more
        default:
            nextAttempt = Date().addingTimeInterval(backoff * Double.random(in: 0.5...1.0))
            backoff = min(backoff * 2, 300)
            lastStatus = status == 0 ? "server unreachable" : "server error \(status)"
        }
        log(lastStatus)
        return .failed
    }

    private func markFailed() -> Step {
        nextAttempt = Date().addingTimeInterval(backoff)
        backoff = min(backoff * 2, 300)
        lastStatus = "could not update the local outbox database"
        log(lastStatus)
        return .failed
    }

    private func sendHeartbeatIfDue(_ input: [String: Any]) {
        guard Date().timeIntervalSince(lastHeartbeat) >= 300, let key = key() else { return }
        lastHeartbeat = Date()
        let (status, _) = LearnerAPI.call("recordAppHeartbeat", input, key: key)
        if status == 401 || status == 403 { keyProblem = true; cachedKey = nil }
        if !(200..<300).contains(status) { log("heartbeat failed (\(status))") }
    }

    private func log(_ message: String) {
        print("[Outbox] \(message)")
        fflush(stdout)
    }
}
