import Foundation
import Testing
@testable import LearnerDesktop

// Ported from tests/ts/voice-transcripts.test.ts, plus the plain-HTTPS session and the
// memo of conversations ChatGPT has no transcript for.

enum VoiceFixture {
    // A fictional voice chat in ai-vault's layout: audio links, no text.
    static let t1 = "2025-03-01T09:00:00.125Z"
    static let t2 = "2025-03-01T09:00:04.500Z"
    static let t3 = "2025-03-01T09:01:00.000Z"
    static let md = [
        "# Morning plan", "", "**Provider:** chatgpt", "**Created:** 2025-03-01T09:00:00.000Z",
        "**Updated:** 2025-03-01T09:01:00.000Z", "**Messages:** 3", "", "---", "",
        "## User", "*\(t1)*", "", "", "", "**Attachments:**",
        "- [audio: file_aaa](https://chatgpt.com/backend-api/files/download/file_aaa)", "", "---", "",
        "## Assistant", "*\(t2)*", "", "", "", "**Attachments:**",
        "- [audio: file_bbb](https://chatgpt.com/backend-api/files/download/file_bbb)", "", "---", "",
        "## User", "*\(t3)*", "", "A typed follow-up.", "", "---", "",
    ].joined(separator: "\n")

    static func at(_ iso: String) -> Double {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso)!.timeIntervalSince1970
    }

    static var api: [String: Any] {
        ["mapping": [
            "a": ["message": ["create_time": at(t1), "content": ["parts": [
                ["content_type": "audio_transcription", "text": "What should I do first today?"],
                ["content_type": "real_time_user_audio_video_asset_pointer"],
            ]]]],
            "b": ["message": ["create_time": at(t2), "content": ["parts": [
                ["content_type": "audio_transcription", "text": "Start with the walk.\nThen email."],
                ["content_type": "audio_asset_pointer"],
            ]]]],
            "c": ["message": ["create_time": at(t3), "content": ["parts": ["A typed follow-up."]]]],
            "root": ["message": NSNull()],
        ]]
    }

    /// ai-vault's config with fictional ChatGPT cookies.
    static func aiVaultConfig(_ dir: TempDir) -> String {
        dir.write("ai-vault-config.json", #"{"providers":{"chatgpt":{"cookies":{"__Secure-next-auth.session-token.0":"fake-a","oai-did":"fake-b"}}}}"#)
    }
}

