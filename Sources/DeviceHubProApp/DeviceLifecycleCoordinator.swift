import DeviceHubProKit
import Foundation

/// Ghost rows are synthetic devices merged into `devices` so the sidebar,
/// the selection and `CanvasStatus.resolve` need no special cases.
enum GhostEntry {
    /// The snapshot always wins: the ghost survives only while its serial is
    /// absent, so a returning device replaces — never duplicates — its ghost.
    static func merge(snapshot: [AndroidDevice], ghost: AndroidDevice?) -> [AndroidDevice] {
        guard let ghost, !snapshot.contains(where: { $0.serial == ghost.serial }) else {
            return snapshot
        }
        return snapshot + [ghost]
    }

    /// The multi-window variant: each workspace's own
    /// episode may ghost its own serial, so more than one synthetic row can
    /// be live at once (`DeviceInventory.ghosts`). Same rule per serial —
    /// the snapshot, then an earlier ghost, always wins — applied in a
    /// stable (serial-sorted) order so the merge is deterministic despite
    /// `Set`'s own order.
    static func merge(snapshot: [AndroidDevice], ghosts: Set<AndroidDevice>) -> [AndroidDevice] {
        var result = snapshot
        for ghost in ghosts.sorted(by: { $0.serial < $1.serial }) {
            result = merge(snapshot: result, ghost: ghost)
        }
        return result
    }
}

/// Bridges `DeviceWatcher` events into the pure `SessionLifecycle` decisions
/// and the app's existing teardown/mirror entry points. Owns only streams and
/// timers; every branch lives in `SessionLifecycle`. It reads the watcher's
/// event stream (`start(stream:)`) and never the watcher itself, which
/// belongs to `DeviceInventory`: that owner starts it, and stops it at quit.
@MainActor
final class DeviceLifecycleCoordinator {
    struct Hooks {
        var applySnapshot: ([AndroidDevice], Bool) -> Void
        var teardown: (TeardownReason) -> Void
        var resume: (String) async -> Void
        var showStatus: (CanvasStatusKind) -> Void
        var setGhost: (String?) -> Void
        var healthFlash: (String) -> Void
        var transportRestarted: () -> Void
        var selectedSerial: () -> String?
        /// The decider's current state, reported once per transition (the
        /// coordinator dedupes) so the stage can route on episode state
        /// instead of the device row's adb state (S4).
        var lifecycleState: (SessionLifecycleState) -> Void
        /// Whether the emulator VM behind a serial still runs (its process,
        /// not its adb transport). The default answers "no", so an emulator
        /// adb still misses after the grace period is torn down as before.
        var isEmulatorRunning: (String) async -> Bool = { _ in false }
    }

    private var hooks: Hooks
    /// Kept so `reset` can rebuild `lifecycle` fresh: a
    /// workspace's coordinator now survives `stop()`, where the old
    /// app-global one was simply discarded and rebuilt by the next
    /// `startDeviceLifecycle()` — `reset()` reproduces that "fresh
    /// `SessionLifecycle`" contract without discarding the coordinator
    /// itself (and the hooks bound to it).
    private let policy: ReconnectPolicy
    // The injected policy must drive the state machine's backoff, not the
    // `ReconnectPolicy` default the lifecycle would otherwise build with.
    private var lifecycle: SessionLifecycle
    private var streamTask: Task<Void, Never>?
    private var resumeTask: Task<Void, Never>?
    private var livenessTask: Task<Void, Never>?
    /// One `flashStatus` per health incident (spec §5.2): the first
    /// `.restarting` of an incident flashes, an incident ends on a snapshot.
    private var healthFlashShown = false
    /// Last handoff to `hooks.lifecycleState`: the decider's state *and* the
    /// panel status it produced. Both are compared because the armed attempt
    /// window changes the status without changing the state — a healthy
    /// session clears the marker while still `.mirroring`, and that is
    /// exactly when the panel must vacate (S4).
    private var lastReportedHandoff: Handoff?

    /// One episode handoff; `Equatable` so the dedupe sees a status-only
    /// change inside an unchanged state.
    private struct Handoff: Equatable {
        let state: SessionLifecycleState
        let status: ReconnectStatus?
    }

    init(hooks: Hooks, policy: ReconnectPolicy = ReconnectPolicy()) {
        self.hooks = hooks
        self.policy = policy
        self.lifecycle = SessionLifecycle(policy: policy)
    }

