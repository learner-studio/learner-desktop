import Foundation

/// ChatGPT voice chats reach the ai-vault export as audio links only: ai-vault keeps a
/// message's plain-string parts and drops the `audio_transcription` parts that hold what
/// was said, so the archive finds no text. This fetches those conversations from ChatGPT
/// with ai-vault's saved cookies (plain HTTPS: GET /api/auth/session for a bearer token,
/// then /backend-api/conversation/<id>) and writes each transcript into its
/// `conversation.md` section under the `*<timestamp>*` line. The archive then sees a
/// changed file and sends it like any typed chat.
///
/// Sections are matched to API messages by timestamp: ai-vault writes each message's
/// `create_time` as an ISO instant, so the two agree to the millisecond.
/// (Ported from the TypeScript watcher, src/voice-transcripts.ts.)
final class VoiceTranscripts: Sendable {
    struct Config: Sendable {
        var root = Paths.vault
        var baseURL = "https://chatgpt.com"
        var aiVaultConfig = Paths.aiVaultConfig
        /// Conversations whose transcripts ChatGPT does not have: not fetched again until the file changes.
        var memoPath = Paths.data + "/voice-transcripts.json"
        /// Gentle on purpose: on 10-28 a 183-conversation catch-up at one request per 3 s,
        /// right after ai-vault's own fetching, put ChatGPT into hours of 429s.
        var delay: TimeInterval = 10
        var requestTimeout: TimeInterval = 30
        /// Bounds one run (the export job runs hourly; the rest waits for the next run).
        var maxPerRun = 30
        var userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    }

    enum Stop: String, Equatable {
        case rateLimited = "rate-limited"
        case loginExpired = "login-expired"
        case unreachable
    }

    struct Summary: Equatable {
        var candidates = 0
        var updated = 0
        var filled = 0
        var missing = 0
        var failed = 0
        /// Skipped: known to have no transcript (memo) and unchanged since.
        var known = 0
        var stopped: Stop?
        var detail: String?

        var describe: String {
            var s = "\(candidates) need transcripts: \(updated) updated (\(filled) messages)"
            if missing > 0 { s += ", \(missing) without a transcript" }
            if failed > 0 { s += ", \(failed) failed" }
            if let stop = stopped { s += "; stopped: \(stop.rawValue)" + (detail.map { " (\($0))" } ?? "") }
            return s
        }
    }

    let config: Config
    private let transport: HTTPTransport
    private let log = Log("Voice")

    init(config: Config = Config(), transport: HTTPTransport = URLSessionTransport()) {
        self.config = config
        self.transport = transport
    }

    // MARK: Markdown

    struct Gap: Equatable {
        let at: String
        let stampLine: Int
    }

    /// Message sections that have audio attached but no text: the ones ai-vault left blank.
    static func findGaps(_ lines: [String]) -> [Gap] {
        let sections = ConversationParser.findSections(lines)
        var gaps: [Gap] = []
        for (s, sec) in sections.enumerated() where sec.kind != "metadata" {
            let end = s + 1 < sections.count ? sections[s + 1].start : lines.count
            let body = ConversationParser.trimSectionTail(Array(lines[(sec.start + 1)..<end]))
            guard let first = body.firstIndex(where: { !JSText.trim($0).isEmpty }),
                  let stamp = ConversationParser.stampLine.match(JSText.trim(body[first])),
                  let at = stamp[1] else { continue }
            let rest = Array(body[(first + 1)...])
            guard ConversationParser.stripAttachments(rest).lines.joined(separator: "\n")
                .isEmptyAfterJSTrim else { continue }
            guard rest.contains(where: { $0.range(of: "[audio:", options: .literal) != nil }) else { continue }
            gaps.append(Gap(at: at, stampLine: sec.start + 1 + first))
        }
        return gaps
    }

    static func hasVoiceGaps(_ md: String) -> Bool { !findGaps(JSText.lines(md)).isEmpty }

