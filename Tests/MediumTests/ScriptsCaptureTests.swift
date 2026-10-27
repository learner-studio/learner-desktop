import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// scripts/stop-capture.sh and scripts/start-capture.sh, run for real but hermetically.
//
// SAFETY: these never touch the real capture stack. Every command that could change
// system state -- launchctl, pkill, pgrep, curl, osascript, open, nc, sqlite3, bun -- is a
// recording stub on a PATH searched first, and HOME is a throwaway directory (so
// $HOME/.bun/bin/bun and the habit database resolve inside the sandbox). Running the
// scripts for real is HeavyTests/CaptureLiveTests (LEARNER_HEAVY_DESTRUCTIVE=1).

private let repo = toolsRepoRoot()
private let stopScript = repo + "/scripts/stop-capture.sh"
private let startScript = repo + "/scripts/start-capture.sh"
private let uid = getuid()

/// Everything either script shells out to that can mutate machine state. A new one added
/// to a script but not here fails noUnstubbedStateChangingCommand instead of escaping.
private let stubbed = ["launchctl", "pkill", "pgrep", "curl", "osascript", "open", "nc", "sqlite3", "bun"]

// /health as screenpipe 2.7.116 reports it before and after Quit.
private let capturing = #"{"status":"healthy","frame_status":"ok","capture_status":{"status":"recording","active_audio_devices":2}}"#
private let searchOnly = #"{"status":"degraded","frame_status":"not_started","capture_status":{"status":"no_input_device","active_audio_devices":0}}"#

/// A sandbox running a capture script with every dangerous command stubbed. Identical
/// configurations share one sandbox on disk (the first exec of a fresh file on macOS is
/// slow); only the call log is per run.
struct Jail: Hashable {
    var launchctlLoaded = true
    var screenpipeRunning = false
    var healthOK = false
    var tunnelUp = false
    var unsynced = "0"
    var habitDB = false
    var plists: [String] = []
    var healthBody = ""

    private static let lock = NSLock()
    nonisolated(unsafe) private static var built: [Jail: (bin: String, home: String)] = [:]
    static let root = NSTemporaryDirectory() + "capture-jail-\(getpid())"

    private func stub(_ path: String, _ name: String, _ body: String) {
        FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\necho \"\(name) $*\" >> \"$STUB_LOG\"\n\(body)\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
    }

    private func sandbox() -> (bin: String, home: String) {
        Jail.lock.withLock {
            if let b = Jail.built[self] { return b }
            let base = Jail.root + "/\(UUID().uuidString.prefix(8))"
            let bin = base + "/bin", home = base + "/home"
            let fm = FileManager.default
            try? fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: home + "/Library/LaunchAgents", withIntermediateDirectories: true)
            // stop-capture.sh used to run $HOME/.bun/bin/bun by absolute path: the
            // sandboxed HOME is what neutralises it.
            try? fm.createDirectory(atPath: home + "/.bun/bin", withIntermediateDirectories: true)
            stub(home + "/.bun/bin/bun", "bun", "exit 0")
            let bodies = [
                "launchctl": "case \"$1\" in print) exit \(launchctlLoaded ? 0 : 1);; esac\nexit 0",
                "pgrep": "exit \(screenpipeRunning ? 0 : 1)",
                "curl": "cat <<'JSON'\n\(healthBody)\nJSON\nexit \(healthOK ? 0 : 1)",
                "sqlite3": "echo \"\(unsynced)\"\nexit 0",
                "nc": "exit \(tunnelUp ? 0 : 1)",
                // The scripts poll with `sleep 1` up to 60 times.
                "sleep": "exit 0",
            ]
            for name in stubbed + ["sleep"] { stub(bin + "/" + name, name, bodies[name] ?? "exit 0") }
            if habitDB {
                try? fm.createDirectory(atPath: home + "/.ai-aggregator", withIntermediateDirectories: true)
                fm.createFile(atPath: home + "/.ai-aggregator/behavior_experiments.sqlite", contents: Data())
            }
            for p in plists { fm.createFile(atPath: home + "/Library/LaunchAgents/" + p, contents: Data()) }
            Jail.built[self] = (bin, home)
            return (bin, home)
        }
    }

    /// Runs `script` in the sandbox: (exit status, stdout+stderr, the stubbed calls in order).
    func run(_ script: String, _ args: String...) -> (status: Int32?, output: String, calls: [String]) {
        let (bin, home) = sandbox()
        let log = Jail.root + "/calls-\(UUID().uuidString.prefix(8))"
        FileManager.default.createFile(atPath: log, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: log) }
        let r = ChildProcess.run("/bin/bash", [script] + args, timeout: 120,
                                 env: ["HOME": home, "PATH": bin + ":/usr/bin:/bin:/usr/sbin:/sbin", "STUB_LOG": log, "TERM": "dumb"],
                                 stderr: true)
        let calls = ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        return (r.status, r.output, calls)
    }
}