    /// Rebinds the hooks after construction: a
    /// `DeviceWorkspace` builds its coordinator as one of its own stored
    /// properties, so its real hooks — which close over `self` — can only be
    /// built once every other property is set (Swift's two-phase init). The
    /// workspace constructs the coordinator with an inert placeholder first,
    /// then calls this once, synchronously, before anything can observe the
    /// gap.
    func rebind(hooks: Hooks) {
        self.hooks = hooks
    }

    func start(stream: AsyncStream<DeviceWatcherEvent>) {
        // Belt and suspenders: a restarted stream inherits no pending resume
        // timer from the previous one.
        resumeTask?.cancel()
        resumeTask = nil
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        resumeTask?.cancel()
        resumeTask = nil
        livenessTask?.cancel()
        livenessTask = nil
    }

    /// Cancels whatever `stop()` cancels and rebuilds the decider from
    /// scratch, so a later `startDeviceLifecycle()` begins exactly the way
    /// the old app-global coordinator always did — freshly built, `.idle`,
    /// no health-flash or handoff memory — even though this coordinator, a
    /// workspace's own, was never discarded by the stop in between.
    func reset() {
        stop()
        lifecycle = SessionLifecycle(policy: policy)
        healthFlashShown = false
        lastReportedHandoff = nil
        // Notifies `hooks.lifecycleState` when there was an episode to clear
        // (the dedupe in `reportStateIfNeeded` skips it when already idle),
        // so a workspace's own waiting panel (`DeviceWorkspace.reconnect`)
        // never outlives this reset.
        reportStateIfNeeded()
    }

    func noteMirrorStarted(serial: String) {
        apply(lifecycle.handle(.mirrorStarted(serial: serial)))
    }

    /// The user ended `serial`'s mirror (Stop Mirror, stopping its VM, a
    /// power-on restart). Only user-initiated stops report here — never the
    /// `teardown` hook's own teardown — so a later unplug/replug of a device
    /// the user stopped neither shows a ghost nor resumes its mirror.
    func noteMirrorStopped(serial: String) {
        let actions = lifecycle.handle(.mirrorStopped(serial: serial))
        if !actions.isEmpty {
            // The episode is over, so nothing is left to check: the decider
            // would ignore the answer, but the VM probe (a `ps` spawn) need
            // not run at all.
            livenessTask?.cancel()
            livenessTask = nil
        }
        apply(actions)
    }

    /// A session on a device adb does not list (an Apple device's) began:
    /// the adb session it replaced ends with any episode, so a later
    /// snapshot without that device neither tears the new session down nor
    /// ghosts the row, and nothing auto-resumes over it.
    func noteNonAdbMirrorStarted() {
        let actions = lifecycle.handle(.nonAdbMirrorStarted)
        if !actions.isEmpty {
            // As for a user stop: the replaced emulator's VM check has no
            // episode left to answer.
            livenessTask?.cancel()
            livenessTask = nil
        }
        apply(actions)
    }

    func noteTransportFatal(serial: String) {
        apply(lifecycle.handle(.transportFatal(serial: serial)))
    }

    func noteResumeFailed(serial: String) {
        apply(lifecycle.handle(.resumeFailed(serial: serial)))
    }

    func noteSelectionChanged() {
        apply(lifecycle.handle(.selectionChanged(selectedSerial: hooks.selectedSerial())))
    }

    /// The waiting panel's Reconnect button: re-arms the episode from either
    /// state (recovering or exhausted) and resumes immediately. Being user
    /// initiated it never marks the attempt as auto, so its failures surface.
    func noteReconnectRequested(serial: String) {
        apply(lifecycle.handle(.reconnectRequested(serial: serial)))
    }

    /// The stats loop's grace gate fired — frame evidence, or the two-clean-
    /// poll fallback for a transport reporting none: the episode proved
    /// itself, so the streak resets and the alert surface reopens.
    func noteMirrorHealthy(serial: String) {
        apply(lifecycle.handle(.mirrorHealthy(serial: serial)))
    }

    /// Whether `serial`'s current session belongs to a machine-driven
    /// reconnect cycle — the single input to `TransportErrorPolicy`.
    func isAutoReconnectArmed(serial: String) -> Bool {
        lifecycle.isAutoReconnectArmed(serial: serial)
    }

