import Foundation
import XCTest
@testable import DeviceHubProKit

// Fakes for "Control this iPhone": a transport, a runner process,
// a launcher and a provisioner. No test starts `xcodebuild`, opens a socket or
// touches a device.

/// A fake runner API: records every request and answers from `handler`.
final class FakeControlTransport: PhysicalControlTransport, @unchecked Sendable {
    typealias Handler = @Sendable (PhysicalControlRequest) async throws -> PhysicalControlResponse

    private let lock = NSLock()
    private var _requests: [PhysicalControlRequest] = []
    private var _handler: Handler

    init(handler: Handler? = nil) {
        _handler = handler ?? FakeControlTransport.defaultHandler
    }

    var requests: [PhysicalControlRequest] { lock.withLock { _requests } }
    func requests(path: String) -> [PhysicalControlRequest] { requests.filter { $0.path == path } }

    func setHandler(_ handler: @escaping Handler) {
        lock.withLock { _handler = handler }
    }

    func send(_ request: PhysicalControlRequest, timeout: Duration) async throws -> PhysicalControlResponse {
        let handler = lock.withLock { () -> Handler in
            _requests.append(request)
            return _handler
        }
        return try await handler(request)
    }

    static func json(_ object: [String: Any], status: Int = 200) -> PhysicalControlResponse {
        PhysicalControlResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    /// The runner's answers on a healthy iPhone 12 (portrait, 390x844 pt).
    static let defaultHandler: Handler = { request in
        switch (request.method, request.path) {
        case (.get, "/screen"):
            return json(["springboardFrameWidth": 390, "springboardFrameHeight": 844, "scale": 3])
        case (.get, "/orientation"):
            return json(["value": "portrait"])
        case (.post, "/orientation"):
            let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            return json(["ok": true, "value": body["value"] as? String ?? "portrait"])
        case (.get, "/foreground"):
            return json(["foreground": []])
        default:
            return json(["ok": true])
        }
    }
}

/// A fake runner process.
final class FakeRunnerProcess: PhysicalControlRunnerProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var _running = true
    private var _tail: String
    private var _signals: [String] = []
    /// Which signal ends it; nil ends only on kill.
    private let endsOn: Set<String>

    init(tail: String = "", endsOn: Set<String> = ["interrupt", "terminate", "kill"]) {
        _tail = tail
        self.endsOn = endsOn
    }

    var isRunning: Bool { lock.withLock { _running } }
    var outputTail: String { lock.withLock { _tail } }
    var signals: [String] { lock.withLock { _signals } }

    func die(tail: String? = nil) {
        lock.withLock {
            _running = false
            if let tail { _tail = tail }
        }
    }

    private func signal(_ name: String) {
        lock.withLock {
            _signals.append(name)
            if endsOn.contains(name) { _running = false }
        }
    }

    func interrupt() { signal("interrupt") }
    func terminate() { signal("terminate") }
    func kill() { signal("kill") }

    func waitForExit(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while isRunning {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }
}

/// A fake launcher: hands out processes and records how it was asked.
final class FakeRunnerLauncher: PhysicalControlRunnerLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var _configurations: [PhysicalControlLaunchConfiguration] = []
    private var _processes: [FakeRunnerProcess] = []
    private var _next: [FakeRunnerProcess] = []
    var failure: PhysicalControlError?

    /// The process the next launch returns (else a fresh healthy one).
    func queue(_ process: FakeRunnerProcess) { lock.withLock { _next.append(process) } }
    var configurations: [PhysicalControlLaunchConfiguration] { lock.withLock { _configurations } }
    var processes: [FakeRunnerProcess] { lock.withLock { _processes } }
    var launchCount: Int { lock.withLock { _configurations.count } }

    func launch(_ configuration: PhysicalControlLaunchConfiguration) throws -> any PhysicalControlRunnerProcess {
        if let failure { throw failure }
        return lock.withLock {
            _configurations.append(configuration)
            let process = _next.isEmpty ? FakeRunnerProcess() : _next.removeFirst()
            _processes.append(process)
            return process
        }
    }
}

/// A fake provisioner: no build, and the calls it saw.
final class FakeProvisioner: PhysicalControlProvisioning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(team: String, target: PhysicalControlTarget)] = []
    var wasBuilt: Bool
    var failure: PhysicalControlError?
    var progress: [String] = []

    init(wasBuilt: Bool = false) {
        self.wasBuilt = wasBuilt
    }

    var callCount: Int { lock.withLock { _calls.count } }
    var teams: [String] { lock.withLock { _calls.map(\.team) } }

    func ensureRunner(
        for target: PhysicalControlTarget,
        team: String,
        progress report: @escaping @Sendable (String) -> Void
    ) async throws -> PhysicalControlBuild {
        lock.withLock { _calls.append((team, target)) }
        if let failure { throw failure }
        for text in progress { report(text) }
        // The session hands progress to its own executor; give it a moment.
        if !progress.isEmpty { try await Task.sleep(for: .milliseconds(30)) }
        return PhysicalControlBuild(xctestrunURL: URL(fileURLWithPath: "/nonexistent/runner.xctestrun"), wasBuilt: wasBuilt)
    }
}

/// Everything a session test needs.
struct ControlHarness {
    static let team = "ABCDE12345"
    static let udid = "00000000-0000000000000000"
    static let address = "fd12:3456:789a::1"

