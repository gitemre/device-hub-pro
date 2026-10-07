import Foundation
import Observation
import DeviceHubProKit

/// The state of one SDK package's download.
enum DownloadState: Equatable {
    case idle
    case downloading(Double?)
    case failed(String)
}

/// How `SDKComponentModel.startDownload(package:)` finished.
enum DownloadOutcome: Equatable {
    case installed
    case cancelled
    case failed(String)
}

/// Whether the downloadable system images have been loaded from sdkmanager.
enum SDKAvailableState: Equatable {
    case idle
    case loading
    case loaded
    case unavailable(String)
}

/// A license sdkmanager is asking about while an install runs.
struct SDKLicensePrompt: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

/// The one sdkmanager install that may run at a time, app-wide. The create
/// sheet, the Pixel screen and Settings each own an `SDKComponentModel`;
/// two installs into one SDK root at once would corrupt each other.
@MainActor
@Observable
final class SDKInstallSlot {
    static let shared = SDKInstallSlot()

    /// The package being installed, if any.
    private(set) var package: String?

    /// Takes the slot for `package`; false when another install holds it.
    func claim(_ package: String) -> Bool {
        guard self.package == nil else { return false }
        self.package = package
        return true
    }

    func release(_ package: String) {
        if self.package == package { self.package = nil }
    }
}

/// SDK component state for the create sheet and Settings: installed system
/// images (on-disk scan), downloadable images (sdkmanager, cached) and at
/// most one download at a time (app-wide, `SDKInstallSlot`), with progress,
/// cancellation and license handling. Owned by the views that need it —
/// AppModel holds no SDK state.
///
/// `sdkmanager` and the SDK root are resolved when first needed and again
/// while missing, so installing the command-line tools after launch works
/// without a restart.
@MainActor
@Observable
final class SDKComponentModel {
    private(set) var installedImages: [SystemImage] = []
    private(set) var availableImages: [SystemImage] = []
    /// Byte sizes (sum of regular-file sizes) per installed package.
    private(set) var installedSizes: [String: Int64] = [:]
    private(set) var availableState: SDKAvailableState = .idle
    /// The newest `emulator` package sdkmanager offers, once listed.
    private(set) var availableEmulatorVersion: String?
    /// The license prompt the running install is waiting on, if any.
    private(set) var licensePrompt: SDKLicensePrompt?

    /// The system image being removed (Settings ▸ Android system images), if any.
    private(set) var removingPackage: String?
    /// Why the last removal of a package failed, by package.
    private(set) var removalFailures: [String: String] = [:]

    private var downloadStates: [String: DownloadState] = [:]
    private var activePackage: String?
    @ObservationIgnored private var resolvedClient: SdkmanagerClient?
    @ObservationIgnored private var resolvedSdkRoot: URL?
    private let locateClient: @MainActor () -> SdkmanagerClient?
    private let locateSdkRoot: @MainActor () -> URL?
    private let installSlot: SDKInstallSlot
    private let freeSpace: @MainActor (URL) -> Int64?
    private let licenseGate = SDKLicenseGate()

    init(
        locateClient: @escaping @MainActor () -> SdkmanagerClient? = { SdkmanagerClient.locate() },
        locateSdkRoot: @escaping @MainActor () -> URL? = { AvdmanagerClient.sdkRoot() },
        installSlot: SDKInstallSlot = .shared,
        freeSpace: @escaping @MainActor (URL) -> Int64? = { DiskSpaceCheck.freeBytes(at: $0) }
    ) {
        self.freeSpace = freeSpace
        self.locateClient = locateClient
        self.locateSdkRoot = locateSdkRoot
        self.installSlot = installSlot
    }

    /// Whether this model is downloading a package.
    var isDownloading: Bool { activePackage != nil }

    /// The package this model is downloading, if any.
    var activeDownloadPackage: String? { activePackage }

    /// The failure message of a start refused because an install runs.
    static let busyMessage = "Another download is already running."
    /// The failure message of a removal refused because sdkmanager is busy.
    static let removalBusyMessage = "Wait for the running download or removal to finish."

    /// Rescans the installed images from disk.
    func rescanInstalled() async {
        await reloadInstalled()
    }

    /// Whether a download can start now: one install runs at a time,
    /// app-wide (`SDKInstallSlot`). Only a download waits for it — creating
    /// an AVD from an installed image runs no sdkmanager.
    var canStartDownload: Bool { activePackage == nil && removingPackage == nil && installSlot.package == nil }

    /// sdkmanager, located now if it was missing so far.
    private func client() -> SdkmanagerClient? {
        if resolvedClient == nil { resolvedClient = locateClient() }
        return resolvedClient
    }

    /// The SDK root, located now if it was missing so far.
    private func sdkRoot() -> URL? {
        if resolvedSdkRoot == nil { resolvedSdkRoot = locateSdkRoot() }
        return resolvedSdkRoot
    }

