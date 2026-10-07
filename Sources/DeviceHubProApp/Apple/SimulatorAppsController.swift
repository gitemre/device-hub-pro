import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import DeviceHubProKit

/// Device Hub's app filter (S28), read from the fields `simctl listapps`
/// prints: All Apps, App Clips, Default (not a developer app, devicectl's
/// meaning of "default") and Developer. Until 2026-09-29 the popup also offered
/// Hidden, Internal and Removable, which Device Hub's does not (measured on
/// Device Hub 27.0: All Apps ✓, a separator, App Clips, Default, Developer).
enum SimulatorAppScope: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all
    case appClips
    case defaultApps
    case developer

    var id: String { rawValue }

    /// Device Hub's filter titles.
    var label: String {
        switch self {
        case .all: "All Apps"
        case .appClips: "App Clips"
        case .defaultApps: "Default"
        case .developer: "Developer"
        }
    }

    /// Device Hub's empty states ("No Developer Apps", …).
    var emptyLabel: String {
        switch self {
        case .all: "No Apps"
        case .appClips: "No App Clips"
        case .defaultApps: "No Default Apps"
        case .developer: "No Developer Apps"
        }
    }

    func admits(_ app: SimulatorApp) -> Bool {
        switch self {
        case .all: true
        case .appClips: app.isAppClip
        case .defaultApps: !app.isDeveloperApp
        case .developer: app.isDeveloperApp
        }
    }
}

/// A simulator's apps in the inspector (Device Hub's S28/S29) and what is
/// dropped on its stage: the list `simctl listapps`
/// prints with its scope and filter, each app's icon read from its bundle at
/// runtime, Launch, Terminate, Uninstall, Show Data Container in Finder, and
/// installs, media imports, root certificates and links (a dropped link and
/// the Device menu's Open URL… take the same path).
///
/// Installs check the bundle first (`SimulatorAppBundle`): a device build or
/// one for another platform is refused with the reason, where simctl would
/// copy it and fail in the Mac's language. An `.ipa` or a zipped `.app` is
/// unzipped into a temporary folder that is removed afterwards. The shown
/// list is read again after an install or an uninstall, and whenever the
/// simulator's installed-apps folder changes (an app installed from Xcode
/// or Device Hub), as Device Hub's does.
///
/// It holds no reference to the model: simctl and the listing come from the
/// inventory, and nothing is forwarded through `AppModel` (the views call it
/// as `model.simulatorApps`).
@MainActor
@Observable
final class SimulatorAppsController {
    /// What runs on a simulator now (the footer's "Installing…").
    enum Activity: Equatable {
        case installing(String)
        case uninstalling(String)
        case importingMedia
        case trustingCertificate
        case openingLink
        case resettingKeychain
        case savingState(String)
        case restoringState(String)
    }

    /// The last listing, sorted by title (Device Hub's order: literal, so a
    /// capital letter sorts before a lower-case one); they belong to `appsUDID`.
    private(set) var apps: [SimulatorApp] = []
    /// The simulator whose apps `apps` holds.
    private(set) var appsUDID: String?
    private(set) var isLoading = false
    /// Why there is no list (the simulator is off, or the read failed).
    private(set) var loadProblem: String?
    var scope: SimulatorAppScope = .all
    var filter = ""
    /// The operation in flight, one at a time.
    private(set) var activity: Activity?
    /// Each app's icon once read, by bundle path; nil when the bundle ships
    /// none (the row keeps its generic glyph).
    private(set) var icons: [String: NSImage?] = [:]
    /// The bundle paths whose tile is Device Hub's icon template rather than
    /// the App Store "A" (`SimulatorAppBundle.usesIconTemplateTile`).
    private(set) var templateTiles: Set<String> = []
    /// The install popover's recents: the last installed simulator apps.
    let recents: RecentAPKStore

