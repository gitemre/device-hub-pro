import Foundation

/// What this Mac offers for Apple simulators, probed without loading any
/// Apple framework (no `dlopen`): the developer directory, the real
/// `simctl` and `devicectl` binaries, whether Xcode's first-launch install is
/// complete, and the support tier that follows.
///
/// `xcrun simctl` and `xcrun devicectl` resolve to wrapper scripts in
/// `<developer dir>/usr/bin/`. Before exec'ing the real binary inside the
/// CoreSimulator or CoreDevice framework, each compares the framework's
/// `CFBundleVersion` with its own `EXPECTED_VERSION` and runs `xcodebuild
/// -runFirstLaunch` on a mismatch (simctl: framework older; devicectl:
/// framework different), which installs system components. Device Hub Pro reads
/// the wrappers as text to learn the expected versions and the real paths,
/// runs only the real binaries, and reports "Open Xcode to finish installing
/// components" instead of ever triggering the installation itself.
///
/// The probe runs no tool that lives inside Xcode.app. On a Mac whose Xcode
/// was never launched, even `xcodebuild -checkFirstLaunchStatus` is unsafe: a
/// process spawned from the bundle makes Gatekeeper assess a quarantined Xcode
/// ("Xcode is damaged and can't be opened") and macOS attributes whatever the
/// tool touches to the responsible process, Device Hub Pro ("Device Hub Pro was prevented
/// from modifying apps on your Mac"). First launch is therefore read from
/// files: the installed CoreSimulator / CoreDevice framework versions against
/// what the wrappers expect (`FirstLaunchState`).
public struct AppleToolchain: Sendable, Equatable {
    /// What the user gets on this Mac.
    public enum Tier: Int, Sendable, Comparable, CustomStringConvertible {
        /// No usable Xcode: a setup card. Android is unaffected.
        case t0 = 0
        /// Public simulator features through simctl.
        case t1 = 1
        /// T1 plus the devicectl-backed rows (devicectl answered for a simulator).
        case t2 = 2
        /// The live canvas (the bridge loaded and passed its smoke check).
        case t3 = 3

        public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }

        public var description: String { "T\(rawValue)" }
    }

    /// Where the system keeps the frameworks and tools the probe reads.
    /// Tests point it at a temporary folder.
    public struct Layout: Sendable, Equatable {
        public var coreSimulatorFramework: URL
        public var coreDeviceFramework: URL
        public var xcodeSelect: URL
        /// The symlink `xcode-select` keeps (`/var/db/xcode_select_link`),
        /// read instead of running `xcode-select -p`; nil: run the tool.
        public var xcodeSelectLink: URL?
        /// The folders searched for an `Xcode*.app` that is installed but may
        /// not be the selected developer directory.
        public var applicationFolders: [URL]

        public init(
            coreSimulatorFramework: URL,
            coreDeviceFramework: URL,
            xcodeSelect: URL,
            xcodeSelectLink: URL? = nil,
            applicationFolders: [URL] = []
        ) {
            self.coreSimulatorFramework = coreSimulatorFramework
            self.coreDeviceFramework = coreDeviceFramework
            self.xcodeSelect = xcodeSelect
            self.xcodeSelectLink = xcodeSelectLink
            self.applicationFolders = applicationFolders
        }

        public static let system = Layout(
            coreSimulatorFramework: URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework"),
            coreDeviceFramework: URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreDevice.framework"),
            xcodeSelect: URL(fileURLWithPath: "/usr/bin/xcode-select"),
            xcodeSelectLink: URL(fileURLWithPath: "/var/db/xcode_select_link"),
            applicationFolders: [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
            ]
        )

        var simctlBinary: URL { resources(of: coreSimulatorFramework).appendingPathComponent("bin/simctl") }
        var devicectlBinary: URL { resources(of: coreDeviceFramework).appendingPathComponent("bin/devicectl") }
        var coreSimulatorInfoPlist: URL { resources(of: coreSimulatorFramework).appendingPathComponent("Info.plist") }
        var coreDeviceInfoPlist: URL { resources(of: coreDeviceFramework).appendingPathComponent("Info.plist") }

        private func resources(of framework: URL) -> URL {
            framework.appendingPathComponent("Versions/A/Resources", isDirectory: true)
        }
    }

    /// One framework-bundled tool.
    public struct BundledTool: Sendable, Equatable {
        /// The real binary, when it exists.
        public let binary: URL?
        /// The framework's `CFBundleVersion`.
        public let installedVersion: String?
        /// The Xcode wrapper's `EXPECTED_VERSION`.
        public let expectedVersion: String?
        /// Whether the wrapper would run `xcodebuild -runFirstLaunch` now.
        public let needsFirstLaunch: Bool
        /// Set by `DHP_SIMCTL` / `DHP_DEVICECTL`; no version checks.
        public let isOverride: Bool

        public init(
            binary: URL?,
            installedVersion: String?,
            expectedVersion: String?,
            needsFirstLaunch: Bool,
            isOverride: Bool = false
        ) {
            self.binary = binary
            self.installedVersion = installedVersion
            self.expectedVersion = expectedVersion
            self.needsFirstLaunch = needsFirstLaunch
            self.isOverride = isOverride
        }

        public static let missing = BundledTool(
            binary: nil,
            installedVersion: nil,
            expectedVersion: nil,
            needsFirstLaunch: false
        )
    }

    public let developerDirectory: URL?
    /// "27.0", from the Xcode bundle's `version.plist`.
    public let xcodeVersion: String?
    /// "27A266a".
    public let xcodeBuild: String?
    /// Whether Xcode's first-launch components are installed, read from the
    /// framework versions (never by running an Xcode tool); nil when there is
    /// no Xcode developer directory to judge.
    public let firstLaunchComplete: Bool?
    public let simctl: BundledTool
    public let devicectl: BundledTool
    /// The `Xcode*.app` bundles found in the application folders (newest
    /// name last), selected or not; empty when none, or not searched.
    public let installedXcodes: [URL]

    public init(
        developerDirectory: URL?,
        xcodeVersion: String?,
        xcodeBuild: String?,
        firstLaunchComplete: Bool?,
        simctl: BundledTool,
        devicectl: BundledTool,
        installedXcodes: [URL] = []
    ) {
        self.installedXcodes = installedXcodes
        self.developerDirectory = developerDirectory
        self.xcodeVersion = xcodeVersion
        self.xcodeBuild = xcodeBuild
        self.firstLaunchComplete = firstLaunchComplete
        self.simctl = simctl
        self.devicectl = devicectl
    }

    /// Why iOS cannot be used on this Mac, and what the app offers about it
    /// (a Device-Hub-style hint with one button).
    public enum XcodeGuidance: Equatable, Sendable {
        /// No Xcode found: "Get Xcode…" opens its Mac App Store page.
        case notInstalled
        /// An Xcode is installed, but `xcode-select` points at the Command
        /// Line Tools or nothing; Xcode > Settings > Locations selects it.
        case notSelected(xcodeName: String, app: URL)
        /// The selected Xcode has components left to install (first launch).
        case finishInstalling(app: URL?)

        public static let appStoreURL = URL(string: "macappstore://apps.apple.com/app/id497799835")!

        public var message: String {
            switch self {
            case .notInstalled:
                "iOS simulators and iPhones need Xcode."
            case .notSelected(let name, _):
                "iOS simulators and iPhones need Xcode, and \(name) is not the selected one. Choose it in Xcode > Settings > Locations."
            case .finishInstalling:
                "Open Xcode, accept the license and let it install its components (a few minutes), then come back."
            }
        }

        /// The hint's button.
        public var actionTitle: String {
            if case .notInstalled = self { return "Get Xcode\u{2026}" }
            return "Open Xcode\u{2026}"
        }

        /// What the button opens (nil: nothing to open).
        public var actionURL: URL? {
            switch self {
            case .notInstalled: Self.appStoreURL
            case .notSelected(_, let app): app
            case .finishInstalling(let app): app
            }
        }
    }

    /// The oldest devicectl JSON version the decoders were written against.
    public static let minimumDevicectlJSONVersion = 5

    // MARK: Derived state

    /// `xcode-select` points at the Command Line Tools, which carry no
    /// simulators and no devicectl (those live inside Xcode.app; a CoreSimulator
    /// framework left by an earlier Xcode must not count as one).
    public var commandLineToolsSelected: Bool {
        developerDirectory?.path.contains("/CommandLineTools") ?? false
    }

    /// simctl can be run: its binary exists and nothing is left to install.
    public var simctlUsable: Bool {
        guard simctl.binary != nil else { return false }
        if simctl.isOverride { return true }
        return developerDirectory != nil && !commandLineToolsSelected && !simctl.needsFirstLaunch && firstLaunchComplete != false
    }

    /// devicectl can be run (whether it reaches simulators is `tier`'s probe).
    public var devicectlUsable: Bool {
        guard devicectl.binary != nil else { return false }
        if devicectl.isOverride { return true }
        return developerDirectory != nil && !commandLineToolsSelected && !devicectl.needsFirstLaunch && firstLaunchComplete != false
    }

    /// Why Apple simulators are unavailable, in words for the setup card; nil
    /// when simctl is usable.
    public var setupAdvice: String? { guidance?.message }

    /// What is missing for iOS (simulators and iPhones both need Xcode), nil
    /// when simctl is usable. Android never depends on it.
    public var guidance: XcodeGuidance? {
        if simctlUsable { return nil }
        // A selected Xcode without the system's CoreSimulator is a first
        // launch not done, not a missing Xcode.
        if developerDirectory == nil || commandLineToolsSelected {
            if let installed = installedXcodes.first {
                return .notSelected(xcodeName: installed.deletingPathExtension().lastPathComponent, app: installed)
            }
            return .notInstalled
        }
        // Xcode is selected: <app>/Contents/Developer.
        let app = developerDirectory?.deletingLastPathComponent().deletingLastPathComponent()
        return .finishInstalling(app: app)
    }

    /// The tier, given the devicectl probe (a devicectl answer for a listed
    /// simulator) and whether the canvas bridge passed its smoke check.
    public func tier(devicectlProbe: DevicectlInfo? = nil, canvasReady: Bool = false) -> Tier {
        let devicectlReady = devicectlUsable
            && devicectlProbe.map { $0.succeeded && $0.jsonVersion >= Self.minimumDevicectlJSONVersion } == true
        return Self.tier(simctlUsable: simctlUsable, devicectlReady: devicectlReady, canvasReady: canvasReady)
    }

    /// The tier as a pure function of its three inputs. The canvas does not
    /// need devicectl, so T3 is reported with or without the T2 rows; which
    /// rows show is decided per row, not by the tier.
    public static func tier(simctlUsable: Bool, devicectlReady: Bool, canvasReady: Bool) -> Tier {
        guard simctlUsable else { return .t0 }
        if canvasReady { return .t3 }
        return devicectlReady ? .t2 : .t1
    }

    /// A simctl client for the real binary, or nil when simctl is unusable.
    public func makeSimctlClient(
        deviceSet: URL? = nil,
        commandTimeout: Duration = SimctlClient.defaultTimeout
    ) -> SimctlClient? {
        guard simctlUsable, let binary = simctl.binary else { return nil }
        return SimctlClient(
            simctlURL: binary,
            deviceSet: deviceSet,
            developerDirectory: developerDirectory,
            commandTimeout: commandTimeout
        )
    }

    /// A devicectl client for one listed simulator, or nil when devicectl is
    /// unusable.
    public func makeDevicectlClient(for simulator: SimulatorDevice) throws -> DevicectlClient? {
        guard devicectlUsable, let binary = devicectl.binary else { return nil }
        return try DevicectlClient(
            devicectlURL: binary,
            simulator: simulator,
            developerDirectory: developerDirectory
        )
    }

    /// The physical-device lister, or nil when devicectl is unusable. It
    /// still makes no call without a `PhysicalDeviceOptIn`.
    public func makePhysicalDeviceLister() -> ApplePhysicalDeviceLister? {
        guard devicectlUsable, let binary = devicectl.binary else { return nil }
        return ApplePhysicalDeviceLister(devicectlURL: binary, developerDirectory: developerDirectory)
    }

    /// A read-only devicectl client for one opted-in physical iPhone, or nil
    /// when devicectl is unusable.
    public func makeDevicectlPhysicalClient(for device: ApplePhysicalDevice) throws -> DevicectlPhysicalClient? {
        guard devicectlUsable, let binary = devicectl.binary else { return nil }
        return try DevicectlPhysicalClient(
            devicectlURL: binary,
            device: device,
            developerDirectory: developerDirectory
        )
    }

    // MARK: Probe

    /// Probes this Mac. Reads files only, and runs `/usr/bin/xcode-select -p`
    /// when neither `DEVELOPER_DIR` nor the selection symlink answers; no tool
    /// inside Xcode.app is ever run.
    public static func probe(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        layout: Layout = .system
    ) async -> AppleToolchain {
        let developerDirectory = await resolveDeveloperDirectory(environment: environment, layout: layout)
        let version = developerDirectory.flatMap(xcodeVersion(developerDirectory:))

        let simctl = bundledTool(
            override: environment["DHP_SIMCTL"],
            wrapper: developerDirectory?.appendingPathComponent("usr/bin/simctl"),
            fallbackBinary: layout.simctlBinary,
            infoPlist: layout.coreSimulatorInfoPlist,
            policy: .olderThanExpected
        )
        let devicectl = bundledTool(
            override: environment["DHP_DEVICECTL"],
            wrapper: developerDirectory?.appendingPathComponent("usr/bin/devicectl"),
            fallbackBinary: layout.devicectlBinary,
            infoPlist: layout.coreDeviceInfoPlist,
            policy: .differentFromExpected
        )

        var firstLaunchComplete: Bool?
        if developerDirectory != nil, !simctl.isOverride {
            let selected = developerDirectory?.path.contains("/CommandLineTools") == false
            firstLaunchComplete = selected ? (simctl.binary != nil && !simctl.needsFirstLaunch) : nil
        }

        return AppleToolchain(
            developerDirectory: developerDirectory,
            xcodeVersion: version?.version,
            xcodeBuild: version?.build,
            firstLaunchComplete: firstLaunchComplete,
            simctl: simctl,
            devicectl: devicectl,
            installedXcodes: findInstalledXcodes(in: layout.applicationFolders)
        )
    }

    /// The `Xcode*.app` bundles (with a `Contents/Developer`) of `folders`,
    /// sorted by name: "Xcode.app" before "Xcode-beta.app".
    static func findInstalledXcodes(in folders: [URL]) -> [URL] {
        let fileManager = FileManager.default
        var found: [URL] = []
        for folder in folders {
            let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names.sorted() where name.hasPrefix("Xcode") && name.hasSuffix(".app") {
                let app = folder.appendingPathComponent(name, isDirectory: true)
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(
                    atPath: app.appendingPathComponent("Contents/Developer").path, isDirectory: &isDirectory
                ), isDirectory.boolValue {
                    found.append(app)
                }
            }
        }
        return found
    }

    /// How a wrapper decides that first launch is needed.
    enum WrapperPolicy {
        /// simctl: the framework is missing or older than expected.
        case olderThanExpected
        /// devicectl: the framework version differs from the expected one.
        case differentFromExpected
    }

    static func bundledTool(
        override: String?,
        wrapper: URL?,
        fallbackBinary: URL,
        infoPlist: URL,
        policy: WrapperPolicy
    ) -> BundledTool {
        let fileManager = FileManager.default
        if let override, !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            return BundledTool(
                binary: fileManager.isExecutableFile(atPath: url.path) ? url : nil,
                installedVersion: nil,
                expectedVersion: nil,
                needsFirstLaunch: false,
                isOverride: true
            )
        }

        // Best effort: an unreadable wrapper means "no expectation known".
        let script = wrapper.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let expected = script.flatMap(expectedVersion(inWrapper:))
        var binary: URL?
        if let target = script.flatMap(execTarget(inWrapper:)),
           target.path != wrapper?.path,
           fileManager.isExecutableFile(atPath: target.path) {
            binary = target
        } else if fileManager.isExecutableFile(atPath: fallbackBinary.path) {
            binary = fallbackBinary
        }
        let installed = bundleVersion(at: infoPlist)

        var needsFirstLaunch = false
        if let expected {
            switch policy {
            case .olderThanExpected:
                needsFirstLaunch = installed.map { compareVersions($0, expected) == .orderedAscending } ?? true
            case .differentFromExpected:
                needsFirstLaunch = installed != expected
            }
        }
        return BundledTool(
            binary: binary,
            installedVersion: installed,
            expectedVersion: expected,
            needsFirstLaunch: needsFirstLaunch
        )
    }

    /// The `EXPECTED_VERSION="…"` assignment of a wrapper script.
    static func expectedVersion(inWrapper script: String) -> String? {
        for line in script.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("EXPECTED_VERSION=") else { continue }
            let value = trimmed.dropFirst("EXPECTED_VERSION=".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// The absolute path a wrapper's `exec "…" "${@}"` line runs.
    static func execTarget(inWrapper script: String) -> URL? {
        for line in script.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("exec ") else { continue }
            let rest = trimmed.dropFirst("exec ".count)
            guard rest.first == "\"", let close = rest.dropFirst().firstIndex(of: "\"") else { continue }
            let path = String(rest[rest.index(after: rest.startIndex)..<close])
            guard path.hasPrefix("/"), !path.contains("$") else { continue }
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Compares dotted version strings the way the simctl wrapper does:
    /// trailing `.0` components do not count (1107.0 == 1107), and components
    /// compare numerically.
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func components(_ version: String) -> [Int] {
            var parts = version.split(separator: ".").map { Int($0) ?? 0 }
            while parts.count > 1, parts.last == 0 {
                parts.removeLast()
            }
            return parts
        }
        let left = components(lhs)
        let right = components(rhs)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static func bundleVersion(at infoPlist: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: infoPlist.path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any]
        else { return nil }
        return dictionary["CFBundleVersion"] as? String
    }

    /// `Xcode.app/Contents/version.plist` next to `Contents/Developer`.
    static func xcodeVersion(developerDirectory: URL) -> (version: String?, build: String?)? {
        let plistURL = developerDirectory.deletingLastPathComponent().appendingPathComponent("version.plist")
        guard let data = FileManager.default.contents(atPath: plistURL.path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any]
        else { return nil }
        return (
            dictionary["CFBundleShortVersionString"] as? String,
            dictionary["ProductBuildVersion"] as? String
        )
    }

    private static func resolveDeveloperDirectory(
        environment: [String: String],
        layout: Layout
    ) async -> URL? {
        if let value = environment["DEVELOPER_DIR"], !value.isEmpty {
            return existingDirectory(value)
        }
        // The selection symlink answers without running anything.
        if let link = layout.xcodeSelectLink,
           let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
           let directory = existingDirectory(target) {
            return directory
        }
        // Best effort: no xcode-select answer means no developer directory.
        guard let result = try? await ProcessRunner.run(
            executable: layout.xcodeSelect,
            arguments: ["-p"],
            timeout: .seconds(5)
        ), result.exitCode == 0 else { return nil }
        return existingDirectory(result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func existingDirectory(_ path: String) -> URL? {
        var isDirectory: ObjCBool = false
        guard !path.isEmpty,
              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
