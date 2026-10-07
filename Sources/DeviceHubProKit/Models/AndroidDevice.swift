import Foundation

public struct AndroidDevice: Sendable, Identifiable, Hashable {
    public let serial: String
    public let state: String
    public let model: String?
    public let product: String?
    public let device: String?
    public let transportID: String?
    /// The phone's `ro.serialno`, set on a row that stands for one physical
    /// device (`AndroidDeviceGrouping`); nil for an ungrouped entry.
    public let hardwareSerial: String?
    /// The other adb serials of the same physical device (its other
    /// transports), kept so a row can fall back to one when its active
    /// transport goes away.
    public let alternateSerials: [String]

    public init(
        serial: String,
        state: String,
        model: String? = nil,
        product: String? = nil,
        device: String? = nil,
        transportID: String? = nil,
        hardwareSerial: String? = nil,
        alternateSerials: [String] = []
    ) {
        self.serial = serial
        self.state = state
        self.model = model
        self.product = product
        self.device = device
        self.transportID = transportID
        self.hardwareSerial = hardwareSerial
        self.alternateSerials = alternateSerials
    }

    public var id: String { serial }
    public var isEmulator: Bool { serial.hasPrefix("emulator-") }
    public var isOnline: Bool { state == "device" }
    /// The name the phone sells under (`ro.product.marketname`, "Redmi Note
    /// 12 Pro"), read with its Info; nil until then and for an emulator.
    public var marketName: String?
    /// The marketing name when known, else adb's model code ("2209116AG").
    public var displayName: String { marketName ?? model ?? product ?? serial }

    public var stateLabel: String {
        switch state {
        case "device": return "Connected"
        case "offline": return "Offline"
        case "unauthorized": return "Unauthorized"
        default: return state.capitalized
        }
    }
}
