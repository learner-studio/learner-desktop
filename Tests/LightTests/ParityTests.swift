import CryptoKit
import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

/// The Swift parser against the TypeScript parser it replaced: tests/Fixtures/parity holds
/// tricky fictional exports and, for each, the TS parser's output (generate.ts, run with bun
/// on the parser from commit b591b40). learner-server dedupes on documentId and compares
/// message text, so ids, order, roles and text must match exactly: strings here are
/// compared scalar by scalar, never with Swift's canonical-equivalence `==`.
@Suite("Parser parity with the TypeScript watcher", .timeLimit(.minutes(1))) struct ParityTests {
    static let dir = Vault.repo + "/tests/Fixtures/parity"
    static let names: [String] = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
        .filter { $0.hasSuffix(".expected.json") }.map { String($0.dropLast(".expected.json".count)) }.sorted()

    @Test func everyFixtureHasAnExpectation() {
        #expect(ParityTests.names.count >= 12)
    }

    @Test(arguments: ParityTests.names)
    func swiftMatchesTypeScript(name: String) throws {
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(ParityTests.dir)/\(name).expected.json"))) as! [String: Any]
        let data = try name == "long-message" ? Data(ParityTests.longMessage.utf8) : Data(contentsOf: URL(fileURLWithPath: "\(ParityTests.dir)/\(name).md"))
        // As the watcher read it (readFileSync 'utf8') and as the archive reads it.
        let text = String(decoding: data, as: UTF8.self)
        let r = ConversationParser.parse(content: text, filePath: expected["filePath"] as? String)

        let actual: [String: Any] = [
            "filePath": expected["filePath"]!,
            "documentId": r.documentId,
            "conversationId": r.conversationId,
            "provider": r.provider.rawValue,
            "contentSha256": r.contentSha256,
            "stats": ["sections": r.stats.sections, "user": r.stats.user, "assistant": r.stats.assistant, "skipped": r.stats.skipped,
                      "skippedByReason": r.stats.skippedByReason, "truncated": r.stats.truncated, "attachments": r.stats.attachments],
            "problems": r.problems,
            "document": r.document.map { ParityTests.digest($0.json) } ?? NSNull(),
        ]
        // What goes on the wire: through JSON and back.
        let wire = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: actual))
        #expect(ParityTests.difference(wire, expected, "$") == nil)
        if name.hasPrefix("invalid-utf8") || name == "unicode-whitespace" {
            // The archive hashes what it parses, so the ledger keys match the watcher's.
            let file = try ConversationParser.parseFile("\(ParityTests.dir)/\(name).md")
            #expect(file.contentSha256 == expected["contentSha256"] as? String)
        }
    }

    // MARK: The same reduction generate.ts applies

    static func digest(_ doc: [String: Any]) -> [String: Any] {
        var d = doc
        let messages: [[String: Any]] = (doc["messages"] as! [[String: Any]]).map { m in
            guard let t = m["text"] as? String, t.utf16.count > 10_000 else { return m }
            var o = m
            o["text"] = nil
            o["textLength"] = t.utf16.count
            o["textSha256"] = SHA256.hash(data: Data(t.utf8)).map { String(format: "%02x", $0) }.joined()
            return o
        }
        d["messages"] = messages.count > 50
            ? ["count": messages.count, "head": Array(messages.prefix(3)), "tail": Array(messages.suffix(3))] as [String: Any]
            : messages
        return d
    }

    /// generate.ts's long-message fixture, built the same way (too big to commit).
    static var longMessage: String {
        let head = ["# A fictional chat", "", "**Provider:** chatgpt", "**Created:** 2024-06-22T12:45:56.025Z",
                    "**Updated:** 2024-06-22T12:46:03.820Z", "**Messages:** 1", "", "---", ""].joined(separator: "\n")
        let body = "😀 start " + String(repeating: "abcé", count: 125_010) + " end"
        return head + ["## User", "*2024-06-22T12:45:56.033Z*", "", body, "", "---", ""].joined(separator: "\n")
    }

    /// The first difference between two JSON values, or nil. Strings by exact scalars.
    static func difference(_ a: Any, _ b: Any, _ path: String) -> String? {
        switch (a, b) {
        case let (x as [String: Any], y as [String: Any]):
            if Set(x.keys) != Set(y.keys) { return "\(path): keys \(x.keys.sorted()) != \(y.keys.sorted())" }
            for k in x.keys.sorted() { if let d = difference(x[k]!, y[k]!, "\(path).\(k)") { return d } }
            return nil
        case let (x as [Any], y as [Any]):
            if x.count != y.count { return "\(path): \(x.count) items != \(y.count)" }
            for i in x.indices { if let d = difference(x[i], y[i], "\(path)[\(i)]") { return d } }
            return nil
        case let (x as String, y as String):
            let xs = x.unicodeScalars.map(\.value), ys = y.unicodeScalars.map(\.value)
            guard xs != ys else { return nil }
            let at = (0..<min(xs.count, ys.count)).first { xs[$0] != ys[$0] } ?? min(xs.count, ys.count)
            return "\(path): differs at scalar \(at) (\(xs.count) vs \(ys.count) scalars): \(String(x.prefix(80))) | \(String(y.prefix(80)))"
        case let (x as NSNumber, y as NSNumber):
            let xb = CFGetTypeID(x) == CFBooleanGetTypeID(), yb = CFGetTypeID(y) == CFBooleanGetTypeID()
            return xb == yb && x.doubleValue == y.doubleValue ? nil : "\(path): \(x) != \(y)"
        case (is NSNull, is NSNull):
            return nil
        default:
            return "\(path): \(a) != \(b)"
        }
    }
}
