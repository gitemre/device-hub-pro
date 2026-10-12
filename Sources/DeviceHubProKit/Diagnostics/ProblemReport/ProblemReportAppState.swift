import Foundation

/// What only the running app knows, handed to the collection as a snapshot (an
/// input, never encoded): the inventory it already holds, its windows, its
/// preferences as yes/no and the Apple tooling it probed. The collector copies
/// the parts a report carries and never asks a device for them again.
public struct ProblemReportAppState: Sendable {
    /// What the app knows about the Apple tooling and its simulators.
    public struct AppleState: Sendable {
        /// "T3".
        public var tier: String?
        public var isProbed: Bool
        public var xcodeVersion: String?
        public var xcodeBuild: String?
        public var setupAdvice: String?
        /// The toolchain the app probed; the collector never probes again.
        public var toolchain: AppleToolchain?
        public var simulatorsListed: Bool
        public var simulatorCount: Int
        public var bootedCount: Int
        public var runtimeCount: Int?
        public var watcherHealth: String?
        public var bridge: String?
        public var canvasReadyCount: Int

        public init(
            tier: String? = nil,
            isProbed: Bool = false,
            xcodeVersion: String? = nil,
            xcodeBuild: String? = nil,
            setupAdvice: String? = nil,
            toolchain: AppleToolchain? = nil,
            simulatorsListed: Bool = false,
            simulatorCount: Int = 0,
            bootedCount: Int = 0,
            runtimeCount: Int? = nil,
            watcherHealth: String? = nil,
            bridge: String? = nil,
            canvasReadyCount: Int = 0
        ) {
            self.tier = tier
            self.isProbed = isProbed
            self.xcodeVersion = xcodeVersion
            self.xcodeBuild = xcodeBuild
            self.setupAdvice = setupAdvice
            self.toolchain = toolchain
            self.simulatorsListed = simulatorsListed
            self.simulatorCount = simulatorCount
            self.bootedCount = bootedCount
            self.runtimeCount = runtimeCount
            self.watcherHealth = watcherHealth
            self.bridge = bridge
            self.canvasReadyCount = canvasReadyCount
        }
    }

    /// `inventory.realDevices`: adb's rows, emulators and phones.
    public var devices: [AndroidDevice]
    /// A phone's serial to its Android version.
    public var androidVersions: [String: String]
    /// An emulator's serial to the AVD name its console gave.
    public var consoleNames: [String: String]
    /// What `emulator -list-avds` listed; nil when it was not read.
    public var emulatorListAvds: [String]?
    public var adbAvailable: Bool
    public var adbServerProblem: Bool
    public var watcherDegraded: Bool
    public var localNetworkAccess: String
    public var adbRestarts: Int
    public var startingAvds: [String]
    public var windows: [ProblemReport.WindowInfo]
    public var preferences: ProblemReport.Preferences
    public var apple: AppleState
    /// Values that must never appear in the report: the team id, the enabled
    /// devices' identifiers and names, the `DHP_IPHONE_UDID` value.
    public var secrets: [String]
    /// The simulators' UDIDs, aliased `sim-1`, `sim-2`, …
    public var simulatorUDIDs: [String]

    public init(
        devices: [AndroidDevice] = [],
        androidVersions: [String: String] = [:],
        consoleNames: [String: String] = [:],
        emulatorListAvds: [String]? = nil,
        adbAvailable: Bool = true,
        adbServerProblem: Bool = false,
        watcherDegraded: Bool = false,
        localNetworkAccess: String = "unknown",
        adbRestarts: Int = 0,
        startingAvds: [String] = [],
        windows: [ProblemReport.WindowInfo] = [],
        preferences: ProblemReport.Preferences,
        apple: AppleState = AppleState(),
        secrets: [String] = [],
        simulatorUDIDs: [String] = []
    ) {
        self.devices = devices
        self.androidVersions = androidVersions
        self.consoleNames = consoleNames
        self.emulatorListAvds = emulatorListAvds
        self.adbAvailable = adbAvailable
        self.adbServerProblem = adbServerProblem
        self.watcherDegraded = watcherDegraded
        self.localNetworkAccess = localNetworkAccess
        self.adbRestarts = adbRestarts
        self.startingAvds = startingAvds
        self.windows = windows
        self.preferences = preferences
        self.apple = apple
        self.secrets = secrets
        self.simulatorUDIDs = simulatorUDIDs
    }
}
