import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf

typealias EmulatorClient = Android_Emulation_Control_EmulatorController.Client<HTTP2ClientTransport.Posix>
typealias EmuImageFormat = Android_Emulation_Control_ImageFormat

/// Adds the emulator's bearer token to every call. Emulators launched by
/// Android Studio's Device Manager enable JWT auth; the token is published in
/// the emulator discovery file under `grpc.token`.
struct BearerTokenInterceptor: ClientInterceptor {
    let token: String

    func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingClientRequest<Input>,
        context: ClientContext,
        next: (
            StreamingClientRequest<Input>,
            ClientContext
        ) async throws -> StreamingClientResponse<Output>
    ) async throws -> StreamingClientResponse<Output> {
        var request = request
        request.metadata.addString("Bearer \(token)", forKey: "authorization")
        return try await next(request, context)
    }
}

/// Thin wrapper around the emulator's gRPC control channel.
enum EmulatorControl {
    // A token change needs no bookkeeping here: the pool compares the token
    // on every lease and replaces a connection opened with a stale one.
    private static let tokenLock = NSLock()
    nonisolated(unsafe) private static var tokensByPort: [Int: String] = [:]

    /// Remembers the JWT token required by the emulator listening on `port`.
    /// Pass `nil` to clear a stale token.
    static func registerToken(_ token: String?, forPort port: Int) {
        tokenLock.lock()
        tokensByPort[port] = token
        tokenLock.unlock()
    }

    static func token(forPort port: Int) -> String? {
        tokenLock.lock()
        defer { tokenLock.unlock() }
        return tokensByPort[port]
    }

    /// Runs `body` on a connection of its own, closed when `body` returns.
    /// For one-off probes of ports that may not be emulators at all
    /// (`EmulatorProbe`); control calls use `withSharedClient`.
    static func withClient<T: Sendable>(
        port: Int,
        _ body: (EmulatorClient) async throws -> T
    ) async throws -> T {
        let interceptors: [any ClientInterceptor] = token(forPort: port).map {
            [BearerTokenInterceptor(token: $0)]
        } ?? []
        return try await withGRPCClient(
            transport: .http2NIOPosix(
                target: .dns(host: "127.0.0.1", port: port),
                transportSecurity: .plaintext
            ),
            interceptors: interceptors
        ) { client in
            try await body(EmulatorClient(wrapping: client))
        }
    }

    /// Runs `body` on the port's shared control connection
    /// (`EmulatorConnectionPool`). A reused connection that reports the
    /// transport unavailable has gone stale (the emulator restarted on the
    /// same port): it is dropped, so the next call reconnects.
    ///
    /// With `retryOnStaleConnection`, `body` also runs once more on a fresh
    /// connection right away. Pass it only for a read or an absolute write
    /// (set the battery, the location, the clipboard): `unavailable` can
    /// arrive after the emulator already acted on part of `body` (the
    /// connection dropped before the reply), and a rerun would deliver an SMS
    /// or a call again, rotate twice, or type text twice.
    static func withSharedClient<T: Sendable>(
        port: Int,
        pool: EmulatorConnectionPool = .shared,
        retryOnStaleConnection: Bool = false,
        _ body: (EmulatorClient) async throws -> T
    ) async throws -> T {
        let token = token(forPort: port)
        let (connection, reused) = try await pool.lease(port: port, token: token)
        do {
            let result = try await body(connection.controller)
            await pool.release(connection, discard: false)
            return result
        } catch {
            let isStale = isConnectionFailure(error)
            await pool.release(connection, discard: isStale)
            guard retryOnStaleConnection, isStale, reused, !Task.isCancelled else { throw error }
        }

        let (fresh, _) = try await pool.lease(port: port, token: token)
        do {
            let result = try await body(fresh.controller)
            await pool.release(fresh, discard: false)
            return result
        } catch {
            await pool.release(fresh, discard: isConnectionFailure(error))
            throw error
        }
    }

    /// Closes the port's shared control connection; the next call reconnects.
    static func closeSharedConnection(port: Int) async {
        await EmulatorConnectionPool.shared.close(port: port)
    }

