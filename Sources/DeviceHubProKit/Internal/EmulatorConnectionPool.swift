import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

/// One running gRPC client to an emulator port: the client plus the task that
/// runs its connections. Created by `EmulatorConnectionPool` for the shared
/// control channel and by `MirrorSession` for its dedicated frame stream.
final class EmulatorConnection: Sendable {
    let port: Int
    let token: String?
    /// Distinguishes a replacement connection to the same port.
    let id: UInt64

    private let client: GRPCClient<HTTP2ClientTransport.Posix>
    private let runner: Task<Void, Never>

    init(port: Int, token: String?, id: UInt64 = 0) throws {
        let interceptors: [any ClientInterceptor] = token.map {
            [BearerTokenInterceptor(token: $0)]
        } ?? []
        let client = try GRPCClient(
            transport: .http2NIOPosix(
                target: .dns(host: "127.0.0.1", port: port),
                transportSecurity: .plaintext
            ),
            interceptors: interceptors
        )
        self.port = port
        self.token = token
        self.id = id
        self.client = client
        // RPCs made before `runConnections` starts are queued by the client,
        // so the connection is usable as soon as it is returned.
        self.runner = Task.detached {
            try? await client.runConnections()
        }
    }

    var controller: EmulatorClient { EmulatorClient(wrapping: client) }

    /// Stops new RPCs, lets the in-flight ones finish and closes the socket.
    func shutdown() {
        client.beginGracefulShutdown()
    }

    /// Waits until the client has stopped (after `shutdown`).
    func waitUntilClosed() async {
        await runner.value
    }
}

/// One long-lived gRPC connection per emulator port for the short control
/// RPCs (the Controls/sensor/clipboard polls, toggles, hinge drags, touch and
/// keyboard input). Before this, every call paid its own TCP connect and
/// HTTP/2 handshake — six per Controls poll and twenty a second while the
/// hinge slider moved.
///
/// Lifetime: a connection is opened on first use, reused while calls keep
/// coming, closed after `idleTimeout` without a call, replaced when the port's
/// JWT token changes or a call reports the transport unavailable (the
/// emulator restarted), and closed on demand with `close(port:)`. The
/// multi-megabyte frame stream and the audio stream stay on their own
/// connections so they never queue behind (or in front of) control calls.
actor EmulatorConnectionPool {
    static let shared = EmulatorConnectionPool()

    /// The polls keep a connection warm (1.2–2 s beats); an emulator nobody
    /// talks to any more releases its socket after this long.
    static let defaultIdleTimeout: Duration = .seconds(15)

    private struct Entry {
        let connection: EmulatorConnection
        var leases: Int
        var lastUse: ContinuousClock.Instant
    }

    private let idleTimeout: Duration
    private var entries: [Int: Entry] = [:]
    private var nextID: UInt64 = 1
    private var sweeper: Task<Void, Never>?

    init(idleTimeout: Duration = EmulatorConnectionPool.defaultIdleTimeout) {
        self.idleTimeout = idleTimeout
    }

    /// The port's connection, opened when there is none (or the token
    /// changed). `reused` is true when the connection served earlier calls,
    /// i.e. when a transport failure may just mean it went stale.
    func lease(port: Int, token: String?) throws -> (connection: EmulatorConnection, reused: Bool) {
        if var entry = entries[port], entry.connection.token == token {
            entry.leases += 1
            entry.lastUse = .now
            entries[port] = entry
            return (entry.connection, true)
        }
        if let stale = entries.removeValue(forKey: port) {
            stale.connection.shutdown()
        }
        let connection = try EmulatorConnection(port: port, token: token, id: nextID)
        nextID += 1
        entries[port] = Entry(connection: connection, leases: 1, lastUse: .now)
        scheduleSweep()
        return (connection, false)
    }

    /// Ends one call on `connection`. `discard` drops it (when it is still the
    /// port's current connection) so the next call reconnects.
    func release(_ connection: EmulatorConnection, discard: Bool) {
        guard var entry = entries[connection.port], entry.connection.id == connection.id else {
            return
        }
        entry.leases = max(0, entry.leases - 1)
        entry.lastUse = .now
        if discard {
            entries.removeValue(forKey: connection.port)
            connection.shutdown()
        } else {
            entries[connection.port] = entry
        }
    }

    /// Closes the port's connection (the emulator went away); the next call
    /// opens a fresh one.
    func close(port: Int) {
        entries.removeValue(forKey: port)?.connection.shutdown()
    }

    func closeAll() {
        let all = entries.values
        entries.removeAll()
        for entry in all {
            entry.connection.shutdown()
        }
    }

    /// Test seam: the id of the port's current connection, if any.
    func connectionID(port: Int) -> UInt64? {
        entries[port]?.connection.id
    }

    // MARK: - Idle sweep

    private func scheduleSweep() {
        guard sweeper == nil else { return }
        let interval = idleTimeout / 2
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, await self.sweep() else { return }
            }
        }
    }

    /// Closes every idle connection; returns false once nothing is left to
    /// watch so the sweeper stops.
    private func sweep() -> Bool {
        let now = ContinuousClock.now
        for (port, entry) in entries where entry.leases == 0 && now - entry.lastUse >= idleTimeout {
            entries.removeValue(forKey: port)
            entry.connection.shutdown()
        }
        if entries.isEmpty {
            sweeper = nil
            return false
        }
        return true
    }
}
