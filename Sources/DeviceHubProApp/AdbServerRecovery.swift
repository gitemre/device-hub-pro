import Foundation
import Network
import Observation
import DeviceHubProKit

/// Keeps the adb server able to reach Wi-Fi devices.
///
/// macOS gives the adb server (a long-lived `adb fork-server`) the Local
/// Network permission of the process that first started it. Started by a tool
/// without the permission, it sees no mDNS services and cannot connect to LAN
/// addresses ("No route to host"), while this app, which holds the
/// permission, can. The monitor browses Bonjour itself (`NWAdbServiceBrowser`),
/// compares with `adb mdns services` and, when `AdbBlockedDetector` confirms
/// the server is blocked, restarts adb from this process so the new server
/// inherits the app's permission. Runs only while the app is active and adb
/// exists; it never restarts adb while a recording or an install runs, nor
/// more than once per `AdbBlockedDetector.minimumRestartInterval`.
///
/// If the user denied the permission to Device Hub Pro the browse reports it
/// (`localNetworkAccess == .denied`), a restart cannot help, and the Pair
/// Nearby sheet shows a hint with a button for the System Settings pane.
///
/// The browse is what makes macOS ask "Allow Device Hub Pro to find devices on
/// local networks?", so nothing here runs until a wireless need arrives
/// (`wantLocalNetwork()`: the Pair Nearby Device sheet's Android tile, a
/// wireless device already connected, or a Mac that used wireless debugging
/// before): a first-time user is not asked before they have done anything.
@MainActor
@Observable
final class AdbServerRecovery {
    /// What the adb side of one check reads and does; the live one wraps the
    /// app's `AdbClient`.
    struct Probes {
        var mdnsRunning: @Sendable () async -> Bool
        var services: @Sendable () async -> [WirelessPairing.MdnsService]
        var restart: @Sendable () async throws -> Void
        var canReach: @Sendable (_ host: String, _ port: Int) async -> Bool

        static func live(_ client: AdbClient) -> Probes {
            Probes(
                mdnsRunning: { await client.mdnsDaemonRunning() },
                services: { (try? await client.mdnsServices()) ?? [] },
                restart: { try await client.restartServer() },
                canReach: { host, port in await LocalReachability.canReach(host: host, port: port) }
            )
        }
    }

    /// The app's own Local Network access, from the browse.
    private(set) var localNetworkAccess: LocalNetworkAccess = .unknown
    /// Whether anything needed the local network yet; until it did, `start()`
    /// does nothing (no Bonjour browse, so no permission prompt).
    private(set) var isLocalNetworkWanted: Bool
    var isLocalNetworkDenied: Bool { localNetworkAccess == .denied }
    /// How many times this run restarted adb.
    private(set) var restartCount = 0

    private let probes: Probes?
    private let browser: (any AdbServiceBrowsing)?
    private let status: StatusCenter
    private let now: @Sendable () -> Date
    private let checkInterval: Duration
    /// How long a "No route to host" signal stays valid for confirmation.
    private let noRouteValidity: TimeInterval = 30

    @ObservationIgnored var isBusy: @MainActor () -> Bool = { false }
    @ObservationIgnored var refresh: @MainActor () async -> Void = {}

    private var state = AdbBlockedState()
    private var tracker = ObservedServiceTracker()
    private var observed: [ObservedBonjourService] = []
    private var noRouteAt: Date?
    private var isRestarting = false
    private var isActive = false
    private var browseTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?

    init(
        probes: Probes?,
        browser: (any AdbServiceBrowsing)?,
        status: StatusCenter,
        localNetworkWanted: Bool = false,
        checkInterval: Duration = .seconds(4),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.isLocalNetworkWanted = localNetworkWanted
        self.probes = probes
        self.browser = browser
        self.status = status
        self.checkInterval = checkInterval
        self.now = now
    }

    // MARK: - Lifecycle

