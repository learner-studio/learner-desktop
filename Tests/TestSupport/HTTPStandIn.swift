import Foundation
import Network

/// The test lanes' one HTTP server: HTTP/1.1 on 127.0.0.1 over real TCP (Network.framework),
/// standing in for learner-server, chatgpt.com or screenpipe. `handler` answers each
/// request (a Response can be delayed); `mode` can instead drop every connection (a server
/// restarting) or hold every request forever (a stuck one).
// @unchecked: mutable state is behind `lock`; the listener calls back on its own queue.
public final class HTTPStandIn: @unchecked Sendable {
    public enum Mode { case answer, refuse, hang }

    public struct Request: Sendable {
        public let method: String
        public let path: String
        public let headers: [String: String]
        public let body: Data

        public func header(_ name: String) -> String? { headers[name.lowercased()] }
        public var json: [String: Any]? { try? JSONSerialization.jsonObject(with: body) as? [String: Any] }
        public var data: [String: Any]? { json?["data"] as? [String: Any] }
    }

    public struct Response: Sendable {
        public var status: Int
        public var body: Data
        /// Holds the answer back (a slow server).
        public var delay: TimeInterval = 0

        public init(status: Int, body: Data, delay: TimeInterval = 0) {
            self.status = status
            self.body = body
            self.delay = delay
        }

        public static func json(_ status: Int, _ object: Any, delay: TimeInterval = 0) -> Response {
            Response(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), delay: delay)
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "http-stand-in")
    private let lock = NSLock()
    private var seen: [Request] = []
    private var held: [NWConnection] = []
    private var handlerFn: (Request) -> Response
    private var _mode = Mode.answer
    public private(set) var port: UInt16 = 0

    public var baseURL: String { "http://127.0.0.1:\(port)" }
    public var url: URL { URL(string: baseURL)! }
    public var requests: [Request] { lock.withLock { seen } }
    public var handler: (Request) -> Response {
        get { lock.withLock { handlerFn } }
        set { lock.withLock { handlerFn = newValue } }
    }
    public var mode: Mode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue } }
    }

    public init(_ handler: @escaping (Request) -> Response) throws {
        handlerFn = handler
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self = self else { return }
            conn.start(queue: self.queue)
            switch self.mode {
            case .refuse: conn.cancel()
            case .hang: self.lock.withLock { self.held.append(conn) }
            case .answer: self.receive(conn, Data())
            }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
        if port == 0 { throw NSError(domain: "HTTPStandIn", code: 1, userInfo: [NSLocalizedDescriptionKey: "listener did not start"]) }
    }

    deinit { stop() }

    public func stop() {
        listener.cancel()
        lock.withLock { held.forEach { $0.cancel() }; held.removeAll() }
    }

    private func receive(_ conn: NWConnection, _ buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self = self else { return }
            var buf = buffer
            if let d = data { buf.append(d) }
            if let req = HTTPStandIn.parse(buf) {
                self.lock.withLock { self.seen.append(req) }
                let res = self.handler(req)
                self.queue.asyncAfter(deadline: .now() + res.delay) { self.respond(conn, res) }
            } else if complete || error != nil {
                conn.cancel()
            } else {
                self.receive(conn, buf)
            }
        }
    }

    private func respond(_ conn: NWConnection, _ res: Response) {
        var head = "HTTP/1.1 \(res.status) \(res.status < 400 ? "OK" : "Error")\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(res.body.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + res.body, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// A complete request (headers and Content-Length bytes of body), or nil to read more.
    static func parse(_ buf: Data) -> Request? {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = head[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = buf[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(body.prefix(length)))
    }
}
