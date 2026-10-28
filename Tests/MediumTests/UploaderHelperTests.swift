import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// The uploader under the app's supervisor, with a stand-in uploader script: the key
// reaches it through the environment and never its log; exit 3 (another copy holds the
// lock) is waited out quietly; exit 2 (config error) is a problem; restarts wait.
@Suite("Uploader helper", .tags(.medium, .sessions, .helpers), .serialized, .quietLog, .timeLimit(.minutes(1))) struct UploaderHelperTests {
    func helper(_ dir: TempDir, exit code: Int, wait: TimeInterval = 0.5) -> ManagedHelper {
        let script = dir.write("uploader.sh", """
            #!/bin/bash
            echo "launch" >> "\(dir.file("launches"))"
            [ -n "$LEARNER_API_KEY" ] && echo "key=present" >> "\(dir.file("env"))"
            echo "client=$LEARNER_CLIENT_ID" >> "\(dir.file("env"))"
            echo "uploader started"
            exit \(code)
            """, executable: true)
        return ManagedHelper(name: "uploader-test", executable: script, arguments: [], marker: "uploader.sh", runtimeDir: dir.path,
                             environment: { ["LEARNER_API_KEY": "secret-test-key", "LEARNER_CLIENT_ID": "ben-mbp"] },
                             minRestart: wait,
                             exitRules: [2: .init(note: "config error", wait: wait, isProblem: true),
                                         3: .init(note: "another uploader is already running", wait: wait, isProblem: false)])
    }

    @Test func theKeyArrivesInTheEnvironmentAndNeverInTheLog() {
        let dir = TempDir()
        let h = helper(dir, exit: 0)
        DispatchQueue.main.sync { h.start() }
        #expect(waitFor(3) { dir.read("env").contains("key=present") })
        #expect(dir.read("env").contains("client=ben-mbp"))
        h.stop(grace: 0.5)
        #expect(!dir.read("logs/uploader-test.log").contains("secret-test-key"))
        #expect(dir.read("logs/uploader-test.log").contains("uploader started"))
    }

    @Test func anotherUploaderRunningIsNotAProblemAndNotACrashLoop() {
        let dir = TempDir()
        let h = helper(dir, exit: 3, wait: 0.4)
        DispatchQueue.main.sync { h.start() }
        Thread.sleep(forTimeInterval: 1.0)
        let launches = dir.read("launches").split(separator: "\n").count
        #expect((2...3).contains(launches), "launched \(launches) times in 1 s with a 0.4 s wait")
        #expect(h.problem == nil || h.isRunning)
        h.stop(grace: 0.5)
    }

    @Test func aConfigErrorIsShownAsAProblem() {
        let dir = TempDir()
        let h = helper(dir, exit: 2, wait: 5)
        DispatchQueue.main.sync { h.start() }
        #expect(waitFor(3) { h.problem?.contains("config error") == true })
        h.stop(grace: 0.5)
    }
}
