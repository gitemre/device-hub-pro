import Foundation

// Result shapes of the read-only `devicectl device info` subcommands run
// against a physical iPhone. They follow the captures under
// `Tests/DeviceHubProKitTests/Fixtures/ios27-device/` (CoreDevice 642.16, JSON
// version 5) and decode leniently: Apple versions this JSON, so every field
// is optional except the ones a list is keyed by. `details` and `appearance`
// reuse `DevicectlDeviceDetails`, `DevicectlAppearance`, `DevicectlVoiceOver`
// and `DevicectlAudio`, whose shapes match.

/// `device info apps`. The first capture is an iPhone with no installed apps;
/// the second lists the developer-installed verifier.
public struct DevicectlAppList: Decodable, Sendable, Equatable {
    public let deviceIdentifier: String?
    public let apps: [DevicectlInstalledApp]
    public let defaultAppsIncluded: Bool?
    public let hiddenAppsIncluded: Bool?
    public let internalAppsIncluded: Bool?
    public let removableAppsIncluded: Bool?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceIdentifier = try container.decodeIfPresent(String.self, forKey: .deviceIdentifier)
        apps = try container.decodeIfPresent([DevicectlInstalledApp].self, forKey: .apps) ?? []
        defaultAppsIncluded = try container.decodeIfPresent(Bool.self, forKey: .defaultAppsIncluded)
        hiddenAppsIncluded = try container.decodeIfPresent(Bool.self, forKey: .hiddenAppsIncluded)
        internalAppsIncluded = try container.decodeIfPresent(Bool.self, forKey: .internalAppsIncluded)
        removableAppsIncluded = try container.decodeIfPresent(Bool.self, forKey: .removableAppsIncluded)
    }

    private enum CodingKeys: String, CodingKey {
        case deviceIdentifier, apps, defaultAppsIncluded, hiddenAppsIncluded
        case internalAppsIncluded, removableAppsIncluded
    }
}

/// One `apps[]` entry of `device info apps`, as captured after the verifier
/// was installed (`devicectl-info-apps-after-install.json`). The bundle
/// identifier is what the list is keyed by and is required; every other key
/// is optional, because Apple versions this JSON.
public struct DevicectlInstalledApp: Decodable, Sendable, Equatable {
    public let bundleIdentifier: String
    public let name: String?
    /// `CFBundleShortVersionString`.
    public let version: String?
    /// `CFBundleVersion`.
    public let bundleVersion: String?
    /// The bundle's `file://` URL under `/private/var/containers/Bundle/Application`.
    public let url: String?
    public let appClip: Bool?
    public let builtByDeveloper: Bool?
    /// Whether `copy from` may read the app's data container (a development
    /// build with `get-task-allow`).
    public let containerAccessible: Bool?
    public let defaultApp: Bool?
    public let hidden: Bool?
    public let internalApp: Bool?
    public let removable: Bool?
}

/// `device info processes`.
public struct DevicectlProcessList: Decodable, Sendable, Equatable {
    public let deviceIdentifier: String?
    public let runningProcesses: [DevicectlRunningProcess]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceIdentifier = try container.decodeIfPresent(String.self, forKey: .deviceIdentifier)
        runningProcesses = try container.decodeIfPresent([DevicectlRunningProcess].self, forKey: .runningProcesses) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case deviceIdentifier, runningProcesses
    }
}

/// One `runningProcesses[]` entry: the executable's file URL and the pid.
public struct DevicectlRunningProcess: Decodable, Sendable, Equatable {
    public let executable: String?
    public let processIdentifier: Int?
}

/// `device info displays`.
public struct DevicectlDisplays: Decodable, Sendable, Equatable {
    public let backlightState: String?
    public let displays: [DevicectlDisplay]
    public let orientation: DevicectlDisplayOrientation?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backlightState = try container.decodeIfPresent(String.self, forKey: .backlightState)
        displays = try container.decodeIfPresent([DevicectlDisplay].self, forKey: .displays) ?? []
        orientation = try container.decodeIfPresent(DevicectlDisplayOrientation.self, forKey: .orientation)
    }

    private enum CodingKeys: String, CodingKey {
        case backlightState, displays, orientation
    }
}

