import Foundation
import Observation
import DeviceHubProKit

/// The adb device list and what the app knows about each device: the rows
/// of the watcher's last snapshot with every workspace's ghost of a device
/// waiting to reconnect merged in, their last-known details, their Info and
/// their consoles' AVD names, each kept per adb transport. It owns the
/// hot-plug watcher: one `DeviceWatcher` for the whole app,
/// pumping every event to each registered workspace's own
/// `DeviceLifecycleCoordinator` in turn — the decider that decides that
/// workspace's own reconnect episode.
///
/// `AppModel` owns one as `inventory`; the views and tests call it directly.
/// `refresh()` stays in the model, and the lifecycle's resume stays on `DeviceWorkspace`. It holds no
/// reference to the model or the registry: a workspace registers its own
/// coordinator (`registerLifecycle`/`unregisterLifecycle`, called from
/// `WorkspaceRegistry.register`/`unregister`), and what the model does after
/// a snapshot goes through the hooks below, which the model sets once it is
/// built. It reads the mirrored device from the shared `ActiveDeviceContext`
/// and forgets the gRPC ports of the emulators that left; each workspace's
/// own coordinator flashes adb's health through its own `StatusCenter` hook.
@MainActor
@Observable
final class DeviceInventory {
    var devices: [AndroidDevice] = []
    var deviceInfos: [String: DeviceInfo] = [:]
    /// The adb transport each `deviceInfos` entry was read from: emulator
    /// serials are reused by whichever VM boots next, and a new VM on the
    /// same serial gets a new transport id, so its info is fetched again.
    private var deviceInfoTransportIDs: [String: String?] = [:]
    /// Every registered workspace's own episode decider, pumped in
    /// registration order on every watcher event
    /// (`registerLifecycle`/`unregisterLifecycle`).
    @ObservationIgnored private var coordinators: [WorkspaceID: DeviceLifecycleCoordinator] = [:]
    @ObservationIgnored private var coordinatorOrder: [WorkspaceID] = []
    /// Whether the watcher is running: `AppServices`/`AppModel`'s `lifecycle`
    /// forward reads this so it answers nil exactly as before — before the
    /// watcher starts, without adb, or once it stops — even though a
    /// workspace's own coordinator now lives for the workspace's whole life.
    private(set) var isLifecycleRunning = false
    /// The task pumping the watcher's stream to every registered coordinator.
    private var pumpTask: Task<Void, Never>?
    /// The watcher, owned here because quit has to stop it: cancelling a
    /// coordinator's own tasks does not take the `track-devices` child down,
    /// and nothing else will (S1).
    private var deviceWatcher: DeviceWatcher?
    var lastKnownDetails: [String: AndroidDevice] = [:]
    /// One workspace's ghost: the serial its own episode is waiting to
    /// reconnect, and the status its panel shows for it.
    private struct WorkspaceGhost {
        var serial: String
        var status: CanvasStatusKind
    }
    /// Every workspace's ghost, keyed by the workspace whose episode set it
    /// (: today there is one entry at most, as before; two
    /// workspaces can each ghost their own serial without touching the
    /// other's).
    private var ghosts: [WorkspaceID: WorkspaceGhost] = [:]
    /// The snapshot's real rows behind `devices`' merged view (spec §5.2
    /// amendment: a synthetic ghost never replaces a real row).
    private(set) var realDevices: [AndroidDevice] = []
    /// The watcher fell back to polling `adb devices` (its `track-devices`
    /// child keeps failing). Only flashed so far; kept for a persistent
    /// sidebar indicator.
    private(set) var watcherDegraded = false
    /// AVD names read from emulator consoles (`adb emu avd name`), keyed by
    /// serial and valid only for the adb transport they were read from: an
    /// emulator serial is reused by whichever VM boots next, and that VM
    /// arrives on a new transport.
    var avdNamesBySerial: [String: (transportID: String?, avd: String)] = [:]

