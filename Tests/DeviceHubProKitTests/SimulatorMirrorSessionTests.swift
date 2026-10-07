import CoreVideo
import IOSurface
import Synchronization
import XCTest
@testable import DeviceHubProKit

/// `SimulatorMirrorSession` on `FakeSimulatorBridge`: publishing (first
/// surface, trailing edge, idle, seed retry), upright frames and the input
/// mapping back to native ratios, the keyboard routing, and the lifecycle.
/// The surfaces are synthetic in-memory buffers (see
/// `SimulatorFrameCopierTests`). The tests call the session from the main
/// thread, as the app does; the fake counts any bridge call made there.
final class SimulatorMirrorSessionTests: XCTestCase {
    private let udid = "00000000-0000-4000-8000-00000000A11A"

    private func makeSurface(width: Int = 4, height: Int = 8) throws -> SimulatorSurface {
        SimulatorSurface(try SimulatorFrameCopierTests.makeSurface(width: width, height: height))
    }

    /// Paints every pixel's red byte, so frames can be told apart; bumps the
    /// seed like a presented frame.
    private func paint(_ surface: SimulatorSurface, _ value: UInt8) {
        let raw = surface.surface
        raw.lock(options: [], seed: nil)
        let base = raw.baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in 0..<raw.height {
            for x in 0..<raw.width {
                base[y * raw.bytesPerRow + x * 4 + 2] = value
            }
        }
        raw.unlock(options: [], seed: nil)
    }

