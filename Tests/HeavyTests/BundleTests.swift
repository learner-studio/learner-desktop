import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// The RELEASE binary (as it ships), packaged and signed by build-app.sh
// (BUNDLE_ONLY: no install, no launchctl). The bundle must run, carry the tunnel script with
// the marker its helper is recognised by, keep the bundle id that TCC and the Pavlok
// settings are keyed to, and verify.
@Suite("App bundle (build-app.sh)", .tags(.heavy, .helpers), .quietLog, .serialized, .timeLimit(.minutes(2)),
       .enabled(if: ProcessInfo.processInfo.environment["LEARNER_HEAVY"] == "1", "heavy lane: set LEARNER_HEAVY=1"))
struct BundleTests {
    @Test func theScriptBuildsASignedRunnableBundle() throws {
        let out = TempDir("bundle")
        var env = ProcessInfo.processInfo.environment
        env["BUNDLE_ONLY"] = "1"
        env["OUT_DIR"] = out.path
        // The release binary scripts/test.sh built for this lane (else build-app.sh compiles it).
        if let release = env["LEARNER_RELEASE_BINARY"] { env["LEARNER_BINARY"] = release } else { env.removeValue(forKey: "LEARNER_BINARY") }
        let r = ChildProcess.run("/bin/bash", [toolsRepoRoot() + "/scripts/build-app.sh"], timeout: 110, env: env, stderr: true)
        #expect(r.status == 0, "\(r.output.suffix(600))")
        let app = out.file("Learner Desktop.app")
        let exe = app + "/Contents/MacOS/learner-desktop"
        #expect(FileManager.default.isExecutableFile(atPath: exe))
        let tunnel = try String(contentsOfFile: app + "/Contents/Resources/tunnel.sh", encoding: .utf8)
        #expect(tunnel.contains("3200:127.0.0.1:3200"))
        let info = try #require(NSDictionary(contentsOfFile: app + "/Contents/Info.plist"))
        #expect(info["CFBundleIdentifier"] as? String == "com.benpollack.ai-aggregator-menubar")
        #expect(info["CFBundleExecutable"] as? String == "learner-desktop")
        #expect(info["LSUIElement"] as? Bool == true)
        #expect((info["NSBluetoothAlwaysUsageDescription"] as? String)?.isEmpty == false)
        #expect(ChildProcess.run("/usr/bin/codesign", ["--verify", "--strict", app], timeout: 30).status == 0)
        let help = ChildProcess.run(exe, ["tool", "--help"], timeout: 30, stderr: true)
        #expect(help.status == 0 && help.output.contains("usage: learner-desktop tool"))
        #expect(!r.output.contains("Installing to"), "BUNDLE_ONLY must not install")
    }
}
