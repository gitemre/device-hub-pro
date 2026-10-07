import Foundation
import Observation
import DeviceHubProKit

/// The Controls panel's two conditions groups: **Network conditions**
/// (emulator only: the console's latency, cell registration, signal and
/// meter, plus the data path they need) and **App conditions** (any device:
/// `am` low memory and kill on a target app).
///
/// Every write is read back from where Android applies it — the console's
/// stored latency, ConnectivityService's default network and capabilities,
/// telephony.registry, the activity manager's process record and exit
/// records — and the row shows that reading, never the value it sent. The
/// reads run on the Controls poll (`refresh()`), in two `adb shell` round
/// trips and one console read.
///
/// One long-lived instance, owned by `AppModel` as `conditions` and called
/// directly by the views (no forwarders). It reads the mirrored device from
/// the shared `ActiveDeviceContext`; the session hubs call `attach()` when a
/// mirror starts and `detach()` before one is torn down.
///
/// It also owns the **Status bar** group (`statusBar`, SystemUI demo mode)
/// and forwards the session's lifecycle to it, so Stop, the recovery's kill
/// and quit wait for its put-back too.
@MainActor
@Observable
final class DeviceConditionsController {
    let adbClient: AdbClient?
    private let context: ActiveDeviceContext
    let status: StatusCenter
    /// The Status bar group (`StatusBarDemoController`).
    let statusBar: StatusBarDemoController

    /// - Parameter statusBarRecords: where the Status bar's put-back records
    ///   outlive the app; nil keeps them for the process only.
    init(
        adbClient: AdbClient?,
        context: ActiveDeviceContext,
        status: StatusCenter,
        statusBarRecords: StatusBarDemoRecordStore? = nil
    ) {
        self.adbClient = adbClient
        self.context = context
        self.status = status
        statusBar = StatusBarDemoController(
            adbClient: adbClient,
            context: context,
            status: status,
            recordStore: statusBarRecords
        )
    }

    // MARK: - Readings

    /// The last Network conditions probe (emulators only).
    var network: NetworkConditionsSnapshot?
    /// The device's speed and latency shaping (`NetworkShaper`): the
    /// build's debuggability, root, the route interface and the netem
    /// qdiscs in place (emulators only).
    var shaping: ShapingReading?
    /// What the Speed and Connection latency rows asked for, per serial,
    /// while it is in place: the poll puts it back on the route's
    /// interface when the data path moves.
    private(set) var desiredShaping: [String: ShapingProfile] = [:]
    /// Serials whose adbd Device Hub Pro restarted as root: Reset conditions and
    /// the disconnect `adb unroot` them (a device that was root already is
    /// left root).
    private(set) var rootedByDeviceHubPro: Set<String> = []
    /// Called after Device Hub Pro restarted adbd of `serial` (root or unroot):
    /// streams that ride adb, like logcat, end with it and start again.
    @ObservationIgnored var onAdbdRestarted: (@MainActor (String) -> Void)?
    @ObservationIgnored private var isReapplyingShaping = false
    /// The last App conditions probe, for `appSnapshotPackage`.
    var app: AppConditionsSnapshot?
    /// The package `app` describes; a snapshot of another target is not
    /// shown.
    private(set) var appSnapshotPackage: String?
    /// The device's API level, from the first probe that answered.
    var apiLevel: Int?

    // MARK: - Target app

    var targetPackage: String? {
        didSet {
            guard targetPackage != oldValue else { return }
            // The captions describe the previous app's results.
            trimOutcome = nil
            killOutcome = nil
        }
    }
    /// Third-party packages, plus the foreground app when it is not one.
    var targetPackages: [String] = []
    var foregroundPackage: String?
    var isLoadingTargets = false

    // MARK: - Row drafts and results

    var trimOutcome: String?
    var killOutcome: String?
    var isEditingCustomLatency = false
    var customLatencyMinimum = ""
    var customLatencyMaximum = ""
    var customLatencyError: String?
    /// True while a write of this controller runs (its buttons disable).
    private(set) var isWriting = false

    /// The Wi-Fi and mobile-data settings `useMobileData()` replaced, per
    /// AVD (`EmulatorInstance.avdName`), until `resetNetworkConditions()`
    /// or `detach()` puts them back. They are guest settings on the AVD's
    /// disk, so they outlast its emulator: a record the disconnect could
    /// not restore (the emulator left first) waits for that AVD's next
    /// session, and never reaches another AVD that takes the serial.
    private(set) var savedDataPaths: [String: SavedDataPath] = [:]

