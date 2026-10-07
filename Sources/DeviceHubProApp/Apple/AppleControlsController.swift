import Foundation
import Observation
import DeviceHubProKit

/// A simulator's Controls panel (Device Hub S20–S25): reads the
/// selected, ready simulator's settings and changes them through
/// `AppleControlsBackend` (devicectl at T2 where it can read back, else
/// simctl), and keeps what simctl cannot read back itself: the simulated
/// location (set again after each boot Device Hub Pro starts), the status bar
/// override, and the time zone those boots take. What it keeps per
/// simulator lives in the app-global `AppleDeviceMemory`, so every window's
/// panel over one simulator agrees.
///
/// The poll (`ControlsPoll`, every 2 s while the panel shows a ready
/// simulator) reads the host's global preferences file on every tick (no
/// spawn) and spends at most one process per tick (`AppleControlsPollPlan`):
/// one `devicectl info appearance` covers every appearance field. An attach
/// reads each row once, the one burst above that budget. A reading that
/// started before a write is dropped, so the poll never flips a row back.
///
/// Views call it directly (`model.appleControls`); `AppModel` wires the
/// lifecycle's boot and ready hooks to it.
@MainActor
@Observable
final class AppleControlsController {
    /// The simulator the panel reads, while it is attached.
    private(set) var udid: String?
    private(set) var state = AppleControlsState()
    /// Whether the attach's first reads have landed.
    private(set) var isLoaded = false
    /// Whether devicectl reaches this simulator (T2).
    private(set) var hasDevicectl = false
    /// The zone the running boot took (`SIMCTL_CHILD_TZ`): `.some(nil)` is
    /// the Mac's zone, nil not read yet.
    private(set) var bootTimeZone: String??
    /// Whether a status bar override is in place (`status_bar list`), nil
    /// until read.
    private(set) var statusBarActive: Bool?
    /// `simctl location list`'s scenarios.
    private(set) var locationScenarios: [String] = []
    /// The controls with a change in flight, per simulator
    /// (`AppleDeviceMemory.busyControls`).
    var busyControls: [String: Set<AppleControl>] { memory.busyControls }
    /// The simulators whose language changed since their last respring
    /// (`AppleDeviceMemory.respringPending`).
    var respringPending: Set<String> { memory.respringPending }
    /// The simulator's apps, for the App conditions' Target app.
    private(set) var apps: [SimulatorApp] = []
    private(set) var isLoadingApps = false
    /// What the last push did, under the Push notification row.
    private(set) var pushNote: String?
    /// What Device Hub Pro set as each simulator's location
    /// (`AppleDeviceMemory.locations`).
    var locations: [String: AppleLocationChoice] { memory.locations }
    /// Each simulator's status bar model (`AppleDeviceMemory.statusBars`).
    var statusBars: [String: SimulatorStatusBarState] { memory.statusBars }

    /// The app Push notification and Permissions act on.
    var targetBundle: String?
    var pushText = SimulatorPushPayload.template
    /// Called with the push simctl took, for the library's Resend Last.
    @ObservationIgnored var onPushSent: (@MainActor (SentPush) -> Void)?
    var permissionService: SimulatorPrivacyService = .photos
    /// The Links group's URL field.
    var linkDraft = ""

    @ObservationIgnored private let simulators: SimulatorInventory
    @ObservationIgnored private let preferences: AppPreferences
    /// What Device Hub Pro keeps per simulator, shared by every panel.
    @ObservationIgnored let memory: AppleDeviceMemory
    @ObservationIgnored private let status: StatusCenter
    @ObservationIgnored private var backend: AppleControlsBackend?
    /// The attached physical iPhone's backend, instead of `backend`.
    @ObservationIgnored private var physicalBackend: ApplePhysicalControlsBackend?
    @ObservationIgnored private var tick = 0
    /// How many unsupported features the physical backend had when the rows
    /// were last asked (`syncCapabilities`).
    @ObservationIgnored private var knownUnsupported = 0
    @ObservationIgnored private var writeGeneration = 0
    @ObservationIgnored private var attachGeneration = 0
    @ObservationIgnored private var lastAttachedUDID: String?

