import AppKit
import Foundation
import Observation
import Synchronization
import DeviceHubProKit

/// Real app icons for the Apps inspector: an in-memory cache over
/// `ApkIconExtractor`'s on-disk cache, filled lazily and asynchronously per
/// row.
///
/// Rows call `icon(for:version:serial:)` while they render. A cached icon is
/// served immediately — including one already on `ApkIconExtractor`'s disk
/// cache, so it never costs a placeholder frame; a miss queues a load and
/// returns nil, so the row keeps its SF tile until — and only if — a real
/// icon arrives. The APK is pulled from the inspected device's serial (never
/// the active one), and every failure is silent by design: an icon is a
/// best-effort decoration. The in-memory memo is keyed per device; the disk
/// cache is shared across devices on purpose (an icon is a property of the
/// app build, not of the device). The install popover's local APKs go
/// through `icon(forLocalAPKAt:…)`, which skips the pull. Owned by
/// `AppsInspectorView` — `AppModel` holds no icon state.
///
/// A device load pulls the whole base APK over the adb transport the mirror
/// shares, so loads are bounded: at most `maxConcurrentDeviceLoads` run, the
/// most recently requested rows go first, and at most
/// `maxPendingDeviceLoads` wait (older requests are dropped; their rows ask
/// again when they render). Nothing is pulled when aapt2 is missing. A
/// device switch cancels the previous device's loads, and releasing the
/// store (the Apps tab closes) cancels all of them — a load holds the store
/// only weakly. Only `icons` and `localIcons` are observed: the bookkeeping
/// sets change on every load and must not re-render every visible row.
@MainActor
@Observable
final class AppIconStore {
    private var icons: [String: NSImage] = [:]
    /// Bumped when a load ends without an icon, so rows re-read `label(for:)`.
    private(set) var labelRevision = 0
    private var localIcons: [String: NSImage] = [:]
    @ObservationIgnored private var failed: Set<String> = []
    /// Labels read from the cache, by "package#version" (read during a row's
    /// render, so not observed: the icon's arrival re-renders the row).
    @ObservationIgnored private var labels: [String: String] = [:]
    /// Keys whose disk cache was probed and empty: a re-render must not hit
    /// the disk again for them while their load is queued or running.
    @ObservationIgnored private var diskMisses: Set<String> = []
    /// Waiting device loads, oldest first; the newest is started first.
    @ObservationIgnored private var pending: [DeviceIconRequest] = []
    @ObservationIgnored private var running: Set<String> = []
    @ObservationIgnored private var localInFlight: Set<String> = []
    @ObservationIgnored private var localFailed: Set<String> = []
    @ObservationIgnored private var tool: URL?
    @ObservationIgnored private var didResolveTool = false
    private let loads = LoadTasks()
    private let adbClient: AdbClient?
    private let cacheDirectory: URL
    private let locateTool: @MainActor () -> URL?

    /// Device loads (a full `adb pull` each) running at once.
    static let maxConcurrentDeviceLoads = 2
    /// Device loads waiting at most; older requests beyond it are dropped.
    static let maxPendingDeviceLoads = 24

    /// The icon cache's format. 2: adaptive icons are composited (foreground
    /// over background); older builds cached background-only squares, so a
    /// cache without this version is emptied once.
    /// 3: labels are cached beside the icons (re-extracts once to get them).
    static let cacheVersion = 3
    static let cacheVersionFileName = ".devicehubpro-cache-version"

    init(
        adbClient: AdbClient? = AdbClient.locate(),
        cacheDirectory: URL = AppIconStore.defaultCacheDirectory(),
        locateTool: @escaping @MainActor () -> URL? = { ApkToolLocator.locate() }
    ) {
        self.adbClient = adbClient
        self.cacheDirectory = Self.canonicalized(cacheDirectory)
        self.locateTool = locateTool
        Self.migrateCache(at: self.cacheDirectory)
    }

