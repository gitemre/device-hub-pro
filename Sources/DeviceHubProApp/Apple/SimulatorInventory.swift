import Foundation
import Observation
import DeviceHubProKit

/// The simulators of one device set — the user's default set in the app,
/// the one Xcode and Device Hub list — and what this Mac's Xcode offers for
/// them (§3.7).
///
/// It runs `SimulatorWatcher` on the set (FSEvents on the set folder, a
/// debounced `simctl list -j devices`, a 5 s safety poll) and publishes
/// every listed device with its runtime's and device type's names
/// (`SimulatorEntry`). Like Device Hub it hides the devices CoreSimulator
/// created by itself until they are first used (`isUnusedDefault`) and those
/// whose OS is older than iOS 17 (`isTooOld`).
///
/// Nothing runs until the first `refresh()` (the model's refresh): it probes
/// Xcode once, off the launch path, builds the simctl client and starts the
/// watcher. Without Apple tooling (`AppEnvironment.apple` nil, as in tests)
/// it stays empty at T0 and never runs a process.
///
/// It holds no reference to the model: `AppModel` owns it as `simulators`,
/// and what follows a list change (the lifecycle's view of the boots, the
/// selection fix-up) goes through `listChanged`, which the model sets.
@MainActor
@Observable
final class SimulatorInventory {
    /// Every device of the last listing, in simctl's order (runtime, name,
    /// UDID), hidden ones included.
    private(set) var simulators: [SimulatorEntry] = []
    /// Whether a listing has arrived since the provider started.
    private(set) var hasListed = false
    /// The tier and the setup card's text.
    private(set) var tooling: AppleToolingStatus
    /// The watcher's trouble, if any: the list keeps failing (the last one
    /// stands), or changes surface only with the 5 s poll.
    private(set) var watcherHealth: SimulatorWatcherHealth?
    /// The installed runtimes, for the names and the create sheet.
    private(set) var runtimes: [SimulatorRuntime] = []
    /// Whether the runtime listing was read (an empty one is an answer: Xcode
    /// without a downloaded platform).
    private(set) var runtimesRead = false
    /// Every device type Xcode ships.
    private(set) var deviceTypes: [SimulatorDeviceType] = []
    /// devicectl's answer for a listed default-set simulator (T2), asked
    /// once per CoreDevice version and kept in the preferences.
    private(set) var devicectlProbe: DevicectlInfo?
    /// The simulators whose live canvas passed its smoke check (T3); set by
    /// the canvas, per simulator.
    private(set) var canvasReadyUDIDs: Set<String> = []
    /// Whether any simulator's live canvas is ready.
    var canvasReady: Bool { !canvasReadyUDIDs.isEmpty }

    /// The display of each device type the stage has drawn, by device type
    /// identifier, from its `capabilities.plist` (`SimulatorDisplayProfile`),
    /// read at runtime from the user's Xcode and never kept on disk. A
    /// device type whose plist has no usable display maps to nil.
    private(set) var displayShapes: [String: DisplayShape?] = [:]
    /// The Apple chrome of each device type the stage has drawn, by device
    /// type identifier (`AppleChromeFrameProvider`: the chrome its display
    /// names, read at runtime from Xcode's DeviceKit and never kept on
    /// disk), read with its display; nil for a device type without one (an
    /// Apple TV), without DeviceKit, or without Apple tooling.
    private(set) var chromeFrames: [String: AppleChromeFrame?] = [:]

    /// The toolchain the probe found; nil until it answered or without
    /// Apple tooling.
    @ObservationIgnored private(set) var toolchain: AppleToolchain?
    /// simctl on the set, once the probe found it usable.
    @ObservationIgnored private(set) var simctl: SimctlClient?
    /// The private bridge for the live canvas, made once the probe answered;
    /// nil keeps every simulator view-only.
    @ObservationIgnored private(set) var bridge: (any SimulatorBridging)?

    /// A list change: the listing or the catalogs.
    /// Its owner re-reads `simulators`/`visibleSimulators` from here.
    @ObservationIgnored var listChanged: @MainActor () -> Void = {}

