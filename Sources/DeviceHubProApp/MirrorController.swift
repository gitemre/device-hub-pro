import Foundation
import Observation
import DeviceHubProKit

/// The mirror: the running session and how its transport is built, the
/// stage's attach state, the stats poll with the stream's health, the state
/// the stage draws from (the device's display shapes included), and in-app
/// audio.
///
/// One long-lived instance per `DeviceWorkspace` (`mirror`), which the
/// views and menus read directly. It starts and
/// ends nothing on its own: `mirror(device:)` and the session hubs
/// (`beginMirrorSession`, `tearDownMirror`) stay in `AppModel` and call into
/// it in their fixed order. The lifecycle decider stays with the model too;
/// the stats poll reaches it, and hands a failed transport's teardown back,
/// through the closures below.
@MainActor
@Observable
final class MirrorController {
    private let adbClient: AdbClient?
    private let context: ActiveDeviceContext
    private let status: StatusCenter
    let audioPlayer = AudioPlayer()

    /// Whether the machine drives a reconnect cycle for `serial` (the
    /// lifecycle's armed marker), read before a failure is raised.
    @ObservationIgnored var isAutoReconnectArmed: @MainActor (_ serial: String) -> Bool = { _ in false }
    /// The stats poll found the physical transport dead: `AppModel` tears
    /// the mirror down and tells the lifecycle, for the serial the session
    /// showed (nil when none was active).
    @ObservationIgnored var onTransportFatal: @MainActor (_ serial: String?) -> Void = { _ in }
    /// The session's stream proved itself (see `noteCleanStatsPoll`):
    /// `AppModel` tells the lifecycle.
    @ObservationIgnored var noteMirrorHealthy: @MainActor (_ serial: String) -> Void = { _ in }
    /// A physical device pushed its clipboard; `AppModel` hands it to the
    /// clipboard sync.
    @ObservationIgnored var receiveDeviceClipboard: @MainActor (_ text: String, _ serial: String) -> Void = { _, _ in }
    /// The stats poll found a simulator's session stopped: `AppModel` hands
    /// it to the simulator canvas, which tears it down or falls back to the
    /// view-only canvas.
    @ObservationIgnored var onSimulatorSessionStopped: @MainActor (_ session: any SimulatorSessionControlling) -> Void = { _ in }
    /// The stats poll found a physical device's view session (the live
    /// capture or the screenshot preview) stopped (the phone was unplugged,
    /// the capture failed): the workspace's `PhysicalLiveViewController`
    /// tears it down and falls back.
    @ObservationIgnored var onPhysicalViewSessionStopped: @MainActor (_ session: any PhysicalViewSession) -> Void = { _ in }
    /// One healthy poll of a physical device's view session (its error and
    /// the preview's cadence).
    @ObservationIgnored var onPhysicalViewSessionPolled: @MainActor (_ session: any PhysicalViewSession) -> Void = { _ in }
    /// The displays of the mirrored Apple device: its device type's, which
    /// the stage draws the device around. `AppModel` wires it to the
    /// simulator inventory.
    @ObservationIgnored var appleDisplayShapes: @MainActor (_ device: DeviceRef) -> [DisplayShape] = { _ in [] }

    /// Each AVD's and each phone model's last reported display shapes:
    /// recorded from the live sessions, read by the live stage before its
    /// own read and by the stopped and booting heroes. App-global (the
    /// owner hands every window's mirror the same library).
    let displayShapes: DisplayShapeLibrary
    /// The model (`adb devices -l`'s `model:`) of the device with this adb
    /// serial, nil when unknown: a physical session's shapes are kept per
    /// model. `AppModel` wires it to its device list.
    @ObservationIgnored var physicalModel: @MainActor (_ serial: String) -> String? = { _ in nil }
    /// The device class `ro.build.characteristics` names for `serial` (nil
    /// until read: handheld is assumed). Only handhelds rotate.
    @ObservationIgnored var deviceFormFactor: @MainActor (_ serial: String) -> SystemImage.FormFactor? = { _ in nil }

    init(
        adbClient: AdbClient?,
        context: ActiveDeviceContext,
        status: StatusCenter,
        perfLog: PerfLogWriter?,
        displayShapes: DisplayShapeLibrary = DisplayShapeLibrary(store: nil)
    ) {
        self.adbClient = adbClient
        self.context = context
        self.status = status
        self.perfLog = perfLog
        self.displayShapes = displayShapes
        wireMirrorViewState()
        wireInputMonitor()
    }

    /// Whether a Xiaomi phone refuses the Mac's input (see
    /// `XiaomiInputMonitor`); drives the stage's banner.
    let inputMonitor = XiaomiInputMonitor()
    /// The physical session `inputMonitor` was begun for.
    @ObservationIgnored private weak var inputMonitorSession: AnyObject?

    private func wireInputMonitor() {
        let adb = adbClient
        inputMonitor.readProbe = { serial in
            guard let adb else { return nil }
            return try? await adb.shell(serial: serial, [XiaomiInputBlock.probeScript], timeout: .seconds(5))
        }
        inputMonitor.clearServerSignal = { [weak self] in
            (self?.inputMonitorSession as? any PhysicalSessionControlling)?.clearInputInjectionDenied()
        }
    }

    /// One stats poll of a physical session: starts the monitor for a new
    /// session and feeds it the server console's refusal signal.
    private func noteInputInjection(of physical: any PhysicalSessionControlling) {
        if inputMonitorSession !== (physical as AnyObject) {
            inputMonitorSession = physical as AnyObject
            inputMonitor.begin(serial: physical.serial)
        }
        inputMonitor.observe(injectionDenied: physical.inputInjectionDenied)
    }

    var session: (any MirrorSessionProtocol)? {
        didSet {
            // Keys held on the old session were released by its teardown
            // (`stopSession`) or by the session itself when its key queue
            // ended; none of them is down on the new one.
            if session !== oldValue {
                heldHardwareKeys = []
                heldChromeButtons = []
            }
        }
    }
    var mirrorViewState = MirrorViewState() {
        didSet { wireMirrorViewState() }
    }
    /// The stage's presentation pose (rotation wrapper + texture uprighting).
    let stagePose = StagePoseAnimator()

    /// The last picture each physical device showed, in memory only: a
    /// session that starts for the device draws it until its first frame
    /// (`beginSeedPicture`).
    @ObservationIgnored let lastPictures = LastPictureCache()
    /// The remembered picture the current session draws before its first
    /// frame; nil when none was remembered or it no longer fits the pose.
    private(set) var seedPicture: RememberedPicture?

    static func pictureKey(_ device: DeviceRef) -> String {
        "\(device.platform.rawValue):\(device.id)"
    }

    /// Keeps the last frame the running session showed for `device`, as
    /// the session ends.
    func rememberLastPicture(for device: DeviceRef) {
        guard let frame = session?.frames.current else { return }
        lastPictures.remember(frame, for: Self.pictureKey(device))
    }

