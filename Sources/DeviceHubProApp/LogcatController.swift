import Foundation
import Observation
import DeviceHubProKit

/// The Diagnostics tab's log: the device it streams, the tail the Logcat
/// view shows, the app filter, the status line and the export.
///
/// An adb device streams logcat (`LogcatStream`); a simulator streams its
/// unified log (`SimulatorLogStream`: `simctl spawn <UDID> log stream
/// --style ndjson`), each event shown as a logcat entry (Debug → D, Info and
/// Default → I, Error → E, Fault → F, activity records → V; the process as
/// the tag, the subsystem kept for the search). Its App picker lists the
/// simulator's apps by bundle identifier and follows one through its
/// executable's process name (`log stream --predicate`), which keeps
/// following it across relaunches. Both streams are polled every 400 ms,
/// so a burst (over 14,000 events a second right after a boot) reaches the
/// view in batches, never line by line: logcat's newest 1,500 entries; the
/// simulator's events since the last poll, converted once, after the
/// previous ones up to 1,500 (more when one poll brings more), so nothing
/// the stream still holds is skipped. What the stream dropped before a poll
/// read it shows as a gap marker (`LogcatFeed`).
///
/// Each `DeviceWorkspace` owns one as `logcat`, which the views read
/// directly. Logcat keeps its own device: it is not tied to the mirrored
/// device, so selection changes and mirror teardown leave it running; quit
/// stops it. A simulator's log runs only while the Diagnostics tab shows
/// that simulator, ready (`AppModel.watchSimulatorLogAudience` calls
/// `closeSimulatorLog` otherwise): a debug-level `log stream` costs about a
/// fifth of a core even while paused (18 % measured), where logcat costs
/// next to nothing.
@MainActor
@Observable
final class LogcatController {
    /// The adb the package list and the stream run on; nil when there is no
    /// adb (opening then only records the serial).
    private let adbClient: AdbClient?
    /// Where an export failure is reported: the window alert.
    private let status: StatusCenter
    /// Asks where an export goes.
    private let picker: any FileDestinationPicker

    init(adbClient: AdbClient?, status: StatusCenter, picker: any FileDestinationPicker) {
        self.adbClient = adbClient
        self.status = status
        self.picker = picker
    }

    /// simctl on the listed device set, for a simulator's log and its app
    /// list; nil without Apple tooling. Wired by its owner.
    @ObservationIgnored var simctlSource: @MainActor () -> SimctlClient? = { nil }

    /// The physical iPhone's client (the inventory's, which answers nil for a
    /// phone that is not enabled, paired and connected); nil without one.
    /// Wired by its owner.
    @ObservationIgnored var physicalClientSource: @MainActor (String) async -> DevicectlPhysicalClient? = { _ in nil }

    var logcatSerial: String?
    /// The physical iPhone (hardware UDID) the log pane shows; nil while it
    /// shows another source. Its console streams only after the user presses
    /// Launch & Stream (`launchPhysicalApp`): the app launches then, and
    /// stopping the stream ends it.
    internal(set) var physicalLogUDID: String?
    var physicalLogApps: [PhysicalLogApp] = []
    var physicalSelectedBundle: String?
    internal(set) var physicalLogPhase: PhysicalLogPhase = .idle
    /// The simulator whose unified log the view streams; nil while it
    /// streams an adb device's logcat, or nothing.
    private(set) var simulatorLogUDID: String?
    var logcatEntries: [LogcatEntry] = []
    var logcatPackages: [String] = []
    var selectedLogcatPackage: String?
    var logcatLevel: LogcatLevel = .debug
    var logcatSearch = ""
    var logcatPaused = false
    var logcatStatusText = ""

    /// Whether the current stop was deliberate (`stopLogcat`): the view shows
    /// its "Log stream stopped" placeholder instead of "No device", which the
    /// cleared serial would otherwise imply.
    internal(set) var logcatWasStopped = false

