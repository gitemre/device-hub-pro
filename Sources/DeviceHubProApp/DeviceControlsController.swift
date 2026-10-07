import Foundation
import Observation
import DeviceHubProKit

/// The Controls tab's panel: the emulator's gRPC state and the Android
/// settings rows, the 2 s poll that refreshes them, the probes that decide
/// which rows show, the recovery card's signal, and the read-backs the
/// settings writes reconcile with. The reads themselves are in
/// `SettingsPollReader.swift`; the settings writes and the Sound knob's
/// volume stepping in `DeviceControlsController+Writes.swift`, which
/// report through `StatusCenter`.
///
/// One long-lived instance, owned by `DeviceWorkspace` as `controlsPanel`;
/// the views read it there. It
/// reads the mirrored device from the shared `ActiveDeviceContext` and
/// holds no reference to the model: whether a session runs, whether a fold
/// animation owns the posture and hinge, and the Location draft a poll
/// primes go through the hooks below, which the model sets once it is
/// built. The teardown hub `detach()`es it.
@MainActor
@Observable
final class DeviceControlsController {
    let adbClient: AdbClient?
    private let context: ActiveDeviceContext
    let status: StatusCenter

    init(adbClient: AdbClient?, context: ActiveDeviceContext, status: StatusCenter) {
        self.adbClient = adbClient
        self.context = context
        self.status = status
        self.languageTime = LanguageTimeController(adbClient: adbClient, context: context, status: status)
        self.colorFilters = ColorFilterController(adbClient: adbClient, context: context, status: status)
    }

    /// The Language & time group, polled with the panel and detached with it.
    let languageTime: LanguageTimeController
    /// The Accessibility group's Color Filter and Color inversion rows, polled
    /// with the panel and detached with it.
    let colorFilters: ColorFilterController

    /// Whether a mirror session runs: the recovery card needs one.
    /// `AppModel` wires it to its `session`.
    @ObservationIgnored var hasSession: @MainActor () -> Bool = { false }
    /// Whether a fold animation or the hinge sender owns the posture and
    /// the hinge angle, which a poll then leaves alone. `AppModel` wires it
    /// to its posture and hinge workers.
    @ObservationIgnored var isPostureBusy: @MainActor () -> Bool = { false }
    /// Takes each applied poll's fix for the Location sheet's draft.
    /// `AppModel` wires it to the location controller.
    @ObservationIgnored var locationPolled: @MainActor (_ location: GpsFix?) -> Void = { _ in }

    var controls = DeviceControlsState()
    var controlsLoaded = false
    /// How long a poll waits for the emulator's gRPC state before it gives
    /// the panel its adb-backed rows without it. Injectable for tests.
    @ObservationIgnored var emulatorReadTimeout: Duration = .seconds(8)
    /// Consecutive Controls polls in which the emulator's gRPC channel
    /// answered nothing at all (no boot state, no display, no battery): the
    /// recovery card's signal that the VM stopped responding.
    private(set) var emulatorUnresponsivePolls = 0
    /// How many such polls (~2 s apart) count as "powered off".
    static let unresponsivePollsForRecovery = 3

    /// Keeps the poll off the settings rows a write owns: while a write
    /// runs the poll leaves them alone (a stale read would flip an
    /// optimistically updated row back to the pre-write value before the
    /// reconcile lands), and a poll whose reads overlapped a write, even one
    /// that already finished, drops them. Readable for tests.
    private(set) var writeFence = SettingsWriteFence()

    /// The Controls tab's Android settings rows (Text Size, Reduce Motion,
    /// Increase Contrast, Show Borders, TalkBack, Sound).
    var deviceSettings = DeviceSettingsState()
    /// The row-availability probes, one per settings command and developer
    /// toggle: each hides its row after 3 consecutive command failures and
    /// clears on any answer (the `AppearanceProbe` rule), and all of them
    /// start over when the panel moves to another device. Readable for
    /// tests.
    private(set) var probes = SettingsProbeSet()

    /// Whether the Controls inspector shows the Appearance row. Hidden only
    /// for a device whose appearance command itself keeps failing.
    var showsAppearanceSection: Bool { probes.showsAppearanceSection }

