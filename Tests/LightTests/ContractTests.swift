import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

/// The JSON Schema subset contract/contract.json uses (learner-server's zod schemas,
/// exported): type, properties, required, additionalProperties, enum, pattern,
/// min/maxLength, min/maxItems, items, anyOf, minimum/maximum. Returns the failures.
enum Schema {
    static func validate(_ value: Any, _ schema: [String: Any], _ path: String = "$") -> [String] {
        if let any = schema["anyOf"] as? [[String: Any]] {
            return any.contains { validate(value, $0, path).isEmpty } ? [] : ["\(path): matches no anyOf branch"]
        }
        var errors: [String] = []
        if let type = schema["type"] as? String, !matches(value, type) { return ["\(path): not \(type) (\(value))"] }
        if let allowed = schema["enum"] as? [Any], !allowed.contains(where: { "\($0)" == "\(value)" }) { errors.append("\(path): \(value) not in enum") }
        if let s = value as? String {
            let n = s.unicodeScalars.count
            if let min = schema["minLength"] as? Int, n < min { errors.append("\(path): shorter than \(min)") }
            if let max = schema["maxLength"] as? Int, n > max { errors.append("\(path): longer than \(max)") }
            if let p = schema["pattern"] as? String, s.range(of: p, options: .regularExpression) == nil { errors.append("\(path): \(s) does not match \(p)") }
        }
        if let n = value as? NSNumber, !isBool(n) {
            if let min = (schema["minimum"] as? NSNumber)?.doubleValue, n.doubleValue < min { errors.append("\(path): below \(min)") }
            if let max = (schema["maximum"] as? NSNumber)?.doubleValue, n.doubleValue > max { errors.append("\(path): above \(max)") }
        }
        if let a = value as? [Any] {
            if let min = schema["minItems"] as? Int, a.count < min { errors.append("\(path): fewer than \(min) items") }
            if let max = schema["maxItems"] as? Int, a.count > max { errors.append("\(path): more than \(max) items") }
            if let items = schema["items"] as? [String: Any] {
                for (i, v) in a.enumerated() { errors += validate(v, items, "\(path)[\(i)]") }
            }
        }
        if let o = value as? [String: Any] {
            let props = schema["properties"] as? [String: [String: Any]] ?? [:]
            for key in schema["required"] as? [String] ?? [] where o[key] == nil { errors.append("\(path).\(key): required") }
            for (k, v) in o {
                if let p = props[k] { errors += validate(v, p, "\(path).\(k)") }
                else if schema["additionalProperties"] as? Bool == false { errors.append("\(path).\(k): not allowed") }
            }
        }
        return errors
    }

    static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }

    static func matches(_ v: Any, _ type: String) -> Bool {
        switch type {
        case "object": return v is [String: Any]
        case "array": return v is [Any]
        case "string": return v is String
        case "boolean": return (v as? NSNumber).map(isBool) ?? false
        case "number": return (v as? NSNumber).map { !isBool($0) } ?? false
        case "integer": return (v as? NSNumber).map { !isBool($0) && $0.doubleValue.rounded() == $0.doubleValue } ?? false
        case "null": return v is NSNull
        default: return false
        }
    }

    static let rpc: [String: Any] = {
        let data = FileManager.default.contents(atPath: Vault.repo + "/contract/contract.json")!
        return (try! JSONSerialization.jsonObject(with: data) as! [String: Any])["rpc"] as! [String: Any]
    }()

    static func input(_ name: String) -> [String: Any] { (rpc[name] as! [String: Any])["input"] as! [String: Any] }

    /// What actually went over the wire: the request's `data`, as JSON.
    static func wire(_ seen: StubTransport.Seen) throws -> Any { try #require(seen.body?["data"]) }

    static var desktopTs: String { try! String(contentsOfFile: Vault.repo + "/contract/desktop.ts", encoding: .utf8) }
}

