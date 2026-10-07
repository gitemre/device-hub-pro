import Foundation

/// The properties of a simulator's Info tab and which of them show: Device
/// Hub's "Edit Visibility" (measured on DH 27.0, 2026-09-29, with a booted
/// iPhone 17 and a shut down Apple TV 4K simulator). The capsule under the
/// cards swaps the tab for a checklist of every property in five sections
/// (Essential, Device, Hardware and Connection Properties, then Device
/// Configuration's Displays) with a Done button; the ticked ones are what
/// the Info tab lists, regrouped by section, an empty section leaving no
/// card. The choice is one for every device (ticking CPU Type on an Apple TV
/// showed it on the iPhone as well) and is kept between launches.
enum SimulatorInfoProperty: String, CaseIterable, Sendable {
    case name, os, coreDeviceID
    case bootState, ddiServices
    case cpuType, model, platform, productType, fidelity, udid
    case lastConnectionDate, pairingState, transportType, tunnelState
    case display

    /// The sections, in order; a section's rows keep `allCases` order.
    enum Section: CaseIterable, Sendable {
        case essential, device, hardware, connection, displays

        /// The checklist's heading; the Displays section sits under "Device
        /// Configuration" with a "Displays" sub-heading.
        var title: String {
            switch self {
            case .essential: "Essential Properties"
            case .device: "Device Properties"
            case .hardware: "Hardware Properties"
            case .connection: "Connection Properties"
            case .displays: "Device Configuration"
            }
        }

        var subtitle: String? { self == .displays ? "Displays" : nil }

        var properties: [SimulatorInfoProperty] {
            SimulatorInfoProperty.allCases.filter { $0.section == self }
        }
    }

    var section: Section {
        switch self {
        case .name, .os, .coreDeviceID: .essential
        case .bootState, .ddiServices: .device
        case .cpuType, .model, .platform, .productType, .fidelity, .udid: .hardware
        case .lastConnectionDate, .pairingState, .transportType, .tunnelState: .connection
        case .display: .displays
        }
    }

    var title: String {
        switch self {
        case .name: "Name"
        case .os: "OS"
        case .coreDeviceID: "CoreDevice ID"
        case .bootState: "Boot State"
        case .ddiServices: "DDI Services"
        case .cpuType: "CPU Type"
        case .model: "Model"
        case .platform: "Platform"
        case .productType: "Product Type"
        case .fidelity: "Fidelity"
        case .udid: "UDID"
        case .lastConnectionDate: "Last Connection Date"
        case .pairingState: "Pairing State"
        case .transportType: "Transport Type"
        case .tunnelState: "Tunnel State"
        case .display: "Display"
        }
    }

    /// What a fresh install lists: Device Hub's own default Info tab.
    static let defaultVisible: Set<SimulatorInfoProperty> = [.name, .os, .model, .productType, .udid, .display]

    /// The persisted form: the raw names, sorted.
    static func encode(_ visible: Set<SimulatorInfoProperty>) -> [String] {
        visible.map(\.rawValue).sorted()
    }

    /// The stored choice; nil (never edited) is the default, and a name this
    /// build does not know is ignored.
    static func decode(_ stored: [String]?) -> Set<SimulatorInfoProperty> {
        guard let stored else { return defaultVisible }
        return Set(stored.compactMap(SimulatorInfoProperty.init(rawValue:)))
    }
}

/// The values of the properties for one simulator, as Device Hub words them
/// (`Booted` / `ShutDown`, `Enabled` / `Disabled`, `Connected` /
/// `Disconnected`, "Simulated", "Same Machine", "Paired").
struct SimulatorInfoValues: Equatable {
    var name: String
    var os: String?
    var udid: String
    var isBooted: Bool
    var model: String?
    var productType: String?
    var platform: String?
    var display: String?
    var lastUsed: Date?
    /// The host's CPU ("arm64").
    var cpuType: String

    /// The value of `property`, nil where the simulator has none (the row is
    /// then left out, as Device Hub leaves out a Last Connection Date the
    /// device never had).
    func value(of property: SimulatorInfoProperty, formatter: (Date) -> String = Self.dateString) -> String? {
        switch property {
        case .name: name
        case .os: os
        case .coreDeviceID: udid
        case .bootState: isBooted ? "Booted" : "ShutDown"
        case .ddiServices: isBooted ? "Enabled" : "Disabled"
        case .cpuType: cpuType
        case .model: model
        case .platform: platform
        case .productType: productType
        case .fidelity: "Simulated"
        case .udid: udid
        case .lastConnectionDate: lastUsed.map(formatter)
        case .pairingState: "Paired"
        case .transportType: "Same Machine"
        case .tunnelState: isBooted ? "Connected" : "Disconnected"
        case .display: display
        }
    }

    /// "29.09.2026, 16:30" in a Turkish locale: the short date, a comma and the
    /// short time.
    static func dateString(_ date: Date) -> String {
        let day = DateFormatter()
        day.dateStyle = .short
        day.timeStyle = .none
        let time = DateFormatter()
        time.dateStyle = .none
        time.timeStyle = .short
        return "\(day.string(from: date)), \(time.string(from: date))"
    }

    /// The Info tab's cards: one per section that has a visible row with a
    /// value, in order.
    func cards(visible: Set<SimulatorInfoProperty>) -> [[(property: SimulatorInfoProperty, value: String)]] {
        SimulatorInfoProperty.Section.allCases.compactMap { section in
            let rows: [(property: SimulatorInfoProperty, value: String)] = section.properties.compactMap { property in
                guard visible.contains(property) else { return nil }
                // An unread display shows two dashes, like Device Hub's.
                if property == .display { return (property, value(of: property) ?? "--") }
                return value(of: property).map { (property, $0) }
            }
            return rows.isEmpty ? nil : rows
        }
    }

    /// The host CPU as Device Hub names it.
    static var hostCPU: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }
}