    /// Restarts a simulator (the lifecycle's Restart, which boots it with
    /// its time zone).
    @ObservationIgnored var restartSimulator: @MainActor (_ udid: String) async -> Void = { _ in }

    /// The client for a physical device (`ApplePhysicalInventory.client(for:)`,
    /// the only way the app reaches one): nil unless the device is listed,
    /// enabled, paired and connected. Wired by its owner.
    @ObservationIgnored var physicalClient: @MainActor (_ udid: String) async -> DevicectlPhysicalClient? = { _ in nil }

    /// Whether the attached device is a physical iPhone: its rows
    /// come from its CoreDevice capability list, and only the rows that
    /// mechanism reaches are offered.
    private(set) var isPhysical = false
    /// The attached device's family, which rows it can work
    /// (`ControlsRow.availability(on:)`); an iPhone until a simulator says otherwise.
    private(set) var family: ControlsFamily = .iPhone
    /// Why the attached physical device's Controls could not be read (its
    /// capability list did not answer), nil while they can.
    private(set) var physicalFailure: String?
    /// Bumped when a call answers CoreDevice 1001: the rows are asked again.
    private(set) var capabilityRevision = 0

    init(simulators: SimulatorInventory, preferences: AppPreferences, memory: AppleDeviceMemory, status: StatusCenter) {
        self.simulators = simulators
        self.preferences = preferences
        self.memory = memory
        self.status = status
    }

    // MARK: - Routing

    /// Where `control` goes on the attached device: on a simulator the
    /// mechanism its tier reaches, on a physical iPhone the one its
    /// capability list allows (`ApplePhysicalControlsBackend.route`).
    func route(_ control: AppleControl) -> AppleControlRoute {
        if isPhysical {
            // Reading the revision makes a row's disappearance after a 1001 observable.
            _ = capabilityRevision
            if let physicalBackend { return physicalBackend.route(control) }
            return AppleControlsRouting.physicalRoute(control, capabilities: ApplePhysicalControlsCapabilities(identifiers: []))
        }
        // A control none of whose rows the family shows is never offered, read or written.
        if let reason = family.unavailableReason(for: control) {
            return AppleControlRoute(control: control, mechanism: nil, support: .unavailable(reason))
        }
        var kinds = AppleControlsRouting.available(devicectl: hasDevicectl)
        // simctl ui answers "Runtime does not support …" for tvOS's appearance and contrast
        // (measured, tvOS 27.0): only devicectl can change them there.
        if family == .appleTV, control == .appearance || control == .increaseContrast { kinds.remove(.simctl) }
        return AppleControlsRouting.route(control, available: kinds)
    }

    /// A physical iPhone's grouped panel: the rows its CoreDevice capability
    /// list takes.
    var groups: [ControlsGroup] { appleControlsGroups(route: route, family: family) }

    /// A simulator's Device Hub cards: the rows this simulator can take
    /// (`osVersion` is its runtime's, for the colour filter).
    func simulatorCards(osVersion: String?) -> [[ControlsRow]] {
        appleSimulatorCards(route: route, colorFilterSupported: appleColorFilterSupported(osVersion: osVersion), family: family)
    }

    /// A simulator's added groups below Device Hub's cards (`appleSimulatorGroups`).
    func simulatorGroups() -> [AppleGroup] {
        appleSimulatorGroups(route: route, supportsBiometrics: state.supportsBiometrics, family: family)
    }

    /// A simulator's plain rows below the groups (`appleSimulatorPlainRows`).
    func simulatorPlainRows() -> [ControlsRow] {
        appleSimulatorPlainRows(route: route, family: family)
    }

    /// The rows a physical iPhone's panel leaves out and why (a simulator's
    /// panel is Device Hub's cards and carries no note).
    var hiddenRows: [(title: String, reason: String)] {
        isPhysical ? applePhysicalHiddenRows(route: route) : []
    }

    /// The backend the attached device's reads and writes go through.
    private var activeBacking: (any AppleControlsBacking)? {
        physicalBackend ?? backend
    }

