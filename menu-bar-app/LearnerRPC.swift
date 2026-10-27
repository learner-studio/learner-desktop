import Foundation

// MARK: - HTTP

/// One HTTP exchange. `status` 0 means no response at all; `error` then says why.
struct HTTPReply {
    let status: Int
    let body: Data?
    let error: String?
}

/// How the app talks HTTP. Tests swap in a stand-in.
protocol HTTPTransport: Sendable {
    /// Never waits longer than `timeout`.
    func send(_ request: URLRequest, timeout: TimeInterval) -> HTTPReply
}

/// URLSession, waited on with a hard bound: URLSession's own timeout is an idle timeout,
/// so the semaphore wait is what keeps a call inside `timeout`.
struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    init(session: URLSession = URLSessionTransport.ephemeral) { self.session = session }

    /// No cookie jar, no cache: every request carries exactly the headers it was given.
    static let ephemeral: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    func send(_ request: URLRequest, timeout: TimeInterval) -> HTTPReply {
        var req = request
        req.timeoutInterval = max(1, timeout)
        let reply = Locked(HTTPReply(status: 0, body: nil, error: "no answer in \(Int(timeout)) s"))
        let done = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: req) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let why = error.map { e -> String in
                let ns = e as NSError
                return "\(ns.localizedDescription) (\(ns.domain) \(ns.code))"
            }
            reply.value = HTTPReply(status: status, body: data, error: status == 0 ? (why ?? "no response") : nil)
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + max(0.05, timeout)) == .timedOut {
            task.cancel()
            return HTTPReply(status: 0, body: nil, error: "no answer in \(String(format: "%.0f", timeout)) s")
        }
        return reply.value
    }
}

// MARK: - learner-server RPC

/// The one learner-server client the outbox, the heartbeat and the chat archive share:
/// POST `{"data": input}` to `<baseURL>/rpc/<name>` with the device key in `x-api-key`
/// (spec: learner-server docs/learner-desktop-api.md; wire shapes in contract/).
final class LearnerRPC: Sendable {
    /// What a reply means for the caller, as the TypeScript client classified it.
    enum Kind: Equatable {
        case ok
        /// 400 / 422: the payload itself is refused. Resending it unchanged never helps.
        case rejected
        /// 401 / 403: the device key is missing or refused.
        case auth
        /// 413
        case tooLarge
        /// 408 / 429 / 5xx / no answer: try again later.
        case transient
        /// Any other status (404, 405 ...): a server or URL problem, not this payload's.
        case unexpected
        /// No device key to send.
        case noKey
    }

    struct Reply {
        let status: Int
        let kind: Kind
        /// The `data` of a 2xx reply (unwrapped), or the parsed error body.
        let body: Any?
        let error: String?

        var describe: String {
            switch kind {
            case .noKey: return "no device key"
            default: return status == 0 ? "no answer (\(error ?? "unknown"))" : "HTTP \(status)"
            }
        }

        /// The server's `message` (error replies), for logs: never payload text.
        var message: String? { (body as? [String: Any])?["message"] as? String }
    }

    static let defaultBaseURL = "https://dev.biztoolz.app/learner-api"
    static let shared = LearnerRPC()

    let baseURL: String
    let clientId: String
    private let transport: HTTPTransport
    private let keySource: @Sendable (TimeInterval) -> String?
    private let log = Log("RPC")
    private let cachedKey = Locked<String?>(nil)

    init(baseURL: String = ProcessInfo.processInfo.environment["LEARNER_API_URL"] ?? LearnerRPC.defaultBaseURL,
         clientId: String = "ben-mbp", transport: HTTPTransport = URLSessionTransport(),
         key: (@Sendable (TimeInterval) -> String?)? = nil) {
        self.baseURL = baseURL.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        self.clientId = clientId
        self.transport = transport
        self.keySource = key ?? LearnerRPC.environmentOrKeychainKey
    }

    static func classify(_ status: Int) -> Kind {
        switch status {
        case 200..<300: return .ok
        case 400, 422: return .rejected
        case 401, 403: return .auth
        case 413: return .tooLarge
        case 0, 408, 429, 500...: return .transient
        default: return .unexpected
        }
    }

