import Foundation

/// A fresh temp directory per test, removed by the caller with `cleanup()`.
public struct TempDir {
    public let path: String
    public init(_ label: String = "learner") {
        path = NSTemporaryDirectory() + "\(label)-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    public func file(_ name: String) -> String { path + "/" + name }
    @discardableResult
    public func write(_ name: String, _ text: String, executable: Bool = false) -> String {
        let f = file(name)
        try? FileManager.default.createDirectory(atPath: (f as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: f, contents: Data(text.utf8),
                                       attributes: executable ? [.posixPermissions: 0o755] : nil)
        return f
    }
    public func cleanup() { try? FileManager.default.removeItem(atPath: path) }
}

/// Polls until `condition` holds or `timeout` passes; true when it held.
public func eventually(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(20_000)
    }
    return condition()
}

/// Captures app log lines for one test at a time (the log sink is process-wide, and
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
