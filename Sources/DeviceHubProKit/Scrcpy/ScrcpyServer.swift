import Darwin
import Foundation

/// The vendored scrcpy server (v3.1, Apache-2.0) and the argv it is launched
/// with.
///
/// The server is pushed to `/data/local/tmp/scrcpy-server` and started with
/// `app_process`; video (and, with `control`, the control socket) arrives
/// over a per-session abstract socket (`localabstract:scrcpy_<scid>`),
/// reached through `adb forward` (the server listens, the client connects).
/// All command construction is pure so it is unit-testable;
/// `ScrcpyServerLauncher` runs it.
public enum ScrcpyServer {
    /// The pinned release; must match the vendored asset (see `Resources/README.md`).
    public static let version = "3.1"
    /// Class path for `app_process`. The server deletes the file at startup.
    public static let devicePath = "/data/local/tmp/scrcpy-server"
    /// Abstract socket name used when no `scid` is set (`scid=-1`).
    public static let socketName = "scrcpy"
    public static let mainClass = "com.genymobile.scrcpy.Server"

    /// A fresh session id. scrcpy expects 31 bits (the sign bit is reserved),
    /// so the value is always a valid `scid` and formats as 8 hex digits.
    public static func randomSessionID() -> UInt32 {
        UInt32.random(in: 0...0x7FFF_FFFF)
    }

    /// The `%08x` rendering of a session id, as scrcpy passes it on the wire.
    public static func sessionIDString(_ scid: UInt32) -> String {
        String(format: "%08x", scid)
    }

    /// The device abstract socket of one session: `scrcpy_<scid>`
    /// (`SC_SOCKET_NAME_PREFIX` in scrcpy 3.1's `app/src/server.c`). The
    /// server appends the scid, so a per-session socket cannot collide with
    /// another session's.
    public static func socketName(for scid: UInt32) -> String {
        "scrcpy_\(sessionIDString(scid))"
    }

    /// Server options, emitted as `key=value` pairs after the version.
    ///
    /// `ScrcpyServerLauncher` supports video over `adb forward`, with or
    /// without the control socket; it rejects `audio` and reverse tunnelling
    /// (`tunnelForward == false`) before touching the device, because the
    /// server would wait forever for sockets it never gets.
    public struct Options: Sendable, Equatable {
        public var logLevel: String
        public var videoBitRate: Int?
        public var maxSize: Int?
        public var maxFPS: Int?
        public var audio: Bool
        public var tunnelForward: Bool
        /// Opens the control socket (touch, keys, text, clipboard). With it
        /// the server also turns the device screen on at start (scrcpy's
        /// default `power_on`) and syncs the device clipboard to the client.
        public var control: Bool

        public init(
            logLevel: String = "info",
            videoBitRate: Int? = nil,
            maxSize: Int? = nil,
            maxFPS: Int? = nil,
            audio: Bool = false,
            tunnelForward: Bool = true,
            control: Bool = false
        ) {
            self.logLevel = logLevel
            self.videoBitRate = videoBitRate
            self.maxSize = maxSize
            self.maxFPS = maxFPS
            self.audio = audio
            self.tunnelForward = tunnelForward
            self.control = control
        }

        /// The tuned production defaults for the physical mirror:
        /// native size (`maxSize` nil), a 60 fps cap and 8 Mbps,
        /// the low end of the prescribed 8–16 Mbps range, and the control
        /// socket for input. This is the one place to change the shipped
        /// tuning when the real-phone acceptance checklist measures
        /// differently (raise the bitrate to 16 Mbps for high-motion content,
        /// or move to h265).
        public static let physicalMirror = Options(
            videoBitRate: 8_000_000,
            maxFPS: 60,
            control: true
        )
    }

    /// The vendored server inside the Kit bundle: the one packaged in the
    /// app's `Contents/Resources` first, then `Bundle.module`
    /// (`ResourceBundleLookup`).
    public static func bundledServerURL() throws -> URL {
        try bundledServerURL(resourceDirectory: Bundle.main.resourceURL, module: { Bundle.module })
    }

