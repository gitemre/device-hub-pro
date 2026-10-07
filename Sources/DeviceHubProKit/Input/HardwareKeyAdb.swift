import Foundation

/// Presses power and volume with `adb shell input keyevent` for a guest
/// that has no keyboard device for the emulator's keys
/// (`EmulatorKeyRoute.adbInput`).
///
/// One `input keyevent` is a whole press, down and up, so a frame button
/// held down is stood in for on the host, with Android's own timings
/// (`Timing.android`):
/// - volume: one press at once; while the button stays down, one more from
///   `repeatTimeout` after it, then every `repeatInterval`, each press
///   waiting for the one before (at most one in flight, so letting go stops
///   the steps within one press);
/// - power: nothing until the button comes up or has been down for
///   `powerLongPress`: up before that is one short press, a hold that long
///   one long press (`input keyevent --longpress 26`: the key held past the
///   long-press timeout with `FLAG_LONG_PRESS`, which the guest's power rule
///   acts on at once, SOURCE-DERIVED: `InputShellCommand.sendKeyEvent`,
///   `SingleKeyGestureDetector.interceptKey`).
///
/// No key is ever left down in the guest: every call is a complete press,
/// even if Device Hub Pro goes away halfway.
///
/// Once the session's `stopSignal` is set, no repeat and no long press is
/// started any more. A key-up still presses what the button's hold called
/// for (the mouse-up came before the stop: the emulator route's key-up
/// would complete a press already sent too); `abandon`, the stream's end
/// with the button still down, presses nothing that has not already gone
/// out.
actor AdbHardwareKeys {
    struct Timing: Sendable, Equatable {
        var repeatTimeout: Duration
        var repeatInterval: Duration
        var powerLongPress: Duration

        /// SOURCE-DERIVED from AOSP `platform/frameworks/base` main:
        /// - `repeatTimeout` 400 ms, `repeatInterval` 50 ms: how a held key
        ///   repeats, `ViewConfiguration`'s `DEFAULT_KEY_REPEAT_TIMEOUT_MS`
        ///   (= `DEFAULT_LONG_PRESS_TIMEOUT`, 400) and
        ///   `DEFAULT_KEY_REPEAT_DELAY_MS` (50)
        ///   (`core/java/android/view/ViewConfiguration.java`);
        /// - `powerLongPress` 500 ms: `config_longPressOnPowerDurationMs`
        ///   (the assistant, the default `config_longPressOnPowerBehavior` 5,
        ///   read by `PhoneWindowManager`) and `config_globalActionsKeyTimeout`
        ///   (the power menu, read by `SingleKeyGestureDetector`), both 500 in
        ///   `core/res/res/values/config.xml`.
        static let android = Timing(
            repeatTimeout: .milliseconds(400),
            repeatInterval: .milliseconds(50),
            powerLongPress: .milliseconds(500)
        )
    }

    /// One whole press of `key` in the guest, long or short.
    typealias Press = @Sendable (_ key: HardwareKey, _ longPress: Bool) async throws -> Void
    /// Waits `duration` (a test seam); throws when the waiting task is
    /// cancelled.
    typealias Sleep = @Sendable (_ duration: Duration) async throws -> Void

    private enum Hold {
        /// Volume, down: the loop that presses and repeats.
        case volume(Task<Void, Never>)
        /// Power, down, no press sent yet. `heldPastLongPress` once the
        /// timer ran out after the stop (so it started nothing).
        case power(id: UInt64, timer: Task<Void, Never>, heldPastLongPress: Bool)
        /// Power, held past the long press: the long press it sent.
        case powerLongPress(Task<Void, Never>)
    }

    private let press: Press
    private let sleep: Sleep
    private let timing: Timing
    private let stopSignal: KeyboardInjector.StopSignal
    private let reportError: @Sendable (String) -> Void
    private var holds: [HardwareKey: Hold] = [:]
    private var nextPowerID: UInt64 = 0

    /// `reportError` receives the failures of the presses that go out while
    /// a button is held (the repeats, the long press); the short press on a
    /// key-up throws instead.
    init(
        press: @escaping Press,
        stopSignal: KeyboardInjector.StopSignal,
        timing: Timing = .android,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        reportError: @escaping @Sendable (String) -> Void
    ) {
        self.press = press
        self.stopSignal = stopSignal
        self.timing = timing
        self.sleep = sleep
        self.reportError = reportError
    }

    /// The `input` arguments of one press.
    static func arguments(for key: HardwareKey, longPress: Bool) -> [String] {
        ["input", "keyevent"] + (longPress ? ["--longpress"] : []) + ["\(key.androidKeyCode)"]
    }

    /// A button went down. Returns at once: the presses it calls for go out
    /// in tasks of their own. A key already down is left as it is.
    func keyDown(_ key: HardwareKey) {
        guard holds[key] == nil else { return }
        switch key {
        case .power:
            nextPowerID &+= 1
            let id = nextPowerID
            let sleep = self.sleep
            let delay = timing.powerLongPress
            let timer = Task { [weak self] in
                do {
                    try await sleep(delay)
                } catch {
                    return
                }
                await self?.powerHeldPastLongPress(id: id)
            }
            holds[.power] = .power(id: id, timer: timer, heldPastLongPress: false)

        case .volumeUp, .volumeDown:
            let press = self.press
            let sleep = self.sleep
            let timing = self.timing
            let stopSignal = self.stopSignal
            let reportError = self.reportError
            holds[key] = .volume(Task.detached {
                await Self.holdVolume(
                    key,
                    press: press,
                    sleep: sleep,
                    timing: timing,
                    stopSignal: stopSignal,
                    reportError: reportError
                )
            })
        }
    }

    /// The button came up: a volume key stops repeating (the press in
    /// flight finishes first); power sends its short press, or its long one
    /// when it was held past the long press after the stop, or waits for the
    /// long press it already sent. Returns once nothing more goes out for
    /// this hold.
    func keyUp(_ key: HardwareKey) async throws {
        // Taken out before any wait: a timer that runs out meanwhile finds
        // no hold and starts nothing.
        guard let hold = holds.removeValue(forKey: key) else { return }
        switch hold {
        case .volume(let loop):
            loop.cancel()
            await loop.value
        case .power(_, let timer, let heldPastLongPress):
            timer.cancel()
            try await Self.shielded(press, .power, longPress: heldPastLongPress)
        case .powerLongPress(let longPress):
            await longPress.value
        }
    }

    /// The key stream ended with the button still down: stops what the hold
    /// was doing and sends nothing new (a power press not yet sent is
    /// dropped); a press already in flight still finishes.
    func abandon(_ key: HardwareKey) async {
        guard let hold = holds.removeValue(forKey: key) else { return }
        switch hold {
        case .volume(let loop):
            loop.cancel()
            await loop.value
        case .power(_, let timer, _):
            timer.cancel()
        case .powerLongPress(let longPress):
            await longPress.value
        }
    }

    /// Power's timer ran out with the button still down.
    private func powerHeldPastLongPress(id: UInt64) {
        guard case .power(let current, let timer, _)? = holds[.power], current == id else { return }
        guard !stopSignal.isStopped else {
            // A stopped session starts nothing; the key-up decides.
            holds[.power] = .power(id: id, timer: timer, heldPastLongPress: true)
            return
        }
        let press = self.press
        let reportError = self.reportError
        holds[.power] = .powerLongPress(Task.detached {
            do {
                try await press(.power, true)
            } catch {
                reportError("\(error)")
            }
        })
    }

    /// One press in a task of its own: a caller that is cancelled must not
    /// cut an adb call short halfway through a press.
    private static func shielded(_ press: @escaping Press, _ key: HardwareKey, longPress: Bool) async throws {
        try await Task { try await press(key, longPress) }.value
    }

    /// A held volume button: the first press at once, then the repeats,
    /// until the loop is cancelled (the button came up), the session stops
    /// or a press fails. Each repeat starts `repeatInterval` after the one
    /// before started, or when it finished if it took longer.
    private static func holdVolume(
        _ key: HardwareKey,
        press: @escaping Press,
        sleep: Sleep,
        timing: Timing,
        stopSignal: KeyboardInjector.StopSignal,
        reportError: @escaping @Sendable (String) -> Void
    ) async {
        // Each press runs in a task of its own, not cancelled with the loop.
        func pressOnce() -> Task<Bool, Never> {
            Task {
                do {
                    try await press(key, false)
                    return true
                } catch {
                    reportError("\(error)")
                    return false
                }
            }
        }
        var inFlight = pressOnce()
        var wait = timing.repeatTimeout
        while true {
            do {
                try await sleep(wait)
            } catch {
                break
            }
            guard await inFlight.value, !Task.isCancelled, !stopSignal.isStopped else { break }
            inFlight = pressOnce()
            wait = timing.repeatInterval
        }
        _ = await inFlight.value
    }
}

