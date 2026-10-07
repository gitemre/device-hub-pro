import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import DeviceHubProKit

/// The inspector's Apps tab and APK install: the device's installed packages
/// with the tab's scope and filter, the app actions, and installs with their
/// recents.
///
/// Each `DeviceWorkspace` owns one as `apps`, which the views read
/// directly. It holds no reference to the
/// model: the serials it targets and the package-set change it reports go
/// through the hooks below, which the model sets once it is built.
@MainActor
@Observable
final class AppsController {
    /// Apps-tab scope filter, Device Hub's scope popup (§7.4). Default
    /// `all`, as Device Hub's: a fresh emulator has no user apps, and a tab
    /// that opens on "No Apps" reads as broken.
    enum AppsScope: Hashable {
        case all
        case user
        case system

        var label: String {
            switch self {
            case .all: "All Apps"
            case .user: "User Apps"
            case .system: "System Apps"
            }
        }

        /// What the list says when the scope (with no text filter) lists
        /// nothing.
        var emptyLabel: String {
            switch self {
            case .all: "No Apps"
            case .user: "No user-installed apps"
            case .system: "No system apps"
            }
        }
    }

    /// Every package on `appsSerial`; the Apps tab's scope (below) and Filter
    /// field are applied client-side in `filteredApps`.
    var installedAppList: [AdbClient.InstalledPackage] = []
    var appsFilter = ""
    /// The Apps tab's scope popup (§7.4); All Apps by default.
    var appsScope: AppsScope = .all
    /// IDs the `-3` (third-party) list reported for `installedAppList`'s
    /// serial. `pm`'s `-3` and `-s` filters partition its unflagged output,
    /// so the complement of this set is the system set — no per-scope adb
    /// query and no refetch on a scope switch.
    private var userAppIDs: Set<String> = []

    /// Whether the `-3` list reported `id` (a user app) for `appsSerial`.
    func isUserApp(_ id: String) -> Bool { userAppIDs.contains(id) }
    var appsSerial: String?
    var isLoadingApps = false
    /// The load found the device still booting (its package manager not up
    /// yet) and waits for `sys.boot_completed` before listing again; the
    /// tab keeps its loading state and raises no alert meanwhile.
    private(set) var isWaitingForBoot = false
    /// The boot wait's clock: `EmulatorBootController`'s, so a test that
    /// shortens `boot.bootTiming` sets this one too.
    @ObservationIgnored var bootTiming = EmulatorBootController.BootTiming()
    /// How many times one load waits out a booting device before its error
    /// shows anyway.
    static let bootWaitLimit = 3
    /// True while `installAPK` runs: the Apps footer shows its inline
    /// "Installing…" state and the install popover disables its actions.
    private(set) var isInstallingAPK = false

    /// The install popover's recents (spec §7.2). Owned here so an install
    /// triggered anywhere — the picker, the popover or a drop onto the mirror
    /// — lands in the same list; recording happens only after `adb install`
    /// reports success.
    let recentAPKs: RecentAPKStore

    private let adbClient: AdbClient?
    private let status: StatusCenter
    /// Where the copy actions put their text.
    private let pasteboard: any MacPasteboard

    /// The device the inspector shows (`AppModel.inspectorSerial`): the app
    /// actions target it first. Nil until its owner sets it.
    @ObservationIgnored var inspectorSerialSource: @MainActor () -> String? = { nil }
    /// The mirrored device: the app actions' target when the inspector shows
    /// none, and an install's when the caller names none.
    @ObservationIgnored var activeSerialSource: @MainActor () -> String? = { nil }
    /// Told the serial of a device whose package set an install or an
    /// uninstall just changed.
    @ObservationIgnored var packagesChanged: @MainActor (_ serial: String) -> Void = { _ in }

    init(
        adbClient: AdbClient?,
        status: StatusCenter,
        recentAPKs: RecentAPKStore,
        pasteboard: any MacPasteboard
    ) {
        self.adbClient = adbClient
        self.status = status
        self.recentAPKs = recentAPKs
        self.pasteboard = pasteboard
    }