    /// Remembers a link that opened (a drop's or the Open URL sheet's): the
    /// recent links Android's Links row keeps (`RecentLinkStore`), which the
    /// sheet offers, so one deep link is tried on both platforms. Wired by
    /// its owner.
    @ObservationIgnored var recordRecentURL: @MainActor (_ url: String) -> Void = { _ in }
    /// An install or an uninstall on the simulator succeeded: its owner has
    /// the apps read again where another view lists them (the log's App
    /// picker, `LogcatController.reloadSimulatorApps`). Wired by its owner.
    @ObservationIgnored var appsChanged: @MainActor (_ udid: String) -> Void = { _ in }
    /// Where "Show in Finder" goes (the Finder in the app, a recorder in tests).
    @ObservationIgnored var revealInFinder: @MainActor (_ url: URL) -> Void = { url in
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    /// Where archives are unzipped for an install.
    @ObservationIgnored var temporaryDirectory = FileManager.default.temporaryDirectory
    /// Whether the list holds the launch-prohibited system apps `simctl
    /// listapps` leaves out and Device Hub lists (`SimulatorRuntimeApps`).
    @ObservationIgnored var listsLaunchProhibitedApps = true
    /// How long a folder change waits before the list is read again.
    @ObservationIgnored var changeDebounce: Duration = .milliseconds(500)
    /// How often a confirmed operation checks whether the one in flight
    /// has finished.
    @ObservationIgnored var busyPollInterval: Duration = .milliseconds(100)

    @ObservationIgnored private let simulators: SimulatorInventory
    @ObservationIgnored private let status: StatusCenter
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var iconLoads: Set<String> = []
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var watchedFolder: String?
    @ObservationIgnored private var pendingReload: Task<Void, Never>?

    /// The recents' defaults key (the APK recents' store, its own list).
    static let recentsKey = "recentSimulatorApps"

    init(simulators: SimulatorInventory, status: StatusCenter, defaults: UserDefaults) {
        self.simulators = simulators
        self.status = status
        self.recents = RecentAPKStore(defaults: defaults, key: Self.recentsKey)
    }

    // MARK: - Reading

    /// The listing through the scope and the filter: the title in the
    /// user's language, the bundle identifier without one (a Turkish "I" is
    /// not an "i", but an identifier is ASCII).
    var filteredApps: [SimulatorApp] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return apps.filter { app in
            scope.admits(app)
                && (query.isEmpty
                    || app.title.localizedCaseInsensitiveContains(query)
                    || app.bundleIdentifier.range(of: query, options: .caseInsensitive) != nil)
        }
    }

    var isBusy: Bool { activity != nil }

    /// The icon of `app`, once `loadIcon(for:)` read it.
    func icon(for app: SimulatorApp) -> NSImage? {
        guard let path = app.path else { return nil }
        return icons[path] ?? nil
    }

    /// Whether `app` without an icon gets the icon template tile.
    func usesTemplateTile(_ app: SimulatorApp) -> Bool {
        app.path.map(templateTiles.contains) ?? false
    }

    // MARK: - Listing

    /// Reads `udid`'s apps (`simctl listapps`) and follows its installed-apps
    /// folder. A simulator that is off has none to list (simctl refuses).
    func load(udid: String) async {
        guard let simctl = simulators.simctl else { return }
        loadGeneration += 1
        let generation = loadGeneration
        if appsUDID != udid {
            apps = []
            appsUDID = udid
            loadProblem = nil
        }
        isLoading = true
        defer {
            if generation == loadGeneration { isLoading = false }
        }
        do {
            let listed = listsLaunchProhibitedApps
                ? try await simctl.listAllApps(udid: udid)
                : try await simctl.listApps(udid: udid)
            guard generation == loadGeneration else { return }
            apps = listed.sorted { Self.isOrdered($0, before: $1) }
            // Icons of apps that are gone (or of another simulator) go.
            let livePaths = Set(apps.compactMap(\.path))
            icons = icons.filter { livePaths.contains($0.key) }
            templateTiles.formIntersection(livePaths)
            loadProblem = nil
            watchInstalledApps(of: udid)
        } catch let failure as SimctlFailure where failure.kind == .invalidState {
            guard generation == loadGeneration else { return }
            apps = []
            loadProblem = Self.shutDownProblem
            stopWatching()
        } catch {
            // A cancelled load (the view went away) is not a failure.
            guard !error.isCancellation, generation == loadGeneration else { return }
            loadProblem = "Could not list the apps: \(Self.reason(error))"
        }
    }

    /// Reads the shown simulator's apps again.
    func reload() async {
        guard let udid = appsUDID else { return }
        await load(udid: udid)
    }

    /// Forgets the list (the inspector shows another device).
    func clear() {
        loadGeneration += 1
        apps = []
        appsUDID = nil
        loadProblem = nil
        isLoading = false
        stopWatching()
    }

    static let shutDownProblem = "Start the simulator to see its apps."

    /// Device Hub's order: by title, literally (no case folding), then by
    /// bundle identifier.
    nonisolated static func isOrdered(_ first: SimulatorApp, before second: SimulatorApp) -> Bool {
        first.title == second.title ? first.bundleIdentifier < second.bundleIdentifier : first.title < second.title
    }

    /// Reads `app`'s icon off the main thread, once per bundle path.
    func loadIcon(for app: SimulatorApp) async {
        guard let path = app.path, icons[path] == nil, !iconLoads.contains(path) else { return }
        iconLoads.insert(path)
        defer { iconLoads.remove(path) }
        let (data, template) = await Task.detached(priority: .utility) { () -> (Data?, Bool) in
            let bundleURL = URL(fileURLWithPath: path, isDirectory: true)
            guard let bundle = SimulatorAppBundle.read(app: bundleURL) else { return (nil, false) }
            guard let file = bundle.iconFile(in: bundleURL) else { return (nil, bundle.usesIconTemplateTile) }
            return (try? Data(contentsOf: file), false)
        }.value
        if template { templateTiles.insert(path) }
        icons[path] = .some(data.flatMap(NSImage.init(data:)))
    }