/// One `displays[]` entry.
public struct DevicectlDisplay: Decodable, Sendable, Equatable {
    public let displayId: Int?
    public let name: String?
    public let primary: Bool?
    /// The display's origin and size in pixels: `[[x, y], [width, height]]`.
    public let bounds: [[Double]]?
    /// Pixels: `[width, height]`.
    public let nativeSize: [Double]?
    /// Inches: `[width, height]`.
    public let physicalSize: [Double]?
    public let pointScale: Double?
    /// Device Hub's chrome name, e.g. "com.apple.dt.devicekit.chrome.phone4".
    public let chromeIdentifier: String?
    public let framebufferMaskIdentifier: String?
    /// "rot0", …
    public let currentOrientation: String?
    public let nativeOrientation: String?
}

/// The `orientation` block of `device info displays`.
public struct DevicectlDisplayOrientation: Decodable, Sendable, Equatable {
    public let currentDeviceOrientation: String?
    public let currentDeviceNonFlatOrientation: String?
    public let currentDeviceOrientationLocked: Bool?
}

/// `device info lockState`.
public struct DevicectlLockState: Decodable, Sendable, Equatable {
    public let deviceIdentifier: String?
    public let passcodeRequired: Bool?
    public let unlockedSinceBoot: Bool?
}

/// `device info ddiServices`.
public struct DevicectlDDIServices: Decodable, Sendable, Equatable {
    public let deviceIdentifier: String?
    public let ddiMetadata: DevicectlDDIMetadata?
}

/// The `ddiMetadata` block: the Developer Disk Image mounted on the device.
public struct DevicectlDDIMetadata: Decodable, Sendable, Equatable {
    public let buildUpdate: String?
    public let platform: String?
    /// "external", …
    public let variant: String?
    public let isUsable: Bool?
    public let isCryptexDDI: Bool?
    public let contentIsCompatible: Bool?
    public let developmentRevision: Int?
    public let enforcingCoreDeviceVersionChecks: Bool?
    public let coreDeviceVersionChecksIncludeDevelopmentRevision: Bool?
    public let projectMetadata: [DevicectlDDIProject]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        buildUpdate = try container.decodeIfPresent(String.self, forKey: .buildUpdate)
        platform = try container.decodeIfPresent(String.self, forKey: .platform)
        variant = try container.decodeIfPresent(String.self, forKey: .variant)
        isUsable = try container.decodeIfPresent(Bool.self, forKey: .isUsable)
        isCryptexDDI = try container.decodeIfPresent(Bool.self, forKey: .isCryptexDDI)
        contentIsCompatible = try container.decodeIfPresent(Bool.self, forKey: .contentIsCompatible)
        developmentRevision = try container.decodeIfPresent(Int.self, forKey: .developmentRevision)
        enforcingCoreDeviceVersionChecks = try container.decodeIfPresent(
            Bool.self,
            forKey: .enforcingCoreDeviceVersionChecks
        )
        coreDeviceVersionChecksIncludeDevelopmentRevision = try container.decodeIfPresent(
            Bool.self,
            forKey: .coreDeviceVersionChecksIncludeDevelopmentRevision
        )
        projectMetadata = try container.decodeIfPresent([DevicectlDDIProject].self, forKey: .projectMetadata) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case buildUpdate, platform, variant, isUsable, isCryptexDDI, contentIsCompatible
        case developmentRevision, enforcingCoreDeviceVersionChecks
        case coreDeviceVersionChecksIncludeDevelopmentRevision, projectMetadata
    }
}

/// One `projectMetadata[]` entry: a component of the DDI and its version.
public struct DevicectlDDIProject: Decodable, Sendable, Equatable {
    public let name: String?
    public let version: String?
}
