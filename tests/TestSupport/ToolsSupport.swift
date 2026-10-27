import Foundation

/// Lines a tool printed, for assertions.
public final class Printed: @unchecked Sendable {
    private let lock = NSLock()
    private var _out: [String] = []
    private var _err: [String] = []
    public init() {}
    public func out(_ s: String) { lock.withLock { _out.append(s) } }
    public func err(_ s: String) { lock.withLock { _err.append(s) } }
    public var stdout: String { lock.withLock { _out.joined(separator: "\n") } }
    public var stderr: String { lock.withLock { _err.joined(separator: "\n") } }
}

/// The repository root, from a test file's #filePath (Tests/<Lane>/<File>.swift).
public func toolsRepoRoot(_ file: String = #filePath) -> String {
    URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
}