    /// The attached simulator's controls with a change in flight.
    var busy: Set<AppleControl> { udid.flatMap { busyControls[$0] } ?? [] }

    func isBusy(_ control: AppleControl) -> Bool { busy.contains(control) }

    private func markBusy(_ control: AppleControl, on udid: String) {
        memory.markBusy(control, on: udid)
    }

    private func clearBusy(_ control: AppleControl, on udid: String) {
        memory.clearBusy(control, on: udid)
    }

    // MARK: - Attach and poll

    /// Starts reading `udid` (ready, selected): builds its backend (devicectl
    /// once T2 answered for it), then reads every row once. Returns the
    /// attach's token for `detach`.
    @discardableResult
    func attach(_ udid: String) async -> Int {
        cancelPendingBiometric()
        attachGeneration += 1
        let generation = attachGeneration
        if lastAttachedUDID != udid {
            // Another simulator's apps are not this one's.
            targetBundle = nil
            lastAttachedUDID = udid
        }
        self.udid = udid
        backend = nil
        physicalBackend = nil
        isPhysical = false
        physicalFailure = nil
        family = simulators.entry(udid: udid).map {
            ControlsFamily.simulator(platform: $0.platform, productFamily: $0.productFamily)
        } ?? .iPhone
        state = AppleControlsState()
        isLoaded = false
        hasDevicectl = false
        bootTimeZone = nil
        statusBarActive = nil
        pushNote = nil
        apps = []
        tick = 0
        guard let simctl = simulators.simctl, let entry = simulators.entry(udid: udid) else { return generation }
        // T2: devicectl is asked once per CoreDevice version (never for a
        // private set); the canvas's attach usually asked already.
        _ = await simulators.probeDevicectlIfNeeded(udid: udid)
        guard generation == attachGeneration else { return generation }
        var devicectl: DevicectlClient?
        if simulators.devicectlReady, let toolchain = simulators.toolchain {
            // Best effort: without a client the rows fall back to simctl or hide.
            devicectl = try? toolchain.makeDevicectlClient(for: entry.device)
        }
        let dataDirectory = entry.device.dataPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard let backend = try? AppleControlsBackend(
            udid: udid, simctl: simctl, devicectl: devicectl, dataDirectory: dataDirectory
        ) else { return generation }
        self.backend = backend
        hasDevicectl = backend.hasDevicectl
        readPreferences()
        await readEverything(backend, generation: generation)
        guard generation == attachGeneration else { return generation }
        isLoaded = true
        return generation
    }

    /// Starts reading a physical iPhone's Controls: asks the
    /// inventory for its client (nil unless the device is enabled, paired and
    /// connected), reads `details`' capability list once, builds the phone's
    /// backend from it and reads every offered row once. A phone that does
    /// not answer leaves `physicalFailure` and no rows. Returns the attach's
    /// token for `detach`.
    @discardableResult
    func attachPhysical(_ hardwareUDID: String) async -> Int {
        cancelPendingBiometric()
        attachGeneration += 1
        let generation = attachGeneration
        let key = PhysicalDeviceOptIn.normalize(hardwareUDID)
        if lastAttachedUDID != key {
            targetBundle = nil
            lastAttachedUDID = key
        }
        udid = key
        backend = nil
        physicalBackend = nil
        isPhysical = true
        family = .physicalApple
        physicalFailure = nil
        knownUnsupported = 0
        state = AppleControlsState()
        isLoaded = false
        hasDevicectl = false
        bootTimeZone = nil
        statusBarActive = nil
        pushNote = nil
        apps = []
        tick = 0
        guard let client = await physicalClient(key) else {
            guard generation == attachGeneration else { return generation }
            physicalFailure = "This device is not ready: enable it, connect and unlock it."
            isLoaded = true
            return generation
        }
        guard generation == attachGeneration else { return generation }
        let capabilities: ApplePhysicalControlsCapabilities
        do {
            capabilities = ApplePhysicalControlsCapabilities(details: try await client.details().value)
        } catch {
            guard generation == attachGeneration else { return generation }
            physicalFailure = "Could not read this device's capabilities: \(Self.describe(error))"
            isLoaded = true
            return generation
        }
        guard generation == attachGeneration else { return generation }
        let backend = ApplePhysicalControlsBackend(client: client, capabilities: capabilities)
        physicalBackend = backend
        hasDevicectl = true
        // One read after the other: each is a call over the phone's link.
        var readings: [AppleControlsReading] = []
        for read in backend.initialReads() {
            // Best effort: an unanswered read leaves its row disabled.
            if let reading = try? await backend.read(read) { readings.append(reading) }
        }
        guard generation == attachGeneration else { return generation }
        for reading in readings { state.apply(reading) }
        capabilityRevision += 1
        isLoaded = true
        return generation
    }

