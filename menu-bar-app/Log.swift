import AppKit
import Foundation
import ServiceManagement
import SQLite3
import CoreBluetooth
import CommonCrypto

// MARK: - Logging

/// Every `print` in the app goes through here (it shadows Swift.print in this module).
/// Lines get a timestamp, and a line that repeats within 10 minutes (numbers ignored) is
/// held back and counted, so a retry loop -- a Bluetooth band out of range, the mic gain
/// guard -- costs one line per 10 minutes instead of thousands. The app's own log file
/// is rotated by AppLog.
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    AppLog.write(items.map { "\($0)" }.joined(separator: separator), terminator: terminator)
}

enum AppLog {
    static let path = NSHomeDirectory() + "/.ai-aggregator/logs/menubar.log"
    static let maxBytes: UInt64 = 10_000_000
    static let repeatWindow: TimeInterval = 600

    private static let lock = NSLock()
    private static var lastSeen: [String: (at: Date, held: Int)] = [:]
    private static var writes = 0
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Send stdout/stderr to the log file (launchd points them there too; this lets the app
    /// rotate it). Not used by the one-shot CLI modes, which print to the terminal.
    static func attachToFile() {
        rotateIfNeeded(force: false)
        freopen(path, "a", stdout)
        freopen(path, "a", stderr)
    }

    static func write(_ line: String, terminator: String) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let key = line.replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
        var text = line
        if let seen = lastSeen[key], now.timeIntervalSince(seen.at) < repeatWindow {
            lastSeen[key] = (seen.at, seen.held + 1)
            return
        } else if let seen = lastSeen[key], seen.held > 0 {
            text += "  [repeated \(seen.held)x in the previous \(Int(repeatWindow / 60)) min]"
        }
        if lastSeen.count > 2000 { lastSeen.removeAll() }
        lastSeen[key] = (now, 0)
        Swift.print("\(stamp.string(from: now)) \(text)", terminator: terminator)
        writes += 1
        if writes % 500 == 0 { rotateIfNeeded(force: false) }
    }

    /// Keep one previous file: menubar.log -> menubar.1.log once it passes maxBytes.
    static func rotateIfNeeded(force: Bool) {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
        guard force || size > maxBytes else { return }
        let old = path.replacingOccurrences(of: ".log", with: ".1.log")
        try? FileManager.default.removeItem(atPath: old)
        try? FileManager.default.moveItem(atPath: path, toPath: old)
        fflush(stdout)
        freopen(path, "a", stdout)
        freopen(path, "a", stderr)
    }

    /// Helper logs (tunnel, watcher): rotate before each launch.
    static func rotate(helperLog: String, maxBytes: UInt64 = 5_000_000) {
        let size = (try? FileManager.default.attributesOfItem(atPath: helperLog)[.size] as? UInt64) ?? 0
        guard size > maxBytes else { return }
        let old = helperLog.replacingOccurrences(of: ".log", with: ".1.log")
        try? FileManager.default.removeItem(atPath: old)
        try? FileManager.default.moveItem(atPath: helperLog, toPath: old)
    }
}