    /// Whether `url` is something `adb install` can take: one APK, a
    /// bundletool `.apks` set, or a folder of split APKs (the Kit resolves
    /// the folder's and the set's contents and says what is wrong with them).
    static func isInstallablePackage(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "apk", "apks":
            return true
        default:
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    /// The install picker's panel: APKs, `.apks` sets and folders of split
    /// APKs, the same set the mirror's drop target takes.
    static func makeInstallPackagePanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose an APK, an .apks set or a folder of split APKs to install"
        panel.allowedContentTypes = ["apk", "apks"].compactMap { UTType(filenameExtension: $0) }
        return panel
    }

    /// Installs an APK (or an `.apks` set, or a folder of split APKs) dropped
    /// onto the mirror (drag & drop from Finder), or onto the device the Apps
    /// tab is inspecting when `serial` is given — the footer's `+` must
    /// target the listed device, which can differ from the mirrored one.
    func installAPK(at url: URL, serial targetSerial: String? = nil) async {
        guard let adbClient, let serial = targetSerial ?? activeSerial else {
            errorMessage = "Connect a device before installing an APK."
            return
        }
        guard Self.isInstallablePackage(url) else {
            errorMessage = "\(url.lastPathComponent) is not an APK, an .apks set or a folder of split APKs."
            return
        }

        let installing = "Installing \(url.lastPathComponent)…"
        var shownStatus: String? = installing
        beginBusy()
        isInstallingAPK = true
        status.showProgress(installing)
        defer {
            endBusy()
            isInstallingAPK = false
            clearStatus(ifShowing: shownStatus)
        }

        do {
            try await adbClient.install(serial: serial, apkURL: url)
            // The inline "Installing…" state ends with the command; the
            // success flash below is the result feedback.
            isInstallingAPK = false
            await recordRecentInstall(at: url)
            // The package set changed: the Controls poll re-reads TalkBack.
            packagesChanged(serial)
            // A successful install must show up without a manual reload when
            // the Apps tab is already listing this device.
            if appsSerial == serial {
                await loadApps(serial: serial)
            }
            let installed = "\(url.lastPathComponent) installed"
            status.showOutcome(installed)
            shownStatus = installed
            // Best effort: the sleep only keeps the result on screen.
            try? await Task.sleep(for: .seconds(2))
        } catch {
            isInstallingAPK = false
            if !error.isCancellation { errorMessage = "\(error)" }
        }
    }

    /// Recents update only on success (spec §7.2). The badging read is best
    /// effort: without a usable aapt2 the entry still records its path and the
    /// popover falls back to the filename.
    private func recordRecentInstall(at url: URL) async {
        let metadata = (try? await ApkIconExtractor.metadata(forAPKAt: url)) ?? ApkMetadata()
        recentAPKs.record(
            url: url,
            package: metadata.package,
            version: metadata.versionCode ?? metadata.versionName,
            name: metadata.label
        )
    }

    /// Packages on `serial` for the inspector Apps tab.
    ///
    /// One adb pair per load (§7.4): the unflagged list drives every scope,
    /// the `-3` list marks which of its packages are user apps. A scope
    /// switch then never refetches and the Filter field composes with the
    /// scope over the same loaded list.
    ///
    /// Only the newest load applies its result. A load that was cancelled —
    /// the Apps tab closed, another device selected — leaves nothing behind:
    /// no alert, and no `appsSerial`, so returning to the tab loads again.
    ///
    /// A device adb lists while Android still boots has no package manager
    /// yet (`cmd: Can't find service: package`): such a failure, or any
    /// failure while `sys.boot_completed` is not 1, is not an error. The load
    /// keeps its loading state, waits for the boot to complete (the same
    /// property Start waits on) and lists again.
    func loadApps(serial: String) async {
        guard let adbClient else { return }
        appsLoadGeneration &+= 1
        let generation = appsLoadGeneration
        isLoadingApps = true
        defer {
            if generation == appsLoadGeneration {
                isLoadingApps = false
                isWaitingForBoot = false
            }
        }
        var bootWaits = 0
        while true {
            do {
                let all = try await adbClient.listPackagesDetailed(
                    serial: serial,
                    includeSystem: true
                )
                let user = try await adbClient.listPackagesDetailed(serial: serial)
                guard generation == appsLoadGeneration, !Task.isCancelled else { return }
                installedAppList = all
                userAppIDs = Set(user.map(\.id))
                appsSerial = serial
                return
            } catch {
                guard generation == appsLoadGeneration,
                      !Task.isCancelled,
                      !(error is CancellationError)
                else { return }
                if bootWaits < Self.bootWaitLimit,
                   await Self.isStillBooting(serial: serial, after: error, adbClient: adbClient) {
                    bootWaits += 1
                    guard generation == appsLoadGeneration, !Task.isCancelled else { return }
                    if appsSerial != serial {
                        // Another device's list must not show under this one.
                        installedAppList = []
                        userAppIDs = []
                    }
                    isWaitingForBoot = true
                    guard await waitForBoot(serial: serial, generation: generation, adbClient: adbClient) else {
                        return
                    }
                    continue
                }
                guard generation == appsLoadGeneration, !Task.isCancelled else { return }
                installedAppList = []
                userAppIDs = []
                appsSerial = serial
                if !error.isCancellation { errorMessage = "\(error)" }
                return
            }
        }
    }

