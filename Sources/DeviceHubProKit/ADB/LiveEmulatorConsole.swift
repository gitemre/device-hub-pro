import Darwin
import Foundation
import os

/// The real console transport: one loopback TCP connection per command, to
/// 127.0.0.1 and, when nothing answers there, ::1 (adb's own loopback
/// client tries both).
///
/// The conversation, which `EmulatorConsole` explains: read the greeting up
/// to its `OK`; when it asks for authentication, send `auth <token>` with the
/// token from `tokenFile` and wait for that `OK` (a `KO` is
/// `EmulatorConsoleError.authenticationRejected`); send the command; read to
/// the answer's `OK` or `KO` line; send `quit`. The blocking socket work runs
/// on a queue of its own (never the main actor, never a Swift concurrency
/// thread), bounded by the call's timeout and ended within about 100 ms of
/// the task's cancellation.
///
/// The token file is read only when the console asks for authentication, and
/// the token goes nowhere but the console's socket: it is in no error and no
/// log.
public struct LiveEmulatorConsole: EmulatorConsoleTransport {
    /// Where the authentication token is read from.
    public let tokenFile: URL

    public init(tokenFile: URL = EmulatorConsole.defaultTokenFile()) {
        self.tokenFile = tokenFile
    }

    private static let queue = DispatchQueue(
        label: "com.devicehubpro.emulator-console",
        qos: .userInitiated,
        attributes: .concurrent
    )

    public func run(_ arguments: [String], port: Int, timeout: Duration) async throws -> String {
        let cancellation = EmulatorConsoleCancellation()
        let tokenFile = tokenFile
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Self.queue.async {
                    continuation.resume(with: Result {
                        try EmulatorConsoleExchange.run(
                            arguments,
                            port: port,
                            tokenFile: tokenFile,
                            timeout: timeout,
                            cancellation: cancellation
                        )
                    })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

/// The switch a cancelled task flips for the exchange running on its behalf.
final class EmulatorConsoleCancellation: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    func cancel() {
        state.withLock { $0 = true }
    }

    var isCancelled: Bool {
        state.withLock { $0 }
    }
}

/// One console conversation, start to finish, on the calling thread.
enum EmulatorConsoleExchange {
    static func run(
        _ arguments: [String],
        port: Int,
        tokenFile: URL,
        timeout: Duration,
        cancellation: EmulatorConsoleCancellation
    ) throws -> String {
        guard !arguments.isEmpty, !arguments.contains(where: { $0.contains(where: \.isNewline) }) else {
            throw EmulatorConsoleError.invalidCommand
        }
        let connection = try EmulatorConsoleConnection.open(
            port: port,
            timeout: timeout,
            cancellation: cancellation
        )

        let greeting = try connection.readAnswer()
        guard let greetingEnd = greeting.terminator else {
            throw EmulatorConsoleError.protocolError("the console closed the connection before its greeting ended")
        }
        guard greetingEnd == "OK" else {
            throw EmulatorConsoleError.protocolError("the console refused the connection: \(greetingEnd)")
        }

        // Authentication only when the console asks for it, and only when
        // there is a token: without one the command still goes out, since
        // `avd name` and `avd grpc` are answered before authentication.
        if EmulatorConsole.greetingAsksForAuthentication(greeting.text),
           let token = EmulatorConsole.token(in: tokenFile) {
            try connection.write("auth \(token)\n")
            let reply = try connection.readAnswer()
            guard let replyEnd = reply.terminator else {
                throw EmulatorConsoleError.protocolError("the console closed the connection while authenticating")
            }
            guard replyEnd == "OK" else {
                throw EmulatorConsoleError.authenticationRejected(replyEnd)
            }
        }

        try connection.write(arguments.joined(separator: " ") + "\n")
        let answer = try connection.readAnswer()
        // Best effort: the answer is complete, and the console may be gone
        // already (`kill` ends the VM).
        try? connection.write("quit\n")
        return answer.text
    }
}

/// A connected loopback socket with line reads and writes bounded by one
/// deadline. Used by one thread; closes its descriptor when released.
final class EmulatorConsoleConnection {
    /// What one answer may hold before the console counts as misbehaving.
    private static let answerLimit = 4 * 1024 * 1024

    /// The loopback addresses, in the order they are tried.
    private enum LoopbackAddress: CaseIterable {
        case ipv4
        case ipv6

        var family: Int32 {
            switch self {
            case .ipv4: return AF_INET
            case .ipv6: return AF_INET6
            }
        }

        /// `connect(2)` to the loopback address on `port`.
        func connect(_ descriptor: Int32, port: UInt16) -> Int32 {
            switch self {
            case .ipv4:
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = port.bigEndian
                inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
                return withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            case .ipv6:
                var address = sockaddr_in6()
                address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                address.sin6_family = sa_family_t(AF_INET6)
                address.sin6_port = port.bigEndian
                inet_pton(AF_INET6, "::1", &address.sin6_addr)
                return withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
            }
        }
    }

    private struct ConnectFailure: Error {
        let reason: String
    }

    /// What `readAnswer` collected.
    struct Answer {
        /// Every byte read, through the terminating line.
        let bytes: [UInt8]
        /// The terminating `OK` or `KO` line without its line ending; nil
        /// when the console closed the connection before one.
        let terminator: String?

        var text: String { String(decoding: bytes, as: UTF8.self) }
    }

    private let descriptor: Int32
    private let timeout: Duration
    private let deadline: ContinuousClock.Instant
    private let cancellation: EmulatorConsoleCancellation
    private var pending: [UInt8] = []
    private var reachedEnd = false

    private init(descriptor: Int32, timeout: Duration, cancellation: EmulatorConsoleCancellation) {
        self.descriptor = descriptor
        self.timeout = timeout
        self.deadline = ContinuousClock.now.advanced(by: timeout)
        self.cancellation = cancellation
    }

    deinit {
        Darwin.close(descriptor)
    }

    /// Connects to the console on `port`: 127.0.0.1, then ::1.
    static func open(
        port: Int,
        timeout: Duration,
        cancellation: EmulatorConsoleCancellation
    ) throws -> EmulatorConsoleConnection {
        guard let port = UInt16(exactly: port) else {
            throw EmulatorConsoleError.couldNotConnect(port: port, reason: "not a port")
        }
        var reason = "no loopback address answered"
        for address in LoopbackAddress.allCases {
            let descriptor = socket(address.family, SOCK_STREAM, 0)
            guard descriptor >= 0 else {
                reason = String(cString: strerror(errno))
                continue
            }
            // A write to a console that went away must fail with EPIPE, not
            // raise SIGPIPE and end the app.
            var on: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)

            let connection = EmulatorConsoleConnection(
                descriptor: descriptor,
                timeout: timeout,
                cancellation: cancellation
            )
            do {
                try connection.connect(to: address, port: port)
                return connection
            } catch let failure as ConnectFailure {
                reason = failure.reason
            }
        }
        throw EmulatorConsoleError.couldNotConnect(port: Int(port), reason: reason)
    }

    private func connect(to address: LoopbackAddress, port: UInt16) throws {
        if address.connect(descriptor, port: port) == 0 { return }
        let started = errno
        guard started == EINPROGRESS else { throw ConnectFailure(reason: String(cString: strerror(started))) }
        try waitReady(Int16(POLLOUT))
        var failure: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &length)
        guard failure == 0 else { throw ConnectFailure(reason: String(cString: strerror(failure))) }
    }

