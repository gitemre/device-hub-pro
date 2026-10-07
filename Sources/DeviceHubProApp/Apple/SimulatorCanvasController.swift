import AppKit
import Foundation
import Observation
import DeviceHubProKit

/// A simulator's mirror session, whichever canvas draws it.
protocol SimulatorSessionControlling: MirrorSessionProtocol {
    /// The simulator.
    var udid: String { get }
    /// Whether this is the live canvas (the private bridge): touches, keys
    /// and buttons reach the simulator. The view-only canvas takes none.
    var isLiveCanvas: Bool { get }
}

extension SimulatorMirrorSession: SimulatorSessionControlling {
    var isLiveCanvas: Bool { true }
}

extension SimulatorScreenshotSession: SimulatorSessionControlling {
    var isLiveCanvas: Bool { false }
}

/// The live stage of a simulator (§3.7): which canvas it gets,
/// starting its session through the model's begin hub, the fallback to the
/// view-only canvas, and the simulator's hardware from the Device menu and
/// the pill (Home, Lock, rotation, shake).
///
/// **The canvas.** The live canvas (`SimulatorMirrorSession` on the private
/// bridge) is used when the bridge exists (Xcode found), `BridgeCompatibility`
/// allows this Mac's CoreSimulator, the CoreSimulator the process loaded is
/// still the installed one (an Xcode update while the app runs makes the
/// bridge stale until a relaunch, §3.7), the runtime is an allowlisted one
/// (`liveCanvasRuntimes`: iOS 26 and 27, the runtimes it was verified on), and
/// it has not failed for this simulator since it booted. Otherwise the stage
/// gets the view-only canvas (`SimulatorScreenshotSession`: `simctl io
/// screenshot` at most once a second while shown) and says why.
///
/// **Smoke check.** A live session must publish its first frame within
/// `smokeTimeout` (3 s, T3 in §3.7); then the tier reads T3
/// (`SimulatorInventory.setCanvasReady`). A session that does not, or that
/// stops later for any reason but the simulator shutting down, is replaced
/// by the view-only canvas and the bridge stays off for that simulator
/// until it shuts down (or the user asks to try again). The input barrier of
/// §3.7 is not part of the check: dtuhidd is connected lazily, on the first
/// input (§3.8).
///
/// **Input takeover (§3.8).** Connecting dtuhidd sets
/// `com.apple.coredevice.dtuhidd.active` for the rest of the simulator's
/// boot, and legacy-Indigo clients (older idb, some agent tools) lose input
/// on it from then on. So when a live session starts, before any input, the
/// flag is read (`spawn <UDID> notifyutil -g`); while it read 0, the canvas
/// carries the first-input tooltip (`inputNotice(for:)`). A 1 means Device
/// Hub or another client already connected in this boot: nothing changes.
///
/// It holds no reference to the model: the begin and teardown hubs and the
/// active session come through the hooks `AppModel` sets.
@MainActor
@Observable
final class SimulatorCanvasController {
    /// How a simulator's canvas is drawn.
    enum Canvas: Equatable {
        /// The private bridge: frames from the screen surface, touches, keys
        /// and buttons.
        case live
        /// `simctl io screenshot` about once a second while shown; `reason`
        /// says why the bridge is not used.
        case viewOnly(reason: String)

        var isLive: Bool { self == .live }
    }

    /// The runtimes the live canvas was verified on: iOS 27 (CoreSimulator
    /// 1171.7, `SimulatorMirrorSessionLiveTests`). Xcode 27 refuses input
    /// below iOS 18, and nothing else was measured.
    /// iOS 26 and 27. Each was verified by `Scripts/ios-bridge-smoke.sh` on
    /// a simulator the script creates: iOS 26.5 on 2026-09-28 (Xcode 27.0,
    /// CoreSimulator 1171.7 — every check passed: first frame 608 ms,
    /// 98 fps while dragging, lazy dtuhidd barrier 264 ms, tap and Home
    /// both move the screen, no callback on the main thread).
    static let liveCanvasRuntimes: [(platform: String, major: Int)] = [("iOS", 26), ("iOS", 27)]

    /// Why the live canvas failed for a simulator in its current boot, by
    /// UDID; cleared when it is seen shut down, and by `retryLiveCanvas`
    /// (`SimulatorCanvasMemory`, shared by every window's stage).
    var liveCanvasFailures: [String: String] { memory.liveCanvasFailures }
    /// The simulator whose session is being started.
    private(set) var attaching: String?
    /// Simulators still booting whose live canvas has published its first
    /// frame (`followBootFrames`): the stage shows the device with a spinner
    /// on its screen from then on, as Device Hub does, instead of a bare
    /// spinner until the boot has finished.
    private(set) var bootFrameReady: Set<String> = []
    /// Simulators `followBootFrames` is following: a session of theirs that
    /// stops before the boot ends is the display not being up yet, not a
    /// failure, so it is not replaced by the view-only canvas.
    @ObservationIgnored private var followingBoot: Set<String> = []
    /// Whether dtuhidd was already connected in the simulator's boot when
    /// its live session last started, by UDID
    /// (`SimulatorCanvasMemory.dtuhiddWasActive`).
    var dtuhiddWasActive: [String: Bool] { memory.dtuhiddWasActive }
    /// The mirrored simulator's device orientation as a pose, for its Apple
    /// chrome (`AppleChromeDeviceView`): the chrome turns with the device,
    /// as Device Hub turns it, animated from one orientation to the next.
    /// Portrait when a session starts, unless its first frame shows the
    /// interface turned (the device was turned before); moved by `rotate`.
    let devicePose = StagePoseAnimator()

