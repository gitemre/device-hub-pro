import Foundation
import DeviceHubProKit

/// One physical iPhone or iPad the lister returned, with what the app says
/// about it before anything is asked of the device itself: its
/// name, model and OS from the list, whether the user enabled it, and the
/// state the sidebar shows.
///
/// Everything here comes from `devicectl list devices`. No other command
/// reaches a device until `isEnabled`; `ApplePhysicalInventory.client(for:)`
/// is the only way to a `DevicectlPhysicalClient`, and it checks
/// `canUseClient`.
struct ApplePhysicalEntry: Identifiable, Equatable, Sendable {
    /// What the sidebar row and the stage say about the device.
    enum State: Equatable, Sendable {
        /// Listed, not yet chosen with "Use This Device…": nothing is sent.
        case notEnabled
        /// Not paired with this Mac: "Pair Nearby Device…" pairs it. Shown
        /// before "Not enabled", because a phone that is not paired cannot be
        /// used whether or not it was chosen.
        case unpaired
        /// Paired, not connected now (cable, network or a locked phone).
        case disconnected
        /// Paired and connected, Developer Mode is off (a step on the
        /// device).
        case developerModeOff
        /// A restart Device Hub Pro issued is in progress: the phone reports itself
        /// unavailable until it is back.
        case restarting
        case ready
    }

    let device: ApplePhysicalDevice
    /// The user enabled this device ("Use This Device…"), or the
    /// `DHP_IPHONE_UDID` switch names it.
    let isEnabled: Bool
    /// Whether `isEnabled` comes from `DHP_IPHONE_UDID` rather than the
    /// user's own choice: "Stop Using This Device" has nothing to remove.
    var isEnabledByLaunchOption = false
    /// A "Restart" we issued is in progress (`ApplePhysicalInventory.beginRestart`).
    var isRestarting = false

    /// The hardware UDID, upper-cased: the row's stable identity, the key of
    /// the preference and of `DeviceSelection.physicalApple`.
    var id: String { PhysicalDeviceOptIn.normalize(device.hardwareUDID) }
    var udid: String { id }

    var name: String {
        device.name ?? device.marketingName ?? device.productType ?? "Apple Device"
    }

    /// "iPhone 12", else the model identifier ("iPhone13,2").
    var modelName: String? { device.marketingName ?? device.productType }

    /// "27.0".
    var osVersion: String? { device.osVersion }

    /// "iOS 27.0" (an iPad reads iPadOS).
    var osLabel: String? {
        guard let osVersion else { return nil }
        return "\(isIPad ? "iPadOS" : "iOS") \(osVersion)"
    }

    var isIPad: Bool {
        (device.productType ?? device.marketingName ?? "").hasPrefix("iPad")
    }

    /// The sidebar glyph: the simulator rows' iPhone and iPad symbols.
    var symbolName: String {
        isIPad ? "ipad" : SimulatorEntry.iPhoneSymbol(forModelName: device.marketingName)
    }

    var state: State {
        if !isEnabled, !device.isPaired { return .unpaired }
        if !isEnabled { return .notEnabled }
        if isRestarting { return .restarting }
        if !device.isPaired { return .unpaired }
        if !device.isConnected { return .disconnected }
        if let mode = device.developerModeStatus, mode != "enabled" { return .developerModeOff }
        return .ready
    }

    /// The sidebar's subtitle and the stage's state pill.
    var stateLabel: String {
        switch state {
        case .notEnabled: "Not enabled"
        case .unpaired: "Unpaired"
        case .disconnected: "Disconnected"
        case .developerModeOff: "Developer Mode off"
        case .restarting: "Restarting\u{2026}"
        case .ready: "Ready"
        }
    }

    /// One line on what the user does next; nil when there is nothing to do.
    /// Pairing starts only from the Pair Nearby Device sheet, on the user's
    /// press; trust and Developer Mode are always the user's own steps on the
    /// phone.
    var hint: String? {
        switch state {
        case .notEnabled:
            "Choose Use This Device to let Device Hub Pro read and manage it."
        case .unpaired:
            "Choose Pair Nearby Device\u{2026} in the + menu to pair it. The phone also needs Developer Mode "
                + "(Settings \u{25B8} Privacy & Security \u{25B8} Developer Mode, then restart the phone)."
        case .disconnected:
            "Connect and unlock the device, then choose Refresh."
        case .developerModeOff:
            "Turn on Developer Mode in Settings > Privacy & Security on the device."
        case .restarting:
            "The device is restarting. It comes back in a minute or two."
        case .ready:
            nil
        }
    }

    /// Whether the device is enabled, paired and connected: the only case in
    /// which the app builds a `DevicectlPhysicalClient` for it. Developer
    /// Mode is not part of it, so the Info card can still read what
    /// CoreDevice answers and show why the rest is off.
    var canUseClient: Bool {
        isEnabled && !isRestarting && device.isPaired && device.isConnected
    }

    /// The row's trailing version text: "27.0".
    var sidebarVersion: String? { osVersion }

    /// Whether the device is present (connected): the sidebar treats it
    /// like a running device (Hide Stopped keeps it).
    var isPresent: Bool { device.isConnected || isRestarting }

    var summary: DeviceSummary {
        DeviceSummary(
            ref: .physicalApple(id),
            kind: .physical,
            name: name,
            osName: isIPad ? "iPadOS" : "iOS",
            osVersion: osVersion,
            model: modelName,
            runState: state == .ready ? .ready : (device.isConnected ? .unreachable : .stopped),
            isAvailable: true
        )
    }
}
