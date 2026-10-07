import Foundation
import DeviceHubProKit

/// One installed app a physical iPhone's log pane can launch.
struct PhysicalLogApp: Identifiable, Equatable, Sendable {
    let bundleID: String
    let title: String

    var id: String { bundleID }
}

/// Where a physical iPhone's log pane is: the
/// app is chosen, launched and streamed, and stopping ends the app's session.
enum PhysicalLogPhase: Equatable {
    /// Waiting for the user to pick an app and press Launch & Stream.
    case idle
    /// The installed apps are being read.
    case loadingApps
    /// The phone cannot be used (not enabled, paired and connected).
    case unavailable
    /// `bundleID` runs under devicectl's console; its lines stream in.
    case streaming(bundleID: String)
    /// The session ended on its own (the app quit or crashed, the phone went
    /// away, the launch failed); the lines stay on screen.
    case ended(reason: String)

    var isStreaming: Bool {
        if case .streaming = self { return true }
        return false
    }
}

/// The wording of a physical iPhone's log pane, pure so the states are pinned
/// by tests.
enum PhysicalLogPane {
    /// The small footnote under the controls.
    static let footnote = "Only the launched app's output shows here. A physical iPhone's system log is not available through public tools. Levels and subsystems are not reported, so every line shows as Info."

    /// The status line beside the controls.
    static func statusText(phase: PhysicalLogPhase, appTitle: String?) -> String {
        switch phase {
        case .idle: return "Choose an app to launch"
        case .loadingApps: return "Reading the apps…"
        case .unavailable: return "This iPhone is not enabled or not connected"
        case .streaming(let bundleID): return "Streaming \(appTitle ?? bundleID)"
        case .ended: return "Session ended"
        }
    }

    /// The button's title: Launch & Stream, or Stop while streaming.
    static func actionTitle(for phase: PhysicalLogPhase) -> String {
        phase.isStreaming ? "Stop" : "Launch & Stream"
    }

    /// What Stop does, for the help text and the accessibility hint.
    static let stopHelp = "Stop ends the app session: the app is closed on the iPhone"

    /// Whether the action button is enabled: Stop always, Launch & Stream
    /// once an app is chosen and the phone is usable.
    static func canAct(phase: PhysicalLogPhase, selectedBundle: String?) -> Bool {
        switch phase {
        case .streaming: return true
        case .loadingApps, .unavailable: return false
        case .idle, .ended: return selectedBundle?.isEmpty == false
        }
    }
}

extension LogcatController {
    /// Shows `udid`'s log pane: reads its installed apps for the picker and
    /// launches nothing. Replaces whatever streamed before.
    func openPhysicalLog(udid: String) async {
        stopLogcat()
        logcatWasStopped = false
        physicalLogUDID = udid
        physicalLogPhase = .loadingApps
        logcatEntries = []
        selectedLogcatPackage = nil
        physicalSelectedBundle = nil
        logcatSearch = ""

        let generation = beginPhysicalLoad()
        guard let client = await physicalClientSource(udid) else {
            if physicalLoadIsCurrent(generation) { physicalLogPhase = .unavailable }
            return
        }
        let apps = await readPhysicalApps(client: client)
        guard physicalLoadIsCurrent(generation) else { return }
        if let apps {
            physicalLogApps = apps
            physicalLogPhase = .idle
        } else {
            // The list could not be read (cancelled reads do not get here):
            // the pane says so, and the refresh below keeps trying.
            physicalLogPhase = .unavailable
        }
        startPhysicalAppRefresh(udid: udid, generation: generation)
    }

    /// The phone's apps for the picker, or nil when devicectl could not list
    /// them. Unstructured, so a caller's cancellation cannot empty the list.
    private func readPhysicalApps(client: DevicectlPhysicalClient) async -> [PhysicalLogApp]? {
        let listed = await Task { try? await client.apps() }.value
        guard let listed else { return nil }
        return listed.value.apps
            .map { PhysicalApp($0) }
            .map { PhysicalLogApp(bundleID: $0.bundleIdentifier, title: $0.title) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Reads the phone's apps again every `packageRefreshInterval` while its
    /// pane is open and no app streams: an app installed meanwhile reaches the
    /// picker, and a first read that failed recovers. A failed re-read keeps
    /// the list; it only marks the pane unavailable while there is none.
    private func startPhysicalAppRefresh(udid: String, generation: UInt64) {
        logcatPackagesTask?.cancel()
        let interval = packageRefreshInterval
        logcatPackagesTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self,
                      self.physicalLoadIsCurrent(generation), self.physicalLogUDID == udid
                else { continue }
                if self.physicalLogPhase.isStreaming { continue }
                guard let client = await self.physicalClientSource(udid) else { continue }
                let apps = await self.readPhysicalApps(client: client)
                guard self.physicalLoadIsCurrent(generation), self.physicalLogUDID == udid,
                      !self.physicalLogPhase.isStreaming
                else { continue }
                if let apps {
                    if apps != self.physicalLogApps { self.physicalLogApps = apps }
                    if case .unavailable = self.physicalLogPhase { self.physicalLogPhase = .idle }
                }
            }
        }
    }

