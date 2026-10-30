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
        "openLearnerWeb": "opens Learner's web UI when the server publishes one",
        "switchToAdvertisedServer": "asks, then switches to the API URL the server now advertises",
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
        "toggleMasteryCallHold": "switches holding mastery toasts during calls",
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
        #expect(opened["openVaultFolder"]?.path == Paths.vault)
        #expect(opened["openScreenpipeData"]?.path == NSHomeDirectory() + "/.screenpipe/data")
        #expect(opened["openUpdateCheckLogs"]?.path == ScreenpipeUpdateCheck.shared.logDir)
        #expect(opened["openAppLog"]?.path == AppLog.path)
    }

    /// The list above stays honest: a listed action that no longer exists fails.
    @Test func everyListedActionExistsOnTheTray() {
        let tray = TrayAppManager()
        for name in Self.actions.keys {
            #expect(tray.responds(to: NSSelectorFromString(name)), "\(name) is listed but the tray has no such action")
        }
    }

    /// The test process's own defaults (not the app's) hold these settings; each click below
    /// is undone, and the values are put back whatever happens.
    static let settingKeys = CoachSettings.Key.allCases.map(\.rawValue) + [ChromiumBrowser.defaultsKey, MasteryFeed.Key.holdDuringCalls]

    func preservingSettings(_ body: () throws -> Void) rethrows {
        let d = UserDefaults.standard
        let saved = Self.settingKeys.map { ($0, d.object(forKey: $0)) }
        defer { for (k, v) in saved { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } } }
        try body()
    }

    /// Clicks the first line with `action` (and `which`) in the menu as it is now.
    func click(_ tray: TrayAppManager, _ action: String, which: (NSMenuItem) -> Bool = { _ in true }) throws {
        let item = try #require(Self.allItems(tray.statusMenu).first { $0.action.map(NSStringFromSelector) == action && which($0) },
                                "no line for \(action)")
        (item.target as? NSObject)?.perform(item.action!, with: item)
    }

    /// Every setting the menu flips or chooses, clicked for real (no Bluetooth: tests never
    /// reach the radio): the setting changes, and a second click (or choosing the old value)
    /// brings it back.
    @Test func everySettingClickChangesItAndCanBeUndone() throws {
        let (tray, _) = builtMenu()
        defer { withExtendedLifetime(tray) {} }
        let s = CoachSettings.shared
        try preservingSettings {
            let toggles: [(String, () -> Bool)] = [
                ("toggleAlertOnlyDuringCalls", { tray.talkMonitor.alertOnlyDuringCalls }),
                ("toggleGoodBehaviorReward", { s.rewardGoodBehavior }),
                ("togglePavlokEnabled", { s.wearableEnabled }),
                ("togglePavlokConnection", { s.keepConnected }),
                ("toggleMasteryCallHold", { MasteryFeed.shared.holdDuringCalls }),
            ]
            for (action, value) in toggles {
                let before = value()
                try click(tray, action)
                #expect(value() != before, "\(action) did not change its setting")
                try click(tray, action)
                #expect(value() == before, "\(action) twice did not restore it")
            }

            let browser = ChromiumBrowser.selected.id
            let other = try #require(ChromiumBrowser.all.first { $0.id != browser }?.id)
            try click(tray, "selectVaultBrowser:") { $0.representedObject as? String == other }
            #expect(ChromiumBrowser.selected.id == other)
            try click(tray, "selectVaultBrowser:") { $0.representedObject as? String == browser }
            #expect(ChromiumBrowser.selected.id == browser)

            let mode = HabitExperimentManager.shared.currentMode
            let otherMode = try #require(AssignmentMode.allCases.first { $0 != mode })
            try click(tray, "selectExperimentArm:") { $0.representedObject as? String == otherMode.rawValue }
            #expect(HabitExperimentManager.shared.currentMode == otherMode)
            try click(tray, "selectExperimentArm:") { $0.representedObject as? String == mode.rawValue }
            #expect(HabitExperimentManager.shared.currentMode == mode)

            let preset = try #require(CuePreset.all.first { $0.key != s.matchingPreset?.key })
            try click(tray, "selectCuePreset:") { $0.representedObject as? String == preset.key }
            #expect(s.matchingPreset?.key == preset.key)
        }
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
