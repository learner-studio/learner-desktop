import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// The RELEASE binary (as it ships), packaged and signed by build-app.sh
// (BUNDLE_ONLY: no install, no launchctl). The bundle must run, carry no tunnel script (the
// tunnel is retired), keep the bundle id that TCC and the Pavlok
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
        #expect(!FileManager.default.fileExists(atPath: app + "/Contents/Resources/tunnel.sh"))
        let info = try #require(NSDictionary(contentsOfFile: app + "/Contents/Info.plist"))
        #expect(info["CFBundleIdentifier"] as? String == "com.benpollack.ai-aggregator-menubar")
        #expect(info["CFBundleExecutable"] as? String == "learner-desktop")
        #expect(info["LSUIElement"] as? Bool == true)
        #expect((info["NSBluetoothAlwaysUsageDescription"] as? String)?.isEmpty == false)
        // The speech detector: its model ships in the bundle, and macOS can ask for the mic.
        #expect((info["NSMicrophoneUsageDescription"] as? String)?.isEmpty == false)
        #expect(FileManager.default.fileExists(atPath: app + "/Contents/Resources/silero-vad.mlmodelc/model.mil"))
        #expect(ChildProcess.run("/usr/bin/codesign", ["--verify", "--strict", app], timeout: 30).status == 0)
        // The microphone + Silero, started from the signed bundle exactly as the app does: a
        // callback that traps on AVAudio's thread (10-27) fails here, not in the owner's tray.
        // Launched through LaunchServices (open), so macOS checks the app's own microphone
        // grant (a binary started directly is attributed to its parent, the test runner).
        // The self-test opens the real microphone for a few seconds. Not during a call, and not
        // on a Bluetooth input: a second app on AirPods' mic flips them into call mode.
        if let why = Self.micBusy() {
            print("speech self-test skipped: \(why)")
        } else {
            selfTest(app: app, out: out)
        }
        let help = ChildProcess.run(exe, ["tool", "--help"], timeout: 30, stderr: true)
        #expect(help.status == 0 && help.output.contains("usage: learner-desktop tool"))
        #expect(!r.output.contains("Installing to"), "BUNDLE_ONLY must not install")
    }

    /// Why the microphone must be left alone now, or nil.
    static func micBusy() -> String? {
        if MicSpeechSource.defaultInputIsBluetooth() { return "the input is Bluetooth" }
        let r = ChildProcess.run("/usr/bin/curl", ["-s", "-m", "3", "http://localhost:3030/meetings"], timeout: 5)
        if let meetings = (try? JSONSerialization.jsonObject(with: Data(r.output.utf8))) as? [[String: Any]],
           meetings.contains(where: { !($0["meeting_end"] is String) }) { return "a meeting is on" }
        return nil
    }

    func selfTest(app: String, out: TempDir) {
        defer {
            // `open` registered this temporary copy under the app's bundle id: forget it.
            _ = ChildProcess.run("/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister",
                                 ["-u", app], timeout: 15)
        }
        let selftest = out.file("speech-selftest.txt")
        let launched = ChildProcess.run("/usr/bin/open", ["-n", "-W", "--stdout", selftest, "--stderr", selftest, app,
                                                          "--args", "tool", "speech-selftest"], timeout: 40, stderr: true)
        let said = (try? String(contentsOfFile: selftest, encoding: .utf8)) ?? ""
        #expect(launched.ok && said.range(of: #"speech-selftest: ([5-9][0-9]|[1-9][0-9]{2,}) frames scored"#, options: .regularExpression) != nil,
                "speech self-test: \(said.isEmpty ? launched.output : said)")
    }
}
