import XCTest
@testable import DeviceHubProKit

/// The frame's side buttons on a guest without the emulator's keyboard
/// (`AdbHardwareKeys`): one `input keyevent` is a whole press, so a held
/// button is stood in for with Android's own timings. No emulator: presses
/// go to a recording fake and time only passes when the test says so
/// (`ManualSleeper`).
///
/// The timings are SOURCE-DERIVED (AOSP `platform/frameworks/base` main):
/// 400 ms and 50 ms are `ViewConfiguration`'s `DEFAULT_KEY_REPEAT_TIMEOUT_MS`
/// and `DEFAULT_KEY_REPEAT_DELAY_MS`; 500 ms is `config.xml`'s
/// `config_longPressOnPowerDurationMs` and `config_globalActionsKeyTimeout`.
/// The key codes are `KeyEvent.java`'s `KEYCODE_POWER` 26,
/// `KEYCODE_VOLUME_UP` 24 and `KEYCODE_VOLUME_DOWN` 25.
final class AdbHardwareKeysTests: XCTestCase {
    /// A clock the test moves: every sleep waits until `elapse()` ends it,
    /// or throws when its task is cancelled.
    final class ManualSleeper: @unchecked Sendable {
        private let lock = NSLock()
        private var nextID = 0
        private var waiting: [Int: (duration: Duration, continuation: CheckedContinuation<Void, any Error>)] = [:]
        private var cancelledEarly: Set<Int> = []
        private var _requested: [Duration] = []

        /// Every sleep asked for, in order.
        var requested: [Duration] { lock.withLock { _requested } }
        /// The sleeps now waiting, oldest first.
        var pending: [Duration] {
            lock.withLock { waiting.keys.sorted().compactMap { waiting[$0]?.duration } }
        }