    /// Whether a listing failed because `serial` is still booting: its
    /// package manager is missing, or Android does not report the boot
    /// complete. A device whose properties cannot be read is not booting,
    /// it is failing, and its error shows.
    private static func isStillBooting(serial: String, after error: any Error, adbClient: AdbClient) async -> Bool {
        if let adbError = error as? AdbError, adbError.isPackageServiceMissing { return true }
        return (try? await adbClient.isBootCompleted(serial: serial)) == false
    }

    /// Polls `sys.boot_completed` every `bootTiming.poll` until it is 1 or
    /// `bootTiming.bootTimeout` passes (the load then lists once more and
    /// shows what that says). False when the load was cancelled or a newer
    /// one started meanwhile.
    private func waitForBoot(serial: String, generation: UInt64, adbClient: AdbClient) async -> Bool {
        let deadline = ContinuousClock.now + bootTiming.bootTimeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: bootTiming.poll)
            guard generation == appsLoadGeneration, !Task.isCancelled else { return false }
            if (try? await adbClient.isBootCompleted(serial: serial)) == true { break }
        }
        return generation == appsLoadGeneration && !Task.isCancelled
    }

    /// Bumped by every Apps load; see `loadApps(serial:)`.
    private var appsLoadGeneration: UInt64 = 0

    /// Apps filtered by the Apps-tab scope popup and Filter field.
    var filteredApps: [AdbClient.InstalledPackage] {
        let query = appsFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = installedAppList.filter { app in
            switch appsScope {
            case .all:
                // Runtime resource overlays are packages, not apps: a fresh
                // emulator's All Apps opened on a screenful of
                // "Auto_generated_rro_…". System Apps and a search keep them.
                guard query.isEmpty == false || !Self.isResourceOverlay(app.id) else { return false }
            case .user:
                guard userAppIDs.contains(app.id) else { return false }
            case .system:
                guard !userAppIDs.contains(app.id) else { return false }
            }
            return query.isEmpty || app.id.localizedCaseInsensitiveContains(query)
        }
        return Self.userAppsFirst(matching, userIDs: userAppIDs)
    }

    /// The SDK's generated runtime resource overlays (`…auto_generated_rro_product__`,
    /// `…_vendor__`, `android.auto_generated_characteristics_rro`), listed by
    /// `pm list packages` beside the apps.
    static func isResourceOverlay(_ id: String) -> Bool {
        id.contains("auto_generated") && id.contains("rro")
    }

    /// User-installed apps first, then system packages, each alphabetical.
    static func userAppsFirst(
        _ apps: [AdbClient.InstalledPackage],
        userIDs: Set<String>
    ) -> [AdbClient.InstalledPackage] {
        apps.sorted { a, b in
            let au = userIDs.contains(a.id), bu = userIDs.contains(b.id)
            if au != bu { return au }
            return a.id.localizedCaseInsensitiveCompare(b.id) == .orderedAscending
        }
    }

    /// The selection after the visible apps change: a package that is no
    /// longer listed — uninstalled, or hidden by a scope change — must be
    /// dropped so the footer `−` can never act on an invisible row.
    static func prunedSelection(
        _ selection: String?,
        visiblePackageIDs: Set<String>
    ) -> String? {
        guard let selection, visiblePackageIDs.contains(selection) else { return nil }
        return selection
    }

    func launchApp(package: String) async {
        guard let adbClient, let serial = inspectorSerial ?? activeSerial else { return }
        beginBusy()
        status.showProgress("Launching \(package)…")
        defer { endBusy() }
        do {
            try await adbClient.launchApp(serial: serial, package: package)
            flashStatus("Launched \(package)")
        } catch {
            statusMessage = nil
            if !error.isCancellation { errorMessage = "\(error)" }
        }
    }

    func uninstallApp(package: String) async {
        guard let adbClient, let serial = inspectorSerial ?? activeSerial else { return }
        beginBusy()
        status.showProgress("Uninstalling \(package)…")
        defer { endBusy() }
        do {
            try await adbClient.uninstallApp(serial: serial, package: package)
            installedAppList.removeAll { $0.id == package }
            // The package set changed: the Controls poll re-reads TalkBack.
            packagesChanged(serial)
            flashStatus("Uninstalled \(package)")
        } catch {
            statusMessage = nil
            if !error.isCancellation { errorMessage = "\(error)" }
        }
    }

    /// Force-stops `package`; deliberately confirmed only by the UI's click.
    func forceStopApp(package: String) async {
        guard let adbClient, let serial = inspectorSerial ?? activeSerial else { return }
        beginBusy()
        status.showProgress("Force stopping \(package)…")
        defer { endBusy() }
        do {
            try await adbClient.forceStop(serial: serial, package: package)
            flashStatus("Stopped \(package)")
        } catch {
            statusMessage = nil
            if !error.isCancellation { errorMessage = "\(error)" }
        }
    }

    /// Clears `package`'s on-device data (`pm clear`) after the UI's
    /// confirmation alert.
    func clearAppData(package: String) async {
        guard let adbClient, let serial = inspectorSerial ?? activeSerial else { return }
        beginBusy()
        status.showProgress("Clearing data for \(package)…")
        defer { endBusy() }
        do {
            try await adbClient.clearData(serial: serial, package: package)
            flashStatus("Cleared data for \(package)")
        } catch {
            statusMessage = nil
            if !error.isCancellation { errorMessage = "\(error)" }
        }
    }

    /// Opens the device's Application Info screen for `package`.
    func openAppInfo(package: String) async {
        guard let adbClient, let serial = inspectorSerial ?? activeSerial else { return }
        do {
            try await adbClient.openAppInfo(serial: serial, package: package)
        } catch {
            if !error.isCancellation { errorMessage = "\(error)" }
        }
    }

    func copyAppPackageName(_ package: String) {
        copyToPasteboard(package, status: "Copied package name")
    }

    func copyAppVersion(package: String) {
        guard let version = installedAppList.first(where: { $0.id == package })?.versionCode,
              !version.isEmpty
        else {
            errorMessage = "No version reported for \(package)."
            return
        }
        copyToPasteboard(version, status: "Copied version \(version)")
    }

    func copyAppDataPath(_ package: String) {
        copyToPasteboard(
            AdbClient.dataPath(package: package),
            status: "Copied data path"
        )
    }

    private func copyToPasteboard(_ text: String, status: String) {
        pasteboard.setString(text)
        flashStatus(status)
    }

    // MARK: - Shims

    // Its owner's serials and `StatusCenter` under the names the moved call
    // sites use, so their text is unchanged.

    private var inspectorSerial: String? { inspectorSerialSource() }

    private var activeSerial: String? { activeSerialSource() }

    private var errorMessage: String? {
        get { status.errorMessage }
        set { status.errorMessage = newValue }
    }

    /// Like `AppModel.statusMessage`: a text shows as an outcome, nil clears
    /// the line.
    private var statusMessage: String? {
        get { status.statusMessage }
        set {
            if let newValue {
                status.showOutcome(newValue)
            } else {
                status.clear()
            }
        }
    }

    private func flashStatus(_ message: String) {
        status.flash(message)
    }

    private func beginBusy() {
        status.beginBusy()
    }

    private func endBusy() {
        status.endBusy()
    }

    private func clearStatus(ifShowing message: String?) {
        status.clear(ifShowing: message)
    }
}