    var showsTextSizeRow: Bool { probes.showsTextSizeRow }
    var showsReduceMotionRow: Bool { probes.showsReduceMotionRow }
    var showsIncreaseContrastRow: Bool { probes.showsIncreaseContrastRow }
    var showsShowBordersRow: Bool { probes.showsShowBordersRow }
    /// Shown only while the installed-package list reports TalkBack and the
    /// probe has not tripped (a device without TalkBack never shows the row).
    var showsTalkBackRow: Bool { probes.showsTalkBackRow(talkBackPackage: deviceSettings.talkBackPackage) }
    var showsSoundRow: Bool { probes.showsSoundRow }

    /// Whether a developer-toggle row is shown: hidden only while its
    /// namespace read keeps failing (the `AppearanceProbe` rule).
    func showsToggle(_ toggle: DeviceToggle) -> Bool {
        probes.showsToggle(toggle, unsupportedToggles: deviceSettings.unsupportedToggles)
    }

    var showsDataSaverRow: Bool { probes.showsDataSaverRow }

    /// A phone connected over Wi-Fi (`ip:port`, or its mDNS name): turning
    /// Wi-Fi or airplane mode off cuts the very link Device Hub Pro drives it
    /// through, with no way back from here, so those two rows are not shown.
    var isWirelessConnection: Bool {
        activeSerial.map(AdbClient.isWirelessSerial) ?? false
    }

    var showsWifiRow: Bool { controls.wifiEnabled != nil && !isWirelessConnection }
    var showsAirplaneModeRow: Bool { controls.airplaneModeEnabled != nil && !isWirelessConnection }

    /// gRPC-only controls (battery, location, foldable) need an emulator port.
    var canUseEmulatorControls: Bool { activePort != nil }

    /// A settings write starts: the poll leaves the settings rows alone
    /// until the matching `endSettingsWrite()`, and a poll already reading
    /// drops them.
    func beginSettingsWrite() {
        writeFence.beginWrite()
    }

    /// The write started by the matching `beginSettingsWrite()` ended.
    func endSettingsWrite() {
        writeFence.endWrite()
    }

    /// The serial whose TalkBack package was last read. `pm list packages`
    /// is the poll's most expensive read, so it runs once per device (and
    /// again after an install or uninstall), not every two seconds.
    private(set) var talkBackPackageSerial: String?
    /// When the slow-changing rows were last read, and how often the poll
    /// reads them again (tests shorten it).
    @ObservationIgnored private var lastSlowRowRead: ContinuousClock.Instant?
    @ObservationIgnored var slowRowInterval: Duration = .seconds(10)

    /// Sets the media stream volume and reads it back.
    /// The last index the device itself was known to be at while the Sound
    /// knob is being dragged; the displayed value is the optimistic target.
    var volumeAppliedIndex: Int?
    var volumeTarget: Int?
    var volumeStepTask: Task<Void, Never>?
    /// Per serial: the animation scales before Reduce Motion first set them
    /// to 0, which Off writes back.
    var animationScalesBeforeReduceMotion: [String: AdbClient.AnimationScales] = [:]

