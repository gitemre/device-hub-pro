import AppKit
import Foundation
import Observation
import DeviceHubProKit

/// The crash reports of the simulator the Diagnostics tab shows (design
/// §3.9's "crash reports per UDID"). Device Hub says crash reports
/// are unavailable for simulators; the crash reporter writes them all the
/// same, with the Mac's own, and each one names its simulator
/// (`SimulatorCrashReportParsing`).
///
/// Reads `~/Library/Logs/DiagnosticReports` (its own files) while the tab
/// shows the simulator, again whenever that folder changes, and once more
/// shortly after a scan met a recent report it could not read yet. Never
/// deletes, moves or changes a report.
///
/// The simulator's own `CrashReporter` folder under CoreSimulator's logs is
/// not read: on the iOS 27.0 runtime it held only empty folders after a
/// crash, every report going to the Mac's folder.
@MainActor
@Observable
final class SimulatorCrashReportsController {
    /// The simulator whose reports are listed; nil while none is shown.
    private(set) var udid: String?
    /// `udid`'s reports, as read last.
    private(set) var reports: [SimulatorCrashReport] = []
    /// Whether `udid`'s folder was read at least once.
    private(set) var hasLoaded = false
    /// "My app only": keep the followed app's reports. Off again for each
    /// simulator shown.
    var myAppOnly = false

    private let simulators: SimulatorInventory
    private let pasteboard: MacPasteboard
    private let scanner = SimulatorCrashReportScanner()
    @ObservationIgnored private var loadGeneration = 0
    /// The last `show` call's token: only its `hide(token:)` ends the list,
    /// so a section that disappears after its successor appeared does not
    /// end the successor's.
    @ObservationIgnored private var owner = 0
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var pendingReload: Task<Void, Never>?
    @ObservationIgnored private var pendingFollowUp: Task<Void, Never>?
    /// How long the folder stays quiet before it is read again: the crash
    /// reporter writes a report in several steps.
    @ObservationIgnored var changeDebounce: Duration = .milliseconds(800)
    /// When a report that did not read yet is read again.
    @ObservationIgnored var followUpDelay: Duration = .seconds(2)
    /// Opens reports in Console (tests replace it).
    @ObservationIgnored var openInConsole: @MainActor ([URL]) -> Void = SimulatorCrashReportsController.openInConsoleApp
    /// Selects reports in Finder (tests replace it).
    @ObservationIgnored var revealInFinder: @MainActor ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }

    init(simulators: SimulatorInventory, pasteboard: MacPasteboard) {
        self.simulators = simulators
        self.pasteboard = pasteboard
    }

    isolated deinit {
        stopWatching()
    }

    /// Where reports are read from; nil without a reports folder.
    var folder: URL? { simulators.diagnosticReportsDirectory }

    /// Lists `udid`'s reports and follows the folder for new ones. Returns
    /// the token `hide(token:)` takes.
    @discardableResult
    func show(udid: String) -> Int {
        owner += 1
        if self.udid != udid {
            self.udid = udid
            reports = []
            hasLoaded = false
            myAppOnly = false
            watch()
            Task { await reload() }
        } else if watcher == nil {
            watch()
        }
        return owner
    }

    /// Ends the list when `token` is the last `show`'s.
    func hide(token: Int) {
        guard token == owner else { return }
        hide()
    }

    /// Ends the list and stops following the folder.
    func hide() {
        udid = nil
        reports = []
        hasLoaded = false
        myAppOnly = false
        loadGeneration += 1
        stopWatching()
    }

    /// Reads the folder again.
    func reload() async {
        await reload(isFollowUp: false)
    }

    private func reload(isFollowUp: Bool) async {
        guard let udid else { return }
        guard let folder else {
            hasLoaded = true
            return
        }
        // The folder may have appeared since the list opened.
        if watcher == nil || watchesParent { watch() }
        loadGeneration += 1
        let generation = loadGeneration
        let scan = await scanner.scan(folders: [folder])
        guard generation == loadGeneration, self.udid == udid else { return }
        reports = scan.reports.filter { $0.udid == udid }
        hasLoaded = true
        if scan.hasRecentUnreadable, !isFollowUp {
            scheduleFollowUp()
        }
    }

    /// The rows to list: `app`'s only when "My app only" is on and an app
    /// is followed.
    func rows(followed app: SimulatorCrashReportList.App?) -> [SimulatorCrashReportRow] {
        guard let udid else { return [] }
        return SimulatorCrashReportList.rows(reports, udid: udid, app: myAppOnly ? app : nil)
    }

    // MARK: - Actions

    /// Opens the row's newest report in Console.
    func open(_ row: SimulatorCrashReportRow) {
        openInConsole([row.newest.url])
    }

    /// Selects the row's reports (every one of a loop) in Finder.
    func reveal(_ row: SimulatorCrashReportRow) {
        revealInFinder(row.reports.map(\.url))
    }

    /// Copies the row's newest report, whole, as text; the file is read off
    /// the main actor.
    @discardableResult
    func copy(_ row: SimulatorCrashReportRow) async -> Bool {
        let url = row.newest.url
        let text = await Task.detached(priority: .userInitiated) {
            (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
        }.value
        guard let text else { return false }
        pasteboard.setString(text)
        return true
    }

    static func openInConsoleApp(_ urls: [URL]) {
        guard let console = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") else {
            urls.forEach { NSWorkspace.shared.open($0) }
            return
        }
        NSWorkspace.shared.open(urls, withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Following the folder

    /// Whether the folder itself is followed (tests).
    var isWatching: Bool { watcher != nil && !watchesParent }
    /// Whether the folder is missing and its parent is followed until it
    /// appears (tests).
    var isWatchingParent: Bool { watcher != nil && watchesParent }
    @ObservationIgnored private var watchesParent = false

    private func watch() {
        stopWatching()
        guard let folder else { return }
        var descriptor = Darwin.open(folder.path, O_EVTONLY)
        watchesParent = false
        if descriptor < 0 {
            // The folder does not exist yet (nothing has crashed on this
            // Mac): follow its parent, and the next read follows the folder
            // once it appears.
            descriptor = Darwin.open(folder.deletingLastPathComponent().path, O_EVTONLY)
            watchesParent = true
        }
        guard descriptor >= 0 else { watchesParent = false; return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.folderChanged() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    private func folderChanged() {
        pendingReload?.cancel()
        pendingReload = Task { [weak self] in
            guard let delay = self?.changeDebounce else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.reload()
        }
    }

    /// One more read a little later: a report still being written grows in
    /// place, which changes no folder entry.
    private func scheduleFollowUp() {
        pendingFollowUp?.cancel()
        pendingFollowUp = Task { [weak self] in
            guard let delay = self?.followUpDelay else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.reload(isFollowUp: true)
        }
    }

    private func stopWatching() {
        pendingReload?.cancel()
        pendingReload = nil
        pendingFollowUp?.cancel()
        pendingFollowUp = nil
        watcher?.cancel()
        watcher = nil
    }
}
