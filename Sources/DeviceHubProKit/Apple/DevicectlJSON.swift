import Foundation

/// The `info` block every devicectl JSON document carries.
///
/// devicectl's help promises that the JSON written with `-j` "is versioned
/// and will remain stable across releases"; its human-readable output is not.
/// `jsonVersion` is that version (5 on CoreDevice 642.16). It encodes back to
/// the same keys, so an answer can be kept (the app caches its T2 probe).
public struct DevicectlInfo: Codable, Sendable, Equatable {
    public let arguments: [String]
    public let commandType: String
    public let jsonVersion: Int
    /// "success" or "failed".
    public let outcome: String
    /// The CoreDevice version that answered, e.g. "642.16".
    public let version: String

    public var succeeded: Bool { outcome == "success" }
}

/// One error in a devicectl error chain.
public struct DevicectlErrorFrame: Sendable, Equatable {
    public let domain: String
    public let code: Int
    public let message: String?
    /// `CapabilityFeatureIdentifier` of a 1001 ("capability … is not
    /// supported") frame, e.g. `com.apple.coredevice.feature.audiooutput`.
    public let capabilityFeatureIdentifier: String?
    /// `CapabilityName` of the same frame ("Audio Output Device Selection").
    public let capabilityName: String?
    /// `NSLocalizedFailureReason`: the launch failure of 10002 says which
    /// application is not installed, the signal failure of 10014 that no such
    /// process exists.
    public let failureReason: String?

    public init(
        domain: String,
        code: Int,
        message: String?,
        capabilityFeatureIdentifier: String? = nil,
        capabilityName: String? = nil,
        failureReason: String? = nil
    ) {
        self.domain = domain
        self.code = code
        self.message = message
        self.capabilityFeatureIdentifier = capabilityFeatureIdentifier
        self.capabilityName = capabilityName
        self.failureReason = failureReason
    }
}

/// A devicectl command that failed, decoded from its JSON `error` block.
///
/// The block is an `NSError` rendering: `domain`, `code` and a `userInfo`
/// whose string values are wrapped as `{"string": …}` and whose
/// `NSUnderlyingError` holds the next error as `{"error": {…}}`. `frames`
/// flattens that chain, outermost first: a multi-flag `settings appearance`
/// call that fails reports 21031 ("Failed to set the device's appearance")
/// wrapping the flag's own error, such as 21063.
public struct DevicectlError: Error, Sendable, Equatable, CustomStringConvertible {
    public let info: DevicectlInfo?
    public let frames: [DevicectlErrorFrame]

    /// CoreDevice codes this build interprets (domain `com.apple.dt.CoreDeviceError`).
    public enum Code {
        /// "The specified device was not found": no device, or a simulator in
        /// a private `simctl --set`, which CoreDevice does not see.
        public static let deviceNotFound = 1000
        /// "The capability … is not supported by this device": `userInfo`
        /// names it in `CapabilityFeatureIdentifier` and `CapabilityName`.
        public static let capabilityNotSupported = 1001
        /// "The application failed to launch." (`process launch`; the failure
        /// reason names the cause, e.g. an application that is not installed).
        public static let applicationFailedToLaunch = 10002
        /// "Failed to send signal 15 to process …" (`process terminate`; no
        /// such process, or the process may already have terminated).
        public static let failedToSendSignal = 10014
        /// "Failed to set the device's appearance" (wraps the cause).
        public static let appearanceChangeFailed = 21031
        /// An accessibility text size needs Larger Accessibility Sizes first.
        public static let largerAccessibilitySizesRequired = 21063
    }

    public static let coreDeviceDomain = "com.apple.dt.CoreDeviceError"

    public var domain: String { frames.first?.domain ?? "" }
    public var code: Int { frames.first?.code ?? 0 }
    public var message: String { frames.first?.message ?? "" }

    /// Whether any error in the chain has this CoreDevice code.
    public func contains(code: Int, domain: String = DevicectlError.coreDeviceDomain) -> Bool {
        frames.contains { $0.code == code && $0.domain == domain }
    }

    public var description: String {
        frames.map { "\($0.message ?? "") (\($0.domain) \($0.code))" }.joined(separator: " ← ")
    }
}

/// A decoded devicectl answer: the `info` block plus the command's result.
public struct DevicectlResult<Value: Sendable>: Sendable {
    public let info: DevicectlInfo
    public let value: Value
}

