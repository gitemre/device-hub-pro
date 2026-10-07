import AppKit
import Foundation
import Observation
import SwiftUI
import DeviceHubProKit

/// Where Device Hub is on this Mac. Its CarPlay Simulator is built in (there
/// is no separate app in Xcode's bundle), so the physical iPhone's "CarPlay
/// Simulator" item opens Device Hub: found by bundle identifier, else at its
/// place in Xcode. Nil when it is not installed (the item is then disabled).
enum DeviceHubLocator {
    static let bundleIdentifier = "com.apple.dt.DeviceHub"
    static let xcodePath = "/Applications/Xcode.app/Contents/Applications/DeviceHub.app"

    static func locate(
        applicationURL: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL? {
        if let url = applicationURL(bundleIdentifier) { return url }
        let xcode = URL(fileURLWithPath: xcodePath)
        return exists(xcode) ? xcode : nil
    }
}

/// The folder "Show in Finder" opens for a physical iPhone. Device Hub shows
/// the device in Finder's sidebar; no public API reveals that location, so
/// the nearest real folder is used: the one macOS keeps the device's own
/// synced crash reports in (`~/Library/Logs/CrashReporter/MobileDevice/<name>`),
/// else the parent of those, else the device backups folder. Nil when none
/// exists (the item then only brings Finder forward).
enum PhysicalDeviceFolder {
    static func candidates(deviceName: String, home: URL) -> [URL] {
        let library = home.appendingPathComponent("Library")
        let mobileDevice = library.appendingPathComponent("Logs/CrashReporter/MobileDevice")
        return [
            mobileDevice.appendingPathComponent(deviceName, isDirectory: true),
            mobileDevice,
            library.appendingPathComponent("Application Support/MobileSync/Backup"),
        ]
    }

    static func locate(
        deviceName: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL? {
        // A name with a slash is no folder name.
        let safeName = deviceName.replacingOccurrences(of: "/", with: "-")
        return candidates(deviceName: safeName, home: home).first(where: exists)
    }
}

/// The right-click menu's actions for a physical device row beyond the ones
/// the stage has (Device Hub's Restart, Rename…,
/// Collect sysdiagnose… and Unpair… for a physical iPhone, and the Android
/// phone's Restart, Collect Bug Report… and Disconnect…).
///
/// Every Apple call goes through `ApplePhysicalInventory.client(for:)`
/// (`DevicectlPhysicalClient`), which answers nil for a device that is not
/// enabled, paired and connected; an Android call needs the row's serial.
/// Restart and Unpair / Disconnect are asked about first (`confirmation`, an
/// alert in Device Hub's style); Rename is edited in the sidebar row.
@MainActor
@Observable
final class PhysicalDeviceActions {
    enum Confirmation: Equatable {
        case restartApple(udid: String, name: String)
        case unpairApple(udid: String, name: String)
        case restartAndroid(serial: String, name: String)
        case disconnectAndroid(serial: String, name: String)

        var title: String {
            switch self {
            case .restartApple(_, let name), .restartAndroid(_, let name): "Restart \(name)?"
            case .unpairApple(_, let name): "Unpair \(name)?"
            case .disconnectAndroid(_, let name): "Disconnect \(name)?"
            }
        }

        var message: String {
            switch self {
            case .restartApple, .restartAndroid:
                "The device restarts, and apps and sessions on it end. It comes back in a minute or two."
            case .unpairApple:
                "This Mac will no longer be trusted by the device. To use it again, pair it with Pair Nearby Device…"
            case .disconnectAndroid:
                "adb drops the wireless connection. Connect it again from Pair Nearby Device\u{2026}."
            }
        }

        var confirmTitle: String {
            switch self {
            case .restartApple, .restartAndroid: "Restart"
            case .unpairApple: "Unpair"
            case .disconnectAndroid: "Disconnect"
            }
        }

        var alertSpec: DHAlertSpec {
            DHAlertSpec(title: title, message: message, confirmTitle: confirmTitle, style: .destructive)
        }
    }

    /// An iPhone being renamed in the sidebar row.
    struct RenameTarget: Equatable, Identifiable {
        let udid: String
        let name: String

        var id: String { udid }
    }

    enum Operation: Equatable {
        case restarting, renaming, collecting, unpairing
    }

    /// The question the alert shows.
    var confirmation: Confirmation?
    var renameTarget: RenameTarget?
    var renameDraft = ""
    /// What runs now, by hardware UDID (an iPhone) or serial (a phone).
    private(set) var operations: [String: Operation] = [:]

