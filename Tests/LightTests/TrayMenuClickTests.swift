import AppKit
import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// Every line of the real tray menu (submenus included), as built by the app: each clickable
// line has a handler, every handler is listed here with what a click does, and every click
// that opens something opens the right place. 10-28: "Open GrowthBook Dashboard" opened a
// tunnel URL whose page could not reach its own API.
@MainActor @Suite("Tray menu: every click", .tags(.light, .status), .quietLog, .serialized)
struct TrayMenuClickTests {
    /// What each menu action does. A new action fails `everyClickableLineIsHandledAndListed`
    /// until it is listed here (and, when it opens something, checked in `everyOpenGoesToTheRightPlace`).
    static let actions: [String: String] = [
        "openGrowthBookDashboard": "opens GrowthBook for the configured learner-server",
        "openVaultFolder": "opens the ai-vault folder",
        "openScreenpipeData": "opens screenpipe's data folder",
        "openUpdateCheckLogs": "opens the update-check logs folder",
        "openAppLog": "opens menubar.log",
        "openLoginItemsSettings": "opens System Settings > Login Items",
        "signInToVault:": "starts an ai-vault sign-in in the chosen browser",
        "pullVaultChats": "runs the export now",
        "triggerHabitSync": "sends queued trials now",
        "restartUploader": "restarts the CLI uploader",
        "runScreenpipeUpdateCheck": "starts a screenpipe update check",
        "quitApp": "quits",
        "selectVaultBrowser:": "chooses the sign-in browser",
        "toggleServerOnThisMac": "switches where learner-server runs (and the uploader)",
        "toggleAlertOnlyDuringCalls": "switches off-call alerts",
        "selectExperimentArm:": "chooses the experiment condition",
        "dismissToast": "dismisses the alert toast",
        "resetStreakAction": "resets the speaking streak",
        "togglePavlokEnabled": "switches wristband feedback",
        "selectCuePreset:": "chooses a cue preset",
        "toggleGoodBehaviorReward": "switches the good-behaviour vibration",
        "togglePavlokConnection": "switches keeping Bluetooth connected",
        "scanPavlokBluetooth": "scans for the wristband",
        "promptPavlokToken": "asks for the cloud token",
    ]

    static func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) }
    }

    func builtMenu() -> (TrayAppManager, [NSMenuItem]) {
        let tray = TrayAppManager()
        tray.statusMenu = NSMenu()
        tray.rebuildMenu()
        return (tray, Self.allItems(tray.statusMenu))
    }

    @Test func everyClickableLineIsHandledAndListed() {
        let (tray, items) = builtMenu()   // menu targets are weak: keep the tray alive
        // A line with a submenu carries AppKit's own submenuAction: it opens the submenu.
        let clickable = items.filter { $0.action != nil && $0.submenu == nil }
        #expect(clickable.count >= 15, "the menu has \(clickable.count) clickable lines")
        defer { withExtendedLifetime(tray) {} }
        for item in clickable {
            let name = NSStringFromSelector(item.action!)
            #expect((item.target as? NSObject)?.responds(to: item.action!) == true, "\(item.title): no handler for \(name) on \(String(describing: item.target))")
            #expect(Self.actions[name] != nil, "\(item.title): \(name) is not listed in TrayMenuClickTests.actions")
        }
    }

    @Test func everyOpenGoesToTheRightPlace() throws {
        let (tray, items) = builtMenu()
        var opened: [String: URL] = [:]
        var current = ""
        tray.openURL = { url in opened[current] = url; return true }
        for item in items {
            guard let action = item.action, NSStringFromSelector(action).hasPrefix("open"),
                  NSStringFromSelector(action) != "openLoginItemsSettings" else { continue }
            current = NSStringFromSelector(action)
            (item.target as? NSObject)?.perform(action, with: item)
        }
        #expect(Set(opened.keys) == ["openGrowthBookDashboard", "openVaultFolder", "openScreenpipeData", "openUpdateCheckLogs", "openAppLog"],
                "\(opened.keys.sorted())")
        #expect(opened["openGrowthBookDashboard"] == GrowthBookLink.current)
        #expect(opened["openGrowthBookDashboard"]?.absoluteString != "http://localhost:3200", "the old tunnel URL")
        #expect(opened["openVaultFolder"]?.path == Paths.vault)
        #expect(opened["openScreenpipeData"]?.path == NSHomeDirectory() + "/.screenpipe/data")
        #expect(opened["openUpdateCheckLogs"]?.path == ScreenpipeUpdateCheck.shared.logDir)
        #expect(opened["openAppLog"]?.path == AppLog.path)
    }

    @Test func theGrowthBookLineSaysWhereItGoes() throws {
        let (tray, items) = builtMenu()
        defer { withExtendedLifetime(tray) {} }
        let line = try #require(items.first { $0.action.map(NSStringFromSelector) == "openGrowthBookDashboard" })
        #expect(line.title.contains("(\(try #require(GrowthBookLink.current?.host)))"), "\(line.title)")
    }

    /// GrowthBook is installed with learner-server, on whichever machine that is: the link
    /// is that server's origin + /growthbook/, the same origin as GrowthBook's own API.
    @Test func theGrowthBookLinkFollowsTheLearnerServer() {
        // Remote (today): the deployed server.
        #expect(GrowthBookLink.url(serverBase: "https://dev.biztoolz.app/learner-api", override: nil)?.absoluteString
                == "https://dev.biztoolz.app/growthbook/")
        // On this Mac, or any host and port: wherever the server is.
        #expect(GrowthBookLink.url(serverBase: "http://localhost:3010", override: nil)?.absoluteString == "http://localhost:3010/growthbook/")
        #expect(GrowthBookLink.url(serverBase: "http://box.test:8080/learner-api/", override: nil)?.absoluteString
                == "http://box.test:8080/growthbook/")
        // Never the old tunnel.
        #expect(GrowthBookLink.url(serverBase: LearnerRPC.defaultBaseURL, override: nil)?.port != 3200)
        // An explicit URL wins; a blank one does not count; a server that is not a URL gives none.
        #expect(GrowthBookLink.url(serverBase: "x", override: " https://gb.example.test ")?.absoluteString == "https://gb.example.test")
        #expect(GrowthBookLink.url(serverBase: "https://dev.biztoolz.app/learner-api", override: "  ")?.host == "dev.biztoolz.app")
        #expect(GrowthBookLink.url(serverBase: "not a url", override: nil) == nil)
    }
}
