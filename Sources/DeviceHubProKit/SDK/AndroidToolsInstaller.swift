import Foundation

/// What `AndroidToolsInstaller` reads from the network.
public protocol FileDownloading: Sendable {
    /// Downloads `url` into `partial` (a file the caller owns; an existing
    /// partial file is continued when the server supports ranges), reporting
    /// `(bytes so far, total bytes if known)`. Cancelling the calling task
    /// stops the transfer and throws `CancellationError`.
    func download(
        _ url: URL,
        to partial: URL,
        onProgress: @Sendable @escaping (Int64, Int64?) -> Void
    ) async throws

    /// A small document (the repository listing, Adoptium's JSON).
    func data(from url: URL) async throws -> Data
}

/// Unpacks the two archive kinds the installer downloads.
public protocol ArchiveExtracting: Sendable {
    func extractZip(_ archive: URL, to directory: URL) async throws
    func extractTarGz(_ archive: URL, to directory: URL) async throws
}

/// The slice of `sdkmanager` the installer uses (`SdkmanagerClient`, or a
/// fake in tests).
public protocol SdkPackageInstalling: Sendable {
    func install(
        package: String,
        onProgress: @Sendable @escaping (Double?) -> Void,
        onLicense: @Sendable @escaping (String) -> Bool
    ) async throws
    func cancel()
}

extension SdkmanagerClient: SdkPackageInstalling {}

public enum AndroidToolsInstallStep: Int, CaseIterable, Equatable, Sendable {
    case checkingJava
    case downloadingJava
    case readingCatalog
    case downloadingCommandLineTools
    case installingPlatformTools
    case installingEmulator
    case finishing

    public var title: String {
        switch self {
        case .checkingJava: return "Checking for Java"
        case .downloadingJava: return "Downloading Java"
        case .readingCatalog: return "Reading Google's SDK catalog"
        case .downloadingCommandLineTools: return "Downloading the command-line tools"
        case .installingPlatformTools: return "Installing the platform tools"
        case .installingEmulator: return "Installing the Android Emulator"
        case .finishing: return "Finishing up"
        }
    }
}

public struct AndroidToolsInstallProgress: Equatable, Sendable {
    public var step: AndroidToolsInstallStep
    /// 0…1 inside the step, nil when the step cannot tell.
    public var fraction: Double?
    /// A short live line ("12 MB of 155 MB", "verifying", "unpacking").
    public var detail: String
}

public enum AndroidToolsInstallError: Error, Equatable, CustomStringConvertible {
    /// No Java 17+ runtime and the caller did not allow downloading one.
    case javaRequired
    case catalogUnreadable(String)
    case noArchiveForThisMac(String)
    case downloadFailed(String)
    case checksumMismatch(String)
    case extractionFailed(String)
    case licenseDeclined
    case toolFailed(String)
    case cancelled

    public var description: String {
        switch self {
        case .javaRequired:
            return "The Android tools need Java 17 or newer, and none was found on this Mac."
        case .catalogUnreadable(let detail):
            return "Google's SDK catalog could not be read. \(detail)"
        case .noArchiveForThisMac(let package):
            return "Google offers no \(package) download for this Mac."
        case .downloadFailed(let detail):
            return "The download failed: \(detail)"
        case .checksumMismatch(let name):
            return "\(name) did not match the checksum Google publishes, so it was discarded. Try again."
        case .extractionFailed(let detail):
            return "Unpacking failed: \(detail)"
        case .licenseDeclined:
            return "The Android SDK license was declined, so nothing more was installed."
        case .toolFailed(let detail):
            return detail
        case .cancelled:
            return "The installation was cancelled."
        }
    }
}

/// Installs the Android command-line tools, platform-tools (adb) and the
/// emulator into an SDK folder from Google's own packages, without admin
/// rights: the command-line tools archive is fetched from the repository
/// listing (its sha1 verified), unpacked to `cmdline-tools/latest`, and
/// `sdkmanager` (which needs Java; a Temurin runtime is downloaded when the
/// Mac has none) installs `platform-tools` and `emulator`, asking the license
/// through `onLicense`. Every step is skipped when its result is already in
/// place, so a run after a cancelled or failed one resumes: a verified
/// archive is reused, a half-moved folder cannot exist (the unpack goes to a
/// staging folder first and moves in one step), and a partial download is
/// continued or restarted.
public final class AndroidToolsInstaller: Sendable {
    public static let downloadsFolderName = ".devicehubpro-downloads"
    public static let stagingFolderName = ".devicehubpro-staging"

