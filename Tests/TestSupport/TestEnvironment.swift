import Foundation

/// Where the tests are running, set by the scripts and never guessed: LEARNER_TEST_ENV=runner
/// on the GitHub runner (scripts/ci.sh), otherwise the owner's Mac. Every lane prints it
/// (scripts/test.sh), and a suite that needs the owner's live machine names it when it skips.
public enum TestEnvironment: String, Sendable {
    /// A clean, throwaway GitHub macOS runner: the app, a virtual microphone, fixtures and
    /// snapshots; no owner accounts, logins or live data.
    case runner
    /// The owner's Mac: the live screenpipe, ai-vault and logins.
    case mac

    public static let current: TestEnvironment =
        ProcessInfo.processInfo.environment["LEARNER_TEST_ENV"] == "runner" ? .runner : .mac

    public static var isRunner: Bool { current == .runner }
}