    /// Starts `session` for `device` with `capabilities` (the model's begin
    /// hub, which tears the previous session down first).
    @ObservationIgnored var beginSession: @MainActor (
        _ session: any MirrorSessionProtocol,
        _ device: DeviceRef,
        _ capabilities: DeviceCapabilities
    ) -> Void = { _, _, _ in }
    /// Ends the active session (the model's teardown hub).
    @ObservationIgnored var tearDownSession: @MainActor (_ cause: MirrorController.MirrorTeardownCause) -> Void = { _ in }
    /// Replaces the capabilities of the mirrored `device` (T2 arrived after
    /// its session started: the view-only canvas can rotate now).
    @ObservationIgnored var updateCapabilities: @MainActor (
        _ device: DeviceRef,
        _ capabilities: DeviceCapabilities
    ) -> Void = { _, _ in }
    /// The mirrored device and its session.
    @ObservationIgnored var activeDevice: @MainActor () -> DeviceRef? = { nil }
    @ObservationIgnored var activeSession: @MainActor () -> (any MirrorSessionProtocol)? = { nil }
    /// How long a live session has to publish its first frame.
    @ObservationIgnored var smokeTimeout: Duration = .seconds(3)
    /// How much longer a session that is still opening (running, no error
    /// yet) gets before the view-only canvas takes over: a Mac busy with
    /// builds or other simulators takes seconds to answer where an idle one
    /// takes 0.6 s, and the fallback lasts until the simulator's next boot.
    /// A session that stopped or reported an error never waits for it.
    @ObservationIgnored var smokeGrace: Duration = .seconds(7)
    /// The wait before the follower starts a boot's session again after
    /// one stopped (the display not up yet): doubles with every stop in a
    /// row, up to `bootRestartMaximumDelay`, and starts over once a frame
    /// arrives. Each start asks CoreSimulator to resolve the screen and
    /// opens threads, so a display that stays away must not be asked about
    /// ten times a second.
    @ObservationIgnored var bootRestartBaseDelay: Duration = .milliseconds(250)
    @ObservationIgnored var bootRestartMaximumDelay: Duration = .seconds(2)
    @ObservationIgnored var smokePollInterval: Duration = .milliseconds(50)
    /// Opens a handoff URL (`NSWorkspace` in the app, a recorder in tests).
    @ObservationIgnored var openURL: @MainActor (_ url: URL) -> Void = { url in
        NSWorkspace.shared.open(url)
    }

    @ObservationIgnored let simulators: SimulatorInventory
    @ObservationIgnored private let mirror: MirrorController
    @ObservationIgnored private let status: StatusCenter
    /// What the canvas learned per simulator (the live canvas's failures,
    /// the dtuhidd flags, the orientations `nextOrientation` reads), shared
    /// by every window's stage.
    @ObservationIgnored let memory: SimulatorCanvasMemory
    @ObservationIgnored private var smokeTask: Task<Void, Never>?

    init(simulators: SimulatorInventory, mirror: MirrorController, memory: SimulatorCanvasMemory, status: StatusCenter) {
        self.simulators = simulators
        self.mirror = mirror
        self.memory = memory
        self.status = status
    }

    // MARK: - Reading

    /// The canvas `entry` gets when its session starts now.
    func canvas(for entry: SimulatorEntry) -> Canvas {
        guard simulators.bridge != nil else {
            return .viewOnly(reason: "The live view needs Xcode 27 and its simulator services.")
        }
        let verdict = simulators.bridgeVerdict()
        guard verdict.allowsBridge else {
            return .viewOnly(reason: Self.reason(for: verdict))
        }
        guard !simulators.bridgeIsStale() else {
            return .viewOnly(reason: Self.staleBridgeReason)
        }
        guard Self.allowsLiveCanvas(platform: entry.platform, version: entry.osVersion) else {
            let runtime = entry.osLabel ?? "this runtime"
            return .viewOnly(reason: "The live view is not verified on \(runtime) yet.")
        }
        if let failure = liveCanvasFailures[entry.udid] {
            return .viewOnly(reason: failure)
        }
        return .live
    }

    /// Whether the live canvas runs on a runtime (`liveCanvasRuntimes`).
    static func allowsLiveCanvas(platform: String?, version: String?) -> Bool {
        guard let platform, let version,
              let major = version.split(separator: ".").first.flatMap({ Int($0) })
        else { return false }
        return liveCanvasRuntimes.contains { $0.platform == platform && $0.major == major }
    }

