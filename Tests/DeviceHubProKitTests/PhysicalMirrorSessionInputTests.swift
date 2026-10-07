import Darwin
import Foundation
import XCTest
@testable import DeviceHubProKit

/// Wiring tests for the physical session's input path: the stage's `send`
/// frames must reach `adb shell input` as complete gestures/commands, and an
/// adb failure must land in `lastError` without tearing the stream down.
/// A stub adb logs its invocations; a socketpair stands in for the video
/// socket (no device needed).
final class PhysicalMirrorSessionInputTests: XCTestCase {
    func testTapIsSentAsOneInputTap() async throws {
        let stub = try StubAdb()
        let session = try await makeSession(stub: stub)

        session.send(TouchCommand(phase: .down, x: 10, y: 20))
        session.send(TouchCommand(phase: .up, x: 10, y: 20))

        let lines = await Self.waitForLog(stub, containing: "input tap 10 20")
        XCTAssertTrue(
            lines.contains { $0.contains("input tap 10 20") },
            "the tap must reach adb: \(lines)"
        )
        XCTAssertNil(session.lastError)
    }

    func testDragIsSentAsOneSwipeFromDownToUp() async throws {
        let stub = try StubAdb()
        let session = try await makeSession(stub: stub)

        session.send(TouchCommand(phase: .down, x: 100, y: 200))
        session.send(contacts: [TouchCommand(phase: .move, x: 100, y: 150)])
        session.send(contacts: [TouchCommand(phase: .up, x: 100, y: 60)])

        let lines = await Self.waitForLog(stub, containing: "input swipe 100 200 100 60")
        XCTAssertTrue(
            lines.contains { $0.contains("input swipe 100 200 100 60") },
            "the drag must become a single swipe: \(lines)"
        )
        XCTAssertNil(session.lastError)
    }

    func testMultiContactFramesAreDropped() async throws {
        let stub = try StubAdb()
        let session = try await makeSession(stub: stub)

        session.send(contacts: [
            TouchCommand(phase: .down, x: 100, y: 100, id: 1),
            TouchCommand(phase: .down, x: 150, y: 100, id: 2),
        ])
        session.send(contacts: [
            TouchCommand(phase: .up, x: 80, y: 100, id: 1),
            TouchCommand(phase: .up, x: 170, y: 100, id: 2),
        ])

        // A following single-finger tap still goes through, proving the
        // multi-touch release was swallowed and the tracker recovered.
        session.send(TouchCommand(phase: .down, x: 7, y: 8))
        session.send(TouchCommand(phase: .up, x: 7, y: 8))
        let lines = await Self.waitForLog(stub, containing: "input tap 7 8")
        XCTAssertTrue(lines.contains { $0.contains("input tap 7 8") }, "\(lines)")
        XCTAssertFalse(
            lines.contains { $0.contains("input swipe") },
            "the pinch must not become a swipe: \(lines)"
        )
    }

    func testTextIsSentEscaped() async throws {
        let stub = try StubAdb()
        let session = try await makeSession(stub: stub)

        session.send(KeyboardCommand.text("hello world"))

        let lines = await Self.waitForLog(stub, containing: "input text hello%sworld")
        XCTAssertTrue(
            lines.contains { $0.contains("input text hello%sworld") },
            "the text must reach adb with input's space placeholder: \(lines)"
        )
        XCTAssertNil(session.lastError)
    }

    func testSpecialKeyIsSentAsKeyevent() async throws {
        let stub = try StubAdb()
        let session = try await makeSession(stub: stub)

        session.send(KeyboardCommand.specialKey(51))

        let lines = await Self.waitForLog(stub, containing: "input keyevent 67")
        XCTAssertTrue(
            lines.contains { $0.contains("input keyevent 67") },
            "delete must map to KEYCODE_DEL: \(lines)"
        )
        XCTAssertNil(session.lastError)
    }