    // MARK: - App actions

    func launch(_ app: SimulatorApp, udid: String) async {
        guard let simctl = simulators.simctl else { return }
        do {
            try await simctl.launch(udid: udid, bundleIdentifier: app.bundleIdentifier)
            status.flash("Launched \(app.title)")
        } catch {
            status.errorMessage = "Unable to Launch App: \(Self.reason(error))"
        }
    }

    /// Launch with Options…: `simctl launch` with arguments, environment
    /// variables and the debugger / terminate flags. Returns whether it launched.
    @discardableResult
    func launch(_ app: SimulatorApp, udid: String, options: SimulatorLaunchOptions) async -> Bool {
        guard let simctl = simulators.simctl else { return false }
        do {
            try await simctl.launch(udid: udid, bundleIdentifier: app.bundleIdentifier, options: options)
            status.flash(options.waitForDebugger ? "Launched \(app.title), waiting for a debugger" : "Launched \(app.title)")
            return true
        } catch {
            status.errorMessage = "Unable to Launch App: \(Self.reason(error))"
            return false
        }
    }

    func terminate(_ app: SimulatorApp, udid: String) async {
        guard let simctl = simulators.simctl else { return }
        do {
            try await simctl.terminate(udid: udid, bundleIdentifier: app.bundleIdentifier)
            status.flash("Terminated \(app.title)")
        } catch let failure as SimctlFailure where failure.kind == .notFound {
            status.flash("\(app.title) is not running")
        } catch {
            status.errorMessage = "Could not terminate \(app.title): \(Self.reason(error))"
        }
    }

    /// Uninstalls after the user confirmed (after the operation in flight,
    /// if one is), then reads the list again.
    func uninstall(bundleIdentifier: String, name: String, udid: String) async {
        guard let simctl = simulators.simctl, await beginAfterCurrent(.uninstalling(name)) else { return }
        defer { activity = nil }
        do {
            try await simctl.uninstall(udid: udid, bundleIdentifier: bundleIdentifier)
            status.flash("Uninstalled \(name)")
            appsChanged(udid)
        } catch {
            status.errorMessage = "Failed to Uninstall App: \(Self.reason(error))"
        }
        await reloadIfShown(udid)
    }

    /// Shows the app's data container in the Finder (Device Hub's App Data
    /// Container ▸ Show in Finder): the one `listapps` named, else the one
    /// `get_app_container … data` prints.
    func showDataContainer(_ app: SimulatorApp, udid: String) async {
        if let container = app.dataContainer, container.isFileURL {
            revealInFinder(container)
            return
        }
        guard let simctl = simulators.simctl else { return }
        do {
            let path = try await simctl.appContainerPath(udid: udid, bundleIdentifier: app.bundleIdentifier, container: .data)
            revealInFinder(URL(fileURLWithPath: path, isDirectory: true))
        } catch {
            status.errorMessage = "Unable to Show App Data Container: \(Self.reason(error))"
        }
    }