    /// Transcript text by message timestamp (ISO, as ai-vault writes it), from a
    /// /backend-api/conversation/<id> reply.
    static func transcriptsByTime(_ conversation: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for case let node as [String: Any] in (conversation["mapping"] as? [String: Any] ?? [:]).values {
            guard let m = node["message"] as? [String: Any], let created = (m["create_time"] as? NSNumber)?.doubleValue,
                  created != 0, created.isFinite else { continue }
            let parts = (m["content"] as? [String: Any])?["parts"] as? [Any] ?? []
            let text = parts.compactMap { p -> String? in
                guard let p = p as? [String: Any], p["content_type"] as? String == "audio_transcription" else { return nil }
                let t = JSText.trim(p["text"] as? String ?? "")
                return t.isEmpty ? nil : t
            }.joined(separator: "\n")
            // JS: new Date(create_time * 1000).toISOString() (milliseconds truncated).
            if !text.isEmpty {
                out[ConversationParser.isoMillis(msSinceEpoch: Int64((created * 1000).rounded(.towardZero)))] = text
            }
        }
        return out
    }

    /// Writes each blank voice section's transcript under its timestamp line.
    static func fillTranscripts(_ md: String, _ transcripts: [String: String]) -> (md: String, filled: Int, missing: Int) {
        var lines = JSText.lines(md)
        let gaps = findGaps(lines)
        var filled = 0
        // Back to front, so earlier line numbers stay valid.
        for gap in gaps.reversed() {
            guard let text = transcripts[gap.at], !text.isEmpty else { continue }
            lines.insert(contentsOf: [""] + JSText.lines(text), at: gap.stampLine + 1)
            filled += 1
        }
        return (lines.joined(separator: "\n"), filled, gaps.count - filled)
    }

    // MARK: ChatGPT

    struct Fetch {
        let status: Int
        let body: [String: Any]?
        let error: String?
    }

