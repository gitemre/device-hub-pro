import DeviceHubProKit
import Foundation
import Observation

/// Device ▸ Keyboard ▸ Simulate Hardware Keyboard for simulators, as Device
/// Hub offers it: connected, iOS takes the keyboard as a hardware one and
/// hides its software keyboard; disconnected, the software keyboard shows.
/// Settings ▸ Keyboard ▸ Simulate hardware keyboard by default connects it
/// when a simulator's live canvas first starts in a boot.
///
/// CoreSimulator has no reading of the switch, so what Device Hub Pro set is
/// kept, for the boot it was set in (simctl's `lastUsedAt`, as the fold book
/// keys a boot); a simulator booted elsewhere and never switched here reads
/// as disconnected, as a simulator `simctl boot` started is.
@MainActor
@Observable
final class SimulatorHardwareKeyboardController {
    /// What Device Hub Pro set, by UDID, with the boot it was set in.
    private(set) var settings: [String: (connected: Bool, boot: Date?)] = [:]
    @ObservationIgnored private let simulators: SimulatorInventory
    @ObservationIgnored private let preferences: AppPreferences
    /// The boots the default was applied in, by UDID.
    @ObservationIgnored private var defaultApplied: [String: Date?] = [:]
    /// Sends the switch off the main thread; settable for tests.
    @ObservationIgnored var send: @Sendable (_ bridge: any SimulatorBridging, _ connected: Bool, _ address: SimulatorAddress) async throws -> Void = {
        bridge, connected, address in
        try await Task.detached { try bridge.setHardwareKeyboard(connected: connected, for: address) }.value
    }

    init(simulators: SimulatorInventory, preferences: AppPreferences) {
        self.simulators = simulators
        self.preferences = preferences
    }

    /// Whether the menu offers the switch for `udid`: a booted iOS simulator
    /// with the bridge loaded.
    func offers(_ udid: String) -> Bool {
        guard simulators.bridge != nil, let entry = simulators.entry(udid: udid) else { return false }
        return entry.device.state == .booted && entry.platform == "iOS"
    }

    /// Whether `udid`'s hardware keyboard is connected, as far as Device Hub
    /// Pro knows (what it set in this boot).
    func isConnected(_ udid: String) -> Bool {
        guard let setting = settings[udid], setting.boot == boot(of: udid) else { return false }
        return setting.connected
    }

    func setConnected(_ connected: Bool, udid: String) {
        guard let bridge = simulators.bridge else { return }
        let boot = boot(of: udid)
        let before = settings[udid]
        settings[udid] = (connected, boot)
        let address = SimulatorAddress(udid: udid, deviceSetPath: simulators.deviceSet?.path)
        Task { [weak self, send] in
            do {
                try await send(bridge, connected, address)
            } catch {
                // Not switched: the menu shows what the simulator has.
                guard let self, self.settings[udid]?.boot == boot else { return }
                self.settings[udid] = before
            }
        }
    }

    /// The simulator's live canvas started: the first time in a boot, the
    /// default setting connects the keyboard.
    func liveCanvasStarted(udid: String) {
        guard offers(udid) else { return }
        let boot = boot(of: udid)
        if let applied = defaultApplied[udid], applied == boot { return }
        defaultApplied[udid] = boot
        guard preferences.simulateHardwareKeyboardByDefault, settings[udid]?.boot != boot else { return }
        setConnected(true, udid: udid)
    }

    private func boot(of udid: String) -> Date? {
        simulators.entry(udid: udid)?.device.lastUsedAt
    }
}