    /// The app's data container on the Mac: the one `listapps` named, else
    /// the one `get_app_container … data` prints.
    private func dataContainerURL(_ app: SimulatorApp, udid: String) async -> URL? {
        if let container = app.dataContainer, container.isFileURL { return container }
        guard let simctl = simulators.simctl,
              let path = try? await simctl.appContainerPath(udid: udid, bundleIdentifier: app.bundleIdentifier, container: .data)
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// App Container ▸ Download…: copies the data container, as it is, into
    /// `folder` under the bundle identifier (Device Hub's: the folder is named
    /// `com.example.app`; a name that is taken gets a number).
    func downloadContainer(_ app: SimulatorApp, udid: String, to folder: URL) async {
        guard let source = await dataContainerURL(app, udid: udid) else {
            status.errorMessage = "Unable to Download App Container: \(app.title) has no data container."
            return
        }
        let progress = "Downloading the data of \(app.title)…"
        status.showProgress(progress)
        defer { status.clear(ifShowing: progress) }
        let bundleIdentifier = app.bundleIdentifier
        do {
            let copy = try await Task.detached(priority: .userInitiated) {
                try Self.copyContainer(source, to: folder, named: bundleIdentifier)
            }.value
            status.flash("Saved the data of \(app.title)")
            revealInFinder(copy)
        } catch {
            status.errorMessage = "Unable to Download App Container: \(Self.reason(error))"
        }
    }

    /// App Container ▸ Replace…: puts the contents of `source` (a folder, or an
    /// `.xcappdata` bundle, whose `AppData` folder is used) into the app's data
    /// container in place of what it holds. The app is stopped first.
    func replaceContainer(_ app: SimulatorApp, udid: String, with source: URL) async {
        guard let simctl = simulators.simctl, let container = await dataContainerURL(app, udid: udid) else {
            status.errorMessage = "Unable to Replace App Container: \(app.title) has no data container."
            return
        }
        let progress = "Replacing the data of \(app.title)…"
        status.showProgress(progress)
        defer { status.clear(ifShowing: progress) }
        // A running app holds its files: stop it (not running is fine).
        try? await simctl.terminate(udid: udid, bundleIdentifier: app.bundleIdentifier)
        do {
            try await Task.detached(priority: .userInitiated) {
                try Self.replaceContainerContents(container, with: source)
            }.value
            status.flash("Replaced the data of \(app.title)")
        } catch {
            status.errorMessage = "Unable to Replace App Container: \(Self.reason(error))"
        }
    }

    /// App Container ▸ Inspect Data…: the inspector for one app, nil when the
    /// simulator's tooling is not available.
    func makeDataInspector(for app: SimulatorApp, udid: String) -> SimulatorAppDataController? {
        guard let simctl = simulators.simctl else { return nil }
        return SimulatorAppDataController(
            app: app, udid: udid, simctl: simctl, status: status, temporaryDirectory: temporaryDirectory
        )
    }

    /// App Container ▸ Save App State…: stops the app, then zips its data
    /// container into `archive` (`AppDataStateArchive`), for a tester to go
    /// back to this state later.
    func saveAppState(_ app: SimulatorApp, udid: String, to archive: URL) async {
        guard let simctl = simulators.simctl, let container = await dataContainerURL(app, udid: udid) else {
            status.errorMessage = "Unable to Save App State: \(app.title) has no data container."
            return
        }
        guard begin(.savingState(app.title)) else { return }
        let progress = "Saving the state of \(app.title)…"
        status.showProgress(progress)
        defer {
            activity = nil
            status.clear(ifShowing: progress)
        }
        // A running app writes while it is zipped: stop it (not running is fine).
        try? await simctl.terminate(udid: udid, bundleIdentifier: app.bundleIdentifier)
        do {
            try await AppDataStateArchive.save(container: container, to: archive)
            status.flash("Saved the state of \(app.title)")
            revealInFinder(archive)
        } catch {
            status.errorMessage = "Unable to Save App State: \(Self.reason(error))"
        }
    }

    /// App Container ▸ Restore App State…: after the user confirmed, stops the
    /// app and puts the archive's files in its data container in place of what
    /// it holds (`AppDataStateArchive.restore`).
    func restoreAppState(_ app: SimulatorApp, udid: String, from archive: URL) async {
        guard let simctl = simulators.simctl, let container = await dataContainerURL(app, udid: udid) else {
            status.errorMessage = "Unable to Restore App State: \(app.title) has no data container."
            return
        }
        guard await beginAfterCurrent(.restoringState(app.title)) else { return }
        let progress = "Restoring the state of \(app.title)…"
        status.showProgress(progress)
        defer {
            activity = nil
            status.clear(ifShowing: progress)
        }
        try? await simctl.terminate(udid: udid, bundleIdentifier: app.bundleIdentifier)
        do {
            try await AppDataStateArchive.restore(archive: archive, into: container, stagingDirectory: temporaryDirectory)
            status.flash("Restored the state of \(app.title)")
        } catch {
            status.errorMessage = "Unable to Restore App State: \(Self.reason(error))"
        }
    }

    // MARK: - Sample data

    /// Device ▸ Add Sample Data ▸ Contacts: `count` fake contacts
    /// (`SimulatorSampleData`) as a `.vcf`, added with `simctl addmedia`.
    func addSampleContacts(count: Int, udid: String) async {
        await addSampleData(udid: udid, summary: "Added \(count) sample contacts") { folder in
            [try SimulatorSampleData.writeContacts(count: count, to: folder)]
        }
    }

    /// Device ▸ Add Sample Data ▸ Photos: `count` numbered placeholder pictures.
    func addSamplePhotos(count: Int, udid: String) async {
        await addSampleData(udid: udid, summary: "Added \(count) sample photos") { folder in
            try SimulatorSampleData.writePhotos(count: count, to: folder)
        }
    }

    private func addSampleData(
        udid: String,
        summary: String,
        make: @escaping @Sendable (URL) throws -> [URL]
    ) async {
        let folder = temporaryDirectory.appendingPathComponent("DeviceHubPro-sample-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            let files = try await Task.detached(priority: .userInitiated) { try make(folder) }.value
            let before = status.errorMessage
            await addMedia(files, udid: udid)
            if status.errorMessage == before { status.flash(summary) }
        } catch {
            status.errorMessage = "Unable to Add Sample Data: \(Self.reason(error))"
        }
    }

    /// Copies `container` into `folder/<name>` (`name 2`, `name 3`… when taken)
    /// and returns the copy.
    nonisolated static func copyContainer(_ container: URL, to folder: URL, named name: String) throws -> URL {
        let manager = FileManager.default
        var destination = folder.appendingPathComponent(name, isDirectory: true)
        var number = 2
        while manager.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(name) \(number)", isDirectory: true)
            number += 1
        }
        try manager.copyItem(at: container, to: destination)
        return destination
    }