    /// The waiting panel's view model for the episode under way, nil when
    /// there is none. Derived from the decider's state *and* the armed
    /// marker: `.mirroring` shows the panel only while the machine's own
    /// attempt is armed, so the panel spans the whole episode — every
    /// attempt window included — and vacates only when the episode ends
    /// (`.mirroring` with no armed cycle = a healthy or manual session) or
    /// the selection changes (S4).
    func reconnectStatus() -> ReconnectStatus? {
        ReconnectStatus(state: lifecycle.state, armedAttempt: armedAttempt)
    }

    /// The attempt the armed cycle is running, for the only state that needs
    /// it: `.recovering` derives its own from the state, `.ghostSelected`
    /// has none.
    private var armedAttempt: Int? {
        guard case .mirroring(let serial) = lifecycle.state else { return nil }
        return lifecycle.autoReconnectAttempt(serial: serial)
    }

    /// The decider's own half of `handle(_:)`, without applying a snapshot —
    /// the pump's entry point (`DeviceInventory.pump`): every registered
    /// coordinator decides in turn (so every workspace's own `setGhost`/
    /// `teardown` lands), and only once every one of them has, the pump
    /// applies the snapshot itself, exactly once, over every workspace's
    /// settled ghost state. A direct caller (a test driving one coordinator
    /// on its own) uses `handle(_:)` instead, which still does both in the
    /// original order.
    func decide(_ event: DeviceWatcherEvent, aliases: [String: String] = [:]) {
        switch event {
        case .snapshot(let devices, _):
            // A snapshot ends the health incident.
            healthFlashShown = false
            // A phone whose transports were folded into one row: an episode
            // about a serial that is now an alias follows the row first, so
            // the snapshot below never ghosts a device that is online
            // elsewhere.
            if !aliases.isEmpty {
                apply(lifecycle.handle(.transportsMoved(aliases: aliases)))
            }
            apply(lifecycle.handle(.devicesChanged(devices)))
        case .health(.restarting(let attempt)):
            hooks.transportRestarted()
            // One flash per incident: later restart signals stay silent.
            if !healthFlashShown {
                healthFlashShown = true
                hooks.healthFlash("Reconnecting to devices (attempt \(attempt))…")
            }
        case .health(.degraded):
            if !healthFlashShown {
                healthFlashShown = true
                hooks.healthFlash("Live device updates unavailable — checking periodically")
            }
        }
    }

    /// Decides `event`, then — for a snapshot — applies it through the
    /// `applySnapshot` hook: decider first, so a teardown's `setGhost`/
    /// `showStatus` actions land before the snapshot hook, whose merge then
    /// carries the ghost, so `ensureDeviceSelection()` keeps a selection
    /// whose serial just vanished from the snapshot. For a coordinator
    /// registered with `DeviceInventory`'s pump, the pump calls `decide(_:)`
    /// directly and applies the snapshot itself instead — see `decide(_:)`.
    func handle(_ event: DeviceWatcherEvent) {
        decide(event)
        if case .snapshot(let devices, let degraded) = event {
            hooks.applySnapshot(devices, degraded)
        }
    }

    private func apply(_ actions: [SessionLifecycleAction]) {
        for action in actions {
            switch action {
            case .teardown(let reason):
                hooks.teardown(reason)
            case .showStatus(let status):
                hooks.showStatus(status)
            case .setGhost(let serial):
                // `.setGhost(nil)` is the decider's auto-resume intent drop
                // (mirror start or selection change-away): the pending
                // resume timer dies with it. A same-serial no-op selection
                // emits nothing, so a legitimately armed timer survives.
                if serial == nil {
                    resumeTask?.cancel()
                    resumeTask = nil
                }
                hooks.setGhost(serial)
            case .resume(let serial):
                // Tracked like the schedule timer: `.setGhost(nil)` (the
                // intent drop — mirror start or selection change-away) and
                // `stop()` cancel a stale auto-resume before it steals the
                // stage, and the hook's guard sees a real `Task.isCancelled`
                // instead of a hardcode.
                resumeTask?.cancel()
                resumeTask = Task { [weak self] in
                    await self?.hooks.resume(serial)
                }
            case .scheduleResume(let serial, let after, let attempt):
                resumeTask?.cancel()
                resumeTask = Task { [weak self] in
                    // Best effort: sleep only fails on cancellation; the guard re-checks Task.isCancelled.
                    try? await Task.sleep(for: after)
                    guard let self, !Task.isCancelled else { return }
                    self.apply(self.lifecycle.handle(.resumeTimerFired(serial: serial, attempt: attempt)))
                }
            case .checkEmulatorLiveness(let serial, let after):
                // The decider ignores a stale answer (the emulator came back
                // online, or the session ended), so the check needs no
                // cancellation beyond `stop()`.
                livenessTask?.cancel()
                livenessTask = Task { [weak self] in
                    // Best effort: sleep only fails on cancellation; the guard re-checks Task.isCancelled.
                    try? await Task.sleep(for: after)
                    guard let self, !Task.isCancelled else { return }
                    let running = await self.hooks.isEmulatorRunning(serial)
                    guard !Task.isCancelled else { return }
                    self.apply(self.lifecycle.handle(
                        .emulatorLivenessChecked(serial: serial, vmRunning: running)
                    ))
                }
            }
        }
        reportStateIfNeeded()
    }