    /// Seeds the session that starts for `device` from its remembered
    /// picture and sizes the stage from it at once, so the device's frame
    /// is laid out for the new device and not for the one before. A stage
    /// starts upright, so a picture taken at another pose is not used.
    func beginSeedPicture(for device: DeviceRef) {
        let picture = lastPictures.picture(for: Self.pictureKey(device), matching: .portrait)
        seedPicture = picture
        mirrorViewState.devicePixelSize = picture?.fullSize
    }

    func clearSeedPicture() {
        seedPicture = nil
    }
    var statsText = ""
    private var statsPollTask: Task<Void, Never>?
    /// Whether the stage shows (window visible, or its compact mirror):
    /// the polls that only feed what the stage draws slow down or pause
    /// while it does not. Wired by its owner.
    @ObservationIgnored var isStageVisible: @MainActor () -> Bool = { true }
    /// The emulator stream's last failure while it reconnects (see
    /// `noteEmulatorStream`); nil while frames flow. Shown over the mirror.
    private(set) var mirrorStreamWarning: String?
    /// Writes mirror stats for `Scripts/perf-check.sh` when the harness sets
    /// `DHP_PERF_LOG`; nil (and free) otherwise.
    private let perfLog: PerfLogWriter?

    /// How long an attach waits for the emulator's controls (port
    /// resolution and the reads around it) before it fails with a reason.
    /// Injectable so tests run fast.
    @ObservationIgnored var attachTimeout: Duration = .seconds(10)
    /// How long a started emulator mirror may go without a first frame before
    /// the stage says the emulator isn't sending its screen.
    @ObservationIgnored var firstFrameTimeout: Duration = .seconds(8)
    /// The beat of the stats poll (and so of the first-frame check).
    @ObservationIgnored var statsPollInterval: Duration = .milliseconds(500)
    /// Whether adb still lists `serial` online; the first-frame watchdog
    /// stays quiet for a device that is not. `DeviceWorkspace` wires it to
    /// the inventory.
    @ObservationIgnored var isDeviceOnline: @MainActor (_ serial: String) -> Bool = { _ in true }
    /// True while an emulator session has produced no frame for
    /// `firstFrameTimeout` with its device online: the stage shows the
    /// stuck-screen state. Clears with the first frame, and with the session.
    private(set) var emulatorScreenStalled = false
    @ObservationIgnored private var streamStartedAt: ContinuousClock.Instant?
    @ObservationIgnored private var sawFrame = false
    /// True while the Android device on the stage reports its screen off
    /// (`watchScreenPower`): the stage says so and offers to wake it, instead
    /// of a black screen nobody can explain.
    private(set) var screenIsOff = false
    /// How often `watchScreenPower` reads the screen's state. Settable for tests.
    @ObservationIgnored var screenPowerRefreshInterval: Duration = .seconds(2)
    /// Bumped by each `wakeScreen`: the framed stage presses its power
    /// button sprite (`HardwareButtonsState.pulse`) as the screen comes on.
    private(set) var wakePulse = 0

    static func attachTimedOutMessage(_ deviceName: String) -> String {
        "\(deviceName) didn't answer in time. Its controls may be stuck; restarting the emulator fixes that."
    }

    /// Bumped by every `mirror(device:)` call and every selection change: an
    /// attach that resolved its port after the user moved on (or after a
    /// newer attach started) applies nothing.
    private var mirrorRequestGeneration: UInt64 = 0
    /// The stage's attach state for one serial: in flight (`failure == nil`)
    /// or failed with the reason. Nil once the session runs or nothing is
    /// being attached; `ConnectingView` routes on it instead of inferring
    /// "attaching" from whatever session happens to be live.
    struct MirrorAttach: Equatable {
        let serial: String
        var failure: String?
    }
    private(set) var mirrorAttach: MirrorAttach?
    /// How one `mirror(device:)` call ended: its session started, it failed
    /// with the message it raised and parked on the stage, or it was
    /// cancelled or superseded and ended silently, applying nothing.
    enum AttachOutcome: Equatable {
        case started
        case failed(String)
        case cancelled
        /// Another workspace's session already owns this device:
        /// nothing here changed. The caller shows the "Shown in
        /// another window" placeholder with Show Window / Move Here rather
        /// than raising it as a failure.
        case ownedElsewhere(WorkspaceID)
    }
    /// The last session error already surfaced through `errorMessage`, so the
    /// 500 ms stats poll raises each failure once.
    private var reportedMirrorError: String?
    /// The last transport failure, recorded even when the alert is suppressed
    /// so the waiting panel's Details disclosure can still show it (S2).
    /// Written by the stats poll and, for a failed resume, through
    /// `recordTransportFailure`.
    private(set) var lastTransportError: String?
    /// The physical session's health episode: its clean polls and whether
    /// its health was reported to the decider, which happens once (see
    /// `MirrorHealthGate`). Reset by `resetMirrorHealth`.
    private(set) var healthGate = MirrorHealthGate()

    /// Test seam: builds the mirror session for a serial (`port` is the
    /// emulator's gRPC port, nil for the scrcpy transport). Nil in
    /// production, which builds the real transports.
    @ObservationIgnored var sessionFactoryOverride: ((_ serial: String, _ port: Int?) -> any MirrorSessionProtocol)?
    /// Test seam: builds a simulator's session (`live` is whether the bridge
    /// canvas was asked for). Nil in production.
    @ObservationIgnored var simulatorSessionFactoryOverride: ((_ udid: String, _ live: Bool) -> any MirrorSessionProtocol)?

    /// Routes settled stream geometry to the pose animator (the texture
    /// uprighting must flip in the same frame as the layout swap).
    private func wireMirrorViewState() {
        mirrorViewState.onSettledGeometry = { [weak self] rotation in
            guard let self else { return }
            if context.port == nil {
                if physicalPoseTurns != nil {
                    // Rotate pinned the phone's pose: the frame follows it. The
                    // stream's picture just turned, so the wrapper snaps in the
                    // same frame (it was already showing the turned frame).
                    Task { await self.followPhysicalPose(snapping: true) }
                } else {
                    // A scrcpy phone's frames carry no pose of their own: the
                    // stage follows the display rotation it reads.
                    stagePose.settle(rotation: rotation)
                }
            } else if !isRotating {
                // An emulator's frame follows the DEVICE pose (the physical
                // model), not the display rotation, which Android leaves
                // alone at upside down on a phone. The display turn only
                // changes the picture (the texture turn). A pose changed
                // from outside (extended controls, `adb emu rotate`) shows
                // up as a display turn, so the model is read again.
                Task { await self.followEmulatorDevicePose(snapping: false) }
            }
        }
    }

    // MARK: - Attach state

    /// Starts an attach request, superseding every earlier one; its
    /// generation tells `isCurrentAttachRequest` whether it still applies.
    func beginAttachRequest() -> UInt64 {
        mirrorRequestGeneration &+= 1
        return mirrorRequestGeneration
    }

    /// Whether no newer attach started and the selection has not changed
    /// since the request of `generation` began.
    func isCurrentAttachRequest(_ generation: UInt64) -> Bool {
        generation == mirrorRequestGeneration
    }

    /// The stage shows `serial` attaching.
    func showAttaching(serial: String) {
        mirrorAttach = MirrorAttach(serial: serial, failure: nil)
    }

    /// Nothing is being attached any more.
    func clearAttach() {
        mirrorAttach = nil
    }