    @ObservationIgnored private let apple: AppleTooling?
    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private var probeTask: Task<AppleToolchain, Never>?
    @ObservationIgnored private var watcher: SimulatorWatcher?
    @ObservationIgnored private var watching: Task<Void, Never>?
    /// The last listing's devices, re-read into entries when the catalogs
    /// land after it.
    @ObservationIgnored private var listedDevices: [SimulatorDevice] = []
    /// Whether both catalogs were read: once per provider start, whatever
    /// they hold (a Mac with Xcode but no runtime downloaded lists none, and
    /// must not list them again on every refresh). A failed read is tried
    /// again on the next refresh.
    @ObservationIgnored private var catalogLoaded = false
    /// Set for good by `stop()` (quit): a refresh still waiting on the probe
    /// or on simctl then starts nothing and applies nothing.
    @ObservationIgnored private var isStopped = false
    /// How many times devicectl was asked about each simulator in this run
    /// without a definitive answer: a failed or raced probe is asked again,
    /// up to `maxDevicectlAttempts` times.
    @ObservationIgnored private var devicectlAttempts: [String: Int] = [:]
    static let maxDevicectlAttempts = 3
    /// The devicectl probe in flight: later callers await it instead of
    /// being told "not ready" while it runs.
    @ObservationIgnored private var devicectlProbeTask: Task<Bool, Never>?

    init(apple: AppleTooling?, preferences: AppPreferences) {
        self.apple = apple
        self.preferences = preferences
        tooling = apple == nil ? .unavailable : .probing
    }

    // MARK: - Reading

    /// The simulators the sidebar lists: all but those Device Hub hides
    /// (the never-used default ones and those older than iOS 17,
    /// `isHiddenByDefault`). Device Hub has no switch to list them, so
    /// neither does the sidebar.
    var visibleSimulators: [SimulatorEntry] {
        simulators.filter { !$0.isHiddenByDefault }
    }

    /// The listed simulator with `udid`, hidden or not.
    func entry(udid: String) -> SimulatorEntry? {
        simulators.first { $0.udid == udid }
    }

    /// Where a deleted device's log folder is removed from.
    var logsDirectory: URL? { apple?.logsDirectory }

    /// Where crash reports are read from (`AppleTooling`); nil lists none.
    var diagnosticReportsDirectory: URL? { apple?.diagnosticReportsDirectory }

    /// The set's device set folder for simctl's `--set` and the bridge: nil
    /// for the default set.
    var deviceSet: URL? { apple?.deviceSet }

    /// The device's own folder in the set (`<set>/<UDID>`): Show in Finder.
    func deviceFolder(udid: String) -> URL? {
        guard let apple, UUID(uuidString: udid) != nil else { return nil }
        return apple.devicesDirectory.appendingPathComponent(udid, isDirectory: true)
    }

    /// Whether the bridge may load on this Mac's CoreSimulator; `.disabled`
    /// without Apple tooling.
    func bridgeVerdict() -> BridgeCompatibility.Verdict {
        apple?.bridgeVerdict() ?? .disabled
    }

    /// Whether an Xcode update replaced the CoreSimulator the live canvas
    /// loaded: no new live session until the app relaunches.
    func bridgeIsStale() -> Bool {
        apple?.bridgeIsStale() ?? false
    }

    /// The display the vector body of `entry` is planned from: its device
    /// type's, once `loadDisplayShape(for:)` read it; nil before and when the
    /// device type declares none.
    func displayShape(for entry: SimulatorEntry) -> DisplayShape? {
        guard let identifier = entry.deviceTypeIdentifier else { return nil }
        return displayShapes[identifier] ?? nil
    }

    /// Whether `entry`'s display was read (with or without a result).
    func hasReadDisplayShape(for entry: SimulatorEntry) -> Bool {
        guard let identifier = entry.deviceTypeIdentifier else { return true }
        return displayShapes.keys.contains(identifier)
    }

    /// The Apple chrome `entry` is drawn in, once `loadDisplayShape(for:)`
    /// read it; nil before, and when its device type has none.
    func chromeFrame(for entry: SimulatorEntry) -> AppleChromeFrame? {
        guard let identifier = entry.deviceTypeIdentifier else { return nil }
        return chromeFrames[identifier] ?? nil
    }

    /// Reads `entry`'s device type display, and the Apple chrome it names,
    /// off the main thread, once per device type. Both are set together, so
    /// a view never draws the vector body first and the chrome a moment
    /// later.
    func loadDisplayShape(for entry: SimulatorEntry) async {
        guard let identifier = entry.deviceTypeIdentifier else { return }
        await loadDisplayShape(identifier: identifier, bundlePath: entry.deviceTypeBundlePath)
    }