    private var logcatStream: LogcatStream?
    private var simulatorLogStream: SimulatorLogStream?
    /// The id of the newest simulator event published to `logcatEntries`;
    /// the next poll reads the ones after it. Zero with every new stream.
    private var simulatorLogCursor: UInt64 = 0
    /// The simulator's apps' process names (`CFBundleExecutable`) by bundle
    /// identifier: the App picker follows an app by its process.
    private var simulatorAppProcesses: [String: String] = [:]
    var physicalLogStream: PhysicalConsoleLogStream?
    var physicalLogCursor: UInt64 = 0
    /// Bumped by every open and teardown of the physical pane, so an app
    /// list still loading cannot land in a pane that has moved on.
    var physicalLoadGeneration: UInt64 = 0
    var logcatPollTask: Task<Void, Never>?
    /// Re-reads the device's third-party packages while its logcat streams:
    /// an app installed after the log opened (or a first read that failed)
    /// must still reach the App picker.
    var logcatPackagesTask: Task<Void, Never>?
    /// How often `logcatPackagesTask` re-reads the package list (tests
    /// shorten it).
    var packageRefreshInterval: Duration = .seconds(5)
    /// Bumped by every start/stop, so an `openLogcat` still loading packages
    /// when a newer start (or the Retry) lands cannot install its stream.
    private var logcatStartGeneration: UInt64 = 0

    // MARK: - Audience

    /// Views showing the log right now (each Logcat view and the Log focus
    /// pane registers itself while it is on screen in a visible window).
    private var shownLogViews: Set<UUID> = []
    /// Set by the first registration: before any view has reported, a
    /// stream runs as it always did (tests, launch-time starts).
    private var logAudienceReported = false
    /// The adb child (and the polls) were stopped because no view shows the
    /// log; `resumeLogStream` starts them again.
    private(set) var logStreamSuspended = false
    /// The revision of the adb stream's history last published to
    /// `logcatEntries` (nil: publish at the next poll).
    private var publishedLogRevision: (stream: ObjectIdentifier, revision: UInt64)?

    var isLogShown: Bool { !shownLogViews.isEmpty }

    /// A log view appeared or its window hid/showed (`shown` false) or the
    /// view disappeared. While no view shows the log, the `adb logcat` child,
    /// the 400 ms poll and the package refresh stop; the history and the
    /// `-T` resume floor stay, so showing it again continues without a gap.
    func setLogShown(_ id: UUID, _ shown: Bool) {
        logAudienceReported = true
        if shown { shownLogViews.insert(id) } else { shownLogViews.remove(id) }
        if isLogShown { resumeLogStream() } else { suspendLogStream() }
    }

    private func suspendLogStream() {
        guard !logStreamSuspended else { return }
        logcatPollTask?.cancel()
        logcatPollTask = nil
        logcatPackagesTask?.cancel()
        logcatPackagesTask = nil
        guard let stream = logcatStream, case .running = stream.status else {
            // Nothing adb to stop (a simulator or physical source, or an
            // already stopped stream): only the poll was idle.
            logStreamSuspended = logcatStream == nil && (simulatorLogStream != nil || physicalLogStream != nil)
            return
        }
        stream.stop()
        logStreamSuspended = true
    }

    private func resumeLogStream() {
        guard logStreamSuspended else { return }
        logStreamSuspended = false
        if let stream = logcatStream, let serial = logcatSerial {
            stream.start()
            publishedLogRevision = nil
            startLogcatPolling()
            if let adbClient {
                startPackageRefresh(serial: serial, adbClient: adbClient, generation: logcatStartGeneration)
            }
        } else if simulatorLogStream != nil || physicalLogStream != nil {
            startLogcatPolling()
        }
    }

    /// The stream process's stop reason, when it has exited (spec §9.3c:
    /// the Logcat view's disconnected placeholder). `nil` while idle or
    /// running.
    var logcatStopReason: String? {
        if case .ended(let reason) = physicalLogPhase { return reason }
        if let simulatorLogStream, case .stopped(let reason) = simulatorLogStream.status {
            return reason
        }
        guard let logcatStream,
              case .stopped(let reason) = logcatStream.status
        else {
            return nil
        }
        return reason
    }

    /// The streamed device, whichever its platform: the adb serial, or the
    /// simulator's UDID. Nil while nothing streams.
    var logSourceID: String? { logcatSerial ?? simulatorLogUDID ?? physicalLogUDID }

    func openLogcat(serial: String) async {
        stopLogcat()
        logcatWasStopped = false
        logcatSerial = serial
        logcatEntries = []
        selectedLogcatPackage = nil
        logcatSearch = ""

        guard let adbClient else { return }

        let generation = logcatStartGeneration
        // Unstructured, so a caller's cancellation (a view's task) cannot
        // turn the first read into an empty list.
        let packages = await Task { try? await adbClient.listPackages(serial: serial) }.value
        // A newer start (e.g. the Retry action) superseded this load while
        // packages were in flight; it owns the serial and the stream.
        guard generation == logcatStartGeneration else { return }
        logcatPackages = Self.pickerPackages(packages ?? [], following: selectedLogcatPackage)

        let stream = LogcatStream(adbURL: adbClient.adbURL, serial: serial)
        logcatStream = stream
        stream.start()
        startLogcatPolling()
        startPackageRefresh(serial: serial, adbClient: adbClient, generation: generation)
        if logAudienceReported && !isLogShown { suspendLogStream() }
    }