    private func request(_ path: String, cookie: String, token: String? = nil) -> Fetch {
        guard let url = URL(string: config.baseURL + path) else { return Fetch(status: 0, body: nil, error: "bad URL") }
        var req = URLRequest(url: url)
        req.httpShouldHandleCookies = false
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let r = transport.send(req, timeout: config.requestTimeout)
        let body = r.status == 200 ? r.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } : nil
        return Fetch(status: r.status, body: body, error: r.error ?? (r.status == 200 && body == nil ? "reply is not JSON" : nil))
    }

    /// GET /backend-api/conversation/<id> (read-only).
    func fetchConversation(_ id: String, cookie: String, token: String) -> Fetch {
        request("/backend-api/conversation/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)", cookie: cookie, token: token)
    }

    /// ai-vault's saved ChatGPT cookies as one Cookie header, or nil.
    func savedCookieHeader() -> String? {
        guard let data = FileManager.default.contents(atPath: config.aiVaultConfig) else { return nil }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            log.warn("\(config.aiVaultConfig) is not JSON")
            return nil
        }
        guard let cookies = ((json["providers"] as? [String: Any])?["chatgpt"] as? [String: Any])?["cookies"] as? [String: Any],
              !cookies.isEmpty else { return nil }
        return cookies.keys.sorted().compactMap { k in (cookies[k] as? String).map { "\(k)=\($0)" } }.joined(separator: "; ")
    }

    /// A bearer token for the backend API, or why there is none.
    func openSession(cookie: String) -> (token: String?, stop: Stop?, detail: String?) {
        let r = request("/api/auth/session", cookie: cookie)
        switch r.status {
        case 200:
            if let t = r.body?["accessToken"] as? String, !t.isEmpty { return (t, nil, nil) }
            return (nil, r.body == nil ? .unreachable : .loginExpired, r.body == nil ? "session reply is not JSON" : "no session")
        case 401, 403: return (nil, .loginExpired, "session HTTP \(r.status)")
        case 429: return (nil, .rateLimited, "session HTTP 429")
        default: return (nil, .unreachable, r.status == 0 ? r.error : "session HTTP \(r.status)")
        }
    }

    // MARK: Memo

    private func loadMemo() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: config.memoPath) else { return [:] }
        guard let memo = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else {
            log.warn("\(config.memoPath) is unreadable; starting it again")
            return [:]
        }
        return memo
    }

    private func saveMemo(_ memo: [String: String]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: memo, options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: config.memoPath), options: .atomic)
        } catch {
            log.warn("cannot save \(config.memoPath): \(error.localizedDescription)")
        }
    }

    // MARK: Run

    /// Fills every ChatGPT conversation that has blank voice sections. Stops at the first
    /// 429, at a 401/403, or after 5 failures in a row. `cancelled` is checked between
    /// requests (quit).
    func run(cancelled: () -> Bool = { false }) -> Summary {
        var summary = Summary()
        var memo = loadMemo()
        var candidates: [(path: String, id: String, hash: String)] = []
        for path in ConversationParser.findConversationFiles(config.root, provider: "chatgpt") {
            guard let data = FileManager.default.contents(atPath: path) else {
                log.warn("cannot read \(path)")
                continue
            }
            guard VoiceTranscripts.hasVoiceGaps(String(decoding: data, as: UTF8.self)) else { continue }
            let id = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            let hash = ConversationParser.sha256(Data(String(decoding: data, as: UTF8.self).utf8))
            if memo[id] == hash { summary.known += 1; continue }
            candidates.append((path, id, hash))
        }
        summary.candidates = candidates.count
        guard !candidates.isEmpty else { return summary }
        if candidates.count > config.maxPerRun {
            log.info("\(candidates.count) conversations need transcripts; doing \(config.maxPerRun) this run")
            candidates = Array(candidates.prefix(config.maxPerRun))
        }

        guard let cookie = savedCookieHeader() else {
            summary.stopped = .loginExpired
            summary.detail = "ai-vault has no ChatGPT login"
            return summary
        }
        let session = openSession(cookie: cookie)
        guard let token = session.token else {
            summary.stopped = session.stop
            summary.detail = session.detail
            return summary
        }

        var consecutiveFailures = 0
        for (i, c) in candidates.enumerated() {
            if i > 0 {
                let until = Date().addingTimeInterval(config.delay)
                while Date() < until && !cancelled() { usleep(50_000) }
            }
            if cancelled() { break }
            log.noisy("\(i + 1)/\(candidates.count) \(c.id)")
            let r = fetchConversation(c.id, cookie: cookie, token: token)
            if r.status == 429 { summary.stopped = .rateLimited; break }
            if r.status == 401 || r.status == 403 { summary.stopped = .loginExpired; summary.detail = "HTTP \(r.status)"; break }
            if r.status == 404 {
                // Deleted on ChatGPT: there is nothing to fetch until the export changes.
                memo[c.id] = c.hash
                summary.missing += 1
                continue
            }
            guard let body = r.body else {
                summary.failed += 1
                log.warn("\(c.id): \(r.status == 0 ? r.error ?? "no answer" : "HTTP \(r.status)")")
                // Five in a row is an outage, not a bad conversation: stop and let the next run retry.
                consecutiveFailures += 1
                if consecutiveFailures >= 5 { summary.stopped = .unreachable; summary.detail = r.error ?? "HTTP \(r.status)"; break }
                continue
            }
            consecutiveFailures = 0
            guard let data = FileManager.default.contents(atPath: c.path) else {
                log.warn("cannot read \(c.path)")
                continue
            }
            let result = VoiceTranscripts.fillTranscripts(String(decoding: data, as: UTF8.self), VoiceTranscripts.transcriptsByTime(body))
            summary.missing += result.missing
            var finalHash = c.hash
            if result.filled > 0 {
                do {
                    try write(result.md, to: c.path)
                    summary.updated += 1
                    summary.filled += result.filled
                    finalHash = ConversationParser.sha256(Data(result.md.utf8))
                } catch {
                    summary.failed += 1
                    log.error("cannot write \(c.path): \(error.localizedDescription)")
                    continue
                }
            }
            // Gaps ChatGPT has no transcript for: remembered, so the next run skips this file.
            if result.missing > 0 { memo[c.id] = finalHash } else { memo[c.id] = nil }
        }
        saveMemo(memo)
        return summary
    }

    /// Atomic replace that keeps the file's permissions.
    private func write(_ text: String, to path: String) throws {
        let fm = FileManager.default
        let mode = (try? fm.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber) ?? NSNumber(value: 0o644)
        let tmp = path + ".tmp"
        try Data(text.utf8).write(to: URL(fileURLWithPath: tmp))
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: tmp)
        if rename(tmp, path) != 0 {
            let why = String(cString: strerror(errno))
            try? fm.removeItem(atPath: tmp)
            throw NSError(domain: "Voice", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "rename: \(why)"])
        }
    }
}

private extension String {
    var isEmptyAfterJSTrim: Bool { JSText.trim(self).isEmpty }
}