extension HardwareKeySender {
    /// The adb route: `keys` stands in for the held button.
    static func adb(_ keys: AdbHardwareKeys) -> HardwareKeySender {
        HardwareKeySender(
            send: { event in
                if event.isDown {
                    await keys.keyDown(event.key)
                } else {
                    try await keys.keyUp(event.key)
                }
            },
            releaseAtEnd: { key in
                await keys.abandon(key)
            }
        )
    }

    /// Sends through `emulatorKeyboard` or `adb`, as `route` decides. A
    /// decided route stays for the run, so a key's down and up take the
    /// same one, except a key that went down before the decision (on the
    /// emulator's keyboard, which a keyboard-less guest drops): its key-up
    /// on adb finds no hold and sends nothing (`AdbHardwareKeys.keyUp`).
    static func routed(
        emulatorKeyboard: HardwareKeySender,
        adb: HardwareKeySender,
        route: @escaping @Sendable () async -> EmulatorKeyRoute
    ) -> HardwareKeySender {
        HardwareKeySender(
            send: { event in
                switch await route() {
                case .emulatorKeyboard: try await emulatorKeyboard.send(event)
                case .adbInput: try await adb.send(event)
                }
            },
            releaseAtEnd: { key in
                switch await route() {
                case .emulatorKeyboard: try await emulatorKeyboard.releaseAtEnd(key)
                case .adbInput: try await adb.releaseAtEnd(key)
                }
            }
        )
    }
}
