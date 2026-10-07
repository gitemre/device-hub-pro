import Foundation

/// A Bonjour service the app's own browse sees (the app holds the macOS Local
/// Network permission; the adb server may not).
public struct ObservedBonjourService: Equatable, Hashable, Sendable {
    /// The instance name, e.g. `adb-R58M12345AB-yXk7tu`.
    public let name: String
    /// The service type without a trailing dot, e.g. `_adb-tls-connect._tcp`.
    public let type: String
    /// When the app's browse first saw this service (continuously since).
    public let firstSeen: Date

    public init(name: String, type: String, firstSeen: Date) {
        self.name = name
        self.type = ObservedBonjourService.normalized(type: type)
        self.firstSeen = firstSeen
    }

    /// `_adb-tls-connect._tcp.` / `_adb-tls-connect._tcp.local.` -> `_adb-tls-connect._tcp`.
    public static func normalized(type: String) -> String {
        var parts = type.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
        if parts.count > 2 { parts = Array(parts.prefix(2)) }
        return parts.joined(separator: ".")
    }
}

/// What the app's own Local Network access looks like from its browse.
public enum LocalNetworkAccess: Equatable, Sendable {
    case unknown
    case allowed
    /// The browse failed with `kDNSServiceErr_PolicyDenied` (-65570).
    case denied
}

/// The macOS Local Network facts shared by the hint and the detection.
public enum LocalNetworkPolicy {
    /// `kDNSServiceErr_PolicyDenied`.
    public static let policyDeniedCode: Int32 = -65570

    /// The hint shown beside wireless debugging when the permission is denied.
    public static let deniedHint =
        "Allow Device Hub Pro under System Settings \u{203A} Privacy & Security \u{203A} Local Network."

    /// The Local Network pane. Opening it is the only thing the app does about
    /// the setting: it never changes it.
    public static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
    )!

    /// The banner shown after the app restarted adb.
    public static let restartedBanner = "Device Hub Pro restarted adb so it can reach Wi-Fi devices."

    public static func access(forDNSServiceError code: Int32) -> LocalNetworkAccess {
        code == policyDeniedCode ? .denied : .unknown
    }
}

/// Everything one detection step reads. A pure value: the monitor gathers it,
/// `AdbBlockedDetector.evaluate` decides.
public struct AdbBlockedInput: Equatable, Sendable {
    /// Services the app's own browse currently sees.
    public var inApp: [ObservedBonjourService]
    /// Services `adb mdns services` lists.
    public var adbServices: [WirelessPairing.MdnsService]
    /// `adb mdns check` reports the daemon running.
    public var adbMdnsRunning: Bool
    /// A failed `adb connect` said "No route to host" for an address the app's
    /// own `NWConnection` reached (the second signal).
    public var noRouteToReachableHost: Bool
    /// A recording or an install runs on some device.
    public var busy: Bool
    public var now: Date

    public init(
        inApp: [ObservedBonjourService],
        adbServices: [WirelessPairing.MdnsService],
        adbMdnsRunning: Bool,
        noRouteToReachableHost: Bool = false,
        busy: Bool,
        now: Date
    ) {
        self.inApp = inApp
        self.adbServices = adbServices
        self.adbMdnsRunning = adbMdnsRunning
        self.noRouteToReachableHost = noRouteToReachableHost
        self.busy = busy
        self.now = now
    }
}

public enum AdbBlockedDecision: Equatable, Sendable {
    /// Nothing blocked, or not confirmed by enough checks yet.
    case none
    /// Blocked and confirmed: restart adb now.
    case restart
    /// Blocked and confirmed, but a recording or an install runs.
    case deferredWhileBusy
    /// Blocked and confirmed, but adb was restarted less than the interval ago.
    case rateLimited
}

/// What the detector carries between checks.
public struct AdbBlockedState: Equatable, Sendable {
    public var consecutiveBlockedChecks = 0
    public var lastRestart: Date?
    public init(consecutiveBlockedChecks: Int = 0, lastRestart: Date? = nil) {
        self.consecutiveBlockedChecks = consecutiveBlockedChecks
        self.lastRestart = lastRestart
    }
}

