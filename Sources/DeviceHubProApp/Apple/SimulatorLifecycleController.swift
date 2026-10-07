import Foundation
import Observation
import DeviceHubProKit

/// Boots, shuts down, restarts, erases, renames, deletes and clones
/// simulators, and decides when a booted one is ready.
///
/// **Ready** takes three conditions (`SimulatorReadiness`): `simctl
/// bootstatus` reports Finished, the runtime's home screen process
/// (SpringBoard; PineBoard on tvOS; none known on other platforms) has a pid
/// in `simctl spawn <UDID> launchctl list`, and the screen shows the home
/// screen rather than the boot screen (`screenContent`: the live canvas's
/// frame while one runs for the simulator — the stage starts it under the
/// booting page once the home screen is waited for — else a `simctl io
/// screenshot`). `simctl list`
/// says Booted about a second into a boot that takes 25–45 s, SpringBoard
/// runs from its first seconds, and a warm boot reports Finished while the
/// Apple logo still shows, so none of the first two will do alone. A screen
/// that stays dark (nothing lit, or no picture at all) for `screenOffGrace`
/// after the first two is a screen that is off — one powered off with
/// `simctl io <UDID> screenConfig power off`, on which a screenshot waits
/// 61 s; a locked iOS 27.0 simulator still shows its lock screen — and
/// counts as ready too; a tvOS boot showed 3.6 s of black between its boot
/// screen and its home screen. A boot this
/// controller starts is followed through its phases (`readiness`); a
/// simulator booted elsewhere (Xcode, Device Hub, a script) is followed the
/// same way once a listing shows it booted (`noteSnapshot`), so it too reads
/// "booting" until it is ready. One that read as not responding is followed
/// again from the start on a Refresh (`refollowUnresponsive`).
///
/// One operation per simulator at a time (`operations`: the sidebar's
/// "Starting", "Stopping", "Erasing", …). Shut Down, Restart, Erase and
/// Delete may interrupt a boot that is waiting to be ready; a rename runs
/// beside such a wait; nothing else overlaps. Erasing a running simulator
/// shuts it down, erases it and boots it again (simctl refuses to erase a
/// booted device), as Device Hub's Reset does. Deleting one removes its
/// `~/Library/Logs/CoreSimulator/<UDID>` folder too, which `simctl delete`
/// can leave behind.
///
/// `bootedByDeviceHubPro` holds the simulators this controller booted and has
/// not seen shut down since: the Quit choice may offer to shut those down,
/// and only those (Device Hub Pro never shuts down a simulator it did not boot).
/// A restart or an erase keeps a simulator's owner.
///
/// Every call goes through `SimctlClient` with the simulator's UDID, never a
/// selector, and every failure lands in the status alert. It holds no
/// reference to the model: the client, the listing, the logs folder and the
/// list reload come through the hooks `AppModel` sets.
@MainActor
@Observable
final class SimulatorLifecycleController {
    /// What the controller is doing to a simulator.
    enum Operation: Equatable, Sendable {
        case starting
        case stopping
        case restarting
        case erasing
        case renaming
        case deleting
        case cloning

        /// The sidebar's subtitle while it runs; "Starting" and "Stopping"
        /// are Device Hub's.
        var label: String {
            switch self {
            case .starting: "Starting"
            case .stopping: "Stopping"
            case .restarting: "Restarting"
            case .erasing: "Erasing"
            case .renaming: "Renaming"
            case .deleting: "Removing"
            case .cloning: "Cloning"
            }
        }
    }

    /// What quitting does with the simulators this controller started
    /// (Device Hub's quit choice, A5). Never anything with the others.
    enum QuitChoice: Equatable, Sendable {
        /// Shut them down.
        case shutDownStarted
        /// Leave them running.
        case keepRunning

        var opposite: QuitChoice {
            self == .shutDownStarted ? .keepRunning : .shutDownStarted
        }

        /// The app menu item that quits this way.
        var menuTitle: String {
            switch self {
            case .shutDownStarted: "Quit and Shut Down Simulators Device Hub Pro Started"
            case .keepRunning: "Quit and Keep Simulators Running"
            }
        }

