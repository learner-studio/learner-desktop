import Foundation

// MARK: - Pairing with learner-server

/// How this app finds and trusts its learner-server, the same machine or another
/// (learner-server docs/specs/server-desktop-pairing.md; wire shapes in contract/desktop.ts).
///
/// - The pairing payload `{apiUrl, clientId, apiKey}` is the trust anchor. The server's
///   installer (same machine) or its operator (remote) writes it; the app imports it once:
///   the key goes to the Keychain, the URL and client id are pinned, the file is deleted.
/// - Before a key goes to a URL, `GET <url>/api/health` must say `product: learner-server`
///   and `contract: 1`.
/// - The key never goes to an origin other than the pinned one. When the server advertises a
///   different API URL, the owner is asked (the tray offers it); nothing switches by itself.
enum Pairing {
    static let product = "learner-server"
    static let contract = 1
    static let urlKey = "learner_api_url"
    static let clientKey = "learner_client_id"
    /// Keychain service of the device key (account: the client id).
    static let keychainService = "learner-server"

    /// Where the installer leaves the payload (LEARNER_PAIRING_FILE overrides).
    static var payloadPath: String {
        ProcessInfo.processInfo.environment["LEARNER_PAIRING_FILE"]
            ?? NSHomeDirectory() + "/Library/Application Support/Learner/desktop-pairing.json"
    }

    struct Payload: Equatable {
        let apiUrl: String
        let clientId: String
        let apiKey: String
    }

