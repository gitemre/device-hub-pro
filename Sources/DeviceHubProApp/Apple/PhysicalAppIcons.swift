import AppKit
import CryptoKit
import Foundation
import Observation
import DeviceHubProKit

/// The real icons of a physical iPhone's apps, for the Apps tab:
/// `devicectl device info appIcon` writes each as a PNG, the
/// store keeps them on disk and in memory and hands the rows an image.
///
/// - **Lazy.** A row asks (`request`) when it shows and cancels
///   (`cancel`) when it scrolls away; nothing is fetched for an app nobody
///   looks at. An icon already on disk never costs a device call.
/// - **Bounded.** At most `maxConcurrent` (two) fetches run at once, so a
///   list of 80 apps never opens 80 `devicectl` processes.
/// - **Cached** per device, bundle identifier and version under
///   `~/Library/Caches/DeviceHubPro/icons/<device digest>/<bundle id>-<version>.png`;
///   a new version of an app is a new file. The device's UDID is never a
///   folder name: only a digest of it.
/// - **Fallible.** A fetch that fails, or a file that is no image, leaves
///   the row on the generic glyph; it is not asked again until the store is
///   made again (the next launch or another device's list).
@MainActor
@Observable
final class PhysicalAppIconStore {
    /// One icon: a device, an app and the app's version (a new version has
    /// a new icon).
    struct Key: Hashable, Sendable {
        let device: String
        let bundleIdentifier: String
        let version: String
    }

    /// Fetches `bundleIdentifier`'s icon of `device` into the PNG file at
    /// `destination` (`size` pixels asked for). Throws when it cannot.
    typealias Fetch = @MainActor (
        _ device: String,
        _ bundleIdentifier: String,
        _ size: Int,
        _ destination: URL
    ) async throws -> Void

    /// The pixel size asked of the device (two times the row's tile).
    static let iconSize = 64
    static let defaultMaxConcurrent = 2

    /// The loaded images.
    private(set) var images: [Key: NSImage] = [:]

    @ObservationIgnored let cacheDirectory: URL
    @ObservationIgnored let maxConcurrent: Int
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private var pending: [Key] = []
    @ObservationIgnored private var running: Set<Key> = []
    @ObservationIgnored private var failed: Set<Key> = []
    /// Fetches in flight (tests assert the bound).
    @ObservationIgnored private(set) var runningCount = 0
    /// Fetches that reached the device since this store was made.
    @ObservationIgnored private(set) var fetchCount = 0

    init(
        cacheDirectory: URL = PhysicalAppIconStore.defaultCacheDirectory(),
        maxConcurrent: Int = PhysicalAppIconStore.defaultMaxConcurrent,
        fetch: @escaping Fetch
    ) {
        self.cacheDirectory = cacheDirectory
        self.maxConcurrent = max(1, maxConcurrent)
        self.fetch = fetch
    }

    /// `~/Library/Caches/DeviceHubPro/icons`.
    static func defaultCacheDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches
            .appendingPathComponent("DeviceHubPro", isDirectory: true)
            .appendingPathComponent("icons", isDirectory: true)
    }

    // MARK: - Keys and files

    static func key(for app: PhysicalApp, udid: String) -> Key {
        Key(
            device: PhysicalDeviceOptIn.normalize(udid),
            bundleIdentifier: app.bundleIdentifier,
            version: app.displayVersion ?? ""
        )
    }

    /// The device's folder: a digest, never the UDID itself.
    func folder(for key: Key) -> URL {
        let digest = SHA256.hash(data: Data(key.device.utf8))
        let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(name, isDirectory: true)
    }

    /// `<bundle id>-<version>.png`, the version cut to safe characters.
    func file(for key: Key) -> URL {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let version = String(key.version.map { allowed.contains($0) ? $0 : "_" }.prefix(40))
        let name = version.isEmpty ? key.bundleIdentifier : "\(key.bundleIdentifier)-\(version)"
        return folder(for: key).appendingPathComponent("\(name).png")
    }

    // MARK: - Reading

    /// The icon once it loaded; nil before, and for an app whose icon could
    /// not be read (the row keeps its glyph).
    func image(for app: PhysicalApp, udid: String) -> NSImage? {
        images[Self.key(for: app, udid: udid)]
    }

    /// Whether the store gave up on `app`'s icon.
    func hasFailed(_ app: PhysicalApp, udid: String) -> Bool {
        failed.contains(Self.key(for: app, udid: udid))
    }

    // MARK: - Asking

    /// A row shows `app`: loads its icon from the disk cache at once, else
    /// queues a fetch (at most `maxConcurrent` run).
    func request(_ app: PhysicalApp, udid: String) {
        let key = Self.key(for: app, udid: udid)
        guard images[key] == nil, !failed.contains(key), !running.contains(key), !pending.contains(key) else { return }
        if let cached = Self.image(at: file(for: key)) {
            images[key] = cached
            return
        }
        pending.append(key)
        pump()
    }

    /// The row scrolled away: a fetch that has not started is dropped (one
    /// running finishes and is cached).
    func cancel(_ app: PhysicalApp, udid: String) {
        let key = Self.key(for: app, udid: udid)
        pending.removeAll { $0 == key }
    }

    /// Drops the loaded images of `udid`'s apps that are no longer listed
    /// (uninstalled, or an older version); the disk cache is untouched.
    func retain(apps: [PhysicalApp], udid: String) {
        let device = PhysicalDeviceOptIn.normalize(udid)
        let live = Set(apps.map { Self.key(for: $0, udid: device) })
        let stale = images.keys.filter { $0.device == device && !live.contains($0) }
        for key in stale { images[key] = nil }
    }

    /// Forgets what failed (a refresh of the list may ask again).
    func forgetFailures() {
        failed.removeAll()
    }

    // MARK: - Fetching

    private func pump() {
        while runningCount < maxConcurrent, !pending.isEmpty {
            let key = pending.removeFirst()
            running.insert(key)
            runningCount += 1
            Task { [weak self] in
                await self?.run(key)
            }
        }
    }

    private func run(_ key: Key) async {
        defer {
            running.remove(key)
            runningCount -= 1
            pump()
        }
        let folder = folder(for: key)
        let staged = folder.appendingPathComponent(".fetch-\(UUID().uuidString).png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            fetchCount += 1
            try await fetch(key.device, key.bundleIdentifier, Self.iconSize, staged)
            guard let image = Self.image(at: staged) else { throw CocoaError(.fileReadCorruptFile) }
            let destination = file(for: key)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: staged, to: destination)
            images[key] = image
        } catch {
            // The generic glyph stays; a leftover staged file is removed.
            try? FileManager.default.removeItem(at: staged)
            failed.insert(key)
        }
    }

    /// The PNG at `url` as an image; nil for a missing, empty or unreadable
    /// file.
    private static func image(at url: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return NSImage(data: data)
    }
}
