import Foundation

public struct DeviceInfo: Sendable {
    public let serial: String
    public let model: String
    public let manufacturer: String
    public let androidVersion: String
    public let apiLevel: String
    public let abi: String
    public let isEmulator: Bool
    /// `ro.build.characteristics`: the comma list the build declares its
    /// device class with ("emulator", "tablet", "watch", "tv", "automotive").
    public let characteristics: String
    /// The `feature:` names `pm list features` reports
    /// (`android.hardware.type.television`, ...). Empty until read. A TV
    /// image's `ro.build.characteristics` is only "emulator" (measured on
    /// the Google TV API 36 image), so the class also comes from here.
    public let features: Set<String>
    /// The name the device sells under (`ro.product.marketname`, or the
    /// vendor / odm copy), nil when the build sets none (emulators).
    public let marketName: String?

    public init(
        serial: String,
        model: String,
        manufacturer: String,
        androidVersion: String,
        apiLevel: String,
        abi: String,
        isEmulator: Bool,
        characteristics: String = "",
        features: Set<String> = [],
        marketName: String? = nil
    ) {
        self.serial = serial
        self.model = model
        self.manufacturer = manufacturer
        self.androidVersion = androidVersion
        self.apiLevel = apiLevel
        self.abi = abi
        self.isEmulator = isEmulator
        self.characteristics = characteristics
        self.features = features
        self.marketName = marketName
    }

    /// The kind of device the build declares (`formFactor(characteristics:)`).
    public var formFactor: SystemImage.FormFactor {
        Self.formFactor(characteristics: characteristics, features: features)
    }

    /// The device class from the characteristics, then from the hardware
    /// type features (`android.hardware.type.watch|television|automotive|
    /// desktop`), which the Google TV image declares where its
    /// characteristics do not.
    public static func formFactor(characteristics: String, features: Set<String>) -> SystemImage.FormFactor {
        let byCharacteristics = formFactor(characteristics: characteristics)
        if byCharacteristics != .handheld { return byCharacteristics }
        if features.contains("android.hardware.type.watch") { return .wear }
        if features.contains("android.hardware.type.television") { return .tv }
        if features.contains("android.hardware.type.automotive") { return .automotive }
        if features.contains("android.hardware.type.desktop") { return .desktop }
        return .handheld
    }

    /// The device class a `ro.build.characteristics` value names: its
    /// comma-separated tokens `watch`, `tv`, `automotive`, `desktop` and
    /// `xr`; anything else (phones, foldables, `tablet`) is handheld. A
    /// device the list does not classify (not read yet included) is handheld,
    /// the class every Controls row was built for.
    public static func formFactor(characteristics: String) -> SystemImage.FormFactor {
        let tokens = Set(
            characteristics.lowercased()
                .split(whereSeparator: { $0 == "," || $0.isWhitespace })
                .map(String.init)
        )
        if tokens.contains("watch") { return .wear }
        if tokens.contains("tv") { return .tv }
        if tokens.contains("automotive") { return .automotive }
        if tokens.contains("desktop") { return .desktop }
        if tokens.contains("xr") { return .xr }
        return .handheld
    }

    public static func from(
        serial: String,
        properties: [String: String],
        isEmulator: Bool,
        features: Set<String> = []
    ) -> DeviceInfo {
        DeviceInfo(
            serial: serial,
            model: properties["ro.product.model"] ?? "Unknown",
            manufacturer: properties["ro.product.manufacturer"] ?? "Unknown",
            androidVersion: properties["ro.build.version.release"] ?? "?",
            apiLevel: properties["ro.build.version.sdk"] ?? "?",
            abi: properties["ro.product.cpu.abi"] ?? "?",
            isEmulator: isEmulator,
            characteristics: properties["ro.build.characteristics"] ?? "",
            features: features,
            marketName: Self.marketName(from: properties)
        )
    }

    /// `ro.product.marketname`, else its vendor or odm copy; blank values
    /// count as none.
    static func marketName(from properties: [String: String]) -> String? {
        for key in ["ro.product.marketname", "ro.product.vendor.marketname", "ro.product.odm.marketname"] {
            if let value = properties[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty { return value }
        }
        return nil
    }
}
