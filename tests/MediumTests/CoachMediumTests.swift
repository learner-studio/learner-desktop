import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

/// The built app binary, from `swift build --show-bin-path` in this package.
private func builtApp() throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["swift", "build", "--show-bin-path"]
    p.currentDirectoryURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    let bin = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return bin + "/LearnerDesktop"
}

@Suite("Coach, medium: the real binary and a local screenpipe") struct CoachMediumTests {
    /// Every malformed invocation dies on the argument check: exit 2 with the usage, and
    /// nothing reaches CoreBluetooth (which would also get an unsigned binary killed by TCC).
    @Test func testFireRejectsBadArgumentsBeforeTouchingBluetooth() throws {
        let app = try builtApp()
        #expect(FileManager.default.isExecutableFile(atPath: app), "not built: \(app)")
        let bad: [[String]] = [[], ["punch"], ["ZAPP"], ["shock"], [""], ["vibe", "0"], ["vibe", "-5"], ["vibe", "101"],
                               ["vibe", "banana"], ["vibe", "20", "--wait", "0"], ["vibe", "20", "--wait", "999999"],
                               ["vibe", "20", "--wait", "soon"], ["vibe", "20", "--wait"]]
        for args in bad {
            let r = ChildProcess.run(app, ["--pavlok-test-fire"] + args, timeout: 20, stderr: true)
            #expect(r.status == 2, "\(args) was accepted: \(r.output)")
            #expect(r.output.contains("usage: --pavlok-test-fire <vibe|beep|zap>"))
            #expect(!r.output.contains("radio state") && !r.output.contains("scanning"))
        }
    }

    /// Real URLSession against a stand-in: the call is found, speech becomes a trial row,
    /// a short outage keeps the call (and is logged and counted), a long one ends it.
    @MainActor
    @Test func thePollerFollowsACallThroughAnOutage() async throws {
        let data = FakeScreenpipeData()
        data.meetings = [["meeting_app": "Zoom", "title": "Planning", "meeting_end": NSNull()]]
        let server = try StandInServer { req in StandInServer.json(200, data.answer(req.path, req.body)) }
        defer { server.stop() }
        let api = ScreenpipeAPI(base: server.baseURL, timeout: 0.5)
        let (logger, db) = scratchLogger()
        let settings = CoachSettings(defaults: UserDefaults(suiteName: "coach-medium-\(UUID().uuidString)")!)
        let coach = SpeakingCoach(settings: settings, speech: ScreenpipeSpeechSource(api: api), calls: ScreenpipeCallSource(api: api),
                                  wearable: QuietWearable(), toast: QuietToast(), logger: logger)
        coach.callOutageGrace = 2.5

        #expect(await tick(coach, until: { coach.activeCallApp == "Zoom" }, within: 3))
        let session = coach.activeSessionId
        #expect(session.hasPrefix("call_zoom_"))

        // Ten seconds of my speech, then someone else: one turn of 9 s (live rows carry start times).
        let start = Date().addingTimeInterval(-12)
        let fmt = ISO8601DateFormatter()
        for i in 0..<10 {
            data.addLive(["id": i + 1, "device_type": "input", "transcript": "this is sentence number \(i) of the plan",
                          "captured_at": fmt.string(from: start.addingTimeInterval(Double(i)))])
        }
        data.addLive(["id": 11, "device_type": "output", "transcript": "sounds good to me",
                      "captured_at": fmt.string(from: start.addingTimeInterval(10))])
        #expect(await tick(coach, until: { logger.waitUntilIdle(); return !turnDurations(db).isEmpty }, within: 3))
        #expect(turnDurations(db) == [9])

        server.mode = .refuse
        #expect(await tick(coach, until: { (api.failures["meetings"] ?? 0) >= 2 }, within: 2))
        #expect(coach.activeCallApp == "Zoom")
        #expect(coach.activeSessionId == session)
        server.mode = .answer
        #expect(await tick(coach, until: { api.failures["meetings"] == nil }, within: 2))
        #expect(coach.activeSessionId == session)

        server.mode = .refuse
        #expect(await tick(coach, until: { coach.activeCallApp == nil }, within: 5))
        #expect(coach.activeSessionId.hasPrefix("solo_"))
    }

    /// A screenpipe that accepts and never answers: each poll times out, and polls never stack.
    @MainActor
    @Test func aStuckScreenpipeTimesOutAndPollsDoNotPileUp() async throws {
        let server = try StandInServer { _ in StandInServer.json(200, [Any]()) }
        defer { server.stop() }
        server.mode = .hang
        let api = ScreenpipeAPI(base: server.baseURL, timeout: 0.6)
        let calls = ScreenpipeCallSource(api: api)
        var answers: [CallPoll] = []
        let began = Date()
        while Date().timeIntervalSince(began) < 1.5 {
            calls.poll { answers.append($0) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        // ~30 asks in 1.5 s, but only one request per 0.6 s timeout.
        #expect((api.requests["meetings"] ?? 0) <= 3)
        #expect((api.failures["meetings"] ?? 0) >= 1)
        #expect(answers.allSatisfy { if case .failed = $0 { return true } else { return false } })
    }

    /// Nothing listening at all: every poll fails fast, is counted, and the coach carries on.
    @MainActor
    @Test func screenpipeDownIsCountedAndHarmless() async throws {
        let gone = try StandInServer { _ in StandInServer.json(200, [Any]()) }
        let url = gone.baseURL
        gone.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        let api = ScreenpipeAPI(base: url, timeout: 0.5)
        let (logger, _) = scratchLogger()
        let coach = SpeakingCoach(settings: CoachSettings(defaults: UserDefaults(suiteName: "coach-medium-\(UUID().uuidString)")!),
                                  speech: ScreenpipeSpeechSource(api: api), calls: ScreenpipeCallSource(api: api),
                                  wearable: QuietWearable(), toast: QuietToast(), logger: logger)
        #expect(await tick(coach, until: { (api.failures["live transcripts"] ?? 0) >= 3 && (api.failures["meetings"] ?? 0) >= 3 }, within: 3))
        #expect(coach.activeCallApp == nil)
        #expect(coach.currentStreak == 0)
    }
}
