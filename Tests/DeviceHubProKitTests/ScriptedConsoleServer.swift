import Darwin
import Foundation
import XCTest

/// The captures under `Fixtures/emulator-console/`: the emulator console's
/// bytes and `adb emu`'s output, taken on 2026-10-12 (see its README for the
/// emulator, the system image, the setup and the scrubbing).
enum EmulatorConsoleFixture {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/emulator-console", isDirectory: true)

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func text(_ name: String) throws -> String {
        try XCTUnwrap(String(data: data(name), encoding: .utf8), "\(name) is not UTF-8")
    }
}

/// A stand-in for an emulator's console on a loopback port the test owns:
/// it greets with the captured bytes, reads the client's lines (each recorded
/// without its line ending) and answers each with what the closure says,
/// until the client sends `quit` (which ends the connection without an
/// answer, as the console does) or closes. Every connection starts afresh, as
/// the real console's do. No other process can listen on 127.0.0.1 at its
/// `port` while it lives, so the port reaches nothing but this server.
final class ScriptedConsoleServer: @unchecked Sendable {
    enum Reply {
        case bytes(Data)
        /// Send these bytes, then close the connection.
        case closing(Data)
        /// Say nothing.
        case silence
    }

    /// What one connection remembers: whether the client has authenticated.
    final class Session: @unchecked Sendable {
        var isAuthenticated = false
    }

    let port: Int
    private let greeting: Data
    private let closesAfterGreeting: Bool
    private let respond: @Sendable (String, Session) -> Reply
    private let lock = NSLock()
    private var stopped = false
    private var received: [String] = []
    private var accepted = 0

    init(
        greeting: Data,
        closesAfterGreeting: Bool = false,
        respond: @escaping @Sendable (String, Session) -> Reply
    ) throws {
        self.greeting = greeting
        self.closesAfterGreeting = closesAfterGreeting
        self.respond = respond

        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 16) == 0 else {
            let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(descriptor)
            throw failure
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        port = Int(UInt16(bigEndian: address.sin_port))

        // The loop owns the listening socket and closes it once stopped.
        let thread = Thread { [self] in
            var ready = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            while !isStopped {
                guard poll(&ready, 1, 50) > 0 else { continue }
                let connection = accept(descriptor, nil, nil)
                guard connection >= 0 else { continue }
                lock.withLock { accepted += 1 }
                Thread { [self] in serve(connection) }.start()
            }
            Darwin.close(descriptor)
        }
        thread.start()
    }

    /// The lines clients sent so far, in order, across connections.
    var lines: [String] { lock.withLock { received } }

    /// The connections accepted so far.
    var connectionCount: Int { lock.withLock { accepted } }

    /// Waits until `count` lines arrived (the client's `quit` follows its
    /// call's return, so a test reads the lines only after this) and returns
    /// them.
    func waitForLines(_ count: Int, timeout: TimeInterval = 5) async -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        while lines.count < count, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return lines
    }

    func stop() {
        lock.withLock { stopped = true }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func serve(_ connection: Int32) {
        defer { Darwin.close(connection) }
        var on: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        send(greeting, on: connection)
        if closesAfterGreeting { return }

        let session = Session()
        var buffer = Data()
        var ready = pollfd(fd: connection, events: Int16(POLLIN), revents: 0)
        while !isStopped {
            guard poll(&ready, 1, 50) > 0 else { continue }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = read(connection, &chunk, chunk.count)
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk[..<count])
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let raw = buffer[..<newline]
                buffer.removeSubrange(...newline)
                let line = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                lock.withLock { received.append(line) }
                if line == "quit" { return }
                switch respond(line, session) {
                case .bytes(let data): send(data, on: connection)
                case .closing(let data):
                    send(data, on: connection)
                    return
                case .silence: break
                }
            }
        }
    }

    private func send(_ data: Data, on connection: Int32) {
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(connection, $0.baseAddress, $0.count) }
            guard written > 0 else { return }
            offset += written
        }
    }
}

extension ScriptedConsoleServer {
    /// A console that asks for no authentication (`~/.emulator_console_auth_token`
    /// empty), answering from the `noauth-*` captures. `auth …` and any
    /// command it does not know get the console's `KO: unknown command`.
    static func noAuthentication() throws -> ScriptedConsoleServer {
        let name = try EmulatorConsoleFixture.data("noauth-avd-name.bin")
        let discoveryPath = try EmulatorConsoleFixture.data("noauth-avd-discoverypath.bin")
        let grpc = try EmulatorConsoleFixture.data("noauth-avd-grpc.bin")
        let resize = try EmulatorConsoleFixture.data("noauth-resize-display-no-index.bin")
        let kill = try EmulatorConsoleFixture.data("noauth-kill.bin")
        let unknown = try EmulatorConsoleFixture.data("noauth-unknown-command.bin")
        return try ScriptedConsoleServer(greeting: EmulatorConsoleFixture.data("noauth-greeting.bin")) { line, _ in
            switch line {
            case "avd name": return .bytes(name)
            case "avd discoverypath": return .bytes(discoveryPath)
            case "avd grpc": return .bytes(grpc)
            case "resize-display": return .bytes(resize)
            case "kill": return .closing(kill)
            default: return .bytes(unknown)
            }
        }
    }

    /// A console that asks for `auth <token>`, answering from the `auth-*`
    /// captures: before authentication only `avd name` and `avd grpc` work
    /// (the `avd` help and a `KO` for the rest), and a wrong token is the
    /// captured `KO: authentication token does not match …`.
    static func authenticating(token: String) throws -> ScriptedConsoleServer {
        let nameBefore = try EmulatorConsoleFixture.data("auth-avd-name-before-auth.bin")
        let discoveryBefore = try EmulatorConsoleFixture.data("auth-avd-discoverypath-before-auth.bin")
        let unknownBefore = try EmulatorConsoleFixture.data("auth-unknown-command-before-auth.bin")
        let wrong = try EmulatorConsoleFixture.data("auth-auth-wrong-token.bin")
        let correct = try EmulatorConsoleFixture.data("auth-auth-correct-token.bin")
        let name = try EmulatorConsoleFixture.data("auth-avd-name.bin")
        let discoveryPath = try EmulatorConsoleFixture.data("adb-emu-avd-discoverypath-auth.stdout.txt")
        return try ScriptedConsoleServer(greeting: EmulatorConsoleFixture.data("auth-greeting.bin")) { line, session in
            if line.hasPrefix("auth ") {
                guard line == "auth \(token)" else { return .bytes(wrong) }
                session.isAuthenticated = true
                return .bytes(correct)
            }
            switch (line, session.isAuthenticated) {
            case ("avd name", false): return .bytes(nameBefore)
            case ("avd name", true): return .bytes(name)
            case ("avd discoverypath", false): return .bytes(discoveryBefore)
            case ("avd discoverypath", true): return .bytes(discoveryPath)
            default: return .bytes(unknownBefore)
            }
        }
    }
}

extension XCTestCase {
    /// Starts `makeServer` and stops the server when the test ends.
    func startConsoleServer(_ makeServer: () throws -> ScriptedConsoleServer) throws -> ScriptedConsoleServer {
        let server = try makeServer()
        addTeardownBlock { server.stop() }
        return server
    }

    /// A token file holding `contents` (an empty file for `""`, the user's
    /// way to switch console authentication off), or the path of a file that
    /// does not exist for nil. Never the user's own.
    func makeTokenFile(_ contents: String?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConsoleToken-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(".emulator_console_auth_token")
        if let contents { try Data(contents.utf8).write(to: file) }
        return file
    }
}
