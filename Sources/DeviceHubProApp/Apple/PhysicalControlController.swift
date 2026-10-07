import Foundation
import AppKit
import Observation
import Synchronization
import DeviceHubProKit

/// Control of one workspace's physical view. There
/// is no switch: when the user has
/// selected an enabled, ready iPhone and its live view or preview shows,
/// fast input starts by itself (`autoStartIfWanted()`, no runner, no
/// signing team, no prompt on the phone) and stops with the view. If
/// it cannot start, `inputFailure` says why with a Retry in the status line.
/// The text below is the older opt-in design the runner-first flow
/// (`turnOn()`, still used by Siri and the App Switcher) keeps: the mode that lets the stage's clicks, drags, keys and the
/// Home and volume commands reach the dedicated test iPhone through
/// the public-XCTest runner (`PhysicalControlSession`).
///
/// - **Off by default.** It exists only while the workspace's physical view
///   (the live capture or the preview) shows a device the user enabled and
///   that is Ready. The runner's signing team is detected (or asked once)
///   when the runner is actually needed, never typed.
///   Turning it on builds and starts the runner (progress shows in the
///   banner) and, when it answers, routes the view session's input to it.
///   With fast input wanted, it starts fast input instead and the runner
///   stays off until an action needs it (Siri, typing that fast input
///   cannot type, a touch it cannot map, a fallback after a fast input
///   failure): `ensureRunner()`. A fast input that cannot start falls back to
///   the runner-first flow.
/// - **View only again, with a reason.** Any failure (the runner did not
///   start, died twice, refused an action, the connection dropped) turns
///   Control off, keeps the picture and says why in the banner. Soft
///   messages (busy, "Tap a text field first") leave Control on.
/// - **It stops with the view.** Deselect, a hidden window (unless
///   recording), window close, "Stop Using This Device", the preference off,
///   a replaced or ended session and quit all end it (`syncWithView()`,
///   `viewSessionEnded(quit:)`).
///
/// The controller holds no reference to the workspace: the inputs, the
/// factory, the pose and the capability updates come through hooks.
@MainActor
@Observable
final class PhysicalControlController {
    /// What the banner shows.
    enum Phase: Equatable {
        case off
        /// The signed runner is being built or found.
        case preparing(String)
        /// The runner is starting on the phone.
        case starting(String)
        /// The runner answers; the stage's input reaches the phone.
        case on
    }

    /// What the controller reads to decide.
    struct Inputs: Equatable {
        /// The selected physical device, when the selection is one.
        var entry: ApplePhysicalEntry?
        /// The signing team stored from an earlier run, else nil. Nothing is
        /// detected here: `resolveTeam` does that when the runner is needed.
        var team: String?
    }

    /// Controls the workspace's capabilities gain while Control is on.
    static let controlCapabilities: DeviceCapabilities = [.touch, .keyboard, .rotate, .hardwareButtons]

    private(set) var phase: Phase = .off
    /// An action is in flight or waiting.
    private(set) var isBusy = false
    /// The banner's line: why Control turned itself off, or a soft note.
    private(set) var message: String?
    /// Why fast input is not carrying the stage's input (it could not start or
    /// stopped, and no runner took over); the status line shows it with Retry.
    /// Nil while input works or nothing was tried.
    private(set) var inputFailure: String?
    /// The device whose automatic start failed: not tried again until Retry,
    /// a new selection or a new view session.
    @ObservationIgnored private var failedUDID: String?
    /// An automatic fast input start is in flight (chrome buttons wait).
    @ObservationIgnored private var autoStarting = false
    /// The phone's orientation as last read.
    private(set) var orientation: PhysicalControlOrientation? { didSet { poses.set(orientation) } }

    /// The stage's touch dots (local feedback, drawn without waiting for the
    /// runner).
    private(set) var touchFeedback = TouchFeedbackModel()
    @ObservationIgnored private var touchPruneTask: Task<Void, Never>?

