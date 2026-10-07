import Foundation
import os

/// The explicit permission to look at physical Apple devices. There are two
/// forms, and neither is ever implied:
///
/// - `init(allowedHardwareUDIDs:)`, the hardware UDIDs the caller names (a
///   dedicated test iPhone, `DHP_IPHONE_UDID` in the live tests and the
///   app's test switch). The lister returns only the devices named.
/// - `everyPhysicalDevice`, the app's user opt-in ("Show physical Apple
///   devices" in Settings): the lister returns every physical entry so the
///   sidebar can offer each one. Listing is all it permits; a command
///   reaches a device only through a `DevicectlPhysicalClient`, which the
///   app builds for a device the user enabled.
///
/// `ApplePhysicalDeviceLister` makes no call without an opt-in.
public struct PhysicalDeviceOptIn: Sendable, Equatable {
    private enum Scope: Sendable, Equatable {
        case named(Set<String>)
        case everyPhysicalDevice
    }

    private let scope: Scope

    /// The named UDIDs, upper-cased, trimmed, never empty; nil for
    /// `everyPhysicalDevice`.
    public var allowedHardwareUDIDs: Set<String>? {
        if case .named(let udids) = scope { return udids }
        return nil
    }

    /// Whether this opt-in lists every physical device.
    public var listsEveryPhysicalDevice: Bool { scope == .everyPhysicalDevice }

    /// nil when no non-empty UDID is given: an opt-in that names nothing
    /// allows nothing, so it is not a value.
    public init?(allowedHardwareUDIDs: some Sequence<String>) {
        let normalized = Set(allowedHardwareUDIDs.map(Self.normalize).filter { !$0.isEmpty })
        guard !normalized.isEmpty else { return nil }
        scope = .named(normalized)
    }

    private init(scope: Scope) {
        self.scope = scope
    }

    /// The app's user opt-in: every physical device is listed (never a
    /// simulator).
    public static let everyPhysicalDevice = PhysicalDeviceOptIn(scope: .everyPhysicalDevice)

    func allows(_ udid: String) -> Bool {
        switch scope {
        case .named(let udids): udids.contains(Self.normalize(udid))
        case .everyPhysicalDevice: true
        }
    }