    /// The console conditions Device Hub Pro changed, per serial, with the
    /// emulator process they were changed on: `detach()` puts them back, so
    /// a latency or No service Device Hub Pro set does not outlive its session —
    /// nothing on the device shows the latency. The console's state ends
    /// with its process, so a record is put back only through that process
    /// (`EmulatorInstance.discoveryPath`); it is dropped once another one
    /// answers on the serial or the emulator is stopped
    /// (`emulatorExited(serial:)`). Conditions Device Hub Pro did not touch (set
    /// from the emulator's own controls) are left alone.
    private(set) var changedConditions: [String: ChangedConsole] = [:]

    /// Keeps a poll that overlapped a write from overwriting the write's
    /// read-back with older values.
    private var writeFence = SettingsWriteFence()
    /// The cleanup `detach()` started (the put-backs);
    /// quit, Stop and the recovery's kill wait for it.
    @ObservationIgnored private(set) var pendingCleanup: Task<Void, Never>?
    /// The mirrored emulator's identity, read once per session by the first
    /// Network conditions write (or Reset) that needs it.
    @ObservationIgnored private var identified: (serial: String, generation: UInt64, instance: EmulatorInstance)?
    @ObservationIgnored private var targetLoad: Task<Void, Never>?
    /// The device whose target apps were listed (by the first poll).
    @ObservationIgnored private var targetsListedSerial: String?

    /// A console setting a Network conditions row writes, with the command
    /// that puts it back (the modem's start state).
    enum ConsoleCondition: CaseIterable, Hashable, Sendable {
        /// Speed and latency (tc netem in the guest, not the console).
        case shaping
        case meter

        var label: String {
            switch self {
            case .shaping: return "speed and latency"
            case .meter: return "meter"
            }
        }
    }

    /// The console conditions Device Hub Pro changed on one emulator process.
    struct ChangedConsole: Equatable {
        /// The process's discovery file (`EmulatorInstance.discoveryPath`).
        let discoveryPath: String
        var conditions: Set<ConsoleCondition>
    }

    /// How long a Stop or the recovery's kill waits for `detach()`'s
    /// cleanup before it goes ahead. The cleanup takes 1–2 s on the API 37
    /// emulator, and about 7 s when it puts the meter back: the console
    /// answers `gsm meter` only after about 5 s (measured).
    static let cleanupWaitLimit: Duration = .seconds(12)

    struct SavedDataPath: Equatable {
        /// `wifi_on` as stored (`0`–`3`); nil when it was unset.
        let wifiOn: String?
        let mobileData: String?

        var wifiEnabled: Bool { wifiOn == "1" || wifiOn == "2" }
        var mobileDataEnabled: Bool { mobileData == "1" }
    }

    // MARK: - Device

    var activeSerial: String? { context.serial }

    /// The AVD behind the mirror, when the session knows it.
    var mirroredAvdName: String? { context.avdName }

    /// The emulator console answers `adb emu` for `emulator-*` serials only.
    var isEmulator: Bool { Self.isEmulatorSerial(activeSerial) }

    nonisolated static func isEmulatorSerial(_ serial: String?) -> Bool {
        serial?.hasPrefix("emulator-") == true
    }

    private var controlsGeneration: UInt64 { context.controlsGeneration }

    // MARK: - Availability

    var showsNetworkConditions: Bool { activeSerial != nil && isEmulator }
    /// The Speed and Connection latency rows: on an emulator whose build
    /// is debuggable (`ro.debuggable`, read by the poll; no `adb root` to
    /// find out), so `tc` can run. Play Store images and phones never show
    /// them.
    var showsShaping: Bool { isEmulator && shaping?.debuggable == true }

    var shaper: NetworkShaper? { adbClient.map { NetworkShaper(adb: $0) } }
    var showsAppConditions: Bool { activeSerial != nil }
    var showsLowMemory: Bool { (apiLevel ?? 0) >= TrimMemoryLevel.minimumAPI }

    /// The target's snapshot, when it describes the selected target.
    var targetSnapshot: AppConditionsSnapshot? {
        guard let targetPackage, appSnapshotPackage == targetPackage else { return nil }
        return app
    }