    /// Empties `container` (its container-manager metadata stays) and copies
    /// `source`'s items in; an `.xcappdata` bundle contributes its `AppData`.
    nonisolated static func replaceContainerContents(_ container: URL, with source: URL) throws {
        let manager = FileManager.default
        var origin = source
        if source.pathExtension.lowercased() == "xcappdata" {
            let appData = source.appendingPathComponent("AppData", isDirectory: true)
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: appData.path, isDirectory: &isDirectory), isDirectory.boolValue {
                origin = appData
            }
        }
        let metadata = ".com.apple.mobile_container_manager.metadata.plist"
        let incoming = try manager.contentsOfDirectory(at: origin, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != metadata }
        for item in try manager.contentsOfDirectory(at: container, includingPropertiesForKeys: nil)
        where item.lastPathComponent != metadata {
            try manager.removeItem(at: item)
        }
        for item in incoming {
            try manager.copyItem(at: item, to: container.appendingPathComponent(item.lastPathComponent))
        }
    }

    // MARK: - Installing

    /// Installs a `.app`, or the app in an `.ipa` or `.zip`, on `udid`, after
    /// checking it is a simulator build for the simulator's platform. Returns
    /// whether it was installed.
    @discardableResult
    func install(_ url: URL, udid: String) async -> Bool {
        guard let simctl = simulators.simctl else { return false }
        let isArchive = ["ipa", "zip"].contains(url.pathExtension.lowercased())
        guard isArchive || url.pathExtension.lowercased() == "app" else {
            status.errorMessage = "“\(url.lastPathComponent)” is not an app (.app, .ipa or .zip)."
            return false
        }
        guard begin(.installing(url.deletingPathExtension().lastPathComponent)) else { return false }
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
        if isArchive {
            let folder = temporaryDirectory.appendingPathComponent("DeviceHubPro-install-\(UUID().uuidString)", isDirectory: true)
            unpacked = folder
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                app = try await SimulatorAppArchive.extract(url, into: folder)
            } catch {
                status.errorMessage = "Failed to Install App: \(Self.reason(error))"
                return false
            }
        }
        let bundle = SimulatorAppBundle.read(app: app)
        if let problem = bundle?.installProblem(runtimePlatform: simulators.entry(udid: udid)?.platform) {
            status.errorMessage = "Failed to Install App: \(problem)"
            return false
        }
        do {
            try await simctl.install(udid: udid, app: app)
        } catch {
            status.errorMessage = "Failed to Install App: \(Self.reason(error))"
            return false
        }
        let name = bundle?.title ?? app.deletingPathExtension().lastPathComponent
        recents.record(url: url, package: bundle?.bundleIdentifier, version: bundle?.shortVersion, name: name)
        status.flash("Installed \(name)")
        appsChanged(udid)
        await reloadIfShown(udid)
        return true
    }

    /// Apply to Selected's Install Build on one simulator of several: the
    /// checks and steps of `install(_:udid:)` without its one-operation slot
    /// (the batch installs on simulators side by side) and its status line.
    /// A build the simulator cannot run throws `BatchSkip`; a failed install
    /// throws its error.
    func installForBatch(_ url: URL, udid: String) async throws {
        guard let simctl = simulators.simctl else {
            throw BatchPerformerError("Xcode's simulator tools were not found.")
        }
        let isArchive = ["ipa", "zip"].contains(url.pathExtension.lowercased())
        guard isArchive || url.pathExtension.lowercased() == "app" else {
            throw BatchSkip("“\(url.lastPathComponent)” is not an app (.app, .ipa or .zip)")
        }
        var unpacked: URL?
        defer {
            if let unpacked {
                // Best effort: a leftover temporary folder is harmless.
                try? FileManager.default.removeItem(at: unpacked)
            }
        }
        var app = url
        if isArchive {
            let folder = temporaryDirectory.appendingPathComponent("DeviceHubPro-install-\(UUID().uuidString)", isDirectory: true)
            unpacked = folder
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            app = try await SimulatorAppArchive.extract(url, into: folder)
        }
        let bundle = SimulatorAppBundle.read(app: app)
        if let problem = bundle?.installProblem(runtimePlatform: simulators.entry(udid: udid)?.platform) {
            throw BatchSkip(problem)
        }
        try await simctl.install(udid: udid, app: app)
        let name = bundle?.title ?? app.deletingPathExtension().lastPathComponent
        recents.record(url: url, package: bundle?.bundleIdentifier, version: bundle?.shortVersion, name: name)
        appsChanged(udid)
        await reloadIfShown(udid)
    }

    // MARK: - Drops

    /// The files and links a drag carried, in its order: each item read as
    /// a URL (a Finder file is a file URL, a link dragged from a browser a
    /// web URL); items that are neither are skipped.
    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            let url: URL? = await withCheckedContinuation { continuation in
                guard provider.canLoadObject(ofClass: NSURL.self) else {
                    return continuation.resume(returning: nil)
                }
                _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                    continuation.resume(returning: object as? URL)
                }
            }
            if let url { urls.append(url) }
        }
        return urls
    }

    /// Handles what was dropped on `udid`'s stage (`SimulatorDropRouting`).
    /// Its certificates go to `confirmCertificates` first, all in one call
    /// (trusting a root is asked, and the user can answer while the rest
    /// runs); the rest runs at once, one drop after another in the order
    /// they came.
    func handleDrop(
        _ urls: [URL],
        udid: String,
        confirmCertificates: @MainActor (_ certificates: [URL]) -> Void
    ) async {
        let drops = SimulatorDropRouting.route(urls)
        var certificates: [URL] = []
        for drop in drops {
            switch drop {
            case .addRootCertificate(let certificate):
                certificates.append(certificate)
            case .addProfile(let profile):
                certificates += await stageCertificates(inProfile: profile)
            default:
                break
            }
        }
        if !certificates.isEmpty { confirmCertificates(certificates) }
        for drop in drops {
            switch drop {
            case .installApp(let url), .installArchive(let url):
                await install(url, udid: udid)
            case .addMedia(let files):
                await addMedia(files, udid: udid)
            case .addRootCertificate, .addProfile:
                continue
            case .openURL(let url):
                await openURL(url, udid: udid)
            case .unsupported(_, let reason):
                status.errorMessage = reason
            }
        }
    }

    /// The prefix of the temporary folders a profile's certificates are written to.
    static let profileCertificatesPrefix = "devicehubpro-profile-certs-"

    /// The certificates in a dropped `.mobileconfig`, written to files in a
    /// temporary folder (removed once they are trusted, `trustRootCertificates`)
    /// so the one trust question and `add-root-cert` take them like dropped
    /// certificates. simctl cannot install a profile itself. A profile that
    /// cannot be read, or holds no certificate, raises its reason.
    private func stageCertificates(inProfile profile: URL) async -> [URL] {
        do {
            let parsed = try await ConfigurationProfile.read(profile)
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent(Self.profileCertificatesPrefix + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return try parsed.writeCertificates(into: folder, profileName: profile.lastPathComponent)
        } catch {
            if !error.isCancellation { status.errorMessage = "\(error)" }
            return []
        }
    }

    /// Removes the temporary folders `stageCertificates(inProfile:)` made.
    private static func removeStagedCertificates(_ certificates: [URL]) {
        for certificate in certificates {
            let folder = certificate.deletingLastPathComponent()
            if folder.lastPathComponent.hasPrefix(profileCertificatesPrefix) {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    /// Imports photos, videos and contact cards (`simctl addmedia`).
    func addMedia(_ files: [URL], udid: String) async {
        guard let simctl = simulators.simctl, begin(.importingMedia) else { return }
        let progress = files.count == 1 ? "Adding \(files[0].lastPathComponent)…" : "Adding \(files.count) items…"
        status.showProgress(progress)
        defer {
            activity = nil
            status.clear(ifShowing: progress)
        }
        do {
            try await simctl.addMedia(udid: udid, files: files)
            status.flash(files.count == 1 ? "Added \(files[0].lastPathComponent) to Photos" : "Added \(files.count) items")
        } catch let failure as SimctlFailure
            where failure.error?.code == 133 && failure.leadingLines.contains(where: { $0.hasPrefix("Failed to import") }) {
            // 133 alone is also what a simulator that stopped answers; only
            // a file simctl names was refused for its type.
            status.errorMessage = "The simulator could not import \(Self.names(files)): it takes photos, videos and contact cards."
        } catch {
            status.errorMessage = "Could not add \(Self.names(files)): \(Self.reason(error))"
        }
    }

    /// What the last keychain reset said, for the Keychain row's caption (the
    /// status line flashes it too).
    private(set) var dataNote: String?

    /// Removes the keychain items from the simulator (`simctl keychain reset`)
    /// after the user confirmed.
    func resetKeychain(udid: String) async {
        guard let simctl = simulators.simctl, await beginAfterCurrent(.resettingKeychain) else { return }
        defer { activity = nil }
        do {
            try await simctl.resetKeychain(udid: udid)
            dataNote = "Keychain reset at \(Date().formatted(date: .omitted, time: .standard))."
            status.flash("Keychain reset")
        } catch {
            dataNote = nil
            status.errorMessage = "Could not reset the keychain: \(Self.reason(error))"
        }
    }

    /// Trusts a drop's root certificates, in order, after the user
    /// confirmed: after the operation in flight (the drop's install, say)
    /// finishes rather than refused. A certificate simctl refuses does not
    /// stop the others; the first refusal is the one shown.
    func trustRootCertificates(_ certificates: [URL], udid: String) async {
        guard !certificates.isEmpty, let simctl = simulators.simctl,
              await beginAfterCurrent(.trustingCertificate)
        else {
            Self.removeStagedCertificates(certificates)
            return
        }
        defer {
            activity = nil
            Self.removeStagedCertificates(certificates)
        }
        var trusted: [URL] = []
        var problem: String?
        for certificate in certificates {
            do {
                try await simctl.addRootCertificate(udid: udid, certificate: certificate)
                trusted.append(certificate)
            } catch let failure as SimctlFailure where failure.kind == .invalidArgument {
                problem = problem ?? "“\(certificate.lastPathComponent)” is not a PEM or DER certificate."
            } catch {
                problem = problem ?? "Could not add \(certificate.lastPathComponent): \(Self.reason(error))"
            }
        }
        if let problem {
            status.errorMessage = problem
        } else {
            status.flash(trusted.count == 1 ? "Trusted \(trusted[0].lastPathComponent)" : "Trusted \(trusted.count) certificates")
        }
    }

    /// Opens typed text as a link (the Device menu's Open URL… sheet): text
    /// that is no link never reaches simctl (`SimctlClient.readLink`), and the
    /// alert says why: no scheme, a host file, or text with a scheme that
    /// reads as no URL (the unreadable-URL alert simctl's −50 gets). The user
    /// asked for it in the sheet, so like a confirmed trust it runs once the
    /// operation in flight on any simulator (an install, a media import)
    /// finishes, never refused: the sheet has closed by then. Returns
    /// whether it opened.
    @discardableResult
    func openURL(_ text: String, udid: String) async -> Bool {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch SimctlClient.readLink(typed) {
        case .success(let url):
            return await openLink(url, shownAs: typed, udid: udid, afterCurrent: true)
        case .failure(.noScheme):
            status.errorMessage = "\(typed) is not a URL: it needs a scheme, such as https: or myapp:."
        case .failure(.hostFile):
            status.errorMessage = "\(typed) is a file on the Mac: a simulator opens links, not files."
        case .failure(.unreadable):
            status.errorMessage = Self.unreadableURL(typed)
        }
        return false
    }

    /// Opens a link in the simulator (`simctl openurl`): a dropped one,
    /// refused with a word while another operation runs, as every drop is.
    /// Returns whether it opened.
    @discardableResult
    func openURL(_ url: URL, udid: String) async -> Bool {
        await openLink(url, shownAs: url.absoluteString, udid: udid, afterCurrent: false)
    }

    /// The one path for a drop's link and the sheet's: a link that opened
    /// joins the recent links, as the user typed it (`recordRecentURL`), and
    /// is flashed; a failure is raised in the alert, in words for the two
    /// answers simctl was measured to give (`openURLFailure`). Like every
    /// operation here it takes the one slot: `afterCurrent` waits for the
    /// one in flight (`beginAfterCurrent`), otherwise it is refused with a
    /// word (`begin`).
    private func openLink(_ url: URL, shownAs shown: String, udid: String, afterCurrent: Bool) async -> Bool {
        guard let simctl = simulators.simctl else { return false }
        let claimed = if afterCurrent { await beginAfterCurrent(.openingLink) } else { begin(.openingLink) }
        guard claimed else { return false }
        defer { activity = nil }
        do {
            try await simctl.openURL(udid: udid, url: url)
        } catch {
            status.errorMessage = Self.openURLFailure(shown, scheme: url.scheme, error)
            return false
        }
        recordRecentURL(shown)
        status.flash("Opened \(shown)")
        return true
    }

    /// The alert for a link the simulator did not open: a scheme no app
    /// handles (115), text simctl could not read as a URL (−50,
    /// `unreadableURL`), a link refused before simctl ran, or simctl's own
    /// line.
    static func openURLFailure(_ shown: String, scheme: String?, _ error: any Error) -> String {
        if let failure = error as? SimctlFailure {
            switch failure.error {
            case SimctlErrorReference(domain: "LSApplicationWorkspaceErrorDomain", code: 115)?:
                return "No app on the simulator opens \(scheme.map { "\($0):" } ?? "these") links."
            case SimctlErrorReference(domain: "NSOSStatusErrorDomain", code: -50)?:
                return unreadableURL(shown)
            default:
                return "Could not open \(shown): \(failure.message)"
            }
        }
        if case SimctlClientError.invalidValue? = error as? SimctlClientError {
            return "\(shown) is not a URL: it needs a scheme, such as https: or myapp:."
        }
        return "Could not open \(shown): \(error)"
    }

    /// The alert for text that reads as no URL, whether simctl said so
    /// (−50) or `SimctlClient.readLink` did before simctl ran.
    static func unreadableURL(_ shown: String) -> String {
        "\(shown) cannot be read as a URL."
    }

    // MARK: - Internals

    /// Claims the one operation slot; a second operation is refused with a
    /// word rather than silently.
    private func begin(_ next: Activity) -> Bool {
        guard activity == nil else {
            status.flash("Wait for the current simulator operation to finish")
            return false
        }
        activity = next
        return true
    }

    /// Claims the slot for an operation the user already confirmed: once
    /// the one in flight finishes, never refused (a cancelled wait claims
    /// nothing).
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
        guard appsUDID == udid else { return }
        await load(udid: udid)
    }

    /// Follows `<device data>/Containers/Bundle/Application`, where every
    /// installed app gets a folder: a change there (Xcode or Device Hub
    /// installed or removed one) reads the list again. CoreSimulator makes
    /// that folder with the first app a user installs (28 of 29 simulators
    /// on the Mac this was measured on had none), so until it exists the
    /// deepest folder of the path that does is followed, and each change
    /// there moves the watch down (`installedAppsFolderChanged`).
    private func watchInstalledApps(of udid: String, rearm: Bool = false) {
        guard let dataPath = simulators.entry(udid: udid)?.dataPath else { return stopWatching() }
        let data = URL(fileURLWithPath: dataPath, isDirectory: true)
        // A folder can appear between finding the deepest one and opening
        // it: look again after each open (the path has three levels).
        var rearm = rearm
        for _ in 0..<4 {
            guard let folder = Self.deepestExistingFolder(of: Self.installedAppsPath, in: data) else { return stopWatching() }
            if folder == watchedFolder, !rearm { return }
            rearm = false
            stopWatching()
            let descriptor = open(folder, O_EVTONLY)
            guard descriptor >= 0 else { return }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main)
            source.setEventHandler { [weak self, weak source] in
                let events = source?.data ?? []
                MainActor.assumeIsolated { self?.installedAppsFolderChanged(udid, events: events) }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watcher = source
            watchedFolder = folder
        }
    }

    /// Where a simulator keeps its installed apps, under its data folder.
    static let installedAppsPath = ["Containers", "Bundle", "Application"]

    /// The deepest existing folder of `components` under `root` (`root`
    /// itself when none exists yet); nil when `root` is missing too.
    static func deepestExistingFolder(of components: [String], in root: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        var deepest = root
        for component in components {
            let next = deepest.appendingPathComponent(component, isDirectory: true)
            guard FileManager.default.fileExists(atPath: next.path, isDirectory: &isDirectory), isDirectory.boolValue else { break }
            deepest = next
        }
        return deepest.path
    }

    /// The followed folder changed: follow the deepest one again (a new
    /// folder, or the followed one removed or renamed), and read the list
    /// again once the changes settle.
    private func installedAppsFolderChanged(_ udid: String, events: DispatchSource.FileSystemEvent) {
        guard appsUDID == udid else { return }
        watchInstalledApps(of: udid, rearm: !events.isDisjoint(with: [.delete, .rename]))
        installedAppsChanged(udid)
    }

    private func installedAppsChanged(_ udid: String) {
        pendingReload?.cancel()
        pendingReload = Task { [weak self] in
            guard let delay = self?.changeDebounce else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.appsUDID == udid, self.activity == nil else { return }
            await self.load(udid: udid)
        }
    }

    private func stopWatching() {
        pendingReload?.cancel()
        pendingReload = nil
        watcher?.cancel()
        watcher = nil
        watchedFolder = nil
    }

    private static func names(_ files: [URL]) -> String {
        files.count == 1 ? "“\(files[0].lastPathComponent)”" : "\(files.count) items"
    }

    /// A failure in the user's words: simctl's own line when it printed one.
    static func reason(_ error: Error) -> String {
        if let failure = error as? SimctlFailure { return failure.message }
        return "\(error)"
    }
}