    /// The stage's line once Xcode replaced the CoreSimulator the process
    /// loaded: its private framework no longer matches the service.
    static let staleBridgeReason = "Xcode was updated: relaunch Device Hub Pro to resume the live view."

    /// The stage's line for a bridge the compatibility check turned off.
    static func reason(for verdict: BridgeCompatibility.Verdict) -> String {
        switch verdict {
        case .allowlisted, .untestedAllowed:
            return ""
        case .untested(let version):
            return "The live view is not tested on this Xcode (CoreSimulator \(version)) yet."
        case .tooOld(let version):
            return "The live view needs Xcode 27 (CoreSimulator \(version) is too old)."
        case .unknownVersion:
            return "The live view needs Xcode 27's simulator services."
        case .disabled:
            return "The live view is turned off (DHP_DISABLE_SIMBRIDGE)."
        }
    }

    /// The first-input tooltip of the live canvas.
    static let inputTakeoverNotice =
        "Your first click or key here connects Device Hub Pro's input to this simulator. Until it restarts, "
        + "tools that use the older simulator input (such as older idb versions) lose keyboard, "
        + "buttons and touch on it."

    /// The live canvas's tooltip for `udid`: the input takeover notice while
    /// the flag read 0 when its session started; nil on the view-only
    /// canvas, when another client had connected already, or when the flag
    /// is not known.
    func inputNotice(for udid: String) -> String? {
        guard session(for: udid)?.isLiveCanvas == true, dtuhiddWasActive[udid] == false else { return nil }
        return Self.inputTakeoverNotice
    }

    /// The active simulator session, when the mirrored device is `udid`.
    func session(for udid: String) -> (any SimulatorSessionControlling)? {
        guard activeDevice() == .apple(udid) else { return nil }
        return activeSession() as? any SimulatorSessionControlling
    }

    /// Whether `udid` is mirrored by a running session.
    func isMirrored(_ udid: String) -> Bool {
        session(for: udid)?.isRunning == true
    }

    // MARK: - Attaching

    /// Starts `udid`'s session when it is booted and not mirrored yet: the
    /// stage calls it once the simulator is ready. A live session then gets
    /// its smoke check in the background. Mirrored or not (the live canvas
    /// may have started under the booting page, `attachForReadiness`),
    /// devicectl is asked about the simulator unless it already answered for
    /// this CoreDevice (T2): the ready simulator, never one still booting.
    func attach(_ udid: String) {
        guard let entry = simulators.entry(udid: udid), entry.state == .booted,
              simulators.simctl != nil
        else { return }
        if !isMirrored(udid) {
            start(entry, canvas: canvas(for: entry))
        }
        probeDevicectl(for: entry.udid)
    }

    /// T2: the simulator the user booted and selected is asked
    /// about once per CoreDevice version (`probeDevicectlIfNeeded`); when
    /// devicectl answers while the simulator is mirrored, its session's
    /// capabilities gain what devicectl backs.
    private func probeDevicectl(for udid: String) {
        guard !simulators.devicectlReady, !simulators.isPrivateSet else { return }
        Task { [weak self] in
            guard let self, await self.simulators.probeDevicectlIfNeeded(udid: udid) else { return }
            self.refreshCapabilities(udid)
        }
    }

    /// The mirrored `udid`'s capabilities, recomputed.
    private func refreshCapabilities(_ udid: String) {
        guard let session = session(for: udid) else { return }
        updateCapabilities(.apple(udid), Self.capabilities(liveCanvas: session.isLiveCanvas, devicectlReady: simulators.devicectlReady))
    }

    /// What a simulator session can do: the live canvas takes input and
    /// turns through the bridge; the view-only one turns only through
    /// devicectl (T2, never in a private set).
    static func capabilities(liveCanvas: Bool, devicectlReady: Bool) -> DeviceCapabilities {
        DeviceCapabilities.simulator(liveCanvas: liveCanvas, rotatesWithoutBridge: devicectlReady)
    }

    /// Starts `udid`'s live canvas before it is ready, while the stage shows
    /// its boot waiting for the home screen: the readiness wait then reads
    /// the canvas's frames (`screenContentFromCanvas`) instead of taking a
    /// `simctl io screenshot` (3 MB) every half second, and the live stage
    /// has its picture the moment the simulator is ready. Only the live
    /// canvas: the view-only one would take the same screenshots.
    func attachForReadiness(_ udid: String) {
        guard !isMirrored(udid),
              let entry = simulators.entry(udid: udid), entry.state == .booted,
              simulators.simctl != nil,
              canvas(for: entry) == .live
        else { return }
        start(entry, canvas: .live)
    }

