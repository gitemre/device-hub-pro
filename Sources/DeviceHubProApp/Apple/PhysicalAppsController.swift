import AppKit
import Foundation
import Observation
import DeviceHubProKit

/// Device Hub's scope popup of the Apps tab: "All
/// Apps" (the default, like Device Hub's) is the home screen's apps, the
/// developer-installed and removable ones plus the default apps the OS ships
/// (`device info apps --include-default-apps`, measured on a test iPhone as
/// the same 81 apps as `--include-all-apps`; hidden, internal and App Clip
/// entries are left out, and so are the non-removable system services and
/// UI-test runners: `PhysicalApp.visibleSystemApps`); "User Apps" is devicectl's plain listing (the
/// developer-installed apps).
enum PhysicalAppScope: String, CaseIterable, Identifiable, Hashable, Sendable {
    case allApps
    case userApps

    var id: String { rawValue }

    var label: String {
        switch self {
        case .userApps: "User Apps"
        case .allApps: "All Apps"
        }
    }

    var emptyLabel: String {
        switch self {
        case .userApps: "No user-installed apps"
        case .allApps: "No Apps"
        }
    }

    /// Whether the listing asks for the default apps too.
    var includesDefaultApps: Bool { self == .allApps }
}

/// One app of a physical iPhone or iPad, as `devicectl device info apps`
/// lists it. The scope decides how much of the
/// device's list the Apps tab shows (`PhysicalAppScope`).
struct PhysicalApp: Identifiable, Equatable, Sendable {
    let bundleIdentifier: String
    let name: String?
    let version: String?
    let bundleVersion: String?
    /// The bundle's `file://` URL on the device.
    let url: String?
    let isRemovable: Bool
    let isDeveloperApp: Bool
    /// An app that ships with the OS (devicectl's "default": not a developer
    /// app), removable or not.
    let isDefaultApp: Bool
    /// A hidden or internal app, or an App Clip: not on the home screen, so
    /// the list leaves it out.
    let isNotOnHomeScreen: Bool
    /// Whether the app's data container can be read (development builds).
    let containerAccessible: Bool

    var id: String { bundleIdentifier }

    /// The name devicectl prints, else the bundle identifier.
    var title: String {
        if let name, !name.isEmpty { return name }
        return bundleIdentifier
    }

    var displayVersion: String? { version ?? bundleVersion }

    init(_ app: DevicectlInstalledApp) {
        bundleIdentifier = app.bundleIdentifier
        name = app.name
        version = app.version
        bundleVersion = app.bundleVersion
        url = app.url
        isRemovable = app.removable ?? false
        isDeveloperApp = app.builtByDeveloper ?? false
        isDefaultApp = app.defaultApp ?? false
        isNotOnHomeScreen = (app.hidden ?? false) || (app.internalApp ?? false) || (app.appClip ?? false)
            || Self.isBackgroundSystemApp(
                bundleIdentifier: app.bundleIdentifier,
                isDefaultApp: app.defaultApp ?? false,
                isRemovable: app.removable ?? false
            )
            || Self.isTestRunner(bundleIdentifier: app.bundleIdentifier)
        containerAccessible = app.containerAccessible ?? false
    }

    /// The system apps a user can open that cannot be removed: Phone and
    /// Settings, and Feedback on a beta. devicectl's JSON has no "shown on
    /// the home screen" flag (a measured iOS 27.0 list marks every entry
    /// `hidden: false`), and its other non-removable default apps are
    /// background services with no icon of their own (ActivityMessagesApp,
    /// AssistiveTouch, BluetoothUIService, BusinessExtensionsWrapper, Web,
    /// Stickers, Xcode Previews...) that Device Hub does not list.
    static let visibleSystemApps: Set<String> = [
        "com.apple.mobilephone", "com.apple.Preferences", "com.apple.appleseed.FeedbackAssistant",
    ]

    /// A default app that cannot be removed and is not one of the apps a
    /// user opens (`visibleSystemApps`): a service, not a home screen app.
    static func isBackgroundSystemApp(bundleIdentifier: String, isDefaultApp: Bool, isRemovable: Bool) -> Bool {
        isDefaultApp && !isRemovable && !visibleSystemApps.contains(bundleIdentifier)
    }

