import Foundation

/// What a user attaches to a GitHub issue so the maintainers see the setup
/// that failed: the Mac, the Android and Apple tooling, the emulators and what
/// they answered, the app's recent errors. One schema for the in-app report
/// and the maintainer CLI (`dhp-report`); the JSON is the source of truth, and
/// the Markdown summary and the findings are derived from it
/// (`ProblemReportRenderer`, `ProblemReportAnalyzer`).
///
/// Every string in a report has been through `ProblemReportScrubber` before it
/// is shown or analyzed; a report holds no token, serial number, address or
/// user name. Dates are ISO 8601 in UTC with whole seconds.
///
/// Compatibility: every field added later in schema 1 is optional. A breaking
/// change bumps `schemaVersion` and keeps a decoder for 1.
public struct ProblemReport: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    /// Who made the report.
    public enum Producer: String, Codable, Sendable, Equatable, CaseIterable {
        case app
        case cli
    }

    public var schemaVersion: Int
    /// Eight lowercase hex characters, random per report (not a UUID).
    public var id: String
    public var createdAt: Date
    public var producer: Producer
    /// The error the user is reporting, when the report starts from one.
    public var subject: Subject?
    public var app: AppInfo
    public var mac: MacInfo
    public var android: AndroidInfo
    public var apple: AppleInfo
    /// One entry per window; app reports only.
    public var windows: [WindowInfo]
    /// Newest first.
    public var recentProblems: [RecentProblem]
    /// Emulator log tails, newest first, at most three.
    public var emulatorLogs: [LogTail]
    public var crashReports: [CrashReportRef]
    /// The rule ids the analyzer of the producing build reported.
    public var findingsShown: [String]
    public var collection: CollectionInfo

    public init(
        id: String,
        createdAt: Date,
        producer: Producer,
        subject: Subject? = nil,
        app: AppInfo,
        mac: MacInfo,
        android: AndroidInfo,
        apple: AppleInfo,
        windows: [WindowInfo] = [],
        recentProblems: [RecentProblem] = [],
        emulatorLogs: [LogTail] = [],
        crashReports: [CrashReportRef] = [],
        findingsShown: [String] = [],
        collection: CollectionInfo = CollectionInfo()
    ) {
        self.schemaVersion = Self.schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.producer = producer
        self.subject = subject
        self.app = app
        self.mac = mac
        self.android = android
        self.apple = apple
        self.windows = windows
        self.recentProblems = recentProblems
        self.emulatorLogs = emulatorLogs
        self.crashReports = crashReports
        self.findingsShown = findingsShown
        self.collection = collection
    }

    // MARK: Subject and the app

    /// The error being reported.
    public struct Subject: Codable, Sendable, Equatable {
        public var message: String
        public var details: [String]?
        public var occurredAt: Date

        public init(message: String, details: [String]? = nil, occurredAt: Date) {
            self.message = message
            self.details = details
            self.occurredAt = occurredAt
        }
    }

    public struct AppInfo: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable, Equatable, CaseIterable {
            case packaged
            case development
            case cli
        }

        public enum Location: String, Codable, Sendable, Equatable, CaseIterable {
            case applications
            case userApplications
            case translocated
            case diskImage
            case other
        }

        public var version: String?
        public var build: String?
        public var kind: Kind
        public var location: Location?
        public var quarantined: Bool?
        /// The sorted names (never the values) of the set, non-empty `DHP_*`
        /// environment variables.
        public var environmentFlags: [String]
        /// App reports only.
        public var preferences: Preferences?

        init(
            version: String? = nil,
            build: String? = nil,
            kind: Kind,
            location: Location? = nil,
            quarantined: Bool? = nil,
            environmentFlags: [String] = [],
            preferences: Preferences? = nil
        ) {
            self.version = version
            self.build = build
            self.kind = kind
            self.location = location
            self.quarantined = quarantined
            self.environmentFlags = environmentFlags
            self.preferences = preferences
        }
    }

    /// The preferences that change what the app does, as yes/no and counts:
    /// never a path, a team or a device.
    public struct Preferences: Codable, Sendable, Equatable {
        public var customEmulatorBinary: Bool
        public var customSDKFolder: Bool
        /// `EmulatorAudioMode`'s raw value.
        public var emulatorAudio: String
        public var autoRepairAvdDisplay: Bool
        public var localNetworkInUse: Bool
        public var showPhysicalAppleDevices: Bool
        public var enabledPhysicalDeviceCount: Int
        public var physicalFastInput: Bool
        public var physicalNativeLiveView: Bool
        public var developmentTeamSet: Bool

        public init(
            customEmulatorBinary: Bool,
            customSDKFolder: Bool,
            emulatorAudio: String,
            autoRepairAvdDisplay: Bool,
            localNetworkInUse: Bool,
            showPhysicalAppleDevices: Bool,
            enabledPhysicalDeviceCount: Int,
            physicalFastInput: Bool,
            physicalNativeLiveView: Bool,
            developmentTeamSet: Bool
        ) {
            self.customEmulatorBinary = customEmulatorBinary
            self.customSDKFolder = customSDKFolder
            self.emulatorAudio = emulatorAudio
            self.autoRepairAvdDisplay = autoRepairAvdDisplay
            self.localNetworkInUse = localNetworkInUse
            self.showPhysicalAppleDevices = showPhysicalAppleDevices
            self.enabledPhysicalDeviceCount = enabledPhysicalDeviceCount
            self.physicalFastInput = physicalFastInput
            self.physicalNativeLiveView = physicalNativeLiveView
            self.developmentTeamSet = developmentTeamSet
        }
    }

    // MARK: The Mac

    public struct MacInfo: Codable, Sendable, Equatable {
        /// "27.0.1", from `operatingSystemVersion`.
        public var macOS: String
        /// `kern.osversion`.
        public var build: String?
        /// `hw.model`.
        public var model: String?
        /// `machdep.cpu.brand_string`.
        public var chip: String?
        /// `hw.memsize`, rounded to whole GiB.
        public var memoryGB: Int?
        /// `hw.optional.arm64`.
        public var appleSilicon: Bool
        /// `sysctl.proc_translated`; a missing key counts as false.
        public var translated: Bool
        /// `kern.hv_support`.
        public var hypervisorSupported: Bool?
        /// `kern.hv_vmm_present`.
        public var insideVirtualMachine: Bool?
        public var freeSpace: [VolumeSpace]

        init(
            macOS: String,
            build: String? = nil,
            model: String? = nil,
            chip: String? = nil,
            memoryGB: Int? = nil,
            appleSilicon: Bool,
            translated: Bool = false,
            hypervisorSupported: Bool? = nil,
            insideVirtualMachine: Bool? = nil,
            freeSpace: [VolumeSpace] = []
        ) {
            self.macOS = macOS
            self.build = build
            self.model = model
            self.chip = chip
            self.memoryGB = memoryGB
            self.appleSilicon = appleSilicon
            self.translated = translated
            self.hypervisorSupported = hypervisorSupported
            self.insideVirtualMachine = insideVirtualMachine
            self.freeSpace = freeSpace
        }
    }

    /// Free space of the volume holding one of the places an emulator writes.
    public struct VolumeSpace: Codable, Sendable, Equatable {
        /// "home", "avdHome" or "sdk".
        public var role: String
        /// Decimal gigabytes.
        public var freeGB: Int

        init(role: String, freeGB: Int) {
            self.role = role
            self.freeGB = freeGB
        }
    }

    // MARK: Android

    public struct AndroidInfo: Codable, Sendable, Equatable {
        public var variables: [Variable]
        /// The app put its "Locate SDK…" folder into `ANDROID_HOME`.
        public var sdkFolderSetByApp: Bool
        /// The app started adb with mDNS discovery off (`AdbMdnsPolicy`).
        public var mdnsDisabledByApp: Bool
        public var sdkRoots: [SdkRoot]
        public var adb: AdbInfo
        /// The emulator binary in use.
        public var emulator: ToolInfo?
        /// The avdmanager Device Hub Pro would run.
        public var avdmanager: ToolInfo?
        public var consoleTokenFile: TokenFileInfo
        /// Only when `ANDROID_EMULATOR_HOME` is set.
        public var emulatorHomeTokenFile: TokenFileInfo?
        public var avdHome: AvdHomeInfo
        /// At most 30: running ones first, then the newest `config.ini`.
        public var avds: [Avd]
        /// What `emulator -list-avds` listed; app reports only.
        public var emulatorListsAvds: [String]?
        /// At most four are probed.
        public var runningEmulators: [RunningEmulator]
        public var phones: [Phone]
        /// "app inventory", "adb devices -l" or "not read: <reason>".
        public var devicesSource: String
        /// App reports only.
        public var appAdb: AppAdbState?

        init(
            variables: [Variable] = [],
            sdkFolderSetByApp: Bool = false,
            mdnsDisabledByApp: Bool = false,
            sdkRoots: [SdkRoot] = [],
            adb: AdbInfo = AdbInfo(),
            emulator: ToolInfo? = nil,
            avdmanager: ToolInfo? = nil,
            consoleTokenFile: TokenFileInfo,
            emulatorHomeTokenFile: TokenFileInfo? = nil,
            avdHome: AvdHomeInfo,
            avds: [Avd] = [],
            emulatorListsAvds: [String]? = nil,
            runningEmulators: [RunningEmulator] = [],
            phones: [Phone] = [],
            devicesSource: String = "not read",
            appAdb: AppAdbState? = nil
        ) {
            self.variables = variables
            self.sdkFolderSetByApp = sdkFolderSetByApp
            self.mdnsDisabledByApp = mdnsDisabledByApp
            self.sdkRoots = sdkRoots
            self.adb = adb
            self.emulator = emulator
            self.avdmanager = avdmanager
            self.consoleTokenFile = consoleTokenFile
            self.emulatorHomeTokenFile = emulatorHomeTokenFile
            self.avdHome = avdHome
            self.avds = avds
            self.emulatorListsAvds = emulatorListsAvds
            self.runningEmulators = runningEmulators
            self.phones = phones
            self.devicesSource = devicesSource
            self.appAdb = appAdb
        }
    }

    /// An environment variable the Android tools read. The value is kept only
    /// for `ADB_MDNS` and an all-digits `ANDROID_ADB_SERVER_PORT`.
    public struct Variable: Codable, Sendable, Equatable {
        public var name: String
        public var value: String?
        /// For the path-valued variables: whether the path exists.
        public var pathExists: Bool?

        init(name: String, value: String? = nil, pathExists: Bool? = nil) {
            self.name = name
            self.value = value
            self.pathExists = pathExists
        }
    }

    public struct SdkRoot: Codable, Sendable, Equatable {
        public var path: String
        /// "ANDROID_HOME", "ANDROID_SDK_ROOT", "default", "adb" or "emulator".
        public var foundBy: [String]
        public var exists: Bool
        /// `platform-tools/source.properties` `Pkg.Revision`.
        public var platformTools: String?
        /// `emulator/source.properties` `Pkg.Revision`, else `package.xml`.
        public var emulator: String?
        public var cmdlineTools: [CmdlineTools]
        /// The count of `system-images/*/*/*` folders.
        public var systemImages: Int?

        init(
            path: String,
            foundBy: [String],
            exists: Bool,
            platformTools: String? = nil,
            emulator: String? = nil,
            cmdlineTools: [CmdlineTools] = [],
            systemImages: Int? = nil
        ) {
            self.path = path
            self.foundBy = foundBy
            self.exists = exists
            self.platformTools = platformTools
            self.emulator = emulator
            self.cmdlineTools = cmdlineTools
            self.systemImages = systemImages
        }
    }

    public struct CmdlineTools: Codable, Sendable, Equatable {
        /// "latest", "19.0", …
        public var folder: String
        public var version: String?

        init(folder: String, version: String? = nil) {
            self.folder = folder
            self.version = version
        }
    }

    public struct AdbInfo: Codable, Sendable, Equatable {
        public var path: String?
        public var version: String?
        /// Other adb executables the locators would also find.
        public var otherCopies: [OtherAdb]
        public var server: AdbServer

        init(path: String? = nil, version: String? = nil, otherCopies: [OtherAdb] = [], server: AdbServer = AdbServer()) {
            self.path = path
            self.version = version
            self.otherCopies = otherCopies
            self.server = server
        }
    }

    public struct OtherAdb: Codable, Sendable, Equatable {
        public var path: String
        public var version: String?

        init(path: String, version: String? = nil) {
            self.path = path
            self.version = version
        }
    }

    public struct AdbServer: Codable, Sendable, Equatable {
        public var running: Bool
        public var port: String?
        public var path: String?
        public var version: String?
        /// Whether the server runs from the adb Device Hub Pro uses; nil when
        /// either path is unknown.
        public var sameAsApp: Bool?
        /// Whether the report asked the server anything.
        public var queried: Bool
        public var notQueriedBecause: String?

        init(
            running: Bool = false,
            port: String? = nil,
            path: String? = nil,
            version: String? = nil,
            sameAsApp: Bool? = nil,
            queried: Bool = false,
            notQueriedBecause: String? = nil
        ) {
            self.running = running
            self.port = port
            self.path = path
            self.version = version
            self.sameAsApp = sameAsApp
            self.queried = queried
            self.notQueriedBecause = notQueriedBecause
        }
    }

    public struct ToolInfo: Codable, Sendable, Equatable {
        public var path: String
        public var version: String?
        public var build: String?

        init(path: String, version: String? = nil, build: String? = nil) {
            self.path = path
            self.version = version
            self.build = build
        }
    }

    /// The state of `~/.emulator_console_auth_token`.
    public enum TokenState: String, Codable, Sendable, Equatable, CaseIterable {
        case missing
        case empty
        /// Only whitespace.
        case blank
        case present
        case notAFile
        case unreadable
    }

    /// A console token file's state. Its contents are never kept: not read
    /// beyond a whitespace check, stored, hashed or logged.
    public struct TokenFileInfo: Codable, Sendable, Equatable {
        public var path: String
        public var state: TokenState
        public var bytes: Int?
        /// The permission bits in octal, "600".
        public var mode: String?
        public var ownedByUser: Bool?

        init(path: String, state: TokenState, bytes: Int? = nil, mode: String? = nil, ownedByUser: Bool? = nil) {
            self.path = path
            self.state = state
            self.bytes = bytes
            self.mode = mode
            self.ownedByUser = ownedByUser
        }
    }

    public struct AvdHomeInfo: Codable, Sendable, Equatable {
        public var path: String
        public var exists: Bool
        /// Only when `AvdConfig.defaultHomeURL` (what the app's own file
        /// operations use) resolves elsewhere.
        public var appPath: String?
        public var avdCount: Int

        init(path: String, exists: Bool, appPath: String? = nil, avdCount: Int = 0) {
            self.path = path
            self.exists = exists
            self.appPath = appPath
            self.avdCount = avdCount
        }
    }

    public enum ImageState: String, Codable, Sendable, Equatable, CaseIterable {
        case ok
        case missing
        case incomplete
        /// The AVD names no system image.
        case unnamed
    }

    public enum ContentFolder: String, Codable, Sendable, Equatable, CaseIterable {
        case inHome
        case external
        case missing
    }

    public struct Avd: Codable, Sendable, Equatable {
        public var name: String
        /// `target=` of the registry entry (`<name>.ini`).
        public var target: String?
        /// `target=` of the AVD's `config.ini`.
        public var configTarget: String?
        public var imageSysdir: String?
        public var imageAPI: String?
        public var abi: String?
        public var tag: String?
        /// `hw.device.name`.
        public var device: String?
        public var playStore: Bool?
        public var ramMB: Int?
        public var image: ImageState
        /// `EmulatorPreflight.problem`'s sentence.
        public var preflightProblem: String?
        public var contentFolder: ContentFolder
        /// `snapshots/default_boot` exists.
        public var quickBootSnapshot: Bool
        /// The names of the `*.lock` entries in the content folder.
        public var lockFiles: [String]
        public var running: Bool
        /// Whether `emulator -list-avds` listed it; app reports only.
        public var listedByEmulator: Bool?

        init(
            name: String,
            target: String? = nil,
            configTarget: String? = nil,
            imageSysdir: String? = nil,
            imageAPI: String? = nil,
            abi: String? = nil,
            tag: String? = nil,
            device: String? = nil,
            playStore: Bool? = nil,
            ramMB: Int? = nil,
            image: ImageState = .ok,
            preflightProblem: String? = nil,
            contentFolder: ContentFolder = .inHome,
            quickBootSnapshot: Bool = false,
            lockFiles: [String] = [],
            running: Bool = false,
            listedByEmulator: Bool? = nil
        ) {
            self.name = name
            self.target = target
            self.configTarget = configTarget
            self.imageSysdir = imageSysdir
            self.imageAPI = imageAPI
            self.abi = abi
            self.tag = tag
            self.device = device
            self.playStore = playStore
            self.ramMB = ramMB
            self.image = image
            self.preflightProblem = preflightProblem
            self.contentFolder = contentFolder
            self.quickBootSnapshot = quickBootSnapshot
            self.lockFiles = lockFiles
            self.running = running
            self.listedByEmulator = listedByEmulator
        }
    }

    public struct RunningEmulator: Codable, Sendable, Equatable {
        public var avd: String
        public var processAlive: Bool
        public var grpcPort: Int?
        public var consolePort: Int?
        /// "emulator-5554".
        public var serial: String?
        /// Allow-listed command-line flags; a value only for `-gpu`,
        /// `-accel`, `-feature` and `-port`, never a path.
        public var flags: [String]
        /// `-qt-hide-window`, `-no-boot-anim` and `-grpc-use-token` are all
        /// present: the way Device Hub Pro starts an emulator.
        public var startedByDeviceHubPro: Bool
        public var discovery: Discovery?
        /// adb's state for the serial ("device", "offline", …); nil when
        /// adb does not list it.
        public var adbState: String?
        public var console: ConsoleProbe
        public var guestAvdName: PropertyProbe
        public var bootCompleted: PropertyProbe

        init(
            avd: String,
            processAlive: Bool,
            grpcPort: Int? = nil,
            consolePort: Int? = nil,
            serial: String? = nil,
            flags: [String] = [],
            startedByDeviceHubPro: Bool = false,
            discovery: Discovery? = nil,
            adbState: String? = nil,
            console: ConsoleProbe = ConsoleProbe(outcome: .skipped),
            guestAvdName: PropertyProbe = PropertyProbe(outcome: .skipped),
            bootCompleted: PropertyProbe = PropertyProbe(outcome: .skipped)
        ) {
            self.avd = avd
            self.processAlive = processAlive
            self.grpcPort = grpcPort
            self.consolePort = consolePort
            self.serial = serial
            self.flags = flags
            self.startedByDeviceHubPro = startedByDeviceHubPro
            self.discovery = discovery
            self.adbState = adbState
            self.console = console
            self.guestAvdName = guestAvdName
            self.bootCompleted = bootCompleted
        }
    }

    /// An emulator's discovery file (`pid_<n>.ini`), as yes/no for its tokens.
    public struct Discovery: Codable, Sendable, Equatable {
        public var found: Bool
        public var emulatorVersion: String?
        public var emulatorBuild: String?
        public var avdID: String?
        public var consolePort: Int?
        public var adbPort: Int?
        public var grpcPort: Int?
        public var hasGrpcToken: Bool
        public var hasJwks: Bool

        init(
            found: Bool,
            emulatorVersion: String? = nil,
            emulatorBuild: String? = nil,
            avdID: String? = nil,
            consolePort: Int? = nil,
            adbPort: Int? = nil,
            grpcPort: Int? = nil,
            hasGrpcToken: Bool = false,
            hasJwks: Bool = false
        ) {
            self.found = found
            self.emulatorVersion = emulatorVersion
            self.emulatorBuild = emulatorBuild
            self.avdID = avdID
            self.consolePort = consolePort
            self.adbPort = adbPort
            self.grpcPort = grpcPort
            self.hasGrpcToken = hasGrpcToken
            self.hasJwks = hasJwks
        }
    }

    public enum ConsoleOutcome: String, Codable, Sendable, Equatable, CaseIterable {
        /// `adb emu avd name` printed the AVD's name.
        case answered
        /// It exited 0 and printed nothing (or only `OK`).
        case emptyAnswer
        /// The console answered `KO`.
        case ko
        case failed
        case timedOut
        case skipped
    }

    /// What `adb -s emulator-N emu avd name` answered.
    public struct ConsoleProbe: Codable, Sendable, Equatable {
        public var outcome: ConsoleOutcome
        public var exitCode: Int32?
        public var stdoutBytes: Int?
        public var sawOK: Bool?
        /// The AVD name the answer carried.
        public var name: String?
        /// The first 200 characters of the error output.
        public var stderr: String?
        public var note: String?

        init(
            outcome: ConsoleOutcome,
            exitCode: Int32? = nil,
            stdoutBytes: Int? = nil,
            sawOK: Bool? = nil,
            name: String? = nil,
            stderr: String? = nil,
            note: String? = nil
        ) {
            self.outcome = outcome
            self.exitCode = exitCode
            self.stdoutBytes = stdoutBytes
            self.sawOK = sawOK
            self.name = name
            self.stderr = stderr
            self.note = note
        }
    }

    public enum PropertyOutcome: String, Codable, Sendable, Equatable, CaseIterable {
        case answered
        case empty
        case failed
        case timedOut
        case skipped
    }

    /// One `getprop` answer.
    public struct PropertyProbe: Codable, Sendable, Equatable {
        public var outcome: PropertyOutcome
        public var value: String?
        public var note: String?

        init(outcome: PropertyOutcome, value: String? = nil, note: String? = nil) {
            self.outcome = outcome
            self.value = value
            self.note = note
        }
    }

    /// A phone adb lists. Phones are never probed; their identifiers never
    /// leave the scrubber.
    public struct Phone: Codable, Sendable, Equatable {
        /// "phone-1".
        public var alias: String
        /// "usb", "wifi" or "mdns".
        public var transports: [String]
        public var state: String
        public var model: String?
        public var device: String?
        public var androidVersion: String?

        init(
            alias: String,
            transports: [String],
            state: String,
            model: String? = nil,
            device: String? = nil,
            androidVersion: String? = nil
        ) {
            self.alias = alias
            self.transports = transports
            self.state = state
            self.model = model
            self.device = device
            self.androidVersion = androidVersion
        }
    }

    /// The app's own view of adb; app reports only.
    public struct AppAdbState: Codable, Sendable, Equatable {
        public var adbAvailable: Bool
        public var serverProblem: Bool
        public var watcherDegraded: Bool
        public var localNetwork: String
        public var adbRestarts: Int
        /// "emulator-5554 → Pixel_8_Pro".
        public var consoleNames: [String]
        public var startingAvds: [String]

        public init(
            adbAvailable: Bool,
            serverProblem: Bool,
            watcherDegraded: Bool,
            localNetwork: String,
            adbRestarts: Int,
            consoleNames: [String],
            startingAvds: [String]
        ) {
            self.adbAvailable = adbAvailable
            self.serverProblem = serverProblem
            self.watcherDegraded = watcherDegraded
            self.localNetwork = localNetwork
            self.adbRestarts = adbRestarts
            self.consoleNames = consoleNames
            self.startingAvds = startingAvds
        }
    }

    // MARK: Apple

    public struct AppleInfo: Codable, Sendable, Equatable {
        public var xcodeVersion: String?
        public var xcodeBuild: String?
        /// "Xcode app", "Command Line Tools" or "other".
        public var developerDirectory: String?
        /// "Xcode-beta.app".
        public var xcodeAppName: String?
        public var installedXcodes: Int?
        public var firstLaunchComplete: Bool?
        public var simctl: AppleTool?
        public var devicectl: AppleTool?
        /// "T3"; app reports only.
        public var tier: String?
        public var setupAdvice: String?
        public var simulators: SimulatorCounts?
        public var bridge: String?

        init(
            xcodeVersion: String? = nil,
            xcodeBuild: String? = nil,
            developerDirectory: String? = nil,
            xcodeAppName: String? = nil,
            installedXcodes: Int? = nil,
            firstLaunchComplete: Bool? = nil,
            simctl: AppleTool? = nil,
            devicectl: AppleTool? = nil,
            tier: String? = nil,
            setupAdvice: String? = nil,
            simulators: SimulatorCounts? = nil,
            bridge: String? = nil
        ) {
            self.xcodeVersion = xcodeVersion
            self.xcodeBuild = xcodeBuild
            self.developerDirectory = developerDirectory
            self.xcodeAppName = xcodeAppName
            self.installedXcodes = installedXcodes
            self.firstLaunchComplete = firstLaunchComplete
            self.simctl = simctl
            self.devicectl = devicectl
            self.tier = tier
            self.setupAdvice = setupAdvice
            self.simulators = simulators
            self.bridge = bridge
        }
    }

    public struct AppleTool: Codable, Sendable, Equatable {
        public var found: Bool
        public var version: String?
        public var expectedVersion: String?
        public var needsFirstLaunch: Bool
        public var overridden: Bool

        init(found: Bool, version: String? = nil, expectedVersion: String? = nil, needsFirstLaunch: Bool = false, overridden: Bool = false) {
            self.found = found
            self.version = version
            self.expectedVersion = expectedVersion
            self.needsFirstLaunch = needsFirstLaunch
            self.overridden = overridden
        }
    }

    public struct SimulatorCounts: Codable, Sendable, Equatable {
        public var listed: Bool
        public var total: Int
        public var booted: Int
        public var runtimes: Int?
        public var watcher: String?
        public var canvasReady: Int

        init(listed: Bool, total: Int, booted: Int, runtimes: Int? = nil, watcher: String? = nil, canvasReady: Int = 0) {
            self.listed = listed
            self.total = total
            self.booted = booted
            self.runtimes = runtimes
            self.watcher = watcher
            self.canvasReady = canvasReady
        }
    }

    // MARK: The app, the problem log, logs

    /// One window of the app; never a device identifier.
    public struct WindowInfo: Codable, Sendable, Equatable {
        /// "emulator", "phone", "simulator", "iPhone or iPad", "Pixel catalog"
        /// or "none".
        public var selection: String
        public var avd: String?
        public var screenStalled: Bool
        public var streamWarning: String?
        public var unresponsivePolls: Int
        public var recoveryCard: String?
        /// The foldable simulator the window shows (iPhone Duo); absent for
        /// any other selection, and in reports made before 2026-10-15.
        public var foldable: FoldableInfo?

        public init(
            selection: String,
            avd: String? = nil,
            screenStalled: Bool = false,
            streamWarning: String? = nil,
            unresponsivePolls: Int = 0,
            recoveryCard: String? = nil,
            foldable: FoldableInfo? = nil
        ) {
            self.selection = selection
            self.avd = avd
            self.screenStalled = screenStalled
            self.streamWarning = streamWarning
            self.unresponsivePolls = unresponsivePolls
            self.recoveryCard = recoveryCard
            self.foldable = foldable
        }
    }

    /// A foldable simulator as the app holds it: the fold it last sent, the
    /// panel it takes as lit and the one the live view shows, its last read
    /// of the two panels' screenshots and the stage around it. The app's own
    /// state, never asked of the simulator for the report.
    public struct FoldableInfo: Codable, Sendable, Equatable {
        /// The device type's model name ("iPhone Duo").
        public var model: String
        /// The hinge angle the app last sent, in degrees (0 closed, 180 flat).
        public var hingeAngle: Double
        public var posture: FoldPosture
        public var held: FoldHold
        /// The panel the app takes as lit.
        public var litPanel: FoldPanel
        /// The panel the live view shows; nil without a live view.
        public var shownPanel: FoldPanel?
        public var lastRead: PanelRead?
        /// The stage offers to lock and wake the simulator: a fold left both
        /// panels dark.
        public var screensStuck: Bool
        public var view: FoldView

        public init(
            model: String,
            hingeAngle: Double,
            posture: FoldPosture,
            held: FoldHold,
            litPanel: FoldPanel,
            shownPanel: FoldPanel?,
            lastRead: PanelRead?,
            screensStuck: Bool,
            view: FoldView
        ) {
            self.model = model
            self.hingeAngle = hingeAngle
            self.posture = posture
            self.held = held
            self.litPanel = litPanel
            self.shownPanel = shownPanel
            self.lastRead = lastRead
            self.screensStuck = screensStuck
            self.view = view
        }
    }

    public enum FoldPanel: String, Codable, Sendable, Equatable, CaseIterable {
        case outer
        case inner
    }

    /// The posture button the pill shows as current.
    public enum FoldPosture: String, Codable, Sendable, Equatable, CaseIterable {
        case closed
        case partiallyOpen = "partially open"
        case open
        case laptop
        case tent
        /// An angle no button stands for (the hinge slider's).
        case other
    }

    /// How the device is held.
    public enum FoldHold: String, Codable, Sendable, Equatable, CaseIterable {
        case portrait
        case upsideDown = "upside down"
        case landscapeLeft = "landscape left"
        case landscapeRight = "landscape right"
        case faceUp = "face up"
        case faceDown = "face down"
    }

    /// How the stage draws the device.
    public enum FoldView: String, Codable, Sendable, Equatable, CaseIterable {
        case turnable3D = "3D turnable"
        case front3D = "3D front"
        case flat2D = "2D"
    }

    /// The last read of a foldable's two panels' screenshots, which tells the
    /// lit panel.
    public struct PanelRead: Codable, Sendable, Equatable {
        /// Seconds between the read and the report.
        public var secondsAgo: Int
        public var outer: PanelReading?
        public var inner: PanelReading?
        /// The panel the read took as lit; nil when it could not tell.
        public var lit: FoldPanel?

        public init(secondsAgo: Int, outer: PanelReading?, inner: PanelReading?, lit: FoldPanel?) {
            self.secondsAgo = secondsAgo
            self.outer = outer
            self.inner = inner
            self.lit = lit
        }
    }

    /// One panel's screenshot: what it shows and its mean grey (0–255).
    public struct PanelReading: Codable, Sendable, Equatable {
        public var content: PanelContent
        public var grey: Int

        public init(content: PanelContent, grey: Int) {
            self.content = content
            self.grey = grey
        }
    }

    public enum PanelContent: String, Codable, Sendable, Equatable, CaseIterable {
        case dark
        case screen
        case bootLogo = "boot logo"
    }

    /// An error the app showed (`RecentProblemStore`).
    public struct RecentProblem: Codable, Sendable, Equatable {
        public var at: Date
        public var message: String
        public var details: [String]?
        /// How many times the same message arrived within the coalescing
        /// window.
        public var count: Int

        public init(at: Date, message: String, details: [String]? = nil, count: Int = 1) {
            self.at = at
            self.message = message
            self.details = details
            self.count = count
        }
    }

    /// The end of one emulator log.
    public struct LogTail: Codable, Sendable, Equatable {
        public var avd: String
        public var modified: Date
        /// The log file's size.
        public var bytes: Int
        public var lines: [String]
        /// Lines before these were left out.
        public var omittedLines: Bool

        init(avd: String, modified: Date, bytes: Int, lines: [String], omittedLines: Bool) {
            self.avd = avd
            self.modified = modified
            self.bytes = bytes
            self.lines = lines
            self.omittedLines = omittedLines
        }
    }

    /// A crash report's existence; its contents are never read.
    public struct CrashReportRef: Codable, Sendable, Equatable {
        public var process: String
        public var date: Date

        init(process: String, date: Date) {
            self.process = process
            self.date = date
        }
    }

    public struct CollectionInfo: Codable, Sendable, Equatable {
        public var milliseconds: Int
        /// What could not be read, and why.
        public var notes: [String]
        /// What the renderer cut to fit an issue.
        public var truncated: [String]
        /// How many values the scrubber replaced, by category: homePath,
        /// userName, fullName, hostName, phoneSerial, lanAddress, ipAddress, ipv6,
        /// macAddress, email, token, udid, uuid, secret.
        public var removed: [String: Int]

        public init(milliseconds: Int = 0, notes: [String] = [], truncated: [String] = [], removed: [String: Int] = [:]) {
            self.milliseconds = milliseconds
            self.notes = notes
            self.truncated = truncated
            self.removed = removed
        }
    }
}