    /// While `udid` boots (the caller's task ends with the boot): starts the
    /// live canvas as soon as the simulator is listed Booted and starts it
    /// again while the display is not up yet, and publishes the first frame
    /// in `bootFrameReady`. Device Hub shows a warm boot's black device with
    /// a spinner from about 1.3 s; the frame comes about as early here. A
    /// session that fails on the way is dropped without a fallback: the
    /// boot's own readiness wait decides whether the simulator answers.
    ///
    /// `isFirstBoot`: the simulator's first boot. Device Hub keeps a bare
    /// spinner through it, then the "Connecting display…" caption, and shows
    /// the dark device only once the boot logo is gone (a later boot shows
    /// the device from the first second). So the first frame alone does not
    /// count: the boot has finished (`isBootFinished`) and the screen is dark
    /// or shows the home screen. (The logo's progress bar reads as a home
    /// screen to `SimulatorReadiness.screenContent`, hence the first
    /// condition.)
    func followBootFrames(
        _ udid: String,
        isFirstBoot: Bool = false,
        isBootFinished: @MainActor () -> Bool = { true }
    ) async {
        followingBoot.insert(udid)
        defer {
            followingBoot.remove(udid)
            bootFrameReady.remove(udid)
        }
        // Consecutive starts that ended without a frame, and when the next
        // start may happen.
        var failedStarts = 0
        var nextStartAllowed = ContinuousClock.now
        while !Task.isCancelled {
            guard let entry = simulators.entry(udid: udid), entry.state == .booted,
                  simulators.simctl != nil, canvas(for: entry) == .live
            else {
                bootFrameReady.remove(udid)
                try? await Task.sleep(for: bootFramePollInterval)
                continue
            }
            if let live = session(for: udid), live.isRunning {
                if live.frames.current != nil { failedStarts = 0 }
                if live.frames.current != nil, !bootFrameReady.contains(udid) {
                    var shows = !isFirstBoot
                    if isFirstBoot, isBootFinished() {
                        switch await screenContentFromCanvas(udid) {
                        case .homeScreen?, .dark?: shows = true
                        case .bootScreen?, nil: break
                        }
                    }
                    if shows, live.isRunning {
                        bootFrameReady.insert(udid)
                        simulators.setCanvasReady(true, udid: udid)
                        adoptFirstFrameOrientation(udid, session: live)
                    }
                }
            } else {
                // No session, or one that stopped because the display was
                // not up: start again.
                bootFrameReady.remove(udid)
                if session(for: udid) != nil, activeDevice() == .apple(udid) {
                    tearDownSession(.disconnected)
                }
                if ContinuousClock.now >= nextStartAllowed {
                    start(entry, canvas: .live, awaitingBoot: true)
                    nextStartAllowed = ContinuousClock.now + Self.backoff(
                        failedStarts: failedStarts,
                        base: bootRestartBaseDelay,
                        maximum: bootRestartMaximumDelay
                    )
                    failedStarts += 1
                }
            }
            try? await Task.sleep(for: bootFramePollInterval)
        }
        // The boot ended (or the stage left it) with a session running and
        // no frame yet: the smoke check takes over.
        if let live = session(for: udid), live.isRunning, live.frames.current == nil,
           activeSession() === live {
            smokeTask?.cancel()
            smokeTask = Task { [weak self] in
                await self?.smokeCheck(udid, session: live)
            }
        }
    }

    /// How often `followBootFrames` looks for the first frame and restarts a
    /// session whose display was not up yet.
    @ObservationIgnored var bootFramePollInterval: Duration = .milliseconds(100)

    /// The wait after `failedStarts` starts that ended without a frame: zero
    /// for the first (the display may just have come up), then `base`,
    /// doubling, never over `maximum`.
    static func backoff(failedStarts: Int, base: Duration, maximum: Duration) -> Duration {
        guard failedStarts > 0 else { return .zero }
        let doublings = min(failedStarts - 1, 16)
        var delay = base
        for _ in 0..<doublings where delay < maximum { delay = delay * 2 }
        return min(delay, maximum)
    }

    /// What `udid`'s screen shows, read from the live canvas's current frame
    /// (`SimulatorReadiness.screenContent`, off the main actor); nil when no
    /// live canvas of `udid` runs or it has no frame yet, and the readiness
    /// wait takes a screenshot instead. A frame is the screen as it is: the
    /// canvas publishes on every change and keeps the last.
    func screenContentFromCanvas(_ udid: String) async -> SimulatorReadiness.ScreenContent? {
        guard let session = session(for: udid), session.isLiveCanvas, session.isRunning,
              let frame = session.frames.current
        else { return nil }
        return await Task.detached(priority: .utility) {
            FrameImage.cgImage(from: frame).flatMap(SimulatorReadiness.screenContent)
        }.value
    }

    /// Clears the live canvas's failure for `udid` and starts its session
    /// again: the view-only stage's "Try Live View" button.
    func retryLiveCanvas(_ udid: String) {
        memory.liveCanvasFailures[udid] = nil
        guard let entry = simulators.entry(udid: udid), entry.state == .booted else { return }
        start(entry, canvas: canvas(for: entry))
    }

