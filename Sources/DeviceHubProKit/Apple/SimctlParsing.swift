import Foundation

// MARK: - Models

/// A simulator's run state as `simctl list` and `device.plist` report it.
public enum SimulatorState: Sendable, Hashable {
    case creating
    case shutdown
    case booting
    case booted
    case shuttingDown
    /// A state this build does not know, kept verbatim.
    case other(String)

    /// The `state` string of `simctl list -j devices`, spelled exactly as
    /// simctl prints it.
    public init(listValue: String) {
        switch listValue {
        case "Creating": self = .creating
        case "Shutdown": self = .shutdown
        case "Booting": self = .booting
        case "Booted": self = .booted
        case "Shutting Down": self = .shuttingDown
        default: self = .other(listValue)
        }
    }

    /// The `state` integer of `Devices/<UDID>/device.plist`. Only 1 and 3 are
    /// ever persisted (measured: the transient states live in memory only).
    public init(plistValue: Int) {
        switch plistValue {
        case 0: self = .creating
        case 1: self = .shutdown
        case 2: self = .booting
        case 3: self = .booted
        case 4: self = .shuttingDown
        default: self = .other(String(plistValue))
        }
    }
}

/// One simulator from `simctl list -j devices`.
///
/// The initializer is internal on purpose: outside the Kit a device value can
/// only come from a `simctl list` read, which is what lets `DevicectlClient`
/// insist that every UDID it addresses is a listed simulator.
public struct SimulatorDevice: Sendable, Hashable, Identifiable {
    public let udid: String
    public let name: String
    public let state: SimulatorState
    public let isAvailable: Bool
    /// Why the device is unavailable (a missing runtime), when it is.
    public let availabilityError: String?
    public let deviceTypeIdentifier: String?
    /// The runtime the listing grouped the device under.
    public let runtimeIdentifier: String
    public let dataPath: String?
    public let logPath: String?
    public let dataPathSize: Int64?
    /// Absent until the device has written logs.
    public let logPathSize: Int64?
    /// Absent until the device has been booted once.
    public let lastUsedAt: Date?

    public var id: String { udid }
    public var isBooted: Bool { state == .booted }

    init(
        udid: String,
        name: String,
        state: SimulatorState,
        isAvailable: Bool,
        availabilityError: String? = nil,
        deviceTypeIdentifier: String?,
        runtimeIdentifier: String,
        dataPath: String? = nil,
        logPath: String? = nil,
        dataPathSize: Int64? = nil,
        logPathSize: Int64? = nil,
        lastUsedAt: Date? = nil
    ) {
        self.udid = udid
        self.name = name
        self.state = state
        self.isAvailable = isAvailable
        self.availabilityError = availabilityError
        self.deviceTypeIdentifier = deviceTypeIdentifier
        self.runtimeIdentifier = runtimeIdentifier
        self.dataPath = dataPath
        self.logPath = logPath
        self.dataPathSize = dataPathSize
        self.logPathSize = logPathSize
        self.lastUsedAt = lastUsedAt
    }
}

/// One runtime from `simctl list -j runtimes`.
public struct SimulatorRuntime: Sendable, Hashable, Identifiable {
    public let identifier: String
    public let name: String
    public let version: String
    public let buildVersion: String
    /// "iOS", "tvOS", …
    public let platform: String?
    public let isAvailable: Bool
    public let isInternal: Bool
    public let availabilityError: String?
    public let bundlePath: String?
    /// The device types this runtime can run, in the listing's order.
    public let supportedDeviceTypeIdentifiers: [String]

    public var id: String { identifier }

    public init(
        identifier: String,
        name: String,
        version: String,
        buildVersion: String,
        platform: String?,
        isAvailable: Bool,
        isInternal: Bool = false,
        availabilityError: String? = nil,
        bundlePath: String? = nil,
        supportedDeviceTypeIdentifiers: [String] = []
    ) {
        self.identifier = identifier
        self.name = name
        self.version = version
        self.buildVersion = buildVersion
        self.platform = platform
        self.isAvailable = isAvailable
        self.isInternal = isInternal
        self.availabilityError = availabilityError
        self.bundlePath = bundlePath
        self.supportedDeviceTypeIdentifiers = supportedDeviceTypeIdentifiers
    }
}

