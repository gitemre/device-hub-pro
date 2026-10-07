import XCTest
import GRPCCore
@testable import DeviceHubProKit

/// The hardware-key queue's rules (`HardwareKeyInjector`), its `sendKey`
/// request and its place in `MirrorSession`. No emulator: the sends go to a
/// recording fake, and the retry test leases connections to port 1, which
/// is closed (no RPC is ever made there).
///
/// The key codes are SOURCE-DERIVED: Android's from AOSP
/// `frameworks/base/core/java/android/view/KeyEvent.java`, the evdev codes
/// from Linux `include/uapi/linux/input-event-codes.h`.
final class HardwareKeyInjectorTests: XCTestCase {
    private static let powerDown = HardwareKeyEvent(key: .power, isDown: true)
    private static let powerUp = HardwareKeyEvent(key: .power, isDown: false)
    private static let volumeUpDown = HardwareKeyEvent(key: .volumeUp, isDown: true)
    private static let volumeUpUp = HardwareKeyEvent(key: .volumeUp, isDown: false)
    private static let volumeDownDown = HardwareKeyEvent(key: .volumeDown, isDown: true)
    private static let volumeDownUp = HardwareKeyEvent(key: .volumeDown, isDown: false)

    /// A sender that records every event it was asked to send, fails the
    /// events the test marks, and can hold a send until the test opens its
    /// gate.
    private final class FakeSender: @unchecked Sendable {
        struct Failure: Error, CustomStringConvertible {
            var description: String { "the emulator refused" }
        }

        private let lock = NSLock()
        private var _sent: [HardwareKeyEvent] = []
        private var _failing: Set<HardwareKeyEvent> = []
        private var _inFlight = 0
        private var _mostInFlight = 0
        private var _held: Set<HardwareKeyEvent> = []
        private var waiters: [CheckedContinuation<Void, Never>] = []

        var sent: [HardwareKeyEvent] { lock.withLock { _sent } }
        var mostInFlight: Int { lock.withLock { _mostInFlight } }

        /// Sends of `event` throw.
        func fail(_ event: HardwareKeyEvent) {
            lock.withLock { _ = _failing.insert(event) }
        }

        /// Sends of `event` wait until `open()`.
        func hold(_ event: HardwareKeyEvent) {
            lock.withLock { _ = _held.insert(event) }
        }

        func open() {
            let pending = lock.withLock {
                _held = []
                defer { waiters = [] }
                return waiters
            }
            pending.forEach { $0.resume() }
        }

        var sender: HardwareKeySender {
            HardwareKeySender { event in
                let (fails, waits) = self.lock.withLock {
                    self._sent.append(event)
                    self._inFlight += 1
                    self._mostInFlight = max(self._mostInFlight, self._inFlight)
                    return (self._failing.contains(event), self._held.contains(event))
                }
                if waits {
                    await withCheckedContinuation { continuation in
                        let resumeNow = self.lock.withLock {
                            guard self._held.contains(event) else { return true }
                            self.waiters.append(continuation)
                            return false
                        }
                        if resumeNow { continuation.resume() }
                    }
                }
                self.lock.withLock { self._inFlight -= 1 }
                if fails { throw Failure() }
            }
        }
    }

    /// Collects `reportError` messages.
    private final class Errors: @unchecked Sendable {
        private let lock = NSLock()
        private var _messages: [String] = []
        var messages: [String] { lock.withLock { _messages } }
        func append(_ message: String) { lock.withLock { _messages.append(message) } }
    }