    /// The duration replayed for a long-press/swipe must come from when the
    /// event was yielded, not from when the consumer got to it: buffered
    /// frames would otherwise compress to an instant and read as a tap.
    func testGestureDurationIsSampledWhenTheEventIsSent() async throws {
        let stub = try StubAdb(inputDelay: 0.8)
        let session = try await makeSession(stub: stub)

        // Occupy the consumer so the gesture frames below stay buffered.
        session.send(KeyboardCommand.specialKey(51))
        try await Task.sleep(for: .milliseconds(100))
        session.send(TouchCommand(phase: .down, x: 100, y: 200))
        try await Task.sleep(for: .milliseconds(700))
        session.send(TouchCommand(phase: .up, x: 100, y: 200))

        let lines = await Self.waitForLog(stub, containing: "input swipe")
        XCTAssertTrue(
            lines.contains { $0.contains("input swipe 100 200 100 200") },
            "a still frame held 700 ms must replay as a long-press swipe: \(lines)"
        )
        XCTAssertFalse(
            lines.contains { $0.contains("input tap 100 200") },
            "the buffered hold must not collapse to a tap: \(lines)"
        )
        let swipe = try XCTUnwrap(lines.first { $0.contains("input swipe") })
        let duration = try XCTUnwrap(Int(swipe.split(separator: " ").last ?? ""))
        XCTAssertGreaterThanOrEqual(
            duration, 500,
            "the replayed duration must come from the yield times: \(swipe)"
        )
    }

    /// `stop()` finishes the input stream, but `AsyncStream` still delivers
    /// already-buffered elements; the consumer must refuse them rather than
    /// inject a gesture into a device it no longer owns. The injected runner
    /// records its invocations, so the assertion does not depend on a
    /// freshly-launched adb child surviving SIGTERM long enough to log — the
    /// timing that let this case pass before the fix.
    func testBufferedGesturesAreNotInjectedAfterStop() async throws {
        let stub = try StubAdb(ignoresTERM: true)
        let client = stub.client
        let recorder = InputCallRecorder()
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        let session = try await makeSession(stub: stub) { arguments in
            await recorder.record(arguments)
            if arguments.contains("keyevent") {
                for await _ in gate { break }
            }
            try await client.run(arguments)
        }

        // Hold the consumer inside the first command, then queue a gesture
        // and stop before it can run.
        session.send(KeyboardCommand.specialKey(51))
        _ = await Self.waitForCalls(recorder, containing: "keyevent")
        session.send(TouchCommand(phase: .down, x: 10, y: 20))
        session.send(TouchCommand(phase: .up, x: 10, y: 20))
        session.stop()
        gateContinuation.yield()
        gateContinuation.finish()

        // Releasing the in-flight command gives the consumer its chance to
        // reach the buffered gesture.
        try await Task.sleep(for: .milliseconds(500))
        let calls = await recorder.calls
        XCTAssertFalse(
            calls.contains { $0.contains("tap") || $0.contains("swipe") },
            "a gesture buffered before stop() must not be injected: \(calls)"
        )
        XCTAssertTrue(
            calls.contains { $0.contains("keyevent") },
            "the in-flight command must still have run: \(calls)"
        )
    }

    func testInputFailureSetsLastErrorWithoutStoppingTheSession() async throws {
        let stub = try StubAdb(failInput: true)
        let session = try await makeSession(stub: stub)

        session.send(TouchCommand(phase: .down, x: 10, y: 20))
        session.send(TouchCommand(phase: .up, x: 10, y: 20))

        let error = await Self.waitForError(on: session)
        XCTAssertNotNil(error, "the failed adb invocation must be surfaced")
        XCTAssertTrue(error?.contains("input") == true, "\(error ?? "nil")")

        // Non-fatal: the session must not tear down its tunnel (no forward
        // removal) in response to an input failure.
        let lines = stub.lines
        XCTAssertFalse(
            lines.contains { $0.contains("forward") && $0.contains("--remove") },
            "an input failure must not stop the stream: \(lines)"
        )
    }

    func testInputIsDroppedWhenNoAdbClientIsInjected() async throws {
        let stub = try StubAdb()
        let (video, peer) = try Self.socketPair()
        let connection = ScrcpyServerConnection(
            port: 4501,
            videoHandle: video,
            adb: stub.client,
            serial: "stub-serial",
            process: Process(),
            scid: 0x0000_4501
        )
        let session = PhysicalMirrorSession(serial: "stub-serial") { connection }
        defer { session.stop() }

        session.start()
        try await Task.sleep(for: .milliseconds(100))
        session.send(TouchCommand(phase: .down, x: 1, y: 1))
        session.send(TouchCommand(phase: .up, x: 1, y: 1))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(session.lastError)
        XCTAssertFalse(
            stub.lines.contains { $0.contains("input") },
            "input must be dropped when no adb client is injected: \(stub.lines)"
        )
        _ = peer
    }