// MARK: - Coding

extension ProblemReport {
    /// Every raw value of the report's string enums. The scrubber leaves a
    /// string equal to one of them alone: a user whose surname is "Blank"
    /// must not turn `"state": "blank"` into `"<name>"`, which the report
    /// could no longer be read back with. (`ProblemReportSourceGuardTests`
    /// checks that every enum of this file is listed.)
    public static let enumRawValues: Set<String> = Set(
        Producer.allCases.map(\.rawValue)
            + AppInfo.Kind.allCases.map(\.rawValue)
            + AppInfo.Location.allCases.map(\.rawValue)
            + TokenState.allCases.map(\.rawValue)
            + ImageState.allCases.map(\.rawValue)
            + ContentFolder.allCases.map(\.rawValue)
            + ConsoleOutcome.allCases.map(\.rawValue)
            + PropertyOutcome.allCases.map(\.rawValue)
            + FoldPanel.allCases.map(\.rawValue)
            + FoldPosture.allCases.map(\.rawValue)
            + FoldHold.allCases.map(\.rawValue)
            + FoldView.allCases.map(\.rawValue)
            + PanelContent.allCases.map(\.rawValue)
    )

    /// The report's JSON: pretty, with sorted keys and unescaped slashes, and
    /// dates as ISO 8601 (UTC, whole seconds).
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The report as JSON text.
    public func jsonText() throws -> String {
        String(decoding: try Self.encoder().encode(self), as: UTF8.self)
    }

    /// A report decoded from its JSON.
    public static func decode(jsonText: String) throws -> ProblemReport {
        try decoder().decode(ProblemReport.self, from: Data(jsonText.utf8))
    }
}
