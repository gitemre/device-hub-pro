import Foundation
import XCTest
@testable import DeviceHubProKit

/// Launcher-level lifecycle tests with a fake adb: no device is needed and
/// every invocation is observable. They pin the findings — the launch
/// is scoped to a unique `scid` (no device-global `pkill`), and a forward that
/// cannot be parsed is removed before the error is thrown.
final class ScrcpyServerLauncherTests: XCTestCase {
    func testStartNeverSweepsDeviceGlobalServersAndScopesTheSession() async throws {
        let tunnel = try makeForwardWithoutServer()
        let stub = try StubAdb(forwardPortOutput: "\(tunnel.port)")
        let launcher = ScrcpyServerLauncher(
            serial: "stub-serial",
            adb: stub.client,
            handshakeTimeout: .milliseconds(100)
        )

        _ = try? await launcher.start()

        let lines = stub.lines
        XCTAssertFalse(
            lines.contains { $0.contains("pkill") && $0.contains("com.genymobile.scrcpy.Server") },
            "a launch must never sweep device-global servers: \(lines)"
        )

        let forward = try XCTUnwrap(
            lines.first { $0.contains("forward tcp:0") },
            "no forward was issued: \(lines)"
        )
        let socketField = try XCTUnwrap(
            forward.split(separator: " ").first { $0.hasPrefix("localabstract:scrcpy_") },
            "the forward must target a per-session socket: \(forward)"
        )
        let scid = socketField.dropFirst("localabstract:scrcpy_".count)
        XCTAssertEqual(scid.count, 8, "a scid is 8 hex digits: \(socketField)")

        let launch = try XCTUnwrap(
            lines.first { $0.contains("app_process") },
            "the server was not launched: \(lines)"
        )
        XCTAssertTrue(
            launch.contains("scid=\(scid)"),
            "the server must be launched with its own scid (\(scid)): \(launch)"
        )
    }

