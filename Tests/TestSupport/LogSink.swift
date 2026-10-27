import Foundation

/// Bridges capturingLog to AppLog.sink: the test targets install the real hook
/// (LogSink.install) once, so TestSupport need not depend on the app module.
public enum LogSink {
    // nonisolated(unsafe): each test target assigns it once, before its first capture.
    nonisolated(unsafe) public static var setter: ((@Sendable (String) -> Void)?) -> Void = { _ in }
    public static func set(_ sink: (@Sendable (String) -> Void)?) { setter(sink) }
}