    /// True for the failure a dead or refused connection produces. A timeout
    /// is not one: the call was slow, the connection may be fine.
    static func isConnectionFailure(_ error: Error) -> Bool {
        (error as? RPCError)?.code == .unavailable
    }
}

extension CallOptions {
    /// Emulator frames can be large (a 2076x2152 RGBA frame is ~18 MB), well above the
    /// 4 MB gRPC default.
    ///
    /// Note: grpc-swift-nio-transport applies `maxRequestMessageBytes` to the client's
    /// inbound decoder as well, so both limits must be raised for large responses.
    static var emulatorFrames: CallOptions {
        var options = CallOptions.defaults
        options.maxRequestMessageBytes = 64 * 1024 * 1024
        options.maxResponseMessageBytes = 64 * 1024 * 1024
        return options
    }
}

/// Whether a mirror session may negotiate the shared-memory (MMAP) frame
/// transport, the default since it measured 60 fps / 0 % drops / 13.5 % CPU
/// against raw frames' 32 fps / 18 % / 41 % (docs/performance.md).
/// `EmulatorVersion.supportsMMAP` still gates it on the emulator build, and
/// any MMAP failure falls back to raw frames.
enum MMAPPolicy {
    static let disableVariable = "DHP_DISABLE_MMAP"
    static let forceVariable = "DHP_FORCE_MMAP"

    /// `DHP_DISABLE_MMAP=1` always wins (the escape hatch);
    /// `DHP_FORCE_MMAP=1` allows MMAP even when the caller asked for raw
    /// frames. Neither bypasses the emulator version gate — older engines
    /// crash on MMAP.
    static func isAllowed(
        requested: Bool,
        forceRaw: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if forceRaw || environment[disableVariable] == "1" { return false }
        return requested || environment[forceVariable] == "1"
    }
}

public enum EmulatorVersion {
    /// MMAP is fixed in emulator 37.2.3 (issue #537802959); older versions crash.
    public static func supportsMMAP(_ version: String) -> Bool {
        guard let parts = components(version) else { return false }
        return compare(parts, mmapMinimum) != .orderedAscending
    }

    private static let mmapMinimum = [37, 2, 3]

    /// `major.minor.patch` of a version string such as `37.2.12` (a trailing
    /// ` (build ...)` is ignored; a missing patch is 0); nil below two numbers.
    static func components(_ version: String) -> [Int]? {
        let numeric = version.split(separator: " ").first.map(String.init) ?? version
        let parts = numeric.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return [parts[0], parts[1], parts.count > 2 ? parts[2] : 0]
    }

    private static func compare(_ a: [Int], _ b: [Int]) -> ComparisonResult {
        for (x, y) in zip(a, b) where x != y { return x < y ? .orderedAscending : .orderedDescending }
        return .orderedSame
    }

    /// Whether `version` is older than `other`; false when either cannot be read.
    public static func isOlder(_ version: String, than other: String) -> Bool {
        guard let a = components(version), let b = components(other) else { return false }
        return compare(a, b) == .orderedAscending
    }

    /// The version of the SDK emulator package beside `emulatorBinary`
    /// (`<sdk>/emulator/emulator`), read from its `package.xml` revision;
    /// nil for a binary that is not an SDK package (a canary build elsewhere).
    public static func installedVersion(emulatorBinary: URL) -> String? {
        let manifest = emulatorBinary.deletingLastPathComponent().appendingPathComponent("package.xml")
        guard let text = try? String(contentsOf: manifest, encoding: .utf8),
              let range = text.range(of: "<revision>.*?</revision>", options: .regularExpression)
        else { return nil }
        let revision = String(text[range])
        func number(_ tag: String) -> Int? {
            guard let r = revision.range(of: "<\(tag)>[0-9]+</\(tag)>", options: .regularExpression) else { return nil }
            return Int(revision[r].dropFirst(tag.count + 2).dropLast(tag.count + 3))
        }
        guard let major = number("major"), let minor = number("minor") else { return nil }
        return "\(major).\(minor).\(number("micro") ?? 0)"
    }
}