    /// An XCTest UI-test runner's host (`*.xctrunner`): installed beside a
    /// development build, never opened by a user.
    static func isTestRunner(bundleIdentifier: String) -> Bool {
        bundleIdentifier.hasSuffix(".xctrunner")
    }

    /// The bundle folder's path without the `/private` prefix the device
    /// uses in some listings and not in others, or nil without a file URL.
    var bundlePath: String? {
        url.flatMap(Self.normalizedPath(ofFileURL:))
    }

    /// The names an app's own executable and crash reports go by: the
    /// bundle folder's name without `.app` (what a development build's
    /// `CFBundleExecutable` almost always is), and the display name.
    var processNames: [String] {
        var names: [String] = []
        if let bundlePath {
            let folder = (bundlePath as NSString).lastPathComponent
            if folder.lowercased().hasSuffix(".app") {
                names.append(String(folder.dropLast(4)))
            }
        }
        if let name, !name.isEmpty { names.append(name) }
        return names
    }

    /// `file:///private/var/x/Y.app/` -> `/var/x/Y.app`.
    static func normalizedPath(ofFileURL text: String) -> String? {
        guard let url = URL(string: text), url.isFileURL else { return nil }
        var path = url.path
        if path.hasPrefix("/private/") { path.removeFirst("/private".count) }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The pids of `app`'s own processes among a device's running ones: the
    /// executables that sit directly in the bundle folder. An app extension's
    /// process (`X.app/PlugIns/W.appex/W`) is not the app.
    static func pids(of app: PhysicalApp, in processes: [DevicectlRunningProcess]) -> [Int] {
        guard let bundle = app.bundlePath else { return [] }
        return processes.compactMap { process in
            guard let executable = process.executable,
                  let path = normalizedPath(ofFileURL: executable),
                  (path as NSString).deletingLastPathComponent == bundle,
                  let pid = process.processIdentifier, pid > 0
            else { return nil }
            return pid
        }
    }
}

/// One entry of an app's data container listing (`device info files`).
struct PhysicalContainerFile: Identifiable, Equatable, Sendable {
    let relativePath: String
    let isDirectory: Bool
    let size: Int?
    let modified: Date?

    var id: String { relativePath }

    /// The last path component.
    var name: String { (relativePath as NSString).lastPathComponent }

    /// How deep the entry sits: 0 for a top-level one.
    var depth: Int { relativePath.split(separator: "/").count - 1 }

    /// The container's entries as devicectl lists them (depth first), ready
    /// to show. Nothing is dropped: folders stay so the tree reads.
    static func list(from files: [DevicectlDeviceFile]) -> [PhysicalContainerFile] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return files.map { file in
            PhysicalContainerFile(
                relativePath: file.relativePath,
                isDirectory: file.isDirectory,
                size: file.metadata?.size,
                modified: file.metadata?.lastModDate.flatMap(formatter.date(from:))
            )
        }
    }
}

/// Copies one file off a physical device into a place the user chose
/// (`devicectl device copy from`), for the container files and the crash
/// logs. The user is asked where first; devicectl writes to a temporary
/// file, which then replaces the chosen file, so a failed copy never leaves
/// a half-written file (or removes an existing one) at the destination.
/// Nothing on the device is ever changed.
@MainActor
struct PhysicalFileSaver {
    let picker: any FileDestinationPicker
    let temporaryDirectory: URL

    /// The saved file, or nil when the user cancelled the panel.
    func save(
        client: DevicectlPhysicalClient,
        domain: DevicectlPhysicalDomain,
        source: String
    ) async throws -> URL? {
        let name = (source as NSString).lastPathComponent
        guard let destination = picker.chooseDestination(
            suggestedName: name,
            directory: picker.autoSaveDirectory
        ) else { return nil }
        let folder = temporaryDirectory.appendingPathComponent("devicehubpro-physical-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            // Best effort: a leftover temporary folder must not fail a save.
            try? FileManager.default.removeItem(at: folder)
        }
        let staged = folder.appendingPathComponent(name.isEmpty ? "file" : name)
        _ = try await client.copyFrom(domain: domain, source: source, to: staged)
        guard FileManager.default.fileExists(atPath: staged.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: staged, to: destination)
        return destination
    }
}

