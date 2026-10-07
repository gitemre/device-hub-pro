import AppKit
import Foundation
import Observation
import DeviceHubProKit

/// The physical iPhones and iPads this Mac's CoreDevice lists, behind the
/// user's opt-in.
///
/// - "Show physical Apple devices" (`AppPreferences.showPhysicalAppleDevices`,
///   off by default) is the master switch. Off, this type runs nothing: not
///   one `devicectl list devices` (`ApplePhysicalDeviceLister.listCallCount`
///   proves it in the tests).
/// - On, `applyPreference()` polls the lister every `pollInterval` (5 s) while
///   the app is active, one listing at a time, until the preference goes off
///   or the app quits (`stop()`). The lister is given
///   `PhysicalDeviceOptIn.everyPhysicalDevice`, so every physical entry shows
///   in the sidebar, or, with `DHP_IPHONE_UDID` set, only that one
///   device (`iphoneUDID`).
/// - Listing is all a device gets until the user enables that device: every
///   row starts "Not enabled", "Use This Device…" (`requestEnable`, a
///   confirmation naming the device, then `enable`) records its hardware UDID
///   in the preferences, and "Stop Using This Device" removes it.
///   `client(for:)` is the only way to a `DevicectlPhysicalClient` and
///   answers nil for a device that is not enabled, paired and connected. The
///   `DHP_IPHONE_UDID` device counts as enabled without the dialog.
/// - Nothing is ever selected here: the sidebar never selects a physical
///   device on launch or when one appears.
///
/// Without a probed toolchain with a usable devicectl (`toolchain` answers
/// nil, as in tests without Apple tooling) it lists nothing and runs no
/// process.
@MainActor
@Observable
final class ApplePhysicalInventory {
    /// The devices of the last listing, by name.
    private(set) var entries: [ApplePhysicalEntry] = []
    /// Whether a listing has arrived since the preference was last turned
    /// on.
    private(set) var hasListed = false
    /// The last listing's failure, if it failed; the previous list stands.
    private(set) var listError: String?
    /// Restarts Device Hub Pro issued, by hardware UDID, with when they began: the
    /// row stays (devicectl reports a restarting phone unavailable, or not at
    /// all) until the device is connected again or `restartTimeout` passes.
    private(set) var restarting: [String: Date] = [:]
    /// "Use This Device…" was asked for this device: the confirmation shows
    /// until the user answers.
    var pendingEnable: ApplePhysicalEntry?

