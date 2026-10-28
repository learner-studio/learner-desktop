import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// The app's launchd agent: started at login, restarted after a crash but not after a clean
// quit (Quit used to be a restart button that skipped the trial flush), and pointing at
// the installed bundle, under the label the capture scripts stop and start.
@Suite("Launch agent", .tags(.light, .helpers), .timeLimit(.minutes(1)), .quietLog) struct LaunchAgentTests {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func plist() throws -> [String: Any] {
        let data = try Data(contentsOf: repo.appendingPathComponent("menu-bar-app/com.benpollack.learner-desktop.plist"))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func restartsOnlyAfterACrashAndStartsAtLogin() throws {
        let p = try plist()
        #expect(p["RunAtLoad"] as? Bool == true)
        #expect((p["KeepAlive"] as? [String: Any])?["SuccessfulExit"] as? Bool == false)
    }

    @Test func launchesTheInstalledBundleAndLogsWhereTheAppRotates() throws {
        let p = try plist()
        let program = (p["ProgramArguments"] as? [String])?.first ?? ""
        #expect(program.hasSuffix("/Applications/Learner Desktop.app/Contents/MacOS/learner-desktop"))
        #expect((p["StandardOutPath"] as? String)?.hasSuffix(".ai-aggregator/logs/menubar.log") == true)
        #expect(AppLog.path == Paths.logs + "/menubar.log")
    }

    @Test func theCaptureScriptsUseTheSameLabel() throws {
        let label = try plist()["Label"] as? String ?? ""
        for script in ["scripts/stop-capture.sh", "scripts/start-capture.sh"] {
            let text = try String(contentsOf: repo.appendingPathComponent(script), encoding: .utf8)
            #expect(text.contains("LABEL_APP=\"\(label)\""), "\(script) must stop/start \(label)")
        }
    }
}

// The SSH tunnel is gone (it only carried GrowthBook's UI, which could not reach its API
// through it): no script, and nothing in the app starts it.
@Suite("No tunnel", .tags(.light, .helpers, .scripts), .timeLimit(.minutes(1)), .quietLog) struct NoTunnelTests {
    @Test func nothingStartsOrBundlesTheTunnel() throws {
        let root = toolsRepoRoot()
        #expect(!FileManager.default.fileExists(atPath: root + "/scripts/tunnel.sh"))
        let build = try String(contentsOfFile: root + "/scripts/build-app.sh", encoding: .utf8)
        #expect(!build.contains("tunnel.sh"))
        let tray = try String(contentsOfFile: root + "/menu-bar-app/Tray.swift", encoding: .utf8)
        #expect(!tray.contains("3200:127.0.0.1:3200") && !tray.contains("localhost:3200"))
    }
}