    /// `awaitingBoot`: started by `followBootFrames` while the simulator
    /// boots; it has no smoke check (a first frame that has not come is the
    /// boot, not a failure) and `followBootFrames` reads its first frame.
    private func start(_ entry: SimulatorEntry, canvas: Canvas, awaitingBoot: Bool = false) {
        guard let simctl = simulators.simctl else { return }
        attaching = entry.udid
        defer { attaching = nil }
        smokeTask?.cancel()
        smokeTask = nil
        memory.orientations[entry.udid] = nil
        devicePose.reset()
        let session = mirror.makeSimulatorSession(
            udid: entry.udid,
            deviceSet: simulators.deviceSet,
            simctl: simctl,
            bridge: canvas.isLive ? simulators.bridge : nil
        )
        // devicectl-backed actions need T2 (§3.7): devicectl answered for a
        // simulator of this set (it never does in a private set).
        let capabilities = Self.capabilities(liveCanvas: canvas.isLive, devicectlReady: simulators.devicectlReady)
        beginSession(session, .apple(entry.udid), capabilities)
        guard canvas.isLive else { return }
        readInputFlag(entry.udid, simctl: simctl)
        guard !awaitingBoot else { return }
        smokeTask = Task { [weak self] in
            await self?.smokeCheck(entry.udid, session: session)
        }
    }

    /// Reads `dtuhidd.active` for a live session that just started: the
    /// session connects dtuhidd only on its first input, which cannot come
    /// before its first frame.
    private func readInputFlag(_ udid: String, simctl: SimctlClient) {
        Task { [weak self] in
            // Best effort: without an answer the canvas carries no notice.
            guard let state = try? await simctl.notifyState(
                udid: udid,
                name: SimulatorHardwareActions.dtuhiddActiveNotification
            ) else { return }
            self?.memory.dtuhiddWasActive[udid] = state != 0
        }
    }

    /// Waits for the live session's first frame: T3 when it comes in time,
    /// the view-only canvas when it does not.
    private func smokeCheck(_ udid: String, session: any MirrorSessionProtocol) async {
        let started = ContinuousClock.now
        while !Task.isCancelled {
            guard activeSession() === session else { return }
            if session.frames.current != nil {
                simulators.setCanvasReady(true, udid: udid)
                adoptFirstFrameOrientation(udid, session: session)
                return
            }
            if !session.isRunning { break }
            let waited = ContinuousClock.now - started
            // Past the first window only a session still opening (running,
            // no error) keeps waiting, up to the grace; one with an error
            // fails at once.
            if waited >= smokeTimeout, session.lastError != nil || waited >= smokeTimeout + smokeGrace { break }
            // Best effort: cancellation ends the loop above.
            try? await Task.sleep(for: smokePollInterval)
        }
        guard !Task.isCancelled, activeSession() === session else { return }
        if session.frames.current != nil {
            simulators.setCanvasReady(true, udid: udid)
            adoptFirstFrameOrientation(udid, session: session)
            return
        }
        if session.lastError == SimulatorMirrorSession.shutDownMessage {
            tearDownSession(.disconnected)
            return
        }
        fallBack(udid, reason: session.lastError ?? "no picture within \(Self.seconds(smokeTimeout + smokeGrace)) s")
    }

    /// A live session whose first frame shows the interface turned started
    /// on a device turned before (in Device Hub, or in an earlier session):
    /// the device pose rests there at once, so the Apple chrome is not
    /// drawn upright around a turned screen. Nothing is asked of the
    /// simulator; an interface that stayed portrait on a turned device (the
    /// home screen) is taken for portrait.
    private func adoptFirstFrameOrientation(_ udid: String, session: any MirrorSessionProtocol) {
        guard memory.orientations[udid] == nil,
              let rotation = (session as? SimulatorMirrorSession)?.publishedRotation,
              rotation != .upright
        else { return }
        let orientation = Self.orientation(for: rotation)
        memory.orientations[udid] = orientation
        devicePose.snap(toTurns: AppleChromePose.turns(for: orientation))
    }

    /// The live canvas failed for `udid`: the view-only canvas takes over,
    /// and the live one is not tried again until the simulator shuts down.
    private func fallBack(_ udid: String, reason: String) {
        let line = "The live view stopped: \(reason)"
        memory.liveCanvasFailures[udid] = line
        simulators.setCanvasReady(false, udid: udid)
        guard let entry = simulators.entry(udid: udid), entry.state == .booted else {
            tearDownSession(.transportFatal)
            return
        }
        start(entry, canvas: .viewOnly(reason: line))
        status.flash("Live view unavailable: showing screenshots")
    }

    // MARK: - Session health

    /// The stats poll found the simulator's session stopped: the simulator
    /// shut down (the stage goes back to its stopped page), the live canvas
    /// failed (the view-only one takes over) or the view-only one failed
    /// (the error is raised).
    func sessionStopped(_ session: any SimulatorSessionControlling) {
        guard activeSession() === session else { return }
        let error = session.lastError
        if followingBoot.contains(session.udid) {
            // The display of a simulator still booting is not up yet:
            // `followBootFrames` starts the session again.
            tearDownSession(.disconnected)
            return
        }
        if error == SimulatorMirrorSession.shutDownMessage {
            tearDownSession(.disconnected)
            return
        }
        if session.isLiveCanvas {
            fallBack(session.udid, reason: error ?? "the session ended")
            return
        }
        tearDownSession(.transportFatal)
        if let error {
            status.errorMessage = error
        }
    }

