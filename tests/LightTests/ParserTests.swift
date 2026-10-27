import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// Ported from tests/ts/ai-vault-messages.test.ts.

private struct Sec {
    let role: String
    var at: String?
    let body: String
}

private func vault(title: String = "A title", provider: String, created: String? = nil, count: Int? = nil,
                   sections: [Sec], metadata: Bool = true) -> String {
    var head = ["# \(title)", "", "**Provider:** \(provider)"]
    if created == nil { head.append("**Created:** 2024-06-22T12:45:56.025Z") } else if created != "" { head.append("**Created:** \(created!)") }
    head += ["**Updated:** 2024-06-22T12:46:03.820Z", "**Messages:** \(count ?? sections.count)", "", "---", ""]
    let parts = sections.map { s in (["## \(s.role)"] + (s.at.map { ["*\($0)*"] } ?? []) + ["", s.body, "", "---", ""]).joined(separator: "\n") }
    let tail = metadata ? ["## Metadata", "", "```json", "{", "  \"messageCount\": 2,", "  \"characterCount\": 10,", "  \"mediaCount\": 0", "}", "```"].joined(separator: "\n") : ""
    return head.joined(separator: "\n") + "\n" + parts.joined(separator: "\n") + tail
}

private func path(_ provider: String, _ id: String) -> String { "/x/ai-vault-data/\(provider)/conversations/\(id)/conversation.md" }

