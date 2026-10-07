import Foundation

/// The properties of a physical iPhone's Info tab and which of them show:
/// Device Hub's rows (measured on Device Hub 27.0 with the test iPhone,
/// 2026-09-29, `r2-phone-inspector-info-dh-vs-ours.png`) plus Device Hub Pro's own
/// state rows, with the simulator Info tab's "Edit Visibility" mechanism
/// (`SimulatorInfoProperty`), kept under its own preference so a phone and
/// a simulator choose separately.
///
/// Device Hub's cards, in order: Name and OS; Capacity, ECID, Model, Product
/// Type, Serial Number and UDID; Display. The rows Device Hub Pro adds (OS Build,
/// Pairing, Connection, Developer Mode, Developer Disk Image, Lock State)
/// stay in the checklist, ticked off by default.
enum PhysicalInfoProperty: String, CaseIterable, Sendable {
    case name, os, osBuild
    case capacity, ecid, model, productType, serialNumber, udid
    case display
    case pairing, connection, developerMode, developerDiskImage, lockState

    /// The sections, in the order their cards show; a section's rows keep
    /// `allCases` order.
    enum Section: CaseIterable, Sendable {
        case essential, hardware, displays, connection

        var title: String {
            switch self {
            case .essential: "Essential Properties"
            case .hardware: "Hardware Properties"
            case .displays: "Device Configuration"
            case .connection: "Connection Properties"
            }
        }

        var subtitle: String? { self == .displays ? "Displays" : nil }

        var properties: [PhysicalInfoProperty] {
            PhysicalInfoProperty.allCases.filter { $0.section == self }
        }
    }

    var section: Section {
        switch self {
        case .name, .os, .osBuild: .essential
        case .capacity, .ecid, .model, .productType, .serialNumber, .udid: .hardware
        case .display: .displays
        case .pairing, .connection, .developerMode, .developerDiskImage, .lockState: .connection
        }
    }

    /// Device Hub's row names ("Product Type", "Display"), and ours for the
    /// state rows.
    var title: String {
        switch self {
        case .name: "Name"
        case .os: "OS"
        case .osBuild: "OS Build"
        case .capacity: "Capacity"
        case .ecid: "ECID"
        case .model: "Model"
        case .productType: "Product Type"
        case .serialNumber: "Serial Number"
        case .udid: "UDID"
        case .display: "Display"
        case .pairing: "Pairing"
        case .connection: "Connection"
        case .developerMode: "Developer Mode"
        case .developerDiskImage: "Developer Disk Image"
        case .lockState: "Lock State"
        }
    }

    /// What a fresh install lists: Device Hub's own rows. Device Hub Pro's extra
    /// state rows are ticked off.
    static let defaultVisible: Set<PhysicalInfoProperty> = [
        .name, .os, .capacity, .ecid, .model, .productType, .serialNumber, .udid, .display,
    ]

    /// The persisted form: the raw names, sorted.
    static func encode(_ visible: Set<PhysicalInfoProperty>) -> [String] {
        visible.map(\.rawValue).sorted()
    }

    /// The stored choice; nil (never edited) is the default, and a name this
    /// build does not know is ignored.
    static func decode(_ stored: [String]?) -> Set<PhysicalInfoProperty> {
        guard let stored else { return defaultVisible }
        return Set(stored.compactMap(PhysicalInfoProperty.init(rawValue:)))
    }
}
