import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// `learner-desktop tool preflight` against a stand-in screenpipe.
//
// SAFETY: never touches the real capture stack. HOME is a temp directory holding a
// synthetic store.bin, PREFLIGHT_EXPECTED points at a temp expectations file,
// SCREENPIPE_API at a local HTTPStandIn and SCREENPIPE_APP at a bundle that does not
// exist (or, for the app-version checks, a fake bundle holding only an Info.plist). The live run is HeavyTests/CaptureLiveTests.

// nonisolated(unsafe): a constant fixture, never mutated.
nonisolated(unsafe) private let baseline: [String: Any] = ["transcriptionMode": "realtime", "audioChunkDuration": 5,
                                       "audioTranscriptionEngine": "whisper-large-v3-turbo-quantized", "autoUpdate": false]
private let rowOK = #"[{"id":1,"audio_chunk_id":2,"timestamp":"2026-09-09T00:00:00-04:00","start_time":0.5,"end_time":1.5,"file_path":"/x.mp4"}]"#

@Suite("Preflight (stand-in screenpipe)", .tags(.medium, .scripts, .tools), .timeLimit(.minutes(1)), .quietLog) struct ScriptsPreflightTests {

    func run(settings: [String: Any], expected: [String: Any] = baseline, pins: [String: Any] = [:],
             health: String? = #"{"status":"healthy","version":"0.4.50"}"#, rows: String = rowOK,
             appVersion: String? = nil) throws -> (status: Int32?, output: String, server: HTTPStandIn?) {
        let dir = TempDir("preflight")
        defer { dir.cleanup() }
        dir.write(".screenpipe/store.bin", Tools.json(["settings": settings]))
        var exp = pins
        exp["settings"] = expected
        let expFile = dir.write("expected.json", Tools.json(exp))
        var server: HTTPStandIn?
        var api = "http://127.0.0.1:9"   // nothing listens: unreachable
        if let health = health {
            let s = try HTTPStandIn { req in
                HTTPStandIn.Response(status: 200, body: Data((req.path == "/raw_sql" ? rows : health).utf8))
            }
            server = s
            api = s.baseURL
        }
        defer { server?.stop() }
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = dir.path
        env["PREFLIGHT_EXPECTED"] = expFile
        env["SCREENPIPE_API"] = api
        env["SCREENPIPE_APP"] = dir.file("no-such.app")
        if let appVersion = appVersion {
            let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": appVersion], format: .xml, options: 0)
            dir.write("fake-screenpipe.app/Contents/Info.plist", String(decoding: info, as: UTF8.self))
            env["SCREENPIPE_APP"] = dir.file("fake-screenpipe.app")
        }
        let r = ChildProcess.run(appBinary, ["tool", "preflight"], timeout: 60, env: env, stderr: true)
        return (r.status, r.output, server)
    }

    @Test func passesWhenLiveSettingsMatchTheCommittedExpectations() throws {
        let r = try run(settings: baseline)
        #expect(r.status == 0, "\(r.output)")
        // It asked the stand-in, not the real :3030.
        #expect(r.server?.requests.map(\.path).contains("/raw_sql") == true)
    }

    @Test func failsWhenTranscriptionSilentlyRevertsToBatch() throws {
        var drifted = baseline
        drifted["transcriptionMode"] = "batch"
        let r = try run(settings: drifted)
        #expect(r.status == 1 && r.output.contains("transcriptionMode") && r.output.contains("batch"))
    }

    @Test func failsWhenAGuardedSettingDisappears() throws {
        var missing = baseline
        missing["audioChunkDuration"] = nil
        let r = try run(settings: missing)
        #expect(r.status == 1 && r.output.contains("audioChunkDuration"))
    }

    @Test func reportsUnreachableScreenpipeSeparatelyFromDrift() throws {
        let r = try run(settings: baseline, health: nil)
        #expect(r.status == 2 && r.output.contains("not answering"), "\(r.output)")
    }

    @Test func failsWhenTheRawSQLShapeTheAppPollsBreaks() throws {
        let r = try run(settings: baseline, rows: #"{"error":"no such column: start_time"}"#)
        #expect(r.status == 1 && r.output.contains("raw_sql"))
    }

    @Test func aMovedEngineVersionIsAPhaseBoundary() throws {
        let moved = try run(settings: baseline, pins: ["_screenpipe_engine_version": "0.4.49"])
        #expect(moved.status == 1 && moved.output.contains("version changed") && moved.output.contains("phase boundary"))
        let pinned = try run(settings: baseline, pins: ["_screenpipe_engine_version": "0.4.50"])
        #expect(pinned.status == 0, "\(pinned.output)")
    }

    @Test func aMovedAppVersionIsAPhaseBoundary() throws {
        let moved = try run(settings: baseline, pins: ["_screenpipe_app_version": "2.0.1"], appVersion: "2.1.0")
        #expect(moved.status == 1, "\(moved.output)")
        #expect(moved.output.contains("screenpipe app version changed: pinned 2.0.1, installed 2.1.0"), "\(moved.output)")
        let pinned = try run(settings: baseline, pins: ["_screenpipe_app_version": "2.0.1"], appVersion: "2.0.1")
        #expect(pinned.status == 0, "\(pinned.output)")
        #expect(pinned.output.contains("screenpipe app version 2.0.1 (pinned)"), "\(pinned.output)")
    }

    @Test func redactedExpectationsAreIgnoredRatherThanReportedAsDrift() throws {
        var expected = baseline
        expected["deepgramApiKey"] = "***REDACTED***"
        #expect(try run(settings: baseline, expected: expected).status == 0)
        var live = baseline
        live["deepgramApiKey"] = "fixture-value"
        #expect(try run(settings: live).status == 0)
    }
}
