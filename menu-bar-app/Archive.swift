import CryptoKit
import Foundation
import SQLite3

// MARK: - ai-vault conversation.md parser

/// ai-vault `conversation.md` -> DesktopConversationDocument (contract/desktop.ts).
///
/// Export layout: <root>/<provider>/conversations/<conversation-id>/conversation.md
///
///     # <title>
///
///     **Provider:** chatgpt
///     **Created:** 2024-06-22T12:45:56.025Z
///     **Updated:** 2024-06-22T12:46:03.820Z
///     **Messages:** 2
///
///     ---
///
///     ## User
///     *2024-06-22T12:45:56.033Z*
///
///     <markdown body, may itself contain `---` and `## ...` headings>
///
///     **Attachments:**
///     - [audio: ...](...)
///
///     ---
///
///     ## Assistant
///     ...
///
///     ---
///
///     ## Metadata
///
///     ```json
///     { "messageCount": 2, "characterCount": 970, "mediaCount": 0 }
///     ```
///
/// A role heading only starts a message when it follows a `---` separator line, so
/// `## Summary`-style headings inside an answer are body text. ChatGPT, Claude.ai and
/// Gemini exports share this layout; the provider comes from the path, else the header.
/// (Ported from the TypeScript watcher, src/parsers/ai-vault-messages.ts.)
enum VaultProvider: String {
    case chatgpt, claude, gemini, unknown

    var source: String {
        switch self {
        case .chatgpt: return "chatgpt"
        case .claude: return "claude-ai"
        case .gemini: return "gemini"
        case .unknown: return "other"
        }
    }
}

struct ConversationMessage: Equatable {
    let role: String
    let text: String
    let at: String?

    var json: [String: Any] {
        var m: [String: Any] = ["role": role, "text": text]
        if let at = at { m["at"] = at }
        return m
    }
}

struct ConversationDocument {
    let documentId: String
    let source: String
    let title: String?
    let occurredAt: String
    let messages: [ConversationMessage]
    let metadata: [String: Any]

    /// The wire shape (DesktopConversationDocument).
    var json: [String: Any] {
        ["documentId": documentId, "source": source, "title": title as Any? ?? NSNull(), "occurredAt": occurredAt,
         "messages": messages.map(\.json), "metadata": metadata]
    }
}

struct ParseStats: Equatable {
    /// Role sections found, including skipped ones.
    var sections = 0
    var user = 0
    var assistant = 0
    var skipped = 0
    var skippedByReason: [String: Int] = [:]
    var truncated = 0
    var attachments = 0
}

struct ParseResult {
    /// nil when the file yields no valid document; `problems` says why.
    let document: ConversationDocument?
    let provider: VaultProvider
    let conversationId: String
    let documentId: String
    let contentSha256: String
    let stats: ParseStats
    /// Non-fatal oddities (e.g. header count mismatch) and fatal ones (document nil).
    let problems: [String]
}

/// JavaScript's whitespace (String.prototype.trim and regex `\s`): WhiteSpace plus
/// LineTerminator. Not Swift's `.whitespacesAndNewlines`, which adds U+0085 and lacks U+FEFF.
enum JSText {
    static let whitespace: Set<UInt32> = [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004,
                                          0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF]
    /// The same set as the inside of an ICU character class.
    static let classBody = #"\t\n\x{0B}\f\r\x{20}\x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}"#

    static func isSpace(_ s: Unicode.Scalar) -> Bool { whitespace.contains(s.value) }

    /// `split('\n')` on the exact scalars.
    static func lines(_ s: String) -> [String] {
        s.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) }
    }

    /// `String.prototype.trim`, on the exact scalars (no normalisation).
    static func trim(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isSpace($0) }) else { return "" }
        let last = scalars.lastIndex(where: { !isSpace($0) })!
        return String(scalars[first...last])
    }
}

/// NSRegularExpression (ICU) with JavaScript's semantics for the patterns the parser uses:
/// `\s`/`\S` are JS whitespace, `\d` is ASCII only, `.` excludes only JS line terminators,
/// and a trailing `$` is the end of input (ICU's also matches before a final newline).
/// Matching is on UTF-16, as in JS, with no normalisation.
struct JSRegex {
    let re: NSRegularExpression
    /// The pattern as JavaScript wrote it.
    let source: String