        /// The saved default (Settings): shut them down, or keep them.
        init(shutsDownByDefault: Bool) {
            self = shutsDownByDefault ? .shutDownStarted : .keepRunning
        }
    }

    /// Where a booted simulator is on its way to ready.
    enum Readiness: Equatable, Sendable {
        case waiting(DeviceBootPhase)
        case ready
        /// The boot status, the home screen process or the home screen did
        /// not come within the bounds: running, but not answering.
        case unresponsive
    }

    /// The operation in flight per UDID.
    private(set) var operations: [String: Operation] = [:]
    /// What is known about each booted simulator's way to ready.
    private(set) var readiness: [String: Readiness] = [:]
    /// The simulators this controller booted and has not seen shut down.
    private(set) var bootedByDeviceHubPro: Set<String> = []
    /// The simulators whose boot in flight is their first (`lastUsedAt` was
    /// empty when it started). Device Hub shows such a boot as a bare spinner
    /// until the display is up, where a later boot shows the device with a
    /// black screen from the first second (`SimulatorStageView`).
    private(set) var firstBoots: Set<String> = []
    /// The state an operation holds a simulator in while it shuts it down or
    /// has it off; it ends with the operation, whose last step re-reads the
    /// list.
    private var transitions: [String: DeviceRunState] = [:]

    /// simctl on the listed set; nil without Apple tooling.
    @ObservationIgnored var simctlSource: @MainActor () -> SimctlClient? = { nil }
    /// Where CoreSimulator keeps each device's log folder.
    @ObservationIgnored var logsDirectorySource: @MainActor () -> URL? = { nil }
    /// The listed simulator with a UDID.
    @ObservationIgnored var entrySource: @MainActor (_ udid: String) -> SimulatorEntry? = { _ in nil }
    /// The latest listing, read when an operation is released to catch up
    /// on listings that arrived while it ran (`noteSnapshot`).
    @ObservationIgnored var snapshotSource: @MainActor () -> [SimulatorEntry] = { [] }
    /// The simulators a listing skipped because an operation was in flight.
    @ObservationIgnored private var skippedWhileBusy: Set<String> = []
    /// Reads the list again, now: every operation does before it ends, so
    /// the listing it leaves behind is current.
    @ObservationIgnored var reloadList: @MainActor () async -> Void = {}
    /// The time zone a boot this controller starts gives the simulator
    /// (`SIMCTL_CHILD_TZ`; simctl has no time-zone command): the Controls'
    /// choice for that UDID, nil for the Mac's zone. A boot started
    /// elsewhere never takes it.
    @ObservationIgnored var timeZoneSource: @MainActor (_ udid: String) -> String? = { _ in nil }
    /// Called once a boot reaches ready, with whether this controller
    /// started that boot (`simctl boot` from Boot, Restart or Erase) rather
    /// than followed one started elsewhere (Xcode, Simulator.app, a script)
    /// or followed again on a Refresh: the Controls set their kept location
    /// again only after a boot Device Hub Pro started, as the time zone applies
    /// only to those.
    @ObservationIgnored var becameReady: @MainActor (_ udid: String, _ bootStartedHere: Bool) -> Void = { _, _ in }

    /// What the simulator's screen shows: the home screen, the boot screen
    /// or nothing lit; nil when no picture could be read. By default a
    /// `simctl io screenshot` (`screenshotContent`); `AppModel` answers
    /// from the live canvas's frame while one runs for the simulator
    /// (`SimulatorCanvasController.screenContentFromCanvas`).
    @ObservationIgnored var screenContent: @MainActor (
        _ udid: String,
        _ simctl: SimctlClient
    ) async -> SimulatorReadiness.ScreenContent? = SimulatorLifecycleController.screenshotContent
    /// How often the home screen process and the screen are looked at once
    /// the boot status is Finished.
    @ObservationIgnored var homeScreenPollInterval: Duration = .milliseconds(500)
    /// How long the home screen process and the home screen may take after
    /// Finished before the simulator reads as not responding.
    @ObservationIgnored var homeScreenTimeout: Duration = .seconds(60)
    /// How long the screen must stay dark (or give no picture) once the
    /// home screen process runs before it reads as off, and the simulator as
    /// ready: well above the 3.6 s of black a tvOS boot showed.
    @ObservationIgnored var screenOffGrace: Duration = .seconds(10)
    /// The bound on one `bootstatus` run (a first boot migrates data).
    @ObservationIgnored var bootStatusTimeout: Duration = SimctlClient.bootTimeout