    /// The contract's DesktopClientId.
    static func validClientId(_ id: String) -> Bool {
        id.range(of: #"^[a-z0-9][a-z0-9-]{0,62}$"#, options: .regularExpression) != nil
    }

    /// The contract's PairingUrl: absolute http(s), no credentials, query or fragment.
    static func validURL(_ s: String) -> Bool {
        guard let c = URLComponents(string: s), let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              c.host?.isEmpty == false else { return false }
        return c.user == nil && c.password == nil && c.query == nil && c.fragment == nil
    }

    /// Trailing slashes off: the server compares URLs that way, and so does the app.
    static func normalized(_ url: String) -> String {
        url.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }

    static func parse(_ data: Data) -> Result<Payload, PairingError> {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failure(.refused("not JSON")) }
        guard let url = json["apiUrl"] as? String, validURL(url) else { return .failure(.refused("apiUrl is not an http(s) URL")) }
        guard let id = json["clientId"] as? String, validClientId(id) else { return .failure(.refused("clientId is not a device id")) }
        guard let key = json["apiKey"] as? String, key.count >= 16 else { return .failure(.refused("apiKey is missing or too short")) }
        // It is passed to `security -i` as one word: no spaces, quotes or control characters.
        guard key.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 && $0 != "\"" && $0 != "'" && $0 != "\\" }) else {
            return .failure(.refused("apiKey has characters a device key never has"))
        }
        return .success(Payload(apiUrl: normalized(url), clientId: id, apiKey: key))
    }

    enum PairingError: Error, Equatable {
        /// The payload itself is wrong: left in place for the owner to replace.
        case refused(String)
        /// The URL did not answer as a learner-server: left in place, tried again next launch.
        case notLearnerServer(String)
        case keychain(String)
    }

    /// `GET <apiUrl>/api/health` (no key sent) answers `product: learner-server, contract: 1`.
    static func checkServer(_ apiUrl: String, transport: HTTPTransport, timeout: TimeInterval = 8) -> Result<Void, PairingError> {
        guard let url = URL(string: normalized(apiUrl) + "/api/health") else { return .failure(.notLearnerServer("bad URL")) }
        let r = transport.send(URLRequest(url: url), timeout: timeout)
        guard r.status == 200 else { return .failure(.notLearnerServer(r.status == 0 ? r.error ?? "no answer" : "health HTTP \(r.status)")) }
        let json = r.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        guard json?["product"] as? String == product else { return .failure(.notLearnerServer("not a learner-server")) }
        guard (json?["contract"] as? NSNumber)?.intValue == contract else {
            return .failure(.notLearnerServer("pairing contract \((json?["contract"] as? NSNumber)?.stringValue ?? "?"), this app speaks \(contract)"))
        }
        return .success(())
    }

    /// The pinned API URL and client id, or nil before a payload was imported.
    static func pinned(_ defaults: UserDefaults = .standard) -> (apiUrl: String, clientId: String)? {
        guard let url = defaults.string(forKey: urlKey), let id = defaults.string(forKey: clientKey) else { return nil }
        return (url, id)
    }

    static func pin(apiUrl: String, clientId: String, _ defaults: UserDefaults = .standard) {
        defaults.set(normalized(apiUrl), forKey: urlKey)
        defaults.set(clientId, forKey: clientKey)
    }

    /// Stores the key under the client id, readable by /usr/bin/security (which the app reads
    /// it through, so a rebuilt app is not prompted). The key goes in on stdin, never as an argument.
    static func keychainStore(clientId: String, key: String) -> Result<Void, PairingError> {
        let command = "add-generic-password -U -s \(keychainService) -a \(clientId) -T /usr/bin/security -w \"\(key)\"\n"
        let r = ChildProcess.run("/usr/bin/security", ["-i"], timeout: 15, stderr: true, input: Data(command.utf8))
        return r.status == 0 && !r.output.contains("error") ? .success(()) : .failure(.keychain(r.stopped ?? "security exit \(r.status.map(String.init) ?? "?")"))
    }

    /// Imports the payload at `path` when there is one: checks it and the server, stores the
    /// key, pins the URL and client id, and deletes the file. nil: no payload to import.
    @discardableResult
    static func importPayload(path: String = payloadPath, defaults: UserDefaults = .standard, transport: HTTPTransport,
                              store: (String, String) -> Result<Void, PairingError> = { keychainStore(clientId: $0, key: $1) },
                              log: Log = Log("Pairing")) -> Result<Payload, PairingError>? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let outcome: Result<Payload, PairingError> = {
            switch parse(data) {
            case .failure(let e): return .failure(e)
            case .success(let p):
                if case .failure(let e) = checkServer(p.apiUrl, transport: transport) { return .failure(e) }
                if case .failure(let e) = store(p.clientId, p.apiKey) { return .failure(e) }
                pin(apiUrl: p.apiUrl, clientId: p.clientId, defaults)
                return .success(p)
            }
        }()
        switch outcome {
        case .success(let p):
            try? FileManager.default.removeItem(atPath: path)
            log.info("paired with \(p.apiUrl) as \(p.clientId); the key is in the Keychain and the pairing file is deleted")
        case .failure(let e):
            log.warn("pairing file \(path) not imported: \(e); left in place")
        }
        return outcome
    }
}

// MARK: - What the server advertises

/// getPairingEndpoints's answer, as the app keeps it (contract GetPairingEndpointsOutput).
struct PairingEndpoints: Codable, Equatable, Sendable {
    var topology: String
    var endpointsVersion: String
    var apiBase: String
    var rpcBase: String
    /// Open-in-browser links only; nil: this install publishes none (the line is hidden).
    var web: String?
    var growthbookApp: String?
    /// remote: this Mac runs learner-upload for its CLI sessions.
    var uploaderRequired: Bool
    var pairingState: String

    static func parse(_ any: Any?) -> PairingEndpoints? {
        guard let o = any as? [String: Any], let topology = o["topology"] as? String,
              let version = o["endpointsVersion"] as? String,
              let api = o["api"] as? [String: Any], let base = api["base"] as? String, let rpcBase = api["rpcBase"] as? String,
              let uploader = o["uploader"] as? [String: Any], let required = uploader["required"] as? Bool else { return nil }
        let web = o["web"] as? String
        let growthbook = (o["growthbook"] as? [String: Any])?["app"] as? String
        return PairingEndpoints(topology: topology, endpointsVersion: version, apiBase: base, rpcBase: rpcBase,
                                web: web.flatMap { Pairing.validURL($0) ? $0 : nil },
                                growthbookApp: growthbook.flatMap { Pairing.validURL($0) ? $0 : nil },
                                uploaderRequired: required,
                                pairingState: (o["device"] as? [String: Any])?["pairingState"] as? String ?? "unknown")
    }
}