    /// The user moved on: an attach still resolving for the old selection
    /// must not select it back or raise its errors.
    func cancelPendingAttach() {
        mirrorRequestGeneration &+= 1
        mirrorAttach = nil
    }

    /// Surfaces an attach failure and parks it on the stage, which offers a
    /// retry instead of an endless "Attaching…" spinner. Returns the
    /// attach's outcome, which carries the message.
    @discardableResult
    func failAttach(serial: String, _ message: String) -> AttachOutcome {
        status.errorMessage = message
        mirrorAttach = MirrorAttach(serial: serial, failure: message)
        return .failed(message)
    }

    // MARK: - Transport

    /// The emulator gRPC mirror for `serial` on `port`. With adb, its keys
    /// (the frame's side buttons, typing) fall back to `adb shell input` on
    /// an AVD without a hardware keyboard (`hw.keyboard=no`, what avdmanager
    /// writes), where the emulator's own key sends are dropped.
    func makeEmulatorSession(serial: String, port: Int) -> any MirrorSessionProtocol {
        if let sessionFactoryOverride {
            return sessionFactoryOverride(serial, port)
        }
        guard let adbClient else { return MirrorSession(port: port) }
        return MirrorSession(port: port, adbFallback: AdbInputFallback(serial: serial, adb: adbClient))
    }

