import Foundation
import Testing
@testable import LearnerDesktop

/// A screenpipe that answers from a table in memory.
final class CannedScreenpipe {
    var meetings: Any = [[String: Any]]()
    var maxId: [String: Int] = ["meeting_transcript_segments": 0, "audio_transcriptions": 0]
    var live: [[String: Any]] = []
    var background: [[String: Any]] = []
    var sqlError = false
    var hang = false
    var queries: [String] = []

    lazy var api = ScreenpipeAPI(base: URL(string: "http://screenpipe.invalid")!) { [unowned self] req, done in
        if self.hang { return }
        let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
        if req.url!.path.hasSuffix("meetings") {
            return done(try! JSONSerialization.data(withJSONObject: self.meetings), http, nil)
        }
        let sql = (try! JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any])["query"] as! String
        self.queries.append(sql)
        if self.sqlError { return done(Data(#"{"error":"no such table"}"#.utf8), http, nil) }
        let table = sql.contains("meeting_transcript_segments") ? "meeting_transcript_segments" : "audio_transcriptions"
        if sql.contains("MAX(id)") {
            return done(try! JSONSerialization.data(withJSONObject: [["id": self.maxId[table]!]]), http, nil)
        }
        let mark = Int(sql.components(separatedBy: "id > ")[1].prefix { $0.isNumber })!
        let rows = (table == "audio_transcriptions" ? self.background : self.live).filter { ($0["id"] as! Int) > mark }
        done(try! JSONSerialization.data(withJSONObject: rows), http, nil)
    }
}

@MainActor
func settle(_ condition: () -> Bool = { false }, within seconds: Double = 1) async {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        try? await Task.sleep(nanoseconds: 5_000_000)
    } while !condition() && Date() < deadline
}

@MainActor
@Suite("Coach sources") struct CoachSourceTests {
    func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    @Test func historyIsNeverReplayedAndBackfillIsNotCountedTwice() async {
        let sp = CannedScreenpipe()
        let source = ScreenpipeSpeechSource(api: sp.api)
        sp.maxId = ["meeting_transcript_segments": 500, "audio_transcriptions": 900]
        sp.live = [["id": 12, "device_type": "input", "transcript": "old meeting speech long ago", "captured_at": "2026-09-01T10:00:00Z"]]
        var heard: [SpeechSpan] = []
        source.poll(now: Date()) { heard += $0 }
        await settle { source.live.watermark != nil && source.background.watermark != nil }
        #expect(heard.isEmpty)
        #expect(source.live.watermark == 500 && source.background.watermark == 900)
        #expect(sp.queries.allSatisfy { $0.contains("MAX(id)") })

        let t = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        sp.live = [
            ["id": 501, "device_type": "input", "transcript": "so the plan for next week", "captured_at": iso(t)],
            ["id": 502, "device_type": "output", "transcript": "mm hmm right", "captured_at": iso(t.addingTimeInterval(3))],
            ["id": 503, "device_type": "input", "transcript": "[BLANK_AUDIO]", "captured_at": iso(t.addingTimeInterval(4))],
        ]
        // The post-meeting back-fill of the same speech, and one later background row.
        sp.background = [
            ["id": 901, "transcription": "so the plan for next week", "timestamp": iso(t), "start_time": 0, "end_time": 2, "file_path": "/x/input (Microphone).mp4"],
            ["id": 902, "transcription": "and then after that we ship", "timestamp": iso(t.addingTimeInterval(10)), "start_time": 0.5, "end_time": 3.25, "file_path": "/x/input (Microphone).mp4"],
        ]
        source.poll(now: t.addingTimeInterval(14)) { heard += $0 }
        await settle { heard.count == 3 }
        #expect(heard.map(\.speaker) == [.me, .other, .me])
        #expect(heard.map(\.path) == ["live_meeting", "live_meeting", "background"])
        #expect(abs(heard[2].start.timeIntervalSince(t) - 10.5) < 0.01)
        #expect(abs(heard[2].end.timeIntervalSince(t) - 13.25) < 0.01)
        #expect(source.live.watermark == 503 && source.background.watermark == 902)
        await settle(within: 0.2)
        #expect(heard.count == 3)
    }

    @Test func bothScreenpipeDateFormatsParse() {
        #expect(ScreenpipeSpeechSource.parseDate("2026-10-21T16:10:12-04:00") != nil)
        #expect(ScreenpipeSpeechSource.parseDate("2026-10-21T15:12:11.241-04:00") != nil)
        #expect(ScreenpipeSpeechSource.parseDate("2026-10-21 15:12:11") == nil)
        #expect(!ScreenpipeSpeechSource.isSpeech("Sous-titrage ST' 501"))
        #expect(!ScreenpipeSpeechSource.isSpeech("[music] (laughs) ok"))
        #expect(ScreenpipeSpeechSource.isSpeech("we should ship it"))
    }

    @Test func aFailingOrStuckPollIsCountedAndNeverStacked() async {
        let sp = CannedScreenpipe()
        let source = ScreenpipeSpeechSource(api: sp.api)
        sp.sqlError = true
        source.poll(now: Date()) { _ in }
        await settle { sp.api.failures["live transcripts"] == 1 }
        #expect(sp.api.failures["live transcripts"] == 1)
        #expect(sp.api.failures["background transcripts"] == 1)
        #expect(source.live.watermark == nil)
        sp.sqlError = false
        source.poll(now: Date()) { _ in }
        await settle { source.live.watermark != nil }
        #expect(sp.api.failures["live transcripts"] == nil)

        sp.hang = true
        for _ in 0..<5 { source.poll(now: Date()) { _ in } }
        await settle(within: 0.2)
        #expect(sp.api.requests["live transcripts"] == 3)    // 2 answered + 1 hung; 4 skipped
    }

    @Test func theCallComesFromTheFirstMeetingWithoutAnEnd() async {
        let sp = CannedScreenpipe()
        let calls = ScreenpipeCallSource(api: sp.api)
        sp.meetings = [["meeting_app": "Zoom", "title": "Sync", "meeting_end": "2026-10-27T09:00:00Z"],
                       ["meeting_app": "Google Meet", "title": NSNull(), "meeting_end": NSNull()]]
        var polls: [CallPoll] = []
        calls.poll { polls.append($0) }
        await settle { !polls.isEmpty }
        guard case .answered(let state)? = polls.first else { Issue.record("no answer"); return }
        #expect(state == CallState(app: "Google Meet", title: nil))
    }
}