    private func loadDisplayShape(identifier: String, bundlePath: String?) async {
        guard !displayShapes.keys.contains(identifier) else { return }
        guard let bundlePath else {
            displayShapes[identifier] = .some(nil)
            chromeFrames[identifier] = .some(nil)
            return
        }
        let deviceKit = apple?.deviceKit
        let (shape, chrome) = await Task.detached(priority: .userInitiated) { () -> (DisplayShape?, AppleChromeFrame?) in
            let bundle = URL(fileURLWithPath: bundlePath, isDirectory: true)
            guard let profile = SimulatorDisplayProfile.read(deviceTypeBundle: bundle) else { return (nil, nil) }
            let chrome = deviceKit.flatMap {
                AppleChromeFrameProvider(deviceKit: $0).frame(deviceTypeBundle: bundle, display: profile)
            }
            return (profile.displayShape(id: "simulator:\(identifier)"), chrome)
        }.value
        chromeFrames[identifier] = .some(chrome)
        displayShapes[identifier] = .some(shape)
    }

    // MARK: - A device type's chrome, for the catalog

    /// Whether the catalog's read of `type` (display and Apple chrome) is
    /// done, with or without a result.
    func hasReadDisplayShape(forDeviceType type: SimulatorDeviceType) -> Bool {
        displayShapes.keys.contains(type.identifier)
    }

    /// The display of a device type, once `loadDisplayShape(forDeviceType:)`
    /// read it; nil before and when it declares none.
    func displayShape(forDeviceType type: SimulatorDeviceType) -> DisplayShape? {
        displayShapes[type.identifier] ?? nil
    }

    /// The Apple chrome of a device type, once read; nil before and when it
    /// has none (Apple TV) or DeviceKit is missing.
    func chromeFrame(forDeviceType type: SimulatorDeviceType) -> AppleChromeFrame? {
        chromeFrames[type.identifier] ?? nil
    }

    /// Reads a device type's display and Apple chrome off the main thread,
    /// once per device type, for the Browse Catalog's cards.
    func loadDisplayShape(forDeviceType type: SimulatorDeviceType) async {
        await loadDisplayShape(identifier: type.identifier, bundlePath: type.bundlePath)
    }

    // MARK: - A physical device's chrome, by model identifier

    /// The device type of a physical iPhone's or iPad's model identifier
    /// ("iPhone13,2"), the one whose Apple chrome and display the live
    /// stage draws the phone in; nil when Xcode ships none for it.
    func deviceType(forModelIdentifier model: String?) -> SimulatorDeviceType? {
        guard let model, !model.isEmpty else { return nil }
        return deviceTypes
            .filter { $0.modelIdentifier == model }
            .min { $0.identifier < $1.identifier }
    }

    /// The Apple chrome for a physical device's model identifier, once
    /// `loadDisplayShape(forModelIdentifier:)` read it.
    func chromeFrame(forModelIdentifier model: String?) -> AppleChromeFrame? {
        guard let identifier = deviceType(forModelIdentifier: model)?.identifier else { return nil }
        return chromeFrames[identifier] ?? nil
    }

    /// The display for a physical device's model identifier, once read.
    func displayShape(forModelIdentifier model: String?) -> DisplayShape? {
        guard let identifier = deviceType(forModelIdentifier: model)?.identifier else { return nil }
        return displayShapes[identifier] ?? nil
    }

    /// Reads the chrome and display of the device type matching a physical
    /// device's model identifier, like `loadDisplayShape(for:)`.
    func loadDisplayShape(forModelIdentifier model: String?) async {
        guard let type = deviceType(forModelIdentifier: model) else { return }
        await loadDisplayShape(identifier: type.identifier, bundlePath: type.bundlePath)
    }

    /// Whether this inventory lists a private set, which CoreDevice (and so
    /// devicectl) cannot see.
    var isPrivateSet: Bool { apple?.deviceSet != nil }

    // MARK: - Provider

    /// Starts the provider on its first call (the probe, the catalogs, the
    /// watcher), then reads the list now, as a manual refresh does. Without
    /// Apple tooling, without a usable simctl, or once stopped, it does
    /// nothing.
    func refresh() async {
        guard !isStopped, let simctl = await prepare(), !isStopped else { return }
        startWatching(simctl)
        if !catalogLoaded {
            await loadCatalog(simctl)
        }
        await reloadList()
    }