    /// `bundledServerURL()` with the lookup's inputs injected (test seam).
    static func bundledServerURL(resourceDirectory: URL?, module: () -> Bundle) throws -> URL {
        guard let url = ResourceBundleLookup.url(
            forResource: "scrcpy-server",
            withExtension: nil,
            bundleName: ResourceBundleLookup.kitBundleName,
            resourceDirectory: resourceDirectory,
            module: module
        ) else {
            throw ScrcpyServerError.assetMissing(name: "scrcpy-server")
        }
        return url
    }

    public static func pushArguments(
        serial: String,
        serverURL: URL,
        destination: String = devicePath
    ) -> [String] {
        ["-s", serial, "push", serverURL.path, destination]
    }

    /// The invocation scrcpy 3.1 itself runs (`app/src/server.c`): option order
    /// follows the client's emission order. `scid` comes right after the
    /// version, before `log_level`; it scopes the server's abstract socket and
    /// its command line to this mirror session.
    public static func launchArguments(
        serial: String,
        scid: UInt32,
        options: Options = Options()
    ) -> [String] {
        var arguments = [
            "-s", serial, "shell",
            "CLASSPATH=\(devicePath)",
            "app_process",
            "/",
            mainClass,
            version,
            "scid=\(sessionIDString(scid))",
            "log_level=\(options.logLevel)",
        ]
        if let videoBitRate = options.videoBitRate {
            arguments.append("video_bit_rate=\(videoBitRate)")
        }
        if !options.audio {
            arguments.append("audio=false")
        }
        if let maxSize = options.maxSize {
            arguments.append("max_size=\(maxSize)")
        }
        if let maxFPS = options.maxFPS {
            arguments.append("max_fps=\(maxFPS)")
        }
        if options.tunnelForward {
            arguments.append("tunnel_forward=true")
        }
        if !options.control {
            arguments.append("control=false")
        }
        return arguments
    }

    /// `tcp:0` lets adb pick a free local port; the server listens on the
    /// device-side abstract socket.
    public static func forwardArguments(
        serial: String,
        port: UInt16,
        deviceSocket: String
    ) -> [String] {
        ["-s", serial, "forward", "tcp:\(port)", "localabstract:\(deviceSocket)"]
    }

    public static func listForwardArguments(serial: String) -> [String] {
        ["-s", serial, "forward", "--list"]
    }

    public static func removeForwardArguments(serial: String, port: UInt16) -> [String] {
        ["-s", serial, "forward", "--remove", "tcp:\(port)"]
    }

    /// Kills only this mirror session's server, which would otherwise hold its
    /// abstract socket after a dead client. The `scid` is part of the
    /// `app_process` command line, so the pattern cannot reach another
    /// session's server (or a desktop scrcpy instance).
    public static func stopArguments(serial: String, scid: UInt32) -> [String] {
        ["-s", serial, "shell", "pkill", "-f", "scid=\(sessionIDString(scid))"]
    }

    /// The `tcp:` ports `forward --list` reports for `serial`'s
    /// `localabstract:deviceSocket` forward. Used to reclaim a forward whose
    /// allocation output could not be parsed.
    public static func parseForwardPorts(
        fromList output: String,
        serial: String,
        deviceSocket: String
    ) -> [UInt16] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3,
                  fields[0] == Substring(serial),
                  fields[2] == Substring("localabstract:\(deviceSocket)"),
                  fields[1].hasPrefix("tcp:"),
                  let port = UInt16(fields[1].dropFirst("tcp:".count))
            else { return nil }
            return port
        }
    }

    /// The port `adb forward tcp:0 …` answered with.
    public static func parseForwardPort(_ output: String) -> UInt16? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = UInt16(trimmed), port > 0 else { return nil }
        return port
    }
}

