import Foundation

/// Why an active mirror session was torn down.
public enum TeardownReason: String, Sendable, Equatable {
    case disconnected
    case unauthorizedPrompt
    case transportFatal
}

public enum SessionLifecycleEvent: Sendable, Equatable {
    case devicesChanged([AndroidDevice])
    case transportFatal(serial: String)
    case resumeTimerFired(serial: String, attempt: Int)
    case resumeFailed(serial: String)
    case selectionChanged(selectedSerial: String?)
    case mirrorStarted(serial: String)
    /// A session proved the transport healthy — frame delivery, or the stats
    /// loop's clean-poll fallback for a transport that reports none: the
    /// reconnect episode (streak + alert suppression) ends here.
    case mirrorHealthy(serial: String)
    /// The waiting panel's Reconnect button: re-arm from either episode state.
    case reconnectRequested(serial: String)
    /// The user ended `serial`'s session (Stop Mirror, stopping the VM, …).
    /// Sent only for user-initiated stops, never from the lifecycle's own
    /// teardown hook: it ends any episode about the serial, so a later
    /// unplug/replug does not resurrect a mirror the user stopped.
    case mirrorStopped(serial: String)
    /// A session on a device adb does not list (an Apple device's) began.
    /// The lifecycle decides adb devices only, so the adb session it
    /// replaced and any episode end here, as another serial's
    /// `mirrorStarted` ends them, but into `.idle`: a later snapshot without
    /// the replaced device is then just a device going away, not a teardown
    /// of the new session, a ghost or an auto-resume over it.
    case nonAdbMirrorStarted
    /// The answer to `.checkEmulatorLiveness`: whether the emulator VM behind
    /// `serial` is still running (its process, not its adb transport).
    case emulatorLivenessChecked(serial: String, vmRunning: Bool)
    /// One physical phone's adb transports were folded into one row
    /// (`AndroidDeviceGrouping`): `aliases` maps each serial that is not its
    /// row's to the row's serial. An episode or session about an aliased
    /// serial follows the live transport instead of ghosting a duplicate.
    case transportsMoved(aliases: [String: String])
}

public enum SessionLifecycleState: Sendable, Equatable {
    case idle
    case mirroring(serial: String)
    /// Ghost shown, auto-resume armed. `nextAttempt` is the attempt a future
    /// schedule would use; `deviceBack` tracks whether the serial is online.
    case recovering(serial: String, nextAttempt: Int, deviceBack: Bool)
    /// Attempts exhausted; the Rescan affordance is the only way back.
    case ghostSelected(serial: String)
}

public enum SessionLifecycleAction: Sendable, Equatable {
    case teardown(TeardownReason)
    case scheduleResume(serial: String, after: Duration, attempt: Int)
    case resume(serial: String)
    case showStatus(CanvasStatusKind)
    case setGhost(String?)
    /// After `after`, check whether the emulator VM behind `serial` still
    /// runs and answer with `.emulatorLivenessChecked`. An emulator's mirror
    /// runs over gRPC, not adb, so adb losing sight of it (an adb server
    /// restart, `adb root`, a guest reboot) is not evidence the mirror died.
    case checkEmulatorLiveness(serial: String, after: Duration)
}

/// Backoff schedule for mirror auto-resume: `delays[attempt - 1]`, nil past
/// `maxAttempts` (the Rescan affordance takes over). `emulatorAbsenceGrace`
/// is how long an emulator may be missing or offline in adb before its VM is
/// checked (and re-checked while adb stays quiet).
public struct ReconnectPolicy: Sendable, Equatable {
    public var delays: [Duration]
    public var maxAttempts: Int
    public var emulatorAbsenceGrace: Duration

    public init(
        delays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(5), .seconds(10)],
        maxAttempts: Int = 5,
        emulatorAbsenceGrace: Duration = .seconds(5)
    ) {
        self.delays = delays
        self.maxAttempts = maxAttempts
        self.emulatorAbsenceGrace = emulatorAbsenceGrace
    }

    public func delay(attempt: Int) -> Duration? {
        guard attempt >= 1, attempt <= maxAttempts, !delays.isEmpty else { return nil }
        return delays[min(attempt - 1, delays.count - 1)]
    }
}