    init(_ js: String, caseInsensitive: Bool = false) {
        source = js
        let space = "[\(JSText.classBody)]"
        var p = js.replacingOccurrences(of: #"\s"#, with: space, options: .literal)
            .replacingOccurrences(of: #"\S"#, with: "[^\(JSText.classBody)]", options: .literal)
            .replacingOccurrences(of: #"\d"#, with: "[0-9]", options: .literal)
            .replacingOccurrences(of: "(.", with: #"([^\n\r\x{2028}\x{2029}]"#, options: .literal)
        if p.hasSuffix("$") && !p.hasSuffix(#"\$"#) { p = String(p.dropLast()) + #"\z"# }
        // Patterns are literals in this file: a bad one is a programming error.
        re = try! NSRegularExpression(pattern: p, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    func test(_ s: String) -> Bool { re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

    /// Capture groups of the first match (index 0 is the whole match), or nil.
    func match(_ s: String) -> [String?]? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } }
    }
}

enum ConversationParser {
    static let maxMessageChars = 500_000
    static let maxMessages = 5_000
    static let maxTitleChars = 500

    static let roleByHeading: [String: String] = [
        "user": "user", "human": "user", "you": "user",
        "assistant": "assistant", "chatgpt": "assistant", "claude": "assistant", "gemini": "assistant", "model": "assistant",
    ]

    struct Section: Equatable {
        /// "user", "assistant" or "metadata".
        let kind: String
        /// Heading line index.
        let start: Int
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `.../<provider>/conversations/<id>/conversation.md`
    static func providerFromPath(_ path: String) -> VaultProvider? {
        let p = path as NSString
        let dir = ((p.deletingLastPathComponent as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        return normalizeProvider((dir as NSString).lastPathComponent)
    }

    static func normalizeProvider(_ raw: String) -> VaultProvider? {
        switch JSText.trim(raw).lowercased() {
        case "chatgpt", "openai": return .chatgpt
        case "claude", "claude-ai", "claude.ai", "anthropic": return .claude
        case "gemini", "bard": return .gemini
        default: return nil
        }
    }

    /// `ai-vault:<provider>:<id>`, with characters outside the contract's id alphabet replaced.
    static func documentId(_ provider: VaultProvider, _ conversationId: String) -> String {
        // JS `replace(/[^A-Za-z0-9._:-]/g, '_')` works on UTF-16 units: an emoji (a surrogate
        // pair) becomes two underscores, a combining accent one.
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-".utf16)
        var safe = String(decoding: conversationId.utf16.map { allowed.contains($0) ? $0 : 0x5F }, as: UTF16.self)
        if safe.isEmpty { safe = "unnamed" }
        return String("ai-vault:\(provider.rawValue):\(safe)".prefix(300))
    }

    static func headerField(_ lines: [String], _ name: String) -> String? {
        let re = JSRegex("^\\*\\*\(NSRegularExpression.escapedPattern(for: name)):\\*\\*\\s*(.*)$", caseInsensitive: true)
        for line in lines {
            if let m = re.match(line) {
                let v = JSText.trim(m[1] ?? "")
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    static let isoPattern = JSRegex(#"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$"#)
    private static let looseDate = JSRegex(#"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?)?\s*(Z|[+-]\d{2}:?\d{2})?$"#)

    /// ISO-8601 with an offset, or nil. Accepts what JS `Date.parse` would for the dates
    /// ai-vault writes and normalises it to UTC `Z` with milliseconds (toISOString).
    static func toIsoInstant(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        let v = JSText.trim(raw)
        guard !v.isEmpty else { return nil }
        if isoPattern.test(v) { return v }
        return jsDateParse(v).map(isoMillis)
    }

    /// JS Date.parse for ISO-like strings: date-only is UTC, date-time without an offset
    /// is local time. Also RFC 2822 ("Sat, 22 Jun 2024 12:45:56 GMT").
    static func jsDateParse(_ v: String) -> Date? {
        if let m = looseDate.match(v) {
            var c = DateComponents()
            c.year = Int(m[1]!); c.month = Int(m[2]!); c.day = Int(m[3]!)
            c.hour = m[4].flatMap { Int($0) } ?? 0
            c.minute = m[5].flatMap { Int($0) } ?? 0
            c.second = m[6].flatMap { Int($0) } ?? 0
            var cal = Calendar(identifier: .gregorian)
            if let tz = m[8] {
                if tz == "Z" { cal.timeZone = TimeZone(identifier: "UTC")! } else {
                    let digits = tz.dropFirst().replacingOccurrences(of: ":", with: "")
                    let secs = (Int(digits.prefix(2)) ?? 0) * 3600 + (Int(digits.suffix(2)) ?? 0) * 60
                    cal.timeZone = TimeZone(secondsFromGMT: tz.hasPrefix("-") ? -secs : secs)!
                }
            } else {
                cal.timeZone = m[4] == nil ? TimeZone(identifier: "UTC")! : .current
            }
            guard let month = c.month, (1...12).contains(month), let day = c.day, (1...31).contains(day),
                  let base = cal.date(from: c) else { return nil }
            let fraction = m[7].map { Double("0." + $0) ?? 0 } ?? 0
            return base.addingTimeInterval((fraction * 1000).rounded(.towardZero) / 1000)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss zzz", "EEE MMM dd yyyy HH:mm:ss zzz"] {
            f.dateFormat = format
            if let d = f.date(from: v) { return d }
        }
        return nil
    }

    /// JS `toISOString`: UTC, milliseconds truncated, `Z`.
    static func isoMillis(_ date: Date) -> String {
        isoMillis(msSinceEpoch: Int64((date.timeIntervalSince1970 * 1000).rounded(.down)))
    }

    static func isoMillis(msSinceEpoch ms: Int64) -> String {
        let secs = ms >= 0 ? ms / 1000 : (ms - 999) / 1000
        let millis = ms - secs * 1000
        var t = time_t(secs)
        var tm = tm()
        gmtime_r(&t, &tm)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", Int(tm.tm_year) + 1900, Int(tm.tm_mon) + 1, Int(tm.tm_mday),
                      Int(tm.tm_hour), Int(tm.tm_min), Int(tm.tm_sec), Int(millis))
    }

    private static let separator = JSRegex(#"^\s*(---|\*\*\*|___)\s*$"#)

    static func isSeparator(_ line: String?) -> Bool { line.map(separator.test) ?? false }

    private static func trimmed(_ s: String) -> String { JSText.trim(s) }

    /// A section heading counts only after a separator, optionally with one blank line between.
    static func followsSeparator(_ lines: [String], _ i: Int) -> Bool {
        if i >= 1 && isSeparator(lines[i - 1]) { return true }
        return i >= 2 && trimmed(lines[i - 1]).isEmpty && isSeparator(lines[i - 2])
    }

    private static let heading = JSRegex(#"^##\s+(.+?)\s*$"#)

    static func findSections(_ lines: [String]) -> [Section] {
        var out: [Section] = []
        for i in lines.indices {
            guard lines[i].utf8.starts(with: "##".utf8), let m = heading.match(lines[i]), followsSeparator(lines, i) else { continue }
            let name = (m[1] ?? "").lowercased()
            if name == "metadata" { out.append(Section(kind: "metadata", start: i)) }
            else if let role = roleByHeading[name] { out.append(Section(kind: role, start: i)) }
        }
        return out
    }

    /// Strips trailing blank lines and the `---` separator that closes a section.
    static func trimSectionTail(_ body: [String]) -> [String] {
        var end = body.count
        while end > 0 && trimmed(body[end - 1]).isEmpty { end -= 1 }
        if end > 0 && isSeparator(body[end - 1]) { end -= 1 }
        while end > 0 && trimmed(body[end - 1]).isEmpty { end -= 1 }
        return Array(body[0..<end])
    }

    private static let attachmentsHeading = JSRegex(#"^\*\*Attachments:\*\*\s*$"#)
    private static let listItem = JSRegex(#"^\s*[-*]\s+"#)

    /// Removes `**Attachments:**` blocks (heading + `- ` list); returns the remaining lines and the item count.
    static func stripAttachments(_ body: [String]) -> (lines: [String], attachments: Int) {
        var lines: [String] = []
        var attachments = 0
        var i = 0
        while i < body.count {
            if attachmentsHeading.test(body[i]) {
                var j = i + 1
                while j < body.count && listItem.test(body[j]) {
                    attachments += 1
                    j += 1
                }
                i = j
                continue
            }
            lines.append(body[i])
            i += 1
        }
        return (lines, attachments)
    }

    private static let fence = JSRegex("```(?:json)?\\s*\\n([\\s\\S]*?)\\n```")

    static func parseMetadataBlock(_ body: [String]) -> [String: Any] {
        guard let m = fence.match(body.joined(separator: "\n")), let json = m[1],
              let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else { return [:] }
        return parsed as? [String: Any] ?? [:]
    }

    static let stampLine = JSRegex(#"^[*_](\d{4}-\d{2}-\d{2}T[^*_\s]+)[*_]$"#)
    private static let titleLine = JSRegex(#"^#\s+\S"#)
    private static let titleMarker = JSRegex(#"^#\s+"#)
    private static let digits = JSRegex(#"^\d+$"#)

    /// JS `String.prototype.slice(0, n)` by UTF-16 units, kept on a character boundary.
    static func prefixUTF16(_ s: String, _ n: Int) -> String {
        guard s.utf16.count > n else { return s }
        var units = 0
        var end = s.unicodeScalars.startIndex
        for scalar in s.unicodeScalars {
            let w = scalar.utf16.count
            if units + w > n { break }
            units += w
            end = s.unicodeScalars.index(after: end)
        }
        return String(s.unicodeScalars[..<end])
    }

    static func parse(content raw: String, sha256 given: String? = nil, filePath: String? = nil,
                      provider forced: VaultProvider? = nil, conversationId forcedId: String? = nil) -> ParseResult {
        let contentSha256 = given ?? sha256(Data(raw.utf8))
        // JS `replace(/\r\n?/g, '\n')`, on UTF-16 (a Swift "\r\n" is one Character).
        let content = raw.replacingOccurrences(of: "\r\n", with: "\n", options: .literal).replacingOccurrences(of: "\r", with: "\n", options: .literal)
        let lines = JSText.lines(content)
        var problems: [String] = []

        let sections = findSections(lines)
        let firstSection = sections.first?.start ?? lines.count
        let head = Array(lines[0..<firstSection])

        let conversationId = forcedId ?? filePath.map { ((($0 as NSString).deletingLastPathComponent) as NSString).lastPathComponent } ?? "unnamed"
        let headerProvider = headerField(head, "Provider")
        let provider = forced ?? filePath.flatMap(providerFromPath) ?? headerProvider.flatMap(normalizeProvider) ?? .unknown
        let documentId = documentId(provider, conversationId)

        let title = head.first(where: { titleLine.test($0) }).map { line -> String in
            let rest = titleMarker.re.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
            return prefixUTF16(trimmed(rest), maxTitleChars)
        }
        let createdAt = toIsoInstant(headerField(head, "Created"))
        let updatedAt = toIsoInstant(headerField(head, "Updated"))
        let headerMessageCount = headerField(head, "Messages").flatMap { digits.test($0) ? Int($0) : nil }

        var stats = ParseStats()
        var messages: [ConversationMessage] = []
        var exportMeta: [String: Any] = [:]

        for (s, sec) in sections.enumerated() {
            let end = s + 1 < sections.count ? sections[s + 1].start : lines.count
            var body = trimSectionTail(Array(lines[(sec.start + 1)..<end]))

            if sec.kind == "metadata" {
                exportMeta = parseMetadataBlock(body)
                continue
            }
            stats.sections += 1

            // Optional `*<timestamp>*` line right under the heading.
            var at: String?
            if let firstIdx = body.firstIndex(where: { !trimmed($0).isEmpty }),
               let tm = stampLine.match(trimmed(body[firstIdx])) {
                at = toIsoInstant(tm[1])
                body = Array(body[(firstIdx + 1)...])
            }

            let stripped = stripAttachments(body)
            stats.attachments += stripped.attachments
            var text = trimmed(stripped.lines.joined(separator: "\n"))

            if text.isEmpty {
                let reason = stripped.attachments > 0 ? "attachment-only" : "empty"
                stats.skipped += 1
                stats.skippedByReason[reason, default: 0] += 1
                continue
            }
            if text.utf16.count > maxMessageChars {
                text = prefixUTF16(text, maxMessageChars)
                stats.truncated += 1
            }
            if sec.kind == "user" { stats.user += 1 } else { stats.assistant += 1 }
            messages.append(ConversationMessage(role: sec.kind, text: text, at: at))
        }

        if let n = headerMessageCount, n != stats.sections {
            problems.append("header-count-mismatch:\(n)!=\(stats.sections)")
        }
        if messages.count > maxMessages {
            problems.append("too-many-messages:\(messages.count)")
            messages = Array(messages.prefix(maxMessages))
        }

        let occurredAt = createdAt ?? messages.first(where: { $0.at != nil })?.at ?? updatedAt
        if occurredAt == nil { problems.append("no-timestamp") }
        if messages.isEmpty { problems.append("no-messages") }

        var metadata: [String: Any] = [
            "exporter": "ai-vault",
            "provider": provider.rawValue,
            "conversationId": conversationId,
            "contentSha256": contentSha256,
            "createdAt": createdAt as Any? ?? NSNull(),
            "updatedAt": updatedAt as Any? ?? NSNull(),
            "headerMessageCount": headerMessageCount as Any? ?? NSNull(),
            "sectionCount": stats.sections,
            "messageCount": messages.count,
            "userMessageCount": stats.user,
            "assistantMessageCount": stats.assistant,
            "skippedMessageCount": stats.skipped,
            "skippedByReason": stats.skippedByReason,
            "truncatedMessageCount": stats.truncated,
            "attachmentCount": stats.attachments,
        ]
        for key in ["characterCount", "mediaCount"] {
            // JS `typeof x === 'number'`: a JSON number, not a boolean.
            if let n = exportMeta[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
                metadata["export" + key.prefix(1).uppercased() + key.dropFirst()] = n
            }
        }

        var document: ConversationDocument?
        if let occurredAt = occurredAt, !messages.isEmpty {
            let candidate = ConversationDocument(documentId: documentId, source: provider.source, title: title,
                                                 occurredAt: occurredAt, messages: messages, metadata: metadata)
            let issues = ConversationContract.issues(candidate)
            if issues.isEmpty { document = candidate } else { problems.append(contentsOf: issues) }
        }
        return ParseResult(document: document, provider: provider, conversationId: conversationId, documentId: documentId,
                           contentSha256: contentSha256, stats: stats, problems: problems)
    }

    /// Reads and parses one file. The hash is of the bytes on disk (what the ledger keys on).
    static func parseFile(_ path: String) throws -> ParseResult {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        // As Node's readFileSync(path, 'utf8'): invalid bytes become U+FFFD, a BOM is kept.
        // The hash is of that text (what the watcher's ledger holds), which is the bytes
        // themselves for any valid UTF-8 file.
        let text = String(decoding: data, as: UTF8.self)
        return parse(content: text, filePath: path)
    }

    /// Every `conversation.md` under the export root, sorted; optionally only one provider's
    /// directory. Symlinks are not followed.
    static func findConversationFiles(_ root: String, provider filter: String? = nil) -> [String] {
        var files: [String] = []
        let fm = FileManager.default
        func recurse(_ dir: String, _ depth: Int) {
            guard depth <= 6, let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for name in entries {
                let full = dir + "/" + name
                guard let type = (try? fm.attributesOfItem(atPath: full))?[.type] as? FileAttributeType else { continue }
                if type == .typeDirectory { recurse(full, depth + 1) }
                else if type == .typeRegular && name == "conversation.md" {
                    if filter == nil || full.contains("/\(filter!)/") { files.append(full) }
                }
            }
        }
        recurse(root, 0)
        // JS sort: by UTF-16 code units.
        return files.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
    }
}

// MARK: - Contract checks

/// DesktopConversationDocument's rules (contract/desktop.ts; JSON Schema in
/// contract/contract.json), checked before a document is sent so one bad file is skipped
/// locally instead of getting its whole batch refused.
enum ConversationContract {
    static let maxDocuments = 50
    static let maxMessages = 5000
    static let maxText = 500_000
    static let maxTitle = 500
    static let sources: Set = ["chatgpt", "claude-ai", "gemini", "other"]
    static let documentId = JSRegex("^[A-Za-z0-9._:-]+$")
    /// The contract's date-time: seconds required, an offset or Z required.
    static let dateTime = JSRegex(#"^(?:(?:\d\d[2468][048]|\d\d[13579][26]|\d\d0[48]|[02468][048]00|[13579][26]00)-02-29|\d{4}-(?:(?:0[13578]|1[02])-(?:0[1-9]|[12]\d|3[01])|(?:0[469]|11)-(?:0[1-9]|[12]\d|30)|(?:02)-(?:0[1-9]|1\d|2[0-8])))T(?:(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?(?:Z|([+-](?:[01]\d|2[0-3]):[0-5]\d)))$"#)
    static let clientId = JSRegex("^[a-z0-9][a-z0-9-]{0,62}$")

    /// `invalid:<path>:<code>` for each rule the document breaks; empty when it is valid.
    static func issues(_ d: ConversationDocument) -> [String] {
        var out: [String] = []
        if d.documentId.isEmpty || d.documentId.utf16.count > 300 || !documentId.test(d.documentId) { out.append("invalid:documentId:invalid_format") }
        if !sources.contains(d.source) { out.append("invalid:source:invalid_value") }
        if let t = d.title, t.utf16.count > maxTitle { out.append("invalid:title:too_big") }
        if !dateTime.test(d.occurredAt) { out.append("invalid:occurredAt:invalid_format") }
        if d.messages.isEmpty { out.append("invalid:messages:too_small") }
        if d.messages.count > maxMessages { out.append("invalid:messages:too_big") }
        for (i, m) in d.messages.enumerated() {
            if m.role != "user" && m.role != "assistant" { out.append("invalid:messages.\(i).role:invalid_value") }
            if m.text.isEmpty { out.append("invalid:messages.\(i).text:too_small") }
            if m.text.utf16.count > maxText { out.append("invalid:messages.\(i).text:too_big") }
            if let at = m.at, !dateTime.test(at) { out.append("invalid:messages.\(i).at:invalid_format") }
        }
        if !JSONSerialization.isValidJSONObject(d.metadata) { out.append("invalid:metadata:invalid_type") }
        return out
    }
}

// MARK: - Archive ledger

/// One row per conversation.md in ~/.ai-aggregator/sync-ledger.sqlite (table
/// archive_ledger, the schema the TypeScript watcher created, so nothing it sent is sent
/// again): what was last sent, parked or skipped for it. A file is resent only when its
/// content hash changes.
///
///   synced   archived by archiveConversationDocuments
///   failed   refused by the server (400/422, or 413 on its own): parked until the file changes
///   skipped  no messages with text (empty or audio-only export): nothing to send
// @unchecked: the SQLite handle is only touched under `lock`.
final class ArchiveLedger: @unchecked Sendable {
    struct Row: Equatable {
        let contentHash: String
        let documentId: String
        let messageCount: Int
        let status: String
        let error: String?
    }

    struct Stats: Equatable {
        var total = 0, synced = 0, failed = 0, skipped = 0
    }

    let path: String
    private var db: OpaquePointer?
    private let lock = NSLock()
    private let log = Log("Archive")

    /// `readOnly` opens an existing ledger without creating, migrating or writing anything.
    init(path: String, readOnly: Bool = false) throws {
        self.path = path
        if !readOnly {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        }
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let why = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            db = nil
            throw NSError(domain: "ArchiveLedger", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot open \(path): \(why)"])
        }
        sqlite3_busy_timeout(db, 5000)
        guard !readOnly else { return }
        try exec("PRAGMA journal_mode = WAL;")
        try exec("""
            CREATE TABLE IF NOT EXISTS archive_ledger (
              file_path TEXT PRIMARY KEY,
              content_hash TEXT NOT NULL,
              document_id TEXT NOT NULL,
              message_count INTEGER NOT NULL,
              sync_status TEXT NOT NULL,
              error_message TEXT,
              updated_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_archive_ledger_doc_id ON archive_ledger (document_id);
            DROP TABLE IF EXISTS sync_ledger;
            """)
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let why = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw NSError(domain: "ArchiveLedger", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(path): \(why)"])
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func row(_ filePath: String) -> Row? {
        lock.withLock {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT content_hash, document_id, message_count, sync_status, error_message FROM archive_ledger WHERE file_path = ?1", -1, &stmt, nil) == SQLITE_OK else {
                log.noisy("ledger read failed: \(String(cString: sqlite3_errmsg(db)))")
                return nil
            }
            sqlite3_bind_text(stmt, 1, filePath, -1, ArchiveLedger.transient)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            func text(_ i: Int32) -> String? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, i)) }
            return Row(contentHash: text(0) ?? "", documentId: text(1) ?? "", messageCount: Int(sqlite3_column_int64(stmt, 2)),
                       status: text(3) ?? "", error: text(4))
        }
    }

    /// Every row, by file path (for the heavy lane's consistency check).
    func all() -> [String: Row] {
        lock.withLock {
            var out: [String: Row] = [:]
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT file_path, content_hash, document_id, message_count, sync_status, error_message FROM archive_ledger", -1, &stmt, nil) == SQLITE_OK else { return out }
            func text(_ i: Int32) -> String? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, i)) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                out[text(0) ?? ""] = Row(contentHash: text(1) ?? "", documentId: text(2) ?? "", messageCount: Int(sqlite3_column_int64(stmt, 3)),
                                         status: text(4) ?? "", error: text(5))
            }
            return out
        }
    }

    /// True when this exact content was already archived, parked or found empty.
    func isUpToDate(_ filePath: String, hash: String) -> Bool { row(filePath)?.contentHash == hash }

    /// False (logged) when the row could not be written.
    @discardableResult
    func record(_ filePath: String, hash: String, documentId: String, messageCount: Int, status: String, error: String? = nil) -> Bool {
        lock.withLock {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                INSERT INTO archive_ledger (file_path, content_hash, document_id, message_count, sync_status, error_message, updated_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                ON CONFLICT(file_path) DO UPDATE SET
                  content_hash = excluded.content_hash, document_id = excluded.document_id,
                  message_count = excluded.message_count, sync_status = excluded.sync_status,
                  error_message = excluded.error_message, updated_at = excluded.updated_at
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                log.error("ledger write failed: \(String(cString: sqlite3_errmsg(db)))")
                return false
            }
            sqlite3_bind_text(stmt, 1, filePath, -1, ArchiveLedger.transient)
            sqlite3_bind_text(stmt, 2, hash, -1, ArchiveLedger.transient)
            sqlite3_bind_text(stmt, 3, documentId, -1, ArchiveLedger.transient)
            sqlite3_bind_int64(stmt, 4, Int64(messageCount))
            sqlite3_bind_text(stmt, 5, status, -1, ArchiveLedger.transient)
            if let e = error { sqlite3_bind_text(stmt, 6, e, -1, ArchiveLedger.transient) } else { sqlite3_bind_null(stmt, 6) }
            sqlite3_bind_text(stmt, 7, ConversationParser.isoMillis(Date()), -1, ArchiveLedger.transient)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                log.error("ledger write failed: \(String(cString: sqlite3_errmsg(db)))")
                return false
            }
            return true
        }
    }

    func stats() -> Stats {
        lock.withLock {
            var s = Stats()
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT sync_status, COUNT(*) FROM archive_ledger GROUP BY sync_status", -1, &stmt, nil) == SQLITE_OK else {
                log.noisy("ledger read failed: \(String(cString: sqlite3_errmsg(db)))")
                return s
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let n = Int(sqlite3_column_int64(stmt, 1))
                s.total += n
                switch String(cString: sqlite3_column_text(stmt, 0)) {
                case "synced": s.synced = n
                case "failed": s.failed = n
                case "skipped": s.skipped = n
                default: break
                }
            }
            return s
        }
    }

    func tableNames() -> [String] {
        lock.withLock {
            var out: [String] = []
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name", -1, &stmt, nil) == SQLITE_OK else { return out }
            while sqlite3_step(stmt) == SQLITE_ROW { out.append(String(cString: sqlite3_column_text(stmt, 0))) }
            return out
        }
    }
}

// MARK: - Archive job

/// Sends every changed ~/ai-vault-data conversation to learner-server with
/// `archiveConversationDocuments` (the "Archive" job: on launch, after each export, and
/// hourly). Replaces the bun watcher: no file watching, a sweep hashes each file and sends
/// only what the ledger has not seen.
///
/// Per reply:
///   2xx         ledger `synced`
///   400 / 422   the batch is split in halves down to the refused document, which is parked
///               (ledger `failed`, id logged, not retried until the file changes)
///   413         the same halving; a lone document that is still too large is parked
///   401 / 403   blocked: "device key refused" (the rest waits for a kick)
///   no key      blocked: "no device key"
///   429/5xx/net failed: the job backs off 1 min -> 1 h; what was sent stays sent
///   other       failed
///
/// Logs carry document ids and counts only, never titles or message text.
final class Archive: Sendable {
    struct Config: Sendable {
        var jobName = "Archive"
        var root = Paths.vault
        var ledgerPath = Paths.data + "/sync-ledger.sqlite"
        var batchSize = ConversationContract.maxDocuments
        var period: TimeInterval = 3600
        var callTimeout: TimeInterval = 60
        var problemGrace: TimeInterval = 10 * 60
    }

    struct Summary: Equatable {
        var discovered = 0
        var upToDate = 0
        var empty = 0
        var unreadable = 0
        var synced = 0
        var parked = 0
        var requests = 0
        /// Set when the sweep stopped early; `remaining` documents were not sent.
        var stopped: String?
        var remaining = 0

        var describe: String {
            var parts = ["\(discovered) files", "\(synced) archived"]
            if parked > 0 { parts.append("\(parked) parked") }
            if empty > 0 { parts.append("\(empty) without text") }
            if unreadable > 0 { parts.append("\(unreadable) unreadable") }
            if let s = stopped { parts.append("stopped: \(s), \(remaining) not sent") }
            return parts.joined(separator: ", ")
        }
    }

    /// What the menu shows.
    struct Status {
        var lastSummary: String
        var lastSweep: Date?
        var ledger: ArchiveLedger.Stats
        /// conversation.md files per provider directory, from the last sweep.
        var filesByProvider: [String: Int]
        /// Blocked, or failing longer than the grace period.
        var problem: String?
    }

    struct Pending {
        let filePath: String
        let hash: String
        let document: ConversationDocument
    }

    static let shared = Archive(rpc: .shared)

    let config: Config
    let rpc: LearnerRPC
    // nonisolated(unsafe): assigned once at the end of init (its body needs `self`); only read after.
    nonisolated(unsafe) private(set) var job: Job!
    private let log = Log("Archive")
    private struct State {
        var ledger: ArchiveLedger?
        var lastSummary = "not run yet"
        var lastSweep: Date?
        var filesByProvider: [String: Int] = [:]
    }
    private let state = Locked(State())

    init(rpc: LearnerRPC, config: Config = Config()) {
        self.rpc = rpc
        self.config = config
        job = Job(config.jobName, period: config.period, firstRun: 0, backoff: Backoff(base: 60, max: 3600),
                  problemGrace: config.problemGrace) { [weak self] _ in self?.runOnce() ?? .idle }
    }

    var status: Status {
        let stats = (try? ledger())?.stats() ?? ArchiveLedger.Stats()
        let s = state.value
        return Status(lastSummary: s.lastSummary, lastSweep: s.lastSweep, ledger: stats, filesByProvider: s.filesByProvider,
                      problem: job.problem)
    }

    /// Parked documents (refused by the server).
    var parkedCount: Int { status.ledger.failed }

    func ledger() throws -> ArchiveLedger {
        try state.withLock { s in
            if let l = s.ledger { return l }
            let l = try ArchiveLedger(path: config.ledgerPath)
            s.ledger = l
            return l
        }
    }

    /// The job body.
    func runOnce() -> Job.Outcome {
        let ledger: ArchiveLedger
        do { ledger = try self.ledger() } catch {
            log.error("cannot open the ledger: \(error.localizedDescription)")
            return .failed("cannot open the ledger: \(error.localizedDescription)")
        }
        let (summary, outcome) = sweep(ledger: ledger)
        state.withLock {
            $0.lastSummary = summary.describe
            $0.lastSweep = Date()
        }
        return outcome
    }

    /// One sweep over the whole export.
    func sweep(ledger: ArchiveLedger) -> (Summary, Job.Outcome) {
        if !FileManager.default.fileExists(atPath: config.root) { log.noisy("\(config.root) does not exist yet (no export so far)") }
        let files = ConversationParser.findConversationFiles(config.root)
        var counts: [String: Int] = [:]
        let rootDepth = (config.root as NSString).pathComponents.count
        for f in files {
            let parts = (f as NSString).pathComponents
            if parts.count > rootDepth { counts[parts[rootDepth], default: 0] += 1 }
        }
        state.withLock { $0.filesByProvider = counts }

        var s = Summary(discovered: files.count)
        var pending: [Pending] = []
        for path in files {
            let r: ParseResult
            do { r = try ConversationParser.parseFile(path) } catch {
                s.unreadable += 1
                log.warn("cannot read \(path): \(error.localizedDescription)")
                continue
            }
            if ledger.isUpToDate(path, hash: r.contentSha256) {
                s.upToDate += 1
                continue
            }
            guard let doc = r.document else {
                s.empty += 1
                ledger.record(path, hash: r.contentSha256, documentId: r.documentId, messageCount: 0, status: "skipped",
                              error: String(r.problems.joined(separator: " ").prefix(500)))
                continue
            }
            pending.append(Pending(filePath: path, hash: r.contentSha256, document: doc))
        }
        let outcome = send(pending, ledger: ledger, summary: &s)
        if s.synced + s.parked + s.empty + s.unreadable > 0 || s.stopped != nil { log.info("sweep: \(s.describe)") }
        return (s, outcome ?? (s.synced + s.parked + s.empty > 0 ? .ok(s.describe) : idleOrRecovered(job, s.describe)))
    }

    /// Sends in batches of ≤ batchSize. Returns a stop outcome, or nil when everything was settled.
    func send(_ docs: [Pending], ledger: ArchiveLedger, summary s: inout Summary) -> Job.Outcome? {
        var work: [[Pending]] = stride(from: 0, to: docs.count, by: max(1, config.batchSize)).map {
            Array(docs[$0..<min(docs.count, $0 + max(1, config.batchSize))])
        }
        while let batch = work.first {
            s.requests += 1
            let r = rpc.call("archiveConversationDocuments",
                             ["clientId": rpc.clientId, "documents": batch.map(\.document.json)], timeout: config.callTimeout)
            func stop(_ why: String, _ outcome: Job.Outcome) -> Job.Outcome {
                s.stopped = why
                s.remaining = work.reduce(0) { $0 + $1.count }
                return outcome
            }
            switch r.kind {
            case .ok:
                work.removeFirst()
                for d in batch {
                    ledger.record(d.filePath, hash: d.hash, documentId: d.document.documentId,
                                  messageCount: d.document.messages.count, status: "synced")
                }
                s.synced += batch.count
                let b = r.body as? [String: Any]
                log.info("archived \(batch.count) document(s)" + (b.map { " (accepted \($0["accepted"] ?? "?"), updated \($0["updated"] ?? "?"), unchanged \($0["unchanged"] ?? "?"))" } ?? ""))
            case .rejected, .tooLarge:
                work.removeFirst()
                if batch.count > 1 {
                    let mid = (batch.count + 1) / 2
                    work.insert(contentsOf: [Array(batch[..<mid]), Array(batch[mid...])], at: 0)
                    log.info("\(r.describe) for \(batch.count) documents; halving the batch")
                    continue
                }
                let d = batch[0]
                ledger.record(d.filePath, hash: d.hash, documentId: d.document.documentId,
                              messageCount: d.document.messages.count, status: "failed", error: r.describe + (r.message.map { ": \($0)" } ?? ""))
                s.parked += 1
                log.warn("\(r.describe): parked \(d.document.documentId) (not retried until the file changes)")
            case .auth:
                return stop("device key refused", .blocked("device key refused (\(r.describe)); chats are not being archived"))
            case .noKey:
                return stop("no device key", .blocked("no device key (Keychain learner-server / ben-mbp); chats are not being archived"))
            case .transient:
                let why = r.status == 0 ? "server unreachable: \(r.error ?? "no answer")" : "server error \(r.status)"
                return stop(why, .failed(why))
            case .unexpected:
                let why = "unexpected \(r.describe) from \(rpc.baseURL)"
                return stop(why, .failed(why))
            }
        }
        return nil
    }
}