    @ObservationIgnored var inputs: @MainActor () -> Inputs = { Inputs() }
    /// The running physical view session that shows `udid`.
    @ObservationIgnored var viewSession: @MainActor (_ udid: String) -> (any PhysicalViewSession)? = { _ in nil }
    /// Makes the control session for a device: built from the inventory's
    /// client and the toolchain (tests hand in a fake). `onChange` reports
    /// the session's state from any thread.
    @ObservationIgnored var makeControl: @MainActor (
        _ entry: ApplePhysicalEntry,
        _ team: String,
        _ onChange: @escaping @Sendable (PhysicalControlSnapshot) -> Void
    ) async throws -> any PhysicalControlling = { _, _, _ in throw PhysicalControlError.notReady }
    /// The signing team of the input runner, resolved at the moment the
    /// runner is needed (a stored team, else the login keychain's single
    /// Apple Development team, else the user's pick). Throws
    /// `PhysicalControlError.noTeam` when there is none.
    /// Nil (tests): the stored team only.
    @ObservationIgnored var teamResolver: (@MainActor () async throws -> String)?
    private func resolveTeam() async throws -> String {
        if let teamResolver { return try await teamResolver() }
        if let team = inputs().team { return team }
        throw PhysicalControlError.noTeam
    }
    /// Whether the runner may take over when fast input stops (it needs a
    /// team, which is resolved only then). The default asks the stored team.
    @ObservationIgnored var runnerMayTakeOver: (@MainActor () -> Bool)?
    /// Turns the Apple chrome with the phone.
    /// `devicectl device orientation get` / `set <pose>` for a device (rotation, no runner).
    @ObservationIgnored var deviceOrientation: @MainActor (_ udid: String) async throws -> PhysicalControlOrientation = { _ in .portrait }
    @ObservationIgnored var setDeviceOrientation: @MainActor (_ udid: String, _ pose: SimulatorDevicePose) async throws -> Void = { _, _ in }
    /// Whether fast input is wanted now (the preference, and not killed).
    @ObservationIgnored var fastInputEnabled: @MainActor () -> Bool = { false }
    /// Builds and starts a fast input session for a device (tests hand in a
    /// fake). Throws a `FastInputError` when it cannot.
    @ObservationIgnored var makeFastInput: @MainActor (
        _ entry: ApplePhysicalEntry
    ) async throws -> any FastInputControlling = { _ in throw FastInputError.disabled }
    /// Turns the Apple chrome with the phone.
    @ObservationIgnored var settlePose: @MainActor (_ turns: Int, _ animated: Bool) -> Void = { _, _ in }
    /// The workspace's capabilities: the base set, plus the control set
    /// while Control is on.
    @ObservationIgnored var setControlCapabilities: @MainActor (_ on: Bool) -> Void = { _ in }
    @ObservationIgnored var flash: @MainActor (_ message: String) -> Void = { _ in }
    /// How long a soft note stays in the banner.
    @ObservationIgnored var softMessageDuration: Duration = .seconds(4)

    @ObservationIgnored private var control: (any PhysicalControlling)?
    /// The running fast input session, while one is set on the router.
    @ObservationIgnored private(set) var fastInput: (any FastInputControlling)?
    @ObservationIgnored private var fastGeneration = 0
    /// Fast input carries Control and the runner starts on demand.
    @ObservationIgnored private var lazyRunner = false
    /// The runner answered (`control` may be set while it still starts).
    @ObservationIgnored private var runnerReady = false
    @ObservationIgnored private var runnerTask: Task<any PhysicalControlling, Error>?
    /// Fast input failed to start this run: it is not tried again.
    @ObservationIgnored private var fastTried = false
    /// What the router holds in lazy mode: it starts the runner when used.
    @ObservationIgnored private var lazyControl: LazyPhysicalControl?
    /// The runner's progress while it starts on demand.
    private(set) var runnerProgress: String?
    @ObservationIgnored private var controlledUDID: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastRevision: UInt64 = 0
    @ObservationIgnored private var attached: (session: any PhysicalViewSession, router: PhysicalControlInputRouter)?
    @ObservationIgnored private let frames = FrameBox()
    /// The orientation for the router's fast path (read off the main actor).
    @ObservationIgnored private let poses = OrientationBox()
    @ObservationIgnored private var softMessageTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    /// The chrome's buttons on their own fast session while Control carries none.
    @ObservationIgnored private var chromeButtons: (session: any PhysicalViewSession, buttons: PhysicalChromeButtons)?
    /// The Apple chrome's hardware buttons reach the phone without Control (fast input wanted,
    /// an enabled, ready iPhone showing): the stage offers them.
    private(set) var chromeButtonsAvailable = false

    // MARK: - Reading