    /// Refreshes the Controls panel: the emulator's gRPC state (battery,
    /// location, posture, hinge, displays) and the settings rows. Every read
    /// is independent, so they overlap — the gRPC read included — and one
    /// refresh costs one round trip. The TalkBack package (a full
    /// `pm list packages`) is read once per device, not every poll.
    ///
    /// What the reads bring back is applied only while it still describes
    /// the panel: nothing when the mirrored device changed or the poll was
    /// cancelled meanwhile, and no settings rows when a settings write
    /// started during the reads (the write's optimistic value and reconcile
    /// own them). The gRPC half is merged into `controls`, so a poll that
    /// skips the settings never blanks the adb-backed rows.
    func refreshControls() async {
        guard let serial = activeSerial, adbClient != nil else { return }
        let generation = controlsGeneration
        let port = activePort

        // The settings-row probes restart when the panel moves to another
        // device, and the TalkBack package survives a failed package read so
        // one failure cannot hide its row.
        let isNewSettingsDevice = probes.prepare(for: serial)

        // Language/time, colour filters, appearance and data saver change
        // rarely: they are read when the device is new and then every
        // `slowRowInterval`; the 2 s beat reads only the fast rows.
        if isNewSettingsDevice { lastSlowRowRead = nil }
        let now = ContinuousClock.now
        let includeSlowRows = lastSlowRowRead.map { now - $0 >= slowRowInterval } ?? true
        if includeSlowRows { lastSlowRowRead = now }

        async let emulatorRead = Self.readEmulatorState(port: port, timeout: emulatorReadTimeout)
        async let languageTimeRead: Void = includeSlowRows ? languageTime.refresh() : ()
        async let colorFilterRead: Void = includeSlowRows ? colorFilters.refresh() : ()
        let writesAtStart = writeFence.pollTicket
        var settingsRead: SettingsPollReadings?
        if writeFence.isIdle {
            settingsRead = await readSettingsPoll(
                serial: serial,
                knownTalkBackPackage: isNewSettingsDevice ? nil : deviceSettings.talkBackPackage,
                includeSlowRows: includeSlowRows
            )
        }
        // Nil: the emulator's gRPC read never answered (a wedged VM). The
        // panel still loads from the adb-backed rows; the missing answer is
        // neither merged nor counted as "powered off".
        let emulatorResult = await emulatorRead
        let emulatorState = emulatorResult ?? DeviceControlsState()
        await languageTimeRead
        await colorFilterRead

        guard !Task.isCancelled, generation == controlsGeneration, serial == activeSerial else { return }

        var state = controls
        if emulatorResult != nil {
            Self.mergeEmulatorFields(emulatorState, into: &state)
        }
        if port != nil, emulatorResult != nil {
            let silent = emulatorState.isBooted == nil
                && emulatorState.displays.isEmpty
                && emulatorState.battery == nil
            emulatorUnresponsivePolls = silent ? emulatorUnresponsivePolls + 1 : 0
        }
        if let settingsRead, writeFence.admits(pollStartedAt: writesAtStart) {
            applySettingsPoll(settingsRead, serial: serial, to: &state)
        }

        // A poll must never fight an in-flight hinge/posture animation.
        if isPostureBusy() {
            state.posture = controls.posture
            state.hingeAngle = controls.hingeAngle
        }
        controls = state
        primeLocationDraft(from: state.location)
        controlsLoaded = true
    }

    private func applySettingsPoll(
        _ poll: SettingsPollReadings,
        serial: String,
        to state: inout DeviceControlsState
    ) {
        var settingsState = DeviceSettingsState()
        settingsState.talkBackPackage = poll.talkBackPackage
        if let answered = poll.talkBackAnswered {
            probes.recordTalkBackPackageRead(answered: answered)
            if answered { talkBackPackageSerial = serial }
        }
        // Rows the reads below only set on an answer start empty, so a
        // failed read shows "unknown" rather than the previous value.
        if poll.appearance.result != nil { state.appearance = nil }
        if poll.dataSaver.result != nil { state.dataSaverEnabled = nil }
        applyGlobal(poll.global, settings: &settingsState)
        applyGlobalControls(poll.global, into: &state)
        applySystem(poll.system, to: &settingsState)
        applySecure(poll.secure, to: &settingsState)
        applyVolume(poll.volume, to: &settingsState)
        applyAppearance(poll.appearance, to: &state)
        applyDataSaver(poll.dataSaver, into: &state)
        deviceSettings = settingsState
    }

    /// The gRPC half of a poll replaces exactly the fields
    /// `EmulatorControls.state` reads; the adb-backed rows stay.
    static func mergeEmulatorFields(_ read: DeviceControlsState, into state: inout DeviceControlsState) {
        state.battery = read.battery
        state.location = read.location
        state.posture = read.posture
        state.hingeAngle = read.hingeAngle
        state.displays = read.displays
        state.isBooted = read.isBooted
    }

    /// The emulator's gRPC state, or an empty snapshot for physical devices.
    /// Nil when the read did not answer within `timeout`.
    private static func readEmulatorState(port: Int?, timeout: Duration) async -> DeviceControlsState? {
        guard let port else { return DeviceControlsState() }
        return await BoundedWait.run(timeout) { await EmulatorControls.state(port: port) }
    }

    // MARK: - Settings applies

    private func applyGlobal(_ readings: GlobalReadings, settings: inout DeviceSettingsState) {
        settings.reduceMotion = readings.reduceMotion
        settings.apply(readings.effects)
        settings.mobileDataAlwaysActive = readings.mobileDataAlwaysActive
        probes.recordGlobalRead(answered: readings.answered)
    }

    private func applyGlobalControls(_ readings: GlobalReadings, into state: inout DeviceControlsState) {
        state.airplaneModeEnabled = readings.airplaneModeEnabled
        state.wifiEnabled = readings.wifiEnabled
        state.bluetoothEnabled = readings.bluetoothEnabled
        state.mobileDataEnabled = readings.mobileDataEnabled
        state.batterySaverEnabled = readings.batterySaverEnabled
    }

