import XCTest
@testable import DeviceHubProKit

/// `SimulatorMirrorSession`'s hardware keys on `FakeSimulatorBridge`: the
/// frame's side buttons (`send(HardwareKeyEvent)`) and the Device menu's
/// presses go out as dtuhidd buttons on the session's own input channel, in
/// order with the touches, and only while it runs. The usages are the ones
/// `SimulatorHardwareActions` documents (Home 0x0C/0x40, side 0x0C/0x30,
/// volume 0x0C/0xE9 and 0xEA).
final class SimulatorMirrorSessionHardwareKeyTests: XCTestCase {
    private let udid = "00000000-0000-4000-8000-00000000A11B"

    private func makeSession(_ bridge: FakeSimulatorBridge) -> SimulatorMirrorSession {
        let session = SimulatorMirrorSession(
            udid: udid,
            deviceSet: URL(fileURLWithPath: "/tmp/SimulatorMirrorSessionHardwareKeyTests", isDirectory: true),
            bridge: bridge,
            minimumPublishInterval: .milliseconds(1),
            keyboardLayout: .usQWERTY
        )
        addTeardownBlock { session.stopAndWait() }
        return session
    }

    private func makeBridge() throws -> FakeSimulatorBridge {
        var configuration = FakeSimulatorBridge.Configuration()
        configuration.surface = SimulatorSurface(try SimulatorFrameCopierTests.makeSurface(width: 4, height: 8))
        configuration.properties = SimulatorScreenProperties(
            screenType: 0, screenID: 1, uiOrientation: 1, pixelWidth: 4, pixelHeight: 8
        )
        return FakeSimulatorBridge(configuration)
    }

    @discardableResult
    private func eventually(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition()
    }

    func testTheFrameButtonsMapToDtuhiddButtons() {
        XCTAssertEqual(SimulatorMirrorSession.button(for: .power), .side)
        XCTAssertEqual(SimulatorMirrorSession.button(for: .volumeUp), .volumeUp)
        XCTAssertEqual(SimulatorMirrorSession.button(for: .volumeDown), .volumeDown)
    }

    /// An Apple chrome button is a HID usage: the named usages map to their
    /// buttons, any other (the Action button, 0x0B/0x2D) is sent as it is.
    func testAHIDUsageNamesItsButton() {
        XCTAssertEqual(SimulatorHardwareButton(usagePage: 0x0C, usage: 0x30), .side)
        XCTAssertEqual(SimulatorHardwareButton(usagePage: 0x0C, usage: 0x40), .home)
        XCTAssertEqual(SimulatorHardwareButton(usagePage: 0x0C, usage: 0xE9), .volumeUp)
        XCTAssertEqual(SimulatorHardwareButton(usagePage: 0x0C, usage: 0xEA), .volumeDown)
        XCTAssertEqual(SimulatorHardwareButton(usagePage: 0x0C, usage: 0xCF), .siri)
        let action = SimulatorHardwareButton(usagePage: 0x0B, usage: 0x2D)
        XCTAssertEqual(action, .usage(page: 0x0B, usage: 0x2D))
        XCTAssertEqual(action.usagePage, 0x0B)
        XCTAssertEqual(action.usage, 0x2D)
    }

    /// A chrome button held by its usage: down and up on the session's one
    /// input channel, in order with the rest; nothing before the start.
    func testAChromeButtonSendsItsTwoEdges() throws {
        let bridge = try makeBridge()
        let session = makeSession(bridge)
        let action = SimulatorHardwareButton(usagePage: 0x0B, usage: 0x2D)
        session.send(button: action, isDown: true)
        session.start()
        XCTAssertTrue(eventually { session.frames.current != nil })

        session.send(button: action, isDown: true)
        session.send(button: action, isDown: false)
        session.send(button: .volumeDown, isDown: true)
        session.send(button: .volumeDown, isDown: false)

        XCTAssertTrue(eventually { bridge.inputs.first?.sent.count == 4 })
        XCTAssertEqual(bridge.inputs.first?.sent, [
            .button(action, isDown: true),
            .button(action, isDown: false),
            .button(.volumeDown, isDown: true),
            .button(.volumeDown, isDown: false),
        ])
        XCTAssertEqual(bridge.mainThreadCalls, 0)
    }

