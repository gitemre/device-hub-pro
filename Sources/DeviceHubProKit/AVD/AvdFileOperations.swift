import Foundation

/// Errors surfaced by `AvdFileOperations`.
public enum AvdFileOperationError: Error, LocalizedError, CustomStringConvertible {
    case avdNotFound(String)
    case invalidName(String, suggestion: String)
    case destinationExists(String)
    case configUnreadable(String)
    case directoryUnreadable(String)
    case renameFailed(String, reason: String, rollbackFailures: [String])

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .avdNotFound(let name):
            return "The AVD \"\(name)\" was not found."
        case .invalidName(_, let suggestion):
            return "AVD names may use letters, digits, \".\", \"_\" and \"-\". Try \"\(suggestion)\"."
        case .destinationExists(let name):
            return "An AVD named \"\(name)\" already exists."
        case .configUnreadable(let name):
            return "Couldn't read the config.ini of \"\(name)\", so nothing was renamed."
        case .directoryUnreadable(let name):
            return "Couldn't read the AVD directory of \"\(name)\"."
        case .renameFailed(let name, let reason, let rollbackFailures):
            guard !rollbackFailures.isEmpty else {
                return "Couldn't rename \"\(name)\": \(reason)"
            }
            return "Couldn't rename \"\(name)\": \(reason) The rollback could not restore "
                + rollbackFailures.joined(separator: "; ") + "."
        }
    }
}

/// The verified running state of an AVD.
public enum AvdRunState: Sendable, Equatable {
    case running
    case stopped
    /// The state could not be established; destructive callers must refuse.
    case unknown
}

/// Recoverable AVD file mutations. An AVD is `<Name>.ini` in `avdHome` (see
/// `AvdConfig.homeURL`) plus the content directory that ini points at —
/// usually `<avdHome>/<Name>.avd/`, but `avdmanager create avd -p <dir>` puts
/// it anywhere (`AvdConfig.contentDirectory`). Callers only run these on
/// stopped AVDs.
public enum AvdFileOperations {
    /// Moves `<Name>.ini` and the AVD's content directory (wherever its
    /// `path=` points) to `trash` (the macOS Trash by default) so the
    /// deletion stays recoverable.
    public static func delete(
        avdName: String,
        avdHome: URL,
        trash: (URL) throws -> Void = AvdFileOperations.defaultTrash
    ) throws {
        let fileManager = FileManager.default
        let items = [
            iniURL(avdName: avdName, avdHome: avdHome),
            AvdConfig.contentDirectory(avdName: avdName, avdHome: avdHome),
        ].filter { fileManager.fileExists(atPath: $0.path) }
        guard !items.isEmpty else { throw AvdFileOperationError.avdNotFound(avdName) }
        for item in items {
            try trash(item)
        }
    }