    public let root: URL
    private let arch: String
    private let includeEmulator: Bool
    private let managedJavaDirectory: URL
    private let repositoryURL: URL
    private let adoptiumListing: URL
    private let downloader: any FileDownloading
    private let extractor: any ArchiveExtracting
    private let findJava: @Sendable () async -> URL?
    private let makeSdkmanager: @Sendable (_ sdkmanager: URL, _ java: URL, _ root: URL) -> any SdkPackageInstalling

    /// - Parameters:
    ///   - root: the SDK folder (the default Android Studio one in the app).
    ///   - arch: `aarch64` or `x64`.
    public init(
        root: URL,
        arch: String = AndroidToolsInstaller.hostArchitecture,
        includeEmulator: Bool = true,
        managedJavaDirectory: URL = JavaRuntimeLocator.managedDirectory,
        repositoryURL: URL = AndroidRepositoryManifest.repositoryURL,
        adoptiumListing: URL? = nil,
        downloader: any FileDownloading = URLSessionFileDownloader(),
        extractor: any ArchiveExtracting = SystemArchiveExtractor(),
        findJava: (@Sendable () async -> URL?)? = nil,
        makeSdkmanager: (@Sendable (_ sdkmanager: URL, _ java: URL, _ root: URL) -> any SdkPackageInstalling)? = nil
    ) {
        self.root = root
        self.arch = arch
        self.includeEmulator = includeEmulator
        self.managedJavaDirectory = managedJavaDirectory
        self.repositoryURL = repositoryURL
        self.adoptiumListing = adoptiumListing ?? AdoptiumRelease.listingURL(major: 21, arch: arch)
        self.downloader = downloader
        self.extractor = extractor
        self.findJava = findJava ?? {
            await JavaRuntimeLocator.workingJava(
                candidates: JavaRuntimeLocator.candidates(managedDirectory: managedJavaDirectory)
            )
        }
        self.makeSdkmanager = makeSdkmanager ?? { sdkmanager, java, root in
            SdkmanagerClient(sdkmanagerURL: sdkmanager, javaURL: java, sdkRoot: root)
        }
    }

    /// `aarch64` on Apple silicon, `x64` on Intel.
    public static var hostArchitecture: String {
        #if arch(arm64)
        return "aarch64"
        #else
        return "x64"
        #endif
    }

    /// What is still missing in `root`, in install order.
    public func missingSteps() -> [AndroidToolsInstallStep] {
        var steps: [AndroidToolsInstallStep] = []
        if !AndroidSDKLocation.hasCommandLineTools(at: root) { steps.append(.downloadingCommandLineTools) }
        if !AndroidSDKLocation.hasPlatformTools(at: root) { steps.append(.installingPlatformTools) }
        if includeEmulator, !AndroidSDKLocation.hasEmulator(at: root) { steps.append(.installingEmulator) }
        return steps
    }

    /// Runs the installation to the end. Throws `AndroidToolsInstallError`;
    /// cancelling the calling task stops it and throws `.cancelled`.
    /// `allowJavaDownload` lets it fetch a Temurin runtime when the Mac has
    /// no usable Java; without it that case throws `.javaRequired` so the
    /// caller can ask first.
    public func install(
        allowJavaDownload: Bool,
        onProgress: @Sendable @escaping (AndroidToolsInstallProgress) -> Void,
        onLicense: @Sendable @escaping (String) -> Bool
    ) async throws {
        let sdkInstaller = SdkInstallerBox()
        do {
            try await withTaskCancellationHandler {
                try await run(
                    allowJavaDownload: allowJavaDownload,
                    box: sdkInstaller,
                    onProgress: onProgress,
                    onLicense: onLicense
                )
            } onCancel: {
                sdkInstaller.cancel()
            }
        } catch is CancellationError {
            throw AndroidToolsInstallError.cancelled
        } catch let error as AndroidToolsInstallError {
            throw error
        } catch let error as SdkmanagerError {
            switch error {
            case .cancelled: throw AndroidToolsInstallError.cancelled
            case .licenseDeclined: throw AndroidToolsInstallError.licenseDeclined
            default: throw AndroidToolsInstallError.toolFailed("\(error)")
            }
        }
    }

