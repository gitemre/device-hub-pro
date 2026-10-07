import Foundation

public enum GrpcPortResolution: Sendable, Equatable {
    case discovery(Int)
    case processMatch(Int)
    case scan(Int)
    case unresolved(String)

    public var port: Int? {
        switch self {
        case .discovery(let port), .processMatch(let port), .scan(let port):
            return port
        case .unresolved:
            return nil
        }
    }
}

/// Identity-based gRPC port selection. The ladder never guesses across
/// identities: when the VM cannot be identified, the resolution is
/// `unresolved` and the app fails closed instead of binding a random emulator.
public enum GrpcPortResolver {
    public static let unresolvedMessage =
        "Could not identify the emulator's control channel (multiple emulators running?). Not connecting."

    /// Ladder: discovery file (JWT, Android-Studio VMs) → AVD-name match
    /// against `ps` → single-VM answer (its parsed port, else one scanned
    /// live port) → fail closed.
    ///
    /// The single-VM answer is only taken when it cannot contradict the
    /// target's identity: with a known `avdName` the lone VM must *be* that
    /// AVD. A known name that matches no parsed VM means the target is simply
    /// not in the list (a command line `ps` parsing does not recognize) — the
    /// one VM that is listed is someone else, and binding it would mirror and
    /// drive the wrong emulator.
    public static func resolve(
        discovery: EmulatorGRPCInfo?,
        avdName: String?,
        running: [RunningEmulator],
        liveScanPorts: [Int]
    ) -> GrpcPortResolution {
        if let discovery {
            return .discovery(discovery.port)
        }
        guard let candidate = identifiedCandidate(avdName: avdName, running: running) else {
            return .unresolved(unresolvedMessage)
        }
        if let port = candidate.grpcPort {
            return .processMatch(port)
        }
        // The scan cannot tell whose port it found, so it only speaks for a
        // VM that is the only one running.
        if running.count == 1, liveScanPorts.count == 1 {
            return .scan(liveScanPorts[0])
        }
        return .unresolved(unresolvedMessage)
    }

    /// True when `resolve` can only answer via `liveScanPorts`, so the caller
    /// should probe the emulator's scan ports (`EmulatorManager.grpcScanPorts`,
    /// 8554…8563 in the app) first — and only then.
    public static func needsScan(
        discovery: EmulatorGRPCInfo?,
        avdName: String?,
        running: [RunningEmulator]
    ) -> Bool {
        if discovery != nil { return false }
        guard let candidate = identifiedCandidate(avdName: avdName, running: running) else {
            return false
        }
        return candidate.grpcPort == nil && running.count == 1
    }

    /// The running VM that is the target: the one named `avdName` when the
    /// name is known (nil when none is), else the only VM running.
    private static func identifiedCandidate(
        avdName: String?,
        running: [RunningEmulator]
    ) -> RunningEmulator? {
        if let avdName {
            return running.first { $0.avd == avdName }
        }
        return running.count == 1 ? running[0] : nil
    }
}

/// Serial → port map behind `AppModel.resolveGrpcPort`. Invalidation is
/// explicit (disconnect, teardown, watcher restart) because a restarted
/// emulator can come back on a different port.
public struct GrpcPortCache: Sendable, Equatable {
    private var ports: [String: Int] = [:]

    public init() {}

    public func port(for serial: String) -> Int? {
        ports[serial]
    }

    public mutating func store(_ port: Int, for serial: String) {
        ports[serial] = port
    }

    public mutating func invalidate(serial: String) {
        ports[serial] = nil
    }

    /// Drops every serial that is not in `present`.
    public mutating func invalidate(missingFrom present: Set<String>) {
        ports = ports.filter { present.contains($0.key) }
    }

    public mutating func invalidateAll() {
        ports.removeAll()
    }
}
