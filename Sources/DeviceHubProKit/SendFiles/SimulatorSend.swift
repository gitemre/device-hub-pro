import Foundation

/// Where Send Files puts a file on an iOS simulator when it is not media,
/// an app or a certificate.
public enum SimulatorFilesDestination: Sendable, Equatable, Hashable {
    /// The Files app's "On My iPhone": the `File Provider Storage` folder of
    /// the Files app's `group.com.apple.FileProvider.LocalStorage` app group.
    case filesApp
    /// The `Documents` folder of an installed app's data container.
    case appDocuments(bundleIdentifier: String)

    /// The text kept in the preferences.
    public var storedValue: String {
        switch self {
        case .filesApp: "files"
        case .appDocuments(let bundleIdentifier): "app:" + bundleIdentifier
        }
    }

    public static func from(storedValue: String?) -> SimulatorFilesDestination? {
        guard let storedValue else { return nil }
        if storedValue == "files" { return .filesApp }
        if storedValue.hasPrefix("app:") {
            let identifier = String(storedValue.dropFirst(4))
            return (try? SimctlClient.validateBundleIdentifier(identifier)) != nil ? .appDocuments(bundleIdentifier: identifier) : nil
        }
        return nil
    }
}

/// What the Send Files path does with each file for a simulator: the drops
/// `SimulatorDropRouting` already knows (apps install, photos / videos /
/// contact cards go to Photos and Contacts, certificates are trusted, links
/// open) pass through; every other file or folder becomes a copy into the
/// Files app (or a chosen app's Documents).
public enum SimulatorSendRouting {
    public struct Plan: Sendable, Equatable {
        /// The files `SimulatorDropRouting` takes, with the links, in order.
        public var existing: [URL]
        /// Files and folders to copy.
        public var files: [URL]
        /// `.apns` push payloads, sent with `simctl push` in this order.
        public var pushes: [URL] = []
    }

    public static func plan(_ urls: [URL]) -> Plan {
        var plan = Plan(existing: [], files: [])
        for url in urls {
            if SimulatorPushFile.isPushFile(url) {
                plan.pushes.append(url)
            } else if url.isFileURL, case .unsupported = SimulatorDropRouting.route(url) {
                plan.files.append(url)
            } else {
                plan.existing.append(url)
            }
        }
        return plan
    }
}

extension SimctlClient {
    /// `get_app_container <udid> <bundle> groups` prints one `<group id>\t<path>`
    /// line per app group (measured on Xcode 27.0, iOS 27.0, the Files app).
    public static func appGroups(from text: String) -> [String: URL] {
        var groups: [String: URL] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count == 2, fields[0].hasPrefix("group.") else { continue }
            groups[String(fields[0])] = URL(fileURLWithPath: String(fields[1]), isDirectory: true)
        }
        return groups
    }

    /// The Files app's bundle identifier and the app group whose
    /// `File Provider Storage` folder is "On My iPhone".
    public static let filesAppBundleIdentifier = "com.apple.DocumentsApp"
    public static let fileProviderGroup = "group.com.apple.FileProvider.LocalStorage"

    /// The folder Files shows as "On My iPhone" for `udid`, created when the
    /// Files app has not made it yet (it makes it on its first launch).
    public func filesAppStorage(udid: String) async throws -> URL {
        try Self.validateUDID(udid)
        let output = try await checked(["get_app_container", udid, Self.filesAppBundleIdentifier, "groups"])
        guard let group = Self.appGroups(from: output.standardOutputText)[Self.fileProviderGroup] else {
            throw SimctlClientError.invalidValue("the Files app's storage group is not on this simulator")
        }
        let storage = group.appendingPathComponent("File Provider Storage", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        return storage
    }

    /// The `Documents` folder of an app's data container on `udid`.
    public func appDocumentsFolder(udid: String, bundleIdentifier: String) async throws -> URL {
        try Self.validateUDID(udid)
        try Self.validateBundleIdentifier(bundleIdentifier)
        let output = try await checked(["get_app_container", udid, bundleIdentifier, "data"])
        let path = output.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else {
            throw SimctlClientError.invalidValue("no data container for \(bundleIdentifier)")
        }
        let documents = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        return documents
    }

    /// Copies each of `items` (a folder keeps its tree) into `folder`,
    /// replacing an item of the same name. Returns how many items were copied.
    @discardableResult
    public static func copyItems(_ items: [URL], into folder: URL) throws -> Int {
        let fileManager = FileManager.default
        var copied = 0
        for item in items {
            let target = folder.appendingPathComponent(item.lastPathComponent)
            if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
            try fileManager.copyItem(at: item, to: target)
            copied += 1
        }
        return copied
    }
}
