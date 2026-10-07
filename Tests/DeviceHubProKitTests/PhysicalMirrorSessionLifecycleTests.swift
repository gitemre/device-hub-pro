import Darwin
import Foundation
import XCTest
@testable import DeviceHubProKit

/// Lifecycle tests for `PhysicalMirrorSession` that do not need a device: a
/// stub adb logs its invocations, and socketpairs stand in for the tunnelled
/// video socket. They cover the two review findings —
/// unexpected EOF must be fatal and tear the tunnel down, and overlapping
/// starts must leave exactly one live connection.
final class PhysicalMirrorSessionLifecycleTests: XCTestCase {
    // MARK: - Unexpected EOF

    func testUnexpectedEOFIsFatalAndTearsDownTheSession() async throws {
        let stub = try StubAdb()
        let (video, peer) = try Self.socketPair()
        let connection = ScrcpyServerConnection(
            port: 4321,
            videoHandle: video,
            adb: stub.client,
            serial: "stub-serial",
            process: Process(),
            scid: 0x0000_4321
        )
        let session = PhysicalMirrorSession(serial: "stub-serial") {
            connection
        }
        defer { session.stop() }

        session.start()
        try await Task.sleep(for: .milliseconds(150))

        // The server (or the adb tunnel) goes away while the session runs.
        try peer.close()

        let error = await Self.waitForError(on: session)
        XCTAssertEqual(error, "The mirror stream ended unexpectedly")
        XCTAssertFalse(
            session.isRunning,
            "a fatal stream error must leave the session stopped, not frozen"
        )

        // `stop()` issues the forward removal first and the server kill
        // second; waiting for the kill also guarantees the removal ran.
        let lines = await Self.waitForLog(stub, containing: "scid=00004321")
        XCTAssertTrue(
            lines.contains { $0.contains("forward") && $0.contains("--remove") && $0.contains("tcp:4321") },
            "the stale forward must be removed: \(lines)"
        )
        XCTAssertTrue(
            lines.contains { $0.contains("pkill") && $0.contains("scid=00004321") },
            "only this mirror session's device server must be killed: \(lines)"
        )
    }

    // MARK: - Stall bound