    @ObservationIgnored private let status: StatusCenter
    /// The claim behind each operation, so an interrupted one cannot end its
    /// successor's.
    @ObservationIgnored private var claims: [String: Int] = [:]
    @ObservationIgnored private var nextClaim = 0
    /// The readiness waits running, per UDID.
    @ObservationIgnored private var readinessWaits: [String: Task<Readiness?, Never>] = [:]
    /// Set for good by `stop()` (quit): no listing or boot starts a wait
    /// after it.
    @ObservationIgnored private var isStopped = false

    init(status: StatusCenter) {
        self.status = status
    }

    // MARK: - Reading

    /// `entry`'s state: the operation's hold, else its way to ready, else the
    /// listing's state.
    func runState(for entry: SimulatorEntry) -> DeviceRunState {
        if let transition = transitions[entry.udid] { return transition }
        switch readiness[entry.udid] {
        case .ready?: return .ready
        case .waiting(let phase)?: return .booting(phase)
        case .unresponsive?: return .unreachable
        case nil: break
        }
        switch entry.state {
        case .shutdown, .creating: return .stopped
        // Booted is not ready: until its readiness is known it is booting.
        case .booted, .booting: return .booting(.launching)
        case .shuttingDown: return .shuttingDown
        case .other: return .unreachable
        }
    }

    func isReady(_ udid: String) -> Bool {
        readiness[udid] == .ready
    }

    // MARK: - Operations

    /// Boots the simulator and follows it to ready. A simulator that is
    /// already booted (by someone else) is only followed, and does not
    /// become Device Hub Pro's. Returns whether it became ready.
    @discardableResult
    func boot(_ udid: String) async -> Bool {
        guard let simctl = simctlSource(), let claim = claim(udid, .starting) else { return false }
        defer { release(udid, claim) }
        return await bootAndWait(udid, simctl: simctl, claim: claim, becomesOurs: true)
    }

    /// Shuts the simulator down; one that is already shut down counts as
    /// done.
    @discardableResult
    func shutDown(_ udid: String) async -> Bool {
        guard let simctl = simctlSource(), let claim = claim(udid, .stopping, interruptsBoot: true) else {
            return false
        }
        defer { release(udid, claim) }
        guard await shutDownNow(udid, simctl: simctl, failure: "Could not shut down") else { return false }
        bootedByDeviceHubPro.remove(udid)
        await reloadList()
        return true
    }

    /// Shuts the simulator down and boots it again, keeping its owner.
    @discardableResult
    func restart(_ udid: String) async -> Bool {
        guard let simctl = simctlSource(), let claim = claim(udid, .restarting, interruptsBoot: true) else {
            return false
        }
        defer { release(udid, claim) }
        let wasOurs = bootedByDeviceHubPro.contains(udid)
        guard await shutDownNow(udid, simctl: simctl, failure: "Could not restart") else { return false }
        return await bootAndWait(udid, simctl: simctl, claim: claim, becomesOurs: wasOurs)
    }