    /// Whether Simulate low memory can send now; nil until the target's
    /// snapshot is read.
    var lowMemoryGate: TrimMemoryGate? {
        guard let snapshot = targetSnapshot else { return nil }
        return TrimMemoryGate.evaluate(
            TrimMemoryLevel.forLowMemory(process: snapshot.runningProcess, apiLevel: apiLevel),
            process: snapshot.runningProcess,
            apiLevel: apiLevel
        )
    }

    /// The switches saved for the mirrored AVD.
    var savedDataPath: SavedDataPath? {
        guard let serial = activeSerial else { return nil }
        let known = identified.flatMap { $0.serial == serial && $0.generation == controlsGeneration ? $0.instance : nil }
        return (mirroredAvdName ?? known?.avdName).flatMap { savedDataPaths[$0] }
    }

    // MARK: - Session

    /// A mirror started. The target apps load with the first poll, so a
    /// session whose Controls tab never opens does not list packages.
    func attach() {
        clearDeviceState()
        statusBar.attach()
    }

    /// The mirror is going away (called before the context is cleared):
    /// on an emulator, puts back the console conditions Device Hub Pro changed and the
    /// Wi-Fi and mobile data `useMobileData()` switched; then forgets the
    /// device's readings. Best effort, since the device may already be
    /// gone: what could not be put back stays recorded for that emulator
    /// (console conditions) or AVD (the switches).
    func detach() {
        // First, while the context still names the device.
        statusBar.detach()
        if let serial = activeSerial, let adbClient {
            let emulator = isEmulator
            // Taken now: a session that starts on the serial meanwhile
            // records its own changes.
            let changed = emulator ? changedConditions.removeValue(forKey: serial) : nil
            let unroot = rootedByDeviceHubPro.remove(serial) != nil
            let previous = pendingCleanup
            pendingCleanup = Task { [weak self] in
                // Quit waits for the newest cleanup only, so it chains the
                // earlier ones.
                await previous?.value
                // Best effort: a device that already left cannot answer.
                guard emulator else { return }
                await self?.putBackAfterDisconnect(serial: serial, changed: changed, unroot: unroot, adbClient: adbClient)
            }
        }
        clearDeviceState()
    }

    /// Waits for `detach()`'s cleanup (quit's bounded cleanup, and a Stop
    /// or kill of the emulator, which must not overtake it) and the Status
    /// bar's put-back, which run side by side: the console put-back can take
    /// 7 s.
    func waitForPendingCleanup() async {
        let statusBar = statusBar
        async let statusBarCleanup: Void = statusBar.waitForPendingCleanup()
        await pendingCleanup?.value
        await statusBarCleanup
    }

    /// The disconnect's put-back on `serial`, through the emulator that
    /// answers there now: the switches saved for its AVD, then the console
    /// conditions changed on that process (the switches first: they are on
    /// the AVD's disk and outlast the emulator, and the console's `gsm
    /// meter` takes 5 s). A console record of another process is dropped
    /// (that emulator exited, and its console state with it); a record of
    /// another AVD is left for that AVD. When the console does not answer —
    /// the emulator left first — nothing is sent and both records wait.
    private func putBackAfterDisconnect(serial: String, changed: ChangedConsole?, unroot: Bool, adbClient: AdbClient) async {
        guard changed != nil || unroot || !savedDataPaths.isEmpty else { return }
        guard let current = await adbClient.emulatorInstance(serial: serial) else {
            if let changed { keepConsoleRecord(changed, serial: serial) }
            if unroot { rootedByDeviceHubPro.insert(serial) }
            return
        }
        noteInstance(current, serial: serial)
        let conditions = changed.flatMap { $0.discoveryPath == current.discoveryPath ? $0.conditions : nil } ?? []
        let dataPath = savedDataPaths[current.avdName]
        let restored = await Self.restoreDataPath(dataPath, serial: serial, adbClient: adbClient)
        // Unless a newer one was recorded meanwhile.
        if restored, let dataPath, savedDataPaths[current.avdName] == dataPath {
            savedDataPaths[current.avdName] = nil
        }
        let failed = await Self.putBack(
            ConsoleCondition.allCases.filter(conditions.contains),
            serial: serial,
            adbClient: adbClient,
            unroot: unroot
        )
        if unroot {
            if failed.contains(where: { $0.condition == .shaping }) {
                rootedByDeviceHubPro.insert(serial)
            } else {
                onAdbdRestarted?(serial)
            }
        }
        if !failed.isEmpty {
            let record = ChangedConsole(discoveryPath: current.discoveryPath, conditions: Set(failed.map(\.condition)))
            keepConsoleRecord(record, serial: serial)
        }
    }