    private let adbClient: AdbClient?
    /// Folds one phone's adb transports (USB, IP:port, mDNS name) into one row.
    @ObservationIgnored private let grouper: AndroidDeviceGrouper
    /// Every adb serial that is not its phone's row, mapped to the row's
    /// serial, as of the last snapshot: the selection follows it
    /// (`AppModel.ensureDeviceSelection`).
    private(set) var serialAliases: [String: String] = [:]
    /// The mirrored device: its serial, port and AVD. Only `AppModel` writes it.
    private let context: ActiveDeviceContext
    private let status: StatusCenter
    private let grpcPorts: GrpcPortService

    /// The current emulator, whose process list answers the liveness probe.
    /// Settings' custom binary path swaps it at run time, so it is asked for
    /// at every use and never kept. Nil (no emulator) until its owner sets it.
    @ObservationIgnored var emulatorManagerProvider: @MainActor () -> EmulatorManager? = { nil }
    /// The AVD cards, whose serials name the AVD behind an emulator serial.
    @ObservationIgnored var avdCardsSource: @MainActor () -> [AvdCard] = { [] }
    /// A snapshot replaced the rows: its owner, which alone writes the
    /// selection, keeps it valid (`AppModel.ensureDeviceSelection()`).
    @ObservationIgnored var keepSelectionValid: @MainActor () -> Void = {}
    /// Re-reads the AVD cards' running state after a snapshot
    /// (`AvdCatalogController.refreshAvdRunningState()`).
    @ObservationIgnored var refreshAvdCards: @MainActor () async -> Void = {}

    init(
        adbClient: AdbClient?,
        context: ActiveDeviceContext,
        status: StatusCenter,
        grpcPorts: GrpcPortService
    ) {
        self.adbClient = adbClient
        self.grouper = AndroidDeviceGrouper(adb: adbClient)
        self.context = context
        self.status = status
        self.grpcPorts = grpcPorts
    }

    // MARK: - Lifecycle coordinators

    /// A workspace's own coordinator joins the pump (`WorkspaceRegistry.register`).
    /// Idempotent per workspace.
    func registerLifecycle(_ coordinator: DeviceLifecycleCoordinator, workspace id: WorkspaceID) {
        guard coordinators[id] == nil else { return }
        coordinators[id] = coordinator
        coordinatorOrder.append(id)
    }

    /// A closing workspace leaves the pump (`WorkspaceRegistry.unregister`),
    /// stopping its own timers first, and gives up whatever ghost its own
    /// episode was holding.
    func unregisterLifecycle(workspace id: WorkspaceID) {
        coordinators[id]?.stop()
        coordinators[id] = nil
        coordinatorOrder.removeAll { $0 == id }
        if ghosts.removeValue(forKey: id) != nil {
            rebuildGhostDevices()
        }
    }

    // MARK: - Watcher and snapshots