/// One device type from `simctl list -j devicetypes`.
public struct SimulatorDeviceType: Sendable, Hashable, Identifiable {
    public let identifier: String
    public let name: String
    /// "iPhone", "iPad", "Apple TV", "Apple Watch", …
    public let productFamily: String?
    /// The hardware model, e.g. "iPhone19,2".
    public let modelIdentifier: String?
    public let minRuntimeVersion: String?
    public let maxRuntimeVersion: String?
    public let bundlePath: String?

    public var id: String { identifier }

    public init(
        identifier: String,
        name: String,
        productFamily: String?,
        modelIdentifier: String? = nil,
        minRuntimeVersion: String? = nil,
        maxRuntimeVersion: String? = nil,
        bundlePath: String? = nil
    ) {
        self.identifier = identifier
        self.name = name
        self.productFamily = productFamily
        self.modelIdentifier = modelIdentifier
        self.minRuntimeVersion = minRuntimeVersion
        self.maxRuntimeVersion = maxRuntimeVersion
        self.bundlePath = bundlePath
    }
}

/// One installed app from `simctl listapps` / `simctl appinfo`.
public struct SimulatorApp: Sendable, Hashable, Identifiable {
    public let bundleIdentifier: String
    public let displayName: String?
    public let bundleName: String?
    public let executable: String?
    public let shortVersion: String?
    public let version: String?
    /// "System" or "User".
    public let applicationType: String?
    /// The `.app` bundle on the host.
    public let path: String?
    public let dataContainer: URL?
    public let groupContainers: [String: URL]
    public let isAppClip: Bool
    public let isDeveloperApp: Bool
    public let isFirstParty: Bool
    public let isHidden: Bool
    public let isRemovable: Bool
    public let tags: [String]

    public var id: String { bundleIdentifier }
    /// The name SpringBoard shows.
    public var title: String { displayName ?? bundleName ?? bundleIdentifier }
    public var isUserApp: Bool { applicationType == "User" }
}

/// `simctl ui <udid> appearance` without a value.
public enum SimulatorAppearance: String, Sendable, CaseIterable {
    case light, dark, unsupported, unknown
}

/// `simctl ui <udid> increase_contrast` without a value.
public enum SimulatorIncreaseContrast: String, Sendable, CaseIterable {
    case enabled, disabled, unsupported, unknown
}

/// `simctl ui <udid> content_size`: the preferred content size category.
public enum SimulatorContentSize: String, Sendable, CaseIterable {
    case extraSmall = "extra-small"
    case small
    case medium
    case large
    case extraLarge = "extra-large"
    case extraExtraLarge = "extra-extra-large"
    case extraExtraExtraLarge = "extra-extra-extra-large"
    case accessibilityMedium = "accessibility-medium"
    case accessibilityLarge = "accessibility-large"
    case accessibilityExtraLarge = "accessibility-extra-large"
    case accessibilityExtraExtraLarge = "accessibility-extra-extra-large"
    case accessibilityExtraExtraExtraLarge = "accessibility-extra-extra-extra-large"
    case unknown
    case unsupported

    /// The twelve categories simctl accepts as a value (`unknown` and
    /// `unsupported` are read-only answers).
    public static let settable: [SimulatorContentSize] = Array(allCases.prefix(12))

    public var isAccessibilitySize: Bool { rawValue.hasPrefix("accessibility-") }
}

/// The status-bar data network, as `status_bar override --dataNetwork` takes it.
public enum SimulatorDataNetwork: String, Sendable, CaseIterable {
    case hide
    case wifi
    case threeG = "3g"
    case fourG = "4g"
    case lte
    case lteA = "lte-a"
    case ltePlus = "lte+"
    case fiveG = "5g"
    case fiveGPlus = "5g+"
    case fiveGUWB = "5g-uwb"
    case fiveGUC = "5g-uc"