@Suite("Conversation parser", .timeLimit(.minutes(1))) struct ParserTests {
    @Test func chatgptTwoMessagesWithTimestampsValidAgainstTheContract() {
        let content = vault(provider: "chatgpt", sections: [
            Sec(role: "User", at: "2024-06-22T12:45:56.033Z", body: "Question?"),
            Sec(role: "Assistant", at: "2024-06-22T12:46:02.830Z", body: "Answer."),
        ])
        let r = ConversationParser.parse(content: content, filePath: path("chatgpt", "67d5e570-3b94-8008-8dd3-dc1cdf6033c9"))
        #expect(r.problems == [])
        let doc = r.document!
        #expect(ConversationContract.issues(doc) == [])
        #expect(doc.documentId == "ai-vault:chatgpt:67d5e570-3b94-8008-8dd3-dc1cdf6033c9")
        #expect(doc.source == "chatgpt")
        #expect(doc.title == "A title")
        #expect(doc.occurredAt == "2024-06-22T12:45:56.025Z")
        #expect(doc.messages == [
            ConversationMessage(role: "user", text: "Question?", at: "2024-06-22T12:45:56.033Z"),
            ConversationMessage(role: "assistant", text: "Answer.", at: "2024-06-22T12:46:02.830Z"),
        ])
        #expect(doc.metadata["userMessageCount"] as? Int == 1)
        #expect(doc.metadata["assistantMessageCount"] as? Int == 1)
        let sha = doc.metadata["contentSha256"] as? String ?? ""
        #expect(sha.count == 64 && sha.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect((doc.metadata["exportCharacterCount"] as? NSNumber)?.intValue == 10)
    }

    @Test func providersMapToContractSources() {
        let sections = [Sec(role: "User", body: "hi")]
        let claude = ConversationParser.parse(content: vault(provider: "claude", sections: sections), filePath: path("claude", "abc"))
        #expect(claude.document?.source == "claude-ai")
        #expect(claude.document?.documentId == "ai-vault:claude:abc")
        let gemini = ConversationParser.parse(content: vault(provider: "gemini", sections: sections), filePath: path("gemini", "g1"))
        #expect(gemini.document?.source == "gemini")
        #expect(gemini.document?.documentId == "ai-vault:gemini:g1")
        let other = ConversationParser.parse(content: vault(provider: "perplexity", sections: sections), filePath: path("perplexity", "p1"))
        #expect(other.document?.source == "other")
        #expect(other.document?.documentId == "ai-vault:unknown:p1")
    }

    @Test func providerFallsBackToTheHeader() {
        let r = ConversationParser.parse(content: vault(provider: "claude", sections: [Sec(role: "User", body: "hi")]), conversationId: "c-1")
        #expect(r.document?.source == "claude-ai")
    }

    @Test func noPerMessageTimestampOmitsAt() {
        let r = ConversationParser.parse(content: vault(provider: "chatgpt", sections: [Sec(role: "User", body: "hi")]), filePath: path("chatgpt", "a"))
        #expect(r.document?.messages.first == ConversationMessage(role: "user", text: "hi", at: nil))
        #expect(r.document?.messages.first?.json["at"] == nil)
    }

    @Test func emptyAndAttachmentOnlyMessagesAreSkippedAndCounted() {
        let content = vault(provider: "chatgpt", sections: [
            Sec(role: "User", at: "2024-06-22T12:45:56.033Z", body: ""),
            Sec(role: "User", at: "2024-06-22T12:45:57.000Z", body: "**Attachments:**\n- [audio: file_1](https://example.invalid/a)"),
            Sec(role: "Assistant", at: "2024-06-22T12:45:58.000Z", body: "Real answer.\n\n**Attachments:**\n- ![image](x.png)"),
        ])
        let r = ConversationParser.parse(content: content, filePath: path("chatgpt", "a"))
        #expect(r.document?.messages == [ConversationMessage(role: "assistant", text: "Real answer.", at: "2024-06-22T12:45:58.000Z")])
        #expect(r.stats.skipped == 2)
        #expect(r.stats.skippedByReason == ["empty": 1, "attachment-only": 1])
        #expect(r.stats.attachments == 2)
        #expect(r.problems == [])
    }

    @Test func onlyEmptyMessagesYieldsNoDocument() {
        let r = ConversationParser.parse(content: vault(provider: "chatgpt", sections: [Sec(role: "User", body: "**Attachments:**\n- [audio: a](b)")]),
                                         filePath: path("chatgpt", "a"))
        #expect(r.document == nil)
        #expect(r.problems.contains("no-messages"))
    }

    @Test func zeroMessageExportYieldsNoDocument() {
        let r = ConversationParser.parse(content: vault(provider: "chatgpt", sections: []), filePath: path("chatgpt", "a"))
        #expect(r.document == nil)
        #expect(r.problems == ["no-messages"])
    }

    @Test func separatorsAndHeadingsInsideABodyAreText() {
        let body = "Intro\n## Summary\nSee below\n## User\nnot a heading (no separator)\n\n---\n\nafter a rule\n\n## Bottom line\nDone."
        let r = ConversationParser.parse(content: vault(provider: "chatgpt", sections: [Sec(role: "User", body: "q"), Sec(role: "Assistant", body: body)]),
                                         filePath: path("chatgpt", "a"))
        #expect(r.document?.messages.count == 2)
        #expect(r.document?.messages.last?.text == body)
    }

    @Test func oddHeadersCRLFNoCreatedNoTitleCountMismatchNoMetadata() {
        let content = vault(provider: "chatgpt", created: "", count: 7, sections: [
            Sec(role: "Human", at: "2025-01-01T10:00:00Z", body: "hi"),
            Sec(role: "Claude", body: "hello"),
        ], metadata: false)
            .replacingOccurrences(of: "# A title\n", with: "")
            .replacingOccurrences(of: "\n", with: "\r\n")
        let r = ConversationParser.parse(content: content, filePath: path("claude", "id with spaces%"))
        let doc = r.document!
        #expect(ConversationContract.issues(doc) == [])
        #expect(doc.title == nil)
        #expect(doc.json["title"] is NSNull)
        #expect(doc.occurredAt == "2025-01-01T10:00:00Z") // first message time when Created is absent
        #expect(doc.messages.map(\.role) == ["user", "assistant"])
        #expect(doc.messages[1].text == "hello")
        #expect(doc.documentId == "ai-vault:claude:id_with_spaces_")
        #expect(r.problems == ["header-count-mismatch:7!=2"])
    }

    @Test func noTimestampAnywhereNoDocument() {
        let content = vault(provider: "chatgpt", created: "", sections: [Sec(role: "User", body: "hi")])
            .replacingOccurrences(of: #"\*\*Updated:\*\*.*\n"#, with: "", options: .regularExpression)
        let r = ConversationParser.parse(content: content, filePath: path("chatgpt", "a"))
        #expect(r.document == nil)
        #expect(r.problems.contains("no-timestamp"))
    }

    @Test func overLongTextIsTruncatedToTheContractLimit() {
        let r = ConversationParser.parse(content: vault(provider: "chatgpt", sections: [Sec(role: "User", body: String(repeating: "x", count: 500_010))]),
                                         filePath: path("chatgpt", "a"))
        #expect(r.document?.messages.first?.text.utf16.count == 500_000)
        #expect(r.stats.truncated == 1)
    }

    @Test func documentIdsStayInsideTheContractAlphabet() {
        #expect(ConversationParser.documentId(.chatgpt, "a b/c") == "ai-vault:chatgpt:a_b_c")
        #expect(ConversationParser.documentId(.unknown, "") == "ai-vault:unknown:unnamed")
        #expect(ConversationParser.documentId(.claude, String(repeating: "z", count: 400)).count == 300)
    }

    // Edge cases beyond the TypeScript suite.

    @Test func minutePrecisionTimesAreRefusedByTheContractNotSent() {
        // The parser keeps ISO strings as written; the contract wants seconds.
        let r = ConversationParser.parse(content: vault(provider: "chatgpt", created: "2025-01-01T10:00Z", sections: [Sec(role: "User", body: "hi")]),
                                         filePath: path("chatgpt", "a"))
        #expect(r.document == nil)
        #expect(r.problems.contains("invalid:occurredAt:invalid_format"))
    }

    @Test func nonIsoDatesAreNormalisedLikeJavaScript() {
        #expect(ConversationParser.toIsoInstant("2024-06-22") == "2024-06-22T00:00:00.000Z")
        #expect(ConversationParser.toIsoInstant("2024-06-22T12:45:56.025+0200") == "2024-06-22T10:45:56.025Z")
        #expect(ConversationParser.toIsoInstant("Sat, 22 Jun 2024 12:45:56 GMT") == "2024-06-22T12:45:56.000Z")
        #expect(ConversationParser.toIsoInstant("  2024-06-22T12:45:56Z ") == "2024-06-22T12:45:56Z")
        #expect(ConversationParser.toIsoInstant("not a date") == nil)
        #expect(ConversationParser.toIsoInstant("") == nil)
        #expect(ConversationParser.isoMillis(msSinceEpoch: 1_740_819_600_125) == "2025-03-01T09:00:00.125Z")
    }

    @Test func aHeadingAfterABlankLineAfterASeparatorStillCounts() {
        let md = "# t\n\n**Created:** 2025-01-01T00:00:00Z\n\n---\n\n## User\nhello\n\n---\n\n\n## Assistant\nhi"
        let r = ConversationParser.parse(content: md, provider: .chatgpt, conversationId: "x")
        // Two blank lines between separator and heading: not a heading, so the reply is body text.
        #expect(r.document?.messages.count == 1)
        #expect(r.document?.messages.first?.text.contains("## Assistant") == true)
    }

    @Test func hashIsOfTheBytesOnDisk() throws {
        let dir = TempDir("parser")
        let f = Vault.writeConversation(dir.path, "c1", "hello")
        let r = try ConversationParser.parseFile(f)
        #expect(r.contentSha256 == ConversationParser.sha256(try Data(contentsOf: URL(fileURLWithPath: f))))
        #expect(r.provider == .chatgpt && r.conversationId == "c1")
    }

    @Test func findsConversationFilesSortedAndFilteredByProvider() {
        let dir = TempDir("find")
        Vault.writeConversation(dir.path, "b", "x")
        Vault.writeConversation(dir.path, "a", "x")
        Vault.writeConversation(dir.path, "c", "x", provider: "claude")
        dir.write("chatgpt/conversations/a/notes.md", "ignored")
        let all = ConversationParser.findConversationFiles(dir.path)
        #expect(all.map { ($0 as NSString).pathComponents.suffix(4).joined(separator: "/") } == [
            "chatgpt/conversations/a/conversation.md", "chatgpt/conversations/b/conversation.md", "claude/conversations/c/conversation.md",
        ])
        #expect(ConversationParser.findConversationFiles(dir.path, provider: "claude").count == 1)
        #expect(ConversationParser.findConversationFiles(dir.path + "/missing").isEmpty)
    }
}