    /// Erases content and settings. A running simulator is shut down first
    /// and booted again after, keeping its owner; a listing that still says
    /// Shutdown about a running one is caught by simctl's refusal.
    @discardableResult
    func erase(_ udid: String) async -> Bool {
        guard let simctl = simctlSource(), let claim = claim(udid, .erasing, interruptsBoot: true) else {
            return false
        }
        defer { release(udid, claim) }
        let wasOurs = bootedByDeviceHubPro.contains(udid)
        var wasRunning = isRunning(udid)
        if wasRunning {
            guard await shutDownNow(udid, simctl: simctl, failure: "Could not erase") else { return false }
        }
        do {
            do {
                try await simctl.erase(udid: udid)
            } catch let failure as SimctlFailure where failure.kind == .invalidState && !wasRunning {
                // The listing was behind: the simulator runs.
                wasRunning = true
                guard await shutDownNow(udid, simctl: simctl, failure: "Could not erase") else { return false }
                try await simctl.erase(udid: udid)
            }
        } catch {
            transitions[udid] = nil
            fail("Could not erase", udid, error)
            return false
        }
        guard wasRunning else {
            await reloadList()
            return true
        }
        return await bootAndWait(udid, simctl: simctl, claim: claim, becomesOurs: wasOurs)
    }