    /// The number `status_bar list` prints for it (measured on Xcode 27.0).
    /// `hide` and `wifi` both print 0 and cannot be told apart.
    public var listCode: Int {
        switch self {
        case .hide, .wifi: return 0
        case .threeG: return 6
        case .fourG: return 7
        case .lte: return 8
        case .lteA: return 9
        case .ltePlus: return 10
        case .fiveG: return 11
        case .fiveGPlus: return 12
        case .fiveGUWB: return 13
        case .fiveGUC: return 14
        }
    }
}

/// Wi-Fi mode for `status_bar override --wifiMode`; `list` prints 1–3.
public enum SimulatorWiFiMode: String, Sendable, CaseIterable {
    case searching, failed, active

    public init?(listCode: Int) {
        switch listCode {
        case 1: self = .searching
        case 2: self = .failed
        case 3: self = .active
        default: return nil
        }
    }
}

/// Cellular mode for `status_bar override --cellularMode`; `list` prints 0–3.
public enum SimulatorCellularMode: String, Sendable, CaseIterable {
    case notSupported, searching, failed, active

    public init?(listCode: Int) {
        switch listCode {
        case 0: self = .notSupported
        case 1: self = .searching
        case 2: self = .failed
        case 3: self = .active
        default: return nil
        }
    }
}

/// Battery state for `status_bar override --batteryState`; `list` prints 0–2.
public enum SimulatorBatteryState: String, Sendable, CaseIterable {
    case discharging, charging, charged

    public init?(listCode: Int) {
        switch listCode {
        case 0: self = .discharging
        case 1: self = .charging
        case 2: self = .charged
        default: return nil
        }
    }
}

/// The overrides `status_bar <udid> list` reports. Enumerations come back as
/// numbers; the typed accessors decode the measured mapping. A field that
/// was never overridden is nil, but simctl resets fields per group (setting
/// `--wifiMode` alone also sets the bars), so callers keep their own model of
/// what they asked for rather than trusting this read-back.
public struct SimulatorStatusBarOverrides: Sendable, Equatable {
    public var time: String?
    public var dataNetworkCode: Int?
    public var wifiModeCode: Int?
    public var wifiBars: Int?
    public var cellularModeCode: Int?
    public var cellularBars: Int?
    public var operatorName: String?
    public var batteryStateCode: Int?
    public var batteryLevel: Int?
    public var notCharging: Int?

    public init() {}

    public var isEmpty: Bool { self == SimulatorStatusBarOverrides() }
    public var wifiMode: SimulatorWiFiMode? { wifiModeCode.flatMap(SimulatorWiFiMode.init(listCode:)) }
    public var cellularMode: SimulatorCellularMode? {
        cellularModeCode.flatMap(SimulatorCellularMode.init(listCode:))
    }
    public var batteryState: SimulatorBatteryState? {
        batteryStateCode.flatMap(SimulatorBatteryState.init(listCode:))
    }
    /// The data network, or nil for 0 (hide and wifi share it) and unknown codes.
    public var dataNetwork: SimulatorDataNetwork? {
        guard let code = dataNetworkCode, code != 0 else { return nil }
        return SimulatorDataNetwork.allCases.first { $0.listCode == code }
    }
}

/// One update from `simctl bootstatus`.
public struct SimulatorBootStatus: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case waitingOnBackBoard
        case waitingOnDataMigration
        case waitingOnSystemApp
        case finished
        case other(String)

        init(_ text: String) {
            switch text {
            case "Waiting on BackBoard": self = .waitingOnBackBoard
            case "Waiting on Data Migration": self = .waitingOnDataMigration
            case "Waiting on System App": self = .waitingOnSystemApp
            case "Finished": self = .finished
            default: self = .other(text)
            }
        }
    }

    /// The bracketed UTC timestamp, verbatim ("2026-09-25 12:04:51 +0000").
    public let timestamp: String
    /// CoreSimulator's numeric status; 4294967295 accompanies Finished.
    public let status: UInt64
    public let isTerminal: Bool
    public let elapsedSeconds: Int
    public let phase: Phase?
    /// The data-migration reason ("Gathering plugins", "Running plugin …").
    public let reason: String?

    public var isFinished: Bool { isTerminal && phase == .finished }
}

