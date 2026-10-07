import Foundation

public struct BatteryInfo: Sendable, Equatable {
    public var level: Int
    public var isCharging: Bool
    public var chargerName: String
    public var statusName: String

    public init(level: Int, isCharging: Bool, chargerName: String, statusName: String) {
        self.level = level
        self.isCharging = isCharging
        self.chargerName = chargerName
        self.statusName = statusName
    }
}

public struct GpsFix: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public enum PostureKind: String, CaseIterable, Identifiable, Sendable {
    case closed
    case halfOpened
    case opened

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .closed: return "Closed"
        case .halfOpened: return "Half"
        case .opened: return "Opened"
        }
    }

    public var systemImage: String {
        switch self {
        case .closed: return "rectangle.portrait"
        case .halfOpened: return "chevron.up"
        case .opened: return "rectangle.split.2x1"
        }
    }

    /// The hinge angle range the posture covers, like Device Manager's cards.
    public var angleRange: String {
        switch self {
        case .closed: return "0–30°"
        case .halfOpened: return "30–150°"
        case .opened: return "150–180°"
        }
    }

    /// The hinge angle the posture settles at (degrees).
    public var hingeAngle: Double {
        switch self {
        case .closed: return 0
        case .halfOpened: return 90
        case .opened: return 180
        }
    }

    /// Maps the emulator's `Posture.PostureValue` enum.
    static func from(protobufValue: Int32) -> PostureKind? {
        switch protobufValue {
        case 1: return .closed
        case 2: return .halfOpened
        case 3: return .opened
        default: return nil
        }
    }

    public var protobufValue: Int32 {
        switch self {
        case .closed: return 1
        case .halfOpened: return 2
        case .opened: return 3
        }
    }
}

/// The device's appearance setting (`cmd uimode night`).
public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case light
    case dark
    case system

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }

    /// The token `cmd uimode night` accepts and prints for this mode.
    public var commandValue: String {
        switch self {
        case .light: return "no"
        case .dark: return "yes"
        case .system: return "auto"
        }
    }
}

/// What `cmd uimode night` answered. The command runs on API 23+ images, but
/// its answer is not always one of the three selectable modes: AOSP prints
/// `custom_schedule`, `custom_bedtime` or `unknown` for legitimate states
/// (dark on a schedule/bedtime, or a mode that was never set). Those are
/// answers, not failures — the app just cannot represent them.
public enum AppearanceReading: Sendable, Equatable {
    /// A mode the Controls popup can represent and select.
    case mode(AppearanceMode)
    /// The command answered with a mode outside Light/Dark/System; the raw
    /// token is kept so the Controls row can label it.
    case unmapped(String)
    /// The command answered with output that carries no mode at all.
    case unreadable

    /// The mode to preselect in the Controls popup, if any.
    public var mode: AppearanceMode? {
        if case .mode(let mode) = self { return mode }
        return nil
    }
}

/// Availability gate for the Controls inspector's Appearance row. Only a
/// *failing command* counts toward hiding the row: an answered read — even
/// an unrepresentable mode like `custom_schedule` — proves `cmd uimode night`
/// exists, so it keeps the row and clears any failure streak.
public struct AppearanceProbe: Sendable, Equatable {
    /// Consecutive command failures tolerated before the row is hidden.
    public static let failureLimit = 3

    public private(set) var consecutiveFailures = 0

    public init() {}

    /// Whether the Appearance row is shown. Hidden only when the command
    /// itself keeps failing (an image without `cmd uimode`).
    public var isAvailable: Bool { consecutiveFailures < Self.failureLimit }

    /// Records one read: an answer clears the streak, a command failure
    /// extends it.
    public mutating func record(_ result: Result<AppearanceReading, Error>) {
        switch result {
        case .success: consecutiveFailures = 0
        case .failure: consecutiveFailures += 1
        }
    }

    /// Starts over — used when the Controls panel moves to another device.
    public mutating func reset() { consecutiveFailures = 0 }
}

public struct DisplayInfo: Sendable, Equatable, Identifiable {
    public let id: UInt32
    public var width: Int
    public var height: Int
    public var dpi: Int

    public init(id: UInt32, width: Int, height: Int, dpi: Int) {
        self.id = id
        self.width = width
        self.height = height
        self.dpi = dpi
    }

    public var pixelCount: Int { width * height }
}

/// A form-factor preset of the resizable emulator (`adb emu resize-display`).
public struct ResizePreset: Sendable, Identifiable, Equatable {
    public let index: Int
    public let name: String

    public var id: Int { index }

    public init(index: Int, name: String) {
        self.index = index
        self.name = name
    }
}

/// A snapshot of emulator/device controls for the inspector panel.
public struct DeviceControlsState: Sendable {
    public var battery: BatteryInfo?
    public var location: GpsFix?
    public var posture: PostureKind?
    public var hingeAngle: Double?
    public var displays: [DisplayInfo] = []
    public var isBooted: Bool?
    /// Framework display rotation (`dumpsys display`); nil when unknown.
    public var displayRotation: Int?

    public var batterySaverEnabled: Bool?
    public var airplaneModeEnabled: Bool?
    public var wifiEnabled: Bool?
    public var bluetoothEnabled: Bool?
    public var mobileDataEnabled: Bool?
    public var dataSaverEnabled: Bool?
    /// Night-mode reading (`cmd uimode night`); nil while the device has not
    /// answered (unreachable, or a command failure on the last poll).
    public var appearance: AppearanceReading?

    public init() {}

    /// Every emulator answers posture and hinge-angle queries, so their mere
    /// presence does not mean foldable. A half-opened posture, however, is one
    /// a non-foldable never reports; the AVD's hinge sensor count is the other
    /// authoritative signal (see `AvdConfig.hingeCount`).
    public var isFoldable: Bool {
        posture == .halfOpened
    }

    public var innerDisplay: DisplayInfo? {
        displays.max { $0.pixelCount < $1.pixelCount }
    }

    public var outerDisplay: DisplayInfo? {
        guard displays.count > 1 else { return nil }
        return displays.min { $0.pixelCount < $1.pixelCount }
    }
}

public struct SavedLocation: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var latitude: Double
    public var longitude: Double

    public init(id: UUID = UUID(), name: String, latitude: Double, longitude: Double) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }

    public static let defaults: [SavedLocation] = [
        SavedLocation(name: "Ankara", latitude: 39.9334, longitude: 32.8597),
        SavedLocation(name: "İstanbul", latitude: 41.0082, longitude: 28.9784),
        SavedLocation(name: "İzmir", latitude: 38.4237, longitude: 27.1428),
        SavedLocation(name: "Paris", latitude: 48.8566, longitude: 2.3522),
        SavedLocation(name: "New York", latitude: 40.7128, longitude: -74.0060),
    ]
}