    func testForwardIsRemovedWhenThePortCannotBeParsed() async throws {
        // Nothing connects: the launch stops at the parse. The listing names
        // the forward adb made.
        let stub = try StubAdb(forwardPortOutput: "not-a-port", listedPort: "4599")
        let launcher = ScrcpyServerLauncher(
            serial: "stub-serial",
            adb: stub.client,
            handshakeTimeout: .milliseconds(100)
        )

        do {
            _ = try await launcher.start()
            XCTFail("the unparsable forward output must fail the launch")
        } catch let error as ScrcpyServerError {
            guard case .launchFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let lines = stub.lines
        XCTAssertTrue(
            lines.contains { $0.contains("forward") && $0.contains("--remove") && $0.contains("tcp:4599") },
            "the forward allocated before the parse failure must be removed: \(lines)"
        )
    }

    func testTeardownKillsOnlyTheLaunchedSessionsServer() async throws {
        let tunnel = try makeForwardWithoutServer()
        let stub = try StubAdb(forwardPortOutput: "\(tunnel.port)")
        let launcher = ScrcpyServerLauncher(
            serial: "stub-serial",
            adb: stub.client,
            handshakeTimeout: .milliseconds(100)
        )

        _ = try? await launcher.start()

        // The launch failed at the handshake, so the cleanup killed the
        // session's device server. It may only use the scid the launch chose.
        let lines = stub.lines
        let forward = try XCTUnwrap(lines.first { $0.contains("forward tcp:0") })
        let socketField = try XCTUnwrap(
            forward.split(separator: " ").first { $0.hasPrefix("localabstract:scrcpy_") }
        )
        let scid = socketField.dropFirst("localabstract:scrcpy_".count)

        let kills = lines.filter { $0.contains("pkill") }
        XCTAssertFalse(kills.isEmpty, "the failed launch must kill its own server: \(lines)")
        for kill in kills {
            XCTAssertTrue(
                kill.contains("scid=\(scid)"),
                "every kill must target the session scid \(scid): \(kill)"
            )
        }
    }

    // MARK: - Unsupported options

    /// `audio` and reverse tunnelling make the server wait for sockets the
    /// launcher never opens; they must fail before anything touches the
    /// device instead of producing a session that never sends a header.
    func testUnsupportedOptionsAreRejectedBeforeTouchingTheDevice() async throws {
        let stub = try StubAdb(forwardPortOutput: "4599")
        for options in [
            ScrcpyServer.Options(audio: true),
            ScrcpyServer.Options(tunnelForward: false),
        ] {
            let launcher = ScrcpyServerLauncher(
                serial: "stub-serial",
                adb: stub.client,
                options: options,
                handshakeTimeout: .milliseconds(100)
            )
            do {
                _ = try await launcher.start()
                XCTFail("\(options) must be rejected")
            } catch let error as ScrcpyServerError {
                guard case .launchFailed(let message) = error else {
                    return XCTFail("unexpected error: \(error)")
                }
                XCTAssertTrue(message.contains("not supported"), message)
            }
        }
        XCTAssertEqual(stub.lines, [], "no adb command may run for an unsupported option")
    }

    // MARK: - Server output

    /// A server that dies at startup used to cost the whole handshake
    /// deadline and then report only "no dummy byte"; its own explanation
    /// went to /dev/null. The launch must fail as soon as the process exits,
    /// quoting what it printed.
    func testAServerThatExitsFailsTheLaunchAtOnceAndQuotesItsOutput() async throws {
        let tunnel = try makeForwardWithoutServer()
        let stub = try StubAdb(
            forwardPortOutput: "\(tunnel.port)",
            serverScript: """
            echo "[server] INFO: Device: stub"
            echo "[server] ERROR: Could not open video stream" >&2
            exit 1
            """
        )
        let launcher = ScrcpyServerLauncher(
            serial: "stub-serial",
            adb: stub.client,
            handshakeTimeout: .seconds(20)
        )

        let started = Date()
        do {
            _ = try await launcher.start()
            XCTFail("a server that exits must fail the launch")
        } catch let error as ScrcpyServerError {
            guard case .handshakeFailed(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("status 1"), message)
            XCTAssertTrue(message.contains("Could not open video stream"), message)
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            5,
            "the launch must not wait out the 20 s handshake deadline"
        )
        XCTAssertTrue(
            stub.lines.contains { $0.contains("forward --remove tcp:\(tunnel.port)") },
            "the failed launch must still remove its forward: \(stub.lines)"
        )
    }

    // MARK: - Sockets

    /// Over a slow tunnel (wireless adb, a remote adb) the dummy byte can take
    /// longer than one poll slice. The connection is already the server's
    /// video socket by then: dropping it and reconnecting used to hand the
    /// retry to the server's control accept, which never sends a dummy byte,
    /// so the launch failed. The launcher must keep waiting on the connection
    /// it has.
    func testASlowDummyByteKeepsTheFirstConnectionAsTheVideoSocket() async throws {
        let server = try FakeScrcpyServer(dummyByteDelay: 1.2)
        let stub = try StubAdb(
            forwardPortOutput: "\(server.port)",
            serverScript: "exec sleep 30"
        )
        let launcher = ScrcpyServerLauncher(
            serial: "stub-serial",
            adb: stub.client,
            options: ScrcpyServer.Options(control: true),
            handshakeTimeout: .seconds(5)
        )

        let connection = try await launcher.start()
        let accepted = try XCTUnwrap(server.waitForConnections(2))
        XCTAssertEqual(
            server.connectionCount,
            2,
            "only the video and the control socket may be opened, no retries"
        )

        try accepted.video.write(contentsOf: Data("video".utf8))
        let video = try XCTUnwrap(try connection.videoHandle.read(upToCount: 5))
        XCTAssertEqual(String(decoding: video, as: UTF8.self), "video")

        let control = try XCTUnwrap(connection.control)
        control.send(.backOrScreenOn(action: .down))
        let written = try XCTUnwrap(try accepted.control.read(upToCount: 2))
        XCTAssertEqual([UInt8](written), [0x04, 0x00])

        await connection.stop()
        _ = server
    }

    /// Waiting on a silent connection must still notice the server dying:
    /// the exit fails the launch at once instead of after the deadline.
    func testAServerThatExitsWhileTheConnectionIsSilentFailsTheLaunchAtOnce() async throws {
        let server = try FakeScrcpyServer(dummyByteDelay: 60)
        let stub = try StubAdb(
            forwardPortOutput: "\(server.port)",
            serverScript: """
            sleep 1
            echo "[server] ERROR: Could not create the display" >&2
            exit 1
            """
        )
        let launcher = ScrcpyServerLauncher(
            serial: "stub-serial",
            adb: stub.client,
            handshakeTimeout: .seconds(20)
        )

        let started = Date()
        do {
            _ = try await launcher.start()
            XCTFail("a server that exits must fail the launch")
        } catch let error as ScrcpyServerError {
            guard case .handshakeFailed(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("status 1"), message)
            XCTAssertTrue(message.contains("Could not create the display"), message)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(server.connectionCount, 1, "the silent connection must not be retried")
    }

    /// Against a fake server behind the "forwarded" port: the video socket is
    /// connected first (and its dummy byte consumed), the control socket
    /// second, the adb forward is removed as soon as both are connected (as
    /// scrcpy's client does, so no forward outlives a crash or a quit), and
    /// teardown does not remove it a second time.
    func testConnectsVideoThenControlAndDropsTheForwardOnceConnected() async throws {
        let server = try FakeScrcpyServer()
        let stub = try StubAdb(
            forwardPortOutput: "\(server.port)",
            serverScript: """
            echo "[server] INFO: Device: [stub] fake (Android 15)"
            exec sleep 30
            """
        )
        let launcher = ScrcpyServerLauncher(
            serial: "stub-serial",
            adb: stub.client,
            options: ScrcpyServer.Options(control: true),
            handshakeTimeout: .seconds(5)
        )

        let connection = try await launcher.start()

        let accepted = try XCTUnwrap(server.waitForConnections(2), "the server saw \(server.connectionCount) connections")
        let control = try XCTUnwrap(connection.control, "control=true must connect the control socket")

        let afterStart = stub.lines
        XCTAssertEqual(
            afterStart.filter { $0.contains("forward --remove tcp:\(server.port)") }.count,
            1,
            "the forward must be gone once the sockets are connected: \(afterStart)"
        )

        // The first accepted socket carries the stream: what the server
        // writes there must come out of the connection's video handle.
        try accepted.video.write(contentsOf: Data("video".utf8))
        let video = try XCTUnwrap(try connection.videoHandle.read(upToCount: 5))
        XCTAssertEqual(String(decoding: video, as: UTF8.self), "video")

        // The second one is the control socket.
        control.send(.backOrScreenOn(action: .down))
        let written = try XCTUnwrap(try accepted.control.read(upToCount: 2))
        XCTAssertEqual([UInt8](written), [0x04, 0x00])

        let log = try XCTUnwrap(connection.serverLog)
        let deadline = Date().addingTimeInterval(3)
        while log.lines.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(log.lines, ["[server] INFO: Device: [stub] fake (Android 15)"])

        await connection.stop()
        let lines = stub.lines
        XCTAssertEqual(
            lines.filter { $0.contains("--remove") }.count,
            1,
            "teardown must not remove a forward the launcher already removed (the port may belong to someone else by now): \(lines)"
        )
        XCTAssertTrue(lines.contains { $0.contains("pkill -f scid=") }, "\(lines)")
        XCTAssertFalse(control.isUsable)
        _ = server
    }
}

/// A loopback listener standing in for the device server behind `adb
/// forward`: it writes the dummy byte on the first accepted socket (after
/// `dummyByteDelay`, like a slow wireless tunnel) and keeps every accepted
/// socket open.
private final class FakeScrcpyServer: @unchecked Sendable {
    struct Accepted {
        let video: FileHandle
        let control: FileHandle
    }

    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var accepted: [FileHandle] = []

    init(dummyByteDelay: TimeInterval = 0) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listener, 8) == 0 else {
            close(listener)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &length)
            }
        }
        self.listener = listener
        port = UInt16(bigEndian: address.sin_port)

        DispatchQueue.global().async { [self] in
            while true {
                let descriptor = accept(listener, nil, nil)
                guard descriptor >= 0 else { return }
                var on: Int32 = 1
                setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                lock.lock()
                let isFirst = accepted.isEmpty
                accepted.append(handle)
                lock.unlock()
                if isFirst {
                    // Only while the server (and so the accepted handle) is
                    // alive: a late write must not reach a recycled descriptor.
                    DispatchQueue.global().asyncAfter(deadline: .now() + dummyByteDelay) { [weak self] in
                        guard let self else { return }
                        withExtendedLifetime(self) {
                            var dummy: UInt8 = 0
                            _ = write(descriptor, &dummy, 1)
                        }
                    }
                }
            }
        }
    }

    deinit {
        Darwin.shutdown(listener, SHUT_RDWR)
        close(listener)
    }

    var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return accepted.count
    }

    func waitForConnections(_ count: Int, timeout: TimeInterval = 3) -> Accepted? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let handles = accepted
            lock.unlock()
            if handles.count >= count {
                return Accepted(video: handles[0], control: handles[1])
            }
            usleep(10_000)
        }
        return nil
    }
}