    private func run(
        allowJavaDownload: Bool,
        box: SdkInstallerBox,
        onProgress: @Sendable @escaping (AndroidToolsInstallProgress) -> Void,
        onLicense: @Sendable @escaping (String) -> Bool
    ) async throws {
        let manager = FileManager.default
        let missing = missingSteps()
        onProgress(.init(step: .checkingJava, fraction: nil, detail: ""))
        let java: URL
        if let found = await findJava() {
            java = found
        } else if allowJavaDownload {
            java = try await downloadJava(onProgress: onProgress)
        } else {
            throw AndroidToolsInstallError.javaRequired
        }
        try Task.checkCancellation()
        guard !missing.isEmpty else {
            onProgress(.init(step: .finishing, fraction: 1, detail: "Everything is already installed"))
            return
        }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        // A staging folder is only ever half of an interrupted unpack.
        let staging = root.appendingPathComponent(Self.stagingFolderName, isDirectory: true)
        try? manager.removeItem(at: staging)
        let downloads = root.appendingPathComponent(Self.downloadsFolderName, isDirectory: true)
        try manager.createDirectory(at: downloads, withIntermediateDirectories: true)

        // The license comes before any Google download: the newer
        // `sdkmanager` (a front for the Android CLI) records the license
        // without asking, so the only consent step is this one.
        var manifest: AndroidRepositoryManifest?
        let accepted = AcceptedFlag()
        let pending = pendingLicenseIDs()
        if !pending.isEmpty {
            let loaded = try await loadManifest(onProgress: onProgress)
            manifest = loaded
            for id in pending {
                guard let text = loaded.licenses[id], !text.isEmpty else {
                    throw AndroidToolsInstallError.catalogUnreadable("Its license text is missing.")
                }
                guard await Self.askOffThePool(text, onLicense) else { throw AndroidToolsInstallError.licenseDeclined }
            }
            accepted.set()
        }
        try Task.checkCancellation()

        if missing.contains(.downloadingCommandLineTools) {
            let loaded: AndroidRepositoryManifest
            if let manifest { loaded = manifest } else { loaded = try await loadManifest(onProgress: onProgress) }
            try await installCommandLineTools(
                manifest: loaded, downloads: downloads, staging: staging, onProgress: onProgress
            )
        }
        try Task.checkCancellation()

        let sdkmanagerURL = root.appendingPathComponent("cmdline-tools/latest/bin/sdkmanager")
        let sdk = makeSdkmanager(sdkmanagerURL, java, root)
        box.set(sdk)
        for (step, package) in [
            (AndroidToolsInstallStep.installingPlatformTools, "platform-tools"),
            (.installingEmulator, "emulator"),
        ] where missing.contains(step) {
            onProgress(.init(step: step, fraction: nil, detail: "Starting"))
            try await sdk.install(
                package: package,
                onProgress: { fraction in
                    onProgress(.init(
                        step: step,
                        fraction: fraction,
                        detail: fraction.map { "\(Int($0 * 100)) %" } ?? "Starting"
                    ))
                },
                // An older sdkmanager asks again: the user already said yes
                // to this license above.
                onLicense: { text in accepted.isSet || onLicense(text) }
            )
            try Task.checkCancellation()
        }

        onProgress(.init(step: .finishing, fraction: nil, detail: ""))
        try? manager.removeItem(at: downloads)
        try? manager.removeItem(at: staging)
        guard AndroidSDKLocation.hasPlatformTools(at: root) else {
            throw AndroidToolsInstallError.toolFailed(
                "sdkmanager finished but platform-tools/adb is not in \(root.path)."
            )
        }
        onProgress(.init(step: .finishing, fraction: 1, detail: "Done"))
    }

    // MARK: - Command-line tools

    /// The licenses (by id) the packages this run installs are under that the
    /// SDK folder has not recorded yet (`licenses/<id>`, which Android Studio
    /// and `sdkmanager` write), in a stable order.
    private func pendingLicenseIDs() -> [String] {
        // Without the catalog the ids are not known yet; every Google package
        // this installer fetches is under `android-sdk-license`.
        let id = "android-sdk-license"
        let file = root.appendingPathComponent("licenses/\(id)")
        let recorded = ((try? Data(contentsOf: file))?.isEmpty == false)
        return recorded ? [] : [id]
    }

