import Foundation
@testable import LearnerDesktop

// Test targets cannot share sources (Package.swift), so these few helpers are repeated
// from LightTests/Support.

final class TempDir {
    let path: String

    init(_ label: String = "learner") {
        // Resolved (/private/var/...), so it compares equal to a child's `pwd`.
        let raw = NSTemporaryDirectory() + "\(label)-\(UUID().uuidString.prefix(8))"
        try! FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        path = (raw as NSString).resolvingSymlinksInPath
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }

    func file(_ relative: String) -> String { path + "/" + relative }

    @discardableResult
    func write(_ relative: String, _ text: String, mode: Int? = nil) -> String {
        let full = file(relative)
        try! FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! text.write(toFile: full, atomically: true, encoding: .utf8)
        if let mode = mode { try! FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: full) }
        return full
    }

    func read(_ relative: String) -> String { (try? String(contentsOfFile: file(relative), encoding: .utf8)) ?? "" }
    func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: file(relative)) }
}

final class JobName {
    let name: String
    init(_ label: String) { name = "test-\(label)-\(UUID().uuidString.prefix(8))" }
    deinit { try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/.ai-aggregator/jobs/\(name).json") }
}

func describe(_ o: Job.Outcome) -> String {
    switch o {
    case let .ok(s, _): return "ok: \(s)"
    case let .failed(s, retry): return "failed: \(s)" + (retry.map { " (retry \(Int($0)))" } ?? "")
    case let .blocked(s): return "blocked: \(s)"
    case .idle: return "idle"
    }
}

/// Kicks `job` and waits for it to record an outcome (not `.idle`, which records none).
@discardableResult
func run(_ job: Job, timeout: TimeInterval = 30) -> Job.State {
    let before = job.snapshot.lastRun
    job.kick("test")
    waitFor(timeout) { job.snapshot.lastRun != before }
    return job.snapshot
}

func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

func pid(in path: String) -> pid_t? {
    (try? String(contentsOfFile: path, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

enum Fixture {
    static func conversation(_ root: String, _ id: String, _ text: String, provider: String = "chatgpt") {
        let dir = "\(root)/\(provider)/conversations/\(id)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try! "# t\n\n**Provider:** \(provider)\n**Created:** 2025-01-01T00:00:00Z\n**Messages:** 1\n\n---\n\n## User\n*2025-01-01T00:00:01Z*\n\n\(text)\n\n---\n\n## Metadata\n"
            .write(toFile: dir + "/conversation.md", atomically: true, encoding: .utf8)
    }

    // A fictional voice chat (audio links, no text) and ChatGPT's reply for it.
    static let t1 = "2025-03-01T09:00:00.125Z"
    static let t2 = "2025-03-01T09:00:04.500Z"
    static let voiceMd = [
        "# Morning plan", "", "**Provider:** chatgpt", "**Created:** 2025-03-01T09:00:00.000Z", "**Messages:** 2", "", "---", "",
        "## User", "*\(t1)*", "", "**Attachments:**", "- [audio: file_aaa](https://chatgpt.com/backend-api/files/download/file_aaa)", "", "---", "",
        "## Assistant", "*\(t2)*", "", "**Attachments:**", "- [audio: file_bbb](https://chatgpt.com/backend-api/files/download/file_bbb)", "", "---", "",
    ].joined(separator: "\n")
    static let voiceApi: [String: Any] = ["mapping": [
        "a": ["message": ["create_time": 1_740_819_600.125, "content": ["parts": [["content_type": "audio_transcription", "text": "What should I do first today?"]]]]],
        "b": ["message": ["create_time": 1_740_819_604.5, "content": ["parts": [["content_type": "audio_transcription", "text": "Start with the walk."]]]]],
    ]]

    static let aiVaultOk = "Conversations:\n  Archived: 3\n\nErrors: 0\n\nCompleted in 40.2s"
    static let aiVaultExpired = "Authentication failed\nYour session cookies appear to be expired or invalid."
    static let aiVaultRateLimited = "Errors: 1\n  • Archive process failed: page.evaluate: Error: API request failed: 429 Too Many Requests"
}