    /// Keeps what a disconnect could not put back, unless another emulator
    /// process took the serial meanwhile (its own record wins).
    private func keepConsoleRecord(_ record: ChangedConsole, serial: String) {
        guard let existing = changedConditions[serial] else {
            changedConditions[serial] = record
            return
        }
        guard existing.discoveryPath == record.discoveryPath else { return }
        changedConditions[serial]?.conditions.formUnion(record.conditions)
    }

    /// The emulator on `serial` exited (Stop, or the recovery's kill): the
    /// console conditions recorded for it ended with it, so none is put
    /// back, on it or on the next emulator to take the serial. The AVD's
    /// saved switches stay: they are on its disk.
    func emulatorExited(serial: String) {
        statusBar.emulatorExited(serial: serial)
        changedConditions[serial] = nil
        rootedByDeviceHubPro.remove(serial)
        desiredShaping[serial] = nil
        if identified?.serial == serial {
            identified = nil
        }
    }

    /// Sends the reset command of each condition, in order; returns the
    /// ones the device refused or could not take.
    static func putBack(
        _ conditions: [ConsoleCondition],
        serial: String,
        adbClient: AdbClient,
        unroot: Bool = false
    ) async -> [(condition: ConsoleCondition, error: any Error)] {
        // The meter (the console answers after about 5 s) and the shaping
        // (adb shell, then adbd's unroot) do not depend on each other: they
        // run side by side. Neither touches the adbd the other uses beyond
        // what `clearShaping` itself orders.
        var outcomes: [(index: Int, condition: ConsoleCondition, error: (any Error)?)] = []
        await withTaskGroup(of: (Int, ConsoleCondition, (any Error)?).self) { group in
            for (index, condition) in conditions.enumerated() {
                group.addTask {
                    do {
                        switch condition {
                        case .shaping: try await Self.clearShaping(serial: serial, adbClient: adbClient, unroot: unroot)
                        case .meter: try await adbClient.setEmulatorMobileDataMetered(serial: serial, metered: true)
                        }
                        return (index, condition, nil)
                    } catch {
                        return (index, condition, error)
                    }
                }
            }
            for await outcome in group { outcomes.append(outcome) }
        }
        var failed = outcomes.sorted { $0.index < $1.index }.compactMap { outcome in
            outcome.error.map { (condition: outcome.condition, error: $0) }
        }
        // Device Hub Pro's root is given back whether or not a shaping was
        // recorded: nothing else may be left to put back.
        if unroot, !conditions.contains(.shaping) {
            do {
                try await NetworkShaper(adb: adbClient).dropRoot(serial: serial)
            } catch {
                failed.append((.shaping, error))
            }
        }
        return failed
    }

    /// Removes the shaping, and with `unroot` the root Device Hub Pro gave adbd
    /// (the tc rules outlive the restart, so they go first). A device that
    /// is not root but still shaped (left over) is rooted for the clearing.
    static func clearShaping(serial: String, adbClient: AdbClient, unroot: Bool) async throws {
        let shaper = NetworkShaper(adb: adbClient)
        let reading = try await shaper.read(serial: serial)
        var drop = unroot
        if reading.isShaping {
            if !reading.isRoot, try await shaper.ensureRoot(serial: serial) == .restartedAsRoot { drop = true }
            try await shaper.clear(serial: serial, reading: reading)
        }
        if drop { try await shaper.dropRoot(serial: serial) }
    }

    /// Turns mobile data, then Wi-Fi, back to `saved`; false when there is
    /// nothing to restore or a command failed.
    static func restoreDataPath(_ saved: SavedDataPath?, serial: String, adbClient: AdbClient) async -> Bool {
        guard let saved else { return false }
        do {
            try await adbClient.setMobileData(serial: serial, enabled: saved.mobileDataEnabled)
            try await adbClient.setWifi(serial: serial, enabled: saved.wifiEnabled)
            return true
        } catch {
            return false
        }
    }