    private func red(of frame: Frame?) -> UInt8? {
        guard let buffer = frame?.pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)[2]
    }

    private func makeBridge(surface: SimulatorSurface?, uiOrientation: UInt32 = 1, width: Int = 4, height: Int = 8) -> FakeSimulatorBridge {
        var configuration = FakeSimulatorBridge.Configuration()
        configuration.surface = surface
        configuration.properties = SimulatorScreenProperties(
            screenType: 0, screenID: 1, uiOrientation: uiOrientation, pixelWidth: width, pixelHeight: height
        )
        return FakeSimulatorBridge(configuration)
    }

    private func makeSession(
        _ bridge: FakeSimulatorBridge,
        interval: Duration = .milliseconds(1),
        layout: SimulatorKeyboardLayout? = .usQWERTY,
        deviceSet: URL = URL(fileURLWithPath: "/tmp/SimulatorMirrorSessionTests", isDirectory: true),
        pasteboard: (@Sendable (String) async throws -> Void)? = nil
    ) -> SimulatorMirrorSession {
        let session = SimulatorMirrorSession(
            udid: udid,
            deviceSet: deviceSet,
            bridge: bridge,
            minimumPublishInterval: interval,
            keyboardLayout: layout,
            pasteboardWriter: pasteboard
        )
        addTeardownBlock { session.stopAndWait() }
        return session
    }

    /// Polls `condition` on the main thread until it holds or `timeout` passes.
    @discardableResult
    private func eventually(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition()
    }

    private func screen(_ bridge: FakeSimulatorBridge) throws -> FakeSimulatorScreen {
        XCTAssertTrue(eventually { bridge.screens.first?.isStarted == true }, "the screen was started")
        return try XCTUnwrap(bridge.screens.first)
    }

    private func sentEvents(_ bridge: FakeSimulatorBridge) -> [SimulatorHIDEvent] {
        bridge.inputs.first?.sent ?? []
    }

    // MARK: - Frames

    func testTheTransport() {
        XCTAssertEqual(MirrorTransport.simulatorSurface.displayName, "simulator IOSurface")
        let session = makeSession(makeBridge(surface: nil))
        XCTAssertEqual(session.transport, .simulatorSurface)
        XCTAssertFalse(session.isRunning)
    }

    /// The surface arriving right after registering is published without any
    /// frame callback: an idle screen sends none.
    func testTheFirstSurfaceIsPublishedUprightWithoutAFrameCallback() throws {
        let surface = try makeSurface()
        let bridge = makeBridge(surface: surface)
        let session = makeSession(bridge)
        session.start()
        XCTAssertTrue(session.isRunning)
        XCTAssertTrue(eventually { session.frames.current != nil })
        let frame = try XCTUnwrap(session.frames.current)
        XCTAssertEqual(frame.width, 4)
        XCTAssertEqual(frame.height, 8)
        XCTAssertEqual(frame.rotation, 0, "display-oriented, like scrcpy")
        XCTAssertNotNil(frame.pixelBuffer)
        let published = try XCTUnwrap(frame.pixelBuffer.flatMap { CVPixelBufferGetIOSurface($0)?.takeUnretainedValue() })
        XCTAssertNotEqual(IOSurfaceGetID(published), surface.surfaceID, "never the live surface")
        XCTAssertEqual(frame.data.count, 4 * 8 * 4, "RGBA bytes on request")
        let statistics = session.surfaceStatistics()
        XCTAssertEqual(statistics.publishedFrames, 1)
        XCTAssertEqual(statistics.frameCallbacks, 0)
        XCTAssertEqual(bridge.mainThreadCalls, 0, "no bridge call on the main thread")
    }

    func testAnIdleScreenPublishesNothingMore() throws {
        let bridge = makeBridge(surface: try makeSurface())
        let session = makeSession(bridge)
        session.start()
        XCTAssertTrue(eventually { session.surfaceStatistics().publishedFrames == 1 })
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(session.surfaceStatistics().publishedFrames, 1)
    }

    /// Ten callbacks inside one interval: one publish at the end of the
    /// burst, and it shows the burst's last frame.
    func testABurstPublishesItsTrailingFrame() throws {
        let surface = try makeSurface()
        let bridge = makeBridge(surface: surface)
        let session = makeSession(bridge, interval: .milliseconds(300))
        session.start()
        let screen = try screen(bridge)
        XCTAssertTrue(eventually { session.surfaceStatistics().publishedFrames == 1 })
        for value in 1...10 {
            paint(surface, UInt8(value))
            screen.emit(.frame)
        }
        XCTAssertTrue(eventually(2) { session.surfaceStatistics().publishedFrames == 2 }, "the trailing publish")
        let statistics = session.surfaceStatistics()
        XCTAssertEqual(statistics.frameCallbacks, 10)
        XCTAssertEqual(statistics.coalescedCallbacks, 9)
        XCTAssertEqual(red(of: session.frames.current), 10, "the burst's last frame, not a stale one")
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(session.surfaceStatistics().publishedFrames, 2, "nothing after the burst")
        XCTAssertEqual(bridge.mainThreadCalls, 0)
    }

    /// Callbacks faster than the interval are held to it.
    func testPublishesAreHeldToTheInterval() throws {
        let surface = try makeSurface()
        let bridge = makeBridge(surface: surface)
        let session = makeSession(bridge, interval: .milliseconds(40))
        session.start()
        let screen = try screen(bridge)
        XCTAssertTrue(eventually { session.surfaceStatistics().publishedFrames == 1 })
        let started = Date()
        for value in 1...60 {
            paint(surface, UInt8(value))
            screen.emit(.frame)
            Thread.sleep(forTimeInterval: 0.004)
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(eventually { self.red(of: session.frames.current) == 60 }, "the last frame lands")
        let published = session.surfaceStatistics().publishedFrames - 1
        XCTAssertLessThanOrEqual(published, Int(elapsed / 0.040) + 2, "at most one publish per interval")
        XCTAssertGreaterThanOrEqual(published, 2)
    }

    /// A write during the first copy is copied again; writes during both
    /// count as torn, and the session copies once more.
    func testTheSeedRetryAndTheTornCount() throws {
        let surface = try makeSurface()
        let bridge = makeBridge(surface: surface)
        let session = makeSession(bridge)
        let writes = Locked(2)
        session.copier.afterCopyAttempt = { raw, _ in
            let write = writes.withLock { remaining -> Bool in
                guard remaining > 0 else { return false }
                remaining -= 1
                return true
            }
            if write { SimulatorFrameCopierTests.scribble(raw) }
        }
        session.start()
        XCTAssertTrue(eventually { session.surfaceStatistics().publishedFrames == 2 }, "the torn frame is replaced")
        let statistics = session.surfaceStatistics()
        XCTAssertEqual(statistics.retriedCopies, 1)
        XCTAssertEqual(statistics.tornFrames, 1)
        XCTAssertEqual(statistics.uprightCopies.count, 2)
    }

    /// Frames are published upright for the reported orientation, and a
    /// rotation republishes at once.
    func testFramesAreTurnedForTheInterfaceOrientation() throws {
        let bridge = makeBridge(surface: try makeSurface(width: 4, height: 8), uiOrientation: 3)
        let session = makeSession(bridge)
        session.start()
        XCTAssertTrue(eventually { session.frames.current != nil })
        XCTAssertEqual(session.frames.current?.width, 8, "turned a quarter at start")
        XCTAssertEqual(session.frames.current?.height, 4)
        XCTAssertEqual(session.publishedRotation, .clockwise)

        let screen = try screen(bridge)
        screen.emit(.propertiesChanged(SimulatorScreenProperties(screenType: 0, screenID: 1, uiOrientation: 1, pixelWidth: 4, pixelHeight: 8)))
        XCTAssertTrue(eventually { session.frames.current?.width == 4 })
        XCTAssertEqual(session.publishedRotation, .upright)
        XCTAssertEqual(session.frames.current?.rotation, 0)
        let buffer = try XCTUnwrap(session.frames.current?.pixelBuffer)
        XCTAssertTrue(SimulatorFrameCopierTests.marker(buffer, x: 3, y: 7) == (3, 7))
    }

    func testResyncRecopiesTheSurface() async throws {
        let surface = try makeSurface()
        let bridge = makeBridge(surface: surface)
        let session = makeSession(bridge)
        session.start()
        for _ in 0..<300 where session.surfaceStatistics().publishedFrames == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        paint(surface, 77)
        await session.resync()
        XCTAssertEqual(session.surfaceStatistics().publishedFrames, 2)
        XCTAssertEqual(red(of: session.frames.current), 77)
        let stats = await session.stats()
        XCTAssertEqual(stats.totalFrames, 2)
        XCTAssertEqual(stats.dropped, 0)
    }

    private func waitForTheFirstPublish(_ session: SimulatorMirrorSession) async throws {
        for _ in 0..<300 where session.surfaceStatistics().publishedFrames == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(session.surfaceStatistics().publishedFrames, 1)
    }

    /// A resync copies what a paced publish was scheduled for; that publish
    /// then has nothing left to copy.
    func testAResyncCoversTheScheduledPublish() async throws {
        let surface = try makeSurface()
        let bridge = makeBridge(surface: surface)
        let session = makeSession(bridge, interval: .milliseconds(300))
        session.start()
        let screen = try screen(bridge)
        try await waitForTheFirstPublish(session)
        paint(surface, 1)
        screen.emit(.frame)  // scheduled for 300 ms after the first publish
        await session.resync()
        XCTAssertEqual(session.surfaceStatistics().publishedFrames, 2)
        XCTAssertEqual(red(of: session.frames.current), 1)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(session.surfaceStatistics().publishedFrames, 2, "no second copy of the same frame")
    }

    /// A frame after a resync folds into the publish already scheduled,
    /// which keeps to the interval after the resync's copy, rather than
    /// scheduling a second publish beside it.
    func testAResyncKeepsThePacing() async throws {
        let surface = try makeSurface()
        let bridge = makeBridge(surface: surface)
        let session = makeSession(bridge, interval: .milliseconds(300))
        session.start()
        let screen = try screen(bridge)
        try await waitForTheFirstPublish(session)
        paint(surface, 1)
        screen.emit(.frame)  // scheduled for 300 ms after the first publish
        await session.resync()
        let resynced = Date()
        XCTAssertEqual(session.surfaceStatistics().publishedFrames, 2)
        paint(surface, 2)
        screen.emit(.frame)
        for _ in 0..<100 where session.surfaceStatistics().publishedFrames < 3 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(resynced), 0.29, "not sooner than the interval after the resync")
        try await Task.sleep(for: .milliseconds(700))
        let statistics = session.surfaceStatistics()
        XCTAssertEqual(statistics.publishedFrames, 3, "one publish after the resync, not two")
        XCTAssertEqual(statistics.frameCallbacks, 2)
        XCTAssertEqual(statistics.coalescedCallbacks, 1)
        XCTAssertEqual(red(of: session.frames.current), 2)
    }

    /// A rotation reported while `resync` reads the properties is newer than
    /// what the read returns: the read must not turn the picture back.
    func testAResyncReadDoesNotUndoARotationThatOvertookIt() async throws {
        let bridge = makeBridge(surface: try makeSurface(width: 4, height: 8))
        let session = makeSession(bridge)
        session.start()
        let screen = try screen(bridge)
        try await waitForTheFirstPublish(session)
        XCTAssertEqual(session.publishedRotation, .upright)
        let landscape = SimulatorScreenProperties(screenType: 0, screenID: 1, uiOrientation: 4, pixelWidth: 4, pixelHeight: 8)
        screen.interceptNextCurrentProperties { screen.emit(.propertiesChanged(landscape)) }
        await session.resync()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(session.publishedRotation, .counterClockwise)
        XCTAssertEqual(session.frames.current?.width, 8)
        XCTAssertEqual(session.frames.current?.height, 4)
    }

    // MARK: - Lifecycle

    /// A nil surface means the device went away: the session stops itself,
    /// unregistering from its own queue (the fake stops the process on the
    /// callback queue).
    func testShutdownStopsTheSession() throws {
        let bridge = makeBridge(surface: try makeSurface())
        let session = makeSession(bridge)
        session.start()
        let screen = try screen(bridge)
        screen.emit(.surfaceChanged(nil))
        XCTAssertTrue(eventually { !session.isRunning })
        XCTAssertEqual(session.lastError, "The simulator shut down.")
        XCTAssertTrue(eventually { screen.unregisterCount == 1 })
        XCTAssertFalse(screen.isStarted)
        // Late events of the dead session change nothing.
        screen.emit(.frame)
        XCTAssertEqual(session.surfaceStatistics().frameCallbacks, 0)
    }

    func testStopIsIdempotentAndUnregistersOnce() throws {
        let bridge = makeBridge(surface: try makeSurface())
        let session = makeSession(bridge)
        session.start()
        let screen = try screen(bridge)
        session.stop()
        session.stop()
        session.stopAndWait()
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(screen.registerCount, 1)
        XCTAssertEqual(screen.unregisterCount, 1)
        XCTAssertNil(session.lastError)
        session.send(TouchCommand(phase: .down, x: 1, y: 1))
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertTrue(bridge.inputs.isEmpty, "a stopped session sends nothing")
        XCTAssertEqual(bridge.mainThreadCalls, 0)
    }

    func testARestartRegistersAgain() throws {
        let bridge = makeBridge(surface: try makeSurface())
        let session = makeSession(bridge)
        session.start()
        _ = try screen(bridge)
        session.start()
        XCTAssertTrue(eventually { bridge.screens.count == 2 && bridge.screens[1].isStarted })
        XCTAssertTrue(eventually { bridge.screens[0].unregisterCount == 1 })
        XCTAssertTrue(session.isRunning)
    }

    /// A restart opens a new input channel: the disconnects `stop()` queues
    /// for the old one (which on the live bridge cancel a connect in
    /// progress) never reach the channel the new start types on.
    func testARestartTypesOnItsOwnInputChannel() throws {
        let bridge = makeBridge(surface: try makeSurface())
        let session = makeSession(bridge)
        session.start()
        session.send(.text("a"))
        XCTAssertTrue(eventually { bridge.inputs.first?.sent.count == 2 })
        session.start()
        session.send(.text("b"))
        XCTAssertTrue(eventually { bridge.inputs.count == 2 && bridge.inputs[1].sent.count == 2 }, "a channel of its own")
        XCTAssertTrue(eventually { bridge.screens.count == 2 && bridge.screens[0].unregisterCount == 1 })
        session.send(.text("c"))
        XCTAssertTrue(eventually { bridge.inputs.count == 2 && bridge.inputs[1].sent.count == 4 })
        let inputs = bridge.inputs
        XCTAssertEqual(inputs.count, 2)
        guard inputs.count == 2 else { return }
        XCTAssertEqual(inputs[0].sent, SimulatorKeyStroke(usage: 0x04).events)
        XCTAssertEqual(inputs[1].sent, SimulatorKeyStroke(usage: 0x05).events + SimulatorKeyStroke(usage: 0x06).events)
        XCTAssertFalse(inputs[0].isConnected, "the old channel is disconnected")
        XCTAssertTrue(inputs[1].isConnected, "the new one is left alone")
        XCTAssertEqual(inputs[1].connectAttempts, 1)
        XCTAssertNil(session.lastError)
    }

    func testAFailedStartLandsInLastError() {
        var configuration = FakeSimulatorBridge.Configuration()
        configuration.screenError = SimulatorBridgeError(.deviceNotBooted, "simulator X is Shutdown, not booted")
        let session = makeSession(FakeSimulatorBridge(configuration))
        session.start()
        XCTAssertTrue(eventually { !session.isRunning })
        XCTAssertEqual(session.lastError, "simulator X is Shutdown, not booted")
    }

    // MARK: - Touch

    /// Nothing connects to dtuhidd before the first input event.
    func testInputIsLazy() throws {
        let bridge = makeBridge(surface: try makeSurface())
        let session = makeSession(bridge)
        session.start()
        XCTAssertTrue(eventually { session.frames.current != nil })
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertTrue(bridge.inputs.isEmpty)
        session.send(TouchCommand(phase: .down, x: 1, y: 1))
        XCTAssertTrue(eventually { bridge.inputs.first?.connectAttempts == 1 })
    }

    /// Displayed pixels map to native ratios through the published frame's
    /// rotation, and an edge contact carries the native edge throughout.
    func testTouchMapsThroughThePublishedRotation() throws {
        // uiOrientation 4: the published frame is 800×400.
        let bridge = makeBridge(surface: try makeSurface(width: 400, height: 800), uiOrientation: 4, width: 400, height: 800)
        let session = makeSession(bridge)
        session.start()
        XCTAssertTrue(eventually { session.frames.current?.width == 800 })

        let rotation = SimulatorFrameRotation.counterClockwise
        session.send(TouchCommand(phase: .down, x: 200, y: 100, id: 1))
        session.send(TouchCommand(phase: .move, x: 500, y: 200, id: 1))
        session.send(TouchCommand(phase: .up, x: 600, y: 200, id: 1))
        XCTAssertTrue(eventually { self.sentEvents(bridge).count == 3 })
        let expected = [(200.0, 100.0, SimulatorTouchPhase.began), (500, 200, .moved), (600, 200, .ended)].map { x, y, phase in
            let point = rotation.nativeRatio(displayX: x, displayY: y, displayWidth: 800, displayHeight: 400)
            return SimulatorHIDEvent.touch(x: point.x, y: point.y, phase: phase)
        }
        XCTAssertEqual(sentEvents(bridge), expected)

        // A swipe up from the displayed bottom starts at the panel's left edge.
        session.send(TouchCommand(phase: .down, x: 400, y: 398, id: 2))
        session.send(TouchCommand(phase: .move, x: 400, y: 200, id: 2))
        session.send(TouchCommand(phase: .up, x: 400, y: 100, id: 2))
        XCTAssertTrue(eventually { self.sentEvents(bridge).count == 6 })
        let edges = sentEvents(bridge).suffix(3).map { event -> SimulatorTouchEdge? in
            if case .edgeTouch(_, _, _, let edge) = event { return edge }
            return nil
        }
        XCTAssertEqual(edges, [.left, .left, .left])
        XCTAssertEqual(bridge.mainThreadCalls, 0)
    }

    func testTwoContactsBecomeOneTwoFingerTouch() throws {
        let bridge = makeBridge(surface: try makeSurface(width: 100, height: 200))
        let session = makeSession(bridge)
        session.start()
        XCTAssertTrue(eventually { session.frames.current != nil })
        session.send(contacts: [TouchCommand(phase: .down, x: 40, y: 90, id: 1), TouchCommand(phase: .down, x: 60, y: 110, id: 2)])
        session.send(contacts: [TouchCommand(phase: .move, x: 30, y: 80, id: 1), TouchCommand(phase: .move, x: 70, y: 120, id: 2)])
        session.send(contacts: [TouchCommand(phase: .up, x: 30, y: 80, id: 1), TouchCommand(phase: .up, x: 70, y: 120, id: 2)])
        XCTAssertTrue(eventually { self.sentEvents(bridge).count == 3 })
        let phases = sentEvents(bridge).map { event -> SimulatorTouchPhase? in
            if case .twoFingerTouch(_, _, let phase) = event { return phase }
            return nil
        }
        XCTAssertEqual(phases, [.began, .moved, .ended])
        if case .twoFingerTouch(let first, let second, _) = sentEvents(bridge)[0] {
            XCTAssertEqual(first, SimulatorTouchPoint(x: 40.5 / 100, y: 90.5 / 200))
            XCTAssertEqual(second, SimulatorTouchPoint(x: 60.5 / 100, y: 110.5 / 200))
        }
    }

    /// Before the first frame there is nothing to position a touch against.
    func testTouchesBeforeTheFirstFrameAreDropped() {
        let session = makeSession(makeBridge(surface: nil))
        session.start()
        session.send(TouchCommand(phase: .down, x: 1, y: 1))
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertNil(session.frames.current)
    }

    /// A dtuhidd that never answers drops the input that queued behind the
    /// failed connect; the next input connects again.
    func testAFailedConnectDropsTheQueuedInput() throws {
        var configuration = FakeSimulatorBridge.Configuration()
        configuration.surface = try makeSurface()
        configuration.failingConnects = 1
        let bridge = FakeSimulatorBridge(configuration)
        let session = makeSession(bridge)
        session.start()
        XCTAssertTrue(eventually { session.frames.current != nil })
        session.send(TouchCommand(phase: .down, x: 1, y: 1, id: 1))
        XCTAssertTrue(eventually { session.lastError != nil })
        XCTAssertEqual(session.lastError, "Simulator input: fake: dtuhidd did not answer")
        XCTAssertTrue(session.isRunning, "input errors do not stop the mirror")
        session.send(TouchCommand(phase: .down, x: 1, y: 1, id: 2))
        XCTAssertTrue(eventually { self.sentEvents(bridge).count == 1 })
    }

    // MARK: - Keyboard

    func testTextAndSpecialKeysAreTypedWithTheLayout() throws {
        let bridge = makeBridge(surface: try makeSurface())
        let session = makeSession(bridge, layout: .turkishQ)
        session.start()
        session.send(.text("iI"))
        session.send(.specialKey(51))
        session.send(.specialKey(122))  // F1: not forwarded
        let expected = SimulatorKeyStroke(usage: 0x34).events
            + SimulatorKeyStroke(usage: 0x0C, modifiers: [0xE1]).events
            + SimulatorKeyStroke(usage: 0x2A).events
        XCTAssertTrue(eventually { self.sentEvents(bridge).count == expected.count })
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(sentEvents(bridge), expected)
    }

    /// What the layout cannot type goes on the pasteboard, then ⌘V. Text
    /// that queued up behind a slow send coalesces into one paste: the first
    /// paste holds the input queue until both later texts are queued, so the
    /// batch does not depend on thread timing.
    func testTextWithoutAKeyIsPasted() throws {
        let bridge = makeBridge(surface: try makeSurface())
        let pasted = Locked<[String]>([])
        let released = Locked(false)
        defer { released.withLock { $0 = true } }  // never leave the input queue held
        let session = makeSession(bridge, layout: .usQWERTY) { text in
            pasted.withLock { $0.append(text) }
            while !released.withLock({ $0 }) {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        session.start()
        session.send(.text("ş"))
        XCTAssertTrue(eventually { pasted.withLock { $0.count } == 1 }, "the first paste holds the input queue")
        session.send(.text("aş"))
        session.send(.text("ğb"))
        released.withLock { $0 = true }
        let expected = SimulatorKeyboard.pasteStroke.events
            + SimulatorKeyStroke(usage: 0x04).events
            + SimulatorKeyboard.pasteStroke.events
            + SimulatorKeyStroke(usage: 0x05).events
        XCTAssertTrue(eventually { self.sentEvents(bridge).count == expected.count })
        XCTAssertEqual(sentEvents(bridge), expected)
        XCTAssertEqual(pasted.withLock { $0 }, ["ş", "şğ"], "the queued texts coalesce into one paste")
    }

    func testWithoutSimctlUntypeableTextIsAnError() throws {
        let bridge = makeBridge(surface: try makeSurface())
        let session = makeSession(bridge, layout: .usQWERTY)
        session.start()
        session.send(.text("ş"))
        XCTAssertTrue(eventually { session.lastError != nil })
        XCTAssertTrue(session.lastError?.contains("no simctl") == true, session.lastError ?? "")
    }

    /// Without a pasteboard only the untypeable run is dropped: the rest of
    /// the text is typed, and a finger held down meanwhile still lifts.
    func testAMissingPasteboardDropsOnlyItsText() throws {
        let bridge = makeBridge(surface: try makeSurface(width: 100, height: 200))
        let session = makeSession(bridge, layout: .usQWERTY)
        session.start()
        XCTAssertTrue(eventually { session.frames.current != nil })
        session.send(TouchCommand(phase: .down, x: 50, y: 100, id: 1))
        session.send(.text("şab"))
        session.send(TouchCommand(phase: .up, x: 50, y: 100, id: 1))
        let point = SimulatorFrameRotation.upright.nativeRatio(displayX: 50, displayY: 100, displayWidth: 100, displayHeight: 200)
        let expected = [SimulatorHIDEvent.touch(x: point.x, y: point.y, phase: .began)]
            + SimulatorKeyStroke(usage: 0x04).events
            + SimulatorKeyStroke(usage: 0x05).events
            + [.touch(x: point.x, y: point.y, phase: .ended)]
        XCTAssertTrue(eventually { self.sentEvents(bridge).count == expected.count })
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(sentEvents(bridge), expected)
        XCTAssertTrue(session.lastError?.contains("no simctl") == true, session.lastError ?? "")
        XCTAssertTrue(session.isRunning)
    }

    /// A failed `pbcopy` drops its run, without the ⌘V; the text around it
    /// is still typed.
    func testAFailedPasteboardWriteDropsOnlyItsText() throws {
        struct PasteboardWriteFailed: Error {}
        let bridge = makeBridge(surface: try makeSurface())
        let session = makeSession(bridge, layout: .usQWERTY) { _ in throw PasteboardWriteFailed() }
        session.start()
        session.send(.text("aşb"))
        let expected = SimulatorKeyStroke(usage: 0x04).events + SimulatorKeyStroke(usage: 0x05).events
        XCTAssertTrue(eventually { self.sentEvents(bridge).count == expected.count })
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(sentEvents(bridge), expected)
        XCTAssertTrue(session.lastError?.contains("PasteboardWriteFailed") == true, session.lastError ?? "")
    }

    /// Preferences that name no layout yet (a freshly created simulator has
    /// not written them) type U.S. for now, and are read again: the layout
    /// they name once written is used from then on.
    func testTheKeyboardLayoutIsReadAgainUntilThePreferencesNameOne() throws {
        let set = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimulatorMirrorSessionTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: set) }
        let bridge = makeBridge(surface: try makeSurface())
        let session = makeSession(bridge, layout: nil, deviceSet: set)
        session.start()
        session.send(.text("i"))
        let us = SimulatorKeyStroke(usage: 0x0C).events
        XCTAssertTrue(eventually { self.sentEvents(bridge) == us }, "U.S. while there are no preferences")

        let preferences = SimulatorKeyboard.globalPreferencesURL(udid: udid, deviceSet: set)
        try FileManager.default.createDirectory(at: preferences.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SimctlFixtureTests.data("bridge", "GlobalPreferences.tr_TR.plist").write(to: preferences)
        let retry = SimulatorMirrorSession.layoutRetryInterval.components
        Thread.sleep(forTimeInterval: Double(retry.seconds) + Double(retry.attoseconds) / 1e18 + 0.1)
        session.send(.text("i"))
        let turkish = SimulatorKeyStroke(usage: 0x34).events
        XCTAssertTrue(eventually { self.sentEvents(bridge) == us + turkish }, "Turkish Q once the preferences name it")
        session.send(.text("i"))
        XCTAssertTrue(eventually { self.sentEvents(bridge) == us + turkish + turkish })
    }
}

/// A value shared with escaping closures, behind a lock.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
