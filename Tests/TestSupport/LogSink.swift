import Foundation

/// Bridges capturingLog to AppLog.sink: the test targets install the real hook
/// (LogSink.install) once, so TestSupport need not depend on the app module.
public enum LogSink {
    nonisolated(unsafe) public static var setter: (((String) -> Void)?) -> Void = { _ in }
    public static func set(_ sink: ((String) -> Void)?) { setter(sink) }
}
