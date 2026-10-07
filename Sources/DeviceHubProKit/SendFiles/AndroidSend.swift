import Foundation

/// Send Files for an Android device: what each
/// file dropped on a device (or picked in the Send Files panel) becomes.
public enum AndroidSend: Sendable, Equatable {
    /// An APK, an `.apks` set or a folder of split APKs: `adb install`.
    case install(URL)
    /// Everything else (photos, videos, documents, whole folders):
    /// `adb push` into the chosen folder of the shared storage, then a media
    /// scan so pictures, videos and music show up in Gallery and Files.
    case push([URL])
}

/// Where Send Files puts a file on an Android device: one of the shared
/// storage's standard folders, or a folder the user typed. Remembered as its
/// `storedValue`.
public enum AndroidSendDestination: Sendable, Equatable, Hashable {
    case downloads, dcim, pictures, movies, music, documents
    /// A folder under the shared storage, normalised (`normalize(custom:)`).
    case custom(String)

    /// The presets, in the panel's order.
    public static let presets: [AndroidSendDestination] = [.downloads, .dcim, .pictures, .movies, .music, .documents]

    /// The folder the files go into, on the device (`/sdcard/…`).
    public var path: String {
        switch self {
        case .downloads: "/sdcard/Download"
        case .dcim: "/sdcard/DCIM"
        case .pictures: "/sdcard/Pictures"
        case .movies: "/sdcard/Movies"
        case .music: "/sdcard/Music"
        case .documents: "/sdcard/Documents"
        case .custom(let path): path
        }
    }

    /// The panel's name for it.
    public var title: String {
        switch self {
        case .downloads: "Downloads"
        case .dcim: "DCIM (camera)"
        case .pictures: "Pictures"
        case .movies: "Movies"
        case .music: "Music"
        case .documents: "Documents"
        case .custom(let path): path
        }
    }

    /// The text kept in the preferences: the preset's folder path.
    public var storedValue: String { path }

    /// The destination `storedValue` stands for (a path that is a preset's
    /// gives the preset; anything else is checked as a custom folder); nil
    /// for a value that is no usable folder.
    public static func from(storedValue: String?) -> AndroidSendDestination? {
        guard let storedValue, let path = normalize(custom: storedValue) else { return nil }
        return presets.first { $0.path == path } ?? .custom(path)
    }

    /// A typed folder as a path under the shared storage: `Download/Test`,
    /// `/sdcard/Download/Test` and `/storage/emulated/0/Download/Test` all
    /// give `/sdcard/Download/Test`. Nil for an empty text, a path outside
    /// the shared storage, one with `..`, or one with a control character.
    public static func normalize(custom text: String) -> String? {
        var path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return nil }
        for prefix in ["/storage/emulated/0", "/sdcard", "/mnt/sdcard"] where path == prefix || path.hasPrefix(prefix + "/") {
            path = "/sdcard" + path.dropFirst(prefix.count)
            break
        }
        if !path.hasPrefix("/") { path = "/sdcard/" + path }
        guard path == "/sdcard" || path.hasPrefix("/sdcard/") else { return nil }
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == ".." { return nil }
            if part != "." { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }
}

/// Sorts what was dropped on an Android device into `AndroidSend`s, by file
/// extension and, for a folder, by what is in it, in the order they came
/// (every file to push is gathered into one `push` at the position of the
/// first).
public enum AndroidSendRouting {
    /// Whether `url` is something `adb install` takes: one APK, an `.apks`
    /// set, or a folder whose top level holds only APKs (a split install).
    public static func isInstallable(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "apk", "apks":
            return true
        default:
            break
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let names = try? FileManager.default.contentsOfDirectory(atPath: url.path)
        else { return false }
        let visible = names.filter { !$0.hasPrefix(".") }
        return !visible.isEmpty && visible.allSatisfy { $0.lowercased().hasSuffix(".apk") }
    }

    public static func route(_ urls: [URL]) -> [AndroidSend] {
        var routes: [AndroidSend] = []
        var pushIndex: Int?
        for url in urls where url.isFileURL {
            if isInstallable(url) {
                routes.append(.install(url))
            } else if let index = pushIndex, case .push(let earlier) = routes[index] {
                routes[index] = .push(earlier + [url])
            } else {
                pushIndex = routes.count
                routes.append(.push([url]))
            }
        }
        return routes
    }
}

/// What a Send Files push did.
public struct AndroidPushResult: Sendable, Equatable {
    /// How many files `adb push` reported pushed (a folder counts its files).
    public let filesPushed: Int
    /// The folder they went into.
    public let destination: String
    /// How many files the media scan was asked about, and how many of those
    /// the device did not know afterwards (a scan is best effort).
    public let scanned: Int
    public let scanMisses: Int
}