    // MARK: - Fallback: coalescing, scaling, timeout

    /// Each `adb shell input` costs an adb spawn plus a device-side JVM; a
    /// burst of keystrokes that queued up behind a slow invocation must go
    /// out as one `input text`, not one invocation per character.
    func testTypingBurstIsSentAsOneInputText() async throws {
        let stub = try StubAdb(inputDelay: 0.6)
        let session = try await makeSession(stub: stub)

        session.send(KeyboardCommand.specialKey(51))
        try await Task.sleep(for: .milliseconds(150))
        for character in ["a", "b", "c"] {
            session.send(KeyboardCommand.text(character))
        }

        let lines = await Self.waitForLog(stub, containing: "input text")
        try await Task.sleep(for: .milliseconds(900))
        let texts = stub.lines.filter { $0.contains("input text") }
        XCTAssertEqual(texts.count, 1, "the burst must be one invocation: \(stub.lines)")
        XCTAssertTrue(texts.first?.hasSuffix("input text abc") == true, "\(lines)")
    }

    /// `input tap` takes display pixels, but the server may stream a smaller
    /// picture (here a 1440x3200 display sent as 864x1920 after its encoder
    /// downsized): the centre of the mirror must land on the centre of the
    /// screen.
    func testFallbackGesturesAreScaledFromVideoToDisplayPixels() async throws {
        let stub = try StubAdb()
        let session = try await makeSession(stub: stub, displaySize: (1440, 3200))
        session.frames.put(Frame(data: Data(), width: 864, height: 1920, seq: 1))

        session.send(TouchCommand(phase: .down, x: 432, y: 960))
        session.send(TouchCommand(phase: .up, x: 432, y: 960))

        let lines = await Self.waitForLog(stub, containing: "input tap")
        XCTAssertTrue(
            lines.contains { $0.hasSuffix("input tap 720 1600") },
            "the frame centre must map to the display centre: \(lines)"
        )
    }

    /// One hung `adb shell input` (a wireless link that stops answering) used
    /// to block every later event until the mirror was restarted.
    func testAStalledInputInvocationTimesOutAndLaterInputStillRuns() async throws {
        let stub = try StubAdb(hangFirstInput: true)
        let session = try await makeSession(stub: stub, inputCommandTimeout: .milliseconds(500))

        session.send(KeyboardCommand.specialKey(51))
        try await Task.sleep(for: .milliseconds(100))
        session.send(TouchCommand(phase: .down, x: 5, y: 6))
        session.send(TouchCommand(phase: .up, x: 5, y: 6))

        let started = Date()
        let lines = await Self.waitForLog(stub, containing: "input tap 5 6", timeout: 4)
        XCTAssertTrue(lines.contains { $0.contains("input tap 5 6") }, "\(lines)")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the hung call must not hold the queue")
        let error = await Self.waitForError(on: session)
        XCTAssertTrue(error?.contains("did not finish") == true, "\(error ?? "nil")")
        XCTAssertTrue(session.isRunning, "an input timeout is not fatal")
    }

    // MARK: - Control socket