/// The endpoints the server last advertised, kept on disk, refreshed when the heartbeat's
/// `endpointsVersion` differs from the one held (so a reconfigured server reaches the tray
/// within one beat).
final class PairingLink: Sendable {
    static let shared = PairingLink()

    private struct State {
        var held: PairingEndpoints?
        /// The server advertises an API URL other than the pinned one: for the owner to confirm.
        var moved: String?
        var onChange: (@Sendable (PairingEndpoints?) -> Void)?
    }
    private let state: Locked<State>
    private let path: String
    private let log = Log("Pairing")

    init(path: String = Paths.data + "/pairing-endpoints.json") {
        self.path = path
        let saved = FileManager.default.contents(atPath: path).flatMap { try? JSONDecoder().decode(PairingEndpoints.self, from: $0) }
        state = Locked(State(held: saved))
    }

    var held: PairingEndpoints? { state.value.held }
    /// An API URL the server advertises that is not the one in use, or nil.
    var moved: String? { state.value.moved }
    /// Called (on any thread) when what is held changes.
    var onChange: (@Sendable (PairingEndpoints?) -> Void)? {
        get { state.value.onChange }
        set { state.withLock { $0.onChange = newValue } }
    }

    /// This side, for the heartbeat (contract PairingReport).
    func report(apiUrlInUse: String, services: [(name: String, url: String)]) -> [String: Any] {
        var r: [String: Any] = [
            "apiUrlInUse": apiUrlInUse,
            "endpointsVersionHeld": held?.endpointsVersion as Any? ?? NSNull(),
            "services": services.filter { Pairing.validURL($0.url) }.prefix(20).map { ["name": $0.name, "url": $0.url] },
        ]
        if let host = Host.current().localizedName, !host.isEmpty { r["hostname"] = String(host.prefix(255)) }
        return r
    }

    /// After a heartbeat: refetch when the server's endpointsVersion is not the one held.
    func heartbeatReplied(_ body: Any?, rpc: LearnerRPC) {
        guard let version = (body as? [String: Any])?["endpointsVersion"] as? String, version != held?.endpointsVersion else { return }
        _ = refresh(rpc: rpc)
    }

    /// getPairingEndpoints for this device. The key only ever goes to `rpc`'s (pinned) URL.
    @discardableResult
    func refresh(rpc: LearnerRPC) -> LearnerRPC.Reply {
        let r = rpc.call("getPairingEndpoints", ["clientId": rpc.clientId])
        guard r.kind == .ok else {
            log.noisy("endpoints not refreshed: \(r.describe)")
            return r
        }
        guard let endpoints = PairingEndpoints.parse(r.body) else {
            log.warn("getPairingEndpoints answered something this app cannot read")
            return r
        }
        let inUse = Pairing.normalized(rpc.baseURL)
        let moved = Pairing.normalized(endpoints.apiBase) == inUse ? nil : Pairing.normalized(endpoints.apiBase)
        let (changed, callback): (Bool, (@Sendable (PairingEndpoints?) -> Void)?) = state.withLock { s in
            let changed = s.held != endpoints || s.moved != moved
            s.held = endpoints
            s.moved = moved
            return (changed, s.onChange)
        }
        if let moved, changed { log.warn("learner-server advertises its API at \(moved), not \(inUse): staying on \(inUse) until you confirm in the menu") }
        if changed {
            if let data = try? JSONEncoder().encode(endpoints) { try? data.write(to: URL(fileURLWithPath: path), options: .atomic) }
            log.info("endpoints \(endpoints.endpointsVersion): \(endpoints.topology), GrowthBook \(endpoints.growthbookApp ?? "none"), web \(endpoints.web ?? "none"), uploader \(endpoints.uploaderRequired ? "on" : "off")")
            callback?(endpoints)
        }
        return r
    }
}