    /// The scrcpy-backed mirror for a non-emulator adb device; nil, with the
    /// error raised, without adb.
    func makePhysicalSession(serial: String) -> (any MirrorSessionProtocol)? {
        guard let adbClient else {
            status.errorMessage = AdbError.adbNotFound.description
            return nil
        }
        if let sessionFactoryOverride {
            return sessionFactoryOverride(serial, nil)
        }
        // The tuned, shipped transport settings (native size, 60 fps,
        // 8 Mbps) live in `ScrcpyServer.Options.physicalMirror`.
        let physical = PhysicalMirrorSession(serial: serial, adb: adbClient, options: .physicalMirror)
        // Device → Mac clipboard. The hook runs on the control channel's
        // delivery queue and later device messages wait for it, so it only
        // hands the text to the main queue.
        physical.onDeviceClipboard = { [weak self] text in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.receiveDeviceClipboard(text, serial)
                }
            }
        }
        // A touch going down re-checks a blocked Xiaomi phone's input switch.
        physical.onInputAttempt = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.inputMonitor.noteClick()
                }
            }
        }
        return physical
    }

    /// A simulator's mirror for an Apple device: the live canvas on the
    /// private bridge when `bridge` is given (`SimulatorMirrorSession`), else
    /// the view-only canvas (`SimulatorScreenshotSession`). The simulator
    /// canvas (`SimulatorCanvasController`) decides which.
    func makeSimulatorSession(
        udid: String,
        deviceSet: URL?,
        simctl: SimctlClient,
        bridge: (any SimulatorBridging)?
    ) -> any MirrorSessionProtocol {
        if let simulatorSessionFactoryOverride {
            return simulatorSessionFactoryOverride(udid, bridge != nil)
        }
        if let bridge {
            return SimulatorMirrorSession(udid: udid, deviceSet: deviceSet, bridge: bridge, simctl: simctl)
        }
        return SimulatorScreenshotSession(udid: udid, simctl: simctl)
    }

    /// Stops the session's transport for `tearDownMirror`. Keys still held
    /// on the frame are released first, while the session still takes them.
    /// A live simulator session queues those ups and its stop clears the
    /// queue, so it sends them itself (`SimulatorMirrorSession.stop`); at
    /// quit it is waited for, so they leave before the process does.
    func stopSession(cause: MirrorTeardownCause) {
        restorePhysicalRotation()
        releaseAllHardwareKeys()
        releaseAllChromeButtons()
        if let physical = session as? any PhysicalSessionControlling {
            physical.onDeviceClipboard = nil
            if cause == .quit {
                // An asynchronous teardown would never run at quit: the
                // sockets close and the device server is killed before this
                // returns (or, at the app's quit, before its wait ends),
                // within the bound.
                quitStop { physical.stopAndWait(timeout: 2) }
            } else {
                physical.stop()
            }
        } else if cause == .quit, let simulator = session as? SimulatorMirrorSession {
            quitStop { simulator.stopAndWait(timeout: 2) }
        } else if cause == .quit, let capture = session as? PhysicalScreenCaptureSession {
            // The capture session stops before the process does.
            quitStop { capture.stopAndWait(timeout: 2) }
        } else {
            session?.stop()
        }
    }

    /// Set by `DeviceWorkspace.beginQuitTeardown` around its teardown: the
    /// quit's bounded blocking stop starts on a background thread at once
    /// instead of blocking the main actor, and `takeQuitStop()` hands it
    /// over to be awaited, so the app's quit stops every window's session
    /// side by side.
    @ObservationIgnored var defersQuitStop = false
    @ObservationIgnored private var deferredQuitStop: Task<Void, Never>?

    /// Runs `stop` now, or, while `defersQuitStop`, starts it on a
    /// background thread and keeps its completion for `takeQuitStop()`.
    private func quitStop(_ stop: @escaping @Sendable () -> Void) {
        guard defersQuitStop else {
            stop()
            return
        }
        deferredQuitStop = Self.startInBackground(stop)
    }

    /// Starts `stop` on a global queue now and returns its completion.
    /// Nonisolated, so neither closure is taken for a main-actor one (the
    /// runtime would trap when the queue runs it).
    private nonisolated static func startInBackground(_ stop: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        let done = DispatchGroup()
        done.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stop()
            done.leave()
        }
        return Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                done.notify(queue: .global(qos: .userInitiated)) { continuation.resume() }
            }
        }
    }

    /// The quit stop `defersQuitStop` started, once; nil when the session
    /// had none to wait for.
    func takeQuitStop() -> Task<Void, Never>? {
        defer { deferredQuitStop = nil }
        return deferredQuitStop
    }

    /// Why the mirror is torn down: decides where a running recording goes
    /// and how the session's transport is closed.
    enum MirrorTeardownCause: Equatable {
        /// The user stopped it (Stop Mirror, stopping its VM, Power On).
        case userStop
        /// Another session replaces it: the user picked another device, or a
        /// start they asked for finished.
        case replaced
        /// The lifecycle saw the device leave adb (or its VM exit).
        case disconnected
        /// The transport failed for good.
        case transportFatal
        /// The app quits.
        case quit
        /// The workspace's window closed: a running
        /// recording is finalized like `.userStop`/`.replaced` — the window
        /// close path already asked "Stop recording and save?" before this
        /// runs, so there is nothing left to interrupt.
        case windowClosed
    }

    // MARK: - Stats and stream health

    /// The first-frame watchdog, from one stats poll of an emulator session:
    /// no frame yet after `firstFrameTimeout`, on a device adb lists online,
    /// raises `emulatorScreenStalled`; any frame clears it for good.
    func noteEmulatorFrames(totalFrames: Int, serial: String?, now: ContinuousClock.Instant = .now) {
        if totalFrames > 0 {
            sawFrame = true
            emulatorScreenStalled = false
            return
        }
        guard !sawFrame, let started = streamStartedAt, let serial else { return }
        if now - started >= firstFrameTimeout, isDeviceOnline(serial) {
            emulatorScreenStalled = true
        }
    }

    func startStatsPolling() {
        streamStartedAt = .now
        sawFrame = false
        emulatorScreenStalled = false
        statsPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let session = self.session else { return }
                let stats = await session.stats()
                // The poll captured `session` before the await; a new
                // `beginMirrorSession` cancels this task and replaces
                // `self.session`, but the `stats()` continuation can already
                // be in flight. Re-check before the result touches the model,
                // so a stale session's leftover error cannot stop the fresh
                // mirror.
                guard shouldApplyStatsResult(
                    isCancelled: Task.isCancelled,
                    isCurrentSession: session === self.session
                ) else { return }
                self.statsText = stats.overlayText
                if self.context.port != nil, !self.context.isPhysicalView {
                    self.noteEmulatorFrames(totalFrames: stats.totalFrames, serial: self.context.serial)
                }
                if let perfLog = self.perfLog {
                    let device = self.context.device?.id ?? self.context.serial ?? "unknown"
                    await perfLog.append(stats, device: device)
                }
                // A fatal physical-transport error stops the session and
                // waits in `lastError`; surface it once through the app's
                // alert path, then tear the mirror down so the stage and the
                // compact window (via `context.device`) return to the
                // stopped state instead of holding a frozen frame. Input
                // errors leave the session running and must not stop it. An
                // emulator `MirrorSession` never stops itself: it reconnects
                // with backoff, keeping the failure in `lastError` while
                // `isStreaming` is false, which the stage shows as a
                // non-fatal warning.
                if let physical = session as? any PhysicalSessionControlling {
                    self.noteInputInjection(of: physical)
                    if let error = physical.lastError {
                        // Read the episode marker before the teardown below
                        // clears it: while the machine drives a reconnect
                        // cycle its failures are recorded for the waiting
                        // panel's Details instead of raising the alert (S2).
                        let armed = self.context.serial.map {
                            self.isAutoReconnectArmed($0)
                        } ?? false
                        let isNewFailure = error != self.reportedMirrorError
                        if shouldStopMirror(after: error, isRunning: physical.isRunning) {
                            let serial = self.context.serial
                            // Both this teardown and the lifecycle hook's own
                            // clear the stash, so the failure is recorded
                            // *after* them — otherwise the panel's Details
                            // would come up empty after every fatal. Not the
                            // user's stop: the episode goes on.
                            self.onTransportFatal(serial)
                            self.lastTransportError = error
                            if isNewFailure,
                               TransportErrorPolicy.shouldSurface(isAutoReconnectArmed: armed),
                               !TransportErrorPolicy.isDisconnect(error) {
                                self.status.errorMessage = error
                            }
                            return
                        }
                        if isNewFailure {
                            self.reportedMirrorError = error
                            self.lastTransportError = error
                            if TransportErrorPolicy.shouldSurface(isAutoReconnectArmed: armed),
                               !TransportErrorPolicy.isDisconnect(error) {
                                self.status.errorMessage = error
                            }
                        }
                    } else if let serial = self.context.serial {
                        // The grace gate: the episode ends on frame evidence,
                        // or on the two-clean-poll fallback — never by
                        // counting polls out over an already-live mirror.
                        self.noteCleanStatsPoll(serial: serial, stats: stats)
                    }
                } else if let emulator = session as? MirrorSession {
                    self.noteEmulatorStream(isStreaming: emulator.isStreaming, lastError: emulator.lastError)
                } else if let view = session as? any PhysicalViewSession {
                    // A physical device's view-only screen: it stops itself
                    // when the phone goes away or its capture fails.
                    guard view.isRunning else {
                        self.onPhysicalViewSessionStopped(view)
                        return
                    }
                    self.onPhysicalViewSessionPolled(view)
                } else if let simulator = session as? any SimulatorSessionControlling {
                    // A simulator's session stops itself when the simulator
                    // shuts down or its canvas fails; the simulator canvas
                    // decides what follows. A running one's error (an input
                    // the simulator did not take, a screenshot that failed)
                    // is raised once as a status line.
                    guard simulator.isRunning else {
                        self.onSimulatorSessionStopped(simulator)
                        return
                    }
                    self.noteSimulatorSessionError(simulator.lastError)
                }
                // Best effort: the sleep fails only on cancellation, checked by the loop.
                // The poll is also the health monitor (a stalled stream, a
                // stopped session), so a hidden stage slows it down rather
                // than stopping it: nothing reads the overlay text then.
                let hidden = !self.isStageVisible() && self.perfLog == nil
                try? await Task.sleep(for: hidden ? self.statsPollInterval * 5 : self.statsPollInterval)
            }
        }
    }

    /// Ends the stats poll for `tearDownMirror`.
    func stopStatsPolling() {
        statsPollTask?.cancel()
        statsPollTask = nil
        emulatorScreenStalled = false
        screenIsOff = false
        streamStartedAt = nil
    }

    /// The emulator stream's health, from one stats poll: a failed stream
    /// (not streaming, with an error) shows as a non-fatal warning over the
    /// mirror while the session reconnects, and the warning clears as soon
    /// as frames flow again. The mirror is never torn down for it.
    func noteEmulatorStream(isStreaming: Bool, lastError: String?) {
        if isStreaming {
            mirrorStreamWarning = nil
        } else if let lastError {
            mirrorStreamWarning = lastError
        }
    }

    /// A running simulator session's error, from one stats poll: flashed
    /// once per new error, and kept for the waiting panel's Details.
    func noteSimulatorSessionError(_ error: String?) {
        guard let error, error != reportedMirrorError else { return }
        reportedMirrorError = error
        lastTransportError = error
        status.flash(error)
    }

    /// One clean poll of the physical session, extracted from the stats loop
    /// so the grace gate is testable without a live transport. The episode
    /// ends on the first frame-bearing read — `totalFrames`/`fps` come from
    /// *this mirror session's* counter, so a previous episode's frames never count —
    /// or on the second consecutive clean poll when the transport shows no
    /// frame evidence at all, and only once per session.
    ///
    /// A dead stream reports `lastError` and never reaches this gate, so
    /// doomed attempts keep the panel up (round-1 flap protection); a stream
    /// that delivers a frame and then dies re-enters through the fatal streak
    /// — the accepted cost recorded in the round-2 ledger.
    func noteCleanStatsPoll(serial: String, stats: MirrorStats) {
        guard healthGate.noteCleanPoll(stats) else { return }
        noteMirrorHealthy(serial)
    }

    /// A lifecycle resume failed with `failure`: kept for the waiting
    /// panel's Details like the stats poll's own failures.
    func recordTransportFailure(_ failure: String) {
        lastTransportError = failure
    }

    /// Forgets the ended session's stream state: the error already raised,
    /// the transport failure, the health episode, the stream warning and
    /// the stats line.
    func resetMirrorHealth() {
        reportedMirrorError = nil
        // The Details disclosure must not carry a previous episode's failure
        // into the session that follows (S4 round 1); the stats poll
        // re-records the failure that tore this mirror session down afterwards.
        lastTransportError = nil
        healthGate.reset()
        mirrorStreamWarning = nil
        inputMonitor.reset()
        inputMonitorSession = nil
        statsText = ""
    }

    // MARK: - Keys and device actions

    func sendKeyEvent(_ keyCode: Int, longPress: Bool = false) async {
        guard let adbClient, let serial = context.serial else { return }
        do {
            try await adbClient.sendKey(serial: serial, keyCode: keyCode, longPress: longPress)
        } catch {
            status.flash("Key event failed")
        }
    }

    func power() async { await sendKeyEvent(26) }
    func showPowerMenu() async { await sendKeyEvent(26, longPress: true) }
    func volumeUp() async { await sendKeyEvent(24) }
    func volumeDown() async { await sendKeyEvent(25) }
    func muteAudio() async { await sendKeyEvent(164) }

    // MARK: - Hardware keys

    /// The frame's buttons held down: each got its key-down and still owes
    /// its key-up. Cleared when the session changes.
    @ObservationIgnored private var heldHardwareKeys: Set<HardwareKey> = []

    /// Whether the session presses power and volume as real key down and up
    /// (an emulator session); the frame offers its buttons only then. The
    /// Device and Controls menus keep their one-shot adb presses either way.
    var supportsHardwareKeys: Bool {
        session?.supportsHardwareKeys ?? false
    }

    /// A frame button went down: the key goes down on the device and stays
    /// down until `releaseHardwareKey`. A key already held, or a session
    /// without hardware keys, sends nothing.
    func pressHardwareKey(_ key: HardwareKey) {
        guard let session, session.supportsHardwareKeys, !heldHardwareKeys.contains(key) else { return }
        heldHardwareKeys.insert(key)
        session.send(HardwareKeyEvent(key: key, isDown: true))
    }

    /// A frame button came up: the key held by `pressHardwareKey` goes up.
    /// A key that is not held sends nothing.
    func releaseHardwareKey(_ key: HardwareKey) {
        guard heldHardwareKeys.remove(key) != nil else { return }
        session?.send(HardwareKeyEvent(key: key, isDown: false))
    }

    /// Releases every held key, in `HardwareKey.allCases` order: the stage
    /// calls it when the mouse-up can no longer arrive (the window resigns
    /// key, the buttons disappear), and `stopSession` before the session
    /// stops.
    func releaseAllHardwareKeys() {
        for key in HardwareKey.allCases where heldHardwareKeys.contains(key) {
            releaseHardwareKey(key)
        }
    }

    // MARK: - Apple chrome buttons

    /// The Apple chrome's buttons held down (`AppleChromeButtonsState`):
    /// each went down and still owes its up. Cleared when the session
    /// changes.
    @ObservationIgnored private var heldChromeButtons: [SimulatorHardwareButton] = []

    /// Whether the session presses an Apple chrome's buttons (the live
    /// simulator canvas); the view-only canvas takes no input, so its
    /// chrome's buttons are drawn but not offered.
    var supportsChromeButtons: Bool {
        (session as? any SimulatorButtonSending)?.acceptsButtons ?? false
    }

    /// An Apple chrome button went down: its HID usage goes down on the
    /// simulator and stays down until `releaseChromeButton`. A button held
    /// already, or a session that takes no buttons, sends nothing.
    func pressChromeButton(_ button: SimulatorHardwareButton) {
        guard let sender = session as? any SimulatorButtonSending, !heldChromeButtons.contains(button) else { return }
        heldChromeButtons.append(button)
        sender.send(button: button, isDown: true)
    }

    /// The button came up; one that is not held sends nothing.
    func releaseChromeButton(_ button: SimulatorHardwareButton) {
        guard let index = heldChromeButtons.firstIndex(of: button) else { return }
        heldChromeButtons.remove(at: index)
        (session as? any SimulatorButtonSending)?.send(button: button, isDown: false)
    }

    /// Releases every held chrome button, in the order they went down: when
    /// the mouse-up can no longer arrive, and before the session stops.
    func releaseAllChromeButtons() {
        for button in heldChromeButtons {
            releaseChromeButton(button)
        }
    }

    /// Back. A physical mirror sends it over scrcpy's control channel as
    /// scrcpy's own right-click does: BACK, or POWER while the screen is off
    /// (no adb process per press).
    func goBack() async {
        if let physical = activePhysicalSession {
            notePhysicalNavigationAttempt()
            physical.sendBackOrScreenOn()
            return
        }
        await pressNavigationKey(.back)
    }

    /// Back, Home or Recents by the fastest path the device has: a physical
    /// phone's scrcpy control channel, an emulator's gRPC `sendKey`, else
    /// `adb shell input keyevent` (also the answer when the gRPC call fails).
    func pressNavigationKey(_ key: NavigationKey) async {
        if let physical = activePhysicalSession {
            notePhysicalNavigationAttempt()
            if key == .back {
                physical.sendBackOrScreenOn()
            } else {
                physical.sendNavigationKey(key)
            }
            return
        }
        if let port = context.port, context.serial != nil {
            do {
                try await EmulatorNavigationKeys.press(key, port: port)
                return
            } catch {
                // Falls through to adb.
            }
        }
        await sendKeyEvent(key.androidKeyCode)
    }

    /// A navigation press on a physical phone: re-reads a blocked Xiaomi
    /// phone's input switch like a touch does, and says why nothing happens
    /// while it is blocked (the stage's banner shows too).
    private func notePhysicalNavigationAttempt() {
        inputMonitor.noteClick()
        if inputMonitor.isBlocked {
            status.flash("The phone refuses input: turn on USB debugging (Security settings)")
        }
    }

    /// The active mirror's scrcpy session, when the active device is physical.
    var activePhysicalSession: (any PhysicalSessionControlling)? {
        guard let physical = session as? any PhysicalSessionControlling,
              physical.serial == context.serial
        else { return nil }
        return physical
    }

    func goHome() async { await pressNavigationKey(.home) }
    func openRecents() async { await pressNavigationKey(.recents) }
    func splitScreen() async { await sendKeyEvent(187, longPress: true) }
    func openAssistant() async { await sendKeyEvent(219) }

    /// Double-pressing Recents switches back to the previous app.
    func switchToPreviousApp() async {
        await sendKeyEvent(187)
        try? await Task.sleep(for: .milliseconds(150))
        await sendKeyEvent(187)
    }

    func restartAndroid() async {
        guard let adbClient, let serial = context.serial else { return }
        do {
            _ = try await adbClient.shell(serial: serial, ["reboot"])
        } catch {
            status.errorMessage = "Could not restart the device: \(error)"
        }
    }

    func shutdownAndroid() async {
        guard let adbClient, let serial = context.serial else { return }
        do {
            _ = try await adbClient.shell(serial: serial, ["reboot", "-p"])
        } catch {
            status.errorMessage = "Could not shut down the device: \(error)"
        }
    }

    // MARK: - Rotation

    /// Releases the guest's rotation lock, so the display can follow the
    /// device pose instead of staying sideways. Called only before an
    /// explicit rotate — attaching a mirror leaves the device's rotation
    /// settings alone; the app keeps no "follow rotation" preference.
    func releaseRotationLock() async {
        guard let adbClient, let serial = context.serial else { return }
        let setting = (try? await adbClient.shell(
            serial: serial,
            ["settings", "get", "system", "accelerometer_rotation"]
        ))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard setting == "0" else { return }
        _ = try? await adbClient.shell(serial: serial, ["wm", "user-rotation", "free"])
        _ = try? await adbClient.shell(
            serial: serial,
            ["settings", "put", "system", "accelerometer_rotation", "1"]
        )
    }

    /// True while `rotateDevice` runs: the display turn it causes must not
    /// send the pose reading below back over the press.
    @ObservationIgnored private var isRotating = false

    /// The quarter turns the stage shows for a physical-model rotation: a
    /// handheld's own, a TV's, watch's or car's none.
    nonisolated static func emulatorPoseTurns(degrees: Float, formFactor: SystemImage.FormFactor) -> Int {
        formFactor == .handheld ? AndroidDevicePose.turns(forRotationDegrees: degrees) : 0
    }

    /// Puts the stage on the emulator's device pose, read from its physical
    /// model: at a session's start (`snapping`, no animation) and when the
    /// display turned without a Rotate press here. A failed read changes
    /// nothing.
    func followEmulatorDevicePose(snapping: Bool) async {
        guard let port = context.port, let serial = context.serial,
              let degrees = await EmulatorControls.rotation(port: port),
              context.port == port, context.serial == serial, !isRotating
        else { return }
        // A TV, a watch or a car keeps its natural pose. Its AVD may still
        // say `hw.initialOrientation=portrait` (avdmanager writes that for
        // every device, a 1920x1080 TV included), which makes the emulator
        // report the physical model turned a quarter: the stage then drew
        // the landscape TV as a portrait phone.
        let turns = Self.emulatorPoseTurns(
            degrees: degrees,
            formFactor: deviceFormFactor(serial) ?? .handheld
        )
        if snapping {
            guard !stagePose.isAnimating else { return }
            stagePose.snap(toTurns: turns)
        } else {
            stagePose.settle(rotation: turns)
        }
    }

    /// Rotates the device one 90° step in the requested direction, exactly like
    /// Device Manager's two rotate buttons: the physical model rotation is
    /// changed and the stream (which is shown as-is) follows the pose. Works in
    /// every posture, including the folded cover, because it does not depend on
    /// the framework or on auto-rotate.
    func rotateDevice(_ direction: RotationDirection) async {
        guard let adbClient, let serial = context.serial else { return }
        if context.port == nil, activePhysicalSession != nil {
            await rotatePhysicalPhone(direction, adb: adbClient, serial: serial)
            return
        }
        // A press while the wrapper is still animating is ignored: the
        // emulator is serializing the rotation anyway, and a second target
        // mid-flight would only stutter the presentation.
        guard !stagePose.isAnimating, !isRotating else { return }
        isRotating = true
        defer { isRotating = false }

        let before = mirrorViewState.deviceRotation

        // The wrapper starts immediately so the press feels instant; the
        // emulator follows underneath and the settle only flips the texture.
        stagePose.beginRotation(direction)

        // A locked guest would keep the UI portrait while the panel turns,
        // showing a sideways screen with black bands. Pressing rotate means
        // the display should follow, so release the lock first.
        await releaseRotationLock()

        // The physical model's z axis is counterclockwise-positive: +90 turns
        // the device to the left, -90 to the right.
        var rotated = false
        if let port = context.port,
           await EmulatorControls.rotate(port: port, delta: direction == .left ? 90 : -90) {
            rotated = true
        } else {
            rotated = (try? await adbClient.emuCommand(serial: serial, ["rotate"])) != nil
        }
        guard rotated else {
            // Neither channel accepted the command: put the wrapper back on
            // the settled pose instead of leaving it on a pose the device is
            // not in.
            stagePose.cancelRotation()
            return
        }

        // The press is the device pose now. Android may keep its display
        // where it was (phones do not turn to upside down); that is the
        // picture's turn inside the frame, not the frame's.
        stagePose.settle(rotation: TextureRotation.normalized(stagePose.targetTurns))

        // Wait for the rotated frame before repainting so a second press does
        // not race the first.
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(150))
            if mirrorViewState.deviceRotation != before {
                break
            }
        }

        // The mapped buffer can lag the pose change; repaint from a consistent
        // snapshot instead of leaving a torn frame on screen.
        await session?.resync()
    }

    // MARK: - Physical phone rotation

    /// The pose Rotate pinned on the mirrored phone (0...3 counter-clockwise
    /// quarter turns); nil until the first Rotate of the session, when the
    /// phone's own rotation is the pose.
    @ObservationIgnored private(set) var physicalPoseTurns: Int?
    /// What each phone's rotation settings were before the first Rotate,
    /// until they are put back. Kept when a put-back failed (the phone was
    /// gone), so the next session of that phone retries.
    @ObservationIgnored private var savedRotation: [String: AndroidPhoneRotation.Saved] = [:]
    /// The same records on disk, so a crash or a force quit leaves them for
    /// the phone's next session (nil: kept in memory only).
    @ObservationIgnored var rotationStore: AndroidRotationRecordStore?
    /// The put-back in flight (`restorePhysicalRotation`); the quit waits
    /// for it.
    @ObservationIgnored private var rotationRestore: Task<Void, Never>?

    /// How long `rotatePhysicalPhone` waits between reads of the display
    /// turning to the pose it pinned. Settable for tests.
    @ObservationIgnored var physicalRotationPoll: Duration = .milliseconds(50)

    /// Whether Rotate does anything for the mirrored phone: a handheld on the
    /// scrcpy transport (Wear OS, TV and the like keep their orientation).
    func canRotatePhysicalPhone(serial: String) -> Bool {
        (deviceFormFactor(serial) ?? .handheld) == .handheld
    }

    /// One quarter turn of a physical phone through adb
    /// (`AndroidPhoneRotation`): the first press remembers the phone's
    /// settings, every press pins the next pose, and the stage then follows
    /// it (`followPhysicalPose`). The frame is the phone's pose; the picture
    /// is the display scrcpy streams, turned by whatever the display really
    /// did, so a phone that keeps its display at 0 for upside down shows the
    /// home screen upside down, as the emulator does.
    func rotatePhysicalPhone(_ direction: RotationDirection, adb: AdbClient, serial: String) async {
        guard canRotatePhysicalPhone(serial: serial) else { return }
        guard !stagePose.isAnimating, !isRotating else { return }
        isRotating = true
        defer { isRotating = false }
        // The frame turns at once, as for an emulator; the phone follows (or,
        // for an app that stays upright, does not) and `followPhysicalPose`
        // settles the frame on what it did. Waiting for the phone first left
        // the click with no answer for most of a second.
        stagePose.beginRotation(direction)

        let current: Int
        if let known = physicalPoseTurns {
            current = known
        } else {
            current = await adb.displayRotation(serial: serial) ?? 0
        }
        guard context.serial == serial else { return }
        if savedRotation[serial] == nil {
            guard let saved = await AndroidPhoneRotation.read(adb: adb, serial: serial) else {
                stagePose.cancelRotation()
                status.errorMessage = "Could not read the phone's rotation settings."
                return
            }
            savedRotation[serial] = saved
            rotationStore?.set(saved, for: serial)
        }
        let next = TextureRotation.normalized(current + (direction == .left ? 1 : -1))
        do {
            try await AndroidPhoneRotation.lock(adb: adb, serial: serial, turns: next)
        } catch {
            stagePose.cancelRotation()
            status.errorMessage = "Could not rotate the phone: \(error)"
            return
        }
        guard context.serial == serial else { return }
        physicalPoseTurns = next
        // The display follows within a moment when the phone honours the
        // pose; a refused one (180 degrees on most phones, an app that stays
        // upright) never does. A turned display turns the stream's picture,
        // and the settled-geometry hook snaps the frame then; a refused one
        // leaves the frame where Rotate already turned it.
        var honoured = false
        for _ in 0..<16 {
            try? await Task.sleep(for: physicalRotationPoll)
            guard context.serial == serial else { return }
            if await adb.displayRotation(serial: serial) == next {
                honoured = true
                break
            }
        }
        if !honoured { await followPhysicalPose() }
        await session?.resync()
    }

    /// Settles the stage's wrapper on the phone's pose relative to its
    /// display: the frame is composed at the display's rotation (scrcpy
    /// streams it posed), so what is left to turn is the difference. Equal
    /// poses turn nothing; a phone at pose 2 with its display still at 0
    /// turns the whole frame by 180 degrees.
    func followPhysicalPose(snapping: Bool = false) async {
        guard let adbClient, let serial = context.serial, let pose = physicalPoseTurns else { return }
        let display = await adbClient.displayRotation(serial: serial) ?? pose
        guard context.serial == serial, physicalPoseTurns == pose else { return }
        let residual = Self.residualTurns(pose: pose, display: display)
        // Rotate turned the wrapper ahead of the phone: when the stream's picture
        // has turned too, the wrapper's turn is dropped in the same frame (an
        // animation back would spin a picture that is already upright).
        if snapping, TextureRotation.normalized(stagePose.targetTurns) != residual {
            stagePose.snap(toTurns: residual)
            return
        }
        stagePose.settle(rotation: residual)
    }

    /// Quarter turns the frame still needs once the display has turned.
    nonisolated static func residualTurns(pose: Int, display: Int) -> Int {
        TextureRotation.normalized(pose - display)
    }

    /// Puts the phone's own rotation settings back and forgets the pose,
    /// when the mirror of this phone ends. Asynchronous; the app's quit
    /// waits for it (`takeRotationRestore`).
    private func restorePhysicalRotation() {
        physicalPoseTurns = nil
        guard let adbClient, let serial = context.serial,
              let saved = savedRotation[serial]
        else { return }
        let previous = rotationRestore
        rotationRestore = Task { [weak self] in
            await previous?.value
            let restored = await AndroidPhoneRotation.restore(adb: adbClient, serial: serial, saved: saved)
            if restored { self?.forgetRotation(serial: serial) }
        }
    }

    private func forgetRotation(serial: String) {
        savedRotation[serial] = nil
        rotationStore?.remove(serial: serial)
    }

    /// Retries a put-back an earlier session of `serial` could not finish,
    /// whichever transport of the phone recorded it (`aliases`: the inventory's
    /// alias → row serial map): a Rotate over USB whose put-back failed when
    /// the cable came out is put back once the phone is mirrored over Wi-Fi.
    func restorePendingRotation(serial: String, aliases: [String: String] = [:]) {
        // What an earlier run recorded and never put back (it ended first).
        var key = serial
        if savedRotation[serial] == nil {
            let candidates = rotationStore?.keys(samePhoneAs: serial, aliases: aliases) ?? []
            if let found = candidates.first(where: { savedRotation[$0] != nil }) ?? candidates.first {
                key = found
                if savedRotation[found] == nil, let persisted = rotationStore?.record(for: found) {
                    savedRotation[found] = persisted
                }
            }
        }
        guard let adbClient, let saved = savedRotation[key] else { return }
        let previous = rotationRestore
        rotationRestore = Task { [weak self] in
            await previous?.value
            let restored = await AndroidPhoneRotation.restore(adb: adbClient, serial: serial, saved: saved)
            if restored { self?.forgetRotation(serial: key) }
        }
    }

    /// The put-back in flight, for the quit to await; nil when none.
    func takeRotationRestore() -> Task<Void, Never>? {
        defer { rotationRestore = nil }
        return rotationRestore
    }

    // MARK: - Display metrics

    /// Reads the mirrored display's size and density into `state`, the
    /// current session's mirror state, so the mirror's gesture zones, touch
    /// slop and wheel gain use the device's dp instead of a phone-sized
    /// estimate (a tablet is ~2x off, Wear the other way). Mirror views call
    /// it once per session and again when the stream changes shape.
    func loadMirrorDisplayMetrics(for state: MirrorViewState) async {
        // A new session gets a new state, so the serial is the state's.
        guard state === mirrorViewState, let adbClient, let serial = context.serial else { return }
        await state.loadDisplayMetrics {
            await Self.readDisplayMetrics(adb: adbClient, serial: serial)
        }
    }

    /// `wm size` and `wm density` in one shell; nil when either is missing.
    nonisolated static func readDisplayMetrics(adb: AdbClient, serial: String) async -> MirrorDisplayMetrics? {
        guard let output = try? await adb.shell(serial: serial, ["wm size; wm density"], timeout: .seconds(5)) else {
            return nil
        }
        return MirrorDisplayMetrics(wmOutput: output)
    }

    // MARK: - Display shapes

    /// Reads every display's screen shape (corner radii, cutout) into
    /// `state`, the current session's mirror state, so the stage clips the
    /// screen to the device's own corner (`ScreenCornerPolicy`). Mirror
    /// views call it with the display metrics: once per session, and again
    /// only for a frame no listed display fits. The shapes are then
    /// remembered for the emulator's AVD or the phone's model
    /// (`recordDisplayShapes`).
    func loadDisplayShapes(for state: MirrorViewState) async {
        guard state === mirrorViewState, let adbClient, let serial = context.serial else { return }
        await state.loadDisplayShapes {
            await adbClient.displayShapes(serial: serial)
        }
        guard state === mirrorViewState else { return }
        recordDisplayShapes()
    }

    /// Remembers the session's shapes as its AVD's once both are known, so
    /// the AVD's stopped hero and its next session start from them, and as
    /// its phone model's when the session is physical, so the phone's next
    /// session starts from its real corners. The console names the AVD after
    /// the session starts, so `AppModel` calls this again when the name
    /// arrives. An emulator forced through the physical transport
    /// (`DHP_FORCE_PHYSICAL`, the live stand-in for a phone) records
    /// both.
    func recordDisplayShapes() {
        let shapes = mirrorViewState.displayShapes
        guard !shapes.isEmpty else { return }
        if let avdName = context.avdName {
            displayShapes.record(shapes, forAvd: avdName)
        }
        if let model = activePhysicalModel {
            displayShapes.record(shapes, forPhysicalModel: model)
        }
    }

    /// The displays the live stage draws the mirrored screen with: this
    /// session's read, else — until it answers — what the AVD last reported,
    /// else, for a phone, what a phone of its model last reported. Empty
    /// with no data at all.
    ///
    /// An emulator never draws with a model's shapes, not even one forced
    /// through the physical transport, which records under its model: every
    /// AVD on one system image shares that model name (`sdk_gphone64_*`), so
    /// the entry can hold another AVD's panels, and one within the 3% aspect
    /// tolerance (a fold's 1080x2424 cover for a 1080x2400 phone) would lend
    /// it a foreign corner and hole. Its AVD's store is its only fallback.
    var liveDisplayShapes: [DisplayShape] {
        // An Apple device reports nothing over adb: its device type's
        // display stands in (`SimulatorDisplayProfile`).
        if let device = context.device, device.platform == .apple {
            return appleDisplayShapes(device)
        }
        let read = mirrorViewState.displayShapes
        guard read.isEmpty else { return read }
        if let avdName = context.avdName {
            let stored = displayShapes.shapes(forAvd: avdName)
            if !stored.isEmpty { return stored }
        }
        guard let physical = activePhysicalSession,
              !physical.serial.hasPrefix("emulator-"),
              let model = activePhysicalModel
        else { return [] }
        return displayShapes.shapes(forPhysicalModel: model)
    }

    /// The model the active physical session's shapes are kept under; nil
    /// for an emulator session, and while the device list does not name the
    /// phone's model.
    private var activePhysicalModel: String? {
        guard let physical = activePhysicalSession,
              let model = physicalModel(physical.serial), !model.isEmpty
        else { return nil }
        return model
    }

    // MARK: - Screen power

    /// Reads whether `serial`'s screen is on every `screenPowerRefreshInterval`
    /// while it is the device on the stage and the stage shows: `screenIsOff`
    /// follows it. The stage's `.task(id:)` runs it for an Android device, so
    /// it ends with the selection. A failed read keeps the last answer.
    func watchScreenPower(serial: String) async {
        defer { if context.serial == serial { screenIsOff = false } }
        while !Task.isCancelled {
            if context.serial == serial, isStageVisible(), let adbClient,
               let state = await adbClient.wakefulness(serial: serial),
               !Task.isCancelled, context.serial == serial {
                screenIsOff = !state.isScreenOn
            }
            try? await Task.sleep(for: screenPowerRefreshInterval)
        }
    }

    /// Turns `serial`'s screen on (KEYCODE_WAKEUP); on an emulator the lock
    /// screen is dismissed too (`AdbClient.wakeScreen`). The caller passes the
    /// selected device (`DeviceWorkspace.menuTargetSerial`); a serial that is
    /// not the one on the stage is refused.
    func wakeScreen(serial: String, isEmulator: Bool) async {
        guard let adbClient, context.serial == serial else { return }
        wakePulse &+= 1
        do {
            try await adbClient.wakeScreen(serial: serial, dismissKeyguard: isEmulator)
            screenIsOff = false
        } catch {
            status.flash("Couldn't wake the screen")
        }
    }

    // MARK: - Display rotation

    /// How often `watchDisplayRotation` reads a phone's display rotation
    /// again while its panel shows a camera cutout. Settable for tests.
    @ObservationIgnored var displayRotationRefreshInterval: Duration = .seconds(2)

    /// Reads the display rotation into `state` for a physical session,
    /// whose scrcpy frames arrive posed with no rotation of their own: the
    /// vector body turns the host-drawn cutout by it. Once the first frame
    /// settles, and again when the frame turns between portrait and
    /// landscape (`MirrorViewState.loadDisplayRotation`); one `dumpsys
    /// display` each time. An emulator is never asked: its frames carry
    /// their rotation and are shown upright.
    func loadDisplayRotation(for state: MirrorViewState) async {
        guard let read = displayRotationReader(for: state) else { return }
        await state.loadDisplayRotation(reading: read)
    }

    /// `loadDisplayRotation(for:)`, then, while the task runs, the rotation
    /// again every `displayRotationRefreshInterval` whenever the panel the
    /// frame shows has a camera cutout: the vector body's watch, for as long
    /// as it is on screen.
    ///
    /// A phone turned by 180° (landscape to reverse landscape, which Android
    /// phones allow without passing through portrait, or an upside-down
    /// portrait) keeps its frame's size, and scrcpy 3.1 re-frames only when
    /// the display's size changes (its `DisplaySizeMonitor`), so the stream
    /// shows nothing of the turn; only the device can say, and the hole
    /// would stay on the old edge, over live content, until asked. Without a
    /// cutout the rotation changes nothing on the stage and is not read
    /// again. A failed read is retried at the next interval. Views of one
    /// session share the reads (`MirrorViewState.loadDisplayRotation`).
    ///
    /// The vector body's `.task(id:)` starts this watch once per landscape
    /// ⟷ portrait flip of the settled frame — so a phone the mirror finds
    /// already turned (no flip ever happens for the rest of that session)
    /// gets exactly one watch for its whole run. `state`'s session is set
    /// synchronously in `beginMirrorSession` before either could be watched,
    /// so a state mismatch or a session that is not physical at all means
    /// this watch is stale or was never going to apply, and it ends now, as
    /// it always has. `activePhysicalSession` additionally requires
    /// `context.serial` to already name this mirror session's serial, which (like
    /// `adbClient`) can legitimately still be catching up for the instant
    /// this watch starts; waiting here for those is this watch's only other
    /// chance, since nothing else calls it again until the device actually
    /// turns.
    func watchDisplayRotation(for state: MirrorViewState) async {
        var ready: (read: @Sendable () async -> Int?, serial: String)?
        while !Task.isCancelled {
            guard state === mirrorViewState, session is any PhysicalSessionControlling else { return }
            if let adbClient, let serial = context.serial, activePhysicalSession != nil {
                ready = ({ await adbClient.displayRotation(serial: serial) }, serial)
                break
            }
            try? await Task.sleep(for: displayRotationRefreshInterval)
        }
        guard !Task.isCancelled, let (read, serial) = ready else { return }
        await state.loadDisplayRotation(reading: read)
        let interval = displayRotationRefreshInterval
        while !Task.isCancelled {
            // Ends early, with the loop, when the task is cancelled.
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled,
                  state === mirrorViewState,
                  context.serial == serial,
                  activePhysicalSession != nil
            else { return }
            // Nothing shows the cutout while the stage is hidden; the first
            // tick after it shows again reads the rotation.
            guard isStageVisible() else { continue }
            guard let frame = state.devicePixelSize,
                  DisplayShape.matching(frame: frame, in: liveDisplayShapes)?.cutout != nil
            else { continue }
            // Half the interval: a second view's watch finds this read fresh.
            await state.loadDisplayRotation(refreshingAfter: interval / 2, reading: read)
        }
    }

    /// The rotation read for `state`: nil unless it is the current session's
    /// and the session is physical.
    private func displayRotationReader(for state: MirrorViewState) -> (@Sendable () async -> Int?)? {
        guard state === mirrorViewState,
              activePhysicalSession != nil,
              let adbClient,
              let serial = context.serial
        else { return nil }
        return { await adbClient.displayRotation(serial: serial) }
    }
}
