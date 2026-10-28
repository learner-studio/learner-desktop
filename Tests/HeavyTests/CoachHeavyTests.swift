import AppKit
import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// The coach against the live machine. Read-only towards screenpipe; the wristband only
// with explicit consent. Each test skips, with its reason, when its dependency is missing.

private let env = ProcessInfo.processInfo.environment
private let heavy = env["LEARNER_HEAVY"] == "1"
private let screenpipe = URL(string: env["SCREENPIPE_API"] ?? "http://localhost:3030")!
private let installedApp = NSHomeDirectory() + "/Applications/Learner Desktop.app"
/// The installed bundle keeps its pre-rename identifier (TCC grants and settings).
private let appDomain = "com.benpollack.ai-aggregator-menubar"

private func screenpipeUp() async -> Bool {
    var req = URLRequest(url: screenpipe.appendingPathComponent("health"))
    req.timeoutInterval = 3
    return ((try? await URLSession.shared.data(for: req))?.1 as? HTTPURLResponse)?.statusCode == 200
}

private func defaultsValue(_ key: String) -> String? {
    let r = ChildProcess.run("/usr/bin/defaults", ["read", appDomain, key], timeout: 10)
    return r.ok ? r.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
}

@MainActor
final class SilentWearable: Wearable {
    var isEnabled = false
    func send(_ m: Modality, intensity: Int, reason: String, context: StimulusContext,
              completion: @escaping @MainActor (StimulusResult) -> Void) { completion(.notSent("heavy test")) }
}

@MainActor
final class TimedToast: CoachToast {
    var firstShown: Date?
    func show(streak: TimeInterval, callApp: String?) { firstShown = firstShown ?? Date() }
    func hide() {}
}

func heavyLogger() -> (HabitEventLogger, String) {
    // By path, not through LEARNER_OUTBOX_DB: changing the process environment races with
    // other suites, and a logger made in that window could open another test's database
    // (or the owner's real one).
    let path = NSTemporaryDirectory() + "coach-heavy-\(UUID().uuidString).sqlite"
    return (HabitEventLogger(path: path), path)
}

@MainActor
private func waitFor(_ seconds: Double, until condition: () -> Bool = { false }) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
}

@Suite("Coach, heavy: live screenpipe and wristband", .tags(.heavy, .coach), .timeLimit(.minutes(2)), .quietLog, .enabled(if: heavy, "heavy lane: set LEARNER_HEAVY=1 (scripts/test.sh heavy)"))
struct CoachHeavyTests {
    /// Every query the coach makes is answered by the installed screenpipe, every timestamp
    /// parses, and the first poll only sets the watermark -- history is never replayed.
    @MainActor
    @Test(.enabled("screenpipe is not answering on \(screenpipe)") { await screenpipeUp() })
    func liveScreenpipeAnswersEveryCoachQuery() async {
        let api = ScreenpipeAPI(base: screenpipe, timeout: 5)
        let source = ScreenpipeSpeechSource(api: api)
        var spans: [SpeechSpan] = []
        let began = Date()
        source.poll(now: Date()) { spans += $0 }
        await waitFor(6) { source.live.watermark != nil && source.background.watermark != nil }
        #expect(source.live.watermark != nil && source.background.watermark != nil, "failures: \(api.failures)")
        #expect(spans.isEmpty)

        for stream in [source.live, source.background] {
            let mark = max(0, (stream.watermark ?? 0) - 200)
            var rows: [[String: Any]] = []
            api.sql("heavy \(stream.name)", stream.page(mark)) { rows = $0 }
            await waitFor(6) { !rows.isEmpty || api.failures["heavy \(stream.name)"] != nil }
            #expect(api.failures["heavy \(stream.name)"] == nil, "\(stream.table) page query failed")
            let stamp = stream === source.live ? "captured_at" : "timestamp"
            for row in rows {
                #expect(ScreenpipeSpeechSource.parseDate(row[stamp] as? String ?? "") != nil, "unparsable \(stamp): \(row[stamp] ?? "nil")")
            }
            if stream === source.background, let row = rows.first {
                for column in ["id", "audio_chunk_id", "transcription", "timestamp", "start_time", "end_time", "file_path"] {
                    #expect(row[column] != nil, "audio_transcriptions page lacks \(column)")
                }
            }
        }

        // A second poll delivers only speech from now on.
        source.poll(now: Date()) { spans += $0 }
        await waitFor(3)
        #expect(spans.allSatisfy { $0.start > began.addingTimeInterval(-120) }, "replayed history: \(spans.map(\.label))")

        var call: CallPoll?
        ScreenpipeCallSource(api: api).poll { call = $0 }
        await waitFor(6) { call != nil }
        if case .answered = call {} else { Issue.record("/meetings did not answer: \(String(describing: call))") }
    }