    /// Idempotent watcher startup: one `DeviceWatcher` per app run. Hot-plug
    /// truth flows through here (spec §5.4) to every registered workspace's
    /// coordinator, in registration order; `refresh()` keeps its manual role.
    /// Every already-registered coordinator is reset first, so this run
    /// begins exactly as the old app-global coordinator always did — a
    /// fresh `SessionLifecycle`, no leftover episode from a previous run.
    func startDeviceLifecycle() {
        guard deviceWatcher == nil, let adbClient, adbClient.isResolved else { return }
        for id in coordinatorOrder {
            coordinators[id]?.reset()
        }
        let watcher = DeviceWatcher(adbURL: adbClient.adbURL)
        deviceWatcher = watcher
        let stream = watcher.events()
        pumpTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.pumpGrouped(event)
            }
        }
        watcher.start()
        isLifecycleRunning = true
    }

    /// Quit hygiene (S1): the `track-devices` child is this app's own
    /// process, so termination has to stop it explicitly. Idempotent, so the
    /// `willTerminate` observer and any direct call can both run it. Every
    /// registered coordinator is reset — its own timers cancelled, its
    /// episode cleared and reported, so no workspace's waiting panel
    /// outlives the watcher it was waiting on — but, unlike the old
    /// app-global coordinator, it stays registered: a workspace's episode
    /// decider lives as long as the workspace does, not as long as the
    /// watcher runs, and the next `startDeviceLifecycle`
    /// resumes pumping to the very same coordinators.
    func stopDeviceLifecycle() {
        pumpTask?.cancel()
        pumpTask = nil
        deviceWatcher?.stop()
        deviceWatcher = nil
        isLifecycleRunning = false
        for id in coordinatorOrder {
            coordinators[id]?.reset()
        }
    }

    /// Hands one watcher event to every registered coordinator's own
    /// decider, in registration order — never its `applySnapshot` hook
    /// (`DeviceLifecycleCoordinator.decide(_:)`) — so every workspace's own
    /// `setGhost`/`teardown` decision for this event lands before anything
    /// downstream (selection fix-up, Info/AVD-name pruning) runs. Only once
    /// every coordinator has decided does a `.snapshot` event apply, exactly
    /// once, over every workspace's now-settled ghost state.
    private func pump(_ event: DeviceWatcherEvent, aliases: [String: String] = [:]) {
        for id in coordinatorOrder {
            coordinators[id]?.decide(event, aliases: aliases)
        }
        if case .snapshot(let devices, let degraded) = event {
            serialAliases = aliases
            applyWatcherSnapshot(devices, degraded: degraded)
        }
    }

    /// A snapshot's entries are folded per physical phone first
    /// (`AndroidDeviceGrouper`: `ro.serialno` read once per IP:port serial),
    /// so every coordinator and the sidebar see one row per phone.
    private func pumpGrouped(_ event: DeviceWatcherEvent) async {
        guard case .snapshot(let raw, let degraded) = event else {
            pump(event)
            return
        }
        let grouped = await grouper.group(raw)
        pump(.snapshot(devices: grouped.devices, degraded: degraded), aliases: grouped.aliases)
    }

    /// `adb devices -l` with one row per physical phone, for Refresh and the
    /// flows that re-read the list. Does not commit the grouper's memory, so
    /// the watcher's lifecycle still hears a transport move.
    func listGroupedDevices() async throws -> [AndroidDevice] {
        guard let adbClient else { return [] }
        let grouped = await grouper.group(try await adbClient.listDevices(), commit: false)
        serialAliases = grouped.aliases
        return grouped.devices
    }

    /// The watcher's snapshot replaces `devices`; every workspace's ghost of
    /// a disconnected-but-selected device is merged in so the sidebar row,
    /// the selection and the status panel all come from existing code (spec
    /// §5.4). The pump (`pump(_:)`) calls this once per snapshot event,
    /// after every registered coordinator has decided its own episode, so
    /// every ghost this reads is already settled; a direct caller (a
    /// coordinator's own `handle(_:)`, or a test) may still call it any
    /// number of times, each recomputing from the current, authoritative
    /// state.
    func applyWatcherSnapshot(_ remote: [AndroidDevice], degraded: Bool) {
        watcherDegraded = degraded
        for device in remote {
            lastKnownDetails[device.serial] = device
        }
        // Bounded cache: only live rows and every workspace's ghost's
        // last-known details survive a snapshot, so hot-plug churn cannot
        // grow the map forever.
        var keep = Set(remote.map(\.serial))
        keep.formUnion(ghosts.values.map(\.serial))
        lastKnownDetails = lastKnownDetails.filter { keep.contains($0.key) }
        let present = Set(remote.map(\.serial))
        releaseVanishedEmulators(present: present)
        grpcCache.invalidate(missingFrom: present)
        setRealDevices(remote)
        pruneDeviceInfos(for: remote)
        pruneAvdNames(for: remote)
        ensureDeviceSelection()
        Task {
            // The AVD cards' running state is `ps` truth, not adb truth: a VM
            // killed outside the app must flip it with this snapshot (spec
            // §6.4). A hot-plugged device gets its Info without a Refresh.
            await refreshAvdRunningState()
            await loadInfos(for: remote)
        }
    }

    /// An emulator that left adb takes its control connection and its gRPC
    /// port reservation with it. The active mirror's port is kept: its VM
    /// may only be hidden from adb for a moment (the lifecycle's liveness
    /// check decides), and its own teardown releases it.
    private func releaseVanishedEmulators(present: Set<String>) {
        let vanished = realDevices.filter { $0.isEmulator && !present.contains($0.serial) }
        let ports = vanished.compactMap { grpcCache.port(for: $0.serial) }.filter { $0 != activePort }
        guard !ports.isEmpty else { return }
        for port in ports {
            EmulatorManager.releasePortReservation(port)
        }
        Task {
            for port in ports {
                await EmulatorControls.closeConnections(port: port)
            }
        }
    }

    /// Drops the Info of every serial that left adb or came back on another
    /// transport (a new VM on a reused emulator serial), so the sidebar and
    /// the Info panel never show the previous device's Android version.
    func pruneDeviceInfos(for remote: [AndroidDevice]) {
        let transports = Dictionary(
            remote.map { ($0.serial, $0.transportID) },
            uniquingKeysWith: { first, _ in first }
        )
        for serial in Array(deviceInfos.keys) {
            let isStale: Bool
            if let transport = transports[serial] {
                isStale = deviceInfoTransportIDs[serial].map { $0 != transport } ?? false
            } else {
                // A ghost keeps its Info while it waits to reconnect.
                isStale = !isGhostSerial(serial)
            }
            if isStale {
                deviceInfos[serial] = nil
                deviceInfoTransportIDs[serial] = nil
            }
        }
    }

    /// Forgets console answers for serials that left adb or changed transport.
    func pruneAvdNames(for remote: [AndroidDevice]) {
        let transports = Dictionary(
            remote.map { ($0.serial, $0.transportID) },
            uniquingKeysWith: { first, _ in first }
        )
        avdNamesBySerial = avdNamesBySerial.filter { serial, entry in
            guard let transport = transports[serial] else { return false }
            return transport == entry.transportID
        }
    }

    /// The only writer of `devices`' real rows (spec §5.2 amendment): every
    /// ghost is appended only while its serial is absent, so a present real
    /// row always survives untouched.
    func setRealDevices(_ remote: [AndroidDevice]) {
        realDevices = remote
        devices = named(GhostEntry.merge(snapshot: remote, ghosts: Set(ghostDevices())))
    }

    /// `devices` with each phone's marketing name from its Info ("Redmi Note
    /// 12 Pro" for adb's "2209116AG"); an emulator keeps its own.
    private func named(_ rows: [AndroidDevice]) -> [AndroidDevice] {
        rows.map { row in
            guard !row.isEmulator, let name = deviceInfos[row.serial]?.marketName, row.marketName != name else { return row }
            var named = row
            named.marketName = name
            return named
        }
    }

    /// AVD name → serial for the online emulators in `devices`, each console
    /// asked once per adb transport (`avdNamesBySerial`).
    func resolveAvdSerials(among devices: [AndroidDevice]) async -> [String: String] {
        var serials: [String: String] = [:]
        for device in devices where device.isEmulator && device.isOnline {
            if let avd = await avdName(of: device) {
                serials[avd] = device.serial
            }
        }
        return serials
    }

    /// The AVD `device` runs, from the cache or its console; nil while the
    /// console does not answer (asked again next time).
    func avdName(of device: AndroidDevice) async -> String? {
        if let cached = avdNamesBySerial[device.serial], cached.transportID == device.transportID {
            return cached.avd
        }
        guard let adbClient,
              // Best effort: an unanswered console is simply asked again later.
              let name = try? await adbClient.avdName(serial: device.serial)
        else { return nil }
        avdNamesBySerial[device.serial] = (device.transportID, name)
        return name
    }

    /// The AVD behind `serial` as far as the model knows it: the active
    /// mirror's, an AVD card's, or a console answer; nil for an unknown one.
    private func knownAvdName(forSerial serial: String) -> String? {
        if serial == activeSerial, let activeAvdName { return activeAvdName }
        if let card = avdCards.first(where: { $0.serial == serial }) { return card.name }
        return avdNamesBySerial[serial]?.avd
    }

    /// The lifecycle's liveness probe: whether the VM behind an emulator
    /// serial adb lost sight of still runs. An unknown AVD answers "no" (the
    /// mirror is torn down as before); a failed `ps` read answers "yes", so
    /// the mirror survives and the decider simply checks again later.
    func isEmulatorVMRunning(serial: String) async -> Bool {
        guard let emulatorManager, let avd = knownAvdName(forSerial: serial) else { return false }
        // Best effort: an unreadable process list is not evidence the VM died.
        guard let running = try? await emulatorManager.runningEmulators() else { return true }
        return running.contains { $0.avd == avd }
    }

    // MARK: - Ghost

    /// Every ghost serial across every workspace — exposed so the sidebar's
    /// "Hide Stopped" exemption (spec §4.5) can keep any ghost row visible,
    /// whichever workspace's episode is waiting on it.
    var ghostSerials: Set<String> { Set(ghosts.values.map(\.serial)) }

    /// `workspace`'s own ghost serial, if its episode is waiting on one.
    func ghostSerial(for workspace: WorkspaceID) -> String? {
        ghosts[workspace]?.serial
    }

    /// `workspace`'s episode sets or clears its own ghost — never another
    /// workspace's, so unplugging the device workspace 1 mirrors ghosts only
    /// workspace 1's row.
    func lifecycleSetGhost(_ serial: String?, workspace: WorkspaceID) {
        if let serial {
            ghosts[workspace] = WorkspaceGhost(serial: serial, status: ghosts[workspace]?.status ?? .unreachable)
        } else {
            ghosts[workspace] = nil
        }
        rebuildGhostDevices()
    }

    func lifecycleShowStatus(_ status: CanvasStatusKind, workspace: WorkspaceID) {
        guard var ghost = ghosts[workspace] else { return }
        ghost.status = status
        ghosts[workspace] = ghost
        rebuildGhostDevices()
    }

    private func isGhostSerial(_ serial: String) -> Bool {
        ghosts.values.contains { $0.serial == serial }
    }

    private func ghostDevices() -> [AndroidDevice] {
        ghosts.values.map { ghost in
            let last = lastKnownDetails[ghost.serial]
            return AndroidDevice(
                serial: ghost.serial,
                state: ghost.status == .unauthorized ? "unauthorized" : "offline",
                model: last?.model,
                product: last?.product,
                device: last?.device,
                transportID: last?.transportID
            )
        }
    }

    private func rebuildGhostDevices() {
        devices = named(GhostEntry.merge(snapshot: realDevices, ghosts: Set(ghostDevices())))
    }

    // MARK: - Device Info

    /// Reads `device`'s Info once per adb transport: a new VM on a reused
    /// emulator serial reads its own.
    func loadInfo(for device: AndroidDevice) async {
        guard let adbClient, device.isOnline else { return }
        if deviceInfos[device.serial] != nil,
           deviceInfoTransportIDs[device.serial] == .some(device.transportID) {
            return
        }
        // Best effort: a device that does not answer keeps no Info yet.
        guard let info = try? await adbClient.deviceInfo(serial: device.serial, isEmulator: device.isEmulator)
        else { return }
        storeDeviceInfo(info, for: device)
    }

    /// Records `info` as `device`'s, unless the serial has since left adb or
    /// moved to another transport (the read answered for a device that is
    /// gone).
    func storeDeviceInfo(_ info: DeviceInfo, for device: AndroidDevice) {
        guard let current = devices.first(where: { $0.serial == device.serial }),
              current.transportID == device.transportID
        else { return }
        deviceInfos[device.serial] = info
        deviceInfoTransportIDs[device.serial] = device.transportID
        if info.marketName != nil, !device.isEmulator {
            devices = named(devices)
        }
    }

    /// `loadInfo` for every online device at once: each read is an adb
    /// round trip, so a refresh no longer waits for them one by one.
    func loadInfos(for devices: [AndroidDevice]) async {
        await withTaskGroup(of: Void.self) { group in
            for device in devices where device.isOnline {
                group.addTask { await self.loadInfo(for: device) }
            }
        }
    }

    // MARK: - Shims

    // The gRPC ports, the mirrored device, its owner's emulator, cards,
    // selection and orchestrators, and `StatusCenter`, under the names the
    // moved call sites use, so their text is unchanged.

    private var grpcCache: GrpcPortService { grpcPorts }

    private var activeSerial: String? { context.serial }

    private var activePort: Int? { context.port }

    private var activeAvdName: String? { context.avdName }

    private var emulatorManager: EmulatorManager? { emulatorManagerProvider() }

    private var avdCards: [AvdCard] { avdCardsSource() }

    private func ensureDeviceSelection() {
        keepSelectionValid()
    }

    private func refreshAvdRunningState() async {
        await refreshAvdCards()
    }
}