/// What a file or link dropped on a physical device's stage or its Apps tab
/// becomes (the simulator's `SimulatorDropRouting`, narrowed to what the
/// physical client runs): an app to install, or a link to open.
enum PhysicalDrop: Equatable {
    /// A `.app` bundle: `install app`.
    case installApp(URL)
    /// An `.ipa`: unzipped into a temporary folder, then installed.
    case installArchive(URL)
    /// A link: `process openURL`.
    case openURL(URL)
    case unsupported(URL, reason: String)

    static func route(_ urls: [URL]) -> [PhysicalDrop] {
        urls.map(route)
    }

    static func route(_ url: URL) -> PhysicalDrop {
        guard url.isFileURL else {
            guard let scheme = url.scheme, !scheme.isEmpty else {
                return .unsupported(url, reason: "“\(url.absoluteString)” is not a link a device can open.")
            }
            return .openURL(url)
        }
        switch url.pathExtension.lowercased() {
        case "app": return .installApp(url)
        case "ipa": return .installArchive(url)
        default:
            return .unsupported(
                url,
                reason: "A physical device can't use “\(url.lastPathComponent)”. Drop an app (.app or .ipa) or a link."
            )
        }
    }
}

/// The Apps tab of an enabled physical iPhone or iPad (Phase
/// 9B-2b): its developer-installed and removable apps, Launch (replacing a
/// running copy), Terminate, Uninstall (confirmed), Install (a `.app` or
/// `.ipa`, picked or dropped), Open URL and a development build's container
/// files. Per window: the workspace owns one.
///
/// Every call goes through `ApplePhysicalInventory.client(for:)`, which
/// answers nil for a device that is not enabled, paired and connected. A nil
/// client shows the device's state hint in place of the controls, and no
/// command is sent. Failures are shown in the window's status line and alert;
/// CoreDevice's launch (10002) and signal (10014) errors say what the device
/// said. The list is read again after each app action.
@MainActor
@Observable
final class PhysicalAppsController {
    /// What runs on the device now (the footer's "Installing…").
    enum Activity: Equatable {
        case launching(String)
        case terminating(String)
        case uninstalling(String)
        case installing(String)
        case openingLink
    }

    /// An app whose uninstall the user is asked about.
    struct UninstallRequest: Equatable, Identifiable {
        let udid: String
        let bundleIdentifier: String
        let name: String

        var id: String { bundleIdentifier }
    }

    /// An app whose container files the sheet shows.
    struct ContainerTarget: Equatable, Identifiable {
        let udid: String
        let bundleIdentifier: String
        let name: String

        var id: String { bundleIdentifier }
    }

    /// The last listing, sorted by title; they belong to `appsUDID`.
    private(set) var apps: [PhysicalApp] = []
    /// The device whose apps `apps` holds.
    private(set) var appsUDID: String?
    private(set) var isLoading = false
    /// Device Hub's scope popup: "All Apps" (the default) or "User Apps".
    /// Changing it reloads (`load(udid:)` reads it).
    var scope: PhysicalAppScope = .allApps
    /// The scope `apps` was listed with.
    private(set) var loadedScope: PhysicalAppScope?
    /// The bundle identifiers of the listed apps that are running now (the
    /// context menu offers Terminate only for these). Read with the list,
    /// best effort: a failed read leaves the set empty.
    private(set) var runningBundleIdentifiers: Set<String> = []
    /// Why there is no list (the device cannot be asked, or the read failed).
    private(set) var loadProblem: String?
    var filter = ""
    /// The selected app's bundle identifier; Diagnostics' "My app only" reads
    /// it.
    var selectedID: String?
    /// The operation in flight, one at a time.
    private(set) var activity: Activity?
    var pendingUninstall: UninstallRequest?
    /// The app whose container the sheet shows; setting it nil closes it.
    var containerTarget: ContainerTarget?
    private(set) var containerFiles: [PhysicalContainerFile] = []
    private(set) var isLoadingContainer = false
    private(set) var containerProblem: String?
    /// The Open URL text. The Apps tab has no field for it any more (Device
    /// Hub's has none); the menus' Open URL sheet edits it.
    var openURLDraft = ""
    /// The real icons of the listed apps (lazy, cached, at most two
    /// fetches at a time).
    let icons: PhysicalAppIconStore
    /// The hardware UDID of the device the window shows, when it is a
    /// physical one (the menus' `openURL(_:)` acts on it).
    @ObservationIgnored var selectedUDID: @MainActor () -> String? = { nil }