    /// Control is on or starting.
    var isOn: Bool { phase != .off }
    /// The runner answers and the stage's input reaches the phone.
    var isReady: Bool { phase == .on }

    /// Why Control cannot be turned on now; nil when it can.
    var unavailableReason: String? {
        let inputs = inputs()
        guard let entry = inputs.entry, entry.isEnabled, entry.state == .ready else {
            return "Control needs an enabled iPhone that is ready."
        }
        guard viewSession(entry.udid) != nil else {
            return "Control needs the live view or the preview to be showing."
        }
        return nil
    }

    /// The Apple chrome's quarter turns the phone reported, while Control is
    /// on.
    var knownChromeTurns: Int? {
        if let turns = trackedInterface?.chromeTurns { return turns }
        return isReady ? orientation?.chromeTurns : nil
    }

    /// The stage pose (the device pose) the native view tracks itself (no runner
    /// needed); nil for a view that does not.
    private var trackedInterface: PhysicalControlOrientation? {
        guard let udid = inputs().entry?.udid else { return nil }
        return viewSession(udid)?.stagePose
    }

    /// The banner's status text while Control starts.
    var progressText: String? {
        switch phase {
        case .preparing(let text), .starting(let text): text
        case .on: runnerProgress
        case .off: nil
        }
    }

    // MARK: - Automatic start

    /// Whether the conditions for an automatic start hold: fast input wanted,
    /// the selected device enabled and ready, its view showing.
    private func autoStartCandidate() -> ApplePhysicalEntry? {
        guard fastInputEnabled(), let entry = inputs().entry, entry.isEnabled, entry.state == .ready,
              viewSession(entry.udid) != nil else { return nil }
        return entry
    }

    /// Starts fast input for the selected device without the runner (called
    /// on every view change, after the user selected the device: never on
    /// launch or appearance). No-op while Control is on or starting, and for a
    /// device whose automatic start already failed (until `retryInput()`).
    func autoStartIfWanted() {
        guard !isOn, let entry = autoStartCandidate(), failedUDID != entry.udid else { return }
        generation += 1
        let mine = generation
        lastRevision = 0
        message = nil
        inputFailure = nil
        controlledUDID = entry.udid
        fastTried = false
        autoStarting = true
        dropChromeButtons(quit: false)
        phase = .preparing("Starting fast input…")
        Task { [weak self] in
            await self?.startAuto(entry: entry, generation: mine)
        }
    }

    private func startAuto(entry: ApplePhysicalEntry, generation mine: Int) async {
        do {
            let started = try await makeFastInput(entry)
            guard mine == generation, isOn else {
                await started.stop()
                return
            }
            autoStarting = false
            fastInput = started
            lazyRunner = true
            lazyControl = LazyPhysicalControl { [weak self] in
                guard let self else { throw PhysicalControlError.stopped }
                return try await self.ensureRunner()
            }
            becameReady()
        } catch {
            guard mine == generation, isOn else { return }
            autoStarting = false
            failedUDID = entry.udid
            let text = (error as? FastInputError)?.description ?? "Fast input could not start."
            end(reason: nil)
            inputFailure = "The iPhone's screen is view only: \(text)"
            flash("iPhone input unavailable: view only")
        }
    }

    /// The status line's Retry: tries the automatic start again.
    func retryInput() {
        failedUDID = nil
        inputFailure = nil
        if isOn { end(reason: nil) }
        autoStartIfWanted()
    }

    /// Forgets a failure that belongs to a device no longer showing.
    private func forgetFailureIfStale() {
        let udid = inputs().entry?.udid
        if let failedUDID, failedUDID != udid { self.failedUDID = nil }
        if inputFailure != nil, failedUDID == nil || udid == nil || viewSession(udid ?? "") == nil {
            inputFailure = nil
            failedUDID = nil
        }
    }

    // MARK: - Turning it on and off

    /// The banner's Control switch.
    func setOn(_ on: Bool) {
        if on {
            turnOn()
        } else {
            end(reason: nil)
        }
    }