@Suite("Voice transcripts", .timeLimit(.minutes(1))) struct VoiceTests {
    @Test func aVoiceChatWithoutTextIsFoundATypedOneIsNot() {
        #expect(VoiceTranscripts.hasVoiceGaps(VoiceFixture.md))
        #expect(!VoiceTranscripts.hasVoiceGaps(VoiceFixture.md.replacingOccurrences(of: #"\[audio: [^\]]+\]"#, with: "[image: x]", options: .regularExpression)))
    }

    @Test func transcriptsAreKeyedByTheTimestampAiVaultWrites() {
        let t = VoiceTranscripts.transcriptsByTime(VoiceFixture.api)
        #expect(t[VoiceFixture.t1] == "What should I do first today?")
        #expect(t[VoiceFixture.t2] == "Start with the walk.\nThen email.")
        #expect(t[VoiceFixture.t3] == nil)
    }

    @Test func filledSectionsParseIntoMessagesTheArchiveSends() {
        let before = ConversationParser.parse(content: VoiceFixture.md, provider: .chatgpt, conversationId: "c1")
        #expect(before.document?.messages.count == 1)
        let r = VoiceTranscripts.fillTranscripts(VoiceFixture.md, VoiceTranscripts.transcriptsByTime(VoiceFixture.api))
        #expect(r.filled == 2 && r.missing == 0)
        #expect(!VoiceTranscripts.hasVoiceGaps(r.md))
        let after = ConversationParser.parse(content: r.md, provider: .chatgpt, conversationId: "c1")
        #expect(after.problems == [])
        #expect(after.document?.messages == [
            ConversationMessage(role: "user", text: "What should I do first today?", at: VoiceFixture.t1),
            ConversationMessage(role: "assistant", text: "Start with the walk.\nThen email.", at: VoiceFixture.t2),
            ConversationMessage(role: "user", text: "A typed follow-up.", at: VoiceFixture.t3),
        ])
    }

    @Test func fillingTwiceChangesNothing() {
        let once = VoiceTranscripts.fillTranscripts(VoiceFixture.md, VoiceTranscripts.transcriptsByTime(VoiceFixture.api)).md
        let twice = VoiceTranscripts.fillTranscripts(once, VoiceTranscripts.transcriptsByTime(VoiceFixture.api))
        #expect(twice.md == once)
        #expect(twice.filled == 0)
    }

    @Test func aMessageWithNoTranscriptStaysBlankAndIsCounted() {
        let partial: [String: Any] = ["mapping": ["a": (VoiceFixture.api["mapping"] as! [String: Any])["a"]!]]
        let r = VoiceTranscripts.fillTranscripts(VoiceFixture.md, VoiceTranscripts.transcriptsByTime(partial))
        #expect(r.filled == 1 && r.missing == 1)
    }

    // MARK: Runs against a stand-in chatgpt.com

    private func setUp(_ ids: [String]) -> (TempDir, VoiceTranscripts.Config, [String]) {
        let dir = TempDir("voice")
        var c = VoiceTranscripts.Config()
        c.root = dir.file("vault")
        c.aiVaultConfig = VoiceFixture.aiVaultConfig(dir)
        c.memoPath = dir.file("memo.json")
        c.baseURL = "https://chatgpt.invalid"
        c.delay = 0
        let files = ids.map { dir.write("vault/chatgpt/conversations/\($0)/conversation.md", VoiceFixture.md) }
        return (dir, c, files)
    }

    /// Session OK; each conversation answers with `status[id]`.
    private func chatgpt(_ status: [String: Int], body: [String: Any] = VoiceFixture.api) -> StubTransport {
        StubTransport { s in
            if s.path == "/api/auth/session" { return StubTransport.json(200, ["accessToken": "fake-token"]) }
            let id = s.url.lastPathComponent
            let code = status[id] ?? 200
            return code == 200 ? StubTransport.json(200, body) : StubTransport.status(code)
        }
    }

    @Test func theRunStopsAtARateLimitAndOnlyRewritesFilesItFilled() throws {
        let (dir, c, files) = setUp(["c1", "c2", "c3"])
        let stub = chatgpt(["c2": 429])
        let s = VoiceTranscripts(config: c, transport: stub).run()
        #expect(stub.seen.filter { $0.path.hasPrefix("/backend-api") }.map(\.url.lastPathComponent) == ["c1", "c2"])
        #expect(s.candidates == 3 && s.updated == 1 && s.filled == 2 && s.stopped == .rateLimited)
        #expect(!VoiceTranscripts.hasVoiceGaps(try String(contentsOfFile: files[0], encoding: .utf8)))
        #expect(try String(contentsOfFile: files[2], encoding: .utf8) == VoiceFixture.md)
        _ = dir
    }

    @Test func fiveFailedFetchesInARowStopTheRunAsAnOutage() {
        let (dir, c, _) = setUp((0..<8).map { "c\($0)" })
        let stub = StubTransport { s in
            s.path == "/api/auth/session" ? StubTransport.json(200, ["accessToken": "fake-token"]) : HTTPReply(status: 0, body: nil, error: "offline")
        }
        let s = VoiceTranscripts(config: c, transport: stub).run()
        #expect(stub.seen.count == 6)
        #expect(s.failed == 5 && s.stopped == .unreachable && s.updated == 0)
        _ = dir
    }

    @Test func requestsCarryAiVaultsCookiesTheBearerTokenAndASafariAgent() {
        let (dir, c, _) = setUp(["c1"])
        let stub = chatgpt([:])
        _ = VoiceTranscripts(config: c, transport: stub).run()
        let session = stub.seen[0], convo = stub.seen[1]
        #expect(session.path == "/api/auth/session")
        #expect(session.headers["Cookie"] == "__Secure-next-auth.session-token.0=fake-a; oai-did=fake-b")
        #expect(session.headers["User-Agent"]?.contains("Safari") == true)
        #expect(convo.path == "/backend-api/conversation/c1")
        #expect(convo.headers["Authorization"] == "Bearer fake-token")
        #expect(convo.headers["Cookie"] == session.headers["Cookie"])
        _ = dir
    }

    @Test func anExpiredLoginIsReportedAsSuchNotAsAFailure() {
        for reply in [StubTransport.json(200, [:]), StubTransport.status(401), StubTransport.status(403)] {
            let (dir, c, _) = setUp(["c1"])
            let s = VoiceTranscripts(config: c, transport: StubTransport { _ in reply }).run()
            #expect(s.stopped == .loginExpired)
            #expect(s.failed == 0)
            _ = dir
        }
        let (dir, c, _) = setUp(["c1"])
        let s = VoiceTranscripts(config: c, transport: chatgpt(["c1": 401])).run()
        #expect(s.stopped == .loginExpired)
        _ = dir
    }

    @Test func noSavedChatGPTLoginIsAnExpiredLogin() {
        var (dir, c, _) = setUp(["c1"])
        c.aiVaultConfig = dir.write("empty-config.json", #"{"providers":{}}"#)
        let stub = chatgpt([:])
        let s = VoiceTranscripts(config: c, transport: stub).run()
        #expect(s.stopped == .loginExpired && s.detail == "ai-vault has no ChatGPT login")
        #expect(stub.seen.isEmpty)
    }

    @Test func aConversationWithoutTranscriptsIsRememberedUntilItsFileChanges() throws {
        let (dir, c, files) = setUp(["c1"])
        let none: [String: Any] = ["mapping": [:]]
        let stub = chatgpt([:], body: none)
        let first = VoiceTranscripts(config: c, transport: stub).run()
        #expect(first.missing == 2 && first.updated == 0)
        let fetches = { stub.seen.filter { $0.path.hasPrefix("/backend-api") }.count }
        #expect(fetches() == 1)

        let second = VoiceTranscripts(config: c, transport: stub).run()
        #expect(second.known == 1 && second.candidates == 0)
        #expect(fetches() == 1)

        // A re-export changes the file: it is tried again.
        try (VoiceFixture.md + "\n").write(toFile: files[0], atomically: true, encoding: .utf8)
        _ = VoiceTranscripts(config: c, transport: stub).run()
        #expect(fetches() == 2)
        _ = dir
    }

    @Test func nothingToFillMakesNoRequests() {
        let (dir, c, _) = setUp([])
        dir.write("vault/chatgpt/conversations/typed/conversation.md", VoiceFixture.md.replacingOccurrences(of: "[audio:", with: "[image:"))
        let stub = chatgpt([:])
        let s = VoiceTranscripts(config: c, transport: stub).run()
        #expect(s.candidates == 0 && stub.seen.isEmpty)
    }

    @Test func aFilledFileKeepsItsPermissions() throws {
        let (dir, c, files) = setUp(["c1"])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: files[0])
        _ = VoiceTranscripts(config: c, transport: chatgpt([:])).run()
        let mode = try FileManager.default.attributesOfItem(atPath: files[0])[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        #expect(!FileManager.default.fileExists(atPath: files[0] + ".tmp"))
        _ = dir
    }
}
