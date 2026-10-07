import Foundation

/// The hardware of one simulator: its buttons, rotation and shake.
///
/// What was seen to work on an iOS 27.0 iPhone 17 Pro (CoreSimulator 1171.7):
///
/// | Action | Mechanism | Observed |
/// |---|---|---|
/// | `home()` | dtuhidd button 0x0C/0x40 | Home screen; unlocks a woken lock screen |
/// | `side()`, `lock()` | dtuhidd button 0x0C/0x30 | locks an unlocked device; pressed again, wakes it |
/// | `volumeUp()`, `volumeDown()` | dtuhidd buttons 0x0C/0xE9, 0x0C/0xEA | one step (1/16) each, read back from the simulator's `audiosettings.plist` a few seconds later |
/// | `siri()` | dtuhidd button 0x0C/0xCF | **not observed**: nothing on screen, short or held 1.5 s (Siri is not set up on a fresh simulator) |
/// | `rotate(to:)` | devicectl, else the Purple GSEvent | the interface turns (`uiOrientation` callback, `simctl io screenshot` 2622×1206) |
/// | `shake()` | `notifyutil -p com.apple.UIKit.SimulatorShake` | **experimental**: Safari offered "Undo Typing" |
///
/// The Purple lock-device GSEvent (type 1014) was sent without error but
/// changed nothing on iOS 27.0, so `lock()` presses the side button, which
/// toggles like the real one.
///
/// Every call waits for its bridge work on a private serial queue, never the
/// main queue. Buttons share the input rules of `SimulatorMirrorSession`: the
/// first press opens the dtuhidd connection (pass the session's own input
/// channel to share one connection, or let this make its own).
public final class SimulatorHardwareActions: Sendable {
    /// How a rotation was delivered.
    public enum RotationRoute: Sendable, Equatable {
        /// `devicectl device orientation set` (public; default-set simulators only).
        case devicectl
        /// The device-orientation GSEvent (private; any device set).
        case gsEvent
    }

    public let address: SimulatorAddress
    /// A tap's press length (idb holds buttons about as long).
    public static let defaultPress: Duration = .milliseconds(80)
    public static let shakeNotification = "com.apple.UIKit.SimulatorShake"
    /// The notify state dtuhidd sets to 1 when a client connects, for the
    /// rest of that boot: from then on legacy-Indigo clients (older idb,
    /// some agent tools) lose keyboard, buttons and touch on the simulator.
    /// Read it with `SimctlClient.notifyState`.
    public static let dtuhiddActiveNotification = "com.apple.coredevice.dtuhidd.active"

    private let bridge: any SimulatorBridging
    private let simctl: SimctlClient?
    private let devicectl: DevicectlClient?
    private let queue = DispatchQueue(label: "com.devicehubpro.simulator-hardware", qos: .userInitiated)
    private let channels: Channels

    /// Made on first use on `queue`.
    private final class Channels: @unchecked Sendable {
        private let lock = NSLock()
        private var input: (any SimulatorInputBridging)?
        private var gsEvents: (any SimulatorGSEventBridging)?

        init(input: (any SimulatorInputBridging)?) {
            self.input = input
        }

        func input(_ make: () -> any SimulatorInputBridging) -> any SimulatorInputBridging {
            lock.withLock {
                if let input { return input }
                let made = make()
                input = made
                return made
            }
        }

        func gsEvents(_ make: () -> any SimulatorGSEventBridging) -> any SimulatorGSEventBridging {
            lock.withLock {
                if let gsEvents { return gsEvents }
                let made = make()
                gsEvents = made
                return made
            }
        }
    }

    /// - Parameters:
    ///   - input: an input channel to share (a session's); nil makes one on first use.
    ///   - simctl: for `shake()`.
    ///   - devicectl: for `rotate(to:)`; only a default-set simulator has one
    ///     (CoreDevice does not see private sets). Without it, or when it
    ///     fails, rotation uses the GSEvent.
    public init(
        address: SimulatorAddress,
        bridge: any SimulatorBridging,
        input: (any SimulatorInputBridging)? = nil,
        simctl: SimctlClient? = nil,
        devicectl: DevicectlClient? = nil
    ) {
        self.address = address
        self.bridge = bridge
        self.simctl = simctl
        self.devicectl = devicectl
        self.channels = Channels(input: input)
    }

    public func home() async throws {
        try await press(.home)
    }

    /// Locks an unlocked device, or wakes a locked one: the side button.
    public func lock() async throws {
        try await press(.side)
    }

    public func side(hold: Duration = SimulatorHardwareActions.defaultPress) async throws {
        try await press(.side, hold: hold)
    }

    public func volumeUp() async throws {
        try await press(.volumeUp)
    }

    public func volumeDown() async throws {
        try await press(.volumeDown)
    }

    /// Not observed to do anything on a fresh iOS 27.0 simulator.
    public func siri(hold: Duration = SimulatorHardwareActions.defaultPress) async throws {
        try await press(.siri, hold: hold)
    }

    /// Presses `button` for `hold`, then flushes the events out.
    public func press(_ button: SimulatorHardwareButton, hold: Duration = SimulatorHardwareActions.defaultPress) async throws {
        let bridge = self.bridge
        let address = self.address
        let channels = self.channels
        let seconds = Double(hold.components.seconds) + Double(hold.components.attoseconds) / 1e18
        try await run {
            let input = channels.input { bridge.makeInput(for: address) }
            try input.send(.button(button, isDown: true))
            Thread.sleep(forTimeInterval: max(0, seconds))
            try input.send(.button(button, isDown: false))
            try input.flush(timeout: .seconds(2))
        }
    }

    /// Turns the simulated device. devicectl first (public), the GSEvent when
    /// there is no devicectl client or it failed.
    @discardableResult
    public func rotate(to orientation: SimulatorOrientation) async throws -> RotationRoute {
        if let devicectl {
            do {
                try await devicectl.setOrientation(orientation)
                return .devicectl
            } catch {
                // A private-set simulator is unknown to CoreDevice (error
                // 1000); fall through to the GSEvent.
            }
        }
        let bridge = self.bridge
        let address = self.address
        let channels = self.channels
        try await run {
            let events = channels.gsEvents { bridge.makeGSEvents(for: address) }
            try events.sendOrientation(orientation.gsEventValue)
        }
        return .gsEvent
    }

    /// Experimental: posts UIKit's simulator-shake notification. Apps that
    /// handle shake react (Safari offered "Undo Typing" on iOS 27.0).
    public func shake() async throws {
        guard let simctl else {
            throw SimulatorBridgeError(.invalidArgument, "shake needs a simctl client")
        }
        try await simctl.postDarwinNotification(udid: address.udid, name: Self.shakeNotification)
    }

    private func run(_ body: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }
}
