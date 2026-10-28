import XCTest

/// The installed app's tray menu, clicked for real (run with scripts/ui-test.sh; it moves the
/// pointer, so it is in no hook). Only what an in-process test cannot reach is here: a real
/// click on the menu-bar item, how long the menu takes to show, every submenu opening, and
/// settings clicked through the real menu and clicked back. Every line's handler and every
/// link's target are checked in-process by Tests/LightTests/TrayMenuClickTests.
///
/// Never clicked here (they act on the owner's data, devices or account): Quit, Pull Latest
/// Chats, Send Queued Trials, Bluetooth scan or keep-connected, the token prompt, wearable
/// feedback, another condition or preset, where learner-server runs, Restart CLI Uploader,
/// the update check, Sign In Again, Reset Streak, Dismiss Toast and the Open... lines.
final class TrayMenuTests: XCTestCase {
    static let bundleId = "com.benpollack.ai-aggregator-menubar"

    override func setUp() {
        continueAfterFailure = false
    }

    /// The tray's menu-bar item; a failure (not a skip) when it is hidden, behind the notch say.
    @MainActor
    func trayItem(_ app: XCUIApplication) -> XCUIElement {
        let first = app.statusItems.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10), "Learner Desktop's menu-bar item is not there (is the app running?)")
        let item = app.statusItems.allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(item, "the menu-bar item is hidden (behind the notch?): \(app.statusItems.allElementsBoundByIndex.map(\.frame))")
        return item!
    }

    @MainActor
    func line(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.menuItems.matching(NSPredicate(format: "title CONTAINS %@", text)).firstMatch
    }

    /// Opens the menu with a click and returns once it shows.
    @MainActor
    func open(_ app: XCUIApplication, _ item: XCUIElement) {
        item.click()
        XCTAssertTrue(line(app, "Pull Latest Chats").waitForExistence(timeout: 15), "the menu did not open")
    }

    @MainActor
    func close(_ app: XCUIApplication) {
        app.typeKey(.escape, modifierFlags: [])
        _ = line(app, "Pull Latest Chats").waitForNonExistence(timeout: 5)
    }

    static func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }
    static func ms(_ xs: [Double]) -> [Int] { xs.map { Int($0 * 1000) } }

    /// The tray menu opens about as fast as an ordinary AppKit menu, clicked the same way
    /// (the host app's "Baseline" menu, Host/main.swift): what XCUITest and the system add
    /// is the same for both, so the difference is the app's. One untimed open each first,
    /// so XCUITest's setup is not in the numbers.
    @MainActor
    func testTheTrayMenuOpensAsFastAsAnOrdinaryMenu() throws {
        let learner = XCUIApplication(bundleIdentifier: Self.bundleId)
        let item = trayItem(learner)
        open(learner, item); close(learner)
        var tray: [Double] = []
        for _ in 0..<5 {
            let started = Date()
            open(learner, item)
            tray.append(Date().timeIntervalSince(started))
            close(learner)
        }

        let host = XCUIApplication()
        host.launch()
        defer { host.terminate() }
        let menu = host.menuBarItems["Baseline"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        let first = host.menuItems["Baseline item 0"]
        menu.click(); XCTAssertTrue(first.waitForExistence(timeout: 15)); host.typeKey(.escape, modifierFlags: [])
        _ = first.waitForNonExistence(timeout: 5)
        var baseline: [Double] = []
        for _ in 0..<5 {
            let started = Date()
            menu.click()
            XCTAssertTrue(first.waitForExistence(timeout: 15))
            baseline.append(Date().timeIntervalSince(started))
            host.typeKey(.escape, modifierFlags: [])
            _ = first.waitForNonExistence(timeout: 5)
        }
        print("MENU-OPEN-MS learner \(Self.ms(tray)) baseline \(Self.ms(baseline))")
        XCTAssertLessThan(Self.median(tray), Self.median(baseline) + 0.3, "learner \(Self.ms(tray)) vs baseline \(Self.ms(baseline))")
    }

    /// Every submenu opens from a real click and shows its lines, the cue panels included
    /// (custom views, which no in-process walk of the item list can reach).
    @MainActor
    func testEverySubmenuOpens() throws {
        let learner = XCUIApplication(bundleIdentifier: Self.bundleId)
        open(learner, trayItem(learner))
        defer { close(learner) }
        // parent line -> a line (or control) its submenu must show
        let submenus: [(path: [String], shows: String)] = [
            (["Pavlok"], "Keep Bluetooth Connected"),
            (["Pavlok", "Cue Preset"], "30s"),
            (["Pavlok", "30s"], "Modalities"),
            (["Pavlok", "60s"], "Modalities"),
            (["Settings"], "Alert"),
            (["Settings", "Sign AI Vault In From"], "Brave"),
            (["Settings", "Select Active Intervention Condition"], "✓"),
            (["Troubleshooting"], "View App Log"),
        ]
        for (path, shows) in submenus {
            for (i, step) in path.enumerated() {
                let parent = line(learner, step)
                XCTAssertTrue(parent.waitForExistence(timeout: 5), "no '\(step)' line (path \(path))")
                parent.hover()
                if i == path.count - 1 {
                    let inside = learner.descendants(matching: .any).matching(NSPredicate(format: "title CONTAINS %@ OR value CONTAINS %@ OR label CONTAINS %@", shows, shows, shows)).firstMatch
                    XCTAssertTrue(inside.waitForExistence(timeout: 5), "\(path.joined(separator: " > ")) did not show '\(shows)'")
                }
            }
        }
    }

    /// A setting clicked through the real menu changes its line, and a second click brings it
    /// back: "Alert Only During Calls" and the good-behaviour reward (each click closes the menu).
    @MainActor
    func testReversibleSettingsFlipAndFlipBack() throws {
        let learner = XCUIApplication(bundleIdentifier: Self.bundleId)
        let item = trayItem(learner)
        for (parent, text) in [("Settings", "Alert"), ("Pavlok", "Good Behavior")] {
            open(learner, item)
            line(learner, parent).hover()
            let before = line(learner, text)
            XCTAssertTrue(before.waitForExistence(timeout: 5), "no '\(text)' line under \(parent)")
            let was = before.title
            before.click()
            open(learner, item)
            line(learner, parent).hover()
            let now = line(learner, text)
            XCTAssertTrue(now.waitForExistence(timeout: 5))
            XCTAssertNotEqual(now.title, was, "'\(text)' did not change")
            now.click()   // back as it was
            open(learner, item)
            line(learner, parent).hover()
            XCTAssertEqual(line(learner, text).title, was, "'\(text)' is not back as it was")
            close(learner)
        }
    }

    /// The real menu names the learner-server host its GrowthBook line opens, or has none.
    @MainActor
    func testTheGrowthBookLineNamesItsHost() throws {
        let learner = XCUIApplication(bundleIdentifier: Self.bundleId)
        open(learner, trayItem(learner))
        defer { close(learner) }
        let growthbook = line(learner, "GrowthBook")
        guard growthbook.exists else { return }   // the server publishes none: no line
        XCTAssertFalse(growthbook.title.contains("localhost:3200"), growthbook.title)
        XCTAssertTrue(growthbook.title.contains("(") && growthbook.isEnabled, growthbook.title)
    }
}