    private func loadManifest(
        onProgress: @Sendable @escaping (AndroidToolsInstallProgress) -> Void
    ) async throws -> AndroidRepositoryManifest {
        onProgress(.init(step: .readingCatalog, fraction: nil, detail: ""))
        do {
            return try AndroidRepositoryManifest.parse(try await downloader.data(from: repositoryURL))
        } catch let error as AndroidRepositoryManifest.ParseError {
            throw AndroidToolsInstallError.catalogUnreadable("\(error)")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AndroidToolsInstallError.catalogUnreadable(error.localizedDescription)
        }
    }

    private func installCommandLineTools(
        manifest: AndroidRepositoryManifest,
        downloads: URL,
        staging: URL,
        onProgress: @Sendable @escaping (AndroidToolsInstallProgress) -> Void
    ) async throws {
        let manager = FileManager.default
        guard let package = manifest.package(path: "cmdline-tools;latest"),
              let archive = AndroidRepositoryManifest.macArchive(of: package, arch: arch),
              let url = AndroidRepositoryManifest.resolvedURL(of: archive),
              let algorithm = FileChecksum.Algorithm(name: archive.checksumType)
        else {
            throw AndroidToolsInstallError.noArchiveForThisMac("command-line tools")
        }
        let name = url.lastPathComponent
        let file = downloads.appendingPathComponent(name)
        try await fetchVerified(
            url: url, to: file, name: name, algorithm: algorithm, expected: archive.checksum,
            size: archive.size, step: .downloadingCommandLineTools, onProgress: onProgress
        )

        onProgress(.init(step: .downloadingCommandLineTools, fraction: 1, detail: "Unpacking"))
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try await extractor.extractZip(file, to: staging)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try? manager.removeItem(at: staging)
            throw AndroidToolsInstallError.extractionFailed("\(error)")
        }
        // The archive holds one `cmdline-tools` folder.
        let unpacked = staging.appendingPathComponent("cmdline-tools", isDirectory: true)
        guard manager.isExecutableFile(atPath: unpacked.appendingPathComponent("bin/sdkmanager").path) else {
            try? manager.removeItem(at: staging)
            try? manager.removeItem(at: file)
            throw AndroidToolsInstallError.extractionFailed("the archive has no cmdline-tools/bin/sdkmanager")
        }
        let parent = root.appendingPathComponent("cmdline-tools", isDirectory: true)
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let destination = parent.appendingPathComponent("latest", isDirectory: true)
        try? manager.removeItem(at: destination)
        do {
            try manager.moveItem(at: unpacked, to: destination)
        } catch {
            throw AndroidToolsInstallError.extractionFailed(error.localizedDescription)
        }
        try? manager.removeItem(at: staging)
    }

    // MARK: - Java

    /// Downloads and unpacks a Temurin 21 runtime under `managedJavaDirectory`
    /// and returns its `java`.
    private func downloadJava(
        onProgress: @Sendable @escaping (AndroidToolsInstallProgress) -> Void
    ) async throws -> URL {
        let manager = FileManager.default
        onProgress(.init(step: .downloadingJava, fraction: nil, detail: "Looking up the latest Java runtime"))
        let release: AdoptiumRelease
        do {
            release = try AdoptiumRelease.parse(try await downloader.data(from: adoptiumListing))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AndroidToolsInstallError.catalogUnreadable("\(error)")
        }
        try manager.createDirectory(at: managedJavaDirectory, withIntermediateDirectories: true)
        let downloads = managedJavaDirectory.appendingPathComponent(".downloads", isDirectory: true)
        try manager.createDirectory(at: downloads, withIntermediateDirectories: true)
        let file = downloads.appendingPathComponent(release.name)
        try await fetchVerified(
            url: release.downloadURL, to: file, name: release.name, algorithm: .sha256,
            expected: release.sha256, size: release.size, step: .downloadingJava, onProgress: onProgress
        )
        onProgress(.init(step: .downloadingJava, fraction: 1, detail: "Unpacking"))
        let staging = managedJavaDirectory.appendingPathComponent(".staging", isDirectory: true)
        try? manager.removeItem(at: staging)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        do {
            try await extractor.extractTarGz(file, to: staging)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AndroidToolsInstallError.extractionFailed("\(error)")
        }
        let folders = (try? manager.contentsOfDirectory(atPath: staging.path)) ?? []
        guard let folder = folders.first(where: {
            manager.isExecutableFile(
                atPath: staging.appendingPathComponent("\($0)/Contents/Home/bin/java").path
            )
        }) else {
            try? manager.removeItem(at: file)
            throw AndroidToolsInstallError.extractionFailed("the archive holds no Java runtime")
        }
        let destination = managedJavaDirectory.appendingPathComponent(folder, isDirectory: true)
        try? manager.removeItem(at: destination)
        do {
            try manager.moveItem(at: staging.appendingPathComponent(folder), to: destination)
        } catch {
            throw AndroidToolsInstallError.extractionFailed(error.localizedDescription)
        }
        try? manager.removeItem(at: downloads)
        return destination.appendingPathComponent("Contents/Home/bin/java")
    }

    // MARK: - Download and verify

    /// Leaves a verified copy of `url` at `file`: an existing verified file is
    /// reused, otherwise the (possibly partial) `file.partial` is continued,
    /// verified, and renamed. A checksum mismatch deletes the bytes.
    private func fetchVerified(
        url: URL,
        to file: URL,
        name: String,
        algorithm: FileChecksum.Algorithm,
        expected: String,
        size: Int64,
        step: AndroidToolsInstallStep,
        onProgress: @Sendable @escaping (AndroidToolsInstallProgress) -> Void
    ) async throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: file.path) {
            onProgress(.init(step: step, fraction: nil, detail: "Verifying the earlier download"))
            if FileChecksum.matches(file, algorithm: algorithm, expected: expected) { return }
            try? manager.removeItem(at: file)
        }
        let partial = file.appendingPathExtension("partial")
        do {
            try await downloader.download(url, to: partial) { done, total in
                let total = total ?? (size > 0 ? size : nil)
                onProgress(.init(
                    step: step,
                    fraction: total.map { $0 > 0 ? min(1, Double(done) / Double($0)) : 0 },
                    detail: Self.byteText(done, of: total)
                ))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AndroidToolsInstallError {
            throw error
        } catch {
            throw AndroidToolsInstallError.downloadFailed(error.localizedDescription)
        }
        try Task.checkCancellation()
        onProgress(.init(step: step, fraction: 1, detail: "Verifying"))
        guard FileChecksum.matches(partial, algorithm: algorithm, expected: expected) else {
            try? manager.removeItem(at: partial)
            throw AndroidToolsInstallError.checksumMismatch(name)
        }
        try? manager.removeItem(at: file)
        try manager.moveItem(at: partial, to: file)
    }

    /// `onLicense` may block until the user answers: it runs on a dispatch
    /// thread, never on the cooperative pool.
    private static func askOffThePool(
        _ text: String,
        _ onLicense: @Sendable @escaping (String) -> Bool
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: onLicense(text))
            }
        }
    }

    static func byteText(_ done: Int64, of total: Int64?) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let doneText = formatter.string(fromByteCount: done)
        guard let total, total > 0 else { return doneText }
        return "\(doneText) of \(formatter.string(fromByteCount: total))"
    }
}

