import Foundation

// MARK: - tool vault-report

/// Parses every ai-vault conversation.md into messages and prints counts only, never
/// text: per file (provider, conversation id, messages, user, assistant, skipped, status),
/// then totals and the files that need a look. Exit 1 when any file yields no document.
///
/// The parser is a parameter. `defaultParser` is a minimal stand-in that follows the
/// ai-vault markdown rules (role sections after a `---` separator, attachment blocks,
/// header counts); once the app's own conversation parser lands, pass an adapter to it
/// instead, so the report and the archive can never disagree.
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

    /// Every conversation.md under `root` (at most 6 levels deep), sorted; with a
    /// provider filter, only those under a `/<provider>/` directory.
    static func findConversationFiles(_ root: String, provider: String? = nil) -> [String] {
        var files: [String] = []
        func recurse(_ dir: String, _ depth: Int) {
            guard depth <= 6, let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
            for name in entries {
                let path = dir + "/" + name
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
                if isDir.boolValue { recurse(path, depth + 1) }
                else if name == "conversation.md", provider.map({ path.contains("/\($0)/") }) ?? true { files.append(path) }
            }
        }
        recurse(root, 0)
        return files.sorted()
    }

    static func main(_ args: [String], io: ToolIO, parse: Parser) -> Int32 {
        if args.contains("-h") || args.contains("--help") {
            io.out("usage: learner-desktop tool vault-report [ROOT]   (default: $AI_VAULT_DATA or ~/ai-vault-data)")
            return 0
        }
        let root = args.first { !$0.hasPrefix("-") } ?? io.env["AI_VAULT_DATA"] ?? NSHomeDirectory() + "/ai-vault-data"
        return report(root: root, io: io, parse: parse)
    }

    static func report(root: String, io: ToolIO, parse: Parser) -> Int32 {
        let files = findConversationFiles(root)
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

    // MARK: Stand-in parser

    static let maxMessageChars = 500_000
    static let maxMessages = 5_000
    static let roles: [String: String] = ["user": "user", "human": "user", "you": "user", "assistant": "assistant",
                                          "chatgpt": "assistant", "claude": "assistant", "gemini": "assistant", "model": "assistant"]

    static func provider(fromPath path: String) -> String? {
        // .../<provider>/conversations/<id>/conversation.md
        let dir = (((path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        return normalizeProvider((dir as NSString).lastPathComponent)
    }

    static func normalizeProvider(_ raw: String) -> String? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "chatgpt", "openai": return "chatgpt"
        case "claude", "claude-ai", "claude.ai", "anthropic": return "claude"
        case "gemini", "bard": return "gemini"
        default: return nil
        }
    }

    static let defaultParser: Parser = { path in
        let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return parseMarkdown(content, path: path)
    }

    static func parseMarkdown(_ raw: String, path: String) -> Summary {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        func isSeparator(_ i: Int) -> Bool {
            i >= 0 && i < lines.count && lines[i].range(of: #"^\s*(---|\*\*\*|___)\s*$"#, options: .regularExpression) != nil
        }
        // A role heading counts only right after a separator (one blank line allowed).
        var sections: [(kind: String, start: Int)] = []
        for (i, line) in lines.enumerated() {
            guard line.hasPrefix("##"), let r = line.range(of: #"^##\s+(.+?)\s*$"#, options: .regularExpression) else { continue }
            guard isSeparator(i - 1) || (i >= 2 && lines[i - 1].trimmingCharacters(in: .whitespaces).isEmpty && isSeparator(i - 2)) else { continue }
            let name = String(line[r]).dropFirst(2).trimmingCharacters(in: .whitespaces).lowercased()
            if name == "metadata" { sections.append(("metadata", i)) } else if let role = roles[name] { sections.append((role, i)) }
        }
        let head = Array(lines.prefix(sections.first?.start ?? lines.count))
        func header(_ field: String) -> String? {
            for l in head {
                if let r = l.range(of: #"^\*\*\#(field):\*\*\s*"#, options: [.regularExpression, .caseInsensitive]) {
                    let v = l[r.upperBound...].trimmingCharacters(in: .whitespaces)
                    return v.isEmpty ? nil : v
                }
            }
            return nil
        }
        let conversationId = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let provider = Self.provider(fromPath: path) ?? header("Provider").flatMap(normalizeProvider) ?? "unknown"
        var s = Summary(provider: provider, conversationId: conversationId, valid: false)
        var sectionCount = 0
        var timestamped = header("Created") != nil || header("Updated") != nil
        for (n, sec) in sections.enumerated() where sec.kind != "metadata" {
            sectionCount += 1
            let end = n + 1 < sections.count ? sections[n + 1].start : lines.count
            var body = Array(lines[(sec.start + 1)..<end])
            while let last = body.last, last.trimmingCharacters(in: .whitespaces).isEmpty || last.range(of: #"^\s*(---|\*\*\*|___)\s*$"#, options: .regularExpression) != nil {
                body.removeLast()
            }
            if let first = body.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
               body[first].trimmingCharacters(in: .whitespaces).range(of: #"^[*_]\d{4}-\d{2}-\d{2}T[^*_\s]+[*_]$"#, options: .regularExpression) != nil {
                timestamped = true
                body.removeFirst(first + 1)
            }
            var kept: [String] = []
            var i = 0
            while i < body.count {
                if body[i].range(of: #"^\*\*Attachments:\*\*\s*$"#, options: .regularExpression) != nil {
                    i += 1
                    while i < body.count, body[i].range(of: #"^\s*[-*]\s+"#, options: .regularExpression) != nil { s.attachments += 1; i += 1 }
                    continue
                }
                kept.append(body[i])
                i += 1
            }
            let text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                let reason = body.contains { $0.hasPrefix("**Attachments:**") } ? "attachment-only" : "empty"
                s.skipped += 1
                s.skippedByReason[reason, default: 0] += 1
                continue
            }
            if text.utf16.count > maxMessageChars { s.truncated += 1 }
            if sec.kind == "user" { s.user += 1 } else { s.assistant += 1 }
            s.messages += 1
        }
        if let count = header("Messages"), let n = Int(count), n != sectionCount {
            s.problems.append("header-count-mismatch:\(n)!=\(sectionCount)")
        }
        if s.messages > maxMessages {
            s.problems.append("too-many-messages:\(s.messages)")
            s.messages = maxMessages
        }
        if !timestamped { s.problems.append("no-timestamp") }
        if s.messages == 0 { s.problems.append("no-messages") }
        s.valid = timestamped && s.messages > 0
        return s
    }
}