    /// The form of a hardware UDID the opt-in and the app compare by.
    public static func normalize(_ udid: String) -> String {
        udid.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

/// One physical Apple device CoreDevice knows about, as the lister read it.
///
/// Only `ApplePhysicalDeviceLister` can create one (the initializer is
/// file-private), so a `DevicectlPhysicalClient` can only be bound to a
/// device that passed the opt-in and was not a simulator.
public struct ApplePhysicalDevice: Sendable, Equatable, Hashable {
    /// CoreDevice's identifier, a UUID: what `--device` is given.
    public let coreDeviceIdentifier: String
    /// The hardware UDID (25 characters on an iPhone 12, `00008101-…` style).
    public let hardwareUDID: String
    public let name: String?
    /// "iPhone13,2".
    public let productType: String?
    /// "iPhone 12".
    public let marketingName: String?
    public let osVersion: String?
    /// "paired", "unpaired", …
    public let pairingState: String?
    /// "connected", "disconnected", …
    public let tunnelState: String?
    /// "wired", "localNetwork", …
    public let transport: String?
    /// "enabled", "disabled", …
    public let developerModeStatus: String?
    /// Whether the Developer Disk Image services are available.
    public let ddiServicesAvailable: Bool?

    public var isPaired: Bool { pairingState == "paired" }
    /// Whether a command can reach the device now. CoreDevice opens a paired, cabled
    /// phone's tunnel only when a command asks for it and closes it again when idle,
    /// so such a phone lists "disconnected" while it sits on the cable (measured on
    /// iOS 27.0 / Xcode 27.0: `device info lockState` connected it, and the list said
    /// "disconnected" again a few seconds later). It counts as connected: "wired" is
    /// the cable itself (unplugged, the same phone lists "localNetwork" at once,
    /// measured). A network device still needs its tunnel up, and "unavailable" (a
    /// phone that is restarting) never counts.
    public var isConnected: Bool {
        tunnelState == "connected" || (isPaired && transport == "wired" && tunnelState == "disconnected")
    }

    /// An iPhone that CoreDevice sees and that is not paired with this Mac:
    /// what the Pair Nearby Device sheet offers (phones only for now). The
    /// state the list reports for one is `pairingState` "unpaired", reachable
    /// over the local network (HELP-DERIVED: no unpaired device was on hand
    /// to capture).
    public var isUnpairedPhone: Bool {
        !isPaired && (productType ?? marketingName ?? "").hasPrefix("iPhone")
    }

    fileprivate init(
        coreDeviceIdentifier: String,
        hardwareUDID: String,
        name: String?,
        productType: String?,
        marketingName: String?,
        osVersion: String?,
        pairingState: String?,
        tunnelState: String?,
        transport: String?,
        developerModeStatus: String?,
        ddiServicesAvailable: Bool?
    ) {
        self.coreDeviceIdentifier = coreDeviceIdentifier
        self.hardwareUDID = hardwareUDID
        self.name = name
        self.productType = productType
        self.marketingName = marketingName
        self.osVersion = osVersion
        self.pairingState = pairingState
        self.tunnelState = tunnelState
        self.transport = transport
        self.developerModeStatus = developerModeStatus
        self.ddiServicesAvailable = ddiServicesAvailable
    }
}

/// Lists physical Apple devices through `devicectl list devices`. This is
/// the only code in Device Hub Pro allowed to run that command.
///
/// - Without a `PhysicalDeviceOptIn` it makes no call at all
///   (`listCallCount` proves it).
/// - It drops every entry whose `hardwareProperties.reality` (or
///   `properties.hardware.reality`) is `simulated`, every entry that is not
///   `physical`, and every entry whose hardware UDID the opt-in does not
///   name. The the machine's simulators and any other phone never leave this type.
public struct ApplePhysicalDeviceLister: Sendable {
    public let devicectlURL: URL
    public let developerDirectory: URL?
    /// devicectl's `-t`; the process itself gets a few seconds more.
    public let commandTimeout: Duration

    public static let defaultTimeout: Duration = .seconds(30)

    private static let calls = OSAllocatedUnfairLock(initialState: 0)

    /// How many times this process has run `devicectl list devices`, counted
    /// before the process starts. Tests read it to prove that no opt-in means
    /// no call.
    public static var listCallCount: Int {
        calls.withLock { $0 }
    }

    public init(
        devicectlURL: URL,
        developerDirectory: URL? = nil,
        commandTimeout: Duration = ApplePhysicalDeviceLister.defaultTimeout
    ) {
        self.devicectlURL = devicectlURL
        self.developerDirectory = developerDirectory
        self.commandTimeout = commandTimeout
    }

    /// The opted-in physical devices, or `[]` without an opt-in (and without
    /// running devicectl).
    public func list(optIn: PhysicalDeviceOptIn?) async throws -> [ApplePhysicalDevice] {
        guard let optIn else { return [] }
        Self.calls.withLock { $0 += 1 }
        let output = DevicectlJSONFile.temporaryURL(purpose: "list")
        defer { DevicectlJSONFile.remove(output) }
        let seconds = max(1, Int(commandTimeout.components.seconds))
        let arguments = ["list", "devices", "--json-output", output.path, "-q", "-t", String(seconds)]
        let data = try await DevicectlJSONFile.run(
            devicectlURL: devicectlURL,
            arguments: arguments,
            jsonOutput: output,
            developerDirectory: developerDirectory,
            commandTimeout: commandTimeout,
            label: "list devices"
        )
        return try Self.devices(fromListJSON: data, optIn: optIn)
    }

    /// Parses a `list devices` document: physical entries whose hardware UDID
    /// the opt-in names, in document order.
    public static func devices(fromListJSON data: Data, optIn: PhysicalDeviceOptIn) throws -> [ApplePhysicalDevice] {
        let result = try DevicectlJSON.decode(ListResult.self, from: data).value
        return result.devices.compactMap { entry in
            guard let entry, let device = entry.device, optIn.allows(device.hardwareUDID) else { return nil }
            return device
        }
    }

    // MARK: Decoding

    private struct ListResult: Decodable, Sendable {
        let devices: [Entry?]

        private enum CodingKeys: String, CodingKey {
            case devices
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // One entry of an unexpected shape drops that entry, not the list.
            devices = try container.decodeIfPresent([Lossy<Entry>].self, forKey: .devices)?.map(\.value) ?? []
        }
    }

    private struct Lossy<Wrapped: Decodable>: Decodable {
        let value: Wrapped?

        init(from decoder: Decoder) throws {
            value = try? Wrapped(from: decoder)
        }
    }

    /// One `devices[]` entry: `properties` first, the deprecated blocks as a
    /// fallback (and for the fields `properties` lacks).
    private struct Entry: Decodable, Sendable {
        let identifier: String?
        let properties: Properties?
        let hardwareProperties: DeprecatedHardware?
        let deviceProperties: DeprecatedDevice?
        let connectionProperties: DeprecatedConnection?

        struct Properties: Decodable, Sendable {
            let hardware: Hardware?
            let software: Software?
            let state: State?
            let connection: Connection?

            struct Hardware: Decodable, Sendable {
                let udid: String?
                let ecid: UInt64?
                let reality: String?
                let marketingName: String?
                let productType: String?
            }

            struct Software: Decodable, Sendable {
                let osVersionNumber: Version?

                struct Version: Decodable, Sendable {
                    let stringValue: String?
                }
            }

            struct State: Decodable, Sendable {
                let name: String?
                /// `{"enabled": {"mode": 1}}`: the single key is the status.
                let developerModeStatus: [String: Lenient]?
            }

            struct Connection: Decodable, Sendable {
                let pairingState: String?
                let transportType: String?
                /// The connection state ("connected"); the deprecated block's
                /// `tunnelState` is preferred where present.
                let state: String?
            }
        }

        struct DeprecatedHardware: Decodable, Sendable {
            let udid: String?
            let ecid: UInt64?
            let reality: String?
            let marketingName: String?
            let productType: String?
        }

        struct DeprecatedDevice: Decodable, Sendable {
            let name: String?
            let osVersionNumber: String?
            let developerModeStatus: String?
            let ddiServicesAvailable: Bool?
        }

        struct DeprecatedConnection: Decodable, Sendable {
            let pairingState: String?
            let transportType: String?
            let tunnelState: String?
        }

        /// Accepts any JSON value; only the keys of the enclosing object are
        /// read.
        struct Lenient: Decodable, Sendable {
            init(from decoder: Decoder) throws {}
        }

        private enum CodingKeys: String, CodingKey {
            case identifier, properties, hardwareProperties, deviceProperties, connectionProperties
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
            // Each block is decoded on its own: a shape change in one must
            // not hide the values the others still carry.
            properties = try? container.decodeIfPresent(Properties.self, forKey: .properties)
            hardwareProperties = try? container.decodeIfPresent(DeprecatedHardware.self, forKey: .hardwareProperties)
            deviceProperties = try? container.decodeIfPresent(DeprecatedDevice.self, forKey: .deviceProperties)
            connectionProperties = try? container.decodeIfPresent(
                DeprecatedConnection.self,
                forKey: .connectionProperties
            )
        }

        /// The physical device this entry describes; nil for a simulator, for
        /// anything marked otherwise than `physical`, and for an entry without both
        /// identifiers. An unpaired phone carries no `reality` at all (captured on
        /// Xcode 27.0 / iOS 27.0 after `manage unpair`: hardware has its UDID, ECID
        /// and serial number, but no reality), so one without the field whose
        /// hardware has an ECID counts as physical: a simulator always says
        /// `simulated`, and has no ECID.
        var device: ApplePhysicalDevice? {
            let reality = properties?.hardware?.reality ?? hardwareProperties?.reality
            let hasECID = properties?.hardware?.ecid != nil || hardwareProperties?.ecid != nil
            guard reality == "physical" || (reality == nil && hasECID),
                  let identifier,
                  let udid = properties?.hardware?.udid ?? hardwareProperties?.udid
            else { return nil }
            return ApplePhysicalDevice(
                coreDeviceIdentifier: identifier,
                hardwareUDID: udid,
                name: properties?.state?.name ?? deviceProperties?.name,
                productType: properties?.hardware?.productType ?? hardwareProperties?.productType,
                marketingName: properties?.hardware?.marketingName ?? hardwareProperties?.marketingName,
                osVersion: properties?.software?.osVersionNumber?.stringValue ?? deviceProperties?.osVersionNumber,
                pairingState: properties?.connection?.pairingState ?? connectionProperties?.pairingState,
                tunnelState: connectionProperties?.tunnelState ?? properties?.connection?.state,
                transport: properties?.connection?.transportType ?? connectionProperties?.transportType,
                developerModeStatus: properties?.state?.developerModeStatus?.keys.sorted().first
                    ?? deviceProperties?.developerModeStatus,
                ddiServicesAvailable: deviceProperties?.ddiServicesAvailable
            )
        }
    }
}
