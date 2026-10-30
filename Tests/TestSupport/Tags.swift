import Testing

// Every suite carries its lane and the workflow(s) it covers. Xcode's test navigator and
// test plans group and filter by these; `swift test --filter` matches names only, so the
// lanes stay split by test target (what scripts/test.sh filters on).
public extension Tag {
    // Lanes (one per test target).
    @Tag static var light: Self
    @Tag static var medium: Self
    @Tag static var heavy: Self

    // Workflows.
    /// Job, Scheduler, ChildProcess, Log: the primitives every workflow uses.
    @Tag static var core: Self
    @Tag static var coach: Self
    @Tag static var outbox: Self
    /// Chat export -> voice transcripts -> archive.
    @Tag static var chats: Self
    @Tag static var status: Self
    @Tag static var helpers: Self
    @Tag static var shutdown: Self
    @Tag static var tools: Self
    @Tag static var scripts: Self
    @Tag static var sessions: Self
    /// Mastery notifications: the feed job, the toast, the tray lines.
    @Tag static var mastery: Self
}