    /// One `hooks.lifecycleState` call per episode handoff (S4): the stage
    /// routes on this, so a re-entrant no-op must not spam it — but every
    /// real transition *and* every panel-status change must land, even when
    /// it produced no actions (a healthy session only flips the marker).
    private func reportStateIfNeeded() {
        let handoff = Handoff(state: lifecycle.state, status: reconnectStatus())
        guard handoff != lastReportedHandoff else { return }
        lastReportedHandoff = handoff
        hooks.lifecycleState(handoff.state)
    }

    /// Same stale-result guard pattern as `shouldApplyStatsResult`: a result
    /// captured before a teardown must never touch the fresh model.
    static func shouldApplyLifecycleEffect(isCancelled: Bool, isCurrentGeneration: Bool) -> Bool {
        !isCancelled && isCurrentGeneration
    }
}

/// Reconnect-cycle alert suppression (S2): a transport failure is worth an
/// alert only when it did not come from a cycle the machine is driving —
/// the waiting panel already narrates those. Manual Reconnect/Rescan
/// attempts pass `isAutoReconnectArmed: false` and keep surfacing.
enum TransportErrorPolicy {
    static func shouldSurface(isAutoReconnectArmed: Bool) -> Bool {
        !isAutoReconnectArmed
    }

    /// A device going away is not an error. DH shows
    /// its own "Currently Unavailable" panel for a lost physical transport
    /// and never raises an alert over it —
    /// the detail already reaches the waiting panel through
    /// `lastTransportError`, so alerting on top of it only dims the window
    /// for no reason. `PhysicalMirrorSession` marks exactly this case with
    /// its EOF message ("The mirror stream ended unexpectedly…", the
    /// server socket closing under a live read); every other physical
    /// failure (a decode error, a corrupt protocol header, an unsupported
    /// codec, an input failure) is a real, actionable error and still
    /// alerts.
    static func isDisconnect(_ message: String) -> Bool {
        message.hasPrefix("The mirror stream ended unexpectedly")
    }
}

/// The waiting panel's view model: `recovering` is armed with the attempt the
/// schedule will run, `ghostSelected` is manual-only with no attempt line,
/// `.idle` hides, and `.mirroring` shows only while the machine's own attempt
/// is armed — that is the whole episode, attempt windows included, so the
/// panel holds the stage instead of alternating with a gray status view (S4).
struct ReconnectStatus: Equatable {
    let serial: String
    let isArmed: Bool
    let attempt: Int?

    init(serial: String, isArmed: Bool, attempt: Int?) {
        self.serial = serial
        self.isArmed = isArmed
        self.attempt = attempt
    }

    /// - Parameter armedAttempt: the attempt the machine's armed cycle for
    ///   this state's serial is running (or next to run), nil when no cycle
    ///   is armed. Only `.mirroring` consults it — every other state derives
    ///   everything from itself, and an unarmed `.mirroring` is a healthy or
    ///   manual session with no panel to show.
    init?(state: SessionLifecycleState, armedAttempt: Int?) {
        switch state {
        case .idle:
            return nil
        case .mirroring(let serial):
            guard let attempt = armedAttempt else { return nil }
            self.init(serial: serial, isArmed: true, attempt: attempt)
        case .recovering(let serial, let nextAttempt, let deviceBack):
            // `deviceBack` means the schedule is armed for `nextAttempt - 1`
            // (the running/next timer's attempt); a device still away reports
            // the attempt its return would run. Clamped: `.reconnectRequested`
            // re-arms at `nextAttempt: 1` and attempt 0 would read wrong.
            self.init(
                serial: serial,
                isArmed: true,
                attempt: deviceBack ? max(nextAttempt - 1, 1) : nextAttempt
            )
        case .ghostSelected(let serial):
            self.init(serial: serial, isArmed: false, attempt: nil)
        }
    }
}