/// The pure disconnect/reconnect state machine behind
/// `DeviceLifecycleCoordinator`. Emulator serials never auto-resume (their
/// stopped-AVD hero owns the stage and starting the VM is the user's action);
/// physical devices do, with capped backoff from `ReconnectPolicy`.
///
/// An emulator mirror is torn down only once its VM is gone: adb losing the
/// emulator first arms a liveness check (`.checkEmulatorLiveness`), and the
/// teardown follows only if adb still does not list it online and the VM
/// process is not running.
public struct SessionLifecycle: Sendable, Equatable {
    public private(set) var state: SessionLifecycleState = .idle
    private let policy: ReconnectPolicy
    /// Highest resume attempt seen in the current reconnect episode. A
    /// transport-fatal stream that dies again right after every auto-resume
    /// carries this forward, so the backoff grows instead of looping at
    /// stream lifetime (S3).
    private var fatalStreak: Int = 0
    /// The machine's armed auto-reconnect attempt: the serial it belongs to
    /// and the attempt it is running (or next to run). Set when the resume
    /// timer fires, kept through the resulting `mirrorStarted`, and dropped
    /// by every hand-off that ends the machine's ownership below — a manual
    /// start, a healthy session, a vanished device, an exhausted schedule.
    /// While it names `serial`, that session's transport errors belong to a
    /// machine-driven cycle and stay out of the alert surface (S2), so it is
    /// false in every state where the machine is no longer driving.
    private var autoResume: AutoResume?
    /// The mirrored emulator adb has lost sight of (missing or not online)
    /// while its liveness check is pending; nil once adb lists it online
    /// again or the session ends.
    private var emulatorAway: String?
    /// Online serials in the last snapshot; nil before the first one. Lets
    /// Reconnect tell a device that is away from one that is present.
    private var onlineSerials: Set<String>?

    /// One armed attempt, so the serial and the attempt it runs cannot drift
    /// apart: the waiting panel narrates the attempt through the window that
    /// `autoResume` names.
    private struct AutoResume: Sendable, Equatable {
        let serial: String
        let attempt: Int
    }

    public init(policy: ReconnectPolicy = ReconnectPolicy()) {
        self.policy = policy
    }

    /// True while `serial`'s session belongs to an auto-reconnect cycle the
    /// machine is driving — used to silence per-cycle transport alerts while
    /// still recording them for the waiting panel's Details disclosure.
    public func isAutoReconnectArmed(serial: String) -> Bool {
        autoResume?.serial == serial
    }

    /// The attempt the armed cycle for `serial` is running (or next to run),
    /// nil when no cycle is armed. `.recovering` derives its attempt from the
    /// state itself; `.mirroring` carries none, which is exactly why the
    /// waiting panel needs this to stay up and honestly narrate the attempt
    /// window instead of vacating the stage (S4).
    public func autoReconnectAttempt(serial: String) -> Int? {
        guard autoResume?.serial == serial else { return nil }
        return autoResume?.attempt
    }