    /// `~/Library/Caches/DeviceHubPro/appicons`, shared with `ApkIconExtractor`.
    static func defaultCacheDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches
            .appendingPathComponent("DeviceHubPro", isDirectory: true)
            .appendingPathComponent("appicons", isDirectory: true)
    }

    /// The icon for `package` on `serial`, or nil while it loads.
    ///
    /// Hits are synchronous — a warm `ApkIconExtractor` disk cache included,
    /// so a cached icon never costs a placeholder frame. A miss queues the
    /// load once — until it finishes (or fails) every call returns nil.
    /// The key carries `serial`: two devices must never share a decoded
    /// image, even when they report the same package and version.
    func icon(for package: String, version: String?, serial: String) -> NSImage? {
        let key = Self.key(package: package, version: version, serial: serial)
        if let image = icons[key] { return image }
        guard !running.contains(key), !failed.contains(key) else { return nil }
        if !diskMisses.contains(key) {
            if let cached = cachedImage(package: package, version: version) {
                memoize(cached, for: key)
                return cached
            }
            diskMisses.insert(key)
        }
        // Without aapt2 nothing can be extracted: never pull for nothing.
        guard resolvedTool() != nil else {
            failed.insert(key)
            return nil
        }
        enqueue(DeviceIconRequest(key: key, package: package, version: version, serial: serial))
        return nil
    }

    /// Rows call `icon(for:…)` while they render, so the memo write is deferred
    /// to the next main-actor turn: mutating `@Observable` state during a view
    /// update is undefined behaviour (AttributeGraph cycles). The check makes
    /// repeated rows in one pass collapse to a single write.
    private func memoize(_ image: NSImage, for key: String) {
        Task { @MainActor [weak self] in
            guard let self, self.icons[key] == nil else { return }
            self.icons[key] = image
        }
    }

    private static func key(package: String, version: String?, serial: String) -> String {
        "\(serial)|\(package)|\(version ?? "")"
    }

    /// The icon for a local APK file (the install popover's recents), or nil
    /// while it loads. No device is involved; the shared disk cache still
    /// short-circuits the extraction once an icon exists for the package. The
    /// key is the canonicalized path, so the same file reached through a
    /// symlink is one memo entry.
    func icon(forLocalAPKAt apk: URL, package: String?, version: String?) -> NSImage? {
        let key = Self.canonicalized(apk).path
        if let image = localIcons[key] { return image }
        guard !localInFlight.contains(key), !localFailed.contains(key) else { return nil }
        if let package, let cached = cachedImage(package: package, version: version) {
            memoizeLocal(cached, for: key)
            return cached
        }
        Task { await loadLocal(apk: apk, package: package, version: version, key: key) }
        return nil
    }

    /// The local-APK twin of `memoize(_:for:)`.
    private func memoizeLocal(_ image: NSImage, for key: String) {
        Task { @MainActor [weak self] in
            guard let self, self.localIcons[key] == nil else { return }
            self.localIcons[key] = image
        }
    }

    /// Forgets the failures remembered for device loads so far, drops the
    /// memoized icons of every device but `serial`, and cancels that other
    /// devices' queued and running loads. The Apps tab calls this when it
    /// switches devices: a device that comes back after a replug or an adb
    /// hiccup may resolve icons the last attempt missed, the previous
    /// serial's icons must not stay in memory once nothing renders them, and
    /// its pulls must not keep loading the adb transport. Local-APK memos are
    /// path-keyed, not serial-keyed, and belong to the install popover, so
    /// they survive the switch.
    func clearDeviceFailures(keepingSerial serial: String) {
        failed.removeAll()
        diskMisses.removeAll()
        let prefix = "\(serial)|"
        icons = icons.filter { $0.key.hasPrefix(prefix) }
        pending.removeAll { !$0.key.hasPrefix(prefix) }
        let abandoned = running.filter { !$0.hasPrefix(prefix) }
        running.subtract(abandoned)
        loads.cancel(abandoned)
        startQueuedLoads()
    }

    /// Device loads queued or running (for tests and diagnostics).
    var deviceLoadCount: (running: Int, pending: Int) {
        (running.count, pending.count)
    }

    /// The one filesystem identity of a URL: `..` sequences collapsed and
    /// symlinks resolved, so `/tmp/app.apk` and `/private/tmp/app.apk` — or a
    /// cache directory reached through either — share one cache entry.
    private static func canonicalized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    // MARK: - Cache version

    /// Empties `directory`'s cached icons once when an older build wrote
    /// them (no or an older `cacheVersion` marker), then records the current
    /// version.
    static func migrateCache(at directory: URL) {
        let marker = directory.appendingPathComponent(cacheVersionFileName)
        if let text = try? String(contentsOf: marker, encoding: .utf8),
           Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) == cacheVersion {
            return
        }
        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.pathExtension.lowercased() == "png" {
            try? manager.removeItem(at: entry)
        }
        markCacheCurrent(in: directory)
    }

    /// Records that `directory` holds icons in the current cache format.
    static func markCacheCurrent(in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data("\(cacheVersion)\n".utf8).write(
            to: directory.appendingPathComponent(cacheVersionFileName),
            options: .atomic
        )
    }

    // MARK: - Device loads

    private func enqueue(_ request: DeviceIconRequest) {
        pending.removeAll { $0.key == request.key }
        pending.append(request)
        if pending.count > Self.maxPendingDeviceLoads {
            pending.removeFirst(pending.count - Self.maxPendingDeviceLoads)
        }
        startQueuedLoads()
    }

    /// Starts the newest queued loads while a slot is free.
    private func startQueuedLoads() {
        while running.count < Self.maxConcurrentDeviceLoads, let request = pending.popLast() {
            start(request)
        }
    }

    private func start(_ request: DeviceIconRequest) {
        guard let tool = resolvedTool() else {
            failed.insert(request.key)
            return
        }
        running.insert(request.key)
        let adbClient = adbClient
        let cacheDirectory = cacheDirectory
        // The heavy work holds no reference to the store, so releasing the
        // store cancels it (`LoadTasks.deinit`) instead of waiting for it.
        let task = Task { [weak self] in
            let extracted = await Self.extractDeviceIcon(
                request,
                adbClient: adbClient,
                cacheDirectory: cacheDirectory,
                tool: tool
            )
            // A cancelled load was already taken off the books by whoever
            // cancelled it; its (failed) result must not be recorded.
            guard !Task.isCancelled else { return }
            self?.finish(request, extracted: extracted)
        }
        loads.insert(task, for: request.key)
    }

    private func finish(_ request: DeviceIconRequest, extracted: URL?) {
        running.remove(request.key)
        loads.remove(request.key)
        if let extracted, let image = NSImage(contentsOf: extracted) {
            icons[request.key] = image
        } else {
            failed.insert(request.key)
            // No icon, but badging may have named the app: the row reads its
            // label again (an icon's arrival does that on its own).
            labelRevision += 1
        }
        startQueuedLoads()
    }

    /// Pull, extract, clean up. Off the main actor; nil on any failure.
    nonisolated private static func extractDeviceIcon(
        _ request: DeviceIconRequest,
        adbClient: AdbClient?,
        cacheDirectory: URL,
        tool: URL
    ) async -> URL? {
        // Another row (another serial, same build) may have extracted it
        // while this one waited.
        if let version = request.version, !version.isEmpty,
           decodableCacheData(package: request.package, version: version, in: cacheDirectory) != nil {
            return ApkIconExtractor.cacheFileURL(
                forPackage: request.package,
                version: version,
                in: cacheDirectory
            )
        }
        guard let adbClient,
              let apkURL = await pullBaseAPK(package: request.package, serial: request.serial, adbClient: adbClient)
        else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: apkURL.deletingLastPathComponent()) }
        guard !Task.isCancelled else { return nil }
        return try? await ApkIconExtractor.icon(
            forAPKAt: apkURL,
            cacheDirectory: cacheDirectory,
            tool: tool
        )
    }

    // MARK: - Local loads

    private func loadLocal(apk: URL, package: String?, version: String?, key: String) async {
        guard localIcons[key] == nil, !localInFlight.contains(key), !localFailed.contains(key) else {
            return
        }
        localInFlight.insert(key)
        defer { localInFlight.remove(key) }

        if let package, let cached = cachedImage(package: package, version: version) {
            localIcons[key] = cached
            return
        }

        guard
            let extracted = try? await ApkIconExtractor.icon(
                forAPKAt: apk,
                cacheDirectory: cacheDirectory,
                tool: resolvedTool()
            ),
            let image = NSImage(contentsOf: extracted)
        else {
            localFailed.insert(key)
            return
        }
        localIcons[key] = image
    }

    // MARK: - Disk cache

    /// The extractor's disk cache for the version the list reports. An app
    /// whose `pm` version code differs from badging's (versionCodeMajor) only
    /// misses here: the extractor still keys its own file and returns it.
    /// The app's own name ("Example VPN"), read with its icon; nil until the
    /// icon was extracted. Rows show it over the guess from the package id.
    func label(for package: String, version: String?) -> String? {
        _ = labelRevision
        guard let version, !version.isEmpty else { return nil }
        let key = "\(package)#\(version)"
        if let known = labels[key] { return known }
        guard let label = ApkIconExtractor.cachedLabel(forPackage: package, version: version, in: cacheDirectory) else {
            return nil
        }
        labels[key] = label
        return label
    }

    private func cachedImage(package: String, version: String?) -> NSImage? {
        guard let version, !version.isEmpty,
              let data = Self.decodableCacheData(package: package, version: version, in: cacheDirectory)
        else {
            return nil
        }
        return NSImage(data: data)
    }

    /// The cached icon's bytes when they are a decodable raster. A poisoned
    /// file (a pre-fix build could cache a non-raster under the `.png` name)
    /// is sniffed out and dropped, and a sniff-passing but undecodable one
    /// (truncated) is dropped too — the same ImageIO decodability bar
    /// extraction uses — so the load falls through to extraction instead of
    /// serving junk or failing forever.
    nonisolated private static func decodableCacheData(
        package: String,
        version: String,
        in cacheDirectory: URL
    ) -> Data? {
        let file = ApkIconExtractor.cacheFileURL(forPackage: package, version: version, in: cacheDirectory)
        guard let data = try? Data(contentsOf: file) else { return nil }
        guard ApkIconExtractor.isDecodableRasterPayload(data) else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return data
    }

    private func resolvedTool() -> URL? {
        if !didResolveTool {
            didResolveTool = true
            tool = locateTool()
        }
        return tool
    }

    // MARK: - ADB

    /// `pm path` → the base APK pulled into a fresh temp directory. The
    /// caller deletes the directory when it is done with the APK.
    nonisolated private static func pullBaseAPK(
        package: String,
        serial: String,
        adbClient: AdbClient
    ) async -> URL? {
        guard let output = try? await adbClient.shell(serial: serial, ["pm", "path", package]) else {
            return nil
        }
        guard let remote = remoteAPKPath(fromPMOutput: output) else { return nil }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicehubpro-appicon-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )) != nil else {
            return nil
        }
        let local = directory.appendingPathComponent("base.apk")
        do {
            try await adbClient.pull(serial: serial, remotePath: remote, to: local)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        return local
    }

    /// The path `pm path` printed for the base APK; a split's `base.apk`
    /// wins, otherwise the first path.
    nonisolated static func remoteAPKPath(fromPMOutput output: String) -> String? {
        let paths = output.split(separator: "\n").compactMap { line -> String? in
            guard let range = line.range(of: "package:") else { return nil }
            let path = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return path.isEmpty ? nil : path
        }
        return paths.first(where: { $0.hasSuffix("/base.apk") }) ?? paths.first
    }
}

/// One queued device icon load.
private struct DeviceIconRequest: Sendable {
    let key: String
    let package: String
    let version: String?
    let serial: String
}

/// The running device loads by key. Owned by the store (and never captured
/// by a load), so releasing the store — the Apps tab closing — cancels every
/// load still pulling.
private final class LoadTasks: Sendable {
    private let tasks = Mutex<[String: Task<Void, Never>]>([:])

    func insert(_ task: Task<Void, Never>, for key: String) {
        tasks.withLock { $0[key] = task }
    }

    func remove(_ key: String) {
        _ = tasks.withLock { $0.removeValue(forKey: key) }
    }

    func cancel(_ keys: Set<String>) {
        let cancelled = tasks.withLock { tasks in
            keys.compactMap { tasks.removeValue(forKey: $0) }
        }
        cancelled.forEach { $0.cancel() }
    }

    deinit {
        tasks.withLock { tasks in
            tasks.values.forEach { $0.cancel() }
        }
    }
}