public enum ScrcpyServerError: Error, CustomStringConvertible {
    case assetMissing(name: String)
    case launchFailed(message: String)
    case handshakeFailed(message: String)

    public var description: String {
        switch self {
        case .assetMissing(let name):
            return "the vendored \(name) is missing from the DeviceHubProKit bundle"
        case .launchFailed(let message):
            return "could not launch the scrcpy server: \(message)"
        case .handshakeFailed(let message):
            return "the scrcpy server did not complete the video handshake: \(message)"
        }
    }
}

/// Pushes, starts and tunnels the vendored server for one adb target.
public struct ScrcpyServerLauncher: Sendable {
    public let serial: String
    private let adb: AdbClient
    private let options: ScrcpyServer.Options
    private let handshakeTimeout: Duration
    private let sessionID: UInt32?

    public init(
        serial: String,
        adb: AdbClient,
        options: ScrcpyServer.Options = ScrcpyServer.Options(),
        handshakeTimeout: Duration = .seconds(10),
        sessionID: UInt32? = nil
    ) {
        self.serial = serial
        self.adb = adb
        self.options = options
        self.handshakeTimeout = handshakeTimeout
        self.sessionID = sessionID
    }

    /// Pushes and launches the server under a fresh session id, then connects
    /// the forwarded video socket (consuming its dummy byte) and, with
    /// `control`, the control socket, in the order the server accepts them.
    /// Throws after cleaning up only this mirror session's tunnel and server when it
    /// does not answer; a server that exits first fails the launch at once,
    /// quoting what it printed. No device-global sweep runs: a stale server
    /// holds a different scoped socket, so it cannot interfere with this
    /// launch.
    ///
    /// The forward is removed as soon as the sockets are connected, as
    /// scrcpy's own client does (`sc_adb_tunnel_close` in `app/src/server.c`):
    /// established connections survive the removal, so no forward can outlive
    /// a crash or a quit.
    public func start() async throws -> ScrcpyServerConnection {
        try Self.validate(options)
        let serverURL = try ScrcpyServer.bundledServerURL()
        let scid = sessionID ?? ScrcpyServer.randomSessionID()
        let deviceSocket = ScrcpyServer.socketName(for: scid)

        _ = try await adb.run(
            ScrcpyServer.pushArguments(serial: serial, serverURL: serverURL)
        )

        let forwardOutput = try await adb.run(
            ScrcpyServer.forwardArguments(serial: serial, port: 0, deviceSocket: deviceSocket)
        )
        guard let port = ScrcpyServer.parseForwardPort(forwardOutput) else {
            // The forward succeeded (the command exited zero) but its output
            // was not a port. Reclaim it through `forward --list` before
            // failing, or the tunnel would outlive this launch attempt.
            await removeSessionForward(deviceSocket: deviceSocket)
            throw ScrcpyServerError.launchFailed(
                message: "adb forward did not report a port (got \"\(forwardOutput.trimmingCharacters(in: .whitespacesAndNewlines))\")"
            )
        }

        let serverLog = ScrcpyServerLog()
        let process: Process
        do {
            process = try Self.launchServer(
                executable: adb.adbURL,
                arguments: ScrcpyServer.launchArguments(
                    serial: serial,
                    scid: scid,
                    options: options
                ),
                log: serverLog
            )
        } catch {
            _ = try? await adb.run(ScrcpyServer.removeForwardArguments(serial: serial, port: port))
            throw ScrcpyServerError.launchFailed(message: error.localizedDescription)
        }

        do {
            let sockets = try await Self.connectSockets(
                port: port,
                control: options.control,
                timeout: handshakeTimeout,
                serverLog: serverLog
            )
            let removed = (try? await adb.run(
                ScrcpyServer.removeForwardArguments(serial: serial, port: port)
            )) != nil
            return ScrcpyServerConnection(
                port: port,
                videoHandle: sockets.video,
                controlHandle: sockets.control,
                adb: adb,
                serial: serial,
                process: process,
                scid: scid,
                serverLog: serverLog,
                forwardActive: !removed
            )
        } catch {
            if process.isRunning {
                process.terminate()
            }
            _ = try? await adb.run(ScrcpyServer.removeForwardArguments(serial: serial, port: port))
            _ = try? await adb.run(ScrcpyServer.stopArguments(serial: serial, scid: scid))
            throw error
        }
    }