    /// Stops reading, unless a newer attach took over.
    func detach(_ generation: Int) {
        guard generation == attachGeneration else { return }
        cancelPendingBiometric()
        attachGeneration += 1
        udid = nil
        backend = nil
        physicalBackend = nil
        isLoaded = false
    }

    /// The attach's burst: every poll read once, side by side, plus the boot
    /// zone, the status bar and the location scenarios.
    private func readEverything(_ backend: AppleControlsBackend, generation: Int) async {
        let reads = AppleControlsPollPlan.initialReads(devicectl: backend.hasDevicectl)
        let base = statusBars[backend.udid] ?? SimulatorStatusBarState()
        async let zone = Self.bootTimeZone(backend)
        async let barList = try? backend.simctl.statusBarOverrides(udid: backend.udid)
        async let scenarios = try? backend.simctl.locationScenarios(udid: backend.udid)
        let readings = await withTaskGroup(of: AppleControlsReading?.self) { group in
            for read in reads {
                // Best effort: an unanswered read leaves its row disabled.
                group.addTask { try? await backend.read(read) }
            }
            var readings: [AppleControlsReading] = []
            for await reading in group {
                if let reading { readings.append(reading) }
            }
            return readings
        }
        let (readZone, readList, readScenarios) = await (zone, barList, scenarios)
        guard generation == attachGeneration else { return }
        for reading in readings { state.apply(reading) }
        if let readZone { bootTimeZone = .some(readZone) }
        if let readList {
            statusBarActive = !readList.isEmpty
            if let model = SimulatorStatusBarState.fromList(readList, over: base) {
                memory.statusBars[backend.udid] = model
            }
        }
        locationScenarios = readScenarios?.map(\.name) ?? []
    }

    /// The zone the running boot took: `.some(nil)` when it took none (the
    /// Mac's zone: `getenv` prints "'TZ' not found" on stderr and exits 0),
    /// nil when the read failed. Not `try?`, which would fold the two
    /// together (SE-0230) and leave a boot without a zone looking unread.
    private nonisolated static func bootTimeZone(_ backend: AppleControlsBackend) async -> String?? {
        do {
            return .some(try await backend.readBootTimeZone())
        } catch {
            return nil
        }
    }

    /// One poll tick: the preferences file, then this tick's one spawn.
    func pollTick() async {
        guard let active = activeBacking, active.deviceIdentifier == udid else { return }
        readPreferences()
        let read = active.pollRead(forTick: tick)
        tick += 1
        // A write in flight answers for its own row; the read would race it.
        guard busy.isEmpty, let read else { return }
        let generation = writeGeneration
        let attach = attachGeneration
        // Best effort: a missed read (the simulator going down) is retried next turn.
        let answer = try? await active.read(read)
        syncCapabilities()
        guard let reading = answer, generation == writeGeneration, attach == attachGeneration else { return }
        state.apply(reading)
    }

    /// A physical device's backend records a feature a call found
    /// unsupported (CoreDevice 1001); the rows are asked again when it grows.
    private func syncCapabilities() {
        let count = physicalBackend?.unsupportedFeatures.count ?? 0
        if count != knownUnsupported {
            knownUnsupported = count
            capabilityRevision += 1
        }
    }

    private func readPreferences() {
        guard let backend else { return }
        // Best effort: a file mid-write is read again next tick.
        if let preferences = try? backend.readGlobalPreferences() {
            state.preferences = preferences
        }
    }