/// One predefined location scenario from `simctl location <udid> list`.
public struct SimulatorLocationScenario: Sendable, Equatable {
    public let name: String
    public let description: String
}

/// One App Group container from `simctl get_app_container … groups`.
public struct SimulatorGroupContainer: Sendable, Equatable {
    public let identifier: String
    public let path: String
}

// MARK: - Parsers

/// Pure parsers for the simctl output Device Hub Pro reads. Each takes exactly
/// what the command printed; none of them runs a process.
public enum SimctlParsing {
    public enum ParseError: Error, Equatable {
        case notJSON(String)
        case notAPropertyList(String)
        case unexpectedShape(String)
    }

    // MARK: list -j

    /// `simctl list -j devices`: every device of every runtime. The listing
    /// is a JSON object keyed by runtime, which has no order, so the result is
    /// sorted by runtime identifier, then name, then UDID.
    public static func devices(fromListJSON data: Data) throws -> [SimulatorDevice] {
        let listing: DeviceListing
        do {
            listing = try JSONDecoder().decode(DeviceListing.self, from: data)
        } catch {
            throw ParseError.notJSON("\(error)")
        }
        var devices: [SimulatorDevice] = []
        for (runtime, entries) in listing.devices {
            for entry in entries {
                devices.append(SimulatorDevice(
                    udid: entry.udid,
                    name: entry.name,
                    state: SimulatorState(listValue: entry.state),
                    isAvailable: entry.isAvailable ?? false,
                    availabilityError: entry.availabilityError,
                    deviceTypeIdentifier: entry.deviceTypeIdentifier,
                    runtimeIdentifier: runtime,
                    dataPath: entry.dataPath,
                    logPath: entry.logPath,
                    dataPathSize: entry.dataPathSize,
                    logPathSize: entry.logPathSize,
                    lastUsedAt: entry.lastUsedAt.flatMap(parseISO8601)
                ))
            }
        }
        return devices.sorted {
            ($0.runtimeIdentifier, $0.name, $0.udid) < ($1.runtimeIdentifier, $1.name, $1.udid)
        }
    }

    /// `simctl list -j runtimes`, in the listing's order.
    public static func runtimes(fromListJSON data: Data) throws -> [SimulatorRuntime] {
        let listing: RuntimeListing
        do {
            listing = try JSONDecoder().decode(RuntimeListing.self, from: data)
        } catch {
            throw ParseError.notJSON("\(error)")
        }
        return listing.runtimes.map { entry in
            SimulatorRuntime(
                identifier: entry.identifier,
                name: entry.name,
                version: entry.version,
                buildVersion: entry.buildversion ?? "",
                platform: entry.platform,
                isAvailable: entry.isAvailable ?? false,
                isInternal: entry.isInternal ?? false,
                availabilityError: entry.availabilityError,
                bundlePath: entry.bundlePath,
                supportedDeviceTypeIdentifiers: (entry.supportedDeviceTypes ?? []).map(\.identifier)
            )
        }
    }

    /// `simctl list -j devicetypes`, in the listing's order.
    public static func deviceTypes(fromListJSON data: Data) throws -> [SimulatorDeviceType] {
        let listing: DeviceTypeListing
        do {
            listing = try JSONDecoder().decode(DeviceTypeListing.self, from: data)
        } catch {
            throw ParseError.notJSON("\(error)")
        }
        return listing.devicetypes.map(\.model)
    }

    // MARK: Apps

    /// `simctl listapps <udid>`: an OpenStep property list keyed by bundle
    /// identifier, sorted here by bundle identifier. Every scalar in that
    /// format is a string (`IsHidden = 0;`), so flags are read as "1"/"0".
    public static func apps(fromListApps text: String) throws -> [SimulatorApp] {
        guard let root = try propertyList(text) as? [String: Any] else {
            throw ParseError.unexpectedShape("listapps is not a dictionary")
        }
        return root.keys.sorted().compactMap { key in
            (root[key] as? [String: Any]).map { app(from: $0, fallbackIdentifier: key) }
        }
    }