    private func clearDeviceState() {
        identified = nil
        targetLoad?.cancel()
        targetLoad = nil
        targetsListedSerial = nil
        network = nil
        shaping = nil
        app = nil
        appSnapshotPackage = nil
        apiLevel = nil
        targetPackage = nil
        targetPackages = []
        foregroundPackage = nil
        isLoadingTargets = false
        trimOutcome = nil
        killOutcome = nil
        isEditingCustomLatency = false
        customLatencyError = nil
    }

    // MARK: - Poll

    /// One Controls poll: the network probe and the console's latency on an
    /// emulator, and the app probe (the device-wide reads without a target).
    func refresh() async {
        guard let adbClient, let serial = activeSerial else { return }
        if targetsListedSerial != serial {
            targetsListedSerial = serial
            loadTargets()
        }
        let generation = controlsGeneration
        let ticket = writeFence.pollTicket
        let emulator = isEmulator
        let package = targetPackage

        async let networkRead: NetworkConditionsSnapshot? = emulator
            ? (try? await adbClient.networkConditions(serial: serial)) : nil
        async let shapingRead: ShapingReading? = emulator
            ? (try? await NetworkShaper(adb: adbClient).read(serial: serial)) : nil
        async let appRead = try? await adbClient.appConditions(serial: serial, package: package)
        let (networkValue, shapingValue, appValue) = await (networkRead, shapingRead, appRead)

        guard !Task.isCancelled, generation == controlsGeneration, serial == activeSerial,
              writeFence.admits(pollStartedAt: ticket)
        else { return }
        if emulator {
            network = networkValue
            shaping = shapingValue
        }
        if package == targetPackage {
            app = appValue
            appSnapshotPackage = package
        }
        if let level = appValue?.apiLevel ?? networkValue?.apiLevel {
            apiLevel = level
        }
        if emulator, let shapingValue { reapplyShapingIfMoved(shapingValue, serial: serial, generation: generation) }
    }