    // MARK: - Writes

    /// Applies `change`; the mechanism's own answer (devicectl's) or the
    /// value simctl was told updates the row at once, the poll confirms.
    @discardableResult
    private func perform(_ change: AppleControlChange, _ what: String) async -> Bool {
        guard let active = activeBacking, let udid else { return false }
        writeGeneration += 1
        let control = change.control
        markBusy(control, on: udid)
        defer { clearBusy(control, on: udid) }
        do {
            let answer = try await active.apply(change)
            guard self.udid == udid else { return true }
            if let answer {
                state.apply(answer)
            } else {
                applyExpected(change)
            }
            // A reading that started before this write is stale.
            writeGeneration += 1
            return true
        } catch {
            syncCapabilities()
            status.errorMessage = "Could not \(what): \(Self.describe(error))"
            return false
        }
    }

    /// What simctl was told, for a write that answers nothing.
    private func applyExpected(_ change: AppleControlChange) {
        switch change {
        case .textSize(let size): state.textSize = size
        case .increaseContrast(let on): state.increaseContrast = on
        case .timeFormat(let setting):
            var preferences = state.preferences ?? SimulatorGlobalPreferences()
            preferences.force24Hour = setting == .twentyFourHour
            preferences.force12Hour = setting == .twelveHour
            state.preferences = preferences
        case .language(let locale):
            var preferences = state.preferences ?? SimulatorGlobalPreferences()
            preferences.languages = [locale.tag]
            preferences.locale = SimulatorGlobalPreferences.localeIdentifier(for: locale) ?? preferences.locale
            state.preferences = preferences
        default:
            break
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case let failure as SimctlFailure: failure.message.isEmpty ? "\(failure)" : failure.message
        case let failure as DevicectlError: failure.message.isEmpty ? "\(failure)" : failure.message
        default: "\(error)"
        }
    }

    // Display & sound, Accessibility

    func setAppearance(dark: Bool) async { await perform(.appearance(dark: dark), "change the appearance") }
    func setLiquidGlassOpacity(_ opacity: Double) async {
        await perform(.liquidGlassOpacity(min(max(opacity, 0), 1)), "change Liquid Glass")
    }
    /// Clear or Tinted (an iOS 26 simulator's Liquid Glass popup).
    func setLookAndFeel(_ look: DevicectlLookAndFeel) async {
        await perform(.lookAndFeel(look), "change Liquid Glass")
    }
    /// The Sound card's Output and Input (Mac audio devices).
    func setAudioOutput(_ device: DevicectlAudioDevice) async { await perform(.audioOutput(device), "change the sound output") }
    func setAudioInput(_ device: DevicectlAudioDevice) async { await perform(.audioInput(device), "change the sound input") }
    func setTextSize(_ size: SimulatorContentSize) async { await perform(.textSize(size), "change the text size") }
    func setLargerAccessibilitySizes(_ on: Bool) async { await perform(.largerAccessibilitySizes(on), "change Larger Accessibility Sizes") }
    func setReduceMotion(_ on: Bool) async { await perform(.reduceMotion(on), "change Reduce Motion") }
    func setShowBorders(_ on: Bool) async { await perform(.showBorders(on), "change Show Borders") }
    func setReduceTransparency(_ on: Bool) async { await perform(.reduceTransparency(on), "change Reduce Transparency") }
    func setVolume(_ volume: Int) async { await perform(.volume(min(max(volume, 0), 100)), "change the volume") }
    func setVoiceOver(_ on: Bool) async { await perform(.voiceOver(on), "change VoiceOver") }
    func setIncreaseContrast(_ on: Bool) async { await perform(.increaseContrast(on), "change Increase Contrast") }

    /// A filter (nil turns it off) at the last intensity the device reported.
    func setColorFilter(_ type: SimulatorColorFilterType?) async {
        await perform(.colorFilter(type, intensity: type?.hasIntensity == true ? state.colorFilterIntensity : nil), "change the color filter")
    }