    /// A peer that declares a large packet and then trickles stops the serial
    /// reader forever unless the read loop wakes up and enforces the stall
    /// deadline. The 64 MiB cap bounds memory; this bounds the wait.
    func testTricklingAnIncompletePacketFailsTheSessionOnTheStallDeadline() async throws {
        let stub = try StubAdb()
        let (video, peer) = try Self.socketPair()
        let connection = ScrcpyServerConnection(
            port: 4331,
            videoHandle: video,
            adb: stub.client,
            serial: "stub-serial",
            process: Process(),
            scid: 0x0000_4331
        )
        let session = PhysicalMirrorSession(
            serial: "stub-serial",
            stallTimeout: 0.4
        ) {
            connection
        }
        defer { session.stop() }

        session.start()
        try await Task.sleep(for: .milliseconds(150))

        var bytes = Data()
        var nameField = Data("stub-device".utf8)
        nameField.append(Data(count: 64 - nameField.count))
        bytes.append(nameField)
        bytes.append(contentsOf: [0x68, 0x32, 0x36, 0x34]) // "h264"
        bytes.append(contentsOf: [0x00, 0x00, 0x04, 0x38]) // 1080
        bytes.append(contentsOf: [0x00, 0x00, 0x07, 0x80]) // 1920
        bytes.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 1]) // pts 1
        bytes.append(contentsOf: [0x00, 0x10, 0x00, 0x00]) // declares 1 MiB
        bytes.append(Data(repeating: 0x5A, count: 64))     // ...and stops
        try peer.write(contentsOf: bytes)

        let error = await Self.waitForError(on: session, timeout: 5)
        XCTAssertTrue(
            error?.contains("stalled") == true,
            "the session must fail with a typed stall error, got \(error ?? "nil")"
        )
        _ = peer
    }

    // MARK: - Deliberate stop

    func testDeliberateStopDoesNotReportAnError() async throws {
        let stub = try StubAdb()
        let (video, peer) = try Self.socketPair()
        let connection = ScrcpyServerConnection(
            port: 4322,
            videoHandle: video,
            adb: stub.client,
            serial: "stub-serial",
            process: Process(),
            scid: 0x0000_4322
        )
        let session = PhysicalMirrorSession(serial: "stub-serial") {
            connection
        }
        defer { session.stop() }

        session.start()
        try await Task.sleep(for: .milliseconds(150))

        // `stop()` shuts the socket down itself; the resulting read must not
        // be reported as an unexpected end of stream.
        session.stop()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertNil(session.lastError)
        let lines = await Self.waitForLog(stub, containing: "tcp:4322")
        XCTAssertTrue(
            lines.contains { $0.contains("forward") && $0.contains("--remove") && $0.contains("tcp:4322") },
            "the tunnel must still be cleaned up: \(lines)"
        )
        _ = peer
    }

    // MARK: - Overlapping starts

    func testOverlappingStartsLeaveExactlyOneLiveConnection() async throws {
        let stub = try StubAdb()
        let (videoA, peerA) = try Self.socketPair()
        let (videoB, peerB) = try Self.socketPair()
        let connectionA = ScrcpyServerConnection(
            port: 4401,
            videoHandle: videoA,
            adb: stub.client,
            serial: "stub-serial",
            process: Process(),
            scid: 0x0000_4401
        )
        let connectionB = ScrcpyServerConnection(
            port: 4402,
            videoHandle: videoB,
            adb: stub.client,
            serial: "stub-serial",
            process: Process(),
            scid: 0x0000_4402
        )
        let gate = StartGate()
        let session = PhysicalMirrorSession(serial: "stub-serial") {
            await gate.next(first: connectionA, second: connectionB)
        }
        defer { session.stop() }

        // Keep both peer ends open: closing B's peer would end the live stream.
        let peers = [peerA, peerB]

        // First start parks inside its launcher; the second start lands while
        // it is still in flight.
        session.start()
        try await Task.sleep(for: .milliseconds(150))
        session.start()
        try await Task.sleep(for: .milliseconds(150))
        await gate.releaseFirst()

        withExtendedLifetime(peers) {
            let lines = Self.waitForLogBlocking(stub, containing: "scid=00004401")
            XCTAssertTrue(
                lines.contains { $0.contains("--remove") && $0.contains("tcp:4401") },
                "the superseded connection must be torn down: \(lines)"
            )
            XCTAssertTrue(
                lines.contains { $0.contains("pkill") && $0.contains("scid=00004401") },
                "the superseded session's own server must be killed: \(lines)"
            )
            XCTAssertFalse(
                lines.contains { $0.contains("tcp:4402") },
                "the winning connection must stay live: \(lines)"
            )
            XCTAssertFalse(
                lines.contains { $0.contains("scid=00004402") },
                "the winner's server must not be touched: \(lines)"
            )
            XCTAssertNil(session.lastError)
        }

        // The survivor is still the session's connection: stopping it tears B
        // down and nothing else.
        session.stop()
        let stopped = await Self.waitForLog(stub, containing: "scid=00004402")
        XCTAssertTrue(
            stopped.contains { $0.contains("--remove") && $0.contains("tcp:4402") },
            "the surviving connection must still be owned by the session: \(stopped)"
        )
        XCTAssertTrue(
            stopped.contains { $0.contains("pkill") && $0.contains("scid=00004402") },
            "the surviving session's server must be killed by its own scid: \(stopped)"
        )
    }

    // MARK: - Per-session teardown

    /// Two sessions on the same device: stopping one may only ever kill its
    /// own server (the finding — the device-global `pkill` reached
    /// every scrcpy server, including desktop instances).
    func testStoppingOneSessionNeverKillsAnotherSessionsServer() async throws {
        let stub = try StubAdb()
        let (videoA, peerA) = try Self.socketPair()
        let (videoB, peerB) = try Self.socketPair()
        let connectionA = ScrcpyServerConnection(
            port: 4411,
            videoHandle: videoA,
            adb: stub.client,
            serial: "stub-serial",
            process: Process(),
            scid: 0x0000_4411
        )
        let connectionB = ScrcpyServerConnection(
            port: 4412,
            videoHandle: videoB,
            adb: stub.client,
            serial: "stub-serial",
            process: Process(),
            scid: 0x0000_4412
        )

        await connectionA.stop()

        let lines = await Self.waitForLog(stub, containing: "scid=00004411")
        XCTAssertTrue(
            lines.contains { $0.contains("pkill") && $0.contains("scid=00004411") },
            "session A's server must be killed: \(lines)"
        )
        XCTAssertFalse(
            lines.contains { $0.contains("scid=00004412") },
            "session B's server and forward must be untouched: \(lines)"
        )
        _ = (peerA, peerB, connectionB)
    }

    // MARK: - Teardown ownership

    /// `stop()` used to close the claimed connection itself, racing the read
    /// loop: a loop that started afterwards asked the closed `FileHandle` for
    /// its descriptor (an uncaught NSException), and one already inside
    /// `poll`/`read` could be handed a recycled descriptor. Once claimed, the
    /// connection now belongs to its read loop: `stop()` only shuts the
    /// sockets down, and the loop tears the connection down when it lets go.
    func testStopBeforeTheReadLoopRunsLeavesTheTeardownToTheLoop() async throws {
        let stub = try StubAdb()
        let (video, peer) = try Self.socketPair()
        let connection = ScrcpyServerConnection(
            port: 4601,
            videoHandle: video,
            adb: stub.client,
            serial: "stub-serial",
            process: Process(),
            scid: 0x0000_4601
        )
        let session = PhysicalMirrorSession(serial: "stub-serial") { connection }
        defer { session.stop() }

        // Hold the read queue so the claimed connection's loop cannot start.
        let gate = DispatchSemaphore(value: 0)
        session.readQueue.async { gate.wait() }

        session.start()
        try await Task.sleep(for: .milliseconds(150))
        session.stop()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(
            stub.lines.contains { $0.contains("pkill") },
            "stop() must not close a connection whose read loop has not let go of it: \(stub.lines)"
        )

        gate.signal()
        let lines = await Self.waitForLog(stub, containing: "scid=00004601")
        XCTAssertTrue(
            lines.contains { $0.contains("pkill") && $0.contains("scid=00004601") },
            "the read loop must tear the connection down once it runs: \(lines)"
        )
        XCTAssertNil(session.lastError)
        _ = peer
    }

    /// The app's quit path cannot wait for an asynchronous teardown: when
    /// `stopAndWait` returns, the device server must already be killed and
    /// the forward removed.
    func testStopAndWaitFinishesTheTeardownBeforeReturning() throws {
        let stub = try StubAdb()
        let (video, peer) = try Self.socketPair()
        let connection = ScrcpyServerConnection(
            port: 4602,
            videoHandle: video,
            adb: stub.client,
            serial: "stub-serial",
            process: Process(),
            scid: 0x0000_4602
        )
        let session = PhysicalMirrorSession(serial: "stub-serial") { connection }

        session.start()
        // Let the launch closure return and the read loop take the socket.
        usleep(300_000)

        session.stopAndWait(timeout: 5)

        let lines = stub.lines
        XCTAssertTrue(
            lines.contains { $0.contains("forward --remove tcp:4602") },
            "the forward must be gone when stopAndWait returns: \(lines)"
        )
        XCTAssertTrue(
            lines.contains { $0.contains("pkill -f scid=00004602") },
            "the device server must be killed when stopAndWait returns: \(lines)"
        )
        XCTAssertFalse(session.isRunning)
        _ = peer
    }

    /// Quitting while the launch is still connecting used to return at once:
    /// the launch then connected into a session that no longer wanted it and
    /// left its teardown to a task the quit never let run, so the device
    /// server and the local `adb shell` outlived the app. `stopAndWait` now
    /// waits for the launch, which tears its late connection down.
    func testStopAndWaitCoversALaunchStillInFlight() throws {
        let stub = try StubAdb()
        let (video, peer) = try Self.socketPair()
        let connection = ScrcpyServerConnection(
            port: 4603,
            videoHandle: video,
            adb: stub.client,
            serial: "stub-serial",
            process: Process(),
            scid: 0x0000_4603
        )
        let gate = LaunchGate()
        let session = PhysicalMirrorSession(serial: "stub-serial") {
            await gate.wait()
            return connection
        }

        session.start()
        usleep(150_000)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            Task { await gate.open() }
        }

        session.stopAndWait(timeout: 5)

        let lines = stub.lines
        XCTAssertTrue(
            lines.contains { $0.contains("pkill -f scid=00004603") },
            "the late connection's server must be killed when stopAndWait returns: \(lines)"
        )
        XCTAssertFalse(session.isRunning)
        _ = peer
    }

    // MARK: - Deadlines

    /// A server that accepts the sockets and never sends the stream header
    /// used to leave the stage connecting forever with no error.
    func testAMissingStreamHeaderFailsTheSessionOnItsDeadline() async throws {
        let stub = try StubAdb()
        let (video, peer) = try Self.socketPair()
        let connection = ScrcpyServerConnection(
            port: 4611,
            videoHandle: video,
            adb: stub.client,
            serial: "stub-serial",
            process: Process(),
            scid: 0x0000_4611
        )
        let session = PhysicalMirrorSession(serial: "stub-serial", headerTimeout: 0.5) {
            connection
        }
        defer { session.stop() }

        session.start()
        try peer.write(contentsOf: Data("stub".utf8))   // a partial device name

        let error = await Self.waitForError(on: session, timeout: 5)
        XCTAssertTrue(
            error?.contains("no stream header") == true,
            "expected the typed header deadline, got \(error ?? "nil")"
        )
        XCTAssertFalse(session.isRunning)
        let lines = await Self.waitForLog(stub, containing: "scid=00004611")
        XCTAssertTrue(lines.contains { $0.contains("pkill") }, "\(lines)")
    }

    /// The header arrives, then nothing: the first-frame deadline fails the
    /// session instead of letting it idle as "running" with no picture.
    func testAStreamWithoutAFirstFrameFailsOnItsDeadline() async throws {
        let stub = try StubAdb()
        let (video, peer) = try Self.socketPair()
        let connection = ScrcpyServerConnection(
            port: 4612,
            videoHandle: video,
            adb: stub.client,
            serial: "stub-serial",
            process: Process(),
            scid: 0x0000_4612
        )
        let session = PhysicalMirrorSession(
            serial: "stub-serial",
            headerTimeout: 5,
            firstFrameTimeout: 0.8
        ) {
            connection
        }
        defer { session.stop() }

        session.start()
        try peer.write(contentsOf: Self.handshake(width: 1080, height: 1920))

        let error = await Self.waitForError(on: session, timeout: 5)
        XCTAssertTrue(
            error?.contains("no video frame") == true,
            "expected the first-frame deadline, got \(error ?? "nil")"
        )
        XCTAssertFalse(session.isRunning)
    }

    // MARK: - Server output

    /// A server that dies mid-stream used to surface only as "The mirror
    /// stream ended unexpectedly"; its own explanation was discarded.
    func testAnUnexpectedEOFQuotesWhatTheServerPrinted() async throws {
        let stub = try StubAdb()
        let (video, peer) = try Self.socketPair()
        let log = ScrcpyServerLog()
        log.append("[server] INFO: Device: stub\n")
        log.append("[server] ERROR: Encoding error: android.media.MediaCodec$CodecException\n")
        log.markExited(status: 1)
        log.finishOutput()
        let connection = ScrcpyServerConnection(
            port: 4621,
            videoHandle: video,
            adb: stub.client,
            serial: "stub-serial",
            process: Process(),
            scid: 0x0000_4621,
            serverLog: log
        )
        let session = PhysicalMirrorSession(serial: "stub-serial") { connection }
        defer { session.stop() }

        session.start()
        try await Task.sleep(for: .milliseconds(150))
        try peer.close()

        let error = await Self.waitForError(on: session)
        XCTAssertEqual(
            error,
            "The mirror stream ended unexpectedly (scrcpy server: [server] INFO: Device: stub | "
                + "[server] ERROR: Encoding error: android.media.MediaCodec$CodecException)"
        )
    }

    // MARK: - Decode errors

    /// An asynchronous VideoToolbox error used to run the whole teardown on
    /// the decoder's output handler, where invalidating the decoder never
    /// returned: the session reported the error but leaked its socket, the
    /// adb forward and the device server. The teardown must now complete.
    func testAnAsynchronousDecodeErrorFailsTheSessionAndCompletesItsTeardown() async throws {
        let stream = try ScrcpyVideoDecoderTests.encodedStream(width: 64, height: 48, frameCount: 2)
        let corrupt = ScrcpyVideoDecoderTests.corrupted(try XCTUnwrap(stream.frames.first))
        let stub = try StubAdb()
        let (video, peer) = try Self.socketPair()
        let connection = ScrcpyServerConnection(
            port: 4631,
            videoHandle: video,
            adb: stub.client,
            serial: "stub-serial",
            process: Process(),
            scid: 0x0000_4631
        )
        let session = PhysicalMirrorSession(serial: "stub-serial") { connection }
        defer { session.stop() }

        session.start()
        var bytes = Self.handshake(width: 64, height: 48)
        bytes.append(Self.packet(ptsWord: ScrcpyFraming.packetFlagConfig, payload: stream.config.payload))
        bytes.append(Self.packet(
            ptsWord: ScrcpyFraming.packetFlagKeyFrame | UInt64(corrupt.pts),
            payload: corrupt.payload
        ))
        try peer.write(contentsOf: bytes)

        let error = await Self.waitForError(on: session, timeout: 5)
        XCTAssertTrue(error?.contains("decode") == true, "\(error ?? "nil")")
        let lines = await Self.waitForLog(stub, containing: "scid=00004631", timeout: 5)
        XCTAssertTrue(
            lines.contains { $0.contains("pkill") && $0.contains("scid=00004631") },
            "the decode failure must still tear the connection down: \(lines)"
        )
        XCTAssertFalse(session.isRunning)
        _ = peer
    }

    // MARK: - Helpers

    /// The stream prefix after the dummy byte: a NUL-padded device name, the
    /// "h264" codec id and the video size.
    static func handshake(width: UInt32, height: UInt32) -> Data {
        var bytes = Data("stub-device".utf8)
        bytes.append(Data(count: 64 - bytes.count))
        bytes.append(contentsOf: [0x68, 0x32, 0x36, 0x34])
        for value in [width, height] {
            bytes.append(contentsOf: [
                UInt8(truncatingIfNeeded: value >> 24),
                UInt8(truncatingIfNeeded: value >> 16),
                UInt8(truncatingIfNeeded: value >> 8),
                UInt8(truncatingIfNeeded: value),
            ])
        }
        return bytes
    }

    static func packet(ptsWord: UInt64, payload: Data) -> Data {
        var bytes = Data()
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: ptsWord >> UInt64(shift)))
        }
        let size = UInt32(payload.count)
        for shift in stride(from: 24, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: size >> UInt32(shift)))
        }
        bytes.append(payload)
        return bytes
    }

    private static func socketPair() throws -> (FileHandle, FileHandle) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return (
            FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true),
            FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        )
    }

    private static func waitForError(
        on session: PhysicalMirrorSession,
        timeout: TimeInterval = 3
    ) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let error = session.lastError { return error }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return session.lastError
    }

    private static func waitForLog(
        _ stub: StubAdb,
        containing needle: String,
        timeout: TimeInterval = 3
    ) async -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let lines = stub.lines
            if lines.contains(where: { $0.contains(needle) }) { return lines }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return stub.lines
    }

    private static func waitForLogBlocking(
        _ stub: StubAdb,
        containing needle: String,
        timeout: TimeInterval = 3
    ) -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let lines = stub.lines
            if lines.contains(where: { $0.contains(needle) }) { return lines }
            usleep(50_000)
        }
        return stub.lines
    }
}

/// A fake `adb` executable that appends its argv to a log file. The session's
/// teardown path (`forward --remove`, `pkill`) is observable through it.
private final class StubAdb {
    let client: AdbClient
    private let directory: URL
    private let logURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicehubpro-scrcpy-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        logURL = directory.appendingPathComponent("calls.log")
        let scriptURL = directory.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(logURL.path)"
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

/// Holds a launch until it is opened.
private actor LaunchGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

/// Deliveries connection A after being released and connection B immediately,
/// so the second `start()` can be in flight while the first is parked.
private actor StartGate {
    private var calls = 0
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func next(
        first: ScrcpyServerConnection,
        second: ScrcpyServerConnection
    ) async -> ScrcpyServerConnection {
        calls += 1
        if calls == 1 {
            if !open {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    waiters.append(continuation)
                }
            }
            return first
        }
        return second
    }

    func releaseFirst() {
        open = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
