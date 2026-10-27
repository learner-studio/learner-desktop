import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

/// TestSupport.capturingLog, wired to the app's log (TestSupport cannot import the app).
@discardableResult
func capturingLog(_ body: () throws -> Void) rethrows -> [String] {
    LogSink.setter = { AppLog.sink = $0 }
    return try TestSupport.capturingLog(body)
}

/// TestSupport.silenceUncapturedLog, wired to the app's log.
func silenceUncapturedLog() {
    LogSink.setter = { AppLog.sink = $0 }
    TestSupport.silenceUncapturedLog()
}

/// A suite whose app log lines (a fixture's warnings, a job's progress) stay out of the
/// lane output, which then shows only test results. capturingLog still sees them.
struct QuietLog: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        silenceUncapturedLog()
        try await function()
    }
}

extension Trait where Self == QuietLog {
    static var quietLog: Self { QuietLog() }
}