private func indexes(_ calls: [String], _ needle: String) -> [Int] {
    calls.indices.filter { calls[$0].contains(needle) }
}

@Suite("Capture scripts (stubbed)") struct ScriptsCaptureTests {
    static let plists = ["com.benpollack.learner-desktop.plist", "screenpipe.plist"]

    func startJail(launchctlLoaded: Bool = false, screenpipeRunning: Bool = false, healthBody: String = "",
                   plists: [String] = ScriptsCaptureTests.plists) -> Jail {
        // tunnelUp/healthOK short-circuit the readiness polls.
        Jail(launchctlLoaded: launchctlLoaded, screenpipeRunning: screenpipeRunning, healthOK: true, tunnelUp: true,
             plists: plists, healthBody: healthBody)
    }

    // MARK: Static checks

    @Test func scriptsParseAndAreExecutable() {
        for s in [stopScript, startScript] {
            let r = ChildProcess.run("/bin/bash", ["-n", s], timeout: 10, stderr: true)
            #expect(r.status == 0, "\(s): \(r.output)")
            #expect(FileManager.default.isExecutableFile(atPath: s))
        }
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/shellcheck")
                   || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/shellcheck"), "shellcheck not installed"))
    func shellcheckClean() {
        let sc = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/shellcheck") ? "/opt/homebrew/bin/shellcheck" : "/usr/local/bin/shellcheck"
        for s in [stopScript, startScript] {
            let r = ChildProcess.run(sc, ["-S", "warning", s], timeout: 30)
            #expect(r.status == 0, "\(r.output)")
        }
    }

    @Test func noUnstubbedStateChangingCommand() throws {
        let risky: Set<String> = ["launchctl", "pkill", "killall", "osascript", "open", "curl", "sqlite3", "nc", "bun",
                                  "npm", "defaults", "systemsetup"]
        for s in [stopScript, startScript] {
            let text = try String(contentsOfFile: s, encoding: .utf8).replacingOccurrences(of: "(", with: " ").replacingOccurrences(of: "\"", with: " ")
            let words = Set(text.split(whereSeparator: \.isWhitespace).map(String.init))
            #expect(words.intersection(risky).subtracting(stubbed).isEmpty, "\(s) calls \(words.intersection(risky).subtracting(stubbed)) unstubbed")
        }
    }

    // MARK: Arguments (handled before any side effect)

    @Test func helpPrintsUsageDocumentsEveryFlagAndTouchesNothing() throws {
        let jail = Jail()
        for s in [stopScript, startScript] {
            for flag in ["--help", "-h"] {
                let r = jail.run(s, flag)
                #expect(r.status == 0 && r.output.contains("Usage:"))
                #expect(r.calls.isEmpty, "--help must not run any command")
            }
            let help = jail.run(s, "--help").output
            let flags = try String(contentsOfFile: s, encoding: .utf8).components(separatedBy: "\n").compactMap { l -> String? in
                guard let r = l.range(of: #"^\s*--[a-z-]+\)"#, options: .regularExpression) else { return nil }
                return String(l[r]).trimmingCharacters(in: .whitespaces).dropLast().description
            }.filter { $0 != "--help" }
            #expect(!flags.isEmpty)
            for f in flags { #expect(help.contains(f), "\(s) accepts \(f) but --help does not mention it") }
        }
    }

    @Test func unknownOptionExitsTwoWithoutActing() {
        for s in [stopScript, startScript] {
            let r = Jail().run(s, "--wat")
            #expect(r.status == 2 && r.output.contains("unknown option") && r.calls.isEmpty)
        }
    }

    // MARK: Stop ordering

    @Test func stopBootsOutTheAppThenScreenpipe() {
        let calls = Jail().run(stopScript).calls
        #expect(calls.filter { $0.hasPrefix("launchctl bootout") } ==
                ["launchctl bootout gui/\(uid)/com.benpollack.learner-desktop", "launchctl bootout gui/\(uid)/screenpipe"])
    }

    @Test func stopWaitsForTheAppToExitBeforeKillingLeftovers() throws {
        // bootout returns before the app's clean shutdown, which still sends queued rows.
        let calls = Jail().run(stopScript).calls
        let waited = try #require(indexes(calls, "pgrep -f MacOS/learner-desktop").first)
        let killed = try #require(indexes(calls, "pkill -f learner-watcher.js").first)
        #expect(waited < killed)
    }

    @Test func stopKillsHelpersACrashedAppLeftBehind() throws {
        let calls = Jail().run(stopScript).calls
        let app = try #require(indexes(calls, "bootout gui/\(uid)/com.benpollack.learner-desktop").first)
        for helper in ["learner-watcher.js", "autossh"] {
            let k = try #require(indexes(calls, helper).first, "never cleaned up a leftover \(helper)")
            #expect(app < k)
        }
    }

    @Test func persistDisablesExactlyWhatItBootsOut() {
        #expect(Jail().run(stopScript).calls.filter { $0.hasPrefix("launchctl disable") }.isEmpty)
        let calls = Jail().run(stopScript, "--persist").calls
        let booted = Set(calls.filter { $0.hasPrefix("launchctl bootout") }.map { $0.split(separator: "/").last! })
        let disabled = Set(calls.filter { $0.hasPrefix("launchctl disable") }.map { $0.split(separator: "/").last! })
        #expect(!booted.isEmpty && booted == disabled)
    }

    @Test func keepScreenpipeSkipsTheWholeScreenpipeTeardown() {
        let calls = Jail().run(stopScript, "--keep-screenpipe").calls
        #expect(indexes(calls, "screenpipe").isEmpty)
        #expect(!indexes(calls, "learner-desktop").isEmpty)
    }

    @Test func stopNeverRunsADatabaseFlushOfItsOwn() {
        // The app sends its own queued rows over HTTPS when it quits.
        let r = Jail(unsynced: "7", habitDB: true).run(stopScript)
        #expect(r.calls.filter { $0.hasPrefix("bun") }.isEmpty)
        #expect(r.output.contains("queued to send: 7"))
    }

    // MARK: screenpipe teardown (no SIGTERM handler: pause over the API first)

    @Test func pausesCaptureOverTheAPIBeforeQuitting() throws {
        let calls = Jail(screenpipeRunning: true, healthOK: true, healthBody: capturing).run(stopScript).calls
        let pause = try #require(indexes(calls, "/audio/stop").first)
        let quit = try #require(indexes(calls, "osascript").first)
        #expect(pause < quit)
    }

    @Test func doesNotQuitOnceTheAPIHasStoppedCapture() {
        // A Quit with capture active pops a dialog and since 2.7.116 does not exit anyway.
        let r = Jail(screenpipeRunning: true, healthOK: true, healthBody: searchOnly).run(stopScript)
        #expect(!indexes(r.calls, "/audio/stop").isEmpty)
        #expect(indexes(r.calls, "osascript").isEmpty && indexes(r.calls, "pkill -TERM").isEmpty && indexes(r.calls, "pkill -KILL").isEmpty)
        #expect(r.output.contains("capture stopped over the API"))
    }

    @Test func escalatesWhenTheAPICannotConfirmCaptureStopped() {
        #expect(!indexes(Jail(screenpipeRunning: true).run(stopScript).calls, "pkill -TERM").isEmpty)
    }

    @Test func escalatesToSIGTERMThenSIGKILLOnlyAfterTheQuit() throws {
        let calls = Jail(screenpipeRunning: true, healthOK: true, healthBody: capturing).run(stopScript).calls
        let quit = try #require(indexes(calls, "osascript").first)
        let term = try #require(indexes(calls, "pkill -TERM").first)
        let kill = try #require(indexes(calls, "pkill -KILL").first)
        #expect(quit < term && term < kill)
    }

    @Test func leavesAScreenpipeThatIsAlreadyGoneAlone() {
        let calls = Jail().run(stopScript).calls
        #expect(indexes(calls, "pkill -TERM").isEmpty && indexes(calls, "osascript").isEmpty)
    }

    // MARK: Start ordering (the exact reverse)

    @Test func startsScreenpipeThenTheAppThenChecksTheServer() throws {
        let calls = startJail().run(startScript).calls
        let order = calls.filter { $0.hasPrefix("launchctl bootstrap") }
            .map { $0.split(separator: "/").last!.replacingOccurrences(of: ".plist", with: "") }
        #expect(order == ["screenpipe", "com.benpollack.learner-desktop"])
        let app = try #require(indexes(calls, "bootstrap gui/\(uid)").last)
        let probe = try #require(indexes(calls, "learner-api/api/health").first, "never checked learner-server")
        #expect(app < probe)
    }

    @Test func enablesEachJobBeforeBootstrappingIt() throws {
        // stop-capture.sh --persist leaves jobs disabled; bootstrap then silently refuses.
        let calls = startJail().run(startScript).calls
        for label in ["learner-desktop", "screenpipe"] {
            let enable = try #require(calls.indices.first { calls[$0].hasPrefix("launchctl enable") && calls[$0].contains(label) })
            let boot = try #require(calls.indices.first { calls[$0].hasPrefix("launchctl bootstrap") && calls[$0].contains(label) })
            #expect(enable < boot, "\(label): enable must precede bootstrap")
        }
    }

    @Test func kickstartsALoadedJobInsteadOfBootstrapping() {
        #expect(startJail(launchctlLoaded: true).run(startScript).calls.contains { $0.hasPrefix("launchctl kickstart -k") })
    }

    @Test func noScreenpipeStartsOnlyTheRest() {
        let calls = startJail().run(startScript, "--no-screenpipe").calls
        #expect(indexes(calls, "screenpipe").isEmpty && !indexes(calls, "learner-desktop").isEmpty)
    }

    @Test func reopensARunningScreenpipeAndResumesPausedCaptureOverTheAPI() throws {
        #expect(!indexes(startJail(screenpipeRunning: true).run(startScript).calls, "open -g -a /Applications/screenpipe.app").isEmpty)
        let calls = startJail(screenpipeRunning: true, healthBody: searchOnly).run(startScript).calls
        let reopen = try #require(indexes(calls, "open -g -a /Applications/screenpipe.app").first)
        let resume = try #require(indexes(calls, "-X POST http://127.0.0.1:3030/audio/start").first)
        #expect(reopen < resume)
        #expect(indexes(startJail(screenpipeRunning: true, healthBody: capturing).run(startScript).calls, "/audio/start").isEmpty)
    }

    @Test func aMissingPlistWarnsAndFallsBack() {
        let r = startJail(plists: []).run(startScript)
        #expect(r.status == 0 && r.output.contains("missing plist"))
        #expect(r.calls.contains { $0.hasPrefix("open ") }, "screenpipe should fall back to `open -g -a screenpipe.app`")
    }

    @Test func everyLabelStopCaptureStopsHasAStartPath() throws {
        let stop = try String(contentsOfFile: stopScript, encoding: .utf8)
        let start = try String(contentsOfFile: startScript, encoding: .utf8)
        let labels = stop.components(separatedBy: "\n").filter { $0.hasPrefix("LABEL_") }
            .map { $0.split(separator: "=", maxSplits: 1)[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
        #expect(!labels.isEmpty)
        for l in labels { #expect(start.contains(l), "stop-capture.sh stops \(l), start-capture.sh never starts it") }
    }
}