/// Decides whether the adb server was started without Local Network
/// permission (so its mDNS browse and its LAN connects are blocked) while the
/// app, which holds the permission, sees the devices.
public enum AdbBlockedDetector {
    /// A service must be visible this long before its absence from adb counts.
    public static let minimumAge: TimeInterval = 6
    /// Checks in a row that must agree before a restart.
    public static let confirmationsRequired = 2
    /// The shortest time between two automatic restarts.
    public static let minimumRestartInterval: TimeInterval = 120

    /// The app-seen services older than `minimumAge` that adb does not list.
    public static func missingFromAdb(_ input: AdbBlockedInput) -> [ObservedBonjourService] {
        input.inApp.filter { seen in
            input.now.timeIntervalSince(seen.firstSeen) > minimumAge
                && !input.adbServices.contains {
                    $0.instance == seen.name && ObservedBonjourService.normalized(type: $0.type) == seen.type
                }
        }
    }

    /// Whether anything is worth asking adb about: lets the monitor skip the
    /// two adb calls while the app sees nothing old enough.
    public static func hasCandidate(inApp: [ObservedBonjourService], now: Date, noRoute: Bool) -> Bool {
        noRoute || inApp.contains { now.timeIntervalSince($0.firstSeen) > minimumAge }
    }

    public static func evaluate(
        state: AdbBlockedState,
        input: AdbBlockedInput
    ) -> (state: AdbBlockedState, decision: AdbBlockedDecision) {
        var next = state
        let blocked = input.adbMdnsRunning
            && (!missingFromAdb(input).isEmpty || input.noRouteToReachableHost)
        guard blocked else {
            next.consecutiveBlockedChecks = 0
            return (next, .none)
        }
        next.consecutiveBlockedChecks += 1
        guard next.consecutiveBlockedChecks >= confirmationsRequired else { return (next, .none) }
        if input.busy { return (next, .deferredWhileBusy) }
        if let last = state.lastRestart, input.now.timeIntervalSince(last) < minimumRestartInterval {
            return (next, .rateLimited)
        }
        next.lastRestart = input.now
        next.consecutiveBlockedChecks = 0
        return (next, .restart)
    }

    /// Whether a failed `adb connect`'s message is the Local Network symptom.
    public static func isNoRouteToHost(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("No route to host")
    }

    /// Whether `adb mdns check` reports a running daemon (its output carries
    /// "mdns daemon version"; an unavailable one says "unavailable").
    public static func mdnsCheckReportsRunning(_ output: String) -> Bool {
        output.localizedCaseInsensitiveContains("mdns daemon version")
            && !output.localizedCaseInsensitiveContains("unavailable")
    }
}

/// Remembers when the app's browse first saw each service, so `firstSeen`
/// survives result updates and restarts from zero when a service goes away.
public struct ObservedServiceTracker: Sendable {
    private var firstSeen: [String: Date] = [:]
    public init() {}

    /// The current results, each with its first-seen time.
    public mutating func update(
        names: [BonjourServiceName],
        now: Date
    ) -> [ObservedBonjourService] {
        var kept: [String: Date] = [:]
        var result: [ObservedBonjourService] = []
        for entry in names {
            let type = ObservedBonjourService.normalized(type: entry.type)
            let key = entry.name + "|" + type
            let date = firstSeen[key] ?? now
            kept[key] = date
            result.append(ObservedBonjourService(name: entry.name, type: type, firstSeen: date))
        }
        firstSeen = kept
        return result
    }
}

extension AdbClient {
    /// `adb mdns check` says the daemon runs. A failed call counts as not
    /// running, so a dead server never triggers a restart.
    public func mdnsDaemonRunning() async -> Bool {
        guard let output = try? await run(["mdns", "check"], timeout: .seconds(5)) else { return false }
        return AdbBlockedDetector.mdnsCheckReportsRunning(output)
    }

    /// Restarts the adb server from this process (`kill-server`, then
    /// `start-server`), so the new server inherits this app's macOS Local
    /// Network permission.
    public func restartServer() async throws {
        _ = try? await run(["kill-server"], timeout: .seconds(10))
        try await run(["start-server"], timeout: .seconds(20))
    }
}