    /// The device key: LEARNER_API_KEY (tests), else the Keychain item the operator stored
    /// with `security add-generic-password -s learner-server -a ben-mbp`, read through
    /// /usr/bin/security (which that item trusts, so a rebuilt app is not prompted) and
    /// bounded, so a locked keychain's prompt cannot stall a job.
    static func environmentOrKeychainKey(timeout: TimeInterval) -> String? {
        if let k = ProcessInfo.processInfo.environment["LEARNER_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty { return k }
        let r = ChildProcess.run("/usr/bin/security", ["find-generic-password", "-s", "learner-server", "-a", "ben-mbp", "-w"],
                                 timeout: max(1, timeout))
        let key = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.status == 0 && !key.isEmpty { return key }
        Log("RPC").noisy("no device key in the Keychain (learner-server / ben-mbp): \(r.stopped ?? "security exit \(r.status.map(String.init) ?? "?")")")
        return nil
    }

    /// The cached key, read once (and again after `forgetKey`).
    func key(timeout: TimeInterval = 10) -> String? {
        if let k = cachedKey.value { return k }
        let k = keySource(timeout)
        cachedKey.value = k
        return k
    }

    /// After a 401/403, or when the user asks to retry: read the Keychain again.
    func forgetKey() { cachedKey.value = nil }

    /// One call, bounded by `timeout` (the key lookup included). Never throws.
    func call(_ name: String, _ input: [String: Any], timeout: TimeInterval = 20) -> Reply {
        let started = Date()
        guard let key = key(timeout: min(10, timeout)) else { return Reply(status: 0, kind: .noKey, body: nil, error: "no device key") }
        guard let url = URL(string: "\(baseURL)/rpc/\(name)") else {
            log.error("\(name): bad base URL \(baseURL)")
            return Reply(status: 0, kind: .unexpected, body: nil, error: "bad URL")
        }
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: ["data": input])
        } catch {
            log.error("\(name): input is not JSON: \(error.localizedDescription)")
            return Reply(status: 0, kind: .rejected, body: nil, error: "input is not JSON")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("application/json", forHTTPHeaderField: "accept")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.httpBody = body
        let left = max(0.05, timeout - Date().timeIntervalSince(started))
        let r = transport.send(req, timeout: left)
        let kind = LearnerRPC.classify(r.status)
        if r.status == 0 { log.noisy("\(name): no answer from \(baseURL): \(r.error ?? "unknown")") }
        if kind == .auth { forgetKey() }
        var parsed: Any? = r.body.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
        if kind == .ok, let envelope = parsed as? [String: Any], let data = envelope["data"] { parsed = data }
        return Reply(status: r.status, kind: kind, body: parsed, error: r.error)
    }

    /// GET <baseURL>/api/health (public, no key): true when the server answers 200.
    func health(timeout: TimeInterval = 10) -> HTTPReply {
        guard let url = URL(string: "\(baseURL)/api/health") else { return HTTPReply(status: 0, body: nil, error: "bad URL") }
        return transport.send(URLRequest(url: url), timeout: timeout)
    }
}

/// The names the tray still uses (base URL for its health probe, client id for the
/// heartbeat).
enum LearnerAPI {
    static var baseURL: String { LearnerRPC.shared.baseURL }
    static var clientId: String { LearnerRPC.shared.clientId }
}

/// The chat, outbox and update-check workflows, as jobs. `install` creates them (which
/// registers them with the Scheduler, whose ticks run them) before `Scheduler.start()`.
enum ChatAndOutboxJobs {
    /// Export (hourly), Archive (launch, after each export, hourly), Outbox (8 s), Heartbeat
    /// (5 min, `heartbeat` builds its input only when one is due), UpdateCheck (1 min).
    static func install(heartbeat: @escaping @Sendable () -> [String: Any]) {
        _ = VaultExport.shared
        _ = Archive.shared
        OutboxSender.shared.setHeartbeatInput(heartbeat)
        _ = ScreenpipeUpdateCheck.shared
    }

    /// At quit, after the outbox drain: stop child programs that would outlive the app.
    static func stopForQuit() {
        VaultExport.shared.stopForQuit()
        ScreenpipeUpdateCheck.shared.stopForQuit()
    }
}

/// A Job outcome that clears an earlier problem: `.idle` leaves `problemSince` set, so a
/// run that found nothing to do after a failure must report `.ok` once.
func idleOrRecovered(_ job: Job, _ summary: String) -> Job.Outcome {
    let s = job.snapshot
    return s.problemSince == nil && !s.blocked ? .idle : .ok(summary)
}
