import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// DESTRUCTIVE: these stop the owner's live recording stack and the installed app, then
// bring them back. Nothing is recorded while they run; never run them during a call.
// They need LEARNER_HEAVY=1 AND LEARNER_HEAVY_DESTRUCTIVE=1, set deliberately:
//
//   LEARNER_HEAVY_DESTRUCTIVE=1 scripts/test.sh heavy --filter Destructive
//
// Everything else about the capture scripts is covered hermetically in
// MediumTests/ScriptsCaptureTests; only what launchd really does lives here.

private enum Launchd {
    static let domain = "gui/\(getuid())"
    static let appLabel = "com.benpollack.learner-desktop"

    static func loaded(_ label: String) -> Bool {
        ChildProcess.run("/bin/launchctl", ["print", "\(domain)/\(label)"], timeout: 10).ok
    }

    static func lastExit(_ label: String) -> String? {
        ChildProcess.run("/bin/launchctl", ["print", "\(domain)/\(label)"], timeout: 10).output
            .components(separatedBy: "\n").first { $0.contains("last exit code") }?
            .components(separatedBy: "=").last?.trimmingCharacters(in: .whitespaces)
    }

    static func appPid() -> pid_t? {
        ChildProcess.run("/usr/bin/pgrep", ["-f", "MacOS/learner-desktop"], timeout: 5).output
            .split(separator: "\n").compactMap { pid_t($0) }.first
    }

    static func wait(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if condition() { return true }; usleep(1_000_000) }
        return condition()
    }

    static func restartApp() -> Bool {
        _ = ChildProcess.run("/bin/launchctl", ["kickstart", "\(domain)/\(appLabel)"], timeout: 20)
        guard wait(20, { appPid() != nil }) else { return false }
        sleep(5)   // past applicationDidFinishLaunching
        return appPid() != nil
    }
}

@Suite("Destructive: capture stack and app lifecycle", .serialized,
       .enabled(if: Live.destructive, "destructive: set LEARNER_HEAVY=1 LEARNER_HEAVY_DESTRUCTIVE=1"))
struct CaptureDestructiveTests {
    private let repo = toolsRepoRoot()

    @Test func stopThenStartReturnsTheStackToItsOriginalState() throws {
        try #require(Launchd.loaded(Launchd.appLabel), "capture stack is not running; nothing to stop")
        defer { _ = ChildProcess.run(repo + "/scripts/start-capture.sh", [], timeout: 300) }   // put it back regardless
        let stop = ChildProcess.run(repo + "/scripts/stop-capture.sh", ["--keep-screenpipe"], timeout: 600, stderr: true)
        #expect(stop.status == 0, "\(stop.output)")
        // KeepAlive respawns anything merely killed: prove it does not come back.
        sleep(10)
        #expect(!Launchd.loaded(Launchd.appLabel), "KeepAlive job survived stop-capture.sh")
        let start = ChildProcess.run(repo + "/scripts/start-capture.sh", ["--no-screenpipe"], timeout: 600, stderr: true)
        #expect(start.status == 0, "\(start.output)")
        #expect(Launchd.wait(90) { Launchd.loaded(Launchd.appLabel) }, "start-capture.sh did not bring the app back")
    }

    @Test func aCleanQuitSendsQueuedRowsExitsZeroAndStaysDown() throws {
        try #require(Launchd.appPid() != nil || Launchd.restartApp(), "the app is not running and could not be started")
        defer { if Launchd.appPid() == nil { _ = Launchd.restartApp() } }
        let db = NSHomeDirectory() + "/.ai-aggregator/behavior_experiments.sqlite"
        let logPath = NSHomeDirectory() + "/.ai-aggregator/logs/menubar.log"
        // Re-queue two already-sent rows; the server dedupes by event id, so resending is harmless.
        _ = ChildProcess.run("/usr/bin/sqlite3", [db, "UPDATE habit_events SET synced_to_server = 0 WHERE event_id IN (SELECT event_id FROM habit_events WHERE synced_to_server = 1 ORDER BY rowid DESC LIMIT 2);"], timeout: 10)
        func unsynced() -> Int {
            Int(ChildProcess.run("/usr/bin/sqlite3", [db, "SELECT COUNT(*) FROM habit_events WHERE synced_to_server = 0;"], timeout: 10)
                .output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        }
        #expect(unsynced() > 0)
        let offset = (try? FileManager.default.attributesOfItem(atPath: logPath)[.size] as? UInt64) ?? 0
        let pid = try #require(Launchd.appPid())
        kill(pid, SIGTERM)   // what bootout, kickstart -k and stop-capture.sh send
        #expect(Launchd.wait(60) { Launchd.appPid() == nil }, "the app did not exit on SIGTERM")
        let h = FileHandle(forReadingAtPath: logPath)
        try? h?.seek(toOffset: offset)
        let log = String(decoding: h?.readDataToEndOfFile() ?? Data(), as: UTF8.self)
        for line in ["[Shutdown] Finalising in-flight turn", "[Shutdown] Sending", "[HabitLogger] SQLite closed cleanly", "[Shutdown] Clean shutdown complete"] {
            #expect(log.contains(line), "missing from menubar.log: \(line)")
        }
        #expect(unsynced() == 0, "queued rows were not sent before exit")
        sleep(10)
        #expect(Launchd.appPid() == nil, "launchd resurrected the app after a clean quit")
        #expect(Launchd.lastExit(Launchd.appLabel) == "0")
        #expect(Launchd.restartApp())
    }

    @Test func aCrashIsStillResurrected() throws {
        try #require(Launchd.appPid() != nil || Launchd.restartApp(), "the app is not running and could not be started")
        let old = try #require(Launchd.appPid())
        kill(old, SIGKILL)
        #expect(Launchd.wait(30) { Launchd.appPid().map { $0 != old } ?? false }, "launchd did not restart the app after SIGKILL")
    }
}