    /// A new listing: the mirrored simulator that is no longer booted (shut
    /// down or deleted elsewhere) loses its session, whose own signal may
    /// not come (a hidden view-only canvas captures nothing); a simulator
    /// seen shut down may try the live canvas again at its next boot.
    func noteListing(_ entries: [SimulatorEntry]) {
        let booted = Set(entries.filter { $0.state == .booted }.map(\.udid))
        memory.forgetAllBut(booted: booted)
        // Slow Animations lasts one boot: a simulator no longer booted has
        // lost it, so its checkmark must not survive into the next boot.
        slowAnimationUDIDs.formIntersection(booted)
        if let device = activeDevice(), device.platform == .apple, !booted.contains(device.id),
           activeSession() is any SimulatorSessionControlling {
            tearDownSession(.disconnected)
        }
    }

    // MARK: - Hardware

    /// The live session of the mirrored simulator.
    private var liveSession: SimulatorMirrorSession? {
        guard let device = activeDevice(), device.platform == .apple else { return nil }
        return activeSession() as? SimulatorMirrorSession
    }

    /// Home (dtuhidd 0x0C/0x40), on the live canvas's input channel.
    func home() {
        liveSession?.press(.home)
    }

    /// The side button (dtuhidd 0x0C/0x30): locks an unlocked simulator,
    /// wakes a locked one.
    func lock() {
        liveSession?.press(.side)
    }

    /// The Siri button (dtuhidd 0x0C/0xCF), held long enough to count as a
    /// press-and-hold, which is how Siri is summoned.
    func siri() {
        liveSession?.press(.siri, hold: .milliseconds(700))
    }

    /// Turns the mirrored simulator a quarter to the left or right: through
    /// devicectl once it answered for this set (T2, never in a private set),
    /// else (or when it fails) the bridge's GSEvent on the live canvas. The
    /// view-only canvas turns only through devicectl, then captures at once;
    /// before T2 it does not turn.
    func rotate(_ direction: RotationDirection) async {
        guard let device = activeDevice(), device.platform == .apple,
              let entry = simulators.entry(udid: device.id),
              let session = activeSession() as? any SimulatorSessionControlling
        else { return }
        let current = memory.orientations[entry.udid]
            ?? Self.orientation(for: (session as? SimulatorMirrorSession)?.publishedRotation)
        let next = Self.nextOrientation(
            from: current,
            direction: direction
        )
        let devicectl: DevicectlClient? = simulators.devicectlReady
            ? (try? simulators.toolchain?.makeDevicectlClient(for: entry.device)) ?? nil
            : nil
        do {
            if session.isLiveCanvas, let bridge = simulators.bridge {
                let actions = SimulatorHardwareActions(
                    address: SimulatorAddress(udid: entry.udid, deviceSetPath: simulators.deviceSet?.path),
                    bridge: bridge,
                    simctl: simulators.simctl,
                    devicectl: devicectl
                )
                try await actions.rotate(to: next)
            } else if let devicectl {
                try await devicectl.setOrientation(next)
            } else {
                return
            }
            memory.orientations[entry.udid] = next
            // The device may have been switched during the await: the pose
            // and the resync belong to the simulator that was rotated.
            guard activeDevice()?.id == entry.udid else { return }
            devicePose.settle(rotation: AppleChromePose.turns(for: next))
            await session.resync()
        } catch {
            status.flash("Could not rotate \(entry.name)")
        }
    }

    /// Experimental: UIKit's simulator-shake notification through simctl
    /// (`SimulatorHardwareActions.shakeNotification`).
    func shake() async {
        guard let device = activeDevice(), device.platform == .apple,
              let simctl = simulators.simctl
        else { return }
        do {
            try await simctl.postDarwinNotification(udid: device.id, name: SimulatorHardwareActions.shakeNotification)
        } catch {
            status.flash("Could not shake the simulator")
        }
    }

    /// The simulators whose Slow Animations this app turned on (the state
    /// lives for one boot; `toggleSlowAnimations` reads the real state before
    /// it flips it).
    private(set) var slowAnimationUDIDs: Set<String> = []

    /// Whether the mirrored simulator runs with Slow Animations on, as far as
    /// the app knows (Device ▸ Slow Animations' checkmark).
    var isSlowAnimationOn: Bool { activeDevice().map { slowAnimationUDIDs.contains($0.id) } ?? false }

    /// Device ▸ Slow Animations (Simulator.app's Debug ▸ Slow Animations):
    /// flips UIKit's slow-motion state in the simulator
    /// (`SimulatorDebugActions.slowAnimationsNotification`).
    func toggleSlowAnimations() async {
        guard let device = activeDevice(), device.platform == .apple,
              let simctl = simulators.simctl
        else { return }
        do {
            let next = try await !simctl.slowAnimationsEnabled(udid: device.id)
            try await simctl.setSlowAnimations(udid: device.id, enabled: next)
            if next { slowAnimationUDIDs.insert(device.id) } else { slowAnimationUDIDs.remove(device.id) }
            status.flash(next ? "Slow Animations on" : "Slow Animations off")
        } catch {
            status.flash("Could not change Slow Animations")
        }
    }