    /// `simctl appinfo <udid> <bundle>`: one app's dictionary.
    public static func app(fromAppInfo text: String) throws -> SimulatorApp {
        guard let dictionary = try propertyList(text) as? [String: Any] else {
            throw ParseError.unexpectedShape("appinfo is not a dictionary")
        }
        return app(from: dictionary, fallbackIdentifier: "")
    }

    /// `simctl get_app_container <udid> <bundle> groups`: one
    /// `identifier<TAB>path` line per App Group, in the printed order.
    public static func groupContainers(from text: String) -> [SimulatorGroupContainer] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return SimulatorGroupContainer(identifier: String(parts[0]), path: String(parts[1]))
        }
    }

    /// The pid from `simctl launch`'s `<bundle>: <pid>` line.
    public static func launchedPID(from text: String) -> Int? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = line.lastIndex(of: ":") else { return nil }
        return Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    /// The UDID `simctl create` / `clone` prints.
    public static func createdUDID(from text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return UUID(uuidString: value) == nil ? nil : value
    }

    // MARK: ui

    public static func appearance(from text: String) -> SimulatorAppearance? {
        SimulatorAppearance(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func increaseContrast(from text: String) -> SimulatorIncreaseContrast? {
        SimulatorIncreaseContrast(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func contentSize(from text: String) -> SimulatorContentSize? {
        SimulatorContentSize(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: status_bar

    /// `simctl status_bar <udid> list`: the header, a rule, then one line per
    /// overridden group (`WiFi Mode: 3, WiFi Bars: 3`).
    public static func statusBarOverrides(from text: String) -> SimulatorStatusBarOverrides {
        var result = SimulatorStatusBarOverrides()
        for line in text.split(whereSeparator: \.isNewline) {
            // `Time: 09:41` has a colon in its value, so fields split on ", "
            // and each field only on its first ": ".
            for field in line.components(separatedBy: ", ") {
                guard let separator = field.range(of: ": ") else { continue }
                let key = field[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
                let value = String(field[separator.upperBound...])
                switch key {
                case "Time": result.time = value
                case "DataNetworkType": result.dataNetworkCode = Int(value)
                case "WiFi Mode": result.wifiModeCode = Int(value)
                case "WiFi Bars": result.wifiBars = Int(value)
                case "Cell Mode": result.cellularModeCode = Int(value)
                case "Cell Bars": result.cellularBars = Int(value)
                case "Operator Name": result.operatorName = value
                case "Battery State": result.batteryStateCode = Int(value)
                case "Battery Level": result.batteryLevel = Int(value)
                case "Not Charging": result.notCharging = Int(value)
                default: continue
                }
            }
        }
        return result
    }

    // MARK: location

    /// `simctl location <udid> list`: a `Name  Description` table under a
    /// rule; columns are separated by runs of two or more spaces.
    public static func locationScenarios(from text: String) -> [SimulatorLocationScenario] {
        var scenarios: [SimulatorLocationScenario] = []
        var pastRule = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if !pastRule {
                pastRule = line.hasPrefix("===")
                continue
            }
            let columns = line
                .components(separatedBy: "  ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard let name = columns.first else { continue }
            scenarios.append(SimulatorLocationScenario(
                name: name,
                description: columns.dropFirst().joined(separator: " ")
            ))
        }
        return scenarios
    }

    // MARK: bootstatus

    /// Every update in a complete `simctl bootstatus` output.
    public static func bootStatuses(from text: String) -> [SimulatorBootStatus] {
        var parser = SimulatorBootStatusParser()
        var updates: [SimulatorBootStatus] = []
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            updates += parser.consume(String(line))
        }
        return updates + parser.finish()
    }

    // MARK: spawn notifyutil -g

    /// `simctl spawn <udid> notifyutil -g <name>`: one `<name> <state>` line
    /// (`com.apple.coredevice.dtuhidd.active 0`). Nil when no line names it
    /// with a number.
    public static func notifyState(fromNotifyutilOutput text: String, name: String) -> UInt64? {
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count == 2, fields[0] == name, let state = UInt64(fields[1]) {
                return state
            }
        }
        return nil
    }

    // MARK: spawn launchctl list

    /// `simctl spawn <udid> launchctl list`: a `PID<TAB>Status<TAB>Label`
    /// header, then one job per line, in launchd's order. A job that is
    /// loaded but not running has `-` for its pid.
    public static func launchdJobs(fromLaunchctlList text: String) -> [SimulatorLaunchdJob] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, fields[2] != "Label" else { return nil }
            return SimulatorLaunchdJob(pid: Int(fields[0]), status: Int(fields[1]), label: String(fields[2]))
        }
    }

    // MARK: device_set.plist

    /// The UDIDs a set's `device_set.plist` lists under `DefaultDevices`: the
    /// devices CoreSimulator created by itself, one per runtime and device
    /// type (Device Hub hides those until they are first used). The
    /// dictionary is keyed by runtime, then device type; it also holds a
    /// `version` number beside the runtimes. A file that cannot be read gives
    /// no defaults (a private set has no such file until something writes it).
    public static func defaultDeviceUDIDs(fromDeviceSetPlist data: Data) -> Set<String> {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any],
              let defaults = root["DefaultDevices"] as? [String: Any]
        else { return [] }
        var udids: Set<String> = []
        for case let byDeviceType as [String: Any] in defaults.values {
            for case let udid as String in byDeviceType.values where UUID(uuidString: udid) != nil {
                udids.insert(udid)
            }
        }
        return udids
    }

    /// The platform and version a runtime identifier spells
    /// (`com.apple.CoreSimulator.SimRuntime.iOS-27-0` → "iOS", "27.0"), for a
    /// device whose runtime the runtime listing no longer has.
    public static func runtimePlatformAndVersion(identifier: String) -> (platform: String, version: String)? {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        guard identifier.hasPrefix(prefix) else { return nil }
        let parts = identifier.dropFirst(prefix.count).split(separator: "-")
        guard parts.count >= 2, parts.dropFirst().allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        return (String(parts[0]), parts.dropFirst().joined(separator: "."))
    }

    // MARK: device.plist

    /// The `state` of a `Devices/<UDID>/device.plist`, read without a process.
    public static func devicePlistState(_ data: Data) -> SimulatorState? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any],
              let state = dictionary["state"] as? Int
        else { return nil }
        return SimulatorState(plistValue: state)
    }

    // MARK: Helpers

    private static func propertyList(_ text: String) throws -> Any {
        do {
            return try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil)
        } catch {
            throw ParseError.notAPropertyList("\(error)")
        }
    }

    private static func app(from dictionary: [String: Any], fallbackIdentifier: String) -> SimulatorApp {
        func string(_ key: String) -> String? {
            switch dictionary[key] {
            case let value as String: return value
            case let value as NSNumber: return value.stringValue
            default: return nil
            }
        }
        func flag(_ key: String) -> Bool {
            switch dictionary[key] {
            case let value as String: return value == "1" || value.lowercased() == "true"
            case let value as NSNumber: return value.boolValue
            default: return false
            }
        }
        var groups: [String: URL] = [:]
        for (identifier, value) in dictionary["GroupContainers"] as? [String: Any] ?? [:] {
            if let text = value as? String, let url = URL(string: text) {
                groups[identifier] = url
            }
        }
        return SimulatorApp(
            bundleIdentifier: string("CFBundleIdentifier") ?? fallbackIdentifier,
            displayName: string("CFBundleDisplayName"),
            bundleName: string("CFBundleName"),
            executable: string("CFBundleExecutable"),
            shortVersion: string("CFBundleShortVersionString"),
            version: string("CFBundleVersion"),
            applicationType: string("ApplicationType"),
            path: string("Path"),
            dataContainer: string("DataContainer").flatMap(URL.init(string:)),
            groupContainers: groups,
            isAppClip: flag("IsAppClip"),
            isDeveloperApp: flag("IsDeveloperApp"),
            isFirstParty: flag("IsFirstParty"),
            isHidden: flag("IsHidden"),
            isRemovable: flag("IsRemovable"),
            tags: dictionary["SBAppTags"] as? [String] ?? []
        )
    }

    private static func parseISO8601(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }
}

