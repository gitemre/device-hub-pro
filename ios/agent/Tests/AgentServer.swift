import Foundation
import Network

// Minimal HTTP/1.1 server on Network.framework.
//
// Security constraints:
//  * The listener is bound to exactly one local address, the device-side address of
//    the CoreDevice tunnel, handed in through the test environment. If that address
//    does not exist on the phone, or the listener cannot be created or fails, the
//    server reports and stops. There is no fallback to any other address or to
//    "all interfaces".
//  * Every request must carry the per-launch token in `X-DeviceHubPro-Token`; without
//    it the answer is 401 and nothing runs. The token is never logged.
//  * As defence in depth a connection whose peer is not an IPv6 unique-local address
//    (fd00::/8, the tunnel's range) is closed before a byte is read.

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data
}

struct HTTPResponse {
    var status: Int
    var contentType: String
    var body: Data

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json", body: data)
    }
    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(["error": message], status: status)
    }
}

enum AgentServerError: Error, CustomStringConvertible {
    case badBindAddress
    case addressNotOnDevice
    case listenerFailed(String)
    case timeout

    var description: String {
        switch self {
        case .badBindAddress: return "DHP_BIND is not an IPv6 address"
        case .addressNotOnDevice: return "the bind address is not configured on any interface of this device"
        case .listenerFailed(let m): return "listener failed: \(m)"
        case .timeout: return "listener did not become ready"
        }
    }
}

final class AgentServer: @unchecked Sendable {
    private let token: [UInt8]
    private let port: UInt16
    private let address: IPv6Address
    private let queue = DispatchQueue(label: "devicehubpro.agent.server")
    private var listener: NWListener?
    /// Called on the main queue; must call `respond` exactly once.
    var handler: (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void = { _, r in r(.error(404, "no handler")) }

    /// Name of the interface that carries the bind address (for the findings, not for the network).
    private(set) var interfaceName: String = "?"
    private(set) var pinnedInterface = false

    init(bind: String, port: UInt16, token: String) throws {
        guard let a = IPv6Address(bind) else { throw AgentServerError.badBindAddress }
        self.address = a
        self.port = port
        self.token = Array(token.utf8)
    }

    /// Finds the interface that owns the address (getifaddrs). Throws if none does.
    private func interfaceOwningAddress() throws -> String {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { throw AgentServerError.addressNotOnDevice }
        defer { freeifaddrs(head) }
        let want = address.rawValue
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            if let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET6) {
                let bytes = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 -> [UInt8] in
                    withUnsafeBytes(of: sin6.pointee.sin6_addr) { Array($0) }
                }
                if Array(want) == bytes { return String(cString: cur.pointee.ifa_name) }
            }
            p = cur.pointee.ifa_next
        }
        throw AgentServerError.addressNotOnDevice
    }

    /// Starts and waits (up to 10 s) until the listener is ready. Throws on any failure.
    func start() throws {
        let ifname = try interfaceOwningAddress()
        interfaceName = ifname

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv6(address), port: NWEndpoint.Port(rawValue: port)!)
        // Pin the interface as well when Network.framework knows it.
        let monitor = NWPathMonitor()
        let sem = DispatchSemaphore(value: 0)
        var found: NWInterface?
        monitor.pathUpdateHandler = { path in
            found = path.availableInterfaces.first { $0.name == ifname }
            sem.signal()
        }
        monitor.start(queue: DispatchQueue(label: "devicehubpro.agent.path"))
        _ = sem.wait(timeout: .now() + 3)
        monitor.cancel()
        if let found {
            params.requiredInterface = found
            pinnedInterface = true
        }

        let l = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        var failure: String?
        l.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let e): failure = "\(e)"; ready.signal()
            case .waiting(let e): failure = "waiting: \(e)"; ready.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        listener = l
        if ready.wait(timeout: .now() + 10) == .timedOut { l.cancel(); throw AgentServerError.timeout }
        if let failure { l.cancel(); throw AgentServerError.listenerFailed(failure) }
    }

    func stop() { listener?.cancel(); listener = nil }

    // MARK: connections

    private func peerIsTunnelRange(_ c: NWConnection) -> Bool {
        if case .hostPort(let host, _) = c.endpoint, case .ipv6(let a) = host {
            return a.rawValue.first == 0xfd
        }
        return false
    }

    private func accept(_ c: NWConnection) {
        guard peerIsTunnelRange(c) else { c.cancel(); return }
        c.start(queue: queue)
        process(c, Data())
    }

    private func process(_ c: NWConnection, _ buffer: Data) {
        var buf = buffer
        if let req = Self.parse(&buf) {
            let keepAlive = req.headers["connection"]?.lowercased() != "close"
            authorizeAndDispatch(req) { resp in
                self.send(c, resp, keepAlive: keepAlive) {
                    if keepAlive { self.process(c, buf) } else { c.cancel() }
                }
            }
            return
        }
        if buf.count > 2_000_000 { c.cancel(); return }
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            var b = buf
            if let data { b.append(data) }
            if error != nil || (isComplete && data == nil) { c.cancel(); return }
            self.process(c, b)
        }
    }

    private func authorizeAndDispatch(_ req: HTTPRequest, _ respond: @escaping (HTTPResponse) -> Void) {
        let given = Array((req.headers["x-devicehubpro-token"] ?? "").utf8)
        var diff = given.count ^ token.count
        for i in 0..<min(given.count, token.count) { diff |= Int(given[i] ^ token[i]) }
        guard diff == 0, !token.isEmpty else {
            respond(.error(401, "unauthorized"))
            return
        }
        DispatchQueue.main.async { self.handler(req, respond) }
    }

    private func send(_ c: NWConnection, _ r: HTTPResponse, keepAlive: Bool, done: @escaping () -> Void) {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 500: "Internal Server Error"][r.status] ?? "Status"
        var head = "HTTP/1.1 \(r.status) \(reason)\r\n"
        head += "Content-Type: \(r.contentType)\r\nContent-Length: \(r.body.count)\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        var out = Data(head.utf8)
        out.append(r.body)
        c.send(content: out, completion: .contentProcessed { _ in done() })
    }

    /// Extracts one complete request from the front of `buf`, or nil.
    static func parse(_ buf: inout Data) -> HTTPRequest? {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headText = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { buf.removeAll(); return nil }
        var headers: [String: String] = [:]
        for l in lines {
            if let i = l.firstIndex(of: ":") {
                headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard buf.distance(from: bodyStart, to: buf.endIndex) >= length else { return nil }
        let body = Data(buf[bodyStart..<buf.index(bodyStart, offsetBy: length)])
        buf.removeSubrange(buf.startIndex..<buf.index(bodyStart, offsetBy: length))
        buf = Data(buf)  // re-base indices
        let target = String(requestLine[1])
        var path = target
        var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            for pair in target[target.index(after: q)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                query[kv[0]] = kv.count > 1 ? (kv[1].removingPercentEncoding ?? kv[1]) : ""
            }
        }
        return HTTPRequest(method: String(requestLine[0]), path: path, query: query, headers: headers, body: body)
    }
}