    /// Opens the physical pane for `udid` unless it already shows it; like the
    /// other `…IfNeeded` opens, not tied to the calling view.
    func openPhysicalLogIfNeeded(udid: String) {
        guard physicalLogUDID != udid else { return }
        Task { await openPhysicalLog(udid: udid) }
    }

    /// Launches `bundleID` on the pane's phone under devicectl's console and
    /// streams its output, replacing a running session (`--terminate-existing`
    /// also ends a copy the user started). Needs the pane open.
    func launchPhysicalApp(bundleID: String) async {
        guard let udid = physicalLogUDID else { return }
        physicalLogStream?.stop()
        physicalLogStream = nil
        logcatPollTask?.cancel()
        logcatEntries = []
        logcatPaused = false
        physicalLogCursor = 0
        physicalSelectedBundle = bundleID
        guard let client = await physicalClientSource(udid), physicalLogUDID == udid else {
            physicalLogPhase = .unavailable
            return
        }
        do {
            let stream = try PhysicalConsoleLogStream(client: client, bundleID: bundleID)
            physicalLogStream = stream
            physicalLogPhase = .streaming(bundleID: bundleID)
            stream.start()
            startLogcatPolling()
        } catch {
            physicalLogPhase = .ended(reason: "\(error)")
        }
    }

    /// Ends the app session: devicectl gets SIGINT, forwards it to the app,
    /// and exits. The lines stay on screen.
    func stopPhysicalStream() {
        guard physicalLogStream != nil else {
            if case .ended = physicalLogPhase { physicalLogPhase = .idle }
            return
        }
        physicalLogStream?.stop()
        physicalLogStream = nil
        logcatPollTask?.cancel()
        logcatPollTask = nil
        logcatStatusText = ""
        physicalLogPhase = .idle
    }

    /// Ends the physical pane once nothing shows it (another selection, Log
    /// focus left): the app session ends with it, and the next time the pane
    /// shows the phone it opens again.
    func closePhysicalLog() {
        guard physicalLogUDID != nil else { return }
        stopLogcat()
        logcatWasStopped = false
    }

    /// Whether devicectl's console runs, for the teardown and its tests.
    var isPhysicalStreaming: Bool { physicalLogStream != nil }

    /// The teardown `stopLogcat` runs: the stream's devicectl is told to
    /// stop, and the pane forgets the phone.
    func endPhysicalLog() {
        physicalLogStream?.stop()
        physicalLogStream = nil
        physicalLogCursor = 0
        physicalLogUDID = nil
        physicalLogApps = []
        physicalSelectedBundle = nil
        physicalLogPhase = .idle
        physicalLoadGeneration &+= 1
    }

    /// One poll of the console: the lines since the last poll, and the end of
    /// the session when devicectl exited by itself.
    func pollPhysicalLog() {
        guard let stream = physicalLogStream else { return }
        if !logcatPaused {
            let fresh = stream.entries(after: physicalLogCursor)
            if let newest = fresh.last {
                physicalLogCursor = newest.id
                logcatEntries = Self.simulatorLogWindow(logcatEntries, adding: fresh)
            }
        }
        if case .stopped(let reason) = stream.status {
            // Read once more so the lines devicectl printed last show.
            let fresh = stream.entries(after: physicalLogCursor)
            if let newest = fresh.last {
                physicalLogCursor = newest.id
                logcatEntries = Self.simulatorLogWindow(logcatEntries, adding: fresh)
            }
            physicalLogStream = nil
            logcatPollTask?.cancel()
            logcatPollTask = nil
            logcatStatusText = ""
            physicalLogPhase = .ended(reason: reason)
        } else {
            let title = physicalLogApps.first { $0.bundleID == physicalSelectedBundle }?.title
            logcatStatusText = PhysicalLogPane.statusText(phase: physicalLogPhase, appTitle: title)
        }
    }

    private func beginPhysicalLoad() -> UInt64 {
        physicalLoadGeneration &+= 1
        return physicalLoadGeneration
    }

    private func physicalLoadIsCurrent(_ generation: UInt64) -> Bool {
        physicalLoadGeneration == generation
    }
}