    /// Feeds `events` to an injector over `fake`, then ends the stream (the
    /// way `MirrorSession.stop()` does when `stops`) and waits for it.
    private func run(
        _ events: [HardwareKeyEvent],
        fake: FakeSender,
        stopSignal: KeyboardInjector.StopSignal = KeyboardInjector.StopSignal(),
        errors: Errors = Errors()
    ) async {
        let (stream, continuation) = AsyncStream<HardwareKeyEvent>.makeStream()
        let injector = Task {
            await HardwareKeyInjector.run(
                events: stream,
                stopSignal: stopSignal,
                sender: fake.sender,
                reportError: { errors.append($0) }
            )
        }
        events.forEach { continuation.yield($0) }
        continuation.finish()
        await injector.value
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: - Codes and the request

    func testTheKeysCarryAndroidsAndLinuxsCodes() {
        XCTAssertEqual(HardwareKey.allCases, [.power, .volumeUp, .volumeDown])
        XCTAssertEqual(HardwareKey.allCases.map(\.androidKeyCode), [26, 24, 25])
        XCTAssertEqual(HardwareKey.allCases.map(\.evdevCode), [116, 115, 114])
    }

    /// `sendKey` with the evdev code: a press is a keydown, a release a
    /// keyup, never a keypress (which would release at once).
    func testTheRequestIsAnEvdevKeyDownOrUp() {
        let down = HardwareKeySender.keyboardEvent(for: Self.powerDown)
        XCTAssertEqual(down.codeType, .evdev)
        XCTAssertEqual(down.eventType, .keydown)
        XCTAssertEqual(down.keyCode, 116)
        XCTAssertEqual(down.key, "")
        XCTAssertEqual(down.text, "")

        let up = HardwareKeySender.keyboardEvent(for: Self.powerUp)
        XCTAssertEqual(up.codeType, .evdev)
        XCTAssertEqual(up.eventType, .keyup)
        XCTAssertEqual(up.keyCode, 116)

        XCTAssertEqual(HardwareKeySender.keyboardEvent(for: Self.volumeUpDown).keyCode, 115)
        XCTAssertEqual(HardwareKeySender.keyboardEvent(for: Self.volumeDownUp).keyCode, 114)
    }

    // MARK: - The rules

    /// Rule 1: a second press of a held key sends nothing.
    func testAPressOfAKeyAlreadyHeldIsIgnored() async {
        let fake = FakeSender()
        await run([Self.powerDown, Self.powerDown, Self.powerUp], fake: fake)
        XCTAssertEqual(fake.sent, [Self.powerDown, Self.powerUp])
    }

    /// Rule 2: once stopped, a press is neither sent nor held (so nothing is
    /// released for it either), while a release still goes out.
    func testAPressAfterTheStopIsDropped() async {
        let fake = FakeSender()
        let (stream, continuation) = AsyncStream<HardwareKeyEvent>.makeStream()
        let stopSignal = KeyboardInjector.StopSignal()
        let injector = Task {
            await HardwareKeyInjector.run(
                events: stream,
                stopSignal: stopSignal,
                sender: fake.sender,
                reportError: { _ in }
            )
        }
        continuation.yield(Self.powerDown)
        let pressed = await waitUntil { fake.sent == [Self.powerDown] }
        XCTAssertTrue(pressed)

        stopSignal.stop()
        continuation.yield(Self.volumeUpDown)
        continuation.yield(Self.powerUp)
        continuation.finish()
        await injector.value

        XCTAssertEqual(fake.sent, [Self.powerDown, Self.powerUp])
    }

    /// Rule 3: a press that failed may still have reached the guest, so the
    /// key counts as held and its release follows.
    func testAFailedPressIsStillReleased() async {
        let fake = FakeSender()
        fake.fail(Self.powerDown)
        let errors = Errors()
        await run([Self.powerDown, Self.powerUp], fake: fake, errors: errors)
        XCTAssertEqual(fake.sent, [Self.powerDown, Self.powerUp])
        XCTAssertEqual(errors.messages, ["hardware key: the emulator refused"])

        let unreleased = FakeSender()
        unreleased.fail(Self.volumeDownDown)
        await run([Self.volumeDownDown], fake: unreleased)
        XCTAssertEqual(unreleased.sent, [Self.volumeDownDown, Self.volumeDownUp], "released when the stream ends")
    }

    /// Rule 4: a release of a key that is not down sends nothing.
    func testAReleaseOfAKeyNotHeldIsIgnored() async {
        let fake = FakeSender()
        await run([Self.volumeUpUp, Self.powerDown, Self.powerUp, Self.powerUp], fake: fake)
        XCTAssertEqual(fake.sent, [Self.powerDown, Self.powerUp])
    }

    /// Rule 5: a failed release is not retried by the queue and leaves the
    /// key released; the stream's end releases nothing more.
    func testAFailedReleaseLeavesTheKeyReleased() async {
        let fake = FakeSender()
        fake.fail(Self.powerUp)
        let errors = Errors()
        await run([Self.powerDown, Self.powerUp, Self.powerUp], fake: fake, errors: errors)
        XCTAssertEqual(fake.sent, [Self.powerDown, Self.powerUp])
        XCTAssertEqual(errors.messages, ["hardware key: the emulator refused"])
    }

    /// Rule 5, the sender's side: on a stale shared connection a release is
    /// sent once more on a fresh one, a press never is (a second power
    /// press would put the screen back to sleep).
    func testOnlyAReleaseIsRetriedOnAStaleConnection() async throws {
        let pool = EmulatorConnectionPool()
        let port = 1
        final class Calls: @unchecked Sendable {
            private let lock = NSLock()
            private var _requests: [Android_Emulation_Control_KeyboardEvent] = []
            var requests: [Android_Emulation_Control_KeyboardEvent] { lock.withLock { _requests } }
            /// Records the call; true for the first call of each event.
            func record(_ request: Android_Emulation_Control_KeyboardEvent) -> Bool {
                lock.withLock {
                    _requests.append(request)
                    return _requests.filter { $0 == request }.count == 1
                }
            }
        }
        let calls = Calls()
        let sender = HardwareKeySender.grpc(port: port, pool: pool) { _, request in
            if calls.record(request) {
                throw RPCError(code: .unavailable, message: "connection reset")
            }
        }

        // Warm the connection so each send runs on a reused one.
        _ = try await EmulatorControl.withSharedClient(port: port, pool: pool) { _ in 0 }
        do {
            try await sender.send(Self.powerDown)
            XCTFail("a press on a stale connection must fail, not rerun")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .unavailable)
        }
        XCTAssertEqual(calls.requests.map(\.eventType), [.keydown])

        _ = try await EmulatorControl.withSharedClient(port: port, pool: pool) { _ in 0 }
        try await sender.send(Self.powerUp)
        XCTAssertEqual(calls.requests.map(\.eventType), [.keydown, .keyup, .keyup])
        XCTAssertEqual(calls.requests.map(\.keyCode), [116, 116, 116])
        await pool.closeAll()
    }