    /// The toolchain once the Xcode probe answered (started here when it has
    /// not run yet, and shared with the refresh: the probe runs once). The
    /// physical-device inventory asks for its devicectl here. Nil without
    /// Apple tooling.
    func probedToolchain() async -> AppleToolchain? {
        _ = await prepare()
        return toolchain
    }

    /// Probes again when the last probe found Xcode not set up (not
    /// installed, not selected, or its first launch not done), so that
    /// opening Xcode once, or installing it, is noticed when the app becomes
    /// active again. The probe only reads files, so it is cheap. Returns true
    /// when simctl became usable (the caller refreshes the lists). Does
    /// nothing while the first probe has not answered or once simctl was
    /// usable.
    func recheckSetupIfPending() async -> Bool {
        guard !isStopped, let apple, let previous = toolchain, !previous.simctlUsable else { return false }
        let fresh = await Task.detached { await apple.probe() }.value
        guard !isStopped, fresh.simctlUsable else {
            if fresh != previous {
                toolchain = fresh
                updateTooling()
            }
            return false
        }
        toolchain = fresh
        simctl = fresh.makeSimctlClient(deviceSet: apple.deviceSet)
        bridge = apple.makeBridge(fresh)
        restoreDevicectlProbe(fresh)
        catalogLoaded = false
        updateTooling()
        return true
    }

    /// Reads the list once, now (after the app itself booted, shut down or
    /// deleted a device), without waiting for the watcher. A failed read
    /// keeps the last list: an empty one would read as "every simulator
    /// deleted".
    func reloadList() async {
        guard let simctl, !isStopped else { return }
        // Best effort: the watcher reports a list that keeps failing.
        guard let devices = try? await simctl.listDevices() else { return }
        apply(devices)
    }

    /// Stops the watcher for good (quit hygiene): a refresh that was waiting
    /// on the probe or on simctl, or that comes later, starts nothing.
    func stop() {
        isStopped = true
        watching?.cancel()
        watching = nil
        watcher?.stop()
        watcher = nil
    }

    /// Whether devicectl answers for this set's simulators (T2, never in a
    /// private set): the devicectl-backed paths (the view-only canvas's
    /// rotation) are on.
    var devicectlReady: Bool {
        guard !isPrivateSet, toolchain?.devicectlUsable == true, let devicectlProbe else { return false }
        return devicectlProbe.succeeded && devicectlProbe.jsonVersion >= AppleToolchain.minimumDevicectlJSONVersion
    }

    /// Asks devicectl about one listed simulator of the default set (`device
    /// info details`) and records its answer: T2. Nothing is
    /// asked in a private set, which CoreDevice cannot see, or for a device
    /// the listing does not show. An answer is kept in the preferences under
    /// the installed CoreDevice version, so a later launch is T2 without
    /// asking (`restoreDevicectlProbe`).
    @discardableResult
    func probeDevicectl(udid: String) async -> Bool {
        guard !isPrivateSet,
              let toolchain,
              let entry = entry(udid: udid),
              // Best effort: an unusable devicectl is simply not T2.
              let client = try? toolchain.makeDevicectlClient(for: entry.device)
        else { return false }
        // Best effort: a devicectl that does not answer leaves the tier as it is.
        guard let answer = try? await client.details() else { return false }
        devicectlProbe = answer.info
        if let version = toolchain.devicectl.installedVersion {
            preferences.setSimulatorDevicectlProbe(CachedDevicectlProbe(coreDeviceVersion: version, info: answer.info))
        }
        updateTooling()
        return true
    }

    /// T2 for a simulator the user booted and selected (the stage asks as
    /// its session starts): asks devicectl once per CoreDevice version — not
    /// at all when the preferences hold an answer for the installed one, and
    /// at most once per simulator in a run while none has answered. Only a
    /// booted simulator is asked (`info details` is read-only); returns
    /// whether devicectl answers.
    @discardableResult
    func probeDevicectlIfNeeded(udid: String) async -> Bool {
        guard devicectlProbe == nil else { return devicectlReady }
        if let task = devicectlProbeTask { return await task.value }
        guard !isPrivateSet, toolchain?.devicectlUsable == true,
              entry(udid: udid)?.state == .booted,
              devicectlAttempts[udid, default: 0] < Self.maxDevicectlAttempts
        else { return false }
        let task = Task { [self] in
            await probeDevicectl(udid: udid)
            // Only a definitive answer (one was recorded) ends the asking.
            if devicectlProbe == nil { devicectlAttempts[udid, default: 0] += 1 }
            return devicectlReady
        }
        devicectlProbeTask = task
        let ready = await task.value
        devicectlProbeTask = nil
        return ready
    }