/// `devicectl device info appearance`, and the `result` of `device settings
/// appearance` (which carries only what the call touched, so every field is
/// optional).
public struct DevicectlAppearance: Decodable, Sendable, Equatable {
    public let deviceIdentifier: String?
    /// "light" or "dark".
    public let userInterfaceStyle: String?
    /// The display name devicectl uses ("Large"), not simctl's token.
    public let textSize: String?
    public let increaseContrast: Bool?
    public let largerAccessibilitySizesEnabled: Bool?
    public let lookAndFeel: String?
    public let supportedLooksAndFeels: [String]?
    public let liquidGlassOpacity: Double?
    public let reduceMotion: Bool?
    public let reduceTransparency: Bool?
    /// "Show Borders" is iOS Button Shapes, not Android's layout bounds.
    public let showBorders: Bool?
    public let colorFilter: Bool?
    /// The filter's display name ("Grayscale", "Protanopia", "Deuteranopia",
    /// "Tritanopia"), present while a filter is on.
    public let colorFilterType: String?
    /// 0.25–1.0; absent for Grayscale, which has no intensity.
    public let colorFilterIntensity: Double?

    private enum CodingKeys: String, CodingKey {
        case deviceIdentifier, userInterfaceStyle, textSize, increaseContrast
        case largerAccessibilitySizesEnabled, lookAndFeel, supportedLooksAndFeels, liquidGlassOpacity
        case reduceMotion, reduceTransparency, showBorders, colorFilter
    }

    private struct Toggle: Decodable {
        let enabled: Bool?
    }

    /// `colorFilter`: `{"enabled": true, "filterType": {"name": "Deuteranopia"},
    /// "intensity": 0.6}` (CoreDevice 642.16), `{"enabled": false}` while off.
    private struct ColorFilter: Decodable {
        struct FilterType: Decodable {
            let name: String?
        }

        let enabled: Bool?
        let filterType: FilterType?
        let intensity: Double?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceIdentifier = try container.decodeIfPresent(String.self, forKey: .deviceIdentifier)
        userInterfaceStyle = try container.decodeIfPresent(String.self, forKey: .userInterfaceStyle)
        textSize = try container.decodeIfPresent(String.self, forKey: .textSize)
        increaseContrast = try container.decodeIfPresent(Bool.self, forKey: .increaseContrast)
        largerAccessibilitySizesEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .largerAccessibilitySizesEnabled
        )
        lookAndFeel = try container.decodeIfPresent(String.self, forKey: .lookAndFeel)
        supportedLooksAndFeels = try container.decodeIfPresent([String].self, forKey: .supportedLooksAndFeels)
        liquidGlassOpacity = try container.decodeIfPresent(Double.self, forKey: .liquidGlassOpacity)
        reduceMotion = try container.decodeIfPresent(Toggle.self, forKey: .reduceMotion)?.enabled
        reduceTransparency = try container.decodeIfPresent(Toggle.self, forKey: .reduceTransparency)?.enabled
        showBorders = try container.decodeIfPresent(Toggle.self, forKey: .showBorders)?.enabled
        let filter = try container.decodeIfPresent(ColorFilter.self, forKey: .colorFilter)
        colorFilter = filter?.enabled
        colorFilterType = filter?.filterType?.name
        colorFilterIntensity = filter?.intensity
    }
}

/// `devicectl device orientation get`.
public struct DevicectlOrientation: Decodable, Sendable, Equatable {
    public let deviceIdentifier: String?
    /// "portrait", "landscapeLeft", …, or "unknown" (an iPhone home screen
    /// that never rotated reports unknown).
    public let deviceOrientation: String?
    /// The last non-flat orientation.
    public let deviceOrientationNonFlat: String?
    public let deviceIsOrientationLocked: Bool?
}

/// One `capabilities[]` entry of `devicectl device info details`.
public struct DevicectlCapability: Decodable, Sendable, Hashable {
    public let featureIdentifier: String
    public let name: String
}

/// `devicectl device info details`, read from the current `properties`
/// dictionary first. CoreDevice 642.16 still writes the deprecated
/// `deviceProperties` / `hardwareProperties` blocks next to it (with a
/// `_deprecationNotice`); they are only a fallback, for a device or version
/// whose `properties` lacks a field.
public struct DevicectlDeviceDetails: Decodable, Sendable, Equatable {
    public let identifier: String
    public let name: String?
    /// "booted", "shutdown", …
    public let bootState: String?
    public let osVersion: String?
    public let osBuild: String?
    public let marketingName: String?
    public let productType: String?
    /// "iPhone", "iPad", …
    public let deviceType: String?
    public let platform: String?
    /// "simulated" for a simulator.
    public let reality: String?
    public let udid: String?
    /// The device's ECID (decimal digits), the serial number and the internal
    /// storage in bytes: the Device Hub-style Info card of a physical iPhone
    /// shows them, exactly as the device reports them. Nil for a
    /// simulator or where the document lacks them.
    public let ecid: String?
    public let serialNumber: String?
    public let internalStorageCapacity: Int64?
    public let supportedBiometrics: [String]
    /// "simulators" for a simulator.
    public let visibilityClass: String?
    public let capabilities: [DevicectlCapability]
    /// The device end of the CoreDevice tunnel (an `fd00::/8` address), while
    /// a physical device is connected through it: `properties.connection.
    /// tunnelIPAddressString`, else the deprecated `connectionProperties.
    /// tunnelIPAddress`. Only the iPhone control's runner is ever pointed at
    /// it; it is never shown, logged or stored.
    public let tunnelIPAddress: String?

