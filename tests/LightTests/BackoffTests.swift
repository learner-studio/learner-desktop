import Testing
@testable import LearnerDesktop

@Suite("Backoff") struct BackoffTests {
    @Test func doublesFromTheBaseUpToTheCap() {
        var b = Backoff(base: 10, max: 60, jitter: 0)
        #expect([b.failed(), b.failed(), b.failed(), b.failed()] == [10, 20, 40, 60])
        b.succeeded()
        #expect(b.failed() == 10)
    }
}