        var sleep: AdbHardwareKeys.Sleep {
            { [self] duration in
                let id = lock.withLock {
                    nextID += 1
                    _requested.append(duration)
                    return nextID
                }
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                        let cancelled = lock.withLock { () -> Bool in
                            if cancelledEarly.remove(id) != nil { return true }
                            waiting[id] = (duration, continuation)
                            return false
                        }
                        if cancelled { continuation.resume(throwing: CancellationError()) }
                    }
                } onCancel: {
                    let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                        if let entry = waiting.removeValue(forKey: id) { return entry.continuation }
                        cancelledEarly.insert(id)
                        return nil
                    }
                    continuation?.resume(throwing: CancellationError())
                }
            }
        }

        /// Ends every sleep now waiting.
        func elapse() {
            let continuations = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
                defer { waiting = [:] }
                return waiting.keys.sorted().compactMap { waiting[$0]?.continuation }
            }
            continuations.forEach { $0.resume() }
        }
    }

    /// Records the presses; can fail them, or hold them until `open()`.
    final class PressLog: @unchecked Sendable {
        struct Press: Equatable, CustomStringConvertible {
            let key: HardwareKey
            let longPress: Bool
            var description: String { "\(key)\(longPress ? " long" : "")" }
        }
        struct Failure: Error, CustomStringConvertible {
            var description: String { "adb failed" }
        }

        private let lock = NSLock()
        private var _presses: [Press] = []
        private var _finished = 0
        private var _inFlight = 0
        private var _mostInFlight = 0
        private var failing = false
        private var holding = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        var presses: [Press] { lock.withLock { _presses } }
        var finished: Int { lock.withLock { _finished } }
        var mostInFlight: Int { lock.withLock { _mostInFlight } }

        func failAll() { lock.withLock { failing = true } }
        func holdAll() { lock.withLock { holding = true } }

        func open() {
            let pending = lock.withLock {
                holding = false
                defer { waiters = [] }
                return waiters
            }
            pending.forEach { $0.resume() }
        }

        var press: AdbHardwareKeys.Press {
            { [self] key, longPress in
                let (fails, waits) = lock.withLock {
                    _presses.append(Press(key: key, longPress: longPress))
                    _inFlight += 1
                    _mostInFlight = max(_mostInFlight, _inFlight)
                    return (failing, holding)
                }
                if waits {
                    await withCheckedContinuation { continuation in
                        let resumeNow = lock.withLock {
                            guard holding else { return true }
                            waiters.append(continuation)
                            return false
                        }
                        if resumeNow { continuation.resume() }
                    }
                }
                lock.withLock {
                    _inFlight -= 1
                    _finished += 1
                }
                if fails { throw Failure() }
            }
        }
    }

    final class Errors: @unchecked Sendable {
        private let lock = NSLock()
        private var _messages: [String] = []
        var messages: [String] { lock.withLock { _messages } }
        func append(_ message: String) { lock.withLock { _messages.append(message) } }
    }

    private static func short(_ key: HardwareKey) -> PressLog.Press { .init(key: key, longPress: false) }
    private static let longPower = PressLog.Press(key: .power, longPress: true)

    private func makeKeys(
        _ log: PressLog,
        _ sleeper: ManualSleeper,
        stopSignal: KeyboardInjector.StopSignal = KeyboardInjector.StopSignal(),
        errors: Errors = Errors()
    ) -> AdbHardwareKeys {
        AdbHardwareKeys(
            press: log.press,
            stopSignal: stopSignal,
            sleep: sleeper.sleep,
            reportError: { errors.append($0) }
        )
    }

    private func waitUntil(
        _ message: @autoclosure () -> String = "",
        timeout: Duration = .seconds(3),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), message(), file: file, line: line)
    }

    // MARK: - Arguments and timings

    func testThePressArgumentsAndAndroidsTimings() {
        XCTAssertEqual(AdbHardwareKeys.arguments(for: .power, longPress: false), ["input", "keyevent", "26"])
        XCTAssertEqual(AdbHardwareKeys.arguments(for: .power, longPress: true), ["input", "keyevent", "--longpress", "26"])
        XCTAssertEqual(AdbHardwareKeys.arguments(for: .volumeUp, longPress: false), ["input", "keyevent", "24"])
        XCTAssertEqual(AdbHardwareKeys.arguments(for: .volumeDown, longPress: false), ["input", "keyevent", "25"])

        XCTAssertEqual(AdbHardwareKeys.Timing.android.repeatTimeout, .milliseconds(400))
        XCTAssertEqual(AdbHardwareKeys.Timing.android.repeatInterval, .milliseconds(50))
        XCTAssertEqual(AdbHardwareKeys.Timing.android.powerLongPress, .milliseconds(500))
    }

    // MARK: - Volume

    /// A click: one step at once; letting go before the repeat timeout
    /// sends nothing more.
    func testAVolumeClickIsOneStep() async throws {
        let log = PressLog()
        let sleeper = ManualSleeper()
        let keys = makeKeys(log, sleeper)

        await keys.keyDown(.volumeUp)
        await waitUntil { log.finished == 1 && sleeper.pending == [.milliseconds(400)] }
        XCTAssertEqual(log.presses, [Self.short(.volumeUp)])

        try await keys.keyUp(.volumeUp)
        XCTAssertEqual(log.presses, [Self.short(.volumeUp)])
        XCTAssertEqual(sleeper.pending, [])
        XCTAssertEqual(sleeper.requested, [.milliseconds(400)])
    }

    /// A hold: the first step at once, the next after 400 ms, then one every
    /// 50 ms until the button comes up.
    func testAHeldVolumeRepeatsLikeAHeldKey() async throws {
        let log = PressLog()
        let sleeper = ManualSleeper()
        let keys = makeKeys(log, sleeper)

        await keys.keyDown(.volumeDown)
        await waitUntil { log.finished == 1 && sleeper.pending == [.milliseconds(400)] }
        for step in 2...5 {
            sleeper.elapse()
            await waitUntil("step \(step)") { log.finished == step && sleeper.pending == [.milliseconds(50)] }
        }
        try await keys.keyUp(.volumeDown)

        XCTAssertEqual(log.presses, Array(repeating: Self.short(.volumeDown), count: 5))
        XCTAssertEqual(sleeper.requested, [.milliseconds(400)] + Array(repeating: .milliseconds(50), count: 4))
        XCTAssertEqual(log.mostInFlight, 1)
    }

    /// A step that takes longer than the interval holds the next one back:
    /// at most one press is in flight.
    func testARepeatWaitsForTheStepBefore() async throws {
        let log = PressLog()
        let sleeper = ManualSleeper()
        let keys = makeKeys(log, sleeper)
        log.holdAll()

        await keys.keyDown(.volumeUp)
        await waitUntil { log.presses.count == 1 && sleeper.pending == [.milliseconds(400)] }
        sleeper.elapse()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(log.presses.count, 1, "the first step is still in flight")

        log.open()
        await waitUntil { log.finished == 2 && sleeper.pending == [.milliseconds(50)] }
        try await keys.keyUp(.volumeUp)
        XCTAssertEqual(log.mostInFlight, 1)
        XCTAssertEqual(log.presses.count, 2)
    }

    /// Letting go waits for the step in flight (a cancelled adb call would
    /// cut a press short), then nothing more goes out.
    func testLettingGoWaitsForTheStepInFlight() async throws {
        let log = PressLog()
        let sleeper = ManualSleeper()
        let keys = makeKeys(log, sleeper)
        log.holdAll()

        await keys.keyDown(.volumeUp)
        await waitUntil { log.presses.count == 1 }
        let release = Task { try await keys.keyUp(.volumeUp) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(log.finished, 0, "the press is not cancelled")

        log.open()
        try await release.value
        XCTAssertEqual(log.finished, 1)
        XCTAssertEqual(log.presses, [Self.short(.volumeUp)])
    }

    /// A step that fails ends the repeats (the device is gone): the error
    /// is reported, and the release still returns.
    func testAFailedStepEndsTheRepeats() async throws {
        let log = PressLog()
        let sleeper = ManualSleeper()
        let errors = Errors()
        let keys = makeKeys(log, sleeper, errors: errors)
        log.failAll()

        await keys.keyDown(.volumeDown)
        await waitUntil { log.finished == 1 && sleeper.pending == [.milliseconds(400)] }
        sleeper.elapse()
        try await Task.sleep(for: .milliseconds(50))
        try await keys.keyUp(.volumeDown)

        XCTAssertEqual(log.presses, [Self.short(.volumeDown)])
        XCTAssertEqual(errors.messages, ["adb failed"])
    }

    // MARK: - Power

    /// A click: nothing while the button is down, one short press when it
    /// comes up.
    func testAPowerClickIsOneShortPressOnRelease() async throws {
        let log = PressLog()
        let sleeper = ManualSleeper()
        let keys = makeKeys(log, sleeper)

        await keys.keyDown(.power)
        await waitUntil { sleeper.pending == [.milliseconds(500)] }
        XCTAssertEqual(log.presses, [])

        try await keys.keyUp(.power)
        XCTAssertEqual(log.presses, [Self.short(.power)])
        XCTAssertEqual(log.finished, 1, "the release returns after its press")
        XCTAssertEqual(sleeper.pending, [])
    }

    /// Held past 500 ms: one long press, at once; the release adds nothing.
    func testAHeldPowerIsOneLongPress() async throws {
        let log = PressLog()
        let sleeper = ManualSleeper()
        let keys = makeKeys(log, sleeper)

        await keys.keyDown(.power)
        await waitUntil { sleeper.pending == [.milliseconds(500)] }
        sleeper.elapse()
        await waitUntil { log.finished == 1 }
        XCTAssertEqual(log.presses, [Self.longPower])

        try await keys.keyUp(.power)
        XCTAssertEqual(log.presses, [Self.longPower])
    }

    /// The release of a long press waits for it to finish.
    func testReleasingALongPressWaitsForIt() async throws {
        let log = PressLog()
        let sleeper = ManualSleeper()
        let keys = makeKeys(log, sleeper)
        log.holdAll()

        await keys.keyDown(.power)
        await waitUntil { sleeper.pending == [.milliseconds(500)] }
        sleeper.elapse()
        await waitUntil { log.presses == [Self.longPower] }
        let release = Task { try await keys.keyUp(.power) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(log.finished, 0)

        log.open()
        try await release.value
        XCTAssertEqual(log.finished, 1)
        XCTAssertEqual(log.presses, [Self.longPower])
    }

    /// A short press that fails throws from the release, which the key
    /// queue reports.
    func testAFailedShortPressThrowsFromTheRelease() async {
        let log = PressLog()
        let sleeper = ManualSleeper()
        let keys = makeKeys(log, sleeper)
        log.failAll()

        await keys.keyDown(.power)
        do {
            try await keys.keyUp(.power)
            XCTFail("the failed press must throw")
        } catch {
            XCTAssertEqual("\(error)", "adb failed")
        }
    }

    // MARK: - Stop and the stream's end

    /// The stream ended with the buttons still down: a power press not yet
    /// sent is dropped (a stopped session presses nothing more), a volume
    /// key stops repeating.
    func testTheStreamsEndSendsNothingNew() async throws {
        let log = PressLog()
        let sleeper = ManualSleeper()
        let keys = makeKeys(log, sleeper)

        await keys.keyDown(.power)
        await keys.keyDown(.volumeUp)
        await waitUntil { log.finished == 1 && sleeper.pending.count == 2 }
        await keys.abandon(.power)
        await keys.abandon(.volumeUp)

        XCTAssertEqual(log.presses, [Self.short(.volumeUp)])
        XCTAssertEqual(sleeper.pending, [])

        // Nothing is held any more: a late release sends nothing.
        try await keys.keyUp(.power)
        XCTAssertEqual(log.presses, [Self.short(.volumeUp)])
    }

    /// After the stop no repeat and no long press starts. A release that
    /// was already on its way still presses what the hold called for: power
    /// held past 500 ms is a long press.
    func testAStoppedSessionStartsNoRepeatAndNoLongPress() async throws {
        let log = PressLog()
        let sleeper = ManualSleeper()
        let stopSignal = KeyboardInjector.StopSignal()
        let keys = makeKeys(log, sleeper, stopSignal: stopSignal)

        await keys.keyDown(.volumeDown)
        await keys.keyDown(.power)
        await waitUntil { log.finished == 1 && sleeper.pending.count == 2 }
        stopSignal.stop()
        sleeper.elapse()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(log.presses, [Self.short(.volumeDown)], "no repeat, no long press")
        XCTAssertEqual(sleeper.pending, [], "the repeat loop ended")

        try await keys.keyUp(.volumeDown)
        try await keys.keyUp(.power)
        XCTAssertEqual(log.presses, [Self.short(.volumeDown), Self.longPower])
    }

    /// Stopped with power held past 500 ms and the stream ending (no
    /// release): nothing at all.
    func testAPowerHoldAbandonedAfterTheStopPressesNothing() async throws {
        let log = PressLog()
        let sleeper = ManualSleeper()
        let stopSignal = KeyboardInjector.StopSignal()
        let keys = makeKeys(log, sleeper, stopSignal: stopSignal)

        await keys.keyDown(.power)
        await waitUntil { sleeper.pending == [.milliseconds(500)] }
        stopSignal.stop()
        sleeper.elapse()
        try await Task.sleep(for: .milliseconds(50))
        await keys.abandon(.power)
        XCTAssertEqual(log.presses, [])
    }

    // MARK: - As the key queue's sender

    /// Through `HardwareKeyInjector`: a volume click is one step, and power
    /// still down when the stream ends is dropped, not pressed.
    func testTheAdbSenderUnderTheKeyQueue() async throws {
        let log = PressLog()
        let sleeper = ManualSleeper()
        let keys = makeKeys(log, sleeper)
        let (stream, continuation) = AsyncStream<HardwareKeyEvent>.makeStream()
        let injector = Task {
            await HardwareKeyInjector.run(
                events: stream,
                stopSignal: KeyboardInjector.StopSignal(),
                sender: .adb(keys),
                reportError: { _ in }
            )
        }
        continuation.yield(HardwareKeyEvent(key: .volumeUp, isDown: true))
        continuation.yield(HardwareKeyEvent(key: .volumeUp, isDown: false))
        continuation.yield(HardwareKeyEvent(key: .power, isDown: true))
        await waitUntil { log.finished == 1 && sleeper.pending == [.milliseconds(500)] }
        continuation.finish()
        await injector.value

        XCTAssertEqual(log.presses, [Self.short(.volumeUp)])
        XCTAssertEqual(sleeper.pending, [])
    }

    /// The routed sender hands each event, and each end-of-stream release,
    /// to the side the route names.
    func testTheRoutedSenderFollowsTheRoute() async throws {
        final class Sent: @unchecked Sendable {
            private let lock = NSLock()
            private var _log: [String] = []
            var log: [String] { lock.withLock { _log } }
            func add(_ entry: String) { lock.withLock { _log.append(entry) } }
        }
        let sent = Sent()
        func side(_ name: String) -> HardwareKeySender {
            HardwareKeySender(
                send: { sent.add("\(name) \($0.key) \($0.isDown ? "down" : "up")") },
                releaseAtEnd: { sent.add("\(name) end \($0)") }
            )
        }
        for route in [EmulatorKeyRoute.emulatorKeyboard, .adbInput] {
            let sender = HardwareKeySender.routed(
                emulatorKeyboard: side("emulator"),
                adb: side("adb"),
                route: { route }
            )
            try await sender.send(HardwareKeyEvent(key: .power, isDown: true))
            try await sender.releaseAtEnd(.power)
        }
        XCTAssertEqual(sent.log, ["emulator power down", "emulator end power", "adb power down", "adb end power"])

        // The default end-of-stream release is a key-up.
        let plain = Sent()
        let grpcLike = HardwareKeySender { plain.add("\($0.key) \($0.isDown ? "down" : "up")") }
        try await grpcLike.releaseAtEnd(.volumeDown)
        XCTAssertEqual(plain.log, ["volumeDown up"])
    }
}