    public var isSimulator: Bool { reality == "simulated" }

    public func supports(_ featureIdentifier: String) -> Bool {
        capabilities.contains { $0.featureIdentifier == featureIdentifier }
    }

    private enum CodingKeys: String, CodingKey {
        case identifier, properties, capabilities, visibilityClass
        case deviceProperties, hardwareProperties, connectionProperties
    }

    private struct Properties: Decodable {
        let hardware: Hardware?
        let software: Software?
        let state: State?
        let connection: Connection?

        struct Connection: Decodable {
            let tunnelIPAddressString: String?
        }

        struct Hardware: Decodable {
            let deviceType: String?
            let marketingName: String?
            let platform: String?
            let productType: String?
            let reality: String?
            let udid: String?
            let ecid: FlexibleNumber?
            let serialNumber: String?
            let internalStorageCapacity: Int64?
            let supportedBiometrics: [String]?
        }

        struct Software: Decodable {
            let osVersionNumber: Version?
            let osBuildVersions: BuildVersions?

            struct Version: Decodable {
                let stringValue: String?
            }

            struct BuildVersions: Decodable {
                let buildVersion: Build?

                struct Build: Decodable {
                    let name: String?
                }
            }
        }

        struct State: Decodable {
            let bootState: String?
            let name: String?
            let visibilityClass: String?
        }
    }

    private struct DeprecatedDeviceProperties: Decodable {
        let bootState: String?
        let name: String?
        let osBuildUpdate: String?
        let osVersionNumber: String?
    }

    private struct DeprecatedConnectionProperties: Decodable {
        let tunnelIPAddress: String?
    }

    private struct DeprecatedHardwareProperties: Decodable {
        let deviceType: String?
        let marketingName: String?
        let platform: String?
        let productType: String?
        let reality: String?
        let udid: String?
        let ecid: FlexibleNumber?
        let serialNumber: String?
        let internalStorageCapacity: Int64?
    }

    /// A number CoreDevice writes as a JSON number in one release and as a
    /// string in another; kept as decimal digits.
    private struct FlexibleNumber: Decodable {
        let text: String

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            // Never throws: an ECID of an unforeseen type must not fail the whole document.
            if let number = try? container.decode(UInt64.self) {
                text = String(number)
            } else {
                text = (try? container.decode(String.self)) ?? ""
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let properties = try container.decodeIfPresent(Properties.self, forKey: .properties)
        // Decoded leniently: a shape change in a deprecated block must not
        // fail a document whose current `properties` are fine.
        let legacyDevice = try? container.decodeIfPresent(DeprecatedDeviceProperties.self, forKey: .deviceProperties)
        let legacyHardware = try? container.decodeIfPresent(
            DeprecatedHardwareProperties.self,
            forKey: .hardwareProperties
        )
        let legacyConnection = try? container.decodeIfPresent(
            DeprecatedConnectionProperties.self,
            forKey: .connectionProperties
        )

        identifier = try container.decode(String.self, forKey: .identifier)
        name = properties?.state?.name ?? legacyDevice?.name
        bootState = properties?.state?.bootState ?? legacyDevice?.bootState
        osVersion = properties?.software?.osVersionNumber?.stringValue ?? legacyDevice?.osVersionNumber
        osBuild = properties?.software?.osBuildVersions?.buildVersion?.name ?? legacyDevice?.osBuildUpdate
        marketingName = properties?.hardware?.marketingName ?? legacyHardware?.marketingName
        productType = properties?.hardware?.productType ?? legacyHardware?.productType
        deviceType = properties?.hardware?.deviceType ?? legacyHardware?.deviceType
        platform = properties?.hardware?.platform ?? legacyHardware?.platform
        reality = properties?.hardware?.reality ?? legacyHardware?.reality
        udid = properties?.hardware?.udid ?? legacyHardware?.udid
        ecid = (properties?.hardware?.ecid ?? legacyHardware?.ecid).flatMap { $0.text.isEmpty ? nil : $0.text }
        serialNumber = properties?.hardware?.serialNumber ?? legacyHardware?.serialNumber
        internalStorageCapacity = properties?.hardware?.internalStorageCapacity ?? legacyHardware?.internalStorageCapacity
        supportedBiometrics = properties?.hardware?.supportedBiometrics ?? []
        let topLevelVisibility = try container.decodeIfPresent(String.self, forKey: .visibilityClass)
        visibilityClass = properties?.state?.visibilityClass ?? topLevelVisibility
        capabilities = try container.decodeIfPresent([DevicectlCapability].self, forKey: .capabilities) ?? []
        tunnelIPAddress = properties?.connection?.tunnelIPAddressString ?? legacyConnection?.tunnelIPAddress
    }
}

/// Decodes devicectl's JSON documents (`-j -` on stdout).
public enum DevicectlJSON {
    public enum DecodeError: Error, Equatable {
        /// stdout held no JSON document (a usage error prints only to stderr).
        case noDocument
        case malformed(String)
        /// `outcome` was "success" but there was no `result`.
        case missingResult(commandType: String)
    }