    /// Keeps `logcatPackages` current while `serial`'s log is open; a failed
    /// read keeps the list it has.
    private func startPackageRefresh(serial: String, adbClient: AdbClient, generation: UInt64) {
        logcatPackagesTask?.cancel()
        let interval = packageRefreshInterval
        logcatPackagesTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled,
                      let packages = try? await adbClient.listPackages(serial: serial),
                      let self, generation == self.logcatStartGeneration, self.logcatSerial == serial
                else { continue }
                let updated = Self.pickerPackages(packages, following: self.selectedLogcatPackage)
                if updated != self.logcatPackages { self.logcatPackages = updated }
            }
        }
    }

    /// The App picker's packages: the device's list, plus the followed app
    /// if it is gone (the stream still follows it until the log reopens).
    static func pickerPackages(_ packages: [String], following selected: String?) -> [String] {
        guard let selected, !packages.contains(selected) else { return packages }
        return (packages + [selected]).sorted()
    }

    /// adbd of `serial` was restarted on purpose (`adb root`): its logcat
    /// process ended with it, so open the stream again on the same app.
    func restartAfterAdbdRestart(serial: String) {
        guard logcatSerial == serial else { return }
        let package = selectedLogcatPackage
        Task {
            await openLogcat(serial: serial)
            if let package, logcatSerial == serial { setLogcatPackage(package) }
        }
    }

    func stopLogcat() {
        logStreamSuspended = false
        publishedLogRevision = nil
        logcatStartGeneration &+= 1
        logcatPollTask?.cancel()
        logcatPollTask = nil
        logcatPackagesTask?.cancel()
        logcatPackagesTask = nil
        logcatStream?.stop()
        logcatStream = nil
        logcatSerial = nil
        simulatorLogStream?.stop()
        simulatorLogStream = nil
        simulatorLogCursor = 0
        simulatorLogUDID = nil
        simulatorAppProcesses = [:]
        endPhysicalLog()
        logcatEntries = []
        logcatStatusText = ""
        logcatWasStopped = true
    }

    /// Opens logcat for `serial` unless it already streams that device. The
    /// stream outlives the Diagnostics tab by design (the toolbar path,
    /// `selectInspectorTab(.diagnostics)`, starts it the same way), so the
    /// start is not tied to the calling view: run inside a view's `.task`,
    /// leaving the tab mid-load cancelled the package list (`try?` turned it
    /// into []) and still started the stream, with an empty PID-follow list.
    func openLogcatIfNeeded(serial: String) {
        guard logcatSerial != serial else { return }
        Task { await openLogcat(serial: serial) }
    }

    /// Filters the stream to `package`. The stream clears its own history
    /// with the switch; only the list on screen empties here, at once. A
    /// simulator's stream starts over, following the app's process.
    func setLogcatPackage(_ package: String?) {
        selectedLogcatPackage = package
        logcatEntries = []
        logcatStream?.setPackage(package)
        if let udid = simulatorLogUDID, let simctl = simctlSource() {
            startSimulatorStream(udid: udid, simctl: simctl, process: package.flatMap { simulatorAppProcesses[$0] })
        }
    }

    func clearLogcat() {
        logcatStream?.clear()
        simulatorLogStream?.clear()
        logcatEntries = []
    }

    // MARK: - Simulators

    /// Streams `udid`'s unified log, the whole log at first (`log stream
    /// --level debug`), and lists its apps for the App picker. Replaces
    /// whatever streamed before, logcat included.
    func openSimulatorLog(udid: String) async {
        stopLogcat()
        logcatWasStopped = false
        simulatorLogUDID = udid
        logcatEntries = []
        selectedLogcatPackage = nil
        logcatSearch = ""

        guard let simctl = simctlSource() else { return }

        let generation = logcatStartGeneration
        // The stream starts first: the log does not wait for the app list.
        startSimulatorStream(udid: udid, simctl: simctl, process: nil)
        startLogcatPolling()
        // Best effort: without the list the picker offers the whole log only.
        // Unstructured, so a caller's cancellation cannot empty the list.
        let apps = await Task { try? await simctl.listApps(udid: udid) }.value ?? []
        // A newer start or a stop superseded this load meanwhile.
        guard generation == logcatStartGeneration else { return }
        simulatorAppProcesses = Self.processNames(of: apps)
        logcatPackages = simulatorAppProcesses.keys.sorted()
        startSimulatorAppRefresh(udid: udid, generation: generation)
    }

    /// Reads `udid`'s apps again every `packageRefreshInterval` while its log
    /// streams: an app installed outside Device Hub Pro (`flutter run`, Xcode)
    /// reaches the App picker too.
    private func startSimulatorAppRefresh(udid: String, generation: UInt64) {
        logcatPackagesTask?.cancel()
        let interval = packageRefreshInterval
        logcatPackagesTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self,
                      generation == self.logcatStartGeneration, self.simulatorLogUDID == udid
                else { continue }
                await self.reloadSimulatorApps(udid: udid)
            }
        }
    }

    /// Reads `udid`'s apps again for the App picker while its log streams:
    /// an app was installed or uninstalled through the Apps inspector or a
    /// stage drop (`SimulatorAppsController.appsChanged`), so a new build
    /// can be followed without reopening the log. The stream goes on as it
    /// is; a followed app that is gone stays listed, as the stream still
    /// follows its process, until the log opens again.
    func reloadSimulatorApps(udid: String) async {
        guard simulatorLogUDID == udid, let simctl = simctlSource() else { return }
        let generation = logcatStartGeneration
        guard let apps = try? await simctl.listApps(udid: udid),
              generation == logcatStartGeneration, simulatorLogUDID == udid
        else { return }
        var processes = Self.processNames(of: apps)
        if let followed = selectedLogcatPackage, processes[followed] == nil {
            processes[followed] = simulatorAppProcesses[followed]
        }
        if processes != simulatorAppProcesses { simulatorAppProcesses = processes }
        let packages = processes.keys.sorted()
        if packages != logcatPackages { logcatPackages = packages }
    }

    /// The app `udid`'s log follows (the App picker), for the crash
    /// reports' "My app only"; nil while the log follows no app or streams
    /// another device.
    func followedSimulatorApp(udid: String) -> SimulatorCrashReportList.App? {
        guard simulatorLogUDID == udid, let bundle = selectedLogcatPackage else { return nil }
        return SimulatorCrashReportList.App(bundleIdentifier: bundle, process: simulatorAppProcesses[bundle])
    }

    /// Opens `udid`'s log unless it already streams it; like
    /// `openLogcatIfNeeded`, not tied to the calling view.
    func openSimulatorLogIfNeeded(udid: String) {
        guard simulatorLogUDID != udid else { return }
        Task { await openSimulatorLog(udid: udid) }
    }

    /// Ends the simulator's log, or its start still listing apps, once
    /// nothing shows it (another selection, the simulator no longer ready,
    /// another tab, the inspector hidden). Unlike Stop it leaves no "Logcat
    /// stopped" behind: the next time the tab shows the ready simulator, the
    /// log opens again. An adb device's logcat is left alone.
    func closeSimulatorLog() {
        guard simulatorLogUDID != nil else { return }
        stopLogcat()
        logcatWasStopped = false
    }

    /// The apps' process names by bundle identifier; an app without an
    /// executable cannot be followed and is left out.
    static func processNames(of apps: [SimulatorApp]) -> [String: String] {
        var names: [String: String] = [:]
        for app in apps {
            guard let executable = app.executable, !executable.isEmpty else { continue }
            names[app.bundleIdentifier] = executable
        }
        return names
    }

    /// (Re)starts the simulator's stream, following `process` when given.
    private func startSimulatorStream(udid: String, simctl: SimctlClient, process: String?) {
        simulatorLogStream?.stop()
        let stream = SimulatorLogStream(
            simctl: simctl,
            udid: udid,
            level: .debug,
            predicate: process.map(SimulatorLogStream.processPredicate)
        )
        simulatorLogStream = stream
        simulatorLogCursor = 0
        stream.start()
    }

    /// The simulator's log window after a poll that read `fresh`: the
    /// newest `pollWindow` entries of `current` and `fresh`, or all of
    /// `fresh` when a burst brought more, so the view's feed receives every
    /// event the stream held.
    static func simulatorLogWindow(_ current: [LogcatEntry], adding fresh: [LogcatEntry]) -> [LogcatEntry] {
        guard fresh.count < pollWindow else { return fresh }
        return Array((current + fresh).suffix(pollWindow))
    }

    /// How many entries a poll publishes at least (logcat's tail).
    static let pollWindow = 1500

    func startLogcatPolling() {
        logcatPollTask?.cancel()
        logcatPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let stream = self.logcatStream {
                    if !self.logcatPaused {
                        // Republish only when the stream's history changed.
                        let revision = stream.revision
                        let key = (stream: ObjectIdentifier(stream), revision: revision)
                        if self.publishedLogRevision?.stream != key.stream
                            || self.publishedLogRevision?.revision != key.revision {
                            self.publishedLogRevision = key
                            self.logcatEntries = stream.tail(Self.pollWindow)
                        }
                    }
                    self.logcatStatusText = Self.describe(stream.status, package: self.selectedLogcatPackage)
                } else if let stream = self.simulatorLogStream {
                    if !self.logcatPaused {
                        let fresh = stream.logcatEntries(after: self.simulatorLogCursor)
                        if let newest = fresh.last {
                            self.simulatorLogCursor = newest.id
                            self.logcatEntries = Self.simulatorLogWindow(self.logcatEntries, adding: fresh)
                        }
                    }
                    let package = self.selectedLogcatPackage
                    self.logcatStatusText = Self.describe(
                        stream.status,
                        package: package,
                        process: package.flatMap { self.simulatorAppProcesses[$0] },
                        sharedWith: package.map { Self.apps(sharingProcessOf: $0, in: self.simulatorAppProcesses) } ?? []
                    )
                } else if self.physicalLogStream != nil {
                    self.pollPhysicalLog()
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    /// The status line for the stream's `status` while it follows `package`
    /// (nil: the whole log). Internal so the tests can pin each state.
    static func describe(_ status: LogcatStream.Status, package: String?) -> String {
        switch status {
        case .idle:
            return "idle"
        case .running(let pid):
            guard let package else { return "all logs" }
            if pid != nil {
                return package
            }
            return "\(package) · waiting for the app…"
        case .stopped(let reason):
            return "stopped: \(reason)"
        }
    }

    /// The status line for a simulator's stream while it follows `package`
    /// through `process` (nil: the whole log). The follow is by process
    /// name, so the other listed apps whose executable has that name
    /// (`sharedWith`: every Flutter app runs as "Runner") show in it too,
    /// and the line says so.
    static func describe(
        _ status: SimulatorLogStream.Status,
        package: String?,
        process: String?,
        sharedWith others: [String] = []
    ) -> String {
        switch status {
        case .idle:
            return "idle"
        case .running:
            guard let package else { return "all logs" }
            guard let process else { return package }
            guard let other = others.first else { return "\(package) · \(process)" }
            let who = others.count == 1 ? other : "\(others.count) other apps"
            return "\(package) · \(process) (\(who) \(others.count == 1 ? "runs" : "run") as \(process) too)"
        case .stopped(let reason):
            return "stopped: \(reason)"
        }
    }

    /// The other apps in `processes` (executable by bundle identifier) that
    /// run under `package`'s process name, sorted.
    static func apps(sharingProcessOf package: String, in processes: [String: String]) -> [String] {
        guard let process = processes[package] else { return [] }
        return processes.filter { $0.key != package && $0.value == process }.map(\.key).sorted()
    }

    // MARK: - Export

    /// Writes `entries` — the Logcat view's filtered history, which reaches
    /// back further than `logcatEntries`' window — to a file the user picks.
    /// The Logcat panel is not a sheet, so a failure uses the window alert.
    func exportLogcat(entries: [LogcatEntry]) {
        guard !entries.isEmpty else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        guard let url = picker.chooseDestination(
            suggestedName: "devicehubpro-logcat-\(formatter.string(from: Date())).log",
            directory: nil
        ) else {
            return
        }
        do {
            try Self.logcatExportText(entries).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            status.errorMessage = "Log export failed: \(error)"
        }
    }

    /// One `timestamp level tag: message` line per entry; a simulator's
    /// event names its subsystem after the process
    /// (`timestamp level tag (subsystem): message`).
    static func logcatExportText(_ entries: [LogcatEntry]) -> String {
        entries
            .map { entry in
                let source = entry.subsystem.isEmpty ? entry.tag : "\(entry.tag) (\(entry.subsystem))"
                return "\(entry.timestamp) \(entry.level.rawValue) \(source): \(entry.message)"
            }
            .joined(separator: "\n")
    }
}