/// Incremental `simctl bootstatus` parser for a streamed run: feed it lines,
/// it returns each update once its block is complete (a blank line, the next
/// status line, or `finish()`).
///
/// A block is a status line, `[<UTC time>] Status=<n>, isTerminal=<YES|NO>,
/// Elapsed=<mm>:<ss>.`, followed by a tab-indented phase line and, while data
/// migration runs, doubly indented `Reason:` and `Migration Elapsed:` lines.
public struct SimulatorBootStatusParser: Sendable {
    private var pending: (timestamp: String, status: UInt64, terminal: Bool, elapsed: Int)?
    private var phase: String?
    private var reason: String?

    public init() {}

    public mutating func consume(_ line: String) -> [SimulatorBootStatus] {
        if let header = Self.statusLine(line) {
            let flushed = flush()
            pending = header
            return flushed
        }
        guard pending != nil else { return [] }
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            return flush()
        }
        if line.hasPrefix("\t\t") {
            let detail = line.trimmingCharacters(in: .whitespaces)
            if detail.hasPrefix("Reason:") {
                let value = String(detail.dropFirst("Reason:".count))
                reason = value == "(null)" ? nil : value
            }
        } else if line.hasPrefix("\t") {
            phase = line.trimmingCharacters(in: .whitespaces)
        }
        return []
    }

    public mutating func finish() -> [SimulatorBootStatus] {
        flush()
    }

    private mutating func flush() -> [SimulatorBootStatus] {
        guard let pending else { return [] }
        let update = SimulatorBootStatus(
            timestamp: pending.timestamp,
            status: pending.status,
            isTerminal: pending.terminal,
            elapsedSeconds: pending.elapsed,
            phase: phase.map(SimulatorBootStatus.Phase.init),
            reason: reason
        )
        self.pending = nil
        phase = nil
        reason = nil
        return [update]
    }

    private static func statusLine(
        _ line: String
    ) -> (timestamp: String, status: UInt64, terminal: Bool, elapsed: Int)? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let timestamp = String(line[line.index(after: line.startIndex)..<close])
        var fields: [String: String] = [:]
        for part in line[line.index(after: close)...].split(separator: ",") {
            let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            fields[String(pair[0])] = String(pair[1])
        }
        guard let status = fields["Status"].flatMap({ UInt64($0) }),
              let terminal = fields["isTerminal"],
              let elapsedText = fields["Elapsed"]?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        else { return nil }
        let clock = elapsedText.split(separator: ":").compactMap { Int($0) }
        let elapsed = clock.reduce(0) { $0 * 60 + $1 }
        return (timestamp, status, terminal == "YES", elapsed)
    }
}