    /// Rule 5, the teardown race: the mirror's teardown closes the shared
    /// connection (`EmulatorControls.closeConnections`) while the session's
    /// last key-ups are still going out. When that close lands between the
    /// lease and the call, the call never starts (the client is stopped),
    /// which is not a stale connection: a release is still sent once more
    /// on a fresh one, a press still never is.
    func testAReleaseIsResentWhenATeardownClosesTheConnectionBeforeTheCall() async throws {
        let pool = EmulatorConnectionPool()
        let port = 1
        final class Calls: @unchecked Sendable {
            private let lock = NSLock()
            private var _requests: [Android_Emulation_Control_KeyboardEvent] = []
            private var _errors: [any Error] = []
            var requests: [Android_Emulation_Control_KeyboardEvent] { lock.withLock { _requests } }
            var errors: [any Error] { lock.withLock { _errors } }
            /// Records the call; true for the first call of each event.
            func record(_ request: Android_Emulation_Control_KeyboardEvent) -> Bool {
                lock.withLock {
                    _requests.append(request)
                    return _requests.filter { $0 == request }.count == 1
                }
            }
            func failed(_ error: any Error) {
                lock.withLock { _errors.append(error) }
            }
        }
        let calls = Calls()
        let sender = HardwareKeySender.grpc(port: port, pool: pool) { controller, request in
            guard calls.record(request) else { return }
            // The teardown's close, after this call's lease and before its
            // RPC: the real `sendKey` on the closed client.
            await pool.close(port: port)
            do {
                _ = try await controller.sendKey(request, options: .controls)
            } catch {
                calls.failed(error)
                throw error
            }
        }

        try await sender.send(Self.powerUp)
        XCTAssertEqual(calls.requests.map(\.eventType), [.keyup, .keyup], "the release is sent again")
        XCTAssertEqual(calls.errors.count, 1)
        XCTAssertEqual((calls.errors.first as? RuntimeError)?.code, .clientIsStopped, "\(calls.errors)")

        do {
            try await sender.send(Self.powerDown)
            XCTFail("a press on a closed connection must fail, not rerun")
        } catch let error as RuntimeError {
            XCTAssertEqual(error.code, .clientIsStopped)
        }
        XCTAssertEqual(calls.requests.map(\.eventType), [.keyup, .keyup, .keydown])
        await pool.closeAll()
    }