    private func applySystem(_ readings: SystemReadings, to settings: inout DeviceSettingsState) {
        settings.fontScale = readings.fontScale
        settings.showTaps = readings.showTaps
        probes.recordSystemRead(answered: readings.answered)
    }

    private func applySecure(_ readings: SecureReadings, to settings: inout DeviceSettingsState) {
        settings.increaseContrast = readings.increaseContrast
        settings.voiceOver = readings.voiceOver
        settings.backgroundANRs = readings.backgroundANRs
        probes.recordSecureRead(answered: readings.answered)
    }

    func applyVolume(_ readings: VolumeReadings, to settings: inout DeviceSettingsState) {
        settings.mediaVolume = readings.volume
        probes.recordVolumeRead(answered: readings.answered)
    }

    private func applyAppearance(_ readings: AppearanceReadings, to state: inout DeviceControlsState) {
        guard let result = readings.result else { return }
        if case .success(let reading) = result {
            state.appearance = reading
        }
        probes.recordAppearanceRead(result)
    }

    /// An answered read — even an unrepresentable one — proves `cmd netpolicy`
    /// exists and keeps the row; only a command failure counts (the
    /// `AppearanceProbe` rule).
    private func applyDataSaver(_ readings: DataSaverReadings, into state: inout DeviceControlsState) {
        switch readings.result {
        case .success(let reading):
            if let isOn = reading.isOn {
                state.dataSaverEnabled = isOn
            }
            probes.recordDataSaverRead(answered: true)
        case .failure:
            probes.recordDataSaverRead(answered: false)
        case nil:
            break
        }
    }

    // MARK: - Settings reconciles

    /// Reads one namespace back after a write, retrying briefly while the
    /// framework has not applied it yet (Wi-Fi, Bluetooth, airplane mode and
    /// the appearance command all settle asynchronously) — the fixed 500 ms
    /// sleeps are gone.
    func reconcileGlobalSettings(
        serial: String,
        until settled: () -> Bool
    ) async {
        let current = stillShowing(serial)
        await settleSetting(
            attemptTimeout: Self.settleCallTimeout,
            isCurrent: current,
            attempt: {
                let readings = await readGlobalSettings(serial: serial)
                guard current() else { return }
                applyGlobal(readings, settings: &deviceSettings)
                applyGlobalControls(readings, into: &controls)
            },
            settled: settled
        )
    }

    func reconcileSecureSettings(
        serial: String,
        talkBackPackage: String?,
        until settled: () -> Bool
    ) async {
        let current = stillShowing(serial)
        await settleSetting(
            attemptTimeout: Self.settleCallTimeout,
            isCurrent: current,
            attempt: {
                let readings = await readSecureSettings(
                    serial: serial,
                    talkBackPackage: talkBackPackage
                )
                guard current() else { return }
                applySecure(readings, to: &deviceSettings)
            },
            settled: settled
        )
    }

    func reconcileSystemSettings(
        serial: String,
        until settled: () -> Bool
    ) async {
        let current = stillShowing(serial)
        await settleSetting(
            attemptTimeout: Self.settleCallTimeout,
            isCurrent: current,
            attempt: {
                let readings = await readSystemSettings(serial: serial)
                guard current() else { return }
                applySystem(readings, to: &deviceSettings)
            },
            settled: settled
        )
    }

    func reconcileAppearance(serial: String, expecting mode: AppearanceMode) async {
        let current = stillShowing(serial)
        await settleSetting(
            attempts: 6,
            attemptTimeout: Self.settleCallTimeout,
            isCurrent: current,
            attempt: {
                let readings = await readAppearanceSetting(serial: serial)
                guard current() else { return }
                applyAppearance(readings, to: &controls)
            },
            settled: {
                controls.appearance == .mode(mode)
            }
        )
    }

    func reconcileDataSaver(serial: String, expecting enabled: Bool) async {
        let current = stillShowing(serial)
        await settleSetting(
            attemptTimeout: Self.settleCallTimeout,
            isCurrent: current,
            attempt: {
                let readings = await readDataSaverSetting(serial: serial)
                guard current() else { return }
                applyDataSaver(readings, into: &controls)
            },
            settled: {
                controls.dataSaverEnabled == enabled
            }
        )
    }