    /// With a control socket, a touch streams as it happens: one
    /// INJECT_TOUCH_EVENT per contact, in video coordinates with the video
    /// size (the server maps them to the display), and no `adb shell input`.
    func testTouchesTravelOverTheControlSocketInVideoCoordinates() async throws {
        let stub = try StubAdb()
        let (session, control) = try await makeControlSession(stub: stub)

        session.send(TouchCommand(phase: .down, x: 100, y: 200))
        session.send(TouchCommand(phase: .move, x: 110, y: 5_000))
        session.send(TouchCommand(phase: .up, x: 110, y: 2_399))

        let bytes = try Self.read(control, count: 96)
        let expected = [
            ScrcpyControlMessage.injectTouch(
                action: .down, pointerID: 0,
                position: ScrcpyPosition(x: 100, y: 200, screenWidth: 1080, screenHeight: 2400),
                pressure: 1
            ),
            .injectTouch(
                action: .move, pointerID: 0,
                position: ScrcpyPosition(x: 110, y: 2_399, screenWidth: 1080, screenHeight: 2400),
                pressure: 1
            ),
            .injectTouch(
                action: .up, pointerID: 0,
                position: ScrcpyPosition(x: 110, y: 2_399, screenWidth: 1080, screenHeight: 2400),
                pressure: 0
            ),
        ].flatMap { [UInt8]($0.serialized) }
        XCTAssertEqual(bytes, expected)
        XCTAssertTrue(session.usesControlSocket)
        XCTAssertFalse(stub.lines.contains { $0.contains(" input ") }, "\(stub.lines)")
    }

    /// A release (or move) for a pointer that never went down would reach
    /// Android as an inconsistent event stream; only the complete touch that
    /// follows goes out.
    func testStrayReleasesNeverReachTheControlSocket() async throws {
        let stub = try StubAdb()
        let (session, control) = try await makeControlSession(stub: stub)

        session.send(TouchCommand(phase: .move, x: 1, y: 1))
        session.send(TouchCommand(phase: .up, x: 1, y: 1))
        session.send(TouchCommand(phase: .down, x: 20, y: 30))

        let bytes = try Self.read(control, count: 32)
        XCTAssertEqual(bytes[1], 0x00, "the first message must be the down")
        XCTAssertEqual(Array(bytes[10..<18]), [0, 0, 0, 20, 0, 0, 0, 30])
    }

    /// Multi-touch has no `adb shell input` form; over the control socket
    /// each contact keeps its own pointer, so a pinch is a real pinch.
    func testMultiContactFramesBecomeOnePointerPerContact() async throws {
        let stub = try StubAdb()
        let (session, control) = try await makeControlSession(stub: stub)

        session.send(contacts: [
            TouchCommand(phase: .down, x: 400, y: 1_000, id: 1),
            TouchCommand(phase: .down, x: 600, y: 1_000, id: 2),
        ])

        let bytes = try Self.read(control, count: 64)
        XCTAssertEqual(Array(bytes[2..<10]), [0, 0, 0, 0, 0, 0, 0, 1], "first pointer id")
        XCTAssertEqual(Array(bytes[34..<42]), [0, 0, 0, 0, 0, 0, 0, 2], "second pointer id")
        XCTAssertEqual(bytes[1], 0x00)
        XCTAssertEqual(bytes[33], 0x00)
    }

    func testKeyboardTravelsOverTheControlSocket() async throws {
        let stub = try StubAdb()
        let (session, control) = try await makeControlSession(stub: stub)

        session.send(KeyboardCommand.specialKey(36))   // return
        XCTAssertEqual(
            try Self.read(control, count: 28),
            [UInt8](ScrcpyControlMessage.injectKeycode(action: .down, keycode: 66).serialized)
                + [UInt8](ScrcpyControlMessage.injectKeycode(action: .up, keycode: 66).serialized)
        )

        session.send(KeyboardCommand.text("hi there"))
        XCTAssertEqual(
            try Self.read(control, count: 13),
            [UInt8](ScrcpyControlMessage.injectText("hi there").serialized)
        )

        // The server types INJECT_TEXT through the virtual key map, which
        // drops Turkish letters; those are pasted instead, with a sequence
        // so the paste can be acknowledged.
        session.send(KeyboardCommand.text("ş"))
        let paste = [UInt8](ScrcpyControlMessage.setClipboard(sequence: 1, paste: true, text: "ş").serialized)
        XCTAssertEqual(try Self.read(control, count: paste.count), paste)
        XCTAssertFalse(stub.lines.contains { $0.contains(" input ") }, "\(stub.lines)")
    }

