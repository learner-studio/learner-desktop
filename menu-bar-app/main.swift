import AppKit
import Foundation
import ServiceManagement
import SQLite3
import CoreBluetooth
import CommonCrypto

// MARK: - Application Entrypoint

if CommandLine.arguments.contains("--browser-cookie-check") {
    runBrowserCookieCheckCLI()
}

// `tool <name> ...`: the owner's one-shot tools (Tools.swift); prints and exits.
if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "tool" { exit(runToolCLI(Array(CommandLine.arguments.dropFirst(2)))) }

if CommandLine.arguments.contains("--pavlok-test-fire") {
    runPavlokTestFireCLI()
}

// `--drain-outbox` sends the outbox once (LEARNER_API_URL / LEARNER_API_KEY /
// LEARNER_OUTBOX_DB override the defaults) and exits 0 when it is empty.
if CommandLine.arguments.contains("--drain-outbox") {
    let left = OutboxSender.shared.drain(until: Date().addingTimeInterval(120))
    print("[Outbox] drain finished: \(left) unsent, last status: \(OutboxSender.shared.lastStatus)")
    HabitEventLogger.shared.close()
    exit(left == 0 ? 0 : 1)
}

let app = NSApplication.shared
let delegate = TrayAppManager()
app.delegate = delegate
AppLog.attachToFile()
delegate.installSignalHandlers()
// .accessory activation policy places the app in the system tray / menu bar without taking up Dock space
app.setActivationPolicy(.accessory)
app.run()