    /// The command's `result` as `Value`, or its decoded `DevicectlError`.
    public static func decode<Value: Decodable & Sendable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> DevicectlResult<Value> {
        guard !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) else {
            throw DecodeError.noDocument
        }
        let document: Document<Value>
        do {
            document = try JSONDecoder().decode(Document<Value>.self, from: data)
        } catch {
            throw DecodeError.malformed("\(error)")
        }
        if let error = document.error {
            throw DevicectlError(info: document.info, frames: error.frames)
        }
        guard document.info.succeeded, let result = document.result else {
            throw DecodeError.missingResult(commandType: document.info.commandType)
        }
        return DevicectlResult(info: document.info, value: result)
    }

    /// Only the `info` block (for a probe that needs `jsonVersion`).
    public static func info(from data: Data) throws -> DevicectlInfo {
        do {
            return try JSONDecoder().decode(InfoOnly.self, from: data).info
        } catch {
            throw DecodeError.malformed("\(error)")
        }
    }

    private struct InfoOnly: Decodable {
        let info: DevicectlInfo
    }

    private struct Document<Value: Decodable>: Decodable {
        let info: DevicectlInfo
        let result: Value?
        let error: ErrorPayload?
    }
}

/// The `error` object: an NSError with a wrapped `userInfo`.
private struct ErrorPayload: Decodable {
    let domain: String
    let code: Int
    let userInfo: [String: JSONValue]?

    var frames: [DevicectlErrorFrame] {
        var frames = [frame]
        var next = underlying
        // A chain deeper than a few links would be a malformed document;
        // the bound keeps a cyclic rendering from looping.
        var depth = 0
        while let current = next, depth < 16 {
            frames.append(current.frame)
            next = current.underlying
            depth += 1
        }
        return frames
    }

    private var message: String? {
        userInfo?["NSLocalizedDescription"]?.wrappedString
    }

    private var frame: DevicectlErrorFrame {
        DevicectlErrorFrame(
            domain: domain,
            code: code,
            message: message,
            capabilityFeatureIdentifier: userInfo?["CapabilityFeatureIdentifier"]?.wrappedString,
            capabilityName: userInfo?["CapabilityName"]?.wrappedString,
            failureReason: userInfo?["NSLocalizedFailureReason"]?.wrappedString
        )
    }

    private var underlying: ErrorPayload? {
        guard case .object(let wrapper)? = userInfo?["NSUnderlyingError"],
              let error = wrapper["error"]
        else { return nil }
        return error.errorPayload
    }
}

/// A JSON value, for devicectl's loosely typed `userInfo`.
private enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Double.self) {
            // Numbers first: error codes must never read as booleans.
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([JSONValue].self))
        }
    }

    /// devicectl wraps strings as `{"string": "…"}`.
    var wrappedString: String? {
        switch self {
        case .string(let value): return value
        case .object(let object):
            if case .string(let value)? = object["string"] { return value }
            return nil
        default: return nil
        }
    }

    var errorPayload: ErrorPayload? {
        guard case .object(let object) = self,
              case .string(let domain)? = object["domain"],
              case .number(let code)? = object["code"]
        else { return nil }
        var userInfo: [String: JSONValue]?
        if case .object(let info)? = object["userInfo"] {
            userInfo = info
        }
        return ErrorPayload(domain: domain, code: Int(code), userInfo: userInfo)
    }
}
