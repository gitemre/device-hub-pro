import Foundation

/// One item of an app's data container, for the data inspector.
public struct AppDataEntry: Sendable, Equatable, Identifiable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    /// A file's size in bytes; a folder's total (the sum of what it holds).
    public let size: Int64
    public let modified: Date?

    public var id: String { url.path }
}

/// The inspector's reads and file operations over an app's data container (or
/// one of its app group containers) on the Mac. Every operation that names an
/// item checks that it lies inside the `root` it was given (symbolic links in
/// the path are resolved first), so a link inside a container cannot lead the
/// inspector out of it.
public enum AppDataBrowser {
    public enum BrowserError: Error, Equatable, CustomStringConvertible {
        case outsideRoot(String)
        case isRoot

        public var description: String {
            switch self {
            case .outsideRoot(let path): "\(path) is outside the app's container."
            case .isRoot: "The container itself cannot be deleted."
            }
        }
    }

    /// The file the container manager keeps its own metadata in; the
    /// inspector lists it like any file but never deletes it.
    public static let metadataFileName = ".com.apple.mobile_container_manager.metadata.plist"

    /// The path of `url` with the links of its parent folders resolved (the
    /// item itself, if a link, stays one).
    public static func resolvedPath(_ url: URL) -> String {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        return parent.appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
    }

    /// Whether `url` is `root` or lies inside it.
    public static func isInside(_ url: URL, root: URL) -> Bool {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = resolvedPath(url)
        return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private static func requireInside(_ url: URL, root: URL) throws {
        guard isInside(url, root: root) else { throw BrowserError.outsideRoot(url.path) }
    }

    /// The items of `directory`, folders first, each group in Finder's order.
    /// A folder's size is the total of its files.
    public static func entries(in directory: URL, root: URL) throws -> [AppDataEntry] {
        try requireInside(directory, root: root)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: []
        )
        let entries: [AppDataEntry] = urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isLink = values?.isSymbolicLink ?? false
            // A link is shown as itself, never followed.
            let isDirectory = !isLink && (values?.isDirectory ?? false)
            return AppDataEntry(
                url: url,
                name: url.lastPathComponent,
                isDirectory: isDirectory,
                isSymbolicLink: isLink,
                size: isDirectory ? totalSize(of: url) : Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate
            )
        }
        return entries.sorted { first, second in
            if first.isDirectory != second.isDirectory { return first.isDirectory }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
    }

    /// The total size in bytes of the regular files under `folder`.
    public static func totalSize(of folder: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    /// Copies a file or folder out of the container into `folder` under its own
    /// name (`name 2`… when taken) and returns the copy.
    public static func export(_ item: URL, root: URL, to folder: URL) throws -> URL {
        try requireInside(item, root: root)
        let manager = FileManager.default
        let base = item.deletingPathExtension().lastPathComponent
        let fileExtension = item.pathExtension
        var destination = folder.appendingPathComponent(item.lastPathComponent)
        var number = 2
        while manager.fileExists(atPath: destination.path) {
            let name = fileExtension.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(fileExtension)"
            destination = folder.appendingPathComponent(name)
            number += 1
        }
        try manager.copyItem(at: item, to: destination)
        return destination
    }

    /// Deletes a file or folder inside the container (never the container
    /// itself, and never the container manager's metadata file).
    public static func delete(_ item: URL, root: URL) throws {
        try requireInside(item, root: root)
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedPath(item) != rootPath else { throw BrowserError.isRoot }
        guard item.lastPathComponent != metadataFileName else { throw BrowserError.outsideRoot(item.path) }
        try FileManager.default.removeItem(at: item)
    }

    /// The `Library/Preferences/<bundle>.plist` of a data container: the
    /// app's standard UserDefaults.
    public static func preferencesURL(dataContainer: URL, bundleIdentifier: String) -> URL {
        dataContainer
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent(bundleIdentifier + ".plist")
    }

    /// Whether a file is a SQLite database the inspector can open: by its
    /// extension (or none), then by the 16-byte header every SQLite file has.
    public static func isSQLiteDatabase(_ url: URL) -> Bool {
        let extensions: Set<String> = ["sqlite", "sqlite3", "db", "db3", "sqlitedb", "store"]
        let fileExtension = url.pathExtension.lowercased()
        guard fileExtension.isEmpty || extensions.contains(fileExtension),
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 16)) ?? Data()
        return header == Data("SQLite format 3\u{0}".utf8)
    }

    /// The SQLite databases under `folder` (at most `limit`), in path order.
    public static func sqliteDatabases(under folder: URL, limit: Int = 200) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: []
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            if isSQLiteDatabase(url) { result.append(url) }
            if result.count >= limit { break }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Whether a file is a property list (`.plist`).
    public static func isPropertyList(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "plist"
    }
}

extension SimctlClient {
    /// Whether the app has a running process on the simulator: the launchd job
    /// `UIKitApplication:<bundle>[…]` with a pid.
    public func isAppRunning(udid: String, bundleIdentifier: String) async throws -> Bool {
        try Self.validateBundleIdentifier(bundleIdentifier)
        let jobs = try await launchdJobs(udid: udid)
        return Self.isAppRunning(bundleIdentifier: bundleIdentifier, in: jobs)
    }

    public static func isAppRunning(bundleIdentifier: String, in jobs: [SimulatorLaunchdJob]) -> Bool {
        jobs.contains { $0.label.hasPrefix("UIKitApplication:\(bundleIdentifier)[") && $0.pid != nil }
    }
}