@Suite("Wire payloads match the pinned contract", .quietLog, .timeLimit(.minutes(1))) struct ContractTests {
    @Test func archivedDocumentsMatchArchiveConversationDocumentsInput() throws {
        let dir = TempDir("contract")
        let job = JobName("contract")
        let stub = StubTransport { s in StubTransport.json(200, ["data": ["accepted": 1, "updated": 0, "unchanged": 0]]) }
        var c = Archive.Config()
        c.jobName = job.name
        c.root = dir.file("vault")
        c.ledgerPath = dir.file("ledger.sqlite")
        let archive = Archive(rpc: LearnerRPC(baseURL: "http://x.invalid", transport: stub, key: { _ in "k" }), config: c)
        Vault.writeConversation(c.root, "a", "plain")
        Vault.writeConversation(c.root, "b c", "with a title-less header", provider: "claude")
        dir.write("vault/chatgpt/conversations/voice/conversation.md",
                  VoiceTranscripts.fillTranscripts(VoiceFixture.md, VoiceTranscripts.transcriptsByTime(VoiceFixture.api)).md)
        _ = archive.runOnce()
        try #require(stub.seen.count == 1)
        let errors = Schema.validate(try Schema.wire(stub.seen[0]), Schema.input("archiveConversationDocuments"))
        #expect(errors == [])
        #expect(stub.seen[0].documentIds.sorted() == ["ai-vault:chatgpt:a", "ai-vault:chatgpt:voice", "ai-vault:claude:b_c"])
    }

    @Test func habitEventsMatchRecordHabitEventsInput() throws {
        let f = OutboxFixture(turns: 2) { s in StubTransport.json(200, ["data": ["accepted": s.eventIds.count, "duplicates": 0]]) }
        // Optional fields empty, and a non-finite latency (sent as null, which the contract allows).
        f.logger.logTurn(occurredAt: nil, sessionId: "sparse", callApp: nil, treatmentArm: "baseline", turnDurationSec: 12,
                         wordsSpoken: 0, warningFiredAt: nil, shockFiredAt: nil, latencyToYieldSec: .infinity,
                         breached30s: false, breached60s: false, wasRewarded: false)
        f.logger.waitUntilIdle()
        _ = f.sender.runOnce()
        try #require(f.stub.seen.count == 1)
        let errors = Schema.validate(try Schema.wire(f.stub.seen[0]), Schema.input("recordHabitEvents"))
        #expect(errors == [])
        #expect(f.stub.seen[0].eventIds.count == 3)
    }

    @Test func legacyTimestampsGainAnOffset() {
        #expect(HabitEventLogger.isoWithOffset("2026-01-05 10:00:00") == "2026-01-05T10:00:00Z")
        #expect(HabitEventLogger.isoWithOffset("2026-01-05T10:00:00+01:00") == "2026-01-05T10:00:00+01:00")
    }

    @Test func theParsersContractChecksAgreeWithTheSchema() {
        let doc = ConversationDocument(documentId: "ai-vault:chatgpt:x", source: "chatgpt", title: nil, occurredAt: "2025-01-01T10:00:00Z",
                                       messages: [ConversationMessage(role: "user", text: "hi", at: "2025-01-01T10:00:01.5+01:00")], metadata: [:])
        let schema = (((Schema.input("archiveConversationDocuments")["properties"] as! [String: Any])["documents"] as! [String: Any])["items"]) as! [String: Any]
        #expect(ConversationContract.issues(doc) == [])
        #expect(Schema.validate(roundTrip(doc.json), schema) == [])
        for bad in ["2025-01-01T10:00Z", "2025-02-30T10:00:00Z", "2025-01-01 10:00:00Z", "2025-01-01T10:00:00"] {
            let d = ConversationDocument(documentId: doc.documentId, source: doc.source, title: nil, occurredAt: bad, messages: doc.messages, metadata: [:])
            #expect(!ConversationContract.issues(d).isEmpty, "\(bad)")
            #expect(!Schema.validate(roundTrip(d.json), schema).isEmpty, "\(bad)")
        }
    }

    @Test func limitsMatchDesktopTs() {
        let ts = Schema.desktopTs
        #expect(ts.contains("documents: z.array(DesktopConversationDocument).min(1).max(\(ConversationContract.maxDocuments))"))
        #expect(ts.contains("messages: z.array(DesktopConversationMessage).min(1).max(\(ConversationContract.maxMessages))"))
        #expect(ts.contains("text: z.string().min(1).max(500_000)") && ConversationContract.maxText == 500_000)
        #expect(ts.contains("title: z.string().max(\(ConversationContract.maxTitle))"))
        #expect(ts.contains("events: z.array(DesktopHabitEvent).min(1).max(\(OutboxSender.maxBatch))"))
        #expect(ts.contains("documentId: z.string().min(1).max(300).regex(/\(ConversationContract.documentId.source)/)"))
        #expect(ts.contains("source: z.enum(['chatgpt', 'claude-ai', 'gemini', 'other'])"))
        let schemaDateTime = ((Schema.input("archiveConversationDocuments")["properties"] as! [String: Any])["documents"] as! [String: Any])
        let occurred = (((schemaDateTime["items"] as! [String: Any])["properties"] as! [String: Any])["occurredAt"] as! [String: Any])["pattern"] as! String
        #expect(occurred == ConversationContract.dateTime.source)
    }

    @Test func theClientIdIsValid() {
        let pattern = ((Schema.input("recordHabitEvents")["properties"] as! [String: Any])["clientId"] as! [String: Any])["pattern"] as! String
        #expect(LearnerRPC.shared.clientId.range(of: pattern, options: .regularExpression) != nil)
        #expect(LearnerAPI.clientId == "ben-mbp")
    }

    @Test func statusClassesMatchTheTypeScriptClient() {
        let kinds = [200, 204, 400, 422, 401, 403, 413, 429, 500, 503, 404, 408, 0].map(LearnerRPC.classify)
        #expect(kinds == [.ok, .ok, .rejected, .rejected, .auth, .auth, .tooLarge, .transient, .transient, .transient, .unexpected, .transient, .transient])
    }

    private func roundTrip(_ o: Any) -> Any {
        try! JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: o))
    }
}