    private func turnOn() {
        guard !isOn else { return }
        if let reason = unavailableReason {
            note(reason, soft: false)
            return
        }
        let inputs = inputs()
        guard let entry = inputs.entry else { return }
        generation += 1
        let mine = generation
        lastRevision = 0
        message = nil
        controlledUDID = entry.udid
        fastTried = false
        if fastInputEnabled() {
            phase = .preparing("Starting fast input…")
            Task { [weak self] in
                await self?.startFastFirst(entry: entry, generation: mine)
            }
            return
        }
        phase = .preparing("Preparing the input runner…")
        Task { [weak self] in
            await self?.startControl(entry: entry, generation: mine)
        }
    }

    /// Fast input first, no runner: on success Control is on at once; else the
    /// runner-first flow runs as if fast input were off.
    private func startFastFirst(entry: ApplePhysicalEntry, generation mine: Int) async {
        do {
            let started = try await makeFastInput(entry)
            guard mine == generation, isOn else {
                await started.stop()
                return
            }
            fastInput = started
            dropChromeButtons(quit: false)
            lazyRunner = true
            lazyControl = LazyPhysicalControl { [weak self] in
                guard let self else { throw PhysicalControlError.stopped }
                return try await self.ensureRunner()
            }
            becameReady()
        } catch {
            guard mine == generation, isOn else { return }
            fastTried = true
            flash("Fast input unavailable, using the standard input")
            note((error as? FastInputError)?.description ?? "Fast input could not start.", soft: true)
            phase = .preparing("Preparing the input runner…")
            await startControl(entry: entry, generation: mine)
        }
    }

    /// The runner, started now if it is not running (fast input on: it starts
    /// only for an action that needs it). Throws what its start throws.
    private func ensureRunner() async throws -> any PhysicalControlling {
        if runnerReady, let control { return control }
        if let runnerTask { return try await runnerTask.value }
        guard isOn, let entry = inputs().entry, entry.udid == controlledUDID else {
            throw PhysicalControlError.notReady
        }
        let mine = generation
        lastRevision = 0
        runnerProgress = "Preparing the input runner…"
        let task = Task { @MainActor [weak self] () throws -> any PhysicalControlling in
            guard let self else { throw PhysicalControlError.stopped }
            let team = try await self.resolveTeam()
            let session = try await self.makeControl(entry, team) { snapshot in
                Task { @MainActor [weak self] in self?.apply(snapshot, generation: mine) }
            }
            guard mine == self.generation, self.isOn else {
                await session.stop()
                throw PhysicalControlError.stopped
            }
            self.control = session
            try await session.start()
            guard mine == self.generation, self.isOn else { throw PhysicalControlError.stopped }
            self.runnerReady = true
            self.runnerProgress = nil
            return session
        }
        runnerTask = task
        do {
            let session = try await task.value
            if mine == generation { runnerTask = nil }
            return session
        } catch {
            if mine == generation {
                runnerTask = nil
                runnerProgress = nil
                if !runnerReady, let failed = control {
                    control = nil
                    Task { await failed.stop() }
                }
            }
            throw error
        }
    }

    /// Runs `action` on the runner, starting it first when it is not running;
    /// a failure is handled like any action's.
    private func withRunner(_ action: @escaping @MainActor (any PhysicalControlling) async throws -> Void) {
        guard isReady else { return }
        Task { [weak self] in
            guard let self else { return }
            do { try await action(try await self.ensureRunner()) } catch { self.handle(error) }
        }
    }

    /// The runner ended on its own while fast input carries Control: the next
    /// action that needs it starts it again.
    private func runnerLost(_ text: String?) {
        guard runnerReady, let ending = control else { return }
        control = nil
        runnerReady = false
        runnerProgress = nil
        Task { await ending.stop() }
        if let text { note(text, soft: true) }
    }

    private func startControl(entry: ApplePhysicalEntry, generation mine: Int) async {
        let session: any PhysicalControlling
        do {
            let team = try await resolveTeam()
            session = try await makeControl(entry, team) { [weak self] snapshot in
                Task { @MainActor [weak self] in self?.apply(snapshot, generation: mine) }
            }
        } catch {
            fail(error, generation: mine)
            return
        }
        guard mine == generation, isOn else {
            await session.stop()
            return
        }
        control = session
        do {
            try await session.start()
        } catch {
            fail(error, generation: mine)
            return
        }
        // The snapshot may not have arrived yet.
        guard mine == generation, isOn else { return }
        runnerReady = true
        becameReady()
    }

