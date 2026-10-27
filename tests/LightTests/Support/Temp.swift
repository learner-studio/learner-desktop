import Foundation

/// A fresh temp directory per test, removed by the caller with `cleanup()`.
struct TempDir {
    let path: String
    init(_ label: String = "learner") {
        path = NSTemporaryDirectory() + "\(label)-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    func file(_ name: String) -> String { path + "/" + name }
    func write(_ name: String, _ text: String, executable: Bool = false) -> String {
        let f = file(name)
        try? FileManager.default.createDirectory(atPath: (f as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: f, contents: Data(text.utf8),
                                       attributes: executable ? [.posixPermissions: 0o755] : nil)
        return f
    }
    func cleanup() { try? FileManager.default.removeItem(atPath: path) }
}

/// Polls until `condition` holds or `timeout` passes; true when it held.
func eventually(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(20_000)
    }
    return condition()
}