    func setColorFilterIntensity(_ intensity: Double) async {
        guard case .some(let type?) = state.colorFilter, type.hasIntensity else { return }
        let clamped = min(max(intensity, SimulatorColorFilterType.intensityRange.lowerBound), SimulatorColorFilterType.intensityRange.upperBound)
        await perform(.colorFilter(type, intensity: clamped), "change the filter intensity")
    }

    // Location

    /// The location Device Hub Pro set on the attached simulator.
    var location: AppleLocationChoice? { udid.flatMap { locations[$0] } }

    /// Sets (nil clears) the location and keeps it, to set it again after a boot.
    func setLocation(_ choice: AppleLocationChoice?) async {
        guard let udid else { return }
        let done = await perform(choice?.change ?? .clearLocation, "set the location")
        if done { memory.locations[udid] = choice }
    }

    /// Apply to Selected changed `udid` outside the panel: what the panel
    /// keeps for it follows, as the row's own write leaves it (a language
    /// waits for a respring, a location is kept to be set again after the
    /// boots Device Hub Pro starts, the status bar's model and switch). The
    /// settings the panel reads back show on its next poll.
    func noteBatchChange(_ change: AppleControlChange, udid: String) {
        switch change {
        case .language:
            memory.respringPending.insert(udid)
        case .location(let latitude, let longitude):
            memory.locations[udid] = .coordinate(name: nil, latitude: latitude, longitude: longitude)
        case .clearLocation:
            memory.locations[udid] = nil
        case .statusBar(let model):
            if let model { memory.statusBars[udid] = model }
            if self.udid == udid { statusBarActive = model != nil }
        default:
            break
        }
    }

    /// A simulator reached ready. After a boot Device Hub Pro started (Boot,
    /// Restart, Erase) its kept location is set again, since a shutdown
    /// loses it (measured). A boot started elsewhere (Xcode, Simulator.app,
    /// a script) or followed again on a Refresh is not Device Hub Pro's to change:
    /// nothing is sent, and the kept choice is dropped, since the running
    /// boot does not have it.
    func simulatorBecameReady(_ udid: String, bootStartedHere: Bool) {
        // A boot shows the language everywhere, as a respring does.
        memory.respringPending.remove(udid)
        guard let choice = locations[udid] else { return }
        guard bootStartedHere else {
            memory.locations[udid] = nil
            return
        }
        guard let simctl = simulators.simctl,
              let backend = try? AppleControlsBackend(udid: udid, simctl: simctl, devicectl: nil, dataDirectory: nil)
        else { return }
        Task {
            // Best effort: the row still shows the kept choice, and the next
            // change sets it again.
            _ = try? await backend.apply(choice.change)
        }
    }

    // Sensors, Advanced

    func setPose(_ pose: SimulatorDevicePose) async { await perform(.orientation(pose), "change the orientation") }
    func setBiometricsEnrolled(_ enrolled: Bool) async { await perform(.biometricsEnrolled(enrolled), "change the enrolment") }

    /// A match or non-match request kept until the simulator shows its
    /// biometric prompt ("the result waits").
    struct PendingBiometric: Equatable {
        let success: Bool
        let udid: String
    }

    /// The request waiting for a prompt on the attached simulator, nil when
    /// none is. The watcher behind it runs only while this is set.
    private(set) var pendingBiometric: PendingBiometric?
    @ObservationIgnored private var biometricTask: Task<Void, Never>?
    @ObservationIgnored private var biometricToken = 0
    /// Replaces the simulator's prompt signal (`SimctlBiometricPromptSignal`); tests use it.
    @ObservationIgnored var biometricSignalOverride: (@MainActor (_ udid: String) -> (any BiometricPromptSignal)?)?
    @ObservationIgnored var biometricTimeout: Duration = BiometricResultWaiter.defaultTimeout
    @ObservationIgnored var biometricSettle: Duration = BiometricResultWaiter.defaultSettle