    /// The list changed, or the preference turned it off: its owner keeps
    /// the selection valid from here.
    @ObservationIgnored var listChanged: @MainActor () -> Void = {}
    /// The user stopped using a device (hardware UDID): what is kept for it
    /// is forgotten.
    @ObservationIgnored var deviceDisabled: @MainActor (String) -> Void = { _ in }

    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let iphoneUDID: String?
    @ObservationIgnored private let toolchain: @MainActor () async -> AppleToolchain?
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let isAppActive: @MainActor () -> Bool
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var isListing = false
    /// The listing in flight (it runs the follow-up too).
    @ObservationIgnored private var listingTask: Task<Void, Never>?
    /// Set by `refreshNow` while a listing runs: one more listing after it.
    @ObservationIgnored private var followUpRequested = false
    /// Bumped whenever a listing in flight must not be applied (the
    /// preference went off, the app is quitting).
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isStopped = false
    @ObservationIgnored private var clients: [String: DevicectlPhysicalClient] = [:]
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    /// Restarts whose device has been seen away (not connected, or not
    /// listed): only then does a connected listing end the restart.
    @ObservationIgnored private var restartSeenAway: Set<String> = []
    /// Whether any restart has seen its device away (a test's probe).
    var restartSeenAwayForTesting: Bool { !restartSeenAway.isEmpty }
    @ObservationIgnored private var restartExpiry: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }
    /// How long a restart keeps the row (3 minutes).
    @ObservationIgnored var restartTimeout: Duration = .seconds(180)

    /// - Parameters:
    ///   - iphoneUDID: `DHP_IPHONE_UDID` (`LaunchOptions.iphoneUDID`).
    ///   - toolchain: the probed Apple toolchain (the simulator provider's
    ///     probe, which runs once); nil answers mean no devicectl.
    ///   - isAppActive: whether the app is active; a listing is skipped
    ///     while it is not. Defaults to the running application's state
    ///     (true where there is none, as in tests); `DHP_LAUNCH_INACTIVE`
    ///     runs count as active, or an agent-driven run would never list.
    init(
        preferences: AppPreferences,
        iphoneUDID: String?,
        launchInactive: Bool = false,
        toolchain: @escaping @MainActor () async -> AppleToolchain?,
        pollInterval: Duration = .seconds(5),
        isAppActive: (@MainActor () -> Bool)? = nil
    ) {
        self.preferences = preferences
        self.iphoneUDID = iphoneUDID.map(PhysicalDeviceOptIn.normalize).flatMap { $0.isEmpty ? nil : $0 }
        self.toolchain = toolchain
        self.pollInterval = pollInterval
        self.isAppActive = isAppActive ?? { launchInactive || (NSApp?.isActive ?? true) }
    }

    /// The plain sentence for a failed listing, the tool's own words kept for
    /// "Show Details".
    nonisolated static func listFailure(_ raw: String) -> PlainFailure {
        PlainFailure.make(raw, fallback: "Couldn\u{2019}t look for iPhones connected to this Mac.")
    }

    // MARK: - Reading

    /// Whether the preference is on: the app looks for devices.
    var isShowing: Bool { preferences.showPhysicalAppleDevices }

    /// The listed device with this hardware UDID.
    func entry(udid: String) -> ApplePhysicalEntry? {
        let key = PhysicalDeviceOptIn.normalize(udid)
        return entries.first { $0.id == key }
    }

    /// The UDIDs the sidebar lists.
    var listedUDIDs: [String] { entries.map(\.id) }

    /// The `DHP_IPHONE_UDID` restriction, if any.
    var restrictedUDID: String? { iphoneUDID }

    // MARK: - Preference and polling

    /// Turns "Show physical Apple devices" on or off, and starts or stops
    /// the poll to match.
    func setShowing(_ show: Bool) {
        guard show != preferences.showPhysicalAppleDevices else { return }
        preferences.setShowPhysicalAppleDevices(show)
        applyPreference()
    }

    /// Starts the poll when the preference is on and it is not running;
    /// stops it, and forgets the list, when it is off. Idempotent: the
    /// launch refresh of every window calls it.
    func applyPreference() {
        guard !isStopped else { return }
        if preferences.showPhysicalAppleDevices {
            startPolling()
        } else {
            stopPolling()
            clearList()
        }
    }

    /// Lists now (the Refresh command), in place of waiting for the poll.
    /// A listing already in flight may have read the devices before the
    /// action that asked: one more listing follows it, and this returns once
    /// that one is done.
    func refreshNow() async {
        if let running = listingTask {
            followUpRequested = true
            await running.value
            return
        }
        await listOnce()
    }

    /// Stops for good (quit): the poll ends and a listing in flight is not
    /// applied.
    func stop() {
        isStopped = true
        stopPolling()
        generation += 1
        clients.removeAll()
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        if activationObserver == nil {
            // Back from another app: list at once, not at the next tick.
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.listOnce() }
            }
        }
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // A restart in progress is polled even while the app is in
                // the background: its row must come back on its own.
                if self.isAppActive() || !self.restarting.isEmpty {
                    await self.listOnce()
                }
                // Cancellation is checked at the top of the loop.
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        generation += 1
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    // MARK: - Restarts

    /// A restart was issued for the device: its row stays, reading
    /// "Restarting\u{2026}", until the device is connected again or three
    /// minutes pass.
    func beginRestart(udid: String) {
        let key = PhysicalDeviceOptIn.normalize(udid)
        guard entry(udid: key) != nil else { return }
        restarting[key] = now()
        restartSeenAway.remove(key)
        clients[key] = nil
        restartExpiry[key]?.cancel()
        let timeout = restartTimeout
        restartExpiry[key] = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.endRestart(key)
            // Past the timeout the list says what is true: back, or gone.
            await self?.listOnce()
        }
        reapplyEnabledFlags()
    }

    private func endRestart(_ key: String) {
        guard restarting[key] != nil else { return }
        restarting[key] = nil
        restartSeenAway.remove(key)
        restartExpiry[key]?.cancel()
        restartExpiry[key] = nil
        reapplyEnabledFlags()
    }

    /// Folds the restarts into a listing: a device that is back (connected,
    /// after it was seen away) or past the timeout ends its restart; a
    /// restarting device the listing lacks keeps its last row.
    private func applyRestarts(to devices: [ApplePhysicalDevice]) -> [ApplePhysicalDevice] {
        var devices = devices
        for (key, started) in restarting {
            let listed = devices.first { PhysicalDeviceOptIn.normalize($0.hardwareUDID) == key }
            let expired = now().timeIntervalSince(started) >= Double(restartTimeout.components.seconds)
            if listed?.isConnected == true {
                if restartSeenAway.contains(key) || expired { endRestart(key) }
            } else {
                restartSeenAway.insert(key)
                if expired {
                    endRestart(key)
                } else if listed == nil, let last = entry(udid: key) {
                    devices.append(last.device)
                }
            }
        }
        return devices
    }

    private func clearList() {
        for task in restartExpiry.values { task.cancel() }
        restartExpiry.removeAll()
        restarting.removeAll()
        restartSeenAway.removeAll()
        clients.removeAll()
        listError = nil
        hasListed = false
        pendingEnable = nil
        if !entries.isEmpty {
            entries = []
        }
        listChanged()
    }

    /// One listing: never overlaps another, never runs with the preference
    /// off, and is dropped when the preference went off (or the app is
    /// quitting) while it ran.
    private func listOnce() async {
        guard preferences.showPhysicalAppleDevices, !isStopped, !isListing, listingTask == nil else { return }
        let task = Task { @MainActor [self] in
            repeat {
                followUpRequested = false
                await listPass()
            } while followUpRequested && !isStopped
            listingTask = nil
        }
        listingTask = task
        await task.value
    }

    private func listPass() async {
        guard preferences.showPhysicalAppleDevices, !isStopped else { return }
        isListing = true
        defer { isListing = false }
        let started = generation
        guard let lister = await toolchain()?.makePhysicalDeviceLister() else { return }
        guard started == generation, preferences.showPhysicalAppleDevices, !isStopped else { return }
        let optIn = iphoneUDID.flatMap { PhysicalDeviceOptIn(allowedHardwareUDIDs: [$0]) }
            ?? .everyPhysicalDevice
        do {
            let devices = try await lister.list(optIn: optIn)
            guard started == generation, preferences.showPhysicalAppleDevices, !isStopped else { return }
            listError = nil
            apply(devices)
        } catch {
            guard started == generation, !isStopped else { return }
            // A failed listing keeps the last list: an empty one would read
            // as "every device unplugged".
            listError = "\(error)"
        }
    }

    private func apply(_ devices: [ApplePhysicalDevice]) {
        var listed = applyRestarts(to: devices).map(makeEntry)
        listed.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        hasListed = true
        if listed != entries {
            entries = listed
        }
        dropStaleClients()
        listChanged()
    }

    private func makeEntry(_ device: ApplePhysicalDevice) -> ApplePhysicalEntry {
        let udid = PhysicalDeviceOptIn.normalize(device.hardwareUDID)
        let byLaunchOption = iphoneUDID == udid
        return ApplePhysicalEntry(
            device: device,
            isEnabled: byLaunchOption || preferences.isPhysicalAppleDeviceEnabled(udid),
            isEnabledByLaunchOption: byLaunchOption,
            isRestarting: restarting[udid] != nil
        )
    }

    private func dropStaleClients() {
        for (udid, client) in clients {
            guard let entry = entry(udid: udid), entry.canUseClient,
                  entry.device.coreDeviceIdentifier == client.device.coreDeviceIdentifier
            else {
                clients[udid] = nil
                continue
            }
        }
    }

    // MARK: - Enabling a device

    /// "Use This Device…": shows the confirmation naming the device. Nothing
    /// is recorded until `enable(udid:)`.
    func requestEnable(_ entry: ApplePhysicalEntry) {
        guard !entry.isEnabled else { return }
        pendingEnable = entry
    }

    /// The user confirmed: the device is enabled from now on (persisted).
    func enable(udid: String) {
        pendingEnable = nil
        guard let entry = entry(udid: udid) else { return }
        preferences.setPhysicalAppleDevice(entry.udid, enabled: true)
        reapplyEnabledFlags()
    }

    /// "Stop Using This Device": nothing more is sent to it. A device
    /// `DHP_IPHONE_UDID` names stays enabled for the run.
    func disable(udid: String) {
        let key = PhysicalDeviceOptIn.normalize(udid)
        preferences.setPhysicalAppleDevice(key, enabled: false)
        clients[key] = nil
        reapplyEnabledFlags()
        deviceDisabled(key)
    }

    private func reapplyEnabledFlags() {
        let updated = entries.map { makeEntry($0.device) }
        if updated != entries {
            entries = updated
        }
        dropStaleClients()
        listChanged()
    }

    // MARK: - Pairing a nearby phone (Pair Nearby Device sheet)

    /// The listed iPhones that are not paired with this Mac: what the Pair
    /// Nearby Device sheet offers.
    var pairCandidates: [ApplePhysicalEntry] {
        entries.filter { $0.device.isUnpairedPhone }
    }

    /// The listed iPhones that are already paired with this Mac: the Pair
    /// Nearby Device sheet shows them greyed under "Already Paired", so a
    /// paired phone is not mistaken for a missing one.
    var pairedPhones: [ApplePhysicalEntry] {
        entries.filter { $0.device.isPaired && ($0.device.productType ?? $0.device.marketingName ?? "").hasPrefix("iPhone") }
    }

    enum PairNearbyError: Error, Equatable, CustomStringConvertible {
        /// The phone is not listed as an unpaired iPhone, the preference is
        /// off, or devicectl is unusable.
        case unavailable
        var description: String { "The iPhone is no longer listed as waiting to pair." }
    }

    /// Pairs a listed, unpaired iPhone (`devicectl manage pair --device`,
    /// the user's own action in the Pair Nearby Device sheet) and, once
    /// CoreDevice answers, enables it ("Use This Device") so it shows up
    /// ready in the sidebar. The only other place besides `client(for:)`
    /// where a client is made; it refuses a device that is paired already.
    func pairNearby(udid: String) async throws {
        let key = PhysicalDeviceOptIn.normalize(udid)
        guard !isStopped, preferences.showPhysicalAppleDevices,
              let entry = entry(udid: key), entry.device.isUnpairedPhone,
              let toolchain = await toolchain(),
              // Best effort: an unusable devicectl is simply unavailable.
              let client = try? toolchain.makeDevicectlPhysicalClient(for: entry.device)
        else { throw PairNearbyError.unavailable }
        try await client.pair()
        preferences.setPhysicalAppleDevice(key, enabled: true)
        await refreshNow()
        reapplyEnabledFlags()
    }

    // MARK: - The client

    /// A read and manage client for the device, or nil unless the device is
    /// listed, enabled, paired and connected (or devicectl is unusable). The
    /// only way the app reaches a physical device with a command other than
    /// the list.
    func client(for udid: String) async -> DevicectlPhysicalClient? {
        let key = PhysicalDeviceOptIn.normalize(udid)
        guard !isStopped, preferences.showPhysicalAppleDevices,
              let entry = entry(udid: key), entry.canUseClient
        else { return nil }
        if let client = clients[key], client.device.coreDeviceIdentifier == entry.device.coreDeviceIdentifier {
            return client
        }
        guard let toolchain = await toolchain(),
              // Best effort: an unusable devicectl is simply no client.
              let client = try? toolchain.makeDevicectlPhysicalClient(for: entry.device),
              // The device may have been disabled while the toolchain answered.
              let current = self.entry(udid: key), current.canUseClient
        else { return nil }
        clients[key] = client
        return client
    }
}