/// adb's forward before the device server is up: a loopback listener the
/// test owns that accepts each connection and closes it at once, so the
/// launcher's connect loop retries until its handshake deadline (or the
/// server's exit). It stands where a fixed port would reach whatever else
/// listens there; no other process can listen on 127.0.0.1 at this port
/// while it lives.
private final class ForwardWithoutServer: @unchecked Sendable {
    let port: UInt16
    private let lock = NSLock()
    private var stopped = false

    init() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listener, 8) == 0 else {
            let code = Int(errno)
            close(listener)
            throw NSError(domain: NSPOSIXErrorDomain, code: code)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &length)
            }
        }
        port = UInt16(bigEndian: address.sin_port)
        // The loop owns the socket and closes it once stopped.
        let thread = Thread { [self] in
            var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            while !lock.withLock({ stopped }) {
                guard poll(&ready, 1, 50) > 0 else { continue }
                let accepted = accept(listener, nil, nil)
                if accepted >= 0 { close(accepted) }
            }
            close(listener)
        }
        thread.start()
    }

    /// Stops listening: the loop closes the socket within 50 ms.
    func stop() {
        lock.withLock { stopped = true }
    }
}

extension XCTestCase {
    /// A `ForwardWithoutServer` that lives until the test ends.
    fileprivate func makeForwardWithoutServer() throws -> ForwardWithoutServer {
        let forward = try ForwardWithoutServer()
        addTeardownBlock { forward.stop() }
        return forward
    }
}