    /// Sends a matching or non-matching face (or finger). On a simulator it
    /// goes at once when a prompt is up, else waits (up to `biometricTimeout`)
    /// for the next prompt and goes then; `pendingBiometric` shows it and
    /// `cancelPendingBiometric` drops it. A physical iPhone has no prompt
    /// signal: sent at once.
    func simulateBiometricMatch(success: Bool) async {
        guard let udid, !isPhysical, let signal = biometricSignal(for: udid) else {
            await sendBiometricMatch(success: success)
            return
        }
        cancelPendingBiometric()
        biometricToken += 1
        let token = biometricToken
        pendingBiometric = PendingBiometric(success: success, udid: udid)
        let timeout = biometricTimeout
        let settle = biometricSettle
        let task = Task { [weak self] in
            let outcome = try? await BiometricResultWaiter.deliver(
                signal: signal, timeout: timeout, settle: settle
            ) { [weak self] in
                await self?.sendBiometricMatch(success: success, udid: udid)
            }
            guard let self, self.biometricToken == token else { return }
            self.pendingBiometric = nil
            if outcome == .timedOut {
                self.status.flash("No Face ID prompt appeared; nothing was sent")
            } else if outcome == .simulatorUnavailable {
                self.status.flash("The simulator is not running or does not answer; nothing was sent")
            }
        }
        biometricTask = task
        await task.value
    }

    /// Drops a request that is still waiting for a prompt.
    func cancelPendingBiometric() {
        biometricToken += 1
        biometricTask?.cancel()
        biometricTask = nil
        pendingBiometric = nil
    }

    private func biometricSignal(for udid: String) -> (any BiometricPromptSignal)? {
        if let biometricSignalOverride { return biometricSignalOverride(udid) }
        guard let simctl = simulators.simctl else { return nil }
        return SimctlBiometricPromptSignal(simctl: simctl, udid: udid)
    }

    @discardableResult
    private func sendBiometricMatch(success: Bool, udid expected: String? = nil) async -> Bool {
        if let expected, expected != udid { return false }
        if await perform(.biometricMatch(success: success), "simulate a match") {
            status.flash(success ? "Sent a matching face" : "Sent a non-matching face")
            return true
        }
        return false
    }

    // Clipboard (a physical iPhone's pasteboard)

    /// Replaces the phone's pasteboard with `text` (`devicectl device
    /// pasteboard copy`). True once it landed.
    func sendPasteboard(_ text: String) async -> Bool {
        await perform(.pasteboard(text), "send the clipboard")
    }

    /// The phone's pasteboard text (`devicectl device pasteboard paste`), nil
    /// when it could not be read (the error shows in the status line).
    func pullPasteboard() async -> String? {
        guard let physicalBackend, let udid else { return nil }
        markBusy(.clipboard, on: udid)
        defer { clearBusy(.clipboard, on: udid) }
        do {
            return try await physicalBackend.pasteboardText()
        } catch {
            syncCapabilities()
            status.errorMessage = "Could not read the clipboard: \(Self.describe(error))"
            return nil
        }
    }

    // App conditions