    /// Starts the browse and the check loop. A no-op without adb or a
    /// browser, and until the local network is wanted.
    func start() {
        guard isLocalNetworkWanted, probes != nil, let browser, browseTask == nil else { return }
        browseTask = Task { [weak self] in
            for await event in browser.events() {
                guard let self, !Task.isCancelled else { return }
                self.apply(event)
            }
        }
        tickTask = Task { [weak self, checkInterval] in
            while !Task.isCancelled {
                // Best effort: a failed sleep means cancellation, which the loop condition sees.
                try? await Task.sleep(for: checkInterval)
                guard let self, !Task.isCancelled else { return }
                await self.check()
            }
        }
    }

    /// Stops both; the browse ends, and what it saw is forgotten.
    func stop() {
        browseTask?.cancel()
        tickTask?.cancel()
        browseTask = nil
        tickTask = nil
        observed = []
        tracker = ObservedServiceTracker()
        state.consecutiveBlockedChecks = 0
        noRouteAt = nil
    }

    func setActive(_ active: Bool) {
        isActive = active
        if active { start() } else { stop() }
    }

    /// The first wireless need: from now on the browse runs while the app is
    /// active (and starts right away). Idempotent.
    func wantLocalNetwork() {
        isLocalNetworkWanted = true
        start()
    }

    func apply(_ event: AdbBrowseEvent) {
        switch event {
        case .services(let names):
            observed = tracker.update(names: names, now: now())
        case .access(let access):
            localNetworkAccess = access
        }
    }

    // MARK: - Signals

    /// A failed `adb connect` to `address`: "No route to host" for an address
    /// this process can reach itself is the second signal that the server is
    /// blocked.
    func noteConnectFailure(address: String, message: String) {
        guard probes != nil, AdbBlockedDetector.isNoRouteToHost(message),
              let separator = address.lastIndex(of: ":"),
              let port = Int(address[address.index(after: separator)...])
        else { return }
        let host = String(address[..<separator]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        Task { [weak self] in
            guard let self, let probes = self.probes else { return }
            guard await probes.canReach(host, port) else { return }
            self.noRouteAt = self.now()
            await self.check()
        }
    }

    // MARK: - One check

    /// One detection step; restarts adb when the detector says so. The loop
    /// calls it every `checkInterval`; tests call it directly.
    func check() async {
        guard let probes, !isRestarting, localNetworkAccess != .denied else { return }
        let moment = now()
        if let at = noRouteAt, moment.timeIntervalSince(at) > noRouteValidity { noRouteAt = nil }
        let noRoute = noRouteAt != nil
        guard AdbBlockedDetector.hasCandidate(inApp: observed, now: moment, noRoute: noRoute) else {
            state.consecutiveBlockedChecks = 0
            return
        }
        let running = await probes.mdnsRunning()
        let services = running ? await probes.services() : []
        let input = AdbBlockedInput(
            inApp: observed,
            adbServices: services,
            adbMdnsRunning: running,
            noRouteToReachableHost: noRoute,
            busy: isBusy(),
            now: now()
        )
        let result = AdbBlockedDetector.evaluate(state: state, input: input)
        state = result.state
        guard result.decision == .restart else { return }
        await restart(probes)
    }

    private func restart(_ probes: Probes) async {
        isRestarting = true
        defer { isRestarting = false }
        do {
            try await probes.restart()
        } catch {
            // The next confirmed check tries again after the rate limit; the
            // user is not alerted over a background repair.
            return
        }
        restartCount += 1
        noRouteAt = nil
        status.flash(LocalNetworkPolicy.restartedBanner, seconds: 6)
        await refresh()
    }
}

/// Whether this process can open a TCP connection to an address: what the
/// "No route to host" signal is compared against.
enum LocalReachability {
    static func canReach(host: String, port: Int, timeout: Duration = .seconds(3)) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let gate = Gate()
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            if gate.take() { continuation.resume(returning: true) }
                        case .failed, .cancelled:
                            if gate.take() { continuation.resume(returning: false) }
                        case .waiting:
                            // No route (or a policy block) right now: not reachable.
                            if gate.take() { continuation.resume(returning: false) }
                        default:
                            break
                        }
                    }
                    connection.start(queue: DispatchQueue(label: "io.github.gitemre.devicehubpro.reachability"))
                }
            }
            group.addTask {
                // Best effort: cancellation just ends the wait early.
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            connection.cancel()
            return first
        }
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        func take() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if taken { return false }
            taken = true
            return true
        }
    }
}
