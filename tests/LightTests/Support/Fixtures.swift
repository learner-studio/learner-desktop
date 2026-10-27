import Foundation
@testable import LearnerDesktop

/// A scratch directory, removed when the fixture goes away.
final class TempDir {
    let path: String

    init(_ label: String = "learner") {
        path = NSTemporaryDirectory() + "\(label)-\(UUID().uuidString.prefix(8))"
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }

    func file(_ relative: String) -> String { path + "/" + relative }

    @discardableResult
    func write(_ relative: String, _ text: String) -> String {
        let full = file(relative)
        try! FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! text.write(toFile: full, atomically: true, encoding: .utf8)
        return full
    }

    func read(_ relative: String) -> String { (try? String(contentsOfFile: file(relative), encoding: .utf8)) ?? "" }
}

/// A unique job name, and its state file removed afterwards.
final class JobName {
    let name: String
    init(_ label: String) { name = "test-\(label)-\(UUID().uuidString.prefix(8))" }
    deinit { try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/.ai-aggregator/jobs/\(name).json") }
}

/// An in-process stand-in for an HTTP server: records each request, answers with `handler`.
final class StubTransport: HTTPTransport {
    struct Seen {
        let url: URL
        let headers: [String: String]
        let body: [String: Any]?
        var path: String { url.path }
        func header(_ name: String) -> String? { headers.first { $0.key.lowercased() == name.lowercased() }?.value }
        /// archiveConversationDocuments / recordHabitEvents: the ids in the batch.
        var documentIds: [String] { ((body?["data"] as? [String: Any])?["documents"] as? [[String: Any]] ?? []).compactMap { $0["documentId"] as? String } }
        var eventIds: [String] { ((body?["data"] as? [String: Any])?["events"] as? [[String: Any]] ?? []).compactMap { $0["eventId"] as? String } }
    }

    private let lock = NSLock()
    private var seenRequests: [Seen] = []
    var handler: (Seen) -> HTTPReply

    init(_ handler: @escaping (Seen) -> HTTPReply) { self.handler = handler }

    var seen: [Seen] { lock.withLock { seenRequests } }

    func send(_ request: URLRequest, timeout: TimeInterval) -> HTTPReply {
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let s = Seen(url: request.url!, headers: request.allHTTPHeaderFields ?? [:], body: body)
        lock.withLock { seenRequests.append(s) }
        return handler(s)
    }

    static func json(_ status: Int, _ object: Any) -> HTTPReply {
        HTTPReply(status: status, body: try! JSONSerialization.data(withJSONObject: object), error: nil)
    }

    static func status(_ status: Int) -> HTTPReply { HTTPReply(status: status, body: Data("{}".utf8), error: nil) }
}

/// A Job outcome as a comparable string: "ok: ...", "failed: ... (retry 1800)", "blocked: ...", "idle".
func describe(_ o: Job.Outcome) -> String {
    switch o {
    case let .ok(s, _): return "ok: \(s)"
    case let .failed(s, retry): return "failed: \(s)" + (retry.map { " (retry \(Int($0)))" } ?? "")
    case let .blocked(s): return "blocked: \(s)"
    case .idle: return "idle"
    }
}

enum Vault {
    /// A fictional one-message ChatGPT conversation in ai-vault's layout.
    @discardableResult
    static func writeConversation(_ root: String, _ id: String, _ text: String, provider: String = "chatgpt") -> String {
        let dir = "\(root)/\(provider)/conversations/\(id)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = dir + "/conversation.md"
        try! "# t\n\n**Provider:** \(provider)\n**Created:** 2025-01-01T00:00:00Z\n**Messages:** 1\n\n---\n\n## User\n*2025-01-01T00:00:01Z*\n\n\(text)\n\n---\n\n## Metadata\n"
            .write(toFile: f, atomically: true, encoding: .utf8)
        return f
    }

    /// The repository root (for contract/ and config/ files).
    static var repo: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path
    }
}