    /// Remembers a link that opened: the recent links Android's Links row and
    /// the simulator keep (`RecentLinkStore`). Wired by its owner.
    @ObservationIgnored var recordRecentURL: @MainActor (_ url: String) -> Void = { _ in }
    /// Where "Show in Finder" goes (the Finder in the app, a recorder in tests).
    @ObservationIgnored var revealInFinder: @MainActor (_ url: URL) -> Void = { url in
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    /// Where an `.ipa` is unzipped for an install.
    @ObservationIgnored var temporaryDirectory: URL
    /// How often a confirmed operation checks whether the one in flight
    /// has finished.
    @ObservationIgnored var busyPollInterval: Duration = .milliseconds(100)

    @ObservationIgnored private let inventory: ApplePhysicalInventory
    @ObservationIgnored private let status: StatusCenter
    @ObservationIgnored private let picker: any FileDestinationPicker
    @ObservationIgnored private var loadGeneration = 0
    /// The last listing per device and scope: shown at once when the tab
    /// opens again while the fresh read runs.
    @ObservationIgnored private var cache: [String: [PhysicalAppScope: Snapshot]] = [:]
    /// Devices in `cache`, least recently listed first.
    @ObservationIgnored private var cacheOrder: [String] = []
    static let cachedDeviceLimit = 4

    private struct Snapshot {
        let apps: [PhysicalApp]
        let running: Set<String>
    }
    @ObservationIgnored private var containerGeneration = 0

    init(
        inventory: ApplePhysicalInventory,
        status: StatusCenter,
        picker: any FileDestinationPicker,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        iconCacheDirectory: URL = PhysicalAppIconStore.defaultCacheDirectory(),
        iconConcurrency: Int = PhysicalAppIconStore.defaultMaxConcurrent
    ) {
        self.inventory = inventory
        self.status = status
        self.picker = picker
        self.temporaryDirectory = temporaryDirectory
        // The icons come through the inventory's client like every other
        // call: a device that cannot be asked yields none.
        icons = PhysicalAppIconStore(cacheDirectory: iconCacheDirectory, maxConcurrent: iconConcurrency) {
            [inventory] udid, bundleID, size, destination in
            guard let client = await inventory.client(for: udid) else {
                throw PhysicalPreviewError(message: "the device is not available")
            }
            _ = try await client.appIcon(bundleID: bundleID, width: size, height: size, to: destination)
        }
    }

    // MARK: - Reading

    /// The listing through the filter: the title in the user's language, the
    /// bundle identifier without one.
    var filteredApps: [PhysicalApp] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return apps.filter { app in
            query.isEmpty
                || app.title.localizedCaseInsensitiveContains(query)
                || app.bundleIdentifier.range(of: query, options: .caseInsensitive) != nil
        }
    }

    var isBusy: Bool { activity != nil }

    /// The selected app of `udid`'s list.
    func selectedApp(udid: String) -> PhysicalApp? {
        guard appsUDID == PhysicalDeviceOptIn.normalize(udid), let selectedID else { return nil }
        return apps.first { $0.id == selectedID }
    }

    /// What the tab says instead of its controls for a device that cannot be
    /// asked: the state's hint.
    func unavailableText(udid: String) -> String {
        ApplePhysicalInventory.unavailableText(entry: inventory.entry(udid: udid))
    }

    // MARK: - Listing

