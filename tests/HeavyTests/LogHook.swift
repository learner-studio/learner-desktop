import Foundation
@testable import LearnerDesktop
import TestSupport

/// TestSupport.capturingLog, wired to the app's log (TestSupport cannot import the app).
@discardableResult
func capturingLog(_ body: () throws -> Void) rethrows -> [String] {
    LogSink.setter = { AppLog.sink = $0 }
    return try TestSupport.capturingLog(body)
}
