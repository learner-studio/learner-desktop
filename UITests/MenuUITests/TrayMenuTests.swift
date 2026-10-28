import XCTest

/// Clicks a running app's menu-bar item the way the owner does and times how long its menu
/// takes to show. Run with scripts/ui-test.sh (Learner Desktop must be running). The host
/// app's plain menu-bar item is timed the same way: the baseline for XCUITest's own cost.
final class TrayMenuTests: XCTestCase {
    @MainActor
    func opens(_ bundleId: String, times: Int = 6) throws -> [Double] {
        let app = XCUIApplication(bundleIdentifier: bundleId)
        let first = app.statusItems.firstMatch
        guard first.waitForExistence(timeout: 10) else { throw XCTSkip("\(bundleId) has no menu-bar item (not running?)") }
        let all = app.statusItems.allElementsBoundByIndex
        print("STATUS-ITEMS \(bundleId) \(all.map { "\($0.frame) hittable=\($0.isHittable)" })")
        guard let item = all.first(where: { $0.isHittable }) else { throw XCTSkip("\(bundleId): no visible menu-bar item") }
        let anyItem = app.menuItems.firstMatch
        var opens: [Double] = []
        for _ in 0..<times {
            let started = Date()
            item.click()
            XCTAssertTrue(anyItem.waitForExistence(timeout: 15), "\(bundleId): the menu did not open")
            opens.append(Date().timeIntervalSince(started))
            app.typeKey(.escape, modifierFlags: [])
            Thread.sleep(forTimeInterval: 1.5)
        }
        return opens
    }

    static func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }
    static func ms(_ xs: [Double]) -> [Int] { xs.map { Int($0 * 1000) } }

    @MainActor
    func testTheTrayMenuOpensAsFastAsAPlainMenuBarApp() throws {
        let learner = try opens("com.benpollack.ai-aggregator-menubar")
        // The host app's ordinary "Baseline" menu, timed the same way (Host/main.swift).
        let host = XCUIApplication()
        host.launch()
        defer { host.terminate() }
        let menu = host.menuBarItems["Baseline"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        let first = host.menuItems["Baseline item 0"]
        var baseline: [Double] = []
        for _ in 0..<6 {
            let started = Date()
            menu.click()
            XCTAssertTrue(first.waitForExistence(timeout: 15))
            baseline.append(Date().timeIntervalSince(started))
            host.typeKey(.escape, modifierFlags: [])
            Thread.sleep(forTimeInterval: 1.5)
        }
        print("MENU-OPEN-MS learner \(Self.ms(learner)) baseline \(Self.ms(baseline))")
        // The first click pays XCUITest's setup; the rest are what a click costs.
        let mine = Self.median(Array(learner.dropFirst()))
        let limit = baseline.count > 1 ? Self.median(Array(baseline.dropFirst())) + 0.3 : 0.8
        XCTAssertLessThan(mine, limit, "learner \(Self.ms(learner)) vs baseline \(Self.ms(baseline))")
    }

    /// The real menu, opened by a click: every line a click acts on is there and enabled,
    /// and the GrowthBook line names the learner-server host it opens (never the old tunnel).
    @MainActor
    func testEveryMenuLineIsThereAndGrowthBookOpensTheServersHost() throws {
        let learner = XCUIApplication(bundleIdentifier: "com.benpollack.ai-aggregator-menubar")
        let item = learner.statusItems.firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "Learner Desktop's menu-bar item is not there (is the app running?)")
        item.click()
        defer { learner.typeKey(.escape, modifierFlags: []) }
        func line(_ text: String) -> XCUIElement {
            learner.menuItems.matching(NSPredicate(format: "title CONTAINS %@", text)).firstMatch
        }
        XCTAssertTrue(line("Pull Latest Chats").waitForExistence(timeout: 15), "the menu did not open")
        for text in ["Pull Latest Chats", "Send Queued Trials Now", "Open GrowthBook Dashboard", "Pavlok", "Settings", "Troubleshooting"] {
            let l = line(text)
            XCTAssertTrue(l.exists, "no '\(text)' line")
            XCTAssertTrue(l.isEnabled, "'\(text)' is disabled")
        }
        let growthbook = line("Open GrowthBook Dashboard").title
        XCTAssertTrue(growthbook.contains("(dev.biztoolz.app)"), growthbook)
        XCTAssertFalse(growthbook.contains("localhost"), growthbook)
    }
}
