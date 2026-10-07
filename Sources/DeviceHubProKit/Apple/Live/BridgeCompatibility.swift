import Foundation

/// A CoreSimulator build number such as `1171.7`, compared component by
/// component (`1155.4` < `1155.10` < `1171`; missing components count as 0).
public struct CoreSimulatorVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let components: [Int]

    /// Parses the framework's `CFBundleVersion`. Nil for anything that is not
    /// dot-separated non-negative integers.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part) else { return nil }
            numbers.append(value)
        }
        components = numbers
    }

    public init(_ components: Int...) {
        self.components = components
    }

    public var major: Int { components.first ?? 0 }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }

    public static func == (lhs: CoreSimulatorVersion, rhs: CoreSimulatorVersion) -> Bool {
        compare(lhs, rhs) == 0
    }

    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }

    public static func < (lhs: CoreSimulatorVersion, rhs: CoreSimulatorVersion) -> Bool {
        compare(lhs, rhs) < 0
    }

    private static func compare(_ lhs: CoreSimulatorVersion, _ rhs: CoreSimulatorVersion) -> Int {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }
}

/// Whether the private simulator bridge (`DeviceHubProSimBridge`) may load on the
/// CoreSimulator this Mac has. The bridge talks to private, yearly-moving
/// surfaces, so it runs only on builds it was verified on:
///
/// - **1171.x** (Xcode 27.0) is allowlisted.
/// - **Below 1155.4** never: that build removed `-ioSurface` and moved input to
///   dtuhidd; older builds would need a second (legacy Indigo) stack.
/// - **Any other build from 1155.4 on** (a newer Xcode, or an Xcode 27 beta)
///   is untested: off unless the caller passes `allowUntested` (for a planned
///   stage opt-in, "Try live view on this untested Xcode"; nothing offers it
///   yet) or `DHP_SIMBRIDGE_ALLOW_UNTESTED=1` is set (the June beta smoke).
/// - `DHP_DISABLE_SIMBRIDGE=1` forces it off whatever the version.
///
/// Off means the view-only stage: the public tier keeps working.
public enum BridgeCompatibility {
    public static let disableVariable = "DHP_DISABLE_SIMBRIDGE"
    public static let allowUntestedVariable = "DHP_SIMBRIDGE_ALLOW_UNTESTED"

    /// Major CoreSimulator versions the bridge was verified on.
    public static let allowlistedMajors: Set<Int> = [1171]
    /// The oldest CoreSimulator the bridge can ever run on.
    public static let minimumVersion = CoreSimulatorVersion(1155, 4)

    /// The system-wide CoreSimulator the bridge loads; its Info.plist is read
    /// without loading anything.
    public static let coreSimulatorInfoPlist = URL(
        fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/Info.plist"
    )

    public enum Verdict: Sendable, Equatable {
        /// A verified build: the bridge may load.
        case allowlisted(CoreSimulatorVersion)
        /// An untested build the user (or the environment) opted into.
        case untestedAllowed(CoreSimulatorVersion)
        /// An untested build: off until someone opts in.
        case untested(CoreSimulatorVersion)
        /// Older than the dtuhidd/SimScreen era: never.
        case tooOld(CoreSimulatorVersion)
        /// The version could not be read or parsed (no Xcode, a damaged install).
        case unknownVersion(String?)
        /// `DHP_DISABLE_SIMBRIDGE=1`.
        case disabled

        public var allowsBridge: Bool {
            switch self {
            case .allowlisted, .untestedAllowed: return true
            case .untested, .tooOld, .unknownVersion, .disabled: return false
            }
        }

        /// Whether opting in would turn the bridge on (what the planned
        /// "Try live view" offer will key on).
        public var canBeOverridden: Bool {
            if case .untested = self { return true }
            return false
        }
    }

    /// Decides for `coreSimulatorVersion` (a `CFBundleVersion` string).
    /// `allowUntested` is the user's explicit opt-in for an untested build.
    public static func verdict(
        coreSimulatorVersion: String?,
        allowUntested: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Verdict {
        if environment[disableVariable] == "1" { return .disabled }
        guard let text = coreSimulatorVersion, let version = CoreSimulatorVersion(text) else {
            return .unknownVersion(coreSimulatorVersion)
        }
        if version < minimumVersion { return .tooOld(version) }
        if allowlistedMajors.contains(version.major) { return .allowlisted(version) }
        if allowUntested || environment[allowUntestedVariable] == "1" { return .untestedAllowed(version) }
        return .untested(version)
    }

    /// The installed CoreSimulator's `CFBundleVersion`, read from its
    /// Info.plist (no `dlopen`), or nil when it is missing or unreadable.
    public static func installedCoreSimulatorVersion(infoPlist: URL = coreSimulatorInfoPlist) -> String? {
        guard let data = try? Data(contentsOf: infoPlist),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleVersion"] as? String
    }

    /// Whether the CoreSimulator this process loaded is no longer the one
    /// installed: an Xcode update replaced it underneath a running app. The
    /// bridge is then stale until the app relaunches.
    public static func isStale(loadedVersion: String?, installedVersion: String?) -> Bool {
        guard let loadedVersion, let loaded = CoreSimulatorVersion(loadedVersion) else { return false }
        guard let installedVersion, let installed = CoreSimulatorVersion(installedVersion) else { return true }
        return loaded != installed
    }
}