    let session: PhysicalControlSession
    let transport: FakeControlTransport
    let launcher: FakeRunnerLauncher
    let provisioner: FakeProvisioner
    let snapshots: SnapshotLog
    /// The endpoints the session made transports for, oldest first.
    let endpoints: EndpointLog

    static func make(
        team: String? = ControlHarness.team,
        address: String? = ControlHarness.address,
        candidates: [String] = [],
        candidateSource: (@Sendable () -> [String])? = nil,
        wasBuilt: Bool = false,
        timing: PhysicalControlSession.Timing = ControlHarness.fastTiming,
        transport: FakeControlTransport = FakeControlTransport(),
        launcher: FakeRunnerLauncher = FakeRunnerLauncher(),
        makeToken: @escaping @Sendable () throws -> PhysicalControlToken = { try PhysicalControlToken.generate() }
    ) -> ControlHarness {
        let provisioner = FakeProvisioner(wasBuilt: wasBuilt)
        let snapshots = SnapshotLog()
        let endpoints = EndpointLog()
        let session = PhysicalControlSession(
            target: PhysicalControlTarget(hardwareUDID: udid, productType: "iPhone13,2"),
            team: { team },
            tunnelAddress: { address },
            candidates: { candidateSource?() ?? candidates },
            provisioner: provisioner,
            launcher: launcher,
            timing: timing,
            makeTransport: { endpoint in
                endpoints.add(endpoint)
                return transport
            },
            makeToken: makeToken,
            onChange: { snapshots.add($0) }
        )
        return ControlHarness(
            session: session,
            transport: transport,
            launcher: launcher,
            provisioner: provisioner,
            snapshots: snapshots,
            endpoints: endpoints
        )
    }

    static var fastTiming: PhysicalControlSession.Timing {
        var timing = PhysicalControlSession.Timing()
        timing.warmStart = .seconds(2)
        timing.firstRunStart = .seconds(4)
        timing.pollInterval = .milliseconds(5)
        timing.healthInterval = nil
        timing.actionTimeout = .seconds(2)
        timing.stopGrace = .milliseconds(80)
        return timing
    }
}

final class SnapshotLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshots: [PhysicalControlSnapshot] = []
    func add(_ snapshot: PhysicalControlSnapshot) { lock.withLock { _snapshots.append(snapshot) } }
    var all: [PhysicalControlSnapshot] { lock.withLock { _snapshots } }
}

final class EndpointLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _endpoints: [PhysicalControlEndpoint] = []
    func add(_ endpoint: PhysicalControlEndpoint) { lock.withLock { _endpoints.append(endpoint) } }
    var all: [PhysicalControlEndpoint] { lock.withLock { _endpoints } }
}

/// A fake control for the router's tests: records the calls and answers from
/// scripted results.
final class FakeControl: PhysicalControlling, @unchecked Sendable {
    enum Call: Equatable {
        case tap(CGPoint)
        case swipe(CGPoint, CGPoint, TimeInterval)
        case type(String, String)
        case press(PhysicalControlButton)
        case setOrientation(PhysicalControlOrientation)
        case siri(String?)
        case appSwitcher
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _terminated = 0
    var portrait: CGSize? = CGSize(width: 390, height: 844)
    var foreground: String? = "com.apple.mobilesafari"
    var currentOrientation: PhysicalControlOrientation = .portrait
    /// Thrown by the next action, once.
    var failure: PhysicalControlError?
    /// Awaited before every action returns (a gate for busy tests).
    var gate: (@Sendable () async -> Void)?

    var calls: [Call] { lock.withLock { _calls } }
    var terminated: Int { lock.withLock { _terminated } }

    private func record(_ call: Call) async throws {
        lock.withLock { _calls.append(call) }
        await gate?()
        if let failure = lock.withLock({ () -> PhysicalControlError? in
            defer { self.failure = nil }
            return self.failure
        }) { throw failure }
    }

    func start() async throws {}
    func stop() async {}
    func terminateNow() { lock.withLock { _terminated += 1 } }
    func snapshot() async -> PhysicalControlSnapshot { PhysicalControlSnapshot(state: .ready, orientation: currentOrientation) }
    func portraitSize() async -> CGSize? { portrait }
    func tap(_ point: CGPoint) async throws { try await record(.tap(point)) }
    func swipe(from: CGPoint, to: CGPoint, duration: TimeInterval) async throws { try await record(.swipe(from, to, duration)) }
    func type(_ text: String, bundleID: String) async throws { try await record(.type(text, bundleID)) }
    func press(_ button: PhysicalControlButton) async throws { try await record(.press(button)) }
    func setOrientation(_ orientation: PhysicalControlOrientation) async throws -> PhysicalControlOrientation {
        try await record(.setOrientation(orientation))
        currentOrientation = orientation
        return orientation
    }
    func orientation() async throws -> PhysicalControlOrientation { currentOrientation }
    func activateSiri(text: String?) async throws { try await record(.siri(text)) }
    func showAppSwitcher() async throws { try await record(.appSwitcher) }
    func foreground(ids: [String]) async throws -> [String] { foreground.map { [$0] } ?? [] }
    func foregroundApp() async throws -> String? { foreground }
}

/// Waits (a bounded poll) for `condition`.
func waitUntil(timeout: TimeInterval = 3, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// A candidate source whose answer and call count a test controls.
final class CandidateSource: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String]
    private var count = 0
    init(_ ids: [String]) { self.ids = ids }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func set(_ new: [String]) { lock.lock(); ids = new; lock.unlock() }
    func read() -> [String] { lock.lock(); defer { lock.unlock() }; count += 1; return ids }
}