    /// The session reported a change.
    private func apply(_ snapshot: PhysicalControlSnapshot, generation mine: Int) {
        guard mine == generation, isOn, snapshot.revision >= lastRevision else { return }
        lastRevision = snapshot.revision
        if snapshot.isBusy != isBusy { isBusy = snapshot.isBusy }
        if let value = snapshot.orientation, value != orientation {
            orientation = value
            applyPose(for: value, animated: true)
        }
        if lazyRunner {
            switch snapshot.state {
            case .preparing(let text), .starting(let text): runnerProgress = text
            case .ready: runnerProgress = nil
            case .failed(let error): runnerLost(error.description)
            case .stopped: runnerLost(nil)
            }
            return
        }
        switch snapshot.state {
        case .preparing(let text):
            if phase != .preparing(text) { phase = .preparing(text) }
        case .starting(let text):
            if phase != .starting(text) { phase = .starting(text) }
        case .ready:
            becameReady()
        case .failed(let error):
            fail(error, generation: mine)
        case .stopped:
            end(reason: nil)
        }
    }

    private func becameReady() {
        guard isOn else { return }
        let first = phase != .on
        if first {
            phase = .on
            setControlCapabilities(true)
        }
        attachToView()
        if first {
            refreshOrientation()
            startFastInput()
        }
    }

    /// Starts fast input beside the runner when it is wanted. The runner
    /// serves every input meanwhile (a first start builds the helper); a
    /// failure says so once and changes nothing else.
    private func startFastInput() {
        guard fastInputEnabled(), !fastTried, fastInput == nil, let udid = controlledUDID,
              let entry = inputs().entry, entry.udid == udid
        else { return }
        fastGeneration += 1
        let mine = fastGeneration
        let session = generation
        Task { [weak self] in
            guard let self else { return }
            do {
                let started = try await self.makeFastInput(entry)
                guard mine == self.fastGeneration, session == self.generation, self.isOn else {
                    await started.stop()
                    return
                }
                self.fastInput = started
                self.dropChromeButtons(quit: false)
                self.attached?.router.setFastInput(started)
            } catch {
                guard mine == self.fastGeneration, self.isOn else { return }
                self.flash("Fast input unavailable, using the standard input")
                self.note((error as? FastInputError)?.description ?? "Fast input could not start.", soft: true)
            }
        }
    }

    /// The router met a fast input error (it has already cleared its fast
    /// path): the session ends and the runner carries on.
    private func fastInputFailed(_ error: FastInputError) {
        guard let ending = fastInput else { return }
        fastInput = nil
        fastGeneration += 1
        Task { await ending.stop() }
        if lazyRunner, !(runnerMayTakeOver?() ?? (inputs().team != nil)), let udid = controlledUDID {
            // Fast input carried Control alone and no runner can take over:
            // say so, with Retry, rather than ignore clicks.
            failedUDID = udid
            end(reason: nil)
            inputFailure = "The iPhone's screen is view only: \(error.description)"
            flash("iPhone input stopped: view only")
            return
        }
        syncChromeButtons()
        note(error.description, soft: true)
        flash("Fast input stopped, using the standard input")
    }

    /// Turns Control off and, when `reason` is given, says why.
    ///
    /// - Returns: the task that ends the runner (quit waits for it).
    @discardableResult
    func end(reason: String?, quit: Bool = false) -> Task<Void, Never>? {
        guard isOn || control != nil else {
            if let reason { note(reason, soft: false) }
            return stopTask
        }
        generation += 1
        autoStarting = false
        let ending = control
        let endingFast = fastInput
        fastInput = nil
        fastGeneration += 1
        runnerTask?.cancel()
        runnerTask = nil
        lazyRunner = false
        lazyControl = nil
        runnerReady = false
        runnerProgress = nil
        control = nil
        controlledUDID = nil
        detachFromView()
        let wasOn = isOn
        phase = .off
        isBusy = false
        if wasOn { setControlCapabilities(false) }
        syncChromeButtons()
        if let reason { note(reason, soft: false) } else { message = nil }
        if quit {
            ending?.terminateNow()
            endingFast?.terminateNow()
        }
        guard ending != nil || endingFast != nil else { return stopTask }
        let previous = stopTask
        let task = Task {
            await previous?.value
            await endingFast?.stop()
            await ending?.stop()
        }
        stopTask = task
        return task
    }

