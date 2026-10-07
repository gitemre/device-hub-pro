import Foundation

/// "Save App State…" and "Restore App State…": a zip of an app's data
/// container, for a tester to keep a state and go back to it. The zip is made
/// and read with `/usr/bin/ditto` (keeping modes, times and links); its root
/// is the container's own contents. The caller stops the app first.
public enum AppDataStateArchive {
    public enum ArchiveError: Error, Equatable, CustomStringConvertible {
        case failed(String)
        case notAnArchive(String)
        case emptyArchive

        public var description: String {
            switch self {
            case .failed(let message): "ditto failed: \(message)"
            case .notAnArchive(let name): "“\(name)” is not an app state archive (a .zip)."
            case .emptyArchive: "The archive holds nothing to restore."
            }
        }
    }

    public static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
    static let timeout: Duration = .seconds(300)

    /// The suggested file name: `<bundle id> <yyyy-MM-dd HH.mm.ss>.zip`.
    public static func suggestedName(bundleIdentifier: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "\(bundleIdentifier) \(formatter.string(from: date)).zip"
    }

    /// Zips the contents of `container` into `archive` (replacing a file there).
    public static func save(container: URL, to archive: URL) async throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: archive.path) { try manager.removeItem(at: archive) }
        let result = try await ProcessRunner.run(
            executable: ditto,
            arguments: ["-c", "-k", "--sequesterRsrc", container.path, archive.path],
            timeout: timeout
        )
        guard result.exitCode == 0 else { throw ArchiveError.failed(result.standardErrorText) }
    }

    /// Unzips `archive` into a staging folder, then, once that worked, empties
    /// `container` (its container-manager metadata stays) and moves the
    /// staged items in. A bad archive leaves the container as it was.
    public static func restore(
        archive: URL,
        into container: URL,
        stagingDirectory: URL = FileManager.default.temporaryDirectory
    ) async throws {
        guard archive.pathExtension.lowercased() == "zip" else {
            throw ArchiveError.notAnArchive(archive.lastPathComponent)
        }
        let manager = FileManager.default
        let staging = stagingDirectory.appendingPathComponent("DeviceHubPro-restore-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        let result = try await ProcessRunner.run(
            executable: ditto,
            arguments: ["-x", "-k", archive.path, staging.path],
            timeout: timeout
        )
        guard result.exitCode == 0 else { throw ArchiveError.failed(result.standardErrorText) }
        let metadata = AppDataBrowser.metadataFileName
        let incoming = try manager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != metadata && $0.lastPathComponent != "__MACOSX" }
        guard !incoming.isEmpty else { throw ArchiveError.emptyArchive }
        for item in try manager.contentsOfDirectory(at: container, includingPropertiesForKeys: nil)
        where item.lastPathComponent != metadata {
            try manager.removeItem(at: item)
        }
        for item in incoming {
            try manager.moveItem(at: item, to: container.appendingPathComponent(item.lastPathComponent))
        }
    }
}
