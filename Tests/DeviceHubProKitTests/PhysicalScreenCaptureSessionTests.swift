import CoreVideo
import Synchronization
import XCTest
@testable import DeviceHubProKit

/// A fake CoreMediaIO + AVFoundation capture: it records how it was asked,
/// hands the test the frame, drop and end callbacks, and never reaches a
/// capture device or the Camera permission.
final class FakeScreenCaptureProvider: PhysicalScreenCaptureProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _allowCalls = 0
    private var _authorization: CaptureAuthorization
    private var _devices: [PhysicalCaptureDevice]
    private var _makeCalls: [String] = []
    private var _requestCalls = 0
    private var _captures: [FakeCapture] = []
    private var _failMake: Error?
    private var _changeHandlers: [@Sendable () -> Void] = []
    private var _grantOnRequest: Bool

    init(
        authorization: CaptureAuthorization = .authorized,
        devices: [PhysicalCaptureDevice] = [],
        grantOnRequest: Bool = true
    ) {
        _authorization = authorization
        _devices = devices
        _grantOnRequest = grantOnRequest
    }

    var allowCalls: Int { lock.withLock { _allowCalls } }
    var requestCalls: Int { lock.withLock { _requestCalls } }
    var makeCalls: [String] { lock.withLock { _makeCalls } }
    var captures: [FakeCapture] { lock.withLock { _captures } }
    var deviceQueries: Int { lock.withLock { _deviceQueries } }
    private var _deviceQueries = 0

    func setAuthorization(_ value: CaptureAuthorization) { lock.withLock { _authorization = value } }
    func setDevices(_ value: [PhysicalCaptureDevice]) { lock.withLock { _devices = value } }
    func failMake(with error: Error?) { lock.withLock { _failMake = error } }

    /// Tells every observer a capture device appeared or disappeared.
    func announceDeviceChange() {
        let handlers = lock.withLock { _changeHandlers }
        handlers.forEach { $0() }
    }

    func allowScreenCaptureDevices() { lock.withLock { _allowCalls += 1 } }

    func captureDevices() -> [PhysicalCaptureDevice] {
        lock.withLock {
            _deviceQueries += 1
            return _devices
        }
    }

    var authorization: CaptureAuthorization { lock.withLock { _authorization } }
    var audioAuthorization: CaptureAuthorization { .authorized }
    func requestAudioAccess() async -> Bool { true }

    func requestAccess() async -> Bool {
        lock.withLock {
            _requestCalls += 1
            if _grantOnRequest { _authorization = .authorized } else { _authorization = .denied }
            return _grantOnRequest
        }
    }

    func makeCapture(
        uniqueID: String,
        onFrame: @escaping @Sendable (CVPixelBuffer) -> Void,
        onAudio: (@Sendable (PhysicalAudioChunk) -> Void)?,
        onDrop: @escaping @Sendable () -> Void,
        onEnd: @escaping @Sendable (PhysicalCaptureEnd) -> Void
    ) throws -> any PhysicalCaptureRunning {
        try lock.withLock {
            _makeCalls.append(uniqueID)
            if let error = _failMake { throw error }
            let capture = FakeCapture(onFrame: onFrame, onDrop: onDrop, onEnd: onEnd, onAudio: onAudio)
            _captures.append(capture)
            return capture
        }
    }

    func observeDeviceChanges(_ handler: @escaping @Sendable () -> Void) -> AnyObject {
        lock.withLock { _changeHandlers.append(handler) }
        return NSObject()
    }
}

final class FakeCapture: PhysicalCaptureRunning, @unchecked Sendable {
    let onFrame: @Sendable (CVPixelBuffer) -> Void
    let onDrop: @Sendable () -> Void
    let onEnd: @Sendable (PhysicalCaptureEnd) -> Void
    /// The audio callback the capture was asked for; nil when no audio
    /// output would have been added.
    let onAudio: (@Sendable (PhysicalAudioChunk) -> Void)?
    private let state = Mutex((started: 0, stopped: 0))

    init(
        onFrame: @escaping @Sendable (CVPixelBuffer) -> Void,
        onDrop: @escaping @Sendable () -> Void,
        onEnd: @escaping @Sendable (PhysicalCaptureEnd) -> Void,
        onAudio: (@Sendable (PhysicalAudioChunk) -> Void)? = nil
    ) {
        self.onFrame = onFrame
        self.onDrop = onDrop
        self.onEnd = onEnd
        self.onAudio = onAudio
    }