    private func fail(_ error: Error, generation mine: Int) {
        guard mine == generation else { return }
        let text = (error as? PhysicalControlError)?.description ?? "The iPhone control failed."
        if let error = error as? PhysicalControlError, error == .stopped { end(reason: nil); return }
        end(reason: text)
        flash("iPhone control stopped: view only")
    }

    /// The stage's action ended with `error`: a soft one is a note, any
    /// other turns Control off.
    private func handle(_ error: Error) {
        if let error = error as? PhysicalControlError, error.isSoft {
            note(error.description, soft: true)
        } else if lazyRunner, fastInput != nil {
            // The runner is only a helper here: fast input keeps Control on.
            note((error as? PhysicalControlError)?.description ?? "The iPhone control failed.", soft: true)
        } else {
            fail(error, generation: generation)
        }
    }

    private func note(_ text: String, soft: Bool) {
        message = text
        softMessageTask?.cancel()
        guard soft else { return }
        let duration = softMessageDuration
        softMessageTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    // MARK: - The view

    /// The view changed (a reconcile, a session that ended or was
    /// replaced): Control follows it. It ends with the session it drives, and
    /// moves to a replacement.
    func syncWithView() {
        defer { syncChromeButtons() }
        forgetFailureIfStale()
        guard isOn else {
            autoStartIfWanted()
            return
        }
        let inputs = inputs()
        guard let entry = inputs.entry, entry.udid == controlledUDID, entry.isEnabled, entry.state == .ready,
              viewSession(entry.udid) != nil
        else {
            end(reason: nil)
            autoStartIfWanted()
            return
        }
        if phase == .on { attachToView() }
    }

    /// The workspace ended the view session (`quit` for the app's quit).
    @discardableResult
    func viewSessionEnded(quit: Bool) -> Task<Void, Never>? {
        dropChromeButtons(quit: quit)
        inputFailure = nil
        failedUDID = nil
        guard isOn || control != nil else { return stopTask }
        return end(reason: nil, quit: quit)
    }

    /// Takes the pending stop task once, so quit can wait for it.
    func takeStopTask() -> Task<Void, Never>? {
        defer { stopTask = nil }
        return stopTask
    }

    // MARK: - The chrome's buttons without Control

    /// Gives the view session its own on-demand button path (`PhysicalChromeButtons`) while
    /// Control is not carrying the buttons through fast input; takes it away otherwise.
    private func syncChromeButtons() {
        let entry = inputs().entry
        let session = entry.flatMap { entry -> (any PhysicalViewSession)? in
            guard fastInputEnabled(), entry.isEnabled, entry.state == .ready,
                  !autoStarting, !(isOn && fastInput != nil) else { return nil }
            return viewSession(entry.udid)
        }
        guard let entry, let session else {
            dropChromeButtons(quit: false)
            return
        }
        if let chromeButtons, chromeButtons.session === session { return }
        dropChromeButtons(quit: false)
        let buttons = PhysicalChromeButtons(
            start: { [weak self] in
                guard let self else { throw FastInputError.stopped }
                return try await self.makeFastInput(entry)
            },
            onFailure: { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.flash("Fast input stopped, the phone's buttons did not work")
                    self?.note(error.description, soft: true)
                }
            }
        )
        session.inputRoute.setChromeButtons(buttons)
        chromeButtons = (session, buttons)
        chromeButtonsAvailable = true
    }

    private func dropChromeButtons(quit: Bool) {
        guard let taken = chromeButtons else { return }
        chromeButtons = nil
        chromeButtonsAvailable = false
        if quit { taken.buttons.terminateNow() }
        taken.session.inputRoute.setChromeButtons(nil)
    }