    /// Reads lines through the first `OK` or `KO` line, or to the end of the
    /// connection.
    func readAnswer() throws -> Answer {
        var bytes: [UInt8] = []
        while let line = try readLine() {
            bytes += line
            let text = String(decoding: line, as: UTF8.self)
            if EmulatorConsole.isTerminator(text) {
                return Answer(bytes: bytes, terminator: text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            guard bytes.count <= Self.answerLimit else {
                throw EmulatorConsoleError.protocolError("an answer longer than \(Self.answerLimit) bytes")
            }
        }
        return Answer(bytes: bytes, terminator: nil)
    }

    /// Writes all of `text`.
    func write(_ text: String) throws {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            try waitReady(Int16(POLLOUT))
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if written > 0 {
                offset += written
            } else if written < 0, errno != EAGAIN, errno != EINTR {
                throw EmulatorConsoleError.protocolError("could not write to the console: \(String(cString: strerror(errno)))")
            }
        }
    }

    /// The next line with its line ending; at the end of the connection the
    /// bytes left over, then nil.
    private func readLine() throws -> [UInt8]? {
        while true {
            if let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Array(pending[...newline])
                pending.removeSubrange(...newline)
                return line
            }
            if reachedEnd {
                guard !pending.isEmpty else { return nil }
                defer { pending.removeAll() }
                return pending
            }
            guard pending.count <= Self.answerLimit else {
                throw EmulatorConsoleError.protocolError("a line longer than \(Self.answerLimit) bytes")
            }
            try fill()
        }
    }

    /// Waits for bytes and reads what is there. An error ends the connection
    /// as the end does: `adb emu` treats a reset (the console's `kill`) as
    /// the end of the answer.
    private func fill() throws {
        try waitReady(Int16(POLLIN))
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        if count > 0 {
            pending.append(contentsOf: chunk[..<count])
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            reachedEnd = true
        }
    }

    /// Waits until the descriptor is ready for `events` (or hung up), in
    /// slices short enough to notice a cancellation.
    @discardableResult
    private func waitReady(_ events: Int16) throws -> Int16 {
        while true {
            if cancellation.isCancelled { throw CancellationError() }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw EmulatorConsoleError.timedOut(timeout) }
            let milliseconds = Int32(min(100, max(1, remaining / .milliseconds(1))))
            var state = pollfd(fd: descriptor, events: events, revents: 0)
            let ready = poll(&state, 1, milliseconds)
            if ready > 0 { return state.revents }
            if ready < 0, errno != EINTR {
                throw EmulatorConsoleError.protocolError("poll failed: \(String(cString: strerror(errno)))")
            }
        }
    }
}