    /// Device ▸ Simulate Memory Warning: bumps the modification time of the
    /// device's `memory_warning_simulation` file
    /// (`SimulatorDebugActions.simulateMemoryWarning`).
    func simulateMemoryWarning() {
        guard let device = activeDevice(), device.platform == .apple,
              let folder = simulators.deviceFolder(udid: device.id)
        else { return }
        do {
            try SimulatorDebugActions.simulateMemoryWarning(dataDirectory: folder.appendingPathComponent("data", isDirectory: true))
            status.flash("Memory warning sent")
        } catch {
            status.flash("Could not send a memory warning")
        }
    }

    /// The device orientation a published frame rotation shows: `uiOrientation`
    /// 4 (`counterClockwise`) is `landscapeLeft`, 3 `landscapeRight`
    /// (`SimulatorOrientation.gsEventValue`, measured on iOS 27.0).
    static func orientation(for rotation: SimulatorFrameRotation?) -> SimulatorOrientation {
        switch rotation {
        case .counterClockwise?: return .landscapeLeft
        case .clockwise?: return .landscapeRight
        case .upsideDown?: return .portraitUpsideDown
        case .upright?, nil: return .portrait
        }
    }

    /// A quarter turn from `current`: to the left, portrait → landscape left
    /// → upside down → landscape right; to the right the other way, for
    /// every device as in Device Hub. An iPhone with Face ID keeps its
    /// interface where it was at upside down, but its frame and screen turn
    /// the half turn all the same (the device pose is separate from the
    /// interface: `AppleChromePose.contentTurns`).
    static func nextOrientation(
        from current: SimulatorOrientation,
        direction: RotationDirection
    ) -> SimulatorOrientation {
        let leftTurns: [SimulatorOrientation] = [.portrait, .landscapeLeft, .portraitUpsideDown, .landscapeRight]
        let step = direction == .left ? 1 : leftTurns.count - 1
        let index = ((leftTurns.firstIndex(of: current) ?? 0) + step) % leftTurns.count
        return leftTurns[index]
    }

    // MARK: - Capture

    /// Why a simulator screenshot could not be taken.
    enum CaptureError: Error, Equatable, CustomStringConvertible {
        /// simctl wrote nothing the app could read.
        case unreadableScreenshot
        /// `io screenshot` had not answered within the bound, in seconds
        /// ("20"): simctl waits 61 s on a screen that is off.
        case screenDidNotAnswer(seconds: String)

        var description: String {
            switch self {
            case .unreadableScreenshot: "The simulator's screenshot could not be read."
            case .screenDidNotAnswer(let seconds):
                "The simulator's screen did not answer within \(seconds) s. Is it off?"
            }
        }
    }

    /// How long a `simctl io screenshot` may take (`simctlScreenshot`).
    @ObservationIgnored var screenshotTimeout: Duration = .seconds(20)

    /// A PNG of the mirrored simulator's screen ("Capture"):
    /// the live canvas's current frame, the screen as its interface shows
    /// it, tagged sRGB like simctl's own capture; on the view-only canvas
    /// (whose picture may be a second old), or before the live canvas's
    /// first frame, a fresh `simctl io <UDID> screenshot`
    /// (`simctlScreenshot`). The frame is encoded off the main actor. Nil
    /// when no simulator is mirrored.
    func screenshotPNG() async throws -> Data? {
        guard let device = activeDevice(), device.platform == .apple,
              let session = activeSession() as? any SimulatorSessionControlling,
              let simctl = simulators.simctl
        else { return nil }
        if session.isLiveCanvas, let frame = session.frames.current {
            let png = await Task.detached(priority: .userInitiated) {
                FrameImage.pngData(from: frame)
            }.value
            if let png { return png }
        }
        return try await Self.simctlScreenshot(udid: device.id, simctl: simctl, timeout: screenshotTimeout)
    }

    /// Starts `simctl io recordVideo` into `url` when the mirrored simulator
    /// is on the view-only canvas, whose once-a-second pictures would make
    /// a slide show; nil for the live canvas, which records its own frames
    /// through the app's recorder, and for any other session.
    func startViewOnlyRecording(to url: URL) -> SimulatorVideoRecording? {
        guard let device = activeDevice(), device.platform == .apple,
              let session = activeSession() as? any SimulatorSessionControlling,
              !session.isLiveCanvas,
              let simctl = simulators.simctl
        else { return nil }
        return SimulatorVideoRecording(udid: device.id, simctl: simctl, url: url)
    }