    private func attachToView() {
        guard let routed = lazyControl ?? control, let udid = controlledUDID, let session = viewSession(udid) else { return }
        if let attached, attached.session === session { return }
        detachFromView()
        frames.set(session.frames)
        let box = frames
        let poses = self.poses
        let tracksInterface = session.viewKind == .nativeLive
        let router = PhysicalControlInputRouter(
            control: routed,
            frameSize: { box.size },
            onFailure: { [weak self] error in
                Task { @MainActor [weak self] in self?.handle(error) }
            },
            onSoftFailure: { [weak self] error in
                Task { @MainActor [weak self] in self?.handle(error) }
            },
            onActionEvent: { [weak self] event in
                // Mouse events arrive on the main thread: apply in the same
                // turn so the dot shows in the frame of the click.
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.touch(event) }
                } else {
                    Task { @MainActor [weak self] in self?.touch(event) }
                }
            },
            onFastInputFailure: { [weak self] error in
                Task { @MainActor [weak self] in self?.fastInputFailed(error) }
            },
            orientation: { session.stagePose ?? poses.value },
            // A view that does not track the interface has the stage's pose as its interface.
            interfaceLandscape: { tracksInterface ? session.interfaceIsLandscape : true }
        )
        if let fastInput { router.setFastInput(fastInput) }
        session.inputRoute.set(router)
        attached = (session, router)
    }

    func touch(_ event: PhysicalControlInputRouter.ActionEvent) {
        guard isOn else { return }
        let now = ProcessInfo.processInfo.systemUptime
        touchFeedback.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        touchFeedback.apply(event, now: now)
        touchPruneTask?.cancel()
        touchPruneTask = nil
        guard let delay = touchFeedback.settleDelay(now: now), !touchFeedback.isEmpty else { return }
        touchPruneTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay + 0.05))
            guard !Task.isCancelled else { return }
            self?.touchFeedback.prune(now: ProcessInfo.processInfo.systemUptime)
        }
    }

    private func detachFromView() {
        touchPruneTask?.cancel()
        touchFeedback = TouchFeedbackModel()
        guard let attached else { return }
        // Clears the route only if it still holds this router.
        attached.session.inputRoute.set(nil)
        attached.router.stop()
        self.attached = nil
        frames.set(nil)
    }

    // MARK: - Actions

    /// Home from a menu: while Control is off and the chrome's buttons are available, a click of
    /// the button through the on-demand fast input; else Control starts on demand.
    func pressFromMenu(_ button: PhysicalControlButton) {
        if !isReady, let buttons = chromeButtons?.buttons {
            let mapped: SimulatorHardwareButton
            switch button {
            case .home: mapped = .home
            case .volumeUp: mapped = .volumeUp
            case .volumeDown: mapped = .volumeDown
            }
            buttons.tap(button: mapped)
            return
        }
        whenReady { $0.press(button) }
    }

    /// Home and the volume buttons (the Controls menu, the Apple chrome).
    func press(_ button: PhysicalControlButton) {
        guard isReady else { return }
        if let router = attached?.router, router.isFastActive {
            router.press(button)
            return
        }
        withRunner { try await $0.press(button) }
    }

    /// Why Rotate cannot run now; nil when it can. Rotation needs no runner and no
    /// Control: `devicectl device orientation set` on an enabled, ready iPhone.
    var rotationUnavailableReason: String? {
        guard let entry = inputs().entry, entry.isEnabled, entry.state == .ready else {
            return "Rotate needs an enabled iPhone that is ready."
        }
        return nil
    }

    /// A quarter turn (the Device menu's Rotate items and the stage's button), without
    /// the runner: the next pose from the interface orientation (the native view's
    /// tracker, else `orientation get`) through `devicectl device orientation set`, which
    /// turns the interface of an app that supports the pose (measured 2026-09-30). The
    /// view's tracker is re-read at once so the stage and chrome follow; an app that
    /// keeps its side says so softly.
    @discardableResult
    func rotate(_ direction: RotationDirection) -> Task<Void, Never>? {
        guard rotationUnavailableReason == nil, let udid = inputs().entry?.udid else { return nil }
        let turn: PhysicalControlTurn = direction == .left ? .left : .right
        return Task { [weak self] in
            guard let self else { return }
            do { try await self.turnInterface(udid: udid, turn: turn) } catch {
                self.note((error as? PhysicalControlError)?.description ?? "Rotate failed: \(error.localizedDescription)", soft: true)
            }
        }
    }

    private func turnInterface(udid: String, turn: PhysicalControlTurn) async throws {
        let session = viewSession(udid)
        let current: PhysicalControlOrientation
        if let tracked = session?.stagePose {
            current = tracked
        } else if let turned = orientation {
            // `orientation get` does not follow `set` (measured), so the last pose asked for wins.
            current = turned
        } else {
            current = try await deviceOrientation(udid)
        }
        let next = current.turned(turn)
        guard let pose = SimulatorDevicePose(rawValue: next.rawValue) else { return }
        try await setDeviceOrientation(udid, pose)
        orientation = next
        guard let session, session.viewKind == .nativeLive else {
            // A view that does not track the pose: the chrome turns to the pose asked for.
            applyPose(for: next, animated: true)
            return
        }
        // The frame and the picture follow the device pose at once, whatever the interface does
        // (Device Hub 27.0): a home screen that stays portrait still turns with the frame.
        await session.noteTurn(to: next)
    }

    /// Presents Siri through the runner (`text`, when given, is processed as
    /// recognised speech). A phone without the route says so softly.
    func activateSiri(text: String? = nil) {
        withRunner { try await $0.activateSiri(text: text) }
    }

    /// The App Switcher: fast input's key, else the runner's held swipe up
    /// from the bottom edge.
    func showAppSwitcher() {
        guard isReady else { return }
        if let router = attached?.router, router.isFastActive {
            router.showAppSwitcher()
            return
        }
        withRunner { try await $0.showAppSwitcher() }
    }

    // MARK: - On demand (the pill and the menus)

    /// How often `ensureReady()` looks at the phase while Control starts.
    @ObservationIgnored var readyPollInterval: Duration = .milliseconds(100)
    /// How long `ensureReady()` waits for a start (a first run builds the
    /// runner, about a minute).
    @ObservationIgnored var readyTimeout: Duration = .seconds(240)

    /// Why an on-demand action cannot start Control now; nil when Control is
    /// on or can be turned on (the device is
    /// ready and its view shows). Nothing is sent when this is non-nil.
    var onDemandUnavailableReason: String? {
        isOn ? nil : unavailableReason
    }

    /// Turns Control on when it is off, then waits until the runner
    /// answers. False when it cannot start (the reason shows in the status
    /// line) or ended while starting.
    func ensureReady() async -> Bool {
        if isReady { return true }
        if !isOn {
            turnOn()
            guard isOn else { return false }
        }
        let deadline = ContinuousClock.now + readyTimeout
        while isOn, !isReady, ContinuousClock.now < deadline {
            do { try await Task.sleep(for: readyPollInterval) } catch { return false }
        }
        return isReady
    }

    /// Runs `action` once Control is ready, starting it first when needed
    /// (the pill's Home and Rotate: a click starts Control on demand).
    func whenReady(_ action: @escaping @MainActor (PhysicalControlController) -> Void) {
        if isReady {
            action(self)
            return
        }
        Task { [weak self] in
            guard let self, await self.ensureReady() else { return }
            action(self)
        }
    }

    /// The picture turned (the frame's shape changed): asks the phone which
    /// way, which the capture cannot say.
    func refreshOrientation() {
        guard isReady, runnerReady, let control else { return }
        Task { [weak self] in
            do {
                self?.noteOrientation(try await control.orientation())
            } catch {
                self?.handle(error)
            }
        }
    }

    private func noteOrientation(_ value: PhysicalControlOrientation) {
        guard isOn else { return }
        if value != orientation { orientation = value }
        applyPose(for: value, animated: true)
    }

    private func applyPose(for value: PhysicalControlOrientation, animated: Bool) {
        // A view that tracks its own interface orientation drives the pose (the device pose
        // includes upside down, which an iPhone with Face ID never shows).
        guard trackedInterface == nil, let turns = value.chromeTurns else { return }
        settlePose(turns, animated)
    }

    // MARK: - Ending

    /// The app quits or the window goes: everything stops at once.
    @discardableResult
    func stop(quit: Bool) -> Task<Void, Never>? {
        softMessageTask?.cancel()
        dropChromeButtons(quit: quit)
        inputFailure = nil
        failedUDID = nil
        return end(reason: nil, quit: quit)
    }
}

/// The current picture's size, readable from the router's threads: the
/// controller points it at the view session's frame store.
private final class OrientationBox: Sendable {
    private let lock = Mutex<PhysicalControlOrientation?>(nil)
    func set(_ value: PhysicalControlOrientation?) { lock.withLock { $0 = value } }
    var value: PhysicalControlOrientation? { lock.withLock { $0 } }
}

private final class FrameBox: Sendable {
    private let store = Mutex<FrameStore?>(nil)

    func set(_ frames: FrameStore?) {
        store.withLock { $0 = frames }
    }

    var size: CGSize? {
        guard let size = store.withLock({ $0 })?.currentSize else { return nil }
        return CGSize(width: size.width, height: size.height)
    }
}