    /// Renames an AVD. For the usual layout it rewrites `path=`/`path.rel=` in
    /// `<Name>.ini`, then moves the ini and the `<Name>.avd/` directory. An AVD
    /// whose content lives elsewhere (a custom `path=`) keeps its directory
    /// where it is — only the ini is renamed, as `avdmanager move avd -r`
    /// does. A case-only rename (`pixel_9` → `Pixel_9`) works on the default
    /// case-insensitive volume. If a step fails after anything has been moved
    /// or rewritten, the original names and bytes are restored; any restore
    /// that also fails is named in the thrown `.renameFailed` error.
    @discardableResult
    public static func rename(
        avdName: String,
        to newName: String,
        avdHome: URL,
        move: (URL, URL) throws -> Void = AvdFileOperations.defaultMoveItem
    ) throws -> String {
        let sanitized = AvdmanagerClient.sanitizedAvdName(newName)
        guard sanitized == newName, !newName.isEmpty else {
            throw AvdFileOperationError.invalidName(newName, suggestion: sanitized)
        }
        guard newName != avdName else { return avdName }

        let fileManager = FileManager.default
        let ini = iniURL(avdName: avdName, avdHome: avdHome)
        let directory = AvdConfig.contentDirectory(avdName: avdName, avdHome: avdHome)
        let defaultDirectory = directoryURL(avdName: avdName, avdHome: avdHome)
        // Only a directory in the default place follows the name; a custom
        // location (possibly another volume) stays put.
        let movesDirectory = directory.standardizedFileURL == defaultDirectory.standardizedFileURL
            || isSameItem(directory, defaultDirectory)
        let newIni = iniURL(avdName: newName, avdHome: avdHome)
        let newDirectory = movesDirectory
            ? directoryURL(avdName: newName, avdHome: avdHome)
            : directory

        guard fileManager.fileExists(atPath: ini.path),
              fileManager.fileExists(atPath: directory.path)
        else {
            throw AvdFileOperationError.avdNotFound(avdName)
        }
        // On a case-insensitive volume the destination of a case-only rename
        // "exists" because it is the source itself; that is not a conflict.
        guard !isOccupied(newIni, byOtherThan: ini),
              !movesDirectory || !isOccupied(newDirectory, byOtherThan: directory)
        else {
            throw AvdFileOperationError.destinationExists(newName)
        }

        let originalIni = try String(contentsOf: ini, encoding: .utf8)

        // `AvdId`/`avd.ini.displayname` follow the id when they still carry the
        // old name; a custom display name is left alone. A missing config.ini
        // is deliberately accepted (the rename needs only the ini), but an
        // existing unreadable one refuses the rename before anything changes.
        let config = directory.appendingPathComponent("config.ini")
        let originalConfig: String?
        if fileManager.fileExists(atPath: config.path) {
            do {
                originalConfig = try String(contentsOf: config, encoding: .utf8)
            } catch {
                throw AvdFileOperationError.configUnreadable(avdName)
            }
        } else {
            originalConfig = nil
        }
        let updatedConfig = originalConfig.map {
            rewritingNames(in: $0, from: avdName, to: newName)
        }

        let iniIsRewritten = movesDirectory
        if iniIsRewritten {
            let updatedIni = rewritingPaths(in: originalIni, avdName: newName, avdHome: avdHome)
            try updatedIni.write(to: ini, atomically: true, encoding: .utf8)
        }

        // What actually happened, so the rollback undoes exactly that (an
        // existence check cannot tell apart the two names of a case-only
        // rename).
        var iniWasMoved = false
        var directoryWasMoved = false
        do {
            try move(ini, newIni)
            iniWasMoved = true
            if movesDirectory {
                try move(directory, newDirectory)
                directoryWasMoved = true
            }
            if let updatedConfig {
                try updatedConfig.write(
                    to: newDirectory.appendingPathComponent("config.ini"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        } catch {
            // The atomic config.ini write is the last step: when it throws the
            // old file is untouched, so only the moves need undoing.
            var rollbackFailures: [String] = []

            if directoryWasMoved {
                do {
                    try move(newDirectory, directory)
                } catch {
                    rollbackFailures.append(
                        "\(newDirectory.lastPathComponent) (\(error.localizedDescription))"
                    )
                }
            }
            if iniWasMoved {
                do {
                    try move(newIni, ini)
                } catch {
                    rollbackFailures.append(
                        "\(newIni.lastPathComponent) (\(error.localizedDescription))"
                    )
                }
            }
            if iniIsRewritten {
                do {
                    try originalIni.write(to: ini, atomically: true, encoding: .utf8)
                } catch {
                    rollbackFailures.append(
                        "\(ini.lastPathComponent) content (\(error.localizedDescription))"
                    )
                }
            }

            throw AvdFileOperationError.renameFailed(
                avdName,
                reason: error.localizedDescription,
                rollbackFailures: rollbackFailures
            )
        }
        return newName
    }

    /// Removes the writable state of an AVD — `userdata` files and snapshot
    /// directories — and keeps `config.ini`, so the next boot starts clean.
    /// Returns the URLs that were removed.
    public static func wipeData(avdName: String, avdHome: URL) throws -> [URL] {
        let fileManager = FileManager.default
        let directory = AvdConfig.contentDirectory(avdName: avdName, avdHome: avdHome)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw AvdFileOperationError.avdNotFound(avdName)
        }
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        } catch {
            // Never report a clean wipe for a directory we could not read.
            throw AvdFileOperationError.directoryUnreadable(avdName)
        }
        let targets = entries.filter {
            userDataFiles.contains($0.lastPathComponent)
                || $0.lastPathComponent.lowercased().hasPrefix("snapshot")
        }
        var removed: [URL] = []
        for target in targets {
            try fileManager.removeItem(at: target)
            removed.append(target)
        }
        return removed
    }

    /// Whether `avdName` is currently running (exact name match).
    public static func isRunning(avdName: String, runningEmulators: [RunningEmulator]) -> Bool {
        runningEmulators.contains { $0.avd == avdName }
    }

    /// Classifies an AVD's running state from a process query that may fail.
    /// A throwing query is `.unknown` — the fail-closed answer destructive
    /// callers must treat as "do not proceed".
    public static func runState(
        avdName: String,
        runningEmulators: @Sendable () async throws -> [RunningEmulator]
    ) async -> AvdRunState {
        await runState {
            isRunning(avdName: avdName, runningEmulators: try await runningEmulators())
        }
    }

    /// Classifies an AVD's running state from a check that may fail (such
    /// as `EmulatorManager.isAnyVMRunning(avd:)`). A throwing check is
    /// `.unknown`, as above.
    public static func runState(isRunning: @Sendable () async throws -> Bool) async -> AvdRunState {
        do {
            return try await isRunning() ? .running : .stopped
        } catch {
            return .unknown
        }
    }

    /// Moves an item on disk; the production default for `rename`.
    public static func defaultMoveItem(_ from: URL, _ to: URL) throws {
        try FileManager.default.moveItem(at: from, to: to)
    }

    /// Moves an item to the macOS Trash; the production default for `delete`.
    public static func defaultTrash(_ url: URL) throws {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
    }

    /// The userdata images a wipe removes (the qcow2 overlay included, so the
    /// emulator cannot resurrect the old state on the next boot).
    private static let userDataFiles: Set<String> = [
        "userdata-qemu.img", "userdata.img", "userdata-qemu.img.qcow2",
    ]

    private static func iniURL(avdName: String, avdHome: URL) -> URL {
        avdHome.appendingPathComponent("\(avdName).ini")
    }

    /// The default content directory, `<avdHome>/<Name>.avd`.
    private static func directoryURL(avdName: String, avdHome: URL) -> URL {
        avdHome.appendingPathComponent("\(avdName).avd", isDirectory: true)
    }

    /// Whether `url` and `other` are the same file system object (one item
    /// reached through two spellings, e.g. differing only in case on a
    /// case-insensitive volume).
    private static func isSameItem(_ url: URL, _ other: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let first = try? url.resourceValues(forKeys: keys).fileResourceIdentifier,
              let second = try? other.resourceValues(forKeys: keys).fileResourceIdentifier
        else {
            return false
        }
        return first.isEqual(second)
    }

    /// Whether something other than `source` already sits at `destination`.
    private static func isOccupied(_ destination: URL, byOtherThan source: URL) -> Bool {
        FileManager.default.fileExists(atPath: destination.path)
            && !isSameItem(destination, source)
    }

    /// Points the ini at its new home; every other line (and every line
    /// ending, CRLF included) stays byte-identical.
    private static func rewritingPaths(in text: String, avdName: String, avdHome: URL) -> String {
        let avdPath = directoryURL(avdName: avdName, avdHome: avdHome).path
        let relativePath = "avd/\(avdName).avd"
        return AvdConfig.linesWithEndings(text)
            .map { line -> String in
                if line.body.hasPrefix("path=") { return "path=\(avdPath)" + line.ending }
                if line.body.hasPrefix("path.rel=") { return "path.rel=\(relativePath)" + line.ending }
                return line.body + line.ending
            }
            .joined()
    }

    /// Renames `AvdId=old`/`avd.ini.displayname=old` lines; anything else
    /// (including a custom display name and every line ending) stays
    /// byte-identical.
    private static func rewritingNames(in text: String, from oldName: String, to newName: String) -> String {
        AvdConfig.linesWithEndings(text)
            .map { line -> String in
                if line.body == "AvdId=\(oldName)" { return "AvdId=\(newName)" + line.ending }
                if line.body == "avd.ini.displayname=\(oldName)" {
                    return "avd.ini.displayname=\(newName)" + line.ending
                }
                return line.body + line.ending
            }
            .joined()
    }
}