// MARK: - Wire shapes

private struct DeviceListing: Decodable {
    let devices: [String: [Entry]]

    struct Entry: Decodable {
        let udid: String
        let name: String
        let state: String
        let isAvailable: Bool?
        let availabilityError: String?
        let deviceTypeIdentifier: String?
        let dataPath: String?
        let logPath: String?
        let dataPathSize: Int64?
        let logPathSize: Int64?
        let lastUsedAt: String?
    }
}

private struct RuntimeListing: Decodable {
    let runtimes: [Entry]

    struct Entry: Decodable {
        let identifier: String
        let name: String
        let version: String
        let buildversion: String?
        let platform: String?
        let isAvailable: Bool?
        let isInternal: Bool?
        let availabilityError: String?
        let bundlePath: String?
        let supportedDeviceTypes: [DeviceTypeEntry]?
    }
}

private struct DeviceTypeListing: Decodable {
    let devicetypes: [DeviceTypeEntry]
}

private struct DeviceTypeEntry: Decodable {
    let identifier: String
    let name: String
    let productFamily: String?
    let modelIdentifier: String?
    let minRuntimeVersionString: String?
    let maxRuntimeVersionString: String?
    let bundlePath: String?

    var model: SimulatorDeviceType {
        SimulatorDeviceType(
            identifier: identifier,
            name: name,
            productFamily: productFamily,
            modelIdentifier: modelIdentifier,
            minRuntimeVersion: minRuntimeVersionString,
            maxRuntimeVersion: maxRuntimeVersionString,
            bundlePath: bundlePath
        )
    }
}
