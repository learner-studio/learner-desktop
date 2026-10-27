import Foundation

/// A fresh temp directory, removed when the value goes away (or by `cleanup()`). Its path
/// is resolved (/private/var/...), so it compares equal to a child process's `pwd`.
public final class TempDir: @unchecked Sendable {
    public let path: String

    public init(_ label: String = "learner") {
        let raw = NSTemporaryDirectory() + "\(label)-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        path = (raw as NSString).resolvingSymlinksInPath
    }

    deinit { cleanup() }
    public func cleanup() { try? FileManager.default.removeItem(atPath: path) }

    public func file(_ relative: String) -> String { path + "/" + relative }
    public func read(_ relative: String) -> String { (try? String(contentsOfFile: file(relative), encoding: .utf8)) ?? "" }
    public func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: file(relative)) }

    @discardableResult
    public func write(_ relative: String, _ text: String, executable: Bool = false, mode: Int? = nil) -> String {
        let full = file(relative)
        try? FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? text.write(toFile: full, atomically: true, encoding: .utf8)
        if let m = mode ?? (executable ? 0o755 : nil) {
            try? FileManager.default.setAttributes([.posixPermissions: m], ofItemAtPath: full)
        }
        return full
    }
}

/// Polls `condition` every 20 ms until it holds or `timeout` passes; true when it held.
@discardableResult
public func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return condition()
}

/// `waitFor` with the argument order the older tests use.
@discardableResult
public func eventually(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool { waitFor(timeout, condition) }

public func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

/// A pid written to a file by a test script.
public func pid(in path: String) -> pid_t? {
    (try? String(contentsOfFile: path, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

/// Captures app log lines for one test at a time (the log sink is process-wide and
/// suites run in parallel). Returns the lines written while `body` ran.
private let captureLock = NSLock()
public func capturingLog(_ body: () throws -> Void) rethrows -> [String] {
    captureLock.lock()
    defer { captureLock.unlock(); LogSink.set(nil) }
    let lines = LockedLines()
    LogSink.set { lines.append($0) }
    try body()
    return lines.all
}

public final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    public init() {}
    public func append(_ l: String) { lock.withLock { lines.append(l) } }
    public var all: [String] { lock.withLock { lines } }
}