    /// The whole coach on the live screenpipe for a few seconds: nothing fails, no turn
    /// from before the start is written.
    @MainActor
    @Test(.enabled("screenpipe is not answering on \(screenpipe)") { await screenpipeUp() })
    func theCoachRunsOnLiveScreenpipe() async {
        let api = ScreenpipeAPI(base: screenpipe, timeout: 2)
        let (logger, _) = heavyLogger()
        let settings = CoachSettings(defaults: ScratchDefaults("coach-heavy"))
        let coach = SpeakingCoach(settings: settings, speech: ScreenpipeSpeechSource(api: api), calls: ScreenpipeCallSource(api: api),
                                  wearable: SilentWearable(), toast: TimedToast(), logger: logger)
        for _ in 0..<5 {
            coach.tick()
            await waitFor(1)
        }
        #expect(api.failures.isEmpty, "\(api.failures)")
        #expect(coach.currentStreak < 10, "a streak of \(coach.currentStreak) s after 5 s means history was replayed")
        coach.resetStreak()
        logger.close()
    }

    /// The toast really appears, and screen sharing cannot capture it.
    @MainActor
    @Test(.enabled(if: !LiveMachine.displayAsleep, "the display is asleep: nothing can be shown"))
    func theToastIsVisibleAndHiddenFromScreenSharing() async {
        _ = NSApplication.shared
        let toast = MonologueToastController()
        toast.show(streak: 35, callApp: "Heavy test")
        // Waited for, not slept on: the 0.25 s fade runs late under the pre-push load.
        await waitFor(3) { (toast.panel?.alphaValue ?? 0) > 0.9 }
        #expect(toast.panel?.isVisible == true)
        #expect(toast.panel?.sharingType == NSWindow.SharingType.none)
        #expect((toast.panel?.alphaValue ?? 0) > 0.9)
        toast.hide()
        await waitFor(3) { toast.panel?.isVisible == false }
        #expect(toast.panel?.isVisible == false)
    }

    /// The installed bundle carries the Bluetooth usage strings, or macOS kills it the
    /// moment it creates a CBCentralManager.
    @Test(.enabled("no installed app at \(installedApp)") { FileManager.default.fileExists(atPath: installedApp) })
    func theInstalledBundleCanAskForBluetooth() throws {
        let plist = try #require(NSDictionary(contentsOfFile: installedApp + "/Contents/Info.plist"))
        for key in ["NSBluetoothAlwaysUsageDescription", "NSBluetoothPeripheralUsageDescription"] {
            #expect(!((plist[key] as? String) ?? "").isEmpty, "\(key) is missing")
        }
    }

    /// One 25% vibration -- never a zap -- through the installed app, verified from its log.
    @Test(.enabled("fires the wristband: set LEARNER_HEAVY_PAVLOK=1") { env["LEARNER_HEAVY_PAVLOK"] == "1" },
          .enabled("no paired wristband (pavlok_last_device_id unset)") { defaultsValue("pavlok_last_device_id") != nil },
          .enabled("no installed app at \(installedApp)") { FileManager.default.fileExists(atPath: installedApp) })
    func aTestVibrationReachesTheWristband() async throws {
        let modality = Modality.vibe     // a test suite never shocks a person
        let enabledBefore = defaultsValue("pavlok_shock_enabled")
        let levelBefore = defaultsValue("pavlok_test_vibe_intensity")
        let log = AppLog.path
        let mark = (try? FileManager.default.attributesOfItem(atPath: log)[.size] as? UInt64) ?? 0
        let opened = ChildProcess.run("/usr/bin/open", ["-n", "-a", installedApp, "--args", "--pavlok-test-fire", modality.rawValue, "25", "--wait", "20"], timeout: 30)
        #expect(opened.ok, "open failed: \(opened.output)")
        var lines: [String] = []
        let deadline = Date().addingTimeInterval(75)
        while Date() < deadline {
            let h = FileHandle(forReadingAtPath: log)
            try? h?.seek(toOffset: mark)
            let text = String(decoding: h?.readDataToEndOfFile() ?? Data(), as: UTF8.self)
            try? h?.close()
            lines = text.split(separator: "\n").map(String.init).filter { $0.contains("Pavlok") }
            if lines.contains(where: { $0.contains("DELIVERED") || $0.contains("FAILED") }) { break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        let verdict = try #require(lines.first { $0.contains("DELIVERED") || $0.contains("FAILED") }, "no verdict:\n\(lines.joined(separator: "\n"))")
        #expect(verdict.contains("DELIVERED"), "wake the band, keep it in range, re-run:\n\(lines.joined(separator: "\n"))")
        #expect(verdict.contains("BLE acknowledged by wristband"))
        #expect(verdict.contains("25%"))
        #expect(!lines.contains { $0.lowercased().contains("zap") || $0.contains("SHOCK") })
        #expect(defaultsValue("pavlok_shock_enabled") == enabledBefore)
        #expect(defaultsValue("pavlok_test_vibe_intensity") == levelBefore)
    }
}