    /// Rejects option combinations the launcher cannot serve. The server
    /// would otherwise wait forever for a socket nobody opens (audio) or dial
    /// a reverse tunnel nobody created, and never send its stream header.
    static func validate(_ options: ScrcpyServer.Options) throws {
        if options.audio {
            throw ScrcpyServerError.launchFailed(
                message: "audio forwarding is not supported (the launcher opens no audio socket)"
            )
        }
        if !options.tunnelForward {
            throw ScrcpyServerError.launchFailed(
                message: "reverse tunnelling is not supported (the launcher only sets up adb forward)"
            )
        }
    }

    /// Starts `adb shell … app_process …` with its console captured into
    /// `log`, and records its exit there so the connect loop can stop
    /// waiting for a server that is already gone.
    private static func launchServer(
        executable: URL,
        arguments: [String],
        log: ScrcpyServerLog
    ) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let console = Pipe()
        process.standardOutput = console
        process.standardError = console
        process.terminationHandler = { finished in
            ChildProcessRegistry.unregister(finished)
            log.markExited(status: finished.terminationStatus)
        }
        // `run()` closes the parent's copy of the pipe's write end, so the
        // capture sees EOF as soon as the process (and adb) let go of it.
        try process.run()
        ChildProcessRegistry.register(process)
        log.capture(console.fileHandleForReading)
        return process
    }

    /// Removes every forward `forward --list` reports for this serial's
    /// session socket. Used when the allocated port never reached us, so the
    /// per-port removal argument cannot be built.
    private func removeSessionForward(deviceSocket: String) async {
        guard let list = try? await adb.run(
            ScrcpyServer.listForwardArguments(serial: serial)
        ) else { return }

        let ports = ScrcpyServer.parseForwardPorts(
            fromList: list,
            serial: serial,
            deviceSocket: deviceSocket
        )
        for port in ports {
            _ = try? await adb.run(
                ScrcpyServer.removeForwardArguments(serial: serial, port: port)
            )
        }
    }

    private struct ConnectedSockets: @unchecked Sendable {
        let video: FileHandle
        let control: FileHandle?
    }

    private static func connectSockets(
        port: UInt16,
        control: Bool,
        timeout: Duration,
        serverLog: ScrcpyServerLog
    ) async throws -> ConnectedSockets {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try blockingConnectSockets(
                        port: port,
                        control: control,
                        timeout: seconds(from: timeout),
                        serverLog: serverLog
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The video socket first (the server writes the dummy byte on it), then
    /// the control socket: `DesktopConnection.open` accepts them in that
    /// order and sends the stream header only once every socket is in. The
    /// second socket needs no retry loop: the server is already listening.
    private static func blockingConnectSockets(
        port: UInt16,
        control: Bool,
        timeout: TimeInterval,
        serverLog: ScrcpyServerLog
    ) throws -> ConnectedSockets {
        var address = loopbackAddress(port: port)
        let video = try blockingConnect(address: &address, timeout: timeout, serverLog: serverLog)
        guard control else {
            return ConnectedSockets(video: video, control: nil)
        }
        guard let descriptor = connectOnce(address: &address) else {
            try? video.close()
            throw ScrcpyServerError.handshakeFailed(
                message: serverLog.annotate("connect(127.0.0.1:\(port)) failed for the control socket")
            )
        }
        return ConnectedSockets(
            video: video,
            control: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        )
    }

    private static func loopbackAddress(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    /// Connects and reads the dummy byte the server writes on accept (scrcpy's
    /// `send_dummy_byte`), which proves the server — not just adb's local
    /// listener — is behind the tunnel. With `adb forward`, adb accepts the
    /// local connection even before the device side listens and closes it as
    /// soon as the device refuses, so only a closed or failed connection is
    /// retried (like scrcpy's `connect_and_read_byte` loop). A connection that
    /// stays open without the byte has already been accepted by the server
    /// (the byte is still in transit, e.g. over wireless adb), so it is
    /// waited on until the deadline: dropping it would spend the server's
    /// video accept on a dead socket and hand the retry to its control
    /// accept. A server process that has exited ends the wait at once.
    private static func blockingConnect(
        address: inout sockaddr_in,
        timeout: TimeInterval,
        serverLog: ScrcpyServerLog
    ) throws -> FileHandle {
        let deadline = Date().addingTimeInterval(max(timeout, 0.1))
        let port = UInt16(bigEndian: address.sin_port)

        var lastFailure = "the server is not listening yet"
        while Date() < deadline {
            try throwIfExited(serverLog)
            guard let descriptor = connectOnce(address: &address) else {
                lastFailure = "connect(127.0.0.1:\(port)) failed"
                usleep(50_000)
                continue
            }

            var outcome = DummyByte.timedOut
            while Date() < deadline, serverLog.exitStatus == nil {
                outcome = readDummyByte(descriptor: descriptor, deadline: deadline)
                if outcome != .timedOut { break }
            }
            switch outcome {
            case .received:
                return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            case .closed:
                close(descriptor)
                lastFailure = "the connection was closed before the dummy byte arrived"
                usleep(50_000)
            case .timedOut:
                close(descriptor)
                lastFailure = "the connection stayed open without the dummy byte"
            }
        }

        try throwIfExited(serverLog)
        throw ScrcpyServerError.handshakeFailed(
            message: serverLog.annotate(
                "no dummy byte within \(String(format: "%.1f", timeout))s (\(lastFailure))"
            )
        )
    }

    private static func throwIfExited(_ serverLog: ScrcpyServerLog) throws {
        guard let status = serverLog.exitStatus else { return }
        serverLog.waitForOutputEnd(timeout: 0.5)
        throw ScrcpyServerError.handshakeFailed(
            message: serverLog.annotate(
                "the server exited with status \(status) before accepting the video socket"
            )
        )
    }

    private static func connectOnce(address: inout sockaddr_in) -> Int32? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    private enum DummyByte {
        case received
        /// EOF, a socket error or a hang-up: the tunnel refused this
        /// connection, so a new one may be tried.
        case closed
        /// Nothing yet on a connection that is still open.
        case timedOut
    }

    /// Waits for the dummy byte for one short slice, so the caller can notice
    /// a server exit between slices without dropping the connection.
    private static func readDummyByte(descriptor: Int32, deadline: Date) -> DummyByte {
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let timeout = Int32(min(max(deadline.timeIntervalSinceNow, 0), 0.5) * 1000)

        let result = poll(&pollDescriptor, 1, timeout)
        if result == 0 || (result < 0 && errno == EINTR) {
            return .timedOut
        }
        guard result > 0,
              pollDescriptor.revents & Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL) != 0
        else { return .closed }

        var byte: UInt8 = 0
        let count = read(descriptor, &byte, 1)
        if count == 1 { return .received }
        if count < 0, errno == EINTR { return .timedOut }
        return .closed
    }

    private static func seconds(from duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}

/// One live server process and its tunneled sockets.
///
/// Teardown is shared by ``stop()`` and ``stopSynchronously(timeout:)``: the
/// first caller performs it (close the sockets, end the local `adb shell`,
/// remove the forward if the launcher could not, kill the session's device
/// server) and later callers wait for it to finish.
public final class ScrcpyServerConnection: @unchecked Sendable {
    /// The bound on an asynchronous ``stop()``'s adb calls.
    static let teardownTimeout: TimeInterval = 10

    public let port: UInt16
    /// The video stream socket: dummy byte already consumed, then device meta
    /// and the 12-byte-framed H.264 stream.
    public let videoHandle: FileHandle
    /// The video socket's descriptor, captured while the handle is open:
    /// `FileHandle.fileDescriptor` raises once the handle is closed, so
    /// readers and ``shutdownSockets()`` never ask the handle for it.
    let videoDescriptor: Int32
    /// The control socket, when the server was launched with `control`.
    public let control: ScrcpyControlChannel?
    /// What the device server printed, when the launcher captured it.
    public let serverLog: ScrcpyServerLog?

    /// The session id the device server was launched with. Teardown kills only
    /// this server, never another session's.
    let scid: UInt32

    private let adb: AdbClient
    private let serial: String
    private let process: Process
    private let lock = NSLock()
    private var socketsClosed = false
    private var stopClaimed = false
    /// Whether the adb forward still exists (the launcher removes it once the
    /// sockets are connected; only a failed removal leaves it to teardown).
    private var forwardActive: Bool
    private let stopped = DispatchGroup()

    init(
        port: UInt16,
        videoHandle: FileHandle,
        controlHandle: FileHandle? = nil,
        adb: AdbClient,
        serial: String,
        process: Process,
        scid: UInt32,
        serverLog: ScrcpyServerLog? = nil,
        forwardActive: Bool = true
    ) {
        self.port = port
        self.videoHandle = videoHandle
        videoDescriptor = videoHandle.fileDescriptor
        control = controlHandle.map { ScrcpyControlChannel(handle: $0) }
        self.adb = adb
        self.serial = serial
        self.process = process
        self.scid = scid
        self.serverLog = serverLog
        self.forwardActive = forwardActive
        stopped.enter()
    }

    /// Wakes every blocked read and write on the sockets without releasing
    /// them, so the thread using a socket can finish with it before teardown
    /// closes it (a closed descriptor number can be reused at once).
    /// Idempotent; a no-op after teardown.
    public func shutdownSockets() {
        lock.lock()
        defer { lock.unlock() }
        guard !socketsClosed else { return }
        Darwin.shutdown(videoDescriptor, SHUT_RDWR)
        control?.shutdown()
    }

    /// Closes the sockets (the server exits on its own once its client is
    /// gone), ends the local `adb shell`, removes the forward if it is still
    /// there and kills the session's device process. Idempotent.
    public func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                self.stopSynchronously(timeout: Self.teardownTimeout)
                continuation.resume()
            }
        }
    }

    /// ``stop()`` for callers that must know teardown is done when they
    /// return, such as the app's termination path: waits at most `timeout`
    /// (each adb call is bounded by what is left of it). Returns false when
    /// the bound cut teardown short.
    @discardableResult
    public func stopSynchronously(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        guard claimStop() else {
            return stopped.wait(timeout: .now() + max(0, timeout)) == .success
        }
        defer { stopped.leave() }

        closeSockets()
        if process.isRunning {
            process.terminate()
        }
        var completed = true
        if takeForward() {
            completed = adb.runBlocking(
                ScrcpyServer.removeForwardArguments(serial: serial, port: port),
                timeout: deadline.timeIntervalSinceNow
            ) && completed
        }
        completed = adb.runBlocking(
            ScrcpyServer.stopArguments(serial: serial, scid: scid),
            timeout: deadline.timeIntervalSinceNow
        ) && completed
        return completed && Date() <= deadline
    }

    private func closeSockets() {
        lock.lock()
        socketsClosed = true
        lock.unlock()
        control?.close()
        try? videoHandle.close()
    }

    /// True for the first caller only.
    private func claimStop() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopClaimed else { return false }
        stopClaimed = true
        return true
    }

    private func takeForward() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let active = forwardActive
        forwardActive = false
        return active
    }
}