    /// Rule 6: keys still down when the stream ends are released, power
    /// first, then volume up, then volume down, whatever the press order.
    func testTheStreamsEndReleasesEveryHeldKeyInOrder() async {
        let fake = FakeSender()
        await run([Self.volumeDownDown, Self.powerDown, Self.volumeUpDown], fake: fake)
        XCTAssertEqual(fake.sent, [
            Self.volumeDownDown, Self.powerDown, Self.volumeUpDown,
            Self.powerUp, Self.volumeUpUp, Self.volumeDownUp,
        ])
    }

    /// Rule 7: one send at a time, in the order the events came; a release
    /// queued behind a slow press waits for it instead of overtaking it.
    func testEventsAreSentOneAtATimeInOrder() async {
        let fake = FakeSender()
        fake.hold(Self.powerDown)
        let (stream, continuation) = AsyncStream<HardwareKeyEvent>.makeStream()
        let injector = Task {
            await HardwareKeyInjector.run(
                events: stream,
                stopSignal: KeyboardInjector.StopSignal(),
                sender: fake.sender,
                reportError: { _ in }
            )
        }
        continuation.yield(Self.powerDown)
        continuation.yield(Self.powerUp)
        continuation.yield(Self.volumeUpDown)
        continuation.yield(Self.volumeUpUp)
        let started = await waitUntil { fake.sent == [Self.powerDown] }
        XCTAssertTrue(started)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fake.sent, [Self.powerDown], "nothing overtakes the held press")

        fake.open()
        continuation.finish()
        await injector.value
        XCTAssertEqual(fake.sent, [Self.powerDown, Self.powerUp, Self.volumeUpDown, Self.volumeUpUp])
        XCTAssertEqual(fake.mostInFlight, 1)
    }

    // MARK: - In the session

    /// The emulator session carries hardware keys on a queue of its own:
    /// stopping it drops a press still queued but delivers the release
    /// queued behind it, and a press after the stop goes nowhere.
    func testTheEmulatorSessionReleasesItsKeysWhenItStops() async {
        let fake = FakeSender()
        fake.hold(Self.powerDown)
        let session = MirrorSession(port: 1, touchSender: { _, _, _ in }, hardwareKeySender: fake.sender)
        XCTAssertTrue(session.supportsHardwareKeys)
        session.start()

        session.send(Self.powerDown)
        let pressing = await waitUntil { fake.sent == [Self.powerDown] }
        XCTAssertTrue(pressing)
        session.send(Self.volumeUpDown)
        session.send(Self.powerUp)
        session.stop()
        session.send(Self.volumeDownDown)
        fake.open()

        let released = await waitUntil { fake.sent.count == 2 }
        XCTAssertTrue(released)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fake.sent, [Self.powerDown, Self.powerUp])
    }

    /// A key held when the session stops is released by the session itself.
    func testStoppingTheEmulatorSessionReleasesAKeyStillHeld() async {
        let fake = FakeSender()
        let session = MirrorSession(port: 1, touchSender: { _, _, _ in }, hardwareKeySender: fake.sender)
        session.start()
        session.send(Self.volumeDownDown)
        let pressed = await waitUntil { fake.sent == [Self.volumeDownDown] }
        XCTAssertTrue(pressed)

        session.stop()

        let released = await waitUntil { fake.sent == [Self.volumeDownDown, Self.volumeDownUp] }
        XCTAssertTrue(released, "\(fake.sent)")
    }

    /// A restarted session gets a fresh key queue.
    func testARestartedSessionStillSendsKeys() async {
        let fake = FakeSender()
        let session = MirrorSession(port: 1, touchSender: { _, _, _ in }, hardwareKeySender: fake.sender)
        session.start()
        session.stop()
        session.start()
        defer { session.stop() }

        session.send(Self.powerDown)
        session.send(Self.powerUp)
        let sent = await waitUntil { fake.sent == [Self.powerDown, Self.powerUp] }
        XCTAssertTrue(sent, "\(fake.sent)")
    }

    /// Sessions without a hardware-key path take the protocol's default:
    /// no support, and a send is dropped.
    func testAPhysicalSessionHasNoHardwareKeys() {
        let session = PhysicalMirrorSession(serial: "stub-serial") { throw CancellationError() }
        XCTAssertFalse(session.supportsHardwareKeys)
        session.send(Self.powerDown)
        XCTAssertFalse(session.isRunning)
    }
}