    /// Each read-back call of a settle loop: short, so a device that stopped
    /// answering cannot hold the write fence for `commandTimeout` a read.
    static let settleCallTimeout: Duration = .seconds(5)

    /// Whether the device a write went to is still the one shown: the same
    /// serial and the same session (generation) as when this is called.
    /// Writes and their read-backs apply their results only while it holds.
    func stillShowing(_ serial: String) -> () -> Bool {
        let generation = controlsGeneration
        return { [weak self] in
            guard let self else { return false }
            return self.activeSerial == serial && self.controlsGeneration == generation
        }
    }

    /// Reads a developer toggle's namespace back after its write.
    func reconcileSettings(
        for toggle: DeviceToggle,
        until settled: () -> Bool
    ) async {
        guard let serial = activeSerial else { return }
        if toggle.readsDeviceEffect {
            await reconcileGlobalSettings(serial: serial, until: settled)
            return
        }
        switch toggle.namespace {
        case "system":
            await reconcileSystemSettings(serial: serial, until: settled)
        case "secure":
            await reconcileSecureSettings(
                serial: serial,
                talkBackPackage: deviceSettings.talkBackPackage,
                until: settled
            )
        default:
            await reconcileGlobalSettings(serial: serial, until: settled)
        }
    }

    // MARK: - Recovery

    /// True when the mirrored emulator stopped responding (for example after
    /// the battery hit 0% and Android powered off): its gRPC channel reports
    /// the guest not booted, or has answered nothing for
    /// `unresponsivePollsForRecovery` polls in a row. Never inferred from
    /// fields that are simply absent — a physical device has no gRPC state
    /// at all, and an emulator's first poll has not landed yet.
    var needsRecovery: Bool { recoveryReason != nil }

    /// Why the recovery card shows: the guest reports itself not booted
    /// (Android powered off, as after an empty battery), or the emulator has
    /// answered nothing for `unresponsivePollsForRecovery` polls (a stuck
    /// emulator, whose battery may well be full). Nil when no card shows.
    var recoveryReason: RecoveryReason? {
        guard hasSession(), activePort != nil, controlsLoaded else { return nil }
        if controls.isBooted == false { return .poweredOff }
        return emulatorUnresponsivePolls >= Self.unresponsivePollsForRecovery ? .unresponsive : nil
    }

    enum RecoveryReason: Equatable {
        case poweredOff
        case unresponsive

        var title: String {
            switch self {
            case .poweredOff: "Device powered off"
            case .unresponsive: "Emulator not responding"
            }
        }

        var actionTitle: String {
            switch self {
            case .poweredOff: "Power On"
            case .unresponsive: "Restart"
            }
        }

        var caption: String {
            switch self {
            case .poweredOff:
                "Android powered off, usually because the battery reached 0%. Power it back on to continue."
            case .unresponsive:
                "The emulator stopped answering its controls. Restarting it fixes this."
            }
        }
    }

    // MARK: - Device switch

    /// Empties the Controls panel for the next device: its state, the
    /// settings rows, the loaded flag and the unresponsive-poll count. The
    /// panel renders its rows under the loading card, so the settings rows
    /// go too: the previous device's TalkBack row or text size must not show
    /// until the next device's first poll lands.
    func detach() {
        controls = DeviceControlsState()
        deviceSettings = DeviceSettingsState()
        controlsLoaded = false
        emulatorUnresponsivePolls = 0
        languageTime.detach()
        colorFilters.detach()
    }

    /// Forgets whose TalkBack package was read, so the next device's first
    /// poll reads its own.
    func forgetTalkBackPackage() {
        talkBackPackageSerial = nil
    }

    /// `serial`'s package set changed: the Controls poll re-reads TalkBack.
    func forgetTalkBackPackage(ifSerial serial: String) {
        if talkBackPackageSerial == serial { talkBackPackageSerial = nil }
    }

    // MARK: Device

    /// The mirrored device's adb serial; nil while nothing is mirrored.
    var activeSerial: String? { context.serial }

    /// The active emulator's gRPC port; nil for a physical device and while
    /// nothing is mirrored.
    private var activePort: Int? { context.port }

    /// Bumped by the session hubs whenever the mirrored device changes.
    var controlsGeneration: UInt64 { context.controlsGeneration }

    /// Hands a poll's fix to the Location draft (`locationPolled`).
    private func primeLocationDraft(from location: GpsFix?) {
        locationPolled(location)
    }
}