    /// The server injects KEYCODE_PASTE asynchronously and the app reads the
    /// clipboard only when it handles the key. A SET_CLIPBOARD sent right
    /// behind a paste could replace the text first, so typing "ışık" could
    /// insert "şşık". The next paste must wait for the previous one's ACK,
    /// and keystrokes typed meanwhile go out together as one paste.
    func testAPasteWaitsForThePreviousPastesAcknowledgement() async throws {
        let stub = try StubAdb()
        let (session, control) = try await makeControlSession(
            stub: stub,
            pasteAcknowledgementTimeout: .seconds(30)
        )

        session.send(KeyboardCommand.text("ı"))
        let first = [UInt8](ScrcpyControlMessage.setClipboard(sequence: 1, paste: true, text: "ı").serialized)
        XCTAssertEqual(try Self.read(control, count: first.count), first)

        session.send(KeyboardCommand.text("ş"))
        session.send(KeyboardCommand.text("ı"))
        session.send(KeyboardCommand.text("k"))
        XCTAssertFalse(
            Self.hasBytes(control, within: 0.4),
            "nothing may follow a paste before the device acknowledged it"
        )

        try control.write(contentsOf: Self.clipboardAcknowledgement(sequence: 1))
        let second = [UInt8](ScrcpyControlMessage.setClipboard(sequence: 2, paste: true, text: "şık").serialized)
        XCTAssertEqual(try Self.read(control, count: second.count), second)
        XCTAssertNil(session.lastError)
    }

    /// A server that never acknowledges must not freeze input: once the
    /// bound passes, what is queued behind the paste goes out.
    func testAnUnacknowledgedPasteReleasesTheInputBehindItAfterItsBound() async throws {
        let stub = try StubAdb()
        let (session, control) = try await makeControlSession(
            stub: stub,
            pasteAcknowledgementTimeout: .milliseconds(300)
        )

        session.send(KeyboardCommand.text("ğ"))
        let paste = [UInt8](ScrcpyControlMessage.setClipboard(sequence: 1, paste: true, text: "ğ").serialized)
        XCTAssertEqual(try Self.read(control, count: paste.count), paste)

        session.send(KeyboardCommand.specialKey(36))   // return
        let enter = [UInt8](ScrcpyControlMessage.injectKeycode(action: .down, keycode: 66).serialized)
            + [UInt8](ScrcpyControlMessage.injectKeycode(action: .up, keycode: 66).serialized)
        XCTAssertEqual(try Self.read(control, count: enter.count, timeout: 3), enter)
    }

    /// Home and Recents (the stage's navigation bar) go out as a key down
    /// and up of Android's key code, no adb process.
    func testNavigationKeysTravelOverTheControlSocket() async throws {
        let stub = try StubAdb()
        let (session, control) = try await makeControlSession(stub: stub)

        session.sendNavigationKey(.home)
        let home = [UInt8](ScrcpyControlMessage.injectKeycode(action: .down, keycode: 3).serialized)
            + [UInt8](ScrcpyControlMessage.injectKeycode(action: .up, keycode: 3).serialized)
        XCTAssertEqual(try Self.read(control, count: home.count), home)

        session.sendNavigationKey(.recents)
        let recents = [UInt8](ScrcpyControlMessage.injectKeycode(action: .down, keycode: 187).serialized)
            + [UInt8](ScrcpyControlMessage.injectKeycode(action: .up, keycode: 187).serialized)
        XCTAssertEqual(try Self.read(control, count: recents.count), recents)
    }

    func testBackScrollAndClipboardTravelOverTheControlSocket() async throws {
        let stub = try StubAdb()
        let (session, control) = try await makeControlSession(stub: stub)

        session.sendBackOrScreenOn()
        XCTAssertEqual(try Self.read(control, count: 4), [0x04, 0x00, 0x04, 0x01])

        session.sendScroll(x: 540, y: 1_200, horizontal: 0, vertical: -1)
        XCTAssertEqual(
            try Self.read(control, count: 21),
            [UInt8](ScrcpyControlMessage.injectScroll(
                position: ScrcpyPosition(x: 540, y: 1_200, screenWidth: 1080, screenHeight: 2400),
                horizontal: 0,
                vertical: -1
            ).serialized)
        )

        session.setDeviceClipboard("copied")
        let expected = [UInt8](ScrcpyControlMessage.setClipboard(sequence: 0, paste: false, text: "copied").serialized)
        XCTAssertEqual(try Self.read(control, count: expected.count), expected)
    }