    /// Takes the kept devicectl answer when it was given by the installed
    /// CoreDevice (a CoreDevice update asks again; an override binary, whose
    /// version is unknown, always asks).
    private func restoreDevicectlProbe(_ toolchain: AppleToolchain) {
        guard devicectlProbe == nil, !isPrivateSet,
              let installed = toolchain.devicectl.installedVersion,
              let cached = preferences.simulatorDevicectlProbe,
              cached.coreDeviceVersion == installed
        else { return }
        devicectlProbe = cached.info
    }

    /// The live canvas of `udid` passed (or lost) its smoke check: T3
    /// while any simulator's canvas is ready; one window's
    /// failure does not turn off another's.
    func setCanvasReady(_ ready: Bool, udid: String) {
        if ready { canvasReadyUDIDs.insert(udid) } else { canvasReadyUDIDs.remove(udid) }
        updateTooling()
    }

    // MARK: - Internals

    /// Probes Xcode once and builds the simctl client; nil without Apple
    /// tooling or a usable simctl.
    private func prepare() async -> SimctlClient? {
        guard let apple else { return nil }
        if toolchain != nil { return simctl }
        let probe = probeTask ?? Task.detached { await apple.probe() }
        probeTask = probe
        let toolchain = await probe.value
        if self.toolchain == nil {
            self.toolchain = toolchain
            simctl = toolchain.makeSimctlClient(deviceSet: apple.deviceSet)
            bridge = apple.makeBridge(toolchain)
            restoreDevicectlProbe(toolchain)
            updateTooling()
        }
        return simctl
    }

    private func startWatching(_ simctl: SimctlClient) {
        guard watcher == nil, !isStopped, let apple else { return }
        let watcher = SimulatorWatcher(simctl: simctl, devicesDirectory: apple.devicesDirectory)
        let events = watcher.events()
        watching = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
        self.watcher = watcher
        watcher.start()
    }

    private func handle(_ event: SimulatorWatcherEvent) {
        guard !isStopped else { return }
        switch event {
        case .snapshot(let devices, let degraded):
            watcherHealth = degraded ? .degraded : nil
            apply(devices)
        case .health(let health):
            watcherHealth = health
        }
    }

    private func loadCatalog(_ simctl: SimctlClient) async {
        async let runtimeList = simctl.listRuntimes()
        async let deviceTypeList = simctl.listDeviceTypes()
        // Best effort: without a catalog the names come from the identifiers
        // until a later refresh reads it.
        let listedRuntimes = try? await runtimeList
        let listedDeviceTypes = try? await deviceTypeList
        if let listedRuntimes {
            runtimes = listedRuntimes
            runtimesRead = true
        }
        if let listedDeviceTypes { deviceTypes = listedDeviceTypes }
        catalogLoaded = listedRuntimes != nil && listedDeviceTypes != nil
        if hasListed {
            apply(listedDevices)
        }
    }

    /// Turns a listing into entries: the names from the catalogs and the
    /// defaults from the set's `device_set.plist`.
    private func apply(_ devices: [SimulatorDevice]) {
        guard !isStopped else { return }
        listedDevices = devices
        let defaults = readDefaultDeviceUDIDs()
        let entries = devices.map {
            SimulatorEntry(device: $0, runtimes: runtimes, deviceTypes: deviceTypes, defaultDeviceUDIDs: defaults)
        }
        if entries != simulators {
            simulators = entries
        }
        hasListed = true
        listChanged()
    }

    private func readDefaultDeviceUDIDs() -> Set<String> {
        guard let apple,
              let data = FileManager.default.contents(
                  atPath: apple.devicesDirectory.appendingPathComponent("device_set.plist").path
              )
        else { return [] }
        return SimctlParsing.defaultDeviceUDIDs(fromDeviceSetPlist: data)
    }

    private func updateTooling() {
        guard let toolchain else { return }
        tooling = AppleToolingStatus(toolchain: toolchain, devicectlProbe: devicectlProbe, canvasReady: canvasReady)
    }
}