    /// Renames the simulator (simctl renames a booted one too). A rename may
    /// run while a boot waits to be ready.
    @discardableResult
    func rename(_ udid: String, to newName: String) async -> Bool {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            status.errorMessage = "A simulator needs a name."
            return false
        }
        guard let simctl = simctlSource() else { return false }
        let claim: Int?
        if operations[udid] == nil {
            claim = self.claim(udid, .renaming)
            guard claim != nil else { return false }
        } else if readinessWaits[udid] != nil {
            claim = nil
        } else {
            return false
        }
        defer {
            if let claim { release(udid, claim) }
        }
        do {
            try await simctl.rename(udid: udid, to: name)
        } catch {
            fail("Could not rename", udid, error)
            return false
        }
        await reloadList()
        return true
    }

    /// Deletes the simulator, shutting it down first when it runs, and
    /// removes its CoreSimulator log folder.
    @discardableResult
    func delete(_ udid: String) async -> Bool {
        guard let simctl = simctlSource(), let claim = claim(udid, .deleting, interruptsBoot: true) else {
            return false
        }
        defer { release(udid, claim) }
        var wasRunning = isRunning(udid)
        if wasRunning {
            guard await shutDownNow(udid, simctl: simctl, failure: "Could not delete") else { return false }
        }
        do {
            do {
                try await simctl.delete(udid: udid)
            } catch let failure as SimctlFailure where failure.kind == .invalidState && !wasRunning {
                wasRunning = true
                guard await shutDownNow(udid, simctl: simctl, failure: "Could not delete") else { return false }
                try await simctl.delete(udid: udid)
            }
        } catch {
            transitions[udid] = nil
            fail("Could not delete", udid, error)
            return false
        }
        forget(udid)
        await removeLogFolder(of: udid)
        await reloadList()
        return true
    }

    /// Clones a shut-down simulator under `newName` and returns the clone's
    /// UDID; simctl cannot clone a running one.
    @discardableResult
    func clone(_ udid: String, as newName: String) async -> String? {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            status.errorMessage = "A simulator needs a name."
            return nil
        }
        guard let simctl = simctlSource(), let claim = claim(udid, .cloning) else { return nil }
        defer { release(udid, claim) }
        let cloned: String
        do {
            cloned = try await simctl.clone(udid: udid, name: name)
        } catch let failure as SimctlFailure where failure.kind == .invalidState {
            status.errorMessage = "Shut down \(displayName(udid)) before cloning it."
            return nil
        } catch {
            fail("Could not clone", udid, error)
            return nil
        }
        await reloadList()
        return cloned
    }

    /// Creates a simulator (`simctl create`, the New Simulator sheet) and
    /// returns its UDID once the list shows it. simctl refuses a device type
    /// the runtime does not run (SimError 403 "Incompatible device").
    @discardableResult
    func create(name: String, deviceTypeIdentifier: String, runtimeIdentifier: String) async -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            status.errorMessage = "A simulator needs a name."
            return nil
        }
        guard let simctl = simctlSource() else { return nil }
        let progress = "Creating \(name)…"
        status.showProgress(progress)
        defer { status.clear(ifShowing: progress) }
        let created: String
        do {
            created = try await simctl.create(
                name: name,
                deviceTypeIdentifier: deviceTypeIdentifier,
                runtimeIdentifier: runtimeIdentifier
            )
        } catch {
            let reason = (error as? SimctlFailure)?.message ?? "\(error)"
            status.errorMessage = "Could not create \(name): \(reason)"
            return nil
        }
        await reloadList()
        return created
    }

    // MARK: - Listing

    /// A new listing. Simulators with an operation in flight are left to it.
    /// For the others: one that is booted with nothing known about it (booted
    /// elsewhere, or found booted at launch) is followed to ready; one that is
    /// shut down or shutting down loses its readiness, and a shut-down one
    /// its owner; one that is gone is forgotten.
    func noteSnapshot(_ entries: [SimulatorEntry]) {
        guard !isStopped else { return }
        let listed = Set(entries.map(\.udid))
        let known = Set(readiness.keys).union(readinessWaits.keys).union(bootedByDeviceHubPro).union(transitions.keys)
        for udid in known.subtracting(listed) {
            if operations[udid] == nil { forget(udid) } else { skippedWhileBusy.insert(udid) }
        }
        for entry in entries {
            if operations[entry.udid] != nil {
                skippedWhileBusy.insert(entry.udid)
                continue
            }
            switch entry.state {
            case .booted, .booting:
                if readiness[entry.udid] == nil, readinessWaits[entry.udid] == nil {
                    followExternalBoot(entry.udid)
                }
            case .shutdown:
                cancelReadinessWait(entry.udid)
                readiness[entry.udid] = nil
                bootedByDeviceHubPro.remove(entry.udid)
            case .shuttingDown:
                cancelReadinessWait(entry.udid)
                readiness[entry.udid] = nil
            case .creating, .other:
                break
            }
        }
    }

    /// Follows every simulator that reads as not responding again, from the
    /// start (the Refresh command): one that was slow to answer, or whose
    /// screen was off, recovers without a restart. One with an operation in
    /// flight is left to it.
    func refollowUnresponsive() {
        guard !isStopped else { return }
        let unresponsive = readiness.filter { $0.value == .unresponsive }.map(\.key).sorted()
        for udid in unresponsive where operations[udid] == nil && readinessWaits[udid] == nil {
            followExternalBoot(udid, startedHere: bootedByDeviceHubPro.contains(udid))
        }
    }

    // MARK: - Quit

    /// The choice the quit in progress was asked for (the app menu's Option
    /// alternate); nil for the saved default.
    @ObservationIgnored var quitChoiceOverride: QuitChoice?

    /// What this quit does with the simulators this controller started: the
    /// alternate's choice, else the saved default.
    func quitChoice(shutsDownByDefault: Bool) -> QuitChoice {
        quitChoiceOverride ?? QuitChoice(shutsDownByDefault: shutsDownByDefault)
    }

    /// Quit: shuts down `udids` (the simulators this controller booted and
    /// has not seen shut down, `bootedByDeviceHubPro`, read before the quit
    /// stops the controller) all at once, and returns those that are down,
    /// one that already was included. A failure leaves the simulator
    /// running: the app is quitting, there is no one to tell. simctl hands
    /// the request to CoreSimulatorService, so a shutdown the quit's bound
    /// abandons still completes.
    nonisolated static func shutDownForQuit(_ udids: Set<String>, simctl: SimctlClient) async -> Set<String> {
        await withTaskGroup(of: String?.self) { group in
            for udid in udids where UUID(uuidString: udid) != nil {
                group.addTask {
                    do {
                        try await simctl.shutdown(udid: udid)
                    } catch let refusal as SimctlFailure where refusal.kind == .invalidState {
                        // Already shut down.
                    } catch {
                        return nil
                    }
                    return udid
                }
            }
            var down: Set<String> = []
            for await udid in group {
                if let udid { down.insert(udid) }
            }
            return down
        }
    }

    /// Ends every readiness wait for good (quit hygiene: their `bootstatus`,
    /// `launchctl` and screenshot children stop with them, and no listing
    /// that arrives during the quit starts another).
    func stop() {
        isStopped = true
        for wait in readinessWaits.values {
            wait.cancel()
        }
        readinessWaits = [:]
    }

    // MARK: - Internals

    /// Claims `udid` for `operation`. Nil, with nothing changed, while
    /// another operation runs — unless `interruptsBoot` and that operation
    /// is only waiting for a boot to be ready, which it then cancels.
    private func claim(_ udid: String, _ operation: Operation, interruptsBoot: Bool = false) -> Int? {
        guard UUID(uuidString: udid) != nil else { return nil }
        if operations[udid] != nil {
            guard interruptsBoot, readinessWaits[udid] != nil else { return nil }
            cancelReadinessWait(udid)
        }
        nextClaim += 1
        claims[udid] = nextClaim
        operations[udid] = operation
        return nextClaim
    }

    private func release(_ udid: String, _ claim: Int) {
        guard claims[udid] == claim else { return }
        claims[udid] = nil
        operations[udid] = nil
        transitions[udid] = nil
        // A listing that arrived while the operation ran was not applied to
        // this simulator: apply the latest one now.
        if skippedWhileBusy.remove(udid) != nil {
            noteSnapshot(snapshotSource())
        }
    }

    private func holds(_ udid: String, _ claim: Int) -> Bool {
        claims[udid] == claim
    }

    /// Whether the simulator runs as far as the app knows: the listing, or
    /// a readiness it is following.
    private func isRunning(_ udid: String) -> Bool {
        if readiness[udid] != nil || readinessWaits[udid] != nil { return true }
        switch entrySource(udid)?.state {
        case .booted?, .booting?, .shuttingDown?: return true
        default: return false
        }
    }

    /// `simctl shutdown`, holding the simulator at "shutting down" and then
    /// "stopped"; one that is already shut down counts as done.
    private func shutDownNow(_ udid: String, simctl: SimctlClient, failure: String) async -> Bool {
        cancelReadinessWait(udid)
        readiness[udid] = nil
        transitions[udid] = .shuttingDown
        do {
            try await simctl.shutdown(udid: udid)
        } catch let refusal as SimctlFailure where refusal.kind == .invalidState {
            // Already shut down.
        } catch {
            transitions[udid] = nil
            fail(failure, udid, error)
            return false
        }
        transitions[udid] = .stopped
        return true
    }

    /// `simctl boot`, then the wait for ready. A simulator that is already
    /// booted is followed without becoming Device Hub Pro's.
    private func bootAndWait(_ udid: String, simctl: SimctlClient, claim: Int, becomesOurs: Bool) async -> Bool {
        transitions[udid] = .booting(.launching)
        if entrySource(udid)?.lastUsedAt == nil { firstBoots.insert(udid) } else { firstBoots.remove(udid) }
        // Whether this call's `simctl boot` started the boot (not one that
        // was running already).
        var startedHere = false
        do {
            try await simctl.boot(udid: udid, timeZone: timeZoneSource(udid))
            startedHere = true
            if becomesOurs {
                bootedByDeviceHubPro.insert(udid)
            }
        } catch let refusal as SimctlFailure
            where refusal.kind == .invalidState && refusal.message.hasSuffix("current state: Booted") {
            // Booted meanwhile, by someone else: follow it all the same.
        } catch {
            transitions[udid] = nil
            fail("Could not start", udid, error)
            return false
        }
        guard holds(udid, claim) else { return false }
        transitions[udid] = nil
        let outcome = await followBoot(udid, simctl: simctl, startedHere: startedHere)
        guard holds(udid, claim) else { return false }
        await reloadList()
        return outcome == .ready
    }

    /// Follows a boot to ready in a wait that a Shut Down, a Restart, an
    /// Erase, a Delete or a listing that shows the simulator off can cancel.
    /// Nil when it was cancelled or the simulator went away meanwhile.
    private func followBoot(_ udid: String, simctl: SimctlClient, startedHere: Bool) async -> Readiness? {
        await startReadinessWait(udid, simctl: simctl, startedHere: startedHere).value
    }

    /// A simulator booted elsewhere: followed to ready in the background.
    private func followExternalBoot(_ udid: String, startedHere: Bool = false) {
        guard let simctl = simctlSource() else { return }
        startReadinessWait(udid, simctl: simctl, startedHere: startedHere)
    }

    /// Registers the wait at once, so a listing that arrives before it runs
    /// does not start a second one, and drops it when it ends.
    @discardableResult
    private func startReadinessWait(_ udid: String, simctl: SimctlClient, startedHere: Bool) -> Task<Readiness?, Never> {
        guard !isStopped else { return Task { nil } }
        cancelReadinessWait(udid)
        readiness[udid] = .waiting(.launching)
        let wait = Task { [weak self] () -> Readiness? in
            await self?.awaitReady(udid, simctl: simctl, startedHere: startedHere)
        }
        readinessWaits[udid] = wait
        Task { [weak self] in
            _ = await wait.value
            if self?.readinessWaits[udid] == wait {
                self?.readinessWaits[udid] = nil
            }
        }
        return wait
    }

    /// The three conditions, in order: `bootstatus` to Finished (its phases
    /// shown as they come), then the home screen process's pid, then the
    /// home screen on the screen — or a screen that stays dark, which is
    /// off. Runs inside a readiness wait.
    private func awaitReady(_ udid: String, simctl: SimctlClient, startedHere: Bool) async -> Readiness? {
        let (updates, continuation) = AsyncStream.makeStream(of: SimulatorBootStatus.self)
        let relay = Task { [weak self] in
            for await update in updates {
                if let phase = update.phase {
                    self?.advance(udid, to: DeviceBootPhase(phase))
                }
            }
        }
        let finished: Bool
        do {
            let last = try await simctl.bootStatus(udid: udid, timeout: bootStatusTimeout) { update in
                continuation.yield(update)
            }
            continuation.finish()
            await relay.value
            finished = SimulatorReadiness.bootFinished(lastUpdate: last)
        } catch {
            continuation.finish()
            relay.cancel()
            return concludeWithout(udid, error)
        }
        guard !Task.isCancelled else { return nil }
        guard finished else { return settle(udid, .unresponsive, startedHere: startedHere) }
        advance(udid, to: .waitingOnHomeScreen)

        let deadline = ContinuousClock.now + homeScreenTimeout
        // Without a known home screen process (watchOS, visionOS) the screen
        // alone decides.
        let label = SimulatorReadiness.homeScreenLabel(platform: entrySource(udid)?.platform)
        var homeScreenRuns = label == nil
        // Since when the screen has been dark (or given no picture).
        var darkSince: ContinuousClock.Instant?
        while !Task.isCancelled {
            do {
                if !homeScreenRuns, let label {
                    let jobs = try await simctl.launchdJobs(udid: udid)
                    homeScreenRuns = SimulatorReadiness.homeScreenPID(in: jobs, label: label) != nil
                }
                if homeScreenRuns {
                    let asked = ContinuousClock.now
                    let content = await screenContent(udid, simctl)
                    guard !Task.isCancelled else { return nil }
                    switch content {
                    case .homeScreen?:
                        return settle(udid, .ready, startedHere: startedHere)
                    case .bootScreen?:
                        darkSince = nil
                    case .dark?, nil:
                        // A screen that is off: black, or no picture at all
                        // (simctl waits 61 s on a powered-off screen, and
                        // the capture is bounded well below that).
                        let since = darkSince ?? asked
                        darkSince = since
                        if ContinuousClock.now - since >= screenOffGrace {
                            return settle(udid, .ready, startedHere: startedHere)
                        }
                    }
                }
            } catch let failure as SimctlFailure where failure.kind == .invalidState || failure.kind == .invalidDevice {
                // Shut down or deleted meanwhile: the listing takes it from here.
                return concludeWithout(udid, failure)
            } catch is CancellationError {
                return nil
            } catch {
                // Try again until the deadline: a spawn can fail while launchd settles.
            }
            guard ContinuousClock.now < deadline else {
                // A screen that is dark as the bound passes is off.
                return settle(udid, darkSince == nil ? .unresponsive : .ready, startedHere: startedHere)
            }
            // Best effort: the sleep fails only on cancellation, which the loop checks.
            try? await Task.sleep(for: homeScreenPollInterval)
        }
        return nil
    }

    /// Takes a screenshot into a temporary file and tells the home screen
    /// from the boot screen and a dark screen
    /// (`SimulatorReadiness.screenContent`); nil when simctl could not take
    /// one (a screen that is off makes simctl wait 61 s, hence the bound).
    /// Runs off the main actor: the PNG is 1206×2622 (3840×2160 on tvOS).
    nonisolated static func screenshotContent(
        _ udid: String,
        _ simctl: SimctlClient
    ) async -> SimulatorReadiness.ScreenContent? {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceHubPro-ready-\(UUID().uuidString).png")
        defer {
            // Best effort: a leftover temporary file is harmless.
            try? FileManager.default.removeItem(at: file)
        }
        do {
            try await simctl.screenshot(udid: udid, to: file, timeout: .seconds(20))
        } catch {
            return nil
        }
        return SimulatorReadiness.screenContent(imageAt: file)
    }

    /// A wait that ended on `error`: cancelled (nil, nothing recorded), the
    /// simulator gone or off (nil, readiness dropped), else not responding.
    private func concludeWithout(_ udid: String, _ error: Error) -> Readiness? {
        if error is CancellationError || Task.isCancelled { return nil }
        if let failure = error as? SimctlFailure, failure.kind == .invalidDevice || failure.kind == .invalidState {
            readiness[udid] = nil
            return nil
        }
        return settle(udid, .unresponsive, startedHere: false)
    }

    /// A phase from the wait, applied while the wait still runs.
    private func advance(_ udid: String, to phase: DeviceBootPhase) {
        guard case .waiting? = readiness[udid] else { return }
        readiness[udid] = .waiting(phase)
    }

    /// The wait's outcome, unless the wait was cancelled meanwhile (a Shut
    /// Down already dropped the readiness it would overwrite). `startedHere`:
    /// the wait follows a boot this controller's `simctl boot` started.
    private func settle(_ udid: String, _ outcome: Readiness, startedHere: Bool) -> Readiness? {
        guard !Task.isCancelled else { return nil }
        readiness[udid] = outcome
        firstBoots.remove(udid)
        if outcome == .ready {
            becameReady(udid, startedHere)
        }
        return outcome
    }

    private func cancelReadinessWait(_ udid: String) {
        readinessWaits.removeValue(forKey: udid)?.cancel()
    }

    /// Drops everything known about a simulator that is gone.
    private func forget(_ udid: String) {
        cancelReadinessWait(udid)
        readiness[udid] = nil
        transitions[udid] = nil
        firstBoots.remove(udid)
        bootedByDeviceHubPro.remove(udid)
    }

    /// Removes `<logs>/<UDID>`. The UDID was checked to be a UUID when the
    /// operation claimed it, so the path cannot leave the logs folder.
    /// CoreSimulatorService may still be writing right after a delete, so a
    /// failed removal is retried briefly.
    private func removeLogFolder(of udid: String) async {
        guard let logs = logsDirectorySource(), UUID(uuidString: udid) != nil else { return }
        let folder = logs.appendingPathComponent(udid, isDirectory: true)
        let fileManager = FileManager.default
        for _ in 0..<10 {
            guard fileManager.fileExists(atPath: folder.path) else { return }
            // Best effort: retried, then reported below.
            try? fileManager.removeItem(at: folder)
            guard fileManager.fileExists(atPath: folder.path) else { return }
            // Best effort: the sleep fails only on cancellation.
            try? await Task.sleep(for: .milliseconds(300))
        }
        status.flash("Could not remove \(folder.path)")
    }

    private func displayName(_ udid: String) -> String {
        entrySource(udid)?.name ?? udid
    }

    private func fail(_ what: String, _ udid: String, _ error: Error) {
        let reason = (error as? SimctlFailure)?.message ?? "\(error)"
        status.errorMessage = "\(what) \(displayName(udid)): \(reason)"
    }
}
