import Foundation
import GRPCCore
import GRPCProtobuf

/// A side button of the device's body: what the frame's painted power
/// button and volume rocker press.
public enum HardwareKey: Sendable, Hashable, CaseIterable {
    case power
    case volumeUp
    case volumeDown

    /// Android's key code (SOURCE-DERIVED: `KEYCODE_POWER` 26,
    /// `KEYCODE_VOLUME_UP` 24, `KEYCODE_VOLUME_DOWN` 25 in AOSP
    /// `frameworks/base/core/java/android/view/KeyEvent.java`).
    public var androidKeyCode: Int {
        switch self {
        case .power: return 26
        case .volumeUp: return 24
        case .volumeDown: return 25
        }
    }

    /// The Linux input code the emulator's `KeyCodeType.Evdev` takes
    /// (SOURCE-DERIVED: `KEY_POWER` 116, `KEY_VOLUMEUP` 115,
    /// `KEY_VOLUMEDOWN` 114 in `include/uapi/linux/input-event-codes.h`).
    /// The guest's `qwerty2` keyboard reports all three.
    public var evdevCode: Int32 {
        switch self {
        case .power: return 116
        case .volumeUp: return 115
        case .volumeDown: return 114
        }
    }
}

/// One edge of a hardware key: pressed (`isDown`) or released. A press and
/// its release are separate events, so a key can be held as long as the
/// mouse is: the guest repeats volume and turns a held power into a long
/// press by itself.
public struct HardwareKeyEvent: Sendable, Hashable {
    public var key: HardwareKey
    public var isDown: Bool

    public init(key: HardwareKey, isDown: Bool) {
        self.key = key
        self.isDown = isDown
    }
}

/// Delivers one hardware key event to the emulator (a test seam).
struct HardwareKeySender: Sendable {
    var send: @Sendable (HardwareKeyEvent) async throws -> Void
    /// Lets go of a key still held when the session's key stream ended (the
    /// injector's rule 6): the mouse-up that would have released it can no
    /// longer come. A key-up by default; the adb route
    /// (`HardwareKeySender.adb`) instead drops a press that has not reached
    /// the guest yet, since a stopped session presses nothing more.
    var releaseAtEnd: @Sendable (HardwareKey) async throws -> Void

    init(
        send: @escaping @Sendable (HardwareKeyEvent) async throws -> Void,
        releaseAtEnd: (@Sendable (HardwareKey) async throws -> Void)? = nil
    ) {
        self.send = send
        self.releaseAtEnd = releaseAtEnd ?? { key in
            try await send(HardwareKeyEvent(key: key, isDown: false))
        }
    }

    /// The emulator's `sendKey` on its shared control connection.
    static func grpc(port: Int) -> HardwareKeySender {
        grpc(port: port, pool: .shared) { controller, request in
            _ = try await controller.sendKey(request, options: .controls)
        }
    }

    /// `grpc(port:)` with the pool and the call itself swappable (test
    /// seam). A key-up may be rerun once on a fresh connection when the
    /// shared one turns out stale: releasing a key that is already up
    /// changes nothing, since the input core ignores an `EV_KEY` value equal
    /// to the key's current state (SOURCE-DERIVED: `input_get_disposition`,
    /// `drivers/input/input.c`). A key-down never is: a rerun could press
    /// twice (a second power press puts the screen back to sleep).
    ///
    /// A key-up is also rerun once when the shared connection was closed
    /// under it: the mirror's teardown closes it
    /// (`EmulatorControls.closeConnections`) while the stopped session's
    /// last key-ups still go out, and a close that lands between the lease
    /// and the call stops the client before the call starts. That is not a
    /// stale connection (`withSharedClient` does not rerun it), and without
    /// the rerun the key would stay down in the guest.
    static func grpc(
        port: Int,
        pool: EmulatorConnectionPool,
        deliver: @escaping @Sendable (EmulatorClient, Android_Emulation_Control_KeyboardEvent) async throws -> Void
    ) -> HardwareKeySender {
        HardwareKeySender { event in
            let request = keyboardEvent(for: event)
            let send = {
                try await EmulatorControl.withSharedClient(
                    port: port,
                    pool: pool,
                    retryOnStaleConnection: !event.isDown
                ) { controller in
                    try await deliver(controller, request)
                }
            }
            do {
                try await send()
            } catch where !event.isDown && isClosedBeforeTheCall(error) && !Task.isCancelled {
                try await send()
            }
        }
    }

    /// True for the failure of a call whose connection was shut down before
    /// the call started (`RuntimeError.Code.clientIsStopped`): nothing
    /// reached the emulator.
    static func isClosedBeforeTheCall(_ error: any Error) -> Bool {
        (error as? RuntimeError)?.code == .clientIsStopped
    }

    /// The `sendKey` request: the key's evdev code, down or up.
    static func keyboardEvent(for event: HardwareKeyEvent) -> Android_Emulation_Control_KeyboardEvent {
        .with {
            $0.codeType = .evdev
            $0.eventType = event.isDown ? .keydown : .keyup
            $0.keyCode = event.key.evdevCode
        }
    }
}

/// Drives one session's hardware-key queue. A key that went down always
/// comes back up: a lost key-up would leave power or volume held in the
/// guest (a power menu that opens by itself, volume running to an end).
///
/// The rules, in order of the checks:
/// 1. a key-down for a key already held is ignored;
/// 2. once `stopSignal` is stopped, key-downs are dropped (not sent, not
///    held) — a stopped or replaced session must not press anything more;
/// 3. a key-down that fails to send still counts as held, so its key-up
///    follows (a stray key-up is harmless, see `HardwareKeySender`);
/// 4. a key-up for a key that is not held is ignored;
/// 5. a key-up leaves the held set whatever its send does (the sender
///    retries it once on a stale connection);
/// 6. when the stream ends, every key still held is released, in
///    `HardwareKey.allCases` order (`HardwareKeySender.releaseAtEnd`);
/// 7. one consumer sends every event in order, each after the previous one
///    returned.
enum HardwareKeyInjector {
    /// Runs until `events` finishes. `reportError` receives failed sends;
    /// the queue keeps going.
    static func run(
        events: AsyncStream<HardwareKeyEvent>,
        stopSignal: KeyboardInjector.StopSignal,
        sender: HardwareKeySender,
        reportError: @escaping @Sendable (String) -> Void
    ) async {
        var held: Set<HardwareKey> = []
        for await event in events {
            if event.isDown {
                guard !stopSignal.isStopped, !held.contains(event.key) else { continue }
                held.insert(event.key)
            } else {
                guard held.remove(event.key) != nil else { continue }
            }
            do {
                try await sender.send(event)
            } catch {
                reportError("hardware key: \(error)")
            }
        }

        // The session stopped (or went away) with keys still down: the
        // mouse-up that would have released them can no longer arrive.
        for key in HardwareKey.allCases where held.contains(key) {
            try? await sender.releaseAtEnd(key)
        }
    }
}