    var startCount: Int { state.withLock { $0.started } }
    var stopCount: Int { state.withLock { $0.stopped } }

    func start() { state.withLock { $0.started += 1 } }
    func stop() { state.withLock { $0.stopped += 1 } }

    /// A 32BGRA, IOSurface-backed buffer of `width` x `height`, the kind the
    /// capture delivers, filled with one BGRA value.
    static func buffer(width: Int, height: Int, blue: UInt8 = 0, green: UInt8 = 0, red: UInt8 = 255) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &buffer
        )
        let made = buffer!
        CVPixelBufferLockBaseAddress(made, [])
        let base = CVPixelBufferGetBaseAddress(made)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(made)
        for row in 0..<height {
            for column in 0..<width {
                let at = row * stride + column * 4
                base[at] = blue
                base[at + 1] = green
                base[at + 2] = red
                base[at + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(made, [])
        return made
    }
}

/// `PhysicalScreenCaptureSession`, the live view-only screen of a
/// USB-connected iPhone, on a fake capture: what it
/// publishes, what it drops, how it ends, and that it never sends input.
final class PhysicalScreenCaptureSessionTests: XCTestCase {
    private let udid = "00000000-0000000000000000"
    private let captureID = "capture-device-1"

    private func makeSession(_ provider: FakeScreenCaptureProvider) -> PhysicalScreenCaptureSession {
        let session = PhysicalScreenCaptureSession(hardwareUDID: udid, captureDeviceID: captureID, provider: provider)
        addTeardownBlock { session.stop() }
        return session
    }

    @discardableResult
    private func eventually(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    func testTheSessionIsViewOnly() {
        let session = makeSession(FakeScreenCaptureProvider())
        XCTAssertEqual(session.transport, .physicalScreenCapture)
        XCTAssertEqual(MirrorTransport.physicalScreenCapture.displayName, "iPhone screen capture (view only)")
        XCTAssertEqual(session.viewKind, .liveCapture)
        XCTAssertFalse(session.supportsHardwareKeys)
        XCTAssertFalse(session.isRunning)
        // Input methods take input and do nothing: no crash, no state.
        session.send(TouchCommand(phase: .down, x: 10, y: 10))
        session.send(contacts: [TouchCommand(phase: .down, x: 10, y: 10)])
        session.send(HardwareKeyEvent(key: .power, isDown: true))
        XCTAssertNil(session.lastError)
    }

    /// Start makes the capture of the named device and starts it; the
    /// frames it delivers reach the store as BGRA pixel buffers, upright.
    func testStartCapturesTheNamedDeviceAndPublishesItsFrames() throws {
        let provider = FakeScreenCaptureProvider()
        let session = makeSession(provider)
        session.start()
        XCTAssertTrue(eventually { provider.captures.first?.startCount == 1 })
        XCTAssertEqual(provider.makeCalls, [captureID])
        XCTAssertTrue(session.isRunning)

        let capture = try XCTUnwrap(provider.captures.first)
        capture.onFrame(FakeCapture.buffer(width: 8, height: 16))
        let frame = try XCTUnwrap(session.frames.current)
        XCTAssertEqual(frame.width, 8)
        XCTAssertEqual(frame.height, 16)
        XCTAssertEqual(frame.rotation, 0)
        let pixels = try XCTUnwrap(frame.pixelBuffer)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(pixels), kCVPixelFormatType_32BGRA)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(pixels), "the renderer samples the buffer in place")
        // The RGBA bytes are made on demand, red first.
        XCTAssertEqual(Array(frame.data.prefix(4)), [255, 0, 0, 255])
    }

    /// The phone turned: the next frame has the other shape and the store
    /// takes it as it comes.
    func testAFrameOfANewSizeReplacesTheOldOne() throws {
        let provider = FakeScreenCaptureProvider()
        let session = makeSession(provider)
        session.start()
        XCTAssertTrue(eventually { provider.captures.first?.startCount == 1 })
        let capture = try XCTUnwrap(provider.captures.first)
        capture.onFrame(FakeCapture.buffer(width: 8, height: 16))
        capture.onFrame(FakeCapture.buffer(width: 16, height: 8))
        let size = try XCTUnwrap(session.frames.currentSize)
        XCTAssertEqual(size.width, 16)
        XCTAssertEqual(size.height, 8)
    }

    func testDroppedFramesAreCountedAndFramesAreReported() async throws {
        let provider = FakeScreenCaptureProvider()
        let session = makeSession(provider)
        session.start()
        XCTAssertTrue(eventually { provider.captures.first?.startCount == 1 })
        let capture = try XCTUnwrap(provider.captures.first)
        capture.onFrame(FakeCapture.buffer(width: 4, height: 4))
        capture.onDrop()
        capture.onDrop()
        let stats = await session.stats()
        XCTAssertEqual(stats.totalFrames, 1)
        XCTAssertEqual(stats.dropped, 2)
    }

    /// The phone went away: the session stops itself, says why, and stops
    /// the capture; a frame that arrives afterwards is ignored.
    func testADisconnectEndsTheSession() throws {
        let provider = FakeScreenCaptureProvider()
        let session = makeSession(provider)
        session.start()
        XCTAssertTrue(eventually { provider.captures.first?.startCount == 1 })
        let capture = try XCTUnwrap(provider.captures.first)
        capture.onEnd(.disconnected)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.lastError, PhysicalScreenCaptureSession.disconnectedMessage)
        XCTAssertTrue(eventually { capture.stopCount == 1 })
        capture.onFrame(FakeCapture.buffer(width: 4, height: 4))
        XCTAssertNil(session.frames.current, "a stopped session publishes nothing")
    }

    func testARuntimeErrorEndsTheSessionWithItsMessage() throws {
        let provider = FakeScreenCaptureProvider()
        let session = makeSession(provider)
        session.start()
        XCTAssertTrue(eventually { provider.captures.first?.startCount == 1 })
        try XCTUnwrap(provider.captures.first).onEnd(.failed("boom"))
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.lastError, "The iPhone's screen capture failed: boom")
    }

    func testAFailedCaptureIsAnErrorNotACrash() {
        let provider = FakeScreenCaptureProvider()
        provider.failMake(with: PhysicalScreenCaptureError.deviceNotFound)
        let session = makeSession(provider)
        session.start()
        XCTAssertTrue(eventually { !session.isRunning })
        XCTAssertEqual(session.lastError, PhysicalScreenCaptureError.deviceNotFound.description)
    }

    /// Stop stops the capture once, is idempotent and leaves no frames
    /// arriving; a restart makes a new capture.
    func testStopStopsTheCaptureAndARestartMakesANewOne() throws {
        let provider = FakeScreenCaptureProvider()
        let session = makeSession(provider)
        session.start()
        XCTAssertTrue(eventually { provider.captures.first?.startCount == 1 })
        let first = try XCTUnwrap(provider.captures.first)
        session.stop()
        session.stop()
        XCTAssertFalse(session.isRunning)
        XCTAssertTrue(eventually { first.stopCount == 1 })
        first.onFrame(FakeCapture.buffer(width: 4, height: 4))
        XCTAssertNil(session.frames.current)

        session.start()
        XCTAssertTrue(eventually { provider.captures.count == 2 })
        XCTAssertTrue(eventually { provider.captures.last?.startCount == 1 })
        XCTAssertTrue(session.isRunning)
    }

    /// The quit's stop returns once the capture has stopped.
    func testStopAndWaitReturnsAfterTheCaptureStopped() throws {
        let provider = FakeScreenCaptureProvider()
        let session = makeSession(provider)
        session.start()
        XCTAssertTrue(eventually { provider.captures.first?.startCount == 1 })
        let capture = try XCTUnwrap(provider.captures.first)
        session.stopAndWait(timeout: 2)
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertFalse(session.isRunning)
    }
}

/// Matching a capture device to the listed, enabled phone: the UDID in the
/// forms it can take, the strict name and model fallback, and never a device
/// that maps to no listed phone.
final class PhysicalCaptureMatcherTests: XCTestCase {
    func testCanonicalFormIgnoresCaseDashesAndWhitespace() {
        let forms = ["00008101-000A4C0E3C38001E", "00008101000a4c0e3c38001e", " 00008101-000a4c0e3c38001e\n", "0000-8101000A4C0E3C38001E"]
        XCTAssertEqual(Set(forms.map(PhysicalCaptureMatcher.canonical)).count, 1)
    }
}
