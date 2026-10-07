import Foundation

// Result shapes of the actions `DevicectlPhysicalClient` runs against a
// physical iPhone. They follow the captures under
// `Tests/DeviceHubProKitTests/Fixtures/ios27-device/` (CoreDevice 642.16, JSON
// version 5) and decode leniently: Apple versions this JSON, so every field
// is optional except the ones a list or a call is keyed by.

/// A `process` block: the executable's file URL and the pid. `launch` and
/// `openURL` add an `auditToken`, which is not read.
public struct DevicectlProcess: Decodable, Sendable, Equatable {
    public let executable: String?
    public let processIdentifier: Int
}

/// `device install app`.
public struct DevicectlInstallResult: Decodable, Sendable, Equatable {
    public let deviceIdentifier: String?
    public let installedApplications: [DevicectlInstalledApplication]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceIdentifier = try container.decodeIfPresent(String.self, forKey: .deviceIdentifier)
        installedApplications = try container.decodeIfPresent(
            [DevicectlInstalledApplication].self,
            forKey: .installedApplications
        ) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case deviceIdentifier, installedApplications
    }
}

/// One `installedApplications[]` entry of `device install app`.
public struct DevicectlInstalledApplication: Decodable, Sendable, Equatable {
    public let bundleID: String
    public let databaseSequenceNumber: Int?
    public let databaseUUID: String?
    /// The new bundle's `file://` URL.
    public let installationURL: String?
    public let launchServicesIdentifier: String?
}

/// `device uninstall app`. The answer is a success even when the app was not
/// installed (captured in `devicectl-uninstall-app-missing.json`).
public struct DevicectlUninstallResult: Decodable, Sendable, Equatable {
    public let deviceIdentifier: String?
    public let uninstalledApplications: [DevicectlUninstalledApplication]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceIdentifier = try container.decodeIfPresent(String.self, forKey: .deviceIdentifier)
        uninstalledApplications = try container.decodeIfPresent(
            [DevicectlUninstalledApplication].self,
            forKey: .uninstalledApplications
        ) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case deviceIdentifier, uninstalledApplications
    }
}

public struct DevicectlUninstalledApplication: Decodable, Sendable, Equatable {
    public let bundleID: String
}

/// `device process launch`.
public struct DevicectlLaunchResult: Decodable, Sendable, Equatable {
    public struct Options: Decodable, Sendable, Equatable {
        public let activatedWhenStarted: Bool?
        public let arguments: [String]
        public let startStopped: Bool?
        public let terminateExistingInstances: Bool?

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            activatedWhenStarted = try container.decodeIfPresent(Bool.self, forKey: .activatedWhenStarted)
            arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
            startStopped = try container.decodeIfPresent(Bool.self, forKey: .startStopped)
            terminateExistingInstances = try container.decodeIfPresent(Bool.self, forKey: .terminateExistingInstances)
        }

        private enum CodingKeys: String, CodingKey {
            case activatedWhenStarted, arguments, startStopped, terminateExistingInstances
        }
    }

    public let deviceIdentifier: String?
    public let launchOptions: Options?
    public let process: DevicectlProcess

    /// The launched process's pid, what `terminate(pid:)` takes.
    public var processIdentifier: Int { process.processIdentifier }
}

/// `device process terminate`.
public struct DevicectlTerminateResult: Decodable, Sendable, Equatable {
    public struct Signal: Decodable, Sendable, Equatable {
        public let name: String?
        public let value: Int?
    }

    public let deviceIdentifier: String?
    /// The device's clock when it sent the signal (ISO 8601).
    public let deviceTimestamp: String?
    public let process: DevicectlProcess
    public let signal: Signal?
}

/// `device process openURL`: the process that took the URL (an installed
/// browser for an https URL).
public struct DevicectlOpenURLResult: Decodable, Sendable, Equatable {
    public let deviceIdentifier: String?
    public let process: DevicectlProcess?
    public let url: String?
}

/// `device capture screenshot`. The image is written to `destination`.
public struct DevicectlScreenshotResult: Decodable, Sendable, Equatable {
    public let deviceIdentifier: String?
    /// A `file://` URL.
    public let destination: String?
    /// "png".
    public let imageFormat: String?
    /// Pixels.
    public let width: Int?
    public let height: Int?
}

/// `device capture screen-record`. The iPhone 12 on iOS 27 never answers
/// with a result (1001, unsupported), so the success body is not captured:
/// only the keys the neighbouring capture command uses are read, both
/// optional.
public struct DevicectlScreenRecordResult: Decodable, Sendable, Equatable {
    public let deviceIdentifier: String?
    public let destination: String?
}

/// `device copy from`. The file is written to `destination`.
public struct DevicectlCopyResult: Decodable, Sendable, Equatable {
    public let deviceIdentifier: String?
    /// A `file://` URL.
    public let destination: String?
    public let domain: String?
    public let domainIdentifier: String?
    public let source: String?
}

/// `device info files`: the entries of one domain, depth first, with paths
/// relative to the domain's root.
public struct DevicectlFileList: Decodable, Sendable, Equatable {
    public let deviceIdentifier: String?
    public let domain: String?
    public let domainIdentifier: String?
    public let files: [DevicectlDeviceFile]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceIdentifier = try container.decodeIfPresent(String.self, forKey: .deviceIdentifier)
        domain = try container.decodeIfPresent(String.self, forKey: .domain)
        domainIdentifier = try container.decodeIfPresent(String.self, forKey: .domainIdentifier)
        files = try container.decodeIfPresent([DevicectlDeviceFile].self, forKey: .files) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case deviceIdentifier, domain, domainIdentifier, files
    }
}

/// One `files[]` entry.
public struct DevicectlDeviceFile: Decodable, Sendable, Equatable {
    public struct Metadata: Decodable, Sendable, Equatable {
        /// Bytes (a directory's own entry size).
        public let size: Int?
        /// The POSIX mode as a decimal number (493 is 0o755).
        public let permissions: Int?
        public let lastModDate: String?
        public let ownerUid: Int?
        public let ownerGid: Int?
    }

    public struct Resources: Decodable, Sendable, Equatable {
        public let isDirectory: Bool?
        public let isHidden: Bool?
        public let isReadable: Bool?
        public let isSymbolicLink: Bool?
        public let isWritable: Bool?
    }

    public let name: String?
    public let relativePath: String
    public let metadata: Metadata?
    public let resources: Resources?

    public var isDirectory: Bool { resources?.isDirectory == true }
}

/// `device info appIcon`: where the PNG was written and which size
/// the device honoured (`devicectl-info-appIcon.json`).
public struct DevicectlAppIconResult: Decodable, Sendable, Equatable {
    /// The `file://` URL of the written PNG.
    public let destination: String?
    public let icon: Icon?

    public struct Icon: Decodable, Sendable, Equatable {
        public let placeholder: Bool?
        public let scale: Double?
        public let pixelSize: Size?
        public let size: Size?
    }

    public struct Size: Decodable, Sendable, Equatable {
        public let width: Double?
        public let height: Double?
    }
}
