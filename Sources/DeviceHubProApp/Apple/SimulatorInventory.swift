import Foundation
import Observation
import DeviceHubProKit

/// The simulators of one device set — the user's default set in the app,
/// the one Xcode and Device Hub list — and what this Mac's Xcode offers for
/// them.
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
    /// The foldable device types among those read (iPhone Duo), by device
    /// type identifier: their two panels and the inner panel's own chrome
    /// and display (the outer panel's are `chromeFrames` and
    /// `displayShapes`, the device type's main display).
    private(set) var foldables: [String: SimulatorFoldable] = [:]
    /// The 3D models that failed to load in this run (`setDeviceModelUnusable`).
    private(set) var unusableDeviceModels: Set<URL> = []
    /// The fold Device Hub Pro last put each booted foldable simulator in,
    /// by UDID. A simulator boots closed, so one missing here is closed; a
    /// simulator that shuts down or boots again is forgotten. Kept in the
    /// preferences: a simulator stays as it was while the app quits and
    /// opens again.
    private(set) var folds: SimulatorFoldBook {
        didSet { if folds != oldValue { preferences.setSimulatorFolds(folds) } }
    }

    /// The toolchain the probe found; nil until it answered or without
    /// Apple tooling.
    @ObservationIgnored private(set) var toolchain: AppleToolchain?
    /// simctl on the set, once the probe found it usable.
    @ObservationIgnored private(set) var simctl: SimctlClient?
    /// The private bridge for the live canvas, made once the probe answered;
    /// nil keeps every simulator view-only.
    @ObservationIgnored private(set) var bridge: (any SimulatorBridging)?
    /// Sends foldable simulators' hinge angles through `bridge`; made with it.
    @ObservationIgnored var foldSender: SimulatorFoldSender? {
        // The one gate for the private path: the fold strip, Laptop and Tent,
        // and a foldable's rotate all send through this.
        guard let bridge, !SimulatorFold.isDisabled() else { return nil }
        if let made = madeFoldSender { return made }
        let sender = SimulatorFoldSender(bridge: bridge)
        madeFoldSender = sender
        return sender
    }
    @ObservationIgnored private var madeFoldSender: SimulatorFoldSender?

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
    /// Retries a failed catalog read on its own: right after a Mac starts,
    /// CoreSimulator can answer too slowly for the first read, and without
    /// the device types the stage has no Apple chrome or product art.
    @ObservationIgnored private var catalogRetry: Task<Void, Never>?
    /// Device types whose display was "read" before the catalog named their
    /// bundle; forgotten when it lands, so their chrome is read then.
    @ObservationIgnored private var shapesReadWithoutCatalog: Set<String> = []
    /// The waits between catalog retries. Settable for tests.
    @ObservationIgnored var catalogRetryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(10), .seconds(20), .seconds(30)]
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
        folds = preferences.simulatorFolds
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
        if litPanel(of: entry) == .inner, let inner = foldables[identifier] { return inner.innerShape }
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
        if litPanel(of: entry) == .inner, let inner = foldables[identifier] { return inner.innerChrome }
        return chromeFrames[identifier] ?? nil
    }

    /// A foldable `entry`'s outer panel display (its device type's own),
    /// whichever panel is lit.
    func outerDisplayShape(for entry: SimulatorEntry) -> DisplayShape? {
        entry.deviceTypeIdentifier.flatMap { displayShapes[$0] ?? nil }
    }

    /// A foldable `entry`'s outer panel chrome (its device type's own),
    /// whichever panel is lit: the closed device's 2D frame, which its
    /// front-on 3D model is sized to.
    func outerChromeFrame(for entry: SimulatorEntry) -> AppleChromeFrame? {
        entry.deviceTypeIdentifier.flatMap { chromeFrames[$0] ?? nil }
    }

    // MARK: - A foldable's panels

    /// `entry`'s two panels when its device type is a foldable whose
    /// display was read; nil otherwise.
    func foldPanels(for entry: SimulatorEntry) -> SimulatorFoldPanels? {
        entry.deviceTypeIdentifier.flatMap { foldables[$0]?.panels }
    }

    /// The panel a foldable `entry` shows: the inner one only after Device
    /// Hub Pro opened it past `SimulatorFold.innerPanelAbove`.
    func litPanel(of entry: SimulatorEntry) -> SimulatorFoldPanel {
        guard foldPanels(for: entry) != nil else { return .outer }
        return folds.record(of: entry.udid).panel
    }

    /// The screen ID simctl's screenshots and recordings of `udid` name
    /// (`--display`): the lit panel of a foldable; nil for every other
    /// device, whose main display simctl captures by itself.
    func captureDisplay(udid: String) -> UInt32? {
        guard let entry = entry(udid: udid), let panels = foldPanels(for: entry) else { return nil }
        return panels.profile(of: litPanel(of: entry)).screenID
    }

    /// The 3D model of `entry`'s device type, when Xcode ships one that has
    /// not failed to load (`AppleDeviceModel.locate`).
    func deviceModel(for entry: SimulatorEntry) -> AppleDeviceModel? {
        guard let model = entry.deviceTypeIdentifier.flatMap({ foldables[$0]?.model }),
              !unusableDeviceModels.contains(model.url)
        else { return nil }
        return model
    }

    /// The 3D stage could not show `model` (it did not load with the shape
    /// the scene needs): the stage and the fold strip go back to the 2D
    /// chrome for the rest of the run.
    func setDeviceModelUnusable(_ model: AppleDeviceModel) {
        unusableDeviceModels.insert(model.url)
    }

    /// `productClass` of a device type's `profile.plist` ("V68").
    nonisolated static func productClass(ofDeviceType bundle: URL) -> String? {
        let url = bundle.appendingPathComponent("Contents/Resources/profile.plist")
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return root["productClass"] as? String
    }

    /// The panel `entry`'s live session mirrors and touches.
    func sessionPanel(for entry: SimulatorEntry) -> SimulatorSessionPanel {
        guard let panels = foldPanels(for: entry) else { return .main }
        return .foldable(litPanel(of: entry), of: panels)
    }

    /// Records the hinge at `angle` for the foldable `udid`; returns whether
    /// the lit panel changed (the session then has to follow it).
    @discardableResult
    func noteFold(udid: String, angle: Double) -> Bool {
        folds.note(udid: udid, angle: angle, bootedAt: bootTime(of: udid))
    }

    /// Records the foldable `udid` held at `pose`.
    func noteFold(udid: String, pose: SimulatorDevicePose) {
        folds.note(udid: udid, pose: pose, bootedAt: bootTime(of: udid))
    }

    /// When the listing says `udid` booted (`SimulatorFoldBook`).
    private func bootTime(of udid: String) -> Date? {
        listedDevices.first { $0.udid == udid && $0.state == .booted }?.lastUsedAt
    }

    /// How `entry`'s foldable is posed on the stage, in counter-clockwise
    /// quarter turns (`AppleChromePose`): the lit panel's resting turn (iPhone
    /// Duo's open panel rests a quarter round) plus the turn it is held at.
    /// Nil for any other device, and before its panels are read.
    func foldPoseTurns(of entry: SimulatorEntry) -> Int? {
        guard let panels = foldPanels(for: entry) else { return nil }
        let resting = AppleChromePose.turns(for: SimulatorFold.restingRotation(of: panels.profile(of: litPanel(of: entry))))
        let held = AppleChromePose.turns(for: folds.record(of: entry.udid).orientation)
        return (resting + held) % 4
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
            // No catalog yet: the vector body for now, read again once the
            // catalog lands (`forgetShapesReadWithoutCatalog`).
            displayShapes[identifier] = .some(nil)
            chromeFrames[identifier] = .some(nil)
            shapesReadWithoutCatalog.insert(identifier)
            return
        }
        let deviceKit = apple?.deviceKit
        let developerDir = toolchain?.developerDirectory
        let (shape, chrome, foldable) = await Task.detached(priority: .userInitiated) {
            () -> (DisplayShape?, AppleChromeFrame?, SimulatorFoldable?) in
            let bundle = URL(fileURLWithPath: bundlePath, isDirectory: true)
            guard let profile = SimulatorDisplayProfile.read(deviceTypeBundle: bundle) else { return (nil, nil, nil) }
            func chrome(_ display: SimulatorDisplayProfile) -> AppleChromeFrame? {
                deviceKit.flatMap { AppleChromeFrameProvider(deviceKit: $0).frame(deviceTypeBundle: bundle, display: display) }
            }
            let foldable = SimulatorFoldPanels(panels: SimulatorDisplayProfile.readPanels(deviceTypeBundle: bundle)).map {
                SimulatorFoldable(
                    panels: $0,
                    innerChrome: chrome($0.inner),
                    innerShape: $0.inner.displayShape(id: "simulator:\(identifier):inner"),
                    model: Self.productClass(ofDeviceType: bundle).flatMap { productClass in
                        developerDir.flatMap { AppleDeviceModel.locate(productClass: productClass, developerDir: $0) }
                    }
                )
            }
            return (profile.displayShape(id: "simulator:\(identifier)"), chrome(profile), foldable)
        }.value
        if let foldable { foldables[identifier] = foldable }
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
        catalogRetry?.cancel()
        catalogRetry = nil
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
        if listedDeviceTypes != nil { forgetShapesReadWithoutCatalog() }
        if hasListed {
            apply(listedDevices)
        }
        if !catalogLoaded { scheduleCatalogRetry(simctl) }
    }

    /// Reads again, now with their bundles, the device types whose display
    /// was "read" before the catalog named a bundle; the views watching
    /// `displayShapes` / `chromeFrames` then draw the chrome.
    private func forgetShapesReadWithoutCatalog() {
        let pending = shapesReadWithoutCatalog
        shapesReadWithoutCatalog = []
        for identifier in pending {
            displayShapes[identifier] = nil
            chromeFrames[identifier] = nil
            guard let type = deviceTypes.first(where: { $0.identifier == identifier }) else { continue }
            Task { [weak self] in
                await self?.loadDisplayShape(identifier: identifier, bundlePath: type.bundlePath)
            }
        }
    }

    /// Reads the catalogs again after each of `catalogRetryDelays` until a
    /// read succeeds; one retry loop at a time.
    private func scheduleCatalogRetry(_ simctl: SimctlClient) {
        guard catalogRetry == nil, !isStopped else { return }
        let delays = catalogRetryDelays
        catalogRetry = Task { [weak self] in
            for delay in delays {
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled, !self.isStopped, !self.catalogLoaded else { break }
                await self.loadCatalogOnce(simctl)
            }
            self?.catalogRetry = nil
        }
    }

    private func loadCatalogOnce(_ simctl: SimctlClient) async {
        async let runtimeList = simctl.listRuntimes()
        async let deviceTypeList = simctl.listDeviceTypes()
        let listedRuntimes = try? await runtimeList
        let listedDeviceTypes = try? await deviceTypeList
        if let listedRuntimes {
            runtimes = listedRuntimes
            runtimesRead = true
        }
        if let listedDeviceTypes { deviceTypes = listedDeviceTypes }
        catalogLoaded = listedRuntimes != nil && listedDeviceTypes != nil
        if listedDeviceTypes != nil { forgetShapesReadWithoutCatalog() }
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
        // Before the entries: a fold kept from an earlier boot (or an earlier
        // run of the app) never reaches the stage.
        let booted = Dictionary(
            devices.filter { $0.state == .booted }.map { ($0.udid, $0.lastUsedAt) },
            uniquingKeysWith: { first, _ in first }
        )
        let recorded = Set(folds.records.keys)
        folds.keep(only: booted)
        // Their input channels too: a reboot starts a new connection.
        for udid in recorded.subtracting(folds.records.keys) {
            madeFoldSender?.forget(SimulatorAddress(udid: udid, deviceSetPath: deviceSet?.path))
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

/// A foldable device type's panels, with the inner panel's own chrome and
/// display (read from the device type like the main ones).
struct SimulatorFoldable: Equatable {
    let panels: SimulatorFoldPanels
    let innerChrome: AppleChromeFrame?
    let innerShape: DisplayShape?
    /// Its 3D model in the user's Xcode, when it ships one
    /// (`AppleDeviceModel.locate`).
    let model: AppleDeviceModel?
}