/// Whether the user accepted the license in this run.
private final class AcceptedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Holds the running sdkmanager so a cancel of the install reaches it.
private final class SdkInstallerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sdk: (any SdkPackageInstalling)?
    private var cancelled = false

    func set(_ sdk: any SdkPackageInstalling) {
        lock.lock()
        self.sdk = sdk
        let already = cancelled
        lock.unlock()
        if already { sdk.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let sdk = self.sdk
        lock.unlock()
        sdk?.cancel()
    }
}

// MARK: - Real downloader and extractor

/// `FileDownloading` over URLSession: streams to the partial file, continuing
/// it with a `Range` request when it already holds bytes.
public struct URLSessionFileDownloader: FileDownloading {
    public init() {}

    public func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AndroidToolsInstallError.downloadFailed("\(url.host ?? "server") answered \(http.statusCode)")
        }
        return data
    }

    public func download(
        _ url: URL,
        to partial: URL,
        onProgress: @Sendable @escaping (Int64, Int64?) -> Void
    ) async throws {
        let operation = DownloadOperation(url: url, partial: partial, onProgress: onProgress)
        try await withTaskCancellationHandler {
            try await operation.run()
        } onCancel: {
            operation.cancel()
        }
    }

    private final class DownloadOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let url: URL
        private let partial: URL
        private let onProgress: @Sendable (Int64, Int64?) -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var task: URLSessionDataTask?
        private var session: URLSession?
        private var handle: FileHandle?
        private var written: Int64 = 0
        private var total: Int64?
        private var failure: Error?
        private var cancelled = false
        private var restartedWithoutRange = false
        private var lastReport = Date.distantPast

        init(url: URL, partial: URL, onProgress: @escaping @Sendable (Int64, Int64?) -> Void) {
            self.url = url
            self.partial = partial
            self.onProgress = onProgress
        }

        func run() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                self.continuation = continuation
                let wasCancelled = cancelled
                lock.unlock()
                if wasCancelled {
                    finish(CancellationError())
                } else {
                    start(allowRange: true)
                }
            }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }

        private func start(allowRange: Bool) {
            let manager = FileManager.default
            let existing = (try? manager.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            if allowRange, existing > 0 {
                request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
            } else {
                try? manager.removeItem(at: partial)
            }
            if !manager.fileExists(atPath: partial.path) {
                manager.createFile(atPath: partial.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: partial) else {
                finish(AndroidToolsInstallError.downloadFailed("cannot write \(partial.lastPathComponent)"))
                return
            }
            try? handle.seekToEnd()
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            let task = session.dataTask(with: request)
            lock.lock()
            self.handle = handle
            self.written = allowRange ? existing : 0
            self.session = session
            self.task = task
            lock.unlock()
            task.resume()
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse else {
                completionHandler(.cancel)
                return
            }
            switch http.statusCode {
            case 206:
                lock.lock()
                total = http.expectedContentLength > 0 ? written + http.expectedContentLength : nil
                lock.unlock()
                completionHandler(.allow)
            case 200:
                // The server ignored the range: start the file over.
                lock.lock()
                try? handle?.truncate(atOffset: 0)
                try? handle?.seek(toOffset: 0)
                written = 0
                total = http.expectedContentLength > 0 ? http.expectedContentLength : nil
                lock.unlock()
                completionHandler(.allow)
            case 416 where !restartedWithoutRange:
                lock.lock()
                restartedWithoutRange = true
                failure = RangeRestart()
                lock.unlock()
                completionHandler(.cancel)
            default:
                lock.lock()
                failure = AndroidToolsInstallError.downloadFailed(
                    "\(url.host ?? "the server") answered \(http.statusCode)"
                )
                lock.unlock()
                completionHandler(.cancel)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            do { try handle?.write(contentsOf: data) } catch {
                failure = AndroidToolsInstallError.downloadFailed("the disk refused the write")
                lock.unlock()
                dataTask.cancel()
                return
            }
            written += Int64(data.count)
            let snapshot = (written, total)
            let due = Date().timeIntervalSince(lastReport) > 0.15
            if due { lastReport = Date() }
            lock.unlock()
            if due { onProgress(snapshot.0, snapshot.1) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            try? handle?.close()
            handle = nil
            let failure = self.failure
            let wasCancelled = cancelled
            let snapshot = (written, total)
            lock.unlock()
            session.finishTasksAndInvalidate()
            if wasCancelled { finish(CancellationError()); return }
            if failure is RangeRestart {
                self.lock.lock()
                self.failure = nil
                self.lock.unlock()
                start(allowRange: false)
                return
            }
            if let failure { finish(failure); return }
            if let error { finish(AndroidToolsInstallError.downloadFailed(error.localizedDescription)); return }
            if let expected = snapshot.1, snapshot.0 != expected {
                finish(AndroidToolsInstallError.downloadFailed("the connection ended early"))
                return
            }
            onProgress(snapshot.0, snapshot.1)
            finish(nil)
        }

        private struct RangeRestart: Error {}

        private func finish(_ error: Error?) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
        }
    }
}

/// `ArchiveExtracting` with the system's `ditto` (zip, which keeps the
/// executable bits and symlinks) and `tar`.
public struct SystemArchiveExtractor: ArchiveExtracting {
    public init() {}

    public func extractZip(_ archive: URL, to directory: URL) async throws {
        try await run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
    }

    public func extractTarGz(_ archive: URL, to directory: URL) async throws {
        try await run("/usr/bin/tar", ["-xzf", archive.path, "-C", directory.path])
    }

    private func run(_ tool: String, _ arguments: [String]) async throws {
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: tool), arguments: arguments)
        guard result.exitCode == 0 else {
            let detail = result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AndroidToolsInstallError.extractionFailed(
                detail.isEmpty ? "\(URL(fileURLWithPath: tool).lastPathComponent) exited with \(result.exitCode)" : detail
            )
        }
    }
}