    /// Where "Show in Finder" goes (the Finder in the app, a recorder in tests).
    @ObservationIgnored var revealInFinder: @MainActor (_ url: URL) -> Void = { url in
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    /// Brings Finder forward when there is no folder to show.
    @ObservationIgnored var activateFinder: @MainActor () -> Void = {
        if let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") {
            NSWorkspace.shared.openApplication(at: finder, configuration: NSWorkspace.OpenConfiguration())
        }
    }
    @ObservationIgnored var openApplication: @MainActor (_ url: URL) -> Void = { url in
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
    @ObservationIgnored var carPlaySimulator: @MainActor () -> URL?
    /// Where the sysdiagnose panel opens (the home folder, as in Device Hub).
    @ObservationIgnored var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    /// Whether the one-time CarPlay explanation was shown.
    @ObservationIgnored var defaults: UserDefaults
    @ObservationIgnored var carPlayExplained: Bool {
        get { defaults.bool(forKey: "carPlayInDeviceHubExplained") }
        set { defaults.set(newValue, forKey: "carPlayInDeviceHubExplained") }
    }

    @ObservationIgnored private let inventory: ApplePhysicalInventory
    @ObservationIgnored private let status: StatusCenter
    @ObservationIgnored private let picker: any FileDestinationPicker
    @ObservationIgnored private let adbClient: AdbClient?

    init(
        inventory: ApplePhysicalInventory,
        status: StatusCenter,
        picker: any FileDestinationPicker,
        adbClient: AdbClient?,
        defaults: UserDefaults
    ) {
        self.defaults = defaults
        self.inventory = inventory
        self.status = status
        self.picker = picker
        self.adbClient = adbClient
        carPlaySimulator = { DeviceHubLocator.locate() }
    }

    // MARK: - Availability

    /// Whether the iPhone can be sent a management command now.
    func canManage(_ entry: ApplePhysicalEntry) -> Bool {
        entry.canUseClient && operations[entry.udid] == nil
    }

    func isBusy(_ key: String) -> Bool { operations[key] != nil }

    // MARK: - Questions

    func requestRestart(_ entry: ApplePhysicalEntry) {
        confirmation = .restartApple(udid: entry.udid, name: entry.name)
    }

    func requestUnpair(_ entry: ApplePhysicalEntry) {
        confirmation = .unpairApple(udid: entry.udid, name: entry.name)
    }

    func requestRestartAndroid(serial: String, name: String) {
        confirmation = .restartAndroid(serial: serial, name: name)
    }

    func requestDisconnectAndroid(serial: String, name: String) {
        confirmation = .disconnectAndroid(serial: serial, name: name)
    }

    func requestRename(_ entry: ApplePhysicalEntry) {
        renameDraft = entry.name
        renameTarget = RenameTarget(udid: entry.udid, name: entry.name)
    }

    /// The alert's answer.
    func resolve(_ confirmation: Confirmation, confirmed: Bool) {
        self.confirmation = nil
        guard confirmed else { return }
        switch confirmation {
        case .restartApple(let udid, let name): Task { await restart(udid: udid, name: name) }
        case .unpairApple(let udid, let name): Task { await unpair(udid: udid, name: name) }
        case .restartAndroid(let serial, let name): Task { await restartAndroid(serial: serial, name: name) }
        case .disconnectAndroid(let serial, let name): Task { await disconnectAndroid(serial: serial, name: name) }
        }
    }

    // MARK: - iPhone

    /// `device reboot`.
    func restart(udid: String, name: String) async {
        let key = PhysicalDeviceOptIn.normalize(udid)
        // Claimed before the client is awaited: a second tap meanwhile finds
        // the device busy instead of running the action twice.
        guard operations[key] == nil else { return }
        operations[key] = .restarting
        defer { operations[key] = nil }
        guard let client = await inventory.client(for: key) else { return }
        do {
            try await client.reboot()
            inventory.beginRestart(udid: key)
            status.flash("Restarting \(name)\u{2026}")
        } catch {
            status.errorMessage = "Could not restart \(name): \(ApplePhysicalController.describe(error))"
        }
        await inventory.refreshNow()
    }

    /// `device rename --name`; the list is read again so the row shows it.
    func rename(udid: String, from oldName: String, to newName: String) async {
        let key = PhysicalDeviceOptIn.normalize(udid)
        // Claimed before the client is awaited: a second tap meanwhile finds
        // the device busy instead of running the action twice.
        guard operations[key] == nil else { return }
        operations[key] = .renaming
        defer { operations[key] = nil }
        guard let client = await inventory.client(for: key) else { return }
        do {
            try await client.rename(to: newName)
            status.flash("Renamed \(oldName) to \(newName)")
        } catch {
            status.errorMessage = "Could not rename \(oldName): \(ApplePhysicalController.describe(error))"
        }
        await inventory.refreshNow()
    }

    /// Device Hub's save panel for a sysdiagnose (measured on 27.0).
    static let sysdiagnosePanelMessage = "Choose a location to save the sysdiagnose."
    static let sysdiagnosePanelPrompt = "Select"

    /// `device sysdiagnose --destination <folder the user chose>`, with the
    /// banner's progress line while it runs and the folder shown after.
    func collectSysdiagnose(udid: String, name: String) async {
        let key = PhysicalDeviceOptIn.normalize(udid)
        guard operations[key] == nil, inventory.entry(udid: key)?.canUseClient == true,
              let folder = picker.chooseFolder(
                  message: Self.sysdiagnosePanelMessage,
                  prompt: Self.sysdiagnosePanelPrompt,
                  directory: homeDirectory
              )
        else { return }
        // Claimed before the client is awaited (see `restart`).
        operations[key] = .collecting
        defer { operations[key] = nil }
        guard let client = await inventory.client(for: key) else { return }
        do {
            let files = try await status.withElapsedStatus("Collecting sysdiagnose from \(name)\u{2026}") {
                try await client.sysdiagnose(into: folder)
            }
            status.flash("Saved the sysdiagnose of \(name) to \(folder.lastPathComponent)", seconds: 4)
            // Device Hub reveals the file in Finder.
            revealInFinder(files.first ?? folder)
        } catch DevicectlPrivilegedError.cancelled {
            // The user dismissed macOS's password dialog: no alert.
        } catch {
            status.errorMessage = "Could not collect the sysdiagnose of \(name): \(ApplePhysicalController.describe(error))"
        }
    }

    /// `manage unpair`; the list is read again so the row shows the state.
    func unpair(udid: String, name: String) async {
        let key = PhysicalDeviceOptIn.normalize(udid)
        // Claimed before the client is awaited: a second tap meanwhile finds
        // the device busy instead of running the action twice.
        guard operations[key] == nil else { return }
        operations[key] = .unpairing
        defer { operations[key] = nil }
        guard let client = await inventory.client(for: key) else { return }
        do {
            try await client.unpair()
            status.flash("Unpaired \(name)")
        } catch {
            status.errorMessage = "Could not unpair \(name): \(ApplePhysicalController.describe(error))"
        }
        await inventory.refreshNow()
    }

    /// Device Hub's Finder shows the device in its sidebar, which no public
    /// API reveals: the device's own local folder is shown (see
    /// `PhysicalDeviceFolder`), else Finder comes forward.
    func showInFinder(_ entry: ApplePhysicalEntry) {
        if let folder = PhysicalDeviceFolder.locate(deviceName: entry.name) {
            revealInFinder(folder)
        } else {
            activateFinder()
        }
    }

    var carPlaySimulatorURL: URL? { carPlaySimulator() }

    /// "CarPlay Simulator" is Device Hub's own built-in head-unit window (in
    /// process, private: no separate app exists), so the item opens Device
    /// Hub, and says so the first time.
    static let carPlayExplanation =
        "CarPlay Simulator runs in Device Hub. Device Hub opens; choose CarPlay Simulator on the iPhone there."

    func openCarPlaySimulator() {
        guard let url = carPlaySimulator() else { return }
        if !carPlayExplained {
            carPlayExplained = true
            status.flash(Self.carPlayExplanation, seconds: 8)
        }
        openApplication(url)
    }

    // MARK: - Android phone

    /// `adb reboot`.
    func restartAndroid(serial: String, name: String) async {
        guard operations[serial] == nil, let adbClient else { return }
        operations[serial] = .restarting
        defer { operations[serial] = nil }
        do {
            try await adbClient.reboot(serial: serial)
            status.flash("Restarting \(name)\u{2026}")
        } catch {
            status.errorMessage = "Could not restart \(name): \(error)"
        }
    }

    /// `adb bugreport <folder the user chose>`.
    func collectBugReport(serial: String, name: String) async {
        guard operations[serial] == nil, let adbClient,
              let folder = picker.chooseFolder(
                  message: "Choose where to save the bug report of \(name).",
                  directory: picker.autoSaveDirectory
              )
        else { return }
        operations[serial] = .collecting
        defer { operations[serial] = nil }
        do {
            try await status.withElapsedStatus("Collecting bug report from \(name)\u{2026}") {
                try await adbClient.bugReport(serial: serial, into: folder)
            }
            status.flash("Saved the bug report of \(name) to \(folder.lastPathComponent)", seconds: 4)
            revealInFinder(folder)
        } catch {
            status.errorMessage = "Could not collect the bug report of \(name): \(error)"
        }
    }

    /// `adb disconnect` (a wireless device).
    func disconnectAndroid(serial: String, name: String) async {
        guard operations[serial] == nil, let adbClient else { return }
        operations[serial] = .unpairing
        defer { operations[serial] = nil }
        do {
            try await adbClient.disconnect(serial: serial)
            status.flash("Disconnected \(name)")
        } catch {
            status.errorMessage = "Could not disconnect \(name): \(error)"
        }
    }
}

/// Presents `PhysicalDeviceActions`' questions over the window, in Device
/// Hub's alert style (as the simulator's destructive actions are).
struct PhysicalDeviceActionsDialogHost: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let actions = model.physicalActions
        content.dhAlert(
            item: actions.confirmation,
            spec: { $0.alertSpec },
            resolve: { confirmation, confirmed in
                actions.resolve(confirmation, confirmed: confirmed)
            }
        )
    }
}
