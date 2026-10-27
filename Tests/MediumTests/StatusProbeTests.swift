import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// The status workflow against stand-ins for screenpipe and learner-server over real HTTP.
@Suite("Status probe", .quietLog, .serialized) struct StatusProbeTests {

    @Test func recordingDegradedAndStoppedScreenpipe() throws {
        var health: [String: Any] = ["status": "healthy", "frame_status": "ok", "audio_status": "ok", "version": "9.9.9"]
        let screenpipe = try HTTPStandIn { req in
            req.path == "/health" ? HTTPStandIn.Response.json(200, health) : HTTPStandIn.Response.json(200, [:])
        }
        let saved = StatusProbe.screenpipeURL
        StatusProbe.screenpipeURL = screenpipe.baseURL
        defer { StatusProbe.screenpipeURL = saved; screenpipe.stop() }

        #expect(StatusProbe.screenpipe() == .recording)
        #expect(CaptureEnvironment.screenpipeVersion == "9.9.9")
        health = ["status": "degraded", "frame_status": "ok", "audio_status": "stalled"]
        #expect(StatusProbe.screenpipe() == .degraded("vision ok, audio stalled"))
        screenpipe.stop()
        if case .stopped = StatusProbe.screenpipe() {} else { Issue.record("a closed port must read as stopped") }
    }

    @Test func noActiveAudioDevicesRestartsThemAndLogsFailures() throws {
        let screenpipe = try HTTPStandIn { req in
            if req.path == "/health" {
                return HTTPStandIn.Response.json(200, ["status": "healthy", "capture_status": ["active_audio_devices": 0]])
            }
            return HTTPStandIn.Response.json(500, ["success": false, "message": "capture is gated or the stream is unavailable"])
        }
        let saved = StatusProbe.screenpipeURL
        StatusProbe.screenpipeURL = screenpipe.baseURL
        StatusProbe.resetAudioRestart()
        defer { StatusProbe.screenpipeURL = saved; screenpipe.stop(); StatusProbe.resetAudioRestart() }
        var capture: AppStatus.Capture = .unknown
        let lines = capturingLog { capture = StatusProbe.screenpipe() }
        let starts = { screenpipe.requests.filter { $0.path == "/audio/device/start" && $0.method == "POST" }.count }
        #expect(starts() == StatusProbe.audioDevices.count)
        #expect(lines.filter { $0.contains("could not start") && $0.contains("capture is gated") }.count == StatusProbe.audioDevices.count)
        #expect(capture == .degraded("no audio devices recording"))
        // Refused: the next check (8 s later in the app) does not try again; it backs off.
        _ = capturingLog { _ = StatusProbe.screenpipe() }
        #expect(starts() == StatusProbe.audioDevices.count)
    }

    @Test func screenpipeWaitingForSpeechIsRecording() throws {
        let screenpipe = try HTTPStandIn { req in
            req.path == "/health"
                ? HTTPStandIn.Response.json(200, ["status": "healthy", "capture_status": [
                    "status": "ready", "severity": "waiting", "active_audio_devices": 0,
                    "reason": "audio capture is ready and waiting for speech"]])
                : HTTPStandIn.Response.json(500, [:])
        }
        let saved = StatusProbe.screenpipeURL
        StatusProbe.screenpipeURL = screenpipe.baseURL
        StatusProbe.resetAudioRestart()
        defer { StatusProbe.screenpipeURL = saved; screenpipe.stop() }
        #expect(StatusProbe.screenpipe() == .recording)
        #expect(!screenpipe.requests.contains { $0.path == "/audio/device/start" })
    }

    @Test func aScreenpipePausedOnPurposeIsShownNotFought() throws {
        let screenpipe = try HTTPStandIn { req in
            req.path == "/health"
                ? HTTPStandIn.Response.json(200, ["status": "healthy", "capture_status": [
                    "status": "screen_locked", "severity": "waiting", "active_audio_devices": 0,
                    "reason": "audio capture is paused while the screen is locked"]])
                : HTTPStandIn.Response.json(500, [:])
        }
        let saved = StatusProbe.screenpipeURL
        StatusProbe.screenpipeURL = screenpipe.baseURL
        StatusProbe.resetAudioRestart()
        defer { StatusProbe.screenpipeURL = saved; screenpipe.stop() }
        let capture = StatusProbe.screenpipe()
        #expect(capture == .degraded("paused: audio capture is paused while the screen is locked"))
        #expect(!screenpipe.requests.contains { $0.path == "/audio/device/start" })
    }

    @Test func collectReportsServerJobAndHelperProblems() throws {
        let screenpipe = try HTTPStandIn { _ in HTTPStandIn.Response.json(200, ["status": "healthy"]) }
        let server = try HTTPStandIn { _ in HTTPStandIn.Response.json(503, [:]) }
        let vault = TempDir("vault")
        for id in ["a", "b", "c"] { _ = vault.write("chatgpt/conversations/\(id)/conversation.md", "# t") }
        _ = vault.write("claude/conversations/x/conversation.md", "# t")
        let saved = (StatusProbe.screenpipeURL, StatusProbe.serverHealthURL, StatusProbe.vaultRoot)
        StatusProbe.screenpipeURL = screenpipe.baseURL
        StatusProbe.serverHealthURL = server.baseURL + "/api/health"
        StatusProbe.vaultRoot = vault.path
        defer {
            (StatusProbe.screenpipeURL, StatusProbe.serverHealthURL, StatusProbe.vaultRoot) = saved
            screenpipe.stop(); server.stop(); vault.cleanup()
        }
        let dir = TempDir("helpers")
        defer { dir.cleanup() }
        let downHelper = ManagedHelper(name: "down", executable: "/bin/true", arguments: [], marker: "x", runtimeDir: dir.path)
        let s = StatusProbe.collect(previous: AppStatus(), helpers: [downHelper], appAgentPlist: dir.file("none.plist"))
        #expect(s.capture == .recording)
        #expect(!s.serverReachable)
        #expect(s.chatgptChats == 3 && s.claudeChats == 1)
        #expect(s.problems.contains(Problem(source: "Helper:down", text: "down is not running")))
        #expect(TrayState.make(s, coach: CoachLive()).kind == "server")
    }
}
