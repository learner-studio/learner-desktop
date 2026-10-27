import Foundation
import Network

/// A local HTTP server for medium tests: answers each request with `handler` and records
/// what it was asked. Real TCP, real URLSession on the app side. A handler status of 0
/// drops the connection without answering.
public final class StandInServer: @unchecked Sendable {
    public struct Request {
        public let method: String
        public let path: String
        public let headers: [String: String]
        public let body: Data
    }
    public typealias Handler = (Request) -> (status: Int, body: Data)

    private let listener: NWListener
    private let queue = DispatchQueue(label: "standin")
    private let lock = NSLock()
    private var _requests: [Request] = []
    public var handler: Handler
    public private(set) var port: UInt16 = 0

    public var url: String { "http://127.0.0.1:\(port)" }
    public var requests: [Request] { lock.withLock { _requests } }

    public init(_ handler: @escaping Handler) throws {
        self.handler = handler
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    deinit { listener.cancel() }
    public func stop() { listener.cancel() }

    public static func json(_ status: Int, _ object: Any) -> (status: Int, body: Data) {
        (status, (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        var buffer = Data()
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, _ in
                guard let self = self else { return }
                if let data = data { buffer.append(data) }
                if let req = Self.parse(buffer) {
                    self.lock.withLock { self._requests.append(req) }
                    let (status, body) = self.handler(req)
                    if status == 0 { c.cancel(); return }
                    let head = "HTTP/1.1 \(status) X\r\nContent-Length: \(body.count)\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n"
                    c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
                } else if done {
                    c.cancel()
                } else {
                    read()
                }
            }
        }
        read()
    }

    /// A complete request (headers + Content-Length body), or nil if more is needed.
    private static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = head.first?.split(separator: " ") ?? []
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            if let i = line.firstIndex(of: ":") {
                headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: first.count > 0 ? String(first[0]) : "", path: first.count > 1 ? String(first[1]) : "",
                       headers: headers, body: Data(body.prefix(length)))
    }
}