/// A fake `adb` that logs its argv. `forward tcp:0` answers with
/// `forwardPortOutput`; `forward --list` echoes the per-session forward the
/// launcher created (on `listedPort`, by default the answered port), so the
/// cleanup path sees a realistic listing. The `app_process` launch runs
/// `serverScript` (by default it exits at once).
private final class StubAdb {
    let client: AdbClient
    private let directory: URL
    private let logURL: URL

    init(forwardPortOutput: String, listedPort: String? = nil, serverScript: String = "") throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicehubpro-launcher-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        logURL = directory.appendingPathComponent("calls.log")
        let socketURL = directory.appendingPathComponent("device-socket")
        let scriptURL = directory.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(logURL.path)"
        for arg in "$@"; do
          case "$arg" in
            localabstract:*) printf '%s' "${arg#localabstract:}" > "\(socketURL.path)" ;;
          esac
        done
        case " $* " in
          *" forward --list "*)
            if [ -f "\(socketURL.path)" ]; then
              printf 'stub-serial tcp:\(listedPort ?? forwardPortOutput) localabstract:%s\\n' "$(cat "\(socketURL.path)")"
            fi
            ;;
          *" forward tcp:0 "*)
            printf '%s\\n' "\(forwardPortOutput)"
            ;;
          *" app_process "*)
        \(serverScript)
            ;;
        esac
        exit 0
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        client = AdbClient(adbURL: scriptURL)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    var lines: [String] {
        (try? String(contentsOf: logURL, encoding: .utf8))?
            .split(separator: "\n")
            .map(String.init) ?? []
    }
}