    /// The server pushes the device clipboard unprompted; the session must
    /// read (drain) the control socket and hand the text over.
    func testDeviceClipboardMessagesReachTheObserver() async throws {
        let stub = try StubAdb()
        let (session, control) = try await makeControlSession(stub: stub)
        let received = ClipboardRecorder()
        session.onDeviceClipboard = { received.record($0) }

        try control.write(contentsOf: Data([0x00, 0x00, 0x00, 0x00, 0x05]) + Data("çağ".utf8))

        let deadline = Date().addingTimeInterval(3)
        while received.texts.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(received.texts, ["çağ"])
    }

    /// A control socket that fails (the server's controller died) must not
    /// swallow input for the rest of the session: later events fall back to
    /// `adb shell input`.
    func testAFailedControlSocketFallsBackToAdbInput() async throws {
        let stub = try StubAdb()
        let (session, control) = try await makeControlSession(stub: stub)
        try control.close()

        session.send(KeyboardCommand.specialKey(51))
        let deadline = Date().addingTimeInterval(3)
        while session.usesControlSocket, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(session.usesControlSocket)

        session.send(TouchCommand(phase: .down, x: 7, y: 8))
        session.send(TouchCommand(phase: .up, x: 7, y: 8))
        let lines = await Self.waitForLog(stub, containing: "input tap 7 8")
        XCTAssertTrue(lines.contains { $0.contains("input tap 7 8") }, "\(lines)")
    }

    // MARK: - Helpers

    /// A session whose video socket is one end of a socketpair (kept open by
    /// the caller for the test's duration) and whose input goes to `stub`,
    /// unless `inputRunner` overrides how an invocation runs.
    private func makeSession(
        stub: StubAdb,
        inputRunner: (@Sendable ([String]) async throws -> Void)? = nil,
        displaySize: (width: Int, height: Int)? = nil,
        inputCommandTimeout: Duration = PhysicalMirrorSession.defaultInputCommandTimeout
    ) async throws -> PhysicalMirrorSession {
        let (video, peer) = try Self.socketPair()
        let connection = ScrcpyServerConnection(
            port: 4500,
            videoHandle: video,
            adb: stub.client,
            serial: "stub-serial",
            process: Process(),
            scid: 0x0000_4500
        )
        var provider: (@Sendable () async -> (width: Int, height: Int)?)?
        if let displaySize {
            let width = displaySize.width
            let height = displaySize.height
            provider = { @Sendable in (width, height) }
        }
        let session = PhysicalMirrorSession(
            serial: "stub-serial",
            adb: stub.client,
            headerTimeout: 60,
            firstFrameTimeout: 60,
            inputCommandTimeout: inputCommandTimeout,
            inputRunner: inputRunner,
            displaySizeProvider: provider
        ) {
            connection
        }
        addTeardownBlock {
            session.stop()
            try? peer.close()
        }
        session.start()
        try await Task.sleep(for: .milliseconds(100))
        return session
    }

    /// A session whose connection carries a control socket (the returned
    /// peer end reads what the session writes) and a 1080x2400 frame.
    private func makeControlSession(
        stub: StubAdb,
        pasteAcknowledgementTimeout: Duration = PhysicalMirrorSession.defaultPasteAcknowledgementTimeout
    ) async throws -> (PhysicalMirrorSession, FileHandle) {
        let (video, videoPeer) = try Self.socketPair()
        let (control, controlPeer) = try Self.socketPair()
        let connection = ScrcpyServerConnection(
            port: 4510,
            videoHandle: video,
            controlHandle: control,
            adb: stub.client,
            serial: "stub-serial",
            process: Process(),
            scid: 0x0000_4510
        )
        let session = PhysicalMirrorSession(
            serial: "stub-serial",
            adb: stub.client,
            headerTimeout: 60,
            firstFrameTimeout: 60,
            pasteAcknowledgementTimeout: pasteAcknowledgementTimeout
        ) {
            connection
        }
        session.frames.put(Frame(data: Data(), width: 1080, height: 2400, seq: 1))
        addTeardownBlock {
            session.stop()
            try? videoPeer.close()
            try? controlPeer.close()
        }
        session.start()
        let deadline = Date().addingTimeInterval(3)
        while !session.usesControlSocket, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(session.usesControlSocket, "the connection's control socket must be in use")
        return (session, controlPeer)
    }

