import Foundation

/// One request to the input runner. The set is closed: only the endpoints
/// below can be built (no launch, probe, host, address or screenshot helper of
/// the spike's runner is ever asked for).
public struct PhysicalControlRequest: Equatable, Sendable {
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
    }

    public let method: Method
    public let path: String
    public let query: [String: String]
    public let body: Data?

    private init(_ method: Method, _ path: String, query: [String: String] = [:], json: [String: Any]? = nil) {
        self.method = method
        self.path = path
        self.query = query
        // Sorted keys: the same request always has the same bytes.
        body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
    }

    public static let status = PhysicalControlRequest(.get, "/status")
    public static let screen = PhysicalControlRequest(.get, "/screen")
    public static let orientation = PhysicalControlRequest(.get, "/orientation")
    public static let stop = PhysicalControlRequest(.post, "/stop", json: [:])

    /// `ref` is the foreground app's bundle identifier: the coordinate
    /// reference the runner resolves the point against (faster than
    /// Springboard's big tree).
    /// `refs` are candidate bundle identifiers in priority order: the runner
    /// picks the first that is in the foreground (`ref`, when given, wins).
    public static func tap(x: Double, y: Double, ref: String?, refs: [String] = []) -> PhysicalControlRequest {
        var json: [String: Any] = ["x": x, "y": y]
        if let ref { json["ref"] = ref }
        if !refs.isEmpty { json["refs"] = refs }
        return PhysicalControlRequest(.post, "/tap", json: json)
    }

    public static func swipe(
        x1: Double, y1: Double, x2: Double, y2: Double, duration: Double, ref: String?,
        refs: [String] = []
    ) -> PhysicalControlRequest {
        var json: [String: Any] = ["x1": x1, "y1": y1, "x2": x2, "y2": y2, "duration": duration]
        if let ref { json["ref"] = ref }
        if !refs.isEmpty { json["refs"] = refs }
        return PhysicalControlRequest(.post, "/swipe", json: json)
    }

    public static func type(text: String, bundleID: String) -> PhysicalControlRequest {
        PhysicalControlRequest(.post, "/type", json: ["text": text, "bundleId": bundleID])
    }

    public static func button(_ button: PhysicalControlButton) -> PhysicalControlRequest {
        PhysicalControlRequest(.post, "/button", json: ["name": button.rawValue])
    }

    /// Presents Siri through public `XCUIDevice.shared.siriService`; `text`,
    /// when given, is processed as if it were recognised speech.
    public static func siri(text: String?) -> PhysicalControlRequest {
        var json: [String: Any] = [:]
        if let text, !text.isEmpty { json["text"] = text }
        return PhysicalControlRequest(.post, "/siri", json: json)
    }

    /// The App Switcher: a swipe up from the bottom edge, held, through the
    /// public `XCUICoordinate.press(forDuration:thenDragTo:...)`.
    public static let appSwitcher = PhysicalControlRequest(.post, "/appSwitcher", json: [:])

    public static func setOrientation(_ orientation: PhysicalControlOrientation) -> PhysicalControlRequest {
        PhysicalControlRequest(.post, "/orientation", json: ["value": orientation.rawValue])
    }

    public static func foreground(ids: [String]) -> PhysicalControlRequest {
        PhysicalControlRequest(.get, "/foreground", query: ["ids": ids.joined(separator: ",")])
    }
}

/// The runner's answer.
public struct PhysicalControlResponse: Equatable, Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    /// The body as a JSON object; nil when it is none.
    var object: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    /// The runner's error text (`{"error": "..."}`), when it sent one.
    var errorMessage: String {
        if let text = object?["error"] as? String { return text }
        return String(data: body.prefix(200), encoding: .utf8) ?? ""
    }
}

/// How the client reaches the runner: one request, one answer. The real one
/// is `PhysicalControlURLSessionTransport`; tests hand in a fake.
public protocol PhysicalControlTransport: Sendable {
    func send(_ request: PhysicalControlRequest, timeout: Duration) async throws -> PhysicalControlResponse
}

/// The real transport: HTTP over the CoreDevice tunnel with URLSession.
///
/// Every request carries the launch's token in `X-DeviceHubPro-Token`. The
/// session is ephemeral (no cache, no cookies, no credentials store) and
/// ignores the system's proxy settings: a request to the tunnel address is
/// never handed to a proxy.
public final class PhysicalControlURLSessionTransport: PhysicalControlTransport, @unchecked Sendable {
    private let endpoint: PhysicalControlEndpoint
    private let session: URLSession

    /// `configuration` is for tests (a `URLProtocol` stub); production uses
    /// the default.
    public init(endpoint: PhysicalControlEndpoint, configuration: URLSessionConfiguration? = nil) {
        self.endpoint = endpoint
        let configuration = configuration ?? URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // One warm connection: the runner handles one request at a time, so
        // a second connection would only cost a handshake. The session (and
        // its connection) lives as long as the transport; the session's
        // health poll keeps it warm between taps.
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.httpShouldUsePipelining = false
        configuration.timeoutIntervalForResource = 300
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// The URLRequest for `request` (public for the tests that pin its shape).
    func urlRequest(for request: PhysicalControlRequest, timeout: Duration) -> URLRequest {
        var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false)!
        components.path = request.path
        if !request.query.isEmpty {
            components.queryItems = request.query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var urlRequest = URLRequest(url: components.url!)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = Double(timeout.components.seconds)
            + Double(timeout.components.attoseconds) / 1e18
        urlRequest.setValue(endpoint.token.value, forHTTPHeaderField: PhysicalControlEndpoint.tokenHeader)
        if let body = request.body {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return urlRequest
    }

    public func send(_ request: PhysicalControlRequest, timeout: Duration) async throws -> PhysicalControlResponse {
        let urlRequest = urlRequest(for: request, timeout: timeout)
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw PhysicalControlError.badResponse("not an HTTP answer")
            }
            return PhysicalControlResponse(status: http.statusCode, body: data)
        } catch let error as PhysicalControlError {
            throw error
        } catch let error as CancellationError {
            throw error
        } catch {
            // The URL names the tunnel address: only the error's class and
            // code are kept.
            let nsError = error as NSError
            throw PhysicalControlError.transportFailed("\(nsError.domain) \(nsError.code)")
        }
    }
}