    /// A held side button: its down and its up, as separate events, on the
    /// session's one input channel.
    func testAHeldFrameButtonSendsItsTwoEdges() throws {
        let bridge = try makeBridge()
        let session = makeSession(bridge)
        XCTAssertTrue(session.supportsHardwareKeys)
        session.start()
        XCTAssertTrue(eventually { session.frames.current != nil })

        session.send(HardwareKeyEvent(key: .power, isDown: true))
        session.send(HardwareKeyEvent(key: .power, isDown: false))
        session.send(HardwareKeyEvent(key: .volumeUp, isDown: true))
        session.send(HardwareKeyEvent(key: .volumeUp, isDown: false))

        XCTAssertTrue(eventually { bridge.inputs.first?.sent.count == 4 })
        XCTAssertEqual(bridge.inputs.count, 1, "one input channel")
        XCTAssertEqual(bridge.inputs.first?.sent, [
            .button(.side, isDown: true),
            .button(.side, isDown: false),
            .button(.volumeUp, isDown: true),
            .button(.volumeUp, isDown: false),
        ])
        XCTAssertEqual(bridge.mainThreadCalls, 0, "no bridge call on the main thread")
    }

    /// Home from the menu: a press and its release, after the touch queued
    /// before it.
    func testAPressFollowsTheQueuedTouches() throws {
        let bridge = try makeBridge()
        let session = makeSession(bridge)
        session.start()
        XCTAssertTrue(eventually { session.frames.current != nil })

        session.send(TouchCommand(phase: .down, x: 2, y: 4))
        session.send(TouchCommand(phase: .up, x: 2, y: 4))
        session.press(.home, hold: .milliseconds(1))

        XCTAssertTrue(eventually { bridge.inputs.first?.sent.count == 4 })
        let sent = try XCTUnwrap(bridge.inputs.first?.sent)
        XCTAssertEqual(Array(sent.suffix(2)), [.button(.home, isDown: true), .button(.home, isDown: false)])
        // The tiny test frame puts every point at an edge: an edge touch.
        switch sent[0] {
        case .touch, .edgeTouch: break
        default: XCTFail("the touch first: \(sent)")
        }
    }

    /// A button held when the mirror is torn down: the teardown's up is
    /// queued and `stop()` clears the queue at once, so the session itself
    /// sends the up, exactly once, on the still-open channel (one connect),
    /// and waits for it to leave the process (a flush) before it
    /// disconnects.
    func testAButtonHeldAtStopGoesUpBeforeTheChannelCloses() throws {
        let bridge = try makeBridge()
        let session = makeSession(bridge)
        session.start()
        XCTAssertTrue(eventually { session.frames.current != nil })
        let action = SimulatorHardwareButton(usagePage: 0x0B, usage: 0x2D)
        session.send(button: action, isDown: true)
        session.send(HardwareKeyEvent(key: .power, isDown: true))
        XCTAssertTrue(eventually { bridge.inputs.first?.sent.count == 2 })
        let input = try XCTUnwrap(bridge.inputs.first)

        // `MirrorController.stopSession`: the releases, then the stop.
        session.send(button: action, isDown: false)
        session.send(HardwareKeyEvent(key: .power, isDown: false))
        session.stop()

        XCTAssertTrue(eventually { !input.isConnected && input.sent.count == 4 })
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(input.sent, [
            .button(action, isDown: true),
            .button(.side, isDown: true),
            .button(action, isDown: false),
            .button(.side, isDown: false),
        ])
        XCTAssertEqual(input.connectAttempts, 1, "the ups went out before the disconnect")
        XCTAssertEqual(input.flushes.last, FakeSimulatorInput.Flush(sentCount: 4, connected: true), "flushed after the ups")
        XCTAssertEqual(bridge.mainThreadCalls, 0)
    }

    /// A button already up owes nothing at the stop; a restart releases what
    /// the previous start held.
    func testOnlyAHeldButtonIsReleasedAtStop() throws {
        let bridge = try makeBridge()
        let session = makeSession(bridge)
        session.start()
        XCTAssertTrue(eventually { session.frames.current != nil })
        session.send(button: .volumeUp, isDown: true)
        session.send(button: .volumeUp, isDown: false)
        session.send(button: .volumeDown, isDown: true)
        XCTAssertTrue(eventually { bridge.inputs.first?.sent.count == 3 })

        session.start()
        XCTAssertTrue(eventually { bridge.inputs.first?.sent.count == 4 })
        session.stopAndWait()
        XCTAssertEqual(bridge.inputs.first?.sent, [
            .button(.volumeUp, isDown: true),
            .button(.volumeUp, isDown: false),
            .button(.volumeDown, isDown: true),
            .button(.volumeDown, isDown: false),
        ])
        XCTAssertEqual(bridge.inputs.count, 1, "the new start sent nothing")
    }

    /// A stopped session presses nothing and connects nothing.
    func testNothingIsPressedWhileStopped() throws {
        let bridge = try makeBridge()
        let session = makeSession(bridge)
        session.send(HardwareKeyEvent(key: .power, isDown: true))
        session.press(.home)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(bridge.inputs.isEmpty)
    }
}
