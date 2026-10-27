import Foundation

/// A throwaway UserDefaults suite that never touches ~/Library/Preferences.
///
/// A suite named like "learner-coach-test-<uuid>" is a plist in ~/Library/Preferences, and
/// cfprefsd writes it back (empty) even after the domain is removed and the file deleted,
/// so every test run used to leave one behind. A suite whose name is an absolute path is
/// kept at that path instead: here, in a temp folder of its own, removed when the value
/// goes away or, for any still alive, when the test process exits.
// @unchecked: UserDefaults is thread-safe; the added fields are immutable.
public final class ScratchDefaults: UserDefaults, @unchecked Sendable {
    /// The suite name: an absolute path (CFPreferences adds ".plist").
    public let suite: String
    private let folder: String

    public init(_ label: String) {
        let id = UUID().uuidString
        folder = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/\(label)-\(id)"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        suite = folder + "/\(label)"
        ScratchDefaults.register(folder)
        super.init(suiteName: suite)!
    }

    deinit { ScratchDefaults.remove(folder) }

    /// Where the suite's values are stored.
    public var plistPath: String { suite + ".plist" }

    private static let lock = NSLock()
    // nonisolated(unsafe): both only touched under `lock`.
    nonisolated(unsafe) private static var live: Set<String> = []
    nonisolated(unsafe) private static var exitHook = false

    private static func register(_ folder: String) {
        lock.withLock {
            live.insert(folder)
            if !exitHook {
                exitHook = true
                atexit { ScratchDefaults.removeAll() }
            }
        }
    }

    private static func remove(_ folder: String) {
        lock.withLock { _ = live.remove(folder) }
        try? FileManager.default.removeItem(atPath: folder)
    }

    private static func removeAll() {
        for folder in lock.withLock({ live }) { remove(folder) }
    }
}