    // MARK: - Listing

    /// Rescans installed images on disk and, once, loads what sdkmanager
    /// offers. The available list is cached for the model's lifetime.
    func refresh() async {
        await reloadInstalled()
        await loadAvailableIfNeeded()
    }

    func downloadState(package: String) -> DownloadState {
        downloadStates[package] ?? .idle
    }

    func isInstalled(_ package: String) -> Bool {
        installedImages.contains { $0.package == package }
    }

    func installedSizeText(package: String) -> String {
        guard let bytes = installedSizes[package] else { return "…" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func reloadInstalled() async {
        guard let sdkRoot = sdkRoot() else {
            installedImages = []
            installedSizes = [:]
            return
        }
        // sdkmanager leaves the package directories behind when a download is
        // cancelled, so the disk scan alone would show phantom images;
        // installed packages carry the tool's `package.xml` manifest.
        let images = AvdmanagerClient.installedSystemImages(sdkRoot: sdkRoot)
            .filter { Self.hasPackageManifest(at: Self.packageDirectory(sdkRoot: sdkRoot, image: $0)) }
        installedImages = images
        let sizes = await Task.detached(priority: .utility) {
            var sizes: [String: Int64] = [:]
            for image in images {
                sizes[image.package] = Self.directorySize(
                    at: Self.packageDirectory(sdkRoot: sdkRoot, image: image)
                )
            }
            return sizes
        }.value
        guard installedImages == images else { return }
        installedSizes = sizes
    }

    private func loadAvailableIfNeeded() async {
        switch availableState {
        case .loaded, .loading:
            return
        case .idle, .unavailable:
            break
        }
        guard let client = client() else {
            availableState = .unavailable(
                "The Android tools aren\u{2019}t installed, so only the images already on this Mac are listed."
            )
            return
        }
        availableState = .loading
        do {
            var seen = Set<String>()
            let listing = try await client.listAvailable()
            availableEmulatorVersion = listing.emulatorVersion
            availableImages = listing.images
                .filter { seen.insert($0.package).inserted }
            availableState = .loaded
        } catch {
            availableImages = []
            // A cancelled read (the view went away) is not a failure: back to
            // idle so the next refresh loads again.
            availableState = Self.isCancellation(error) ? .idle : .unavailable("\(error)")
        }
    }

    // MARK: - Downloading

    /// Downloads `package`, reporting progress through
    /// `downloadState(package:)`. One download runs at a time, app-wide; a
    /// start while one runs fails without touching the running download's
    /// state. On success the installed images are rescanned from disk.
    @discardableResult
    func startDownload(package: String) async -> DownloadOutcome {
        guard canStartDownload else {
            let message = Self.busyMessage
            if activePackage != package, installSlot.package != package {
                downloadStates[package] = .failed(message)
            }
            return .failed(message)
        }
        guard let client = client() else {
            let message = UserFacingText.androidToolsMissing
            downloadStates[package] = .failed(message)
            return .failed(message)
        }
        // A download that cannot fit fails now, in words, rather than half
        // way through. (The create sheet warns earlier, at size + 2 GB.)
        let location = sdkRoot() ?? FileManager.default.homeDirectoryForCurrentUser
        if DiskSpaceCheck.cannotFit(freeBytes: freeSpace(location)) {
            let message = DiskSpaceCheck.warning(freeBytes: freeSpace(location)) ?? PlainFailure.diskFullSummary
            downloadStates[package] = .failed(message)
            return .failed(message)
        }
        guard installSlot.claim(package) else {
            return .failed(Self.busyMessage)
        }
        defer { installSlot.release(package) }
        activePackage = package
        licenseGate.reset()
        downloadStates[package] = .downloading(nil)

        let gate = licenseGate
        do {
            try await client.install(
                package: package,
                onProgress: { [weak self] progress in
                    Task { @MainActor in
                        self?.setProgress(progress, for: package)
                    }
                },
                onLicense: { [weak self] text in
                    guard let self else { return false }
                    return gate.wait(text: text) { prompt in
                        Task { @MainActor in
                            self.licensePrompt = SDKLicensePrompt(text: prompt)
                        }
                    }
                }
            )
        } catch {
            activePackage = nil
            licensePrompt = nil
            if Self.isCancellation(error) {
                downloadStates[package] = .idle
                return .cancelled
            }
            let message = "\(error)"
            downloadStates[package] = .failed(message)
            return .failed(message)
        }
        activePackage = nil
        licensePrompt = nil
        await reloadInstalled()
        downloadStates[package] = .idle
        return .installed
    }

    // MARK: - Removing

    /// Uninstalls the system image `package` with sdkmanager and rescans the
    /// disk; nil on success, else why it failed (also kept in
    /// `removalFailures`). It takes the app-wide install slot, so no download
    /// runs into the same SDK meanwhile. Emulators built on the image stop
    /// starting: the caller confirms first (`SystemImageRemovalPlan`).
    @discardableResult
    func removeImage(package: String) async -> String? {
        guard canStartDownload else { return Self.removalBusyMessage }
        guard let client = client() else { return UserFacingText.androidToolsMissing }
        guard installSlot.claim(package) else { return Self.removalBusyMessage }
        defer { installSlot.release(package) }
        removingPackage = package
        removalFailures[package] = nil
        var failure: String?
        do {
            try await client.uninstall(package: package, sdkRoot: sdkRoot())
        } catch {
            failure = "\(error)"
        }
        removingPackage = nil
        removalFailures[package] = failure
        if failure == nil, let root = sdkRoot() {
            Self.pruneEmptyDirectories(of: package, sdkRoot: root)
        }
        await reloadInstalled()
        return failure
    }

    /// sdkmanager leaves the removed package's parents behind, empty
    /// (`system-images/android-24/default`); removes those, never a directory
    /// that still holds anything, and never the SDK root's own folders.
    nonisolated static func pruneEmptyDirectories(of package: String, sdkRoot: URL) {
        var components = package.split(separator: ";").map(String.init)
        let manager = FileManager.default
        while components.count > 1 {
            let url = components.reduce(sdkRoot) { $0.appendingPathComponent($1, isDirectory: true) }
            if let contents = try? manager.contentsOfDirectory(atPath: url.path) {
                guard contents.allSatisfy({ $0 == ".DS_Store" }) else { return }
                try? manager.removeItem(at: url)
            }
            components.removeLast()
        }
    }

    /// Accepts the license sdkmanager is waiting on.
    func acceptLicense() {
        licenseGate.decide(true)
        licensePrompt = nil
    }

    /// Declines the license sdkmanager is waiting on.
    func declineLicense() {
        licenseGate.decide(false)
        licensePrompt = nil
    }

    /// Cancels this model's running download (including a pending license
    /// prompt). Another model's download is left alone.
    func cancelDownload() {
        guard activePackage != nil else { return }
        licenseGate.decide(false)
        licensePrompt = nil
        resolvedClient?.cancel()
    }

    private func setProgress(_ progress: Double?, for package: String) {
        guard activePackage == package else { return }
        downloadStates[package] = .downloading(progress)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let sdkError = error as? SdkmanagerError, case .cancelled = sdkError {
            return true
        }
        return false
    }

    /// `system-images/<api>/<tag>/<abi>` under the SDK root.
    nonisolated static func packageDirectory(sdkRoot: URL, image: SystemImage) -> URL {
        var url = sdkRoot
        url.appendPathComponent("system-images", isDirectory: true)
        url.appendPathComponent(image.api, isDirectory: true)
        url.appendPathComponent(image.tag, isDirectory: true)
        url.appendPathComponent(image.abi, isDirectory: true)
        return url
    }

    /// True when sdkmanager's install manifest is present — a package
    /// directory left behind by a cancelled download does not have one.
    nonisolated static func hasPackageManifest(at url: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: url.appendingPathComponent("package.xml").path
        )
    }

    /// Sum of the regular files' byte sizes under `url` (the on-disk size of
    /// one `system-images/<api>/<tag>/<abi>` tree).
    nonisolated static func directorySize(at url: URL) -> Int64 {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = manager.enumerator(
                  at: url,
                  includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                  options: [],
                  errorHandler: nil
              )
        else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            ), values.isRegularFile == true, let size = values.fileSize
            else { continue }
            total += Int64(size)
        }
        return total
    }
}

/// Bridges sdkmanager's synchronous license prompt (raised on a process
/// reader thread) to the main actor: `wait` blocks that thread until the
/// user answers, `decide` records the answer. An answer that arrives before
/// its prompt (cancel) satisfies the next prompt immediately; a second
/// answer for the same prompt is ignored.
final class SDKLicenseGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var decision: Bool?

    /// Drops any stale answer and un-consumed signal.
    func reset() {
        lock.lock()
        decision = nil
        lock.unlock()
        while semaphore.wait(timeout: .now()) == .success {}
    }

    /// Shows `text` through `present`, then blocks until an answer exists.
    func wait(text: String, present: @escaping @Sendable (String) -> Void) -> Bool {
        present(text)
        semaphore.wait()
        lock.lock()
        defer { lock.unlock() }
        let value = decision ?? false
        decision = nil
        return value
    }

    /// Records the user's answer, unless one is already waiting to be read.
    func decide(_ accepted: Bool) {
        lock.lock()
        if decision != nil {
            lock.unlock()
            return
        }
        decision = accepted
        lock.unlock()
        semaphore.signal()
    }
}
