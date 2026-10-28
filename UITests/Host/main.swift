import AppKit

// The baseline for the tray-menu timing test: an ordinary AppKit app menu ("Baseline") about
// the size of Learner Desktop's tray menu. XCUITest's own cost, and the system's (WindowServer
// delivering the click), are the same for both; what is left over is Learner's.
@MainActor
final class Baseline: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "UITestHost")
        bar.addItem(appItem)
        let item = NSMenuItem(title: "Baseline", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Baseline")
        for i in 0..<40 { menu.addItem(NSMenuItem(title: "Baseline item \(i)", action: nil, keyEquivalent: "")) }
        item.submenu = menu
        bar.addItem(item)
        NSApp.mainMenu = bar
        NSApp.activate()
    }
}

let app = NSApplication.shared
let delegate = Baseline()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