    /// Reads exactly `count` bytes from `handle`, or fails after `timeout`.
    private static func read(
        _ handle: FileHandle,
        count: Int,
        timeout: TimeInterval = 3
    ) throws -> [UInt8] {
        let descriptor = handle.fileDescriptor
        let deadline = Date().addingTimeInterval(timeout)
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while bytes.count < count {
            let remaining = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard remaining > 0, poll(&descriptorState, 1, remaining) > 0 else {
                XCTFail("timed out with \(bytes.count) of \(count) bytes: \(bytes)")
                return bytes
            }
            let wanted = min(buffer.count, count - bytes.count)
            let received = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, wanted)
            }
            guard received > 0 else {
                XCTFail("the socket closed after \(bytes.count) of \(count) bytes")
                return bytes
            }
            bytes.append(contentsOf: buffer[0..<received])
        }
        return bytes
    }

    /// True when `handle` becomes readable within `seconds`.
    private static func hasBytes(_ handle: FileHandle, within seconds: TimeInterval) -> Bool {
        var descriptorState = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
        return poll(&descriptorState, 1, Int32(seconds * 1000)) > 0
    }

    /// The ACK_CLIPBOARD device message for `sequence`.
    private static func clipboardAcknowledgement(sequence: UInt64) -> Data {
        var bytes = Data([ScrcpyControl.deviceTypeAckClipboard])
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: sequence >> UInt64(shift)))
        }
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

    private static func waitForLog(
        _ stub: StubAdb,
        containing needle: String,
        timeout: TimeInterval = 3
    ) async -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let lines = stub.lines
            if lines.contains(where: { $0.contains(needle) }) { return lines }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return stub.lines
    }

    private static func waitForError(
        on session: PhysicalMirrorSession,
        timeout: TimeInterval = 3
    ) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let error = session.lastError { return error }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return session.lastError
    }

    private static func waitForCalls(
        _ recorder: InputCallRecorder,
        containing needle: String,
        timeout: TimeInterval = 3
    ) async -> [[String]] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let calls = await recorder.calls
            if calls.contains(where: { $0.contains(needle) }) { return calls }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await recorder.calls
    }
}

private final class ClipboardRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ text: String) {
        lock.lock()
        storage.append(text)
        lock.unlock()
    }

    var texts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Records the argv of every input invocation the consumer runs.
private actor InputCallRecorder {
    private(set) var calls: [[String]] = []

    func record(_ arguments: [String]) {
        calls.append(arguments)
    }
}

/// A fake `adb` executable that appends its argv to a log file. When
/// `failInput` is set, `input` invocations exit non-zero with a stderr line;
/// `inputDelay` makes input invocations slow; `hangFirstInput` makes the
/// first input invocation hang for 5 s; `ignoresTERM` keeps the child alive
/// through the runner's SIGTERM so tests can observe work that the session
/// should not have started after `stop()`.
private final class StubAdb {
    let client: AdbClient
    private let directory: URL
    private let logURL: URL

    init(
        failInput: Bool = false,
        inputDelay: TimeInterval = 0,
        hangFirstInput: Bool = false,
        ignoresTERM: Bool = false
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicehubpro-input-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        logURL = directory.appendingPathComponent("calls.log")
        if failInput {
            FileManager.default.createFile(
                atPath: directory.appendingPathComponent("fail-input").path,
                contents: nil
            )
        }
        let scriptURL = directory.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        \(ignoresTERM ? "trap '' TERM" : "")
        printf '%s\\n' "$*" >> "\(logURL.path)"
        case " $* " in
          *" input "*) if [ -f "\(directory.path)/fail-input" ]; then
            echo "input injection failed" >&2
            exit 1
          fi
          \(hangFirstInput ? "if [ ! -f \"\(directory.path)/hung\" ]; then touch \"\(directory.path)/hung\"; exec sleep 5; fi" : "")
          \(inputDelay > 0 ? "sleep \(inputDelay)" : "") ;;
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