    /// The data path moved to another interface (Wi-Fi to mobile data, a
    /// route that came back): the netem sits on the old one, so put what
    /// the rows asked for on the route's interface now.
    private func reapplyShapingIfMoved(_ reading: ShapingReading, serial: String, generation: UInt64) {
        guard let profile = desiredShaping[serial], !profile.isNeutral, reading.isRoot,
              reading.routeInterface != nil, !reading.isPlaced(for: profile),
              !isReapplyingShaping, !isWriting
        else { return }
        isReapplyingShaping = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isReapplyingShaping = false }
            await self.applyShaping(profile, quiet: true, expecting: (serial, generation))
        }
    }

    // MARK: - Target apps

    /// An install or uninstall through Device Hub Pro (`AppsController`): relists
    /// the mirrored device's targets once they were listed, so a removed
    /// app leaves the popup and a new one joins it.
    func packagesChanged(serial: String) {
        guard serial == activeSerial, targetsListedSerial == serial else { return }
        loadTargets()
    }

    /// Lists the third-party packages and the foreground app. The target
    /// defaults to the foreground app when it is a third-party one (the app
    /// under test, usually); a system app in front — the launcher, Settings
    /// — is listed but not picked, so a stray Kill cannot hit it.
    func loadTargets() {
        guard let adbClient, let serial = activeSerial else { return }
        let generation = controlsGeneration
        targetLoad?.cancel()
        isLoadingTargets = true
        targetLoad = Task { [weak self] in
            async let packagesRead = try? await adbClient.listPackages(serial: serial, thirdPartyOnly: true)
            async let foregroundRead = try? await adbClient.foregroundPackage(serial: serial)
            let (packages, foreground) = await (packagesRead, foregroundRead)
            guard let self, !Task.isCancelled, generation == self.controlsGeneration, serial == self.activeSerial else {
                return
            }
            self.isLoadingTargets = false
            let thirdParty = (packages ?? []).sorted()
            let resolvedForeground = foreground
            self.foregroundPackage = resolvedForeground
            self.targetPackages = Self.targetOptions(thirdParty: thirdParty, foreground: resolvedForeground)
            self.targetPackage = Self.defaultTarget(
                current: self.targetPackage,
                thirdParty: thirdParty,
                foreground: resolvedForeground,
                options: self.targetPackages
            )
        }
    }

    nonisolated static func targetOptions(thirdParty: [String], foreground: String?) -> [String] {
        guard let foreground, !thirdParty.contains(foreground) else { return thirdParty }
        return [foreground] + thirdParty
    }

    /// Keeps a still-listed choice; otherwise the foreground app when it is
    /// third-party; otherwise none.
    nonisolated static func defaultTarget(
        current: String?,
        thirdParty: [String],
        foreground: String?,
        options: [String]
    ) -> String? {
        if let current, options.contains(current) { return current }
        if let foreground, thirdParty.contains(foreground) { return foreground }
        return nil
    }

    // MARK: - Write fence

    func beginWrite() {
        writeFence.beginWrite()
        isWriting = true
    }

    func endWrite() {
        writeFence.endWrite()
        isWriting = !writeFence.isIdle
    }

    // MARK: - Emulator identity

    /// The emulator on `serial`, read once per session. Reading it drops a
    /// console record of another process on the serial.
    func emulatorInstance(serial: String, generation: UInt64) async -> EmulatorInstance? {
        if let identified, identified.serial == serial, identified.generation == generation {
            return identified.instance
        }
        guard let adbClient, let instance = await adbClient.emulatorInstance(serial: serial) else { return nil }
        noteInstance(instance, serial: serial)
        if isCurrent(serial: serial, generation: generation) {
            identified = (serial, generation, instance)
        }
        return instance
    }

    /// The emulator a Network conditions write goes to, so that the change
    /// can be put back on that emulator alone; nil, with the error raised,
    /// when its console does not say which one it is.
    func identifyForWrite(serial: String, generation: UInt64) async -> EmulatorInstance? {
        if let instance = await emulatorInstance(serial: serial, generation: generation) {
            return instance
        }
        if isCurrent(serial: serial, generation: generation) {
            errorMessage = "Couldn't tell which emulator this is, so Device Hub Pro could not put the change back later. Nothing was changed."
        }
        return nil
    }

    /// `instance` answers on `serial` now: a console record of another
    /// process there belongs to an emulator that exited.
    private func noteInstance(_ instance: EmulatorInstance, serial: String) {
        if let record = changedConditions[serial], record.discoveryPath != instance.discoveryPath {
            changedConditions[serial] = nil
        }
    }

    /// Records the data path the next `useMobileData()` replaces on `avdName`
    /// (tests and the write itself); the first one recorded is the original.
    func rememberDataPath(_ saved: SavedDataPath, avdName: String) {
        if savedDataPaths[avdName] == nil {
            savedDataPaths[avdName] = saved
        }
    }

    func forgetDataPath(avdName: String) {
        savedDataPaths[avdName] = nil
    }

    /// A Network conditions row is about to write `condition` on
    /// `instance`: `detach()` puts it back through the same emulator.
    func markChanged(_ condition: ConsoleCondition, serial: String, instance: EmulatorInstance) {
        if changedConditions[serial]?.discoveryPath != instance.discoveryPath {
            changedConditions[serial] = ChangedConsole(discoveryPath: instance.discoveryPath, conditions: [])
        }
        changedConditions[serial]?.conditions.insert(condition)
    }

    /// These are back at the modem's start state (Reset conditions, or a
    /// row set its start value): the disconnect need not put them back.
    func recordRootedByDeviceHubPro(_ rooted: Bool, serial: String) {
        if rooted { rootedByDeviceHubPro.insert(serial) } else { rootedByDeviceHubPro.remove(serial) }
    }

    func setDesiredShaping(_ profile: ShapingProfile?, serial: String) {
        desiredShaping[serial] = profile
    }

    func markRestored(_ conditions: [ConsoleCondition], serial: String) {
        changedConditions[serial]?.conditions.subtract(conditions)
        if changedConditions[serial]?.conditions.isEmpty == true {
            changedConditions[serial] = nil
        }
    }

    /// Whether `serial` still is the device a write started on.
    func isCurrent(serial: String, generation: UInt64) -> Bool {
        serial == activeSerial && generation == controlsGeneration
    }

    var currentGeneration: UInt64 { controlsGeneration }

    func applyApp(_ snapshot: AppConditionsSnapshot, package: String) {
        app = snapshot
        appSnapshotPackage = package
        if let level = snapshot.apiLevel { apiLevel = level }
    }

    // MARK: - Status

    var errorMessage: String? {
        get { status.errorMessage }
        set { status.errorMessage = newValue }
    }

    func flashStatus(_ message: String) {
        status.flash(message)
    }
}