    @discardableResult
    public mutating func handle(_ event: SessionLifecycleEvent) -> [SessionLifecycleAction] {
        switch event {
        case .mirrorStarted(let serial):
            // Canonical streak rule: a session that starts OUTSIDE the
            // current auto episode — a manual start (the same serial
            // included) or another serial's start — begins a fresh episode,
            // so the streak and the armed marker reset. The episode's own
            // auto `mirrorStarted` (the marker still naming this serial) is
            // the machine starting its own attempt: it continues the
            // episode, keeping the streak and the marker so the attempt's
            // transport errors stay silenced.
            if autoResume?.serial != serial {
                fatalStreak = 0
                autoResume = nil
            }
            emulatorAway = nil
            state = .mirroring(serial: serial)
            return [.setGhost(nil)]

        case .mirrorStopped(let serial):
            // The user's stop ends every episode about the serial: no ghost,
            // no armed attempt, and — since the state leaves `.mirroring` — a
            // later unplug/replug is just a device coming and going.
            guard activeOrHeldSerial == serial else { return [] }
            state = .idle
            fatalStreak = 0
            autoResume = nil
            emulatorAway = nil
            return [.setGhost(nil)]

        case .nonAdbMirrorStarted:
            // Idle has no ghost, armed attempt or pending check to drop.
            guard state != .idle else { return [] }
            state = .idle
            fatalStreak = 0
            autoResume = nil
            emulatorAway = nil
            return [.setGhost(nil)]

        case .emulatorLivenessChecked(let serial, let vmRunning):
            guard case .mirroring(let active) = state, active == serial,
                  emulatorAway == serial else { return [] }
            if vmRunning {
                // The VM lives (a guest reboot, an adb restart still
                // settling), so the gRPC mirror stays. Look again later: if
                // the VM dies while adb stays quiet, no snapshot will say so.
                return [.checkEmulatorLiveness(serial: serial, after: policy.emulatorAbsenceGrace)]
            }
            emulatorAway = nil
            return enterDisconnected(serial: serial, reason: .disconnected)

        case .mirrorHealthy(let serial):
            guard case .mirroring(let active) = state, active == serial else { return [] }
            // The session proved healthy: the episode is over, so a much-later
            // death starts a fresh attempt 1 and stops silencing alerts.
            fatalStreak = 0
            autoResume = nil
            return []

        case .reconnectRequested(let serial):
            // The waiting panel holds the stage for an episode about
            // `serial` — the armed attempt window included — so a click
            // there takes the machine's cycle over manually: the marker
            // clears (its failures surface again), the streak resets and
            // the attempt restarts from 1.
            guard holdsEpisode(serial: serial) else { return [] }
            fatalStreak = 0
            autoResume = nil
            if isKnownAway(serial: serial) {
                // Nothing to connect to yet: resuming now would burn every
                // attempt against an absent device and end in `.ghostSelected`,
                // which ignores the device's return. Re-arm from attempt 1
                // and let the return edge schedule it instead.
                state = .recovering(serial: serial, nextAttempt: 1, deviceBack: false)
                return []
            }
            state = .recovering(serial: serial, nextAttempt: 1, deviceBack: true)
            return [.resume(serial: serial)]

        case .devicesChanged(let devices):
            return handleDevicesChanged(devices)

        case .transportsMoved(let aliases):
            return handleTransportsMoved(aliases)

        case .transportFatal(let serial):
            guard case .mirroring(let active) = state, active == serial else { return [] }
            return enterDisconnected(serial: serial, reason: .transportFatal)

        case .resumeTimerFired(let serial, let attempt):
            guard case .recovering(let held, _, let back) = state,
                  held == serial, back else { return [] }
            fatalStreak = max(fatalStreak, attempt)
            autoResume = AutoResume(serial: serial, attempt: attempt)
            return [.resume(serial: serial)]

        case .resumeFailed(let serial):
            guard case .recovering(let held, let nextAttempt, let back) = state,
                  held == serial, back else { return [] }
            guard let delay = policy.delay(attempt: nextAttempt) else {
                // Same exhaustion bookkeeping as `enterDisconnected`: the
                // machine gives up, so the marker clears — otherwise the
                // `.ghostSelected` state would still read as armed and a
                // session started later would be misclassified as
                // machine-driven — and the streak resets, so the next fatal
                // starts at attempt 1.
                exhaustEpisode()
                state = .ghostSelected(serial: serial)
                return []
            }
            state = .recovering(serial: serial, nextAttempt: nextAttempt + 1, deviceBack: true)
            return [.scheduleResume(serial: serial, after: delay, attempt: nextAttempt)]

        case .selectionChanged(let selectedSerial):
            guard let held = heldSerial, held != selectedSerial else { return [] }
            state = .idle
            fatalStreak = 0
            autoResume = nil
            return [.setGhost(nil)]
        }
    }

    /// The row of the phone this episode or session is about now lives on
    /// another adb transport. A mirror restarts on it at once, with no
    /// waiting panel; a ghost or a waiting episode is re-armed on it from
    /// attempt 1. Emulators never move.
    private mutating func handleTransportsMoved(_ aliases: [String: String]) -> [SessionLifecycleAction] {
        guard let serial = activeOrHeldSerial, !serial.hasPrefix("emulator-"),
              let target = aliases[serial], target != serial else { return [] }
        fatalStreak = 0
        autoResume = nil
        emulatorAway = nil
        switch state {
        case .mirroring:
            state = .mirroring(serial: target)
            return [.teardown(.disconnected), .setGhost(nil), .resume(serial: target)]
        case .recovering, .ghostSelected:
            guard let delay = policy.delay(attempt: 1) else { return [] }
            state = .recovering(serial: target, nextAttempt: 2, deviceBack: true)
            return [.setGhost(nil), .scheduleResume(serial: target, after: delay, attempt: 1)]
        case .idle:
            return []
        }
    }

    private var heldSerial: String? {
        switch state {
        case .idle, .mirroring:
            return nil
        case .recovering(let serial, _, _), .ghostSelected(let serial):
            return serial
        }
    }

    /// The serial any non-idle state is about.
    private var activeOrHeldSerial: String? {
        if case .mirroring(let serial) = state { return serial }
        return heldSerial
    }

    /// Whether `serial` is known to be away: the episode already says so
    /// (`deviceBack: false`), or the last snapshot does not list it online.
    /// Before any snapshot nothing is known, so nothing counts as away.
    private func isKnownAway(serial: String) -> Bool {
        if case .recovering(let held, _, let back) = state, held == serial, !back {
            return true
        }
        guard let onlineSerials else { return false }
        return !onlineSerials.contains(serial)
    }