    /// `simctl io <UDID> screenshot` into a temporary file, read back and
    /// removed: never `-`, which simctl takes for a file name rather than
    /// standard output. Bounded by `timeout`, well below the 61 s simctl
    /// waits on a screen that is off, so simctl's own answer then never
    /// comes: the bound ends it with `CaptureError.screenDidNotAnswer`.
    nonisolated static func simctlScreenshot(
        udid: String,
        simctl: SimctlClient,
        timeout: Duration = .seconds(20)
    ) async throws -> Data {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceHubPro-capture-\(UUID().uuidString).png")
        defer {
            // Best effort: a leftover temporary file is harmless.
            try? FileManager.default.removeItem(at: file)
        }
        do {
            try await simctl.screenshot(udid: udid, to: file, timeout: timeout)
        } catch ProcessRunnerError.timedOut {
            throw CaptureError.screenDidNotAnswer(seconds: seconds(timeout))
        }
        guard let png = try? Data(contentsOf: file), !png.isEmpty else {
            throw CaptureError.unreadableScreenshot
        }
        return png
    }

    // MARK: - Handoff

    /// Shows the simulator in Apple's own app, on a user's click only: Device
    /// Hub (`devices://device/open?id=<UDID>`) on Xcode 27 and later, else
    /// Simulator.app for that device.
    func openInAppleApp(_ udid: String) {
        guard UUID(uuidString: udid) != nil else { return }
        if let url = Self.handoffURL(udid: udid, xcodeVersion: simulators.tooling.xcodeVersion) {
            openURL(url)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["-CurrentDeviceUDID", udid]
        guard let simulatorApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iphonesimulator") else {
            status.flash("Simulator.app was not found")
            return
        }
        NSWorkspace.shared.openApplication(at: simulatorApp, configuration: configuration)
    }

    /// Device Hub's URL for `udid` on Xcode 27 or later (or an unknown
    /// version: Device Hub is the current app); nil before Xcode 27, which
    /// has Simulator.app instead.
    static func handoffURL(udid: String, xcodeVersion: String?) -> URL? {
        if let major = xcodeVersion?.split(separator: ".").first.flatMap({ Int($0) }), major < 27 {
            return nil
        }
        return URL(string: "devices://device/open?id=\(udid)")
    }

    /// The handoff button's title for this Mac's Xcode.
    var handoffTitle: String {
        Self.handoffURL(udid: "00000000-0000-0000-0000-000000000000", xcodeVersion: simulators.tooling.xcodeVersion) == nil
            ? "Open in Simulator"
            : "Open in Device Hub"
    }

    private nonisolated static func seconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return value.formatted(.number.precision(.fractionLength(0...1)))
    }
}

/// The Device menu's simulator items and what enables each (Device Hub's
/// Device menu: power management, then the device's hardware).
///
/// - Start / Shut Down and Restart act on the simulator the stage selects,
///   gated like its row menu: one operation at a time, except that a boot
///   waiting to be ready may be interrupted.
/// - Home, Lock and Shake act on the mirrored Apple device, each gated by
///   what its session can do (`DeviceCapabilities`); rotation is the shared
///   Rotate items'.
/// - Show in Finder, Rename…, Reset Content and Settings… and Remove… are the
///   shared file items, which take the selected simulator too.
///
/// The Android items keep their own gates.
struct SimulatorDeviceMenuState: Equatable {
    /// The selected simulator's UDID, when the stage selects one.
    var selectedUDID: String?
    var showsItems = false
    var isSelectedRunning = false
    var canStart = false
    var canShutDown = false
    var canRestart = false
    /// Show in Finder, Rename…, Reset…, Remove… for the selected simulator.
    var canManage = false
    /// Open URL… on the selected simulator: booted, nothing in flight.
    var canOpenURL = false
    var canPressHome = false
    var canLock = false
    var canRotate = false
    var canShake = false
    /// Slow Animations and Simulate Memory Warning: a simctl spawn and a file
    /// made at boot, so a running simulator with either canvas has both.
    var canDebug = false

    init(
        device: DeviceRef?,
        capabilities: DeviceCapabilities,
        selected: SimulatorEntry? = nil,
        operation: SimulatorLifecycleController.Operation? = nil
    ) {
        if let selected {
            selectedUDID = selected.udid
            isSelectedRunning = selected.state == .booted || selected.state == .booting
            let isFree = operation == nil || operation == .starting
            canStart = !isSelectedRunning && operation == nil && selected.isAvailable
            canShutDown = isSelectedRunning && isFree
            canRestart = isSelectedRunning && isFree
            canManage = isFree
            canOpenURL = selected.state == .booted && operation == nil
        }
        // A stopped simulator answers none of the hardware buttons (Device
        // Hub disables Home, Lock and Siri there).
        if device?.platform == .apple, selected == nil || isSelectedRunning {
            canPressHome = capabilities.contains(.hardwareButtons)
            canLock = capabilities.contains(.hardwareButtons)
            canRotate = capabilities.contains(.rotate)
            canShake = capabilities.contains(.shake)
            canDebug = capabilities.contains(.shake)
        }
        showsItems = selected != nil || device?.platform == .apple
    }
}