extension AdbClient {
    /// `adb push` of one file or folder reports `<path>: N file(s) pushed, M
    /// skipped.` (stderr, measured on API 35: "1 file pushed, 0 skipped",
    /// "2 files pushed, 0 skipped").
    public static func pushedCount(from text: String) -> Int? {
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            guard let range = line.range(of: " pushed") else { continue }
            let head = line[..<range.lowerBound]
            // "<n> file(s)" sits right before " pushed".
            let words = head.split(separator: " ")
            if words.count >= 2, words[words.count - 1].hasPrefix("file"), let count = Int(words[words.count - 2]) {
                return count
            }
        }
        return nil
    }

    /// The files under `item` (the item itself when it is a file), each with
    /// its path relative to `item`'s parent: what a push to `<folder>/` puts on
    /// the device. Hidden files are included (adb pushes them).
    static func filesToPush(_ item: URL) -> [String] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory) else { return [] }
        let base = item.lastPathComponent
        guard isDirectory.boolValue else { return [base] }
        guard let walker = FileManager.default.enumerator(atPath: item.path) else { return [] }
        var files: [String] = []
        for case let relative as String in walker {
            var childIsDirectory: ObjCBool = false
            let child = item.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: child.path, isDirectory: &childIsDirectory), !childIsDirectory.boolValue {
                files.append(base + "/" + relative)
            }
        }
        return files.sorted()
    }

    /// The words of a failed push: adb's stderr, else its stdout.
    static func pushFailure(_ standardError: String, _ standardOutput: String) -> String {
        let candidates: [String] = [standardError, standardOutput]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return candidates.first { !$0.isEmpty } ?? ""
    }

    /// How many files a media scan is asked about in one device shell call,
    /// and in all (a bigger drop stays pushed, only the scan stops).
    static let scanBatchSize = 40
    static let scanLimit = 400

    /// The shared storage's real path (`readlink -f /sdcard`, measured
    /// `/storage/emulated/0`), which MediaStore's `scan_file` wants.
    public func sharedStorageRoot(serial: String) async -> String {
        let text = (try? await shell(serial: serial, ["readlink", "-f", "/sdcard"])) ?? ""
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/storage/") ? path : "/storage/emulated/0"
    }

    /// The device command that asks MediaStore to index one file: `content
    /// call --uri content://media/external/file --method scan_file --arg
    /// <path>`. It answers `Result: Bundle[{android.intent.extra.STREAM=…}]`
    /// with a value for a file it indexed and `STREAM=null` for one it could
    /// not find (measured on API 35). It replaces the broadcast
    /// `MEDIA_SCANNER_SCAN_FILE`, which Android ignores from API 29 on.
    static func scanFileCommand(path: String) -> String {
        "content call --uri content://media/external/file --method scan_file --arg \(shellWord(path))"
    }

    /// How many `scan_file` answers in `output` were `STREAM=null` (the file
    /// was not found), and how many were answers at all.
    static func scanOutcome(_ output: String) -> (answers: Int, misses: Int) {
        var answers = 0
        var misses = 0
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("Result:") {
            answers += 1
            if line.contains("android.intent.extra.STREAM=null") { misses += 1 }
        }
        return (answers, misses)
    }

    /// Removes the files a push of `item` into `folder` may have left half
    /// written. Runs in its own task: the push's was cancelled.
    func removePartial(_ item: URL, folder: String, serial: String) async {
        let paths = Self.filesToPush(item).map { Self.shellWord(folder + "/" + $0) }
        guard !paths.isEmpty else { return }
        await Task { _ = try? await shell(serial: serial, ["rm", "-f"] + paths, timeout: .seconds(15)) }.value
    }

    /// Pushes each of `items` (files or folders; a folder keeps its tree)
    /// into `destination` on `serial`, creating the folder first, then asks
    /// MediaStore to index what arrived. `progress` is told before each item.
    public func send(
        _ items: [URL],
        to destination: AndroidSendDestination,
        serial: String,
        progress: (@Sendable (_ index: Int, _ item: URL) -> Void)? = nil
    ) async throws -> AndroidPushResult {
        let folder = destination.path
        guard AndroidSendDestination.normalize(custom: folder) == folder else {
            throw AdbError.commandFailed(arguments: ["push"], exitCode: 1, message: "“\(folder)” is not a folder on the shared storage.")
        }
        _ = try await shell(serial: serial, ["mkdir", "-p", Self.shellWord(folder)])
        var pushed = 0
        var remoteFiles: [String] = []
        for (index, item) in items.enumerated() {
            progress?(index, item)
            let arguments = ["-s", serial, "push", item.path, folder + "/"]
            let result: ProcessResult
            do {
                result = try await execute(arguments, timeout: Self.transferTimeout)
            } catch {
                // Cancelled (or timed out) part-way: what arrived is a
                // truncated file, not the user's file.
                await removePartial(item, folder: folder, serial: serial)
                throw error
            }
            guard result.exitCode == 0 else {
                throw AdbError.commandFailed(
                    arguments: arguments,
                    exitCode: result.exitCode,
                    message: Self.pushFailure(result.standardErrorText, result.standardOutputText)
                )
            }
            pushed += Self.pushedCount(from: result.standardErrorText + "\n" + result.standardOutputText)
                ?? Self.filesToPush(item).count
            remoteFiles += Self.filesToPush(item)
        }
        // The scan: one device shell call per batch of files.
        let root = await sharedStorageRoot(serial: serial)
        let realFolder = root + folder.dropFirst("/sdcard".count)
        let toScan = remoteFiles.prefix(Self.scanLimit).map { realFolder + "/" + $0.decomposedStringWithCanonicalMapping }
        var scanned = 0
        var misses = 0
        var index = 0
        while index < toScan.count {
            let batch = toScan[index..<min(index + Self.scanBatchSize, toScan.count)]
            index += Self.scanBatchSize
            guard let output = try? await shell(
                serial: serial,
                [batch.map(Self.scanFileCommand(path:)).joined(separator: "; ")],
                timeout: .seconds(60)
            ) else { continue }
            let outcome = Self.scanOutcome(output)
            scanned += outcome.answers
            misses += outcome.misses
        }
        return AndroidPushResult(filesPushed: pushed, destination: folder, scanned: scanned, scanMisses: misses)
    }
}
