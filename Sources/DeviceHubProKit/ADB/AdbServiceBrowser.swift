import Foundation
import Network

public struct BonjourServiceName: Equatable, Hashable, Sendable {
    public let name: String
    public let type: String
    public init(name: String, type: String) {
        self.name = name
        self.type = type
    }
}

/// One event of the app's own Bonjour browse for adb's wireless services.
public enum AdbBrowseEvent: Equatable, Sendable {
    /// The services currently visible (instance name and type).
    case services([BonjourServiceName])
    case access(LocalNetworkAccess)
}

/// The app's Bonjour browse for `_adb-tls-connect._tcp` and
/// `_adb-tls-pairing._tcp`. The browse runs while the stream is consumed and
/// stops when the consumer's task ends.
public protocol AdbServiceBrowsing: Sendable {
    func events() -> AsyncStream<AdbBrowseEvent>
}

/// `NWBrowser`-backed browse. Run by the app itself, which holds the Local
/// Network permission (`NSBonjourServices` in packaging/Info.plist).
public final class NWAdbServiceBrowser: AdbServiceBrowsing {
    public static let serviceTypes = ["_adb-tls-connect._tcp", "_adb-tls-pairing._tcp"]

    public init() {}

    public func events() -> AsyncStream<AdbBrowseEvent> {
        AsyncStream { continuation in
            let session = Session(continuation: continuation)
            session.start()
            continuation.onTermination = { _ in session.stop() }
        }
    }

    /// All state is touched on `queue` only.
    private final class Session: @unchecked Sendable {
        private let queue = DispatchQueue(label: "io.github.gitemre.devicehubpro.adb-browse")
        private let continuation: AsyncStream<AdbBrowseEvent>.Continuation
        private var browsers: [NWBrowser] = []
        private var results: [String: Set<BonjourServiceName>] = [:]
        private var access: [String: LocalNetworkAccess] = [:]
        private var lastAccess: LocalNetworkAccess?
        private var lastServices: Set<BonjourServiceName>?

        init(continuation: AsyncStream<AdbBrowseEvent>.Continuation) {
            self.continuation = continuation
        }

        func start() {
            queue.async { [self] in
                for type in NWAdbServiceBrowser.serviceTypes {
                    let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
                    browser.stateUpdateHandler = { [weak self] state in
                        self?.handle(state: state, type: type)
                    }
                    browser.browseResultsChangedHandler = { [weak self] found, _ in
                        self?.handle(results: found, type: type)
                    }
                    browsers.append(browser)
                    browser.start(queue: queue)
                }
            }
        }

        func stop() {
            queue.async { [self] in
                for browser in browsers { browser.cancel() }
                browsers = []
            }
        }

        private func handle(state: NWBrowser.State, type: String) {
            switch state {
            case .ready:
                access[type] = .allowed
            case .waiting(let error), .failed(let error):
                if case .dns(let code) = error, LocalNetworkPolicy.access(forDNSServiceError: code) == .denied {
                    access[type] = .denied
                }
            default:
                break
            }
            let combined: LocalNetworkAccess = access.values.contains(.denied)
                ? .denied
                : (access.values.contains(.allowed) ? .allowed : .unknown)
            if combined != lastAccess {
                lastAccess = combined
                continuation.yield(.access(combined))
            }
        }

        private func handle(results found: Set<NWBrowser.Result>, type: String) {
            var names = Set<BonjourServiceName>()
            for result in found {
                if case .service(let name, let serviceType, _, _) = result.endpoint {
                    names.insert(BonjourServiceName(name: name, type: serviceType))
                }
            }
            results[type] = names
            let all = results.values.reduce(into: Set<BonjourServiceName>()) { $0.formUnion($1) }
            guard all != lastServices else { return }
            lastServices = all
            continuation.yield(.services(all.sorted { ($0.type, $0.name) < ($1.type, $1.name) }))
        }
    }
}
