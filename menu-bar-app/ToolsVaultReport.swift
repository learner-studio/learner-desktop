import Foundation

// MARK: - tool vault-report

/// Parses every ai-vault conversation.md into messages and prints counts only, never
/// text: per file (provider, conversation id, messages, user, assistant, skipped, status),
/// then totals and the files that need a look. Exit 1 when any file yields no document.
///
/// It runs the archive's own parser (ConversationParser), so the report and what the
/// Archive job sends can never disagree. The parser is a parameter for tests.
enum VaultReport {
    /// What one file parsed to: counts and problem codes, no content.
    struct Summary {
        var provider: String
        var conversationId: String
        var valid: Bool
        var messages = 0
        var user = 0
        var assistant = 0
        var skipped = 0
        var skippedByReason: [String: Int] = [:]
        var truncated = 0
        var attachments = 0
        var problems: [String] = []
    }

    typealias Parser = (_ path: String) -> Summary

    static func main(_ args: [String], io: ToolIO, parse: Parser) -> Int32 {
        if args.contains("-h") || args.contains("--help") {
            io.out("usage: learner-desktop tool vault-report [ROOT]   (default: $AI_VAULT_DATA or ~/ai-vault-data)")
            return 0
        }
        let root = args.first { !$0.hasPrefix("-") } ?? io.env["AI_VAULT_DATA"] ?? NSHomeDirectory() + "/ai-vault-data"
        return report(root: root, io: io, parse: parse)
    }

    static func report(root: String, io: ToolIO, parse: Parser) -> Int32 {
        let files = ConversationParser.findConversationFiles(root)
        var valid = 0, invalid = 0, messages = 0, user = 0, assistant = 0, skipped = 0, attachments = 0
        var byProvider: [String: Int] = [:], skippedByReason: [String: Int] = [:]
        var flagged: [String] = []
        io.out(["provider", "conversation_id", "messages", "user", "assistant", "skipped", "status"].joined(separator: "\t"))
        for file in files {
            let r = parse(file)
            byProvider[r.provider, default: 0] += 1
            messages += r.messages
            user += r.user
            assistant += r.assistant
            skipped += r.skipped
            attachments += r.attachments
            for (k, v) in r.skippedByReason { skippedByReason[k, default: 0] += v }
            if r.valid { valid += 1 } else { invalid += 1 }
            var reasons = r.problems
            for (k, v) in r.skippedByReason.sorted(by: { $0.key < $1.key }) { reasons.append("skipped-\(k):\(v)") }
            if r.truncated > 0 { reasons.append("truncated:\(r.truncated)") }
            if !reasons.isEmpty { flagged.append("  \(r.provider):\(r.conversationId)  \(reasons.joined(separator: " "))") }
            let status = r.valid ? (reasons.isEmpty ? "valid" : "valid,flagged") : "INVALID"
            io.out([r.provider, r.conversationId, "\(r.messages)", "\(r.user)", "\(r.assistant)", "\(r.skipped)", status].joined(separator: "\t"))
        }
        func list(_ d: [String: Int]) -> String { d.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ") }
        io.out("")
        io.out("root: \(root)")
        io.out("files: \(files.count) (\(byProvider.isEmpty ? "none" : list(byProvider)))")
        io.out("documents: valid=\(valid) invalid=\(invalid)")
        io.out("messages: total=\(messages) user=\(user) assistant=\(assistant)")
        io.out("skipped messages: \(skipped)" + (skippedByReason.isEmpty ? "" : " (\(list(skippedByReason)))"))
        io.out("attachments stripped: \(attachments)")
        io.out("flagged files: \(flagged.count)")
        flagged.forEach(io.out)
        return invalid > 0 ? 1 : 0
    }

    /// The archive's parser, reduced to counts.
    static let defaultParser: Parser = { path in
        guard let r = try? ConversationParser.parseFile(path) else {
            let parts = path.split(separator: "/")
            return Summary(provider: parts.count > 3 ? String(parts[parts.count - 4]) : "unknown",
                           conversationId: parts.count > 1 ? String(parts[parts.count - 2]) : "unnamed",
                           valid: false, problems: ["unreadable"])
        }
        return Summary(provider: r.provider.rawValue, conversationId: r.conversationId, valid: r.document != nil,
                       messages: r.document?.messages.count ?? 0, user: r.stats.user, assistant: r.stats.assistant,
                       skipped: r.stats.skipped, skippedByReason: r.stats.skippedByReason, truncated: r.stats.truncated,
                       attachments: r.stats.attachments, problems: r.problems)
    }
}