    /// Reads `udid`'s apps (`device info apps`). A device that cannot be asked
    /// has none to list: the tab shows its hint and nothing is sent.
    func load(udid: String) async {
        let key = PhysicalDeviceOptIn.normalize(udid)
        loadGeneration += 1
        let generation = loadGeneration
        if appsUDID != key || loadedScope != scope {
            if appsUDID != key { selectedID = nil }
            let cached = cache[key]?[scope]
            apps = cached?.apps ?? []
            appsUDID = key
            loadedScope = scope
            runningBundleIdentifiers = cached?.running ?? []
            loadProblem = nil
        }
        let listedScope = scope
        guard let client = await inventory.client(for: key) else {
            guard generation == loadGeneration else { return }
            apps = []
            loadProblem = unavailableText(udid: key)
            isLoading = false
            return
        }
        isLoading = true
        defer {
            if generation == loadGeneration { isLoading = false }
        }
        do {
            // Which of them run: best effort, for the menu's Terminate; read
            // while the list is.
            async let runningRead = try? await client.processes().value.runningProcesses
            let all = try await client.apps(includeDefaultApps: listedScope.includesDefaultApps)
                .value.apps.map(PhysicalApp.init)
            let processes = await runningRead
            let listed = listedScope == .allApps ? all.filter { !$0.isNotOnHomeScreen } : all
            guard generation == loadGeneration else { return }
            apps = listed.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            runningBundleIdentifiers = Set(listed.filter { app in
                processes.map { !PhysicalApp.pids(of: app, in: $0).isEmpty } ?? false
            }.map(\.id))
            cache[key, default: [:]][listedScope] = Snapshot(apps: apps, running: runningBundleIdentifiers)
            // Keep the few most recently listed devices only.
            cacheOrder.removeAll { $0 == key }
            cacheOrder.append(key)
            while cacheOrder.count > Self.cachedDeviceLimit {
                cache[cacheOrder.removeFirst()] = nil
            }
            icons.retain(apps: apps, udid: key)
            loadProblem = nil
            if let selectedID, !apps.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            }
        } catch {
            // A cancelled load (the view went away) is not a failure.
            guard !error.isCancellation, generation == loadGeneration else { return }
            loadProblem = "Could not list the apps: \(ApplePhysicalController.describe(error))"
        }
    }

    /// Reads the shown device's apps again.
    func reload() async {
        guard let udid = appsUDID else { return }
        await load(udid: udid)
    }

    /// Forgets the list (the inspector shows another device, or this one
    /// cannot be asked any more).
    func clear() {
        loadGeneration += 1
        apps = []
        appsUDID = nil
        loadedScope = nil
        runningBundleIdentifiers = []
        loadProblem = nil
        isLoading = false
        selectedID = nil
    }

    // MARK: - App actions

    /// Launches `app`, replacing a running copy (`--terminate-existing`).
    func launch(_ app: PhysicalApp, udid: String) async {
        guard let client = await clientOrExplain(udid), begin(.launching(app.title)) else { return }
        defer { activity = nil }
        do {
            _ = try await client.launchApp(bundleID: app.bundleIdentifier, terminateExisting: true)
            status.flash("Launched \(app.title)")
        } catch {
            status.errorMessage = Self.launchFailure(app.title, error)
        }
        await reloadIfShown(udid)
    }

    /// Terminates `app`: finds its process among the device's running ones
    /// (`device info processes`, the executables inside its bundle) and
    /// sends each a SIGTERM.
    func terminate(_ app: PhysicalApp, udid: String) async {
        guard let client = await clientOrExplain(udid), begin(.terminating(app.title)) else { return }
        defer { activity = nil }
        do {
            let processes = try await client.processes().value.runningProcesses
            let pids = PhysicalApp.pids(of: app, in: processes)
            guard !pids.isEmpty else {
                status.flash("\(app.title) is not running")
                return
            }
            for pid in pids {
                _ = try await client.terminate(pid: pid)
            }
            status.flash("Terminated \(app.title)")
        } catch {
            status.errorMessage = Self.terminateFailure(app.title, error)
        }
        await reloadIfShown(udid)
    }

    /// Asks whether to uninstall `app`: the confirmation the Apps tab shows.
    func requestUninstall(_ app: PhysicalApp, udid: String) {
        pendingUninstall = UninstallRequest(
            udid: PhysicalDeviceOptIn.normalize(udid),
            bundleIdentifier: app.bundleIdentifier,
            name: app.title
        )
    }

    /// Uninstalls after the user confirmed (after the operation in flight,
    /// if one is), then reads the list again.
    func uninstall(bundleIdentifier: String, name: String, udid: String) async {
        guard let client = await clientOrExplain(udid), await beginAfterCurrent(.uninstalling(name)) else { return }
        defer { activity = nil }
        do {
            _ = try await client.uninstallApp(bundleID: bundleIdentifier)
            status.flash("Uninstalled \(name)")
        } catch {
            status.errorMessage = "Failed to Uninstall App: \(ApplePhysicalController.describe(error))"
        }
        await reloadIfShown(udid)
    }

    // MARK: - Installing

    /// Installs a `.app`, or the app in an `.ipa`, on `udid`. The device
    /// checks the signature: a build its provisioning profile does not list
    /// fails with CoreDevice's own words. Returns whether it was installed.
    @discardableResult
    func install(_ url: URL, udid: String) async -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        guard fileExtension == "ipa" || fileExtension == "app" else {
            status.errorMessage = "“\(url.lastPathComponent)” is not an app (.app or .ipa)."
            return false
        }
        guard let client = await clientOrExplain(udid),
              begin(.installing(url.deletingPathExtension().lastPathComponent))
        else { return false }
        let progress = "Installing \(url.lastPathComponent)…"
        status.showProgress(progress)
        var unpacked: URL?
        defer {
            activity = nil
            status.clear(ifShowing: progress)
            if let unpacked {
                // Best effort: a leftover temporary folder is harmless.
                try? FileManager.default.removeItem(at: unpacked)
            }
        }
        var app = url
        if fileExtension == "ipa" {
            let folder = temporaryDirectory.appendingPathComponent("DeviceHubPro-install-\(UUID().uuidString)", isDirectory: true)
            unpacked = folder
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                app = try await SimulatorAppArchive.extract(url, into: folder)
            } catch {
                status.errorMessage = "Failed to Install App: \(error)"
                return false
            }
        }
        let name = SimulatorAppBundle.read(app: app)?.title ?? app.deletingPathExtension().lastPathComponent
        let installed: DevicectlInstallResult
        do {
            installed = try await client.installApp(at: app).value
        } catch {
            status.errorMessage = "Failed to Install App: \(ApplePhysicalController.describe(error))"
            return false
        }
        status.flash("Installed \(name)")
        await reloadIfShown(udid)
        if appsUDID == PhysicalDeviceOptIn.normalize(udid),
           let bundleID = installed.installedApplications.first?.bundleID,
           apps.contains(where: { $0.id == bundleID }) {
            selectedID = bundleID
        }
        return true
    }

    // MARK: - Drops

    /// Handles what was dropped on `udid`'s stage or Apps tab
    /// (`PhysicalDrop`): apps install, links open, in the order they came.
    func handleDrop(_ urls: [URL], udid: String) async {
        for drop in PhysicalDrop.route(urls) {
            switch drop {
            case .installApp(let url), .installArchive(let url):
                await install(url, udid: udid)
            case .openURL(let url):
                await openURL(url, shownAs: url.absoluteString, udid: udid, afterCurrent: false)
            case .unsupported(_, let reason):
                status.errorMessage = reason
            }
        }
    }

    // MARK: - Open URL

    /// Opens typed text as a link on the device (`device process openURL`):
    /// text that is no link never reaches devicectl (`SimctlClient.readLink`),
    /// and the alert says why. Returns whether it opened.
    @discardableResult
    func openURL(_ text: String) async -> Bool {
        guard let udid = selectedUDID() else { return false }
        return await openURL(text, udid: udid)
    }

    /// `openURL(_:)` for an explicit device.
    @discardableResult
    func openURL(_ text: String, udid: String) async -> Bool {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch SimctlClient.readLink(typed) {
        case .success(let url):
            return await openURL(url, shownAs: typed, udid: udid, afterCurrent: true)
        case .failure(.noScheme):
            status.errorMessage = "\(typed) is not a URL: it needs a scheme, such as https: or myapp:."
        case .failure(.hostFile):
            status.errorMessage = "\(typed) is a file on the Mac: a device opens links, not files."
        case .failure(.unreadable):
            status.errorMessage = "\(typed) cannot be read as a URL."
        }
        return false
    }

    @discardableResult
    private func openURL(_ url: URL, shownAs shown: String, udid: String, afterCurrent: Bool) async -> Bool {
        guard let client = await clientOrExplain(udid) else { return false }
        let claimed = if afterCurrent { await beginAfterCurrent(.openingLink) } else { begin(.openingLink) }
        guard claimed else { return false }
        defer { activity = nil }
        do {
            _ = try await client.openURL(url)
        } catch {
            status.errorMessage = "Could not open \(shown): \(ApplePhysicalController.describe(error))"
            return false
        }
        recordRecentURL(shown)
        status.flash("Opened \(shown)")
        return true
    }

    // MARK: - Container files

    /// Opens the container sheet for `app` and lists its files
    /// (`device info files`, the app's data container).
    func showContainerFiles(_ app: PhysicalApp, udid: String) async {
        let key = PhysicalDeviceOptIn.normalize(udid)
        let target = ContainerTarget(udid: key, bundleIdentifier: app.bundleIdentifier, name: app.title)
        containerTarget = target
        containerFiles = []
        containerProblem = nil
        containerGeneration += 1
        let generation = containerGeneration
        guard let client = await inventory.client(for: key) else {
            containerProblem = unavailableText(udid: key)
            return
        }
        isLoadingContainer = true
        defer {
            if generation == containerGeneration { isLoadingContainer = false }
        }
        do {
            let listed = try await client.listFiles(domain: .appDataContainer(bundleID: app.bundleIdentifier)).value
            guard generation == containerGeneration else { return }
            containerFiles = PhysicalContainerFile.list(from: listed.files)
        } catch {
            guard generation == containerGeneration else { return }
            containerProblem = "Could not list the files: \(ApplePhysicalController.describe(error))"
        }
    }

    /// Ends the sheet's listing.
    func closeContainerFiles() {
        containerGeneration += 1
        containerTarget = nil
        containerFiles = []
        containerProblem = nil
        isLoadingContainer = false
    }

    /// "Save to…": asks where, then copies `file` off the device
    /// (`device copy from`). Returns the saved file, nil when cancelled or
    /// failed (the reason is in the status line).
    @discardableResult
    func saveContainerFile(_ file: PhysicalContainerFile, revealAfter: Bool = false) async -> URL? {
        guard let target = containerTarget, !file.isDirectory,
              let client = await inventory.client(for: target.udid)
        else { return nil }
        let saver = PhysicalFileSaver(picker: picker, temporaryDirectory: temporaryDirectory)
        do {
            guard let saved = try await saver.save(
                client: client,
                domain: .appDataContainer(bundleID: target.bundleIdentifier),
                source: file.relativePath
            ) else { return nil }
            status.flash("Saved \(saved.lastPathComponent)")
            if revealAfter { revealInFinder(saved) }
            return saved
        } catch {
            status.errorMessage = "Could not save \(file.name): \(ApplePhysicalController.describe(error))"
            return nil
        }
    }

    // MARK: - Errors

    /// 10002: "<app> failed to launch: <reason>", in CoreDevice's words.
    static func launchFailure(_ title: String, _ error: Error) -> String {
        if case DevicectlPhysicalError.applicationFailedToLaunch(let message, let reason) = error {
            return "\(title) failed to launch: \(reason ?? message)"
        }
        return "\(title) failed to launch: \(ApplePhysicalController.describe(error))"
    }

    /// 10014: "<app> could not be stopped: <reason>".
    static func terminateFailure(_ title: String, _ error: Error) -> String {
        if case DevicectlPhysicalError.failedToSendSignal(let message, let reason) = error {
            return "\(title) could not be stopped: \(reason ?? message)"
        }
        return "\(title) could not be stopped: \(ApplePhysicalController.describe(error))"
    }

    // MARK: - Internals

    /// The client for `udid`, or nil after saying why in the status line
    /// (the device's state hint); nothing is sent then.
    private func clientOrExplain(_ udid: String) async -> DevicectlPhysicalClient? {
        if let client = await inventory.client(for: udid) { return client }
        status.errorMessage = unavailableText(udid: udid)
        return nil
    }

    /// Claims the one operation slot; a second operation is refused with a
    /// word rather than silently.
    private func begin(_ next: Activity) -> Bool {
        guard activity == nil else {
            status.flash("Wait for the current device operation to finish")
            return false
        }
        activity = next
        return true
    }

    /// Claims the slot for an operation the user already confirmed: once the
    /// one in flight finishes, never refused (a cancelled wait claims nothing).
    private func beginAfterCurrent(_ next: Activity) async -> Bool {
        while activity != nil {
            do {
                try await Task.sleep(for: busyPollInterval)
            } catch {
                return false
            }
        }
        activity = next
        return true
    }

    private func reloadIfShown(_ udid: String) async {
        guard appsUDID == PhysicalDeviceOptIn.normalize(udid) else { return }
        await load(udid: udid)
    }
}

extension ApplePhysicalInventory {
    /// What a tab says instead of its controls for a device that cannot be
    /// asked (not enabled, unpaired, disconnected): the state's hint.
    static func unavailableText(entry: ApplePhysicalEntry?) -> String {
        entry?.hint ?? "This device is not available."
    }
}