    /// Whether an episode about `serial` is under way: `.recovering` and
    /// `.ghostSelected` always, `.mirroring` only while the machine's own
    /// attempt is armed — exactly the window where the waiting panel holds
    /// the stage, so its Reconnect button is live there too.
    private func holdsEpisode(serial: String) -> Bool {
        switch state {
        case .idle:
            return false
        case .recovering(let held, _, _), .ghostSelected(let held):
            return held == serial
        case .mirroring(let active):
            return active == serial && autoResume?.serial == active
        }
    }

    /// Attempts are exhausted: the machine hands over to the Rescan path, so
    /// the armed marker clears (`isAutoReconnectArmed` must be false in every
    /// non-armed state) and the next episode starts from attempt 1.
    private mutating func exhaustEpisode() {
        fatalStreak = 0
        autoResume = nil
    }

    private mutating func handleDevicesChanged(_ devices: [AndroidDevice]) -> [SessionLifecycleAction] {
        onlineSerials = Set(devices.filter(\.isOnline).map(\.serial))
        switch state {
        case .mirroring(let serial) where serial.hasPrefix("emulator-"):
            // The emulator mirror runs over gRPC; adb absence alone proves
            // nothing (spec §5.2 amendment, 2026-09-24). Arm one liveness
            // check per absence; adb listing it online again disarms it.
            if devices.contains(where: { $0.serial == serial && $0.isOnline }) {
                emulatorAway = nil
                return []
            }
            guard emulatorAway != serial else { return [] }
            emulatorAway = serial
            return [.checkEmulatorLiveness(serial: serial, after: policy.emulatorAbsenceGrace)]

        case .mirroring(let serial):
            guard let device = devices.first(where: { $0.serial == serial }) else {
                return enterDisconnected(serial: serial, reason: .disconnected)
            }
            guard !device.isOnline else { return [] }
            let reason: TeardownReason = device.state == "unauthorized"
                ? .unauthorizedPrompt
                : .disconnected
            return enterDisconnected(serial: serial, reason: reason)

        case .recovering(let serial, let nextAttempt, let back):
            let isBack = devices.contains { $0.serial == serial && $0.isOnline }
            if isBack, !back {
                guard let delay = policy.delay(attempt: nextAttempt) else {
                    exhaustEpisode()
                    state = .ghostSelected(serial: serial)
                    return []
                }
                state = .recovering(serial: serial, nextAttempt: nextAttempt + 1, deviceBack: true)
                return [.scheduleResume(serial: serial, after: delay, attempt: nextAttempt)]
            }
            if back, !isBack {
                // The device is away, so no attempt is running: the marker
                // clears (there is no armed window while the schedule waits)
                // and the state holds until the return edge.
                autoResume = nil
                state = .recovering(serial: serial, nextAttempt: nextAttempt, deviceBack: false)
            }
            return []

        case .ghostSelected, .idle:
            return []
        }
    }

    private mutating func enterDisconnected(
        serial: String,
        reason: TeardownReason
    ) -> [SessionLifecycleAction] {
        let status: CanvasStatusKind = reason == .unauthorizedPrompt ? .unauthorized : .unreachable
        emulatorAway = nil
        // Emulators have no auto-resume: the AVD row returns to its stopped
        // hero (Device Hub parity), so the ghost machinery is physical-only.
        if serial.hasPrefix("emulator-") {
            state = .idle
            fatalStreak = 0
            autoResume = nil
            return [.teardown(reason)]
        }
        var actions: [SessionLifecycleAction] = [.teardown(reason), .setGhost(serial), .showStatus(status)]
        // The armed marker only covers the attempt the machine itself started;
        // this teardown ends that attempt either way.
        autoResume = nil
        // Spec §5.2 amendment: a `transportFatal` teardown arms its attempt
        // immediately — adb still lists the device, so no watcher edge will
        // ever re-trigger the schedule — and the listed device counts as
        // back (if it truly vanished, the next snapshot disarms via the
        // flapping rules below). The attempt number carries the fatal streak
        // (S3): a stream that dies right after every start grows its backoff
        // instead of looping at stream lifetime; past the policy the machine
        // lands on the Rescan affordance instead.
        if reason == .transportFatal {
            let attempt = fatalStreak + 1
            guard let delay = policy.delay(attempt: attempt) else {
                exhaustEpisode()
                state = .ghostSelected(serial: serial)
                return actions
            }
            fatalStreak = attempt
            state = .recovering(serial: serial, nextAttempt: attempt + 1, deviceBack: true)
            actions.append(.scheduleResume(serial: serial, after: delay, attempt: attempt))
            return actions
        }
        state = .recovering(serial: serial, nextAttempt: 1, deviceBack: false)
        return actions
    }
}