    /// Reads the simulator's apps for Target app (user apps first).
    func loadApps() async {
        guard let backend, !isLoadingApps else { return }
        isLoadingApps = true
        defer { isLoadingApps = false }
        // Best effort: the popup shows what it had.
        guard let listed = try? await backend.simctl.listApps(udid: backend.udid) else { return }
        apps = listed.sorted {
            if $0.isUserApp != $1.isUserApp { return $0.isUserApp }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    /// Sends the payload; true only when simctl took it (the Push sheet
    /// closes then, and stays open with the note or the error otherwise).
    @discardableResult
    func sendPush() async -> Bool {
        guard let bundle = targetBundle else { return false }
        let payload: SimulatorPushPayload
        // Smart quotes pasted from a document are put back to plain ones.
        pushText = PushPayloadText.straightened(pushText)
        do {
            payload = try SimulatorPushPayload(pushText)
        } catch {
            pushNote = "\(error)"
            return false
        }
        guard let backend, let udid else { return false }
        writeGeneration += 1
        markBusy(.push, on: udid)
        defer { clearBusy(.push, on: udid) }
        do {
            try await backend.apply(.push(bundleIdentifier: bundle, payload: payload))
            onPushSent?(SentPush(bundleIdentifier: bundle, payload: pushText))
            // The note is the attached simulator's; another may be attached now.
            guard self.udid == udid else { return true }
            pushNote = "Sent to \(bundle) at \(Self.clock(Date()))."
            return true
        } catch let failure as SimctlFailure where failure.isPushNotAuthorized {
            // simctl took the payload; iOS only declined to post it (a fresh
            // simulator has no app with notification permission), so it still
            // counts as the last push.
            onPushSent?(SentPush(bundleIdentifier: bundle, payload: pushText))
            guard self.udid == udid else { return false }
            pushNote = "iOS did not keep it: \(bundle) never asked to post notifications. The app still receives it while it is in front."
            return false
        } catch {
            if self.udid == udid { pushNote = nil }
            status.errorMessage = "Could not send the push: \(Self.describe(error))"
            return false
        }
    }

    func setPermission(_ action: SimulatorPrivacyAction) async {
        guard let bundle = targetBundle else { return }
        let service = permissionService
        if await perform(.privacy(action, service, bundleIdentifier: bundle), "change the permission") {
            let verb = switch action {
            case .grant: "Allowed"
            case .revoke: "Denied"
            case .reset: "Reset"
            }
            status.flash("\(verb) \(service.title) for \(bundle)")
        }
    }

    // Language & time

    /// Whether the attached simulator's language changed since its last respring.
    var respringSuggested: Bool { udid.map(respringPending.contains) ?? false }

    func setLanguage(_ locale: DeviceLocale) async {
        guard let udid else { return }
        if await perform(.language(locale), "change the language") {
            memory.respringPending.insert(udid)
        }
    }

    func respring() async {
        guard let udid else { return }
        if await perform(.respring, "respring") {
            memory.respringPending.remove(udid)
            status.flash("Respring: the home screen comes back in a few seconds")
        }
    }

    func setTimeFormat(_ setting: TimeFormatSetting) async { await perform(.timeFormat(setting), "change the clock") }

    /// The zone chosen for `udid` (nil: the Mac's), for the boots Device Hub Pro starts.
    func timeZone(for udid: String) -> String? { memory.timeZone(for: udid) }

    /// Chooses the attached simulator's boot zone (nil: the Mac's). It
    /// applies at the next boot Device Hub Pro starts (`needsRestartForTimeZone`).
    func setTimeZone(_ identifier: String?) {
        guard let udid else { return }
        memory.setTimeZone(identifier, udid: udid)
    }

    /// Whether the chosen zone differs from the one the running boot took.
    var needsRestartForTimeZone: Bool {
        guard let udid, case .some(let running) = bootTimeZone else { return false }
        return timeZone(for: udid) != running
    }

    func restartForTimeZone() async {
        guard let udid else { return }
        await restartSimulator(udid)
    }

    // Status bar

    /// The attached simulator's status bar model.
    var statusBar: SimulatorStatusBarState { udid.flatMap { statusBars[$0] } ?? SimulatorStatusBarState() }

    func setStatusBarActive(_ on: Bool) async {
        guard let udid else { return }
        let model = statusBar
        if await perform(.statusBar(on ? model : nil), on ? "override the status bar" : "clear the status bar") {
            memory.statusBars[udid] = model
            // The flag is the attached simulator's; another may be attached now.
            if self.udid == udid { statusBarActive = on }
        }
    }

    /// Clean status bar: on applies the Screenshot look over a fresh model
    /// (a blank carrier), off clears the override.
    func setCleanStatusBar(_ on: Bool) async {
        if on {
            await applyStatusBarPreset(.screenshot, over: SimulatorStatusBarState())
        } else {
            await setStatusBarActive(false)
        }
    }

    private func applyStatusBarPreset(_ preset: SimulatorStatusBarPreset, over base: SimulatorStatusBarState) async {
        guard let udid else { return }
        let model = preset.applied(to: base)
        if await perform(.statusBar(model), "override the status bar") {
            memory.statusBars[udid] = model
            if self.udid == udid { statusBarActive = true }
        }
    }

    private static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}
