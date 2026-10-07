import IOSurface
import UniformTypeIdentifiers
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// A simulator session the test drives: no simulator, no bridge, no simctl.
/// It publishes a frame, stops with an error, and counts the resyncs, as the
/// test says.
final class FakeSimulatorSession: SimulatorSessionControlling, @unchecked Sendable {
    let udid: String
    let isLiveCanvas: Bool
    let frames = FrameStore()
    var transport: MirrorTransport { isLiveCanvas ? .simulatorSurface : .simulatorScreenshots }

    private let lock = NSLock()
    private var _isRunning = false
    private var _lastError: String?
    private var _resyncs = 0
    private var _stops = 0

    init(udid: String, isLiveCanvas: Bool) {
        self.udid = udid
        self.isLiveCanvas = isLiveCanvas
    }

    var isRunning: Bool { lock.withLock { _isRunning } }
    var lastError: String? { lock.withLock { _lastError } }
    var resyncs: Int { lock.withLock { _resyncs } }
    var stops: Int { lock.withLock { _stops } }

    func start() { lock.withLock { _isRunning = true } }

    func stop() {
        lock.withLock {
            _isRunning = false
            _stops += 1
        }
    }

    func resync() async { lock.withLock { _resyncs += 1 } }

    func stats() async -> MirrorStats {
        MirrorStats(fps: 0, totalFrames: 0, dropped: 0, averageLatencyMs: 0)
    }

    func send(_ command: TouchCommand) {}
    func send(contacts: [TouchCommand]) {}
    func send(_ command: KeyboardCommand) {}

    /// A first frame, as the canvas's smoke check waits for.
    func putFrame() {
        frames.put(Frame(data: Data(repeating: 255, count: 4 * 8 * 4), width: 4, height: 8, seq: 1))
    }

    /// Stops the session on its own, as a transport does, with `error`.
    func end(_ error: String?) {
        lock.withLock {
            _isRunning = false
            _lastError = error
        }
    }

    /// An error while it keeps running (an input the simulator did not take).
    func report(_ error: String) {
        lock.withLock { _lastError = error }
    }
}

/// The simulator canvas (`SimulatorCanvasController`) on a model whose
/// simctl is a stub replaying the lifecycle captures (a booted iPhone 17 Pro
/// on iOS 27.0 in a private set, followed to ready) and whose bridge is a
/// `FakeSimulatorBridge`: which canvas a simulator gets, the start through
/// the begin hub with the simulator's capabilities, the smoke check and the
/// fallback to the view-only canvas, the stats poll's hand-off of a stopped
/// session, the listing's teardown, the hardware (Home, Lock, rotation,
/// shake), the Device menu's gates and the handoff to Apple's app. No adb is
/// ever run for the simulator.
@MainActor
final class SimulatorCanvasTests: XCTestCase {
    private static let udid = SimulatorFixtures.udid
    private static let allowlisted = BridgeCompatibility.Verdict.allowlisted(CoreSimulatorVersion(1171, 7))

    /// The sessions the model's simulator factory made, in order.
    private final class Made {
        var sessions: [(udid: String, live: Bool, session: any MirrorSessionProtocol)] = []
        var fakes: [FakeSimulatorSession] { sessions.compactMap { $0.session as? FakeSimulatorSession } }
    }

    /// Its arms match with or without `--set <folder>` in front (a private
    /// set, or the default one).
    private func makeSimctl(dtuhiddFlag: String = "before-input") throws -> StubTool {
        try makeStubTool("simctl", arms: """
          *"spawn \(Self.udid) notifyutil -g com.apple.coredevice.dtuhidd.active")
            \(SimulatorFixtures.cat("simctl-spawn-notifyutil-g-dtuhidd-active.\(dtuhiddFlag).stdout.txt")) ;;
          *"list -j devices")
            \(SimulatorFixtures.cat("simctl-list-j-devices.booted-after-rename.json")) ;;
          *"list -j runtimes")
            \(SimulatorFixtures.cat("simctl-list-j-runtimes.json")) ;;
          *"list -j devicetypes")
            \(SimulatorFixtures.cat("simctl-list-j-devicetypes.json")) ;;
          *"bootstatus \(Self.udid)")
            \(SimulatorFixtures.cat("simctl-bootstatus.already-booted.stdout.txt")) ;;
          *"spawn \(Self.udid) launchctl list")
            \(SimulatorFixtures.cat("simctl-spawn-launchctl-list.ready.stdout.txt")) ;;
          *"io \(Self.udid) screenshot --type=png "*)
            \(SimulatorFixtures.screenshot("simctl-io-screenshot.home-screen-loading.png")) ;;
          *"spawn \(Self.udid) notifyutil -p com.apple.UIKit.SimulatorShake")
            ;;
          *"spawn \(Self.udid) notifyutil -g com.apple.UIKit.SimulatorSlowMotionAnimationState")
            echo "com.apple.UIKit.SimulatorSlowMotionAnimationState 0" ;;
          *"spawn \(Self.udid) notifyutil -s com.apple.UIKit.SimulatorSlowMotionAnimationState 1 -p com.apple.UIKit.SimulatorSlowMotionAnimationState")
            ;;
        """)
    }

    /// A model whose one simulator is booted and ready, its factory making
    /// fake sessions (or, with `realSessions`, the real ones on the fake
    /// bridge).
    private func readyModel(
        bridge: FakeSimulatorBridge? = FakeSimulatorBridge(),
        verdict: BridgeCompatibility.Verdict = allowlisted,
        bridgeIsStale: Bool = false,
        dtuhiddFlag: String = "before-input",
        devicectl: StubTool? = nil,
        privateSet: Bool = true,
        adb: AdbClient? = nil,
        realSessions: Bool = false
    ) async throws -> (AppModel, Made, StubTool) {
        let simctl = try makeSimctl(dtuhiddFlag: dtuhiddFlag)
        var apple = AppleTooling.stubbed(
            simctl: simctl,
            devicectl: devicectl,
            devicesDirectory: try makeTemporaryFolder("set"),
            logsDirectory: try makeTemporaryFolder("logs"),
            privateSet: privateSet
        )
        apple.makeBridge = { _ in bridge }
        apple.bridgeVerdict = { verdict }
        apple.bridgeIsStale = { bridgeIsStale }
        let model = AppModel.testing(adb: adb, apple: apple)
        addTeardownBlock { @MainActor in
            model.tearDownMirror(cause: .userStop)
            model.stopSimulatorProvider()
        }
        let made = Made()
        if !realSessions {
            model.mirror.simulatorSessionFactoryOverride = { udid, live in
                let session = FakeSimulatorSession(udid: udid, isLiveCanvas: live)
                made.sessions.append((udid, live, session))
                return session
            }
        }
        model.simulatorCanvas.smokeTimeout = .milliseconds(300)
        model.simulatorCanvas.smokePollInterval = .milliseconds(10)
        model.simulatorCanvas.smokeGrace = .zero
        await model.simulators.refresh()
        await waitUntil(timeout: 10, "ready") { model.simulatorLifecycle.isReady(Self.udid) }
        return (model, made, simctl)
    }

    private func entry(_ model: AppModel) throws -> SimulatorEntry {
        try XCTUnwrap(model.simulators.entry(udid: Self.udid))
    }

    // MARK: - Which canvas

    /// iOS 27 on an allowlisted CoreSimulator with the bridge: the live
    /// canvas. Without the bridge, with the bridge turned off, or on another
    /// runtime: the view-only canvas, saying why.
    func testTheCanvasFollowsTheBridgeTheVerdictAndTheRuntime() async throws {
        let (model, _, _) = try await readyModel()
        let iPhone = try entry(model)
        XCTAssertEqual(model.simulatorCanvas.canvas(for: iPhone), .live)

        let (unbridged, _, _) = try await readyModel(bridge: nil)
        guard case .viewOnly(let reason) = unbridged.simulatorCanvas.canvas(for: try entry(unbridged)) else {
            return XCTFail("view only without a bridge")
        }
        XCTAssertTrue(reason.contains("Xcode 27"), reason)

        let (disabled, _, _) = try await readyModel(verdict: .disabled)
        XCTAssertEqual(
            disabled.simulatorCanvas.canvas(for: try entry(disabled)),
            .viewOnly(reason: "The live view is turned off (DHP_DISABLE_SIMBRIDGE).")
        )
        let untested = SimulatorCanvasController.reason(for: .untested(CoreSimulatorVersion(1200, 1)))
        XCTAssertTrue(untested.contains("1200.1"), untested)

        XCTAssertTrue(SimulatorCanvasController.allowsLiveCanvas(platform: "iOS", version: "27.0"))
        XCTAssertTrue(SimulatorCanvasController.allowsLiveCanvas(platform: "iOS", version: "27.1"))
        // iOS 26 passed the same bridge smoke as 27 (26.5 on 2026-09-28).
        XCTAssertTrue(SimulatorCanvasController.allowsLiveCanvas(platform: "iOS", version: "26.5"))
        XCTAssertFalse(SimulatorCanvasController.allowsLiveCanvas(platform: "iOS", version: "25.0"))
        XCTAssertFalse(SimulatorCanvasController.allowsLiveCanvas(platform: "tvOS", version: "27.0"))
        XCTAssertFalse(SimulatorCanvasController.allowsLiveCanvas(platform: nil, version: nil))
    }

    /// Xcode replaced CoreSimulator while the app runs (the loaded one is
    /// no longer the installed one): no new live session on the old private
    /// framework until a relaunch, and the stage says so. Try Live View
    /// cannot bring it back either.
    func testAStaleBridgeKeepsNewSessionsViewOnly() async throws {
        let (model, made, _) = try await readyModel(bridgeIsStale: true)
        let iPhone = try entry(model)

        XCTAssertEqual(
            model.simulatorCanvas.canvas(for: iPhone),
            .viewOnly(reason: "Xcode was updated: relaunch Device Hub Pro to resume the live view.")
        )
        model.simulatorCanvas.attach(Self.udid)
        XCTAssertEqual(made.sessions.map(\.live), [false])
        XCTAssertEqual(model.context.capabilities.contains(.hardwareButtons), false)

        model.simulatorCanvas.retryLiveCanvas(Self.udid)
        XCTAssertEqual(made.sessions.map(\.live), [false, false])
    }

    /// A live session reads `dtuhidd.active` as it starts, before any
    /// input (§3.8): read 0, the canvas carries the first-input tooltip; read
    /// 1 (Device Hub or another client connected in this boot), none. The
    /// view-only canvas takes no input and reads nothing. A shutdown forgets
    /// the reading (a boot starts at 0).
    func testALiveSessionReadsTheInputFlagBeforeItsFirstInput() async throws {
        let (model, _, simctl) = try await readyModel()
        let read = "spawn \(Self.udid) notifyutil -g com.apple.coredevice.dtuhidd.active"
        XCTAssertNil(model.simulatorCanvas.inputNotice(for: Self.udid))

        model.simulatorCanvas.attach(Self.udid)
        await waitUntil(timeout: 5, "the flag read") { model.simulatorCanvas.dtuhiddWasActive[Self.udid] != nil }

        XCTAssertEqual(model.simulatorCanvas.dtuhiddWasActive[Self.udid], false)
        XCTAssertEqual(model.simulatorCanvas.inputNotice(for: Self.udid), SimulatorCanvasController.inputTakeoverNotice)
        XCTAssertEqual(simctl.calls.filter { $0 == read }.count, 1)

        model.simulatorCanvas.noteListing([])
        XCTAssertNil(model.simulatorCanvas.dtuhiddWasActive[Self.udid])

        let (connected, _, _) = try await readyModel(dtuhiddFlag: "after-input")
        connected.simulatorCanvas.attach(Self.udid)
        await waitUntil(timeout: 5, "the flag read") { connected.simulatorCanvas.dtuhiddWasActive[Self.udid] != nil }
        XCTAssertEqual(connected.simulatorCanvas.dtuhiddWasActive[Self.udid], true)
        XCTAssertNil(connected.simulatorCanvas.inputNotice(for: Self.udid))

        let (viewOnly, _, viewOnlySimctl) = try await readyModel(bridge: nil)
        viewOnly.simulatorCanvas.attach(Self.udid)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(viewOnlySimctl.calls.contains(read))
        XCTAssertNil(viewOnly.simulatorCanvas.inputNotice(for: Self.udid))
    }

    // MARK: - Starting

    /// A ready simulator's live session starts through the begin hub: the
    /// context names the Apple device with the live canvas's capabilities
    /// (no rotation without the bridge's route in a private set: the bridge
    /// is there, so it rotates), no adb serial, no port. Its first frame
    /// passes the smoke check: tier T3.
    func testAttachStartsTheLiveCanvasAndItsFirstFramePassesTheSmokeCheck() async throws {
        let (model, made, _) = try await readyModel()
        XCTAssertEqual(model.simulators.tooling.tier, .t1)

        model.simulatorCanvas.attach(Self.udid)

        XCTAssertEqual(made.sessions.count, 1)
        XCTAssertEqual(made.sessions.first?.live, true)
        let session = try XCTUnwrap(made.fakes.first)
        XCTAssertTrue(session.isRunning)
        XCTAssertTrue(model.workspace.mirror.session === session)
        XCTAssertEqual(model.context.device, .apple(Self.udid))
        XCTAssertEqual(model.context.capabilities, .simulator(liveCanvas: true, rotatesWithoutBridge: false))
        XCTAssertNil(model.activeDeviceSerial)
        XCTAssertNil(model.workspace.context.port)
        XCTAssertTrue(model.simulatorCanvas.isMirrored(Self.udid))

        model.simulatorCanvas.attach(Self.udid)
        XCTAssertEqual(made.sessions.count, 1, "a mirrored simulator is not attached again")

        session.putFrame()
        await waitUntil(timeout: 3, "T3") { model.simulators.tooling.tier == .t3 }
    }

    /// A live session that shows nothing within the smoke check's bound is
    /// replaced by the view-only canvas, which keeps the reason; the live
    /// one is not tried again for that boot until the user asks.
    func testALiveCanvasWithoutAFrameFallsBackToViewOnly() async throws {
        let (model, made, _) = try await readyModel()
        model.simulatorCanvas.attach(Self.udid)
        let live = try XCTUnwrap(made.fakes.first)

        await waitUntil(timeout: 3, "fallback") { made.sessions.count == 2 }

        XCTAssertEqual(made.sessions.map(\.live), [true, false])
        XCTAssertFalse(live.isRunning, "the live session was torn down")
        let viewOnly = try XCTUnwrap(made.fakes.last)
        XCTAssertTrue(model.workspace.mirror.session === viewOnly)
        XCTAssertEqual(model.context.capabilities, .simulator(liveCanvas: false, rotatesWithoutBridge: false))
        XCTAssertNotNil(model.simulatorCanvas.liveCanvasFailures[Self.udid])
        guard case .viewOnly(let reason) = model.simulatorCanvas.canvas(for: try entry(model)) else {
            return XCTFail("view only after the failure")
        }
        XCTAssertTrue(reason.hasPrefix("The live view stopped:"), reason)
        XCTAssertNotEqual(model.simulators.tooling.tier, .t3)

        model.simulatorCanvas.retryLiveCanvas(Self.udid)
        XCTAssertEqual(made.sessions.map(\.live), [true, false, true])
        XCTAssertNil(model.simulatorCanvas.liveCanvasFailures[Self.udid])
    }

    /// A live session still opening (running, no error) gets the grace after
    /// the first window: a slow Mac is not demoted for the rest of the boot.
    /// One that already reported an error fails at the first window's end.
    func testASessionStillOpeningGetsTheGraceBeforeTheFallback() async throws {
        let (model, made, _) = try await readyModel()
        model.simulatorCanvas.smokeTimeout = .milliseconds(100)
        model.simulatorCanvas.smokeGrace = .milliseconds(1500)
        model.simulatorCanvas.attach(Self.udid)
        let live = try XCTUnwrap(made.fakes.first)

        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(made.sessions.map(\.live), [true], "still waiting inside the grace")
        live.putFrame()
        await waitUntil(timeout: 3, "T3") { model.simulators.tooling.tier == .t3 }
        XCTAssertEqual(made.sessions.map(\.live), [true])

        let (failing, madeFailing, _) = try await readyModel()
        failing.simulatorCanvas.smokeTimeout = .milliseconds(100)
        failing.simulatorCanvas.smokeGrace = .seconds(30)
        failing.simulatorCanvas.attach(Self.udid)
        try XCTUnwrap(madeFailing.fakes.first).report("the display vends no framebuffer surface")
        await waitUntil(timeout: 3, "fallback") { madeFailing.sessions.count == 2 }
        XCTAssertEqual(madeFailing.sessions.map(\.live), [true, false])
    }

    /// The boot follower waits longer between starts of a session whose
    /// display stays away, up to a cap, and the first start is immediate.
    func testTheBootRestartBackoffDoublesUpToACap() {
        let base = Duration.milliseconds(250)
        let cap = Duration.seconds(2)
        typealias Canvas = SimulatorCanvasController
        XCTAssertEqual(Canvas.backoff(failedStarts: 0, base: base, maximum: cap), .zero)
        XCTAssertEqual(Canvas.backoff(failedStarts: 1, base: base, maximum: cap), .milliseconds(250))
        XCTAssertEqual(Canvas.backoff(failedStarts: 2, base: base, maximum: cap), .milliseconds(500))
        XCTAssertEqual(Canvas.backoff(failedStarts: 3, base: base, maximum: cap), .seconds(1))
        XCTAssertEqual(Canvas.backoff(failedStarts: 4, base: base, maximum: cap), .seconds(2))
        XCTAssertEqual(Canvas.backoff(failedStarts: 50, base: base, maximum: cap), .seconds(2))
    }

    /// A display that never comes up: the follower starts a session at once,
    /// then no faster than the backoff, not every poll.
    func testTheBootFollowerBacksOffFromASessionThatKeepsStopping() async throws {
        let (model, made, _) = try await readyModel()
        let canvas = model.simulatorCanvas
        canvas.bootFramePollInterval = .milliseconds(5)
        canvas.bootRestartBaseDelay = .milliseconds(200)
        canvas.bootRestartMaximumDelay = .milliseconds(400)
        let follower = Task { await canvas.followBootFrames(Self.udid) }
        let stopper = Task { @MainActor in
            var stopped = 0
            while !Task.isCancelled {
                if made.fakes.count > stopped {
                    made.fakes[stopped].end("The simulator shut down.")
                    stopped += 1
                }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        try await Task.sleep(for: .milliseconds(1500))
        follower.cancel()
        stopper.cancel()
        await follower.value
        // Unbacked, a 5 ms poll would start ~300 sessions in 1.5 s.
        XCTAssertGreaterThanOrEqual(made.sessions.count, 3)
        XCTAssertLessThanOrEqual(made.sessions.count, 8, "\(made.sessions.count) sessions started")
    }

    /// Without the bridge the view-only canvas starts at once and has no
    /// smoke check.
    func testWithoutTheBridgeTheViewOnlyCanvasStarts() async throws {
        let (model, made, _) = try await readyModel(bridge: nil)
        model.simulatorCanvas.attach(Self.udid)
        XCTAssertEqual(made.sessions.map(\.live), [false])
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(made.sessions.count, 1)
        XCTAssertEqual(model.context.capabilities, [.mirror, .shake])
    }

    /// The real factory: the live canvas on the bridge, the view-only one
    /// on simctl. Making them runs nothing.
    func testTheFactoryMakesTheRealSessions() async throws {
        let (model, _, simctl) = try await readyModel(realSessions: true)
        let client = try XCTUnwrap(model.simulators.simctl)
        let calls = simctl.calls.count
        let live = model.mirror.makeSimulatorSession(udid: Self.udid, deviceSet: nil, simctl: client, bridge: FakeSimulatorBridge())
        let viewOnly = model.mirror.makeSimulatorSession(udid: Self.udid, deviceSet: nil, simctl: client, bridge: nil)
        XCTAssertTrue(live is SimulatorMirrorSession)
        XCTAssertTrue(viewOnly is SimulatorScreenshotSession)
        XCTAssertEqual((live as? any SimulatorSessionControlling)?.isLiveCanvas, true)
        XCTAssertEqual((viewOnly as? any SimulatorSessionControlling)?.isLiveCanvas, false)
        XCTAssertEqual(simctl.calls.count, calls)
    }

    // MARK: - Health

    /// The stats poll hands a stopped simulator session to the canvas: a
    /// shut-down simulator's session is torn down; a live canvas that failed
    /// gives way to the view-only one; a running session's error is flashed
    /// once.
    func testTheStatsPollHandsAStoppedSessionToTheCanvas() async throws {
        let (model, made, _) = try await readyModel()
        model.simulatorCanvas.attach(Self.udid)
        let live = try XCTUnwrap(made.fakes.first)
        live.putFrame()

        live.report("Simulator input: dtuhidd did not answer")
        await waitUntil(timeout: 3, "flashed") { model.workspace.status.statusMessage == "Simulator input: dtuhidd did not answer" }

        live.end("the bridge failed")
        await waitUntil(timeout: 3, "fallback") { made.sessions.count == 2 }
        XCTAssertEqual(made.sessions.last?.live, false)

        let viewOnly = try XCTUnwrap(made.fakes.last)
        viewOnly.end(SimulatorMirrorSession.shutDownMessage)
        await waitUntil(timeout: 3, "torn down") { model.workspace.mirror.session == nil }
        XCTAssertNil(model.context.device)
        XCTAssertEqual(made.sessions.count, 2, "a shut-down simulator gets no new session")
    }

    /// A view-only session that fails for good is torn down and its error
    /// raised.
    func testAFailedViewOnlySessionIsTornDownWithItsError() async throws {
        let (model, made, _) = try await readyModel(bridge: nil)
        model.simulatorCanvas.attach(Self.udid)
        let viewOnly = try XCTUnwrap(made.fakes.first)
        viewOnly.end("Simulator screenshot failed: disk full")
        await waitUntil(timeout: 3, "torn down") { model.workspace.mirror.session == nil }
        XCTAssertEqual(model.workspace.status.errorMessage, "Simulator screenshot failed: disk full")
    }

    /// A listing that no longer shows the mirrored simulator booted ends its
    /// session (a hidden view-only canvas would never notice).
    func testAListingWithoutTheBootedSimulatorEndsItsSession() async throws {
        let (model, made, _) = try await readyModel(bridge: nil)
        model.simulatorCanvas.attach(Self.udid)
        XCTAssertNotNil(model.workspace.mirror.session)
        let shutDown = try SimulatorFixtures.entry("simctl-list-j-devices.cloned.json", udid: Self.udid)
        XCTAssertEqual(shutDown.state, .shutdown)

        model.simulatorCanvas.noteListing([shutDown])

        XCTAssertNil(model.workspace.mirror.session)
        XCTAssertEqual(made.fakes.first?.isRunning, false)
    }

    // MARK: - Hardware

    private static func surface() throws -> SimulatorSurface {
        SimulatorSurface(try XCTUnwrap(IOSurface(properties: [
            .width: 4,
            .height: 8,
            .bytesPerElement: 4,
            .pixelFormat: 0x4247_5241,
        ])))
    }

    /// Home and Lock press the dtuhidd buttons on the live session's own
    /// input channel; the frame's power button is the side button.
    func testHomeAndLockPressTheButtonsOnTheLiveSession() async throws {
        var configuration = FakeSimulatorBridge.Configuration()
        configuration.surface = try Self.surface()
        configuration.properties = SimulatorScreenProperties(screenType: 0, screenID: 1, uiOrientation: 1, pixelWidth: 4, pixelHeight: 8)
        let bridge = FakeSimulatorBridge(configuration)
        let (model, _, _) = try await readyModel(bridge: bridge, realSessions: true)
        model.simulatorCanvas.attach(Self.udid)
        let session = try XCTUnwrap(model.workspace.mirror.session as? SimulatorMirrorSession)
        await waitUntil(timeout: 3, "first frame") { session.frames.current != nil }
        XCTAssertTrue(model.mirror.supportsHardwareKeys, "the frame's side buttons are offered")

        model.simulatorCanvas.home()
        model.simulatorCanvas.lock()

        await waitUntil(timeout: 3, "pressed") { bridge.inputs.first?.sent.count == 4 }
        XCTAssertEqual(bridge.inputs.count, 1)
        XCTAssertEqual(bridge.inputs.first?.sent, [
            .button(.home, isDown: true), .button(.home, isDown: false),
            .button(.side, isDown: true), .button(.side, isDown: false),
        ])
        XCTAssertEqual(bridge.mainThreadCalls, 0)
    }

    /// In a private set (CoreDevice cannot see it) the live canvas turns the
    /// simulator with the GSEvent; an iPhone reaches upside down too (its
    /// frame turns half a turn, Device Hub's Rotate); the picture
    /// is read again after each turn.
    func testRotationTurnsThroughTheBridgeAndReachesUpsideDownOnAnIPhone() async throws {
        let bridge = FakeSimulatorBridge()
        let (model, made, _) = try await readyModel(bridge: bridge)
        model.simulatorCanvas.attach(Self.udid)
        let session = try XCTUnwrap(made.fakes.first)
        session.putFrame()

        let pose = model.simulatorCanvas.devicePose
        XCTAssertEqual(pose.targetTurns, 0, "a session starts upright")
        await model.workspace.rotateDevice(.left)
        XCTAssertEqual(pose.targetTurns, 1, "the Apple chrome turns to landscape left")
        await model.workspace.rotateDevice(.left)
        XCTAssertEqual(pose.targetTurns, 2, "upside down, half a turn, an iPhone included")
        await model.workspace.rotateDevice(.right)
        XCTAssertEqual(pose.targetTurns, 1)
        XCTAssertEqual(pose.presentedAngle, -90)
        await model.workspace.rotateDevice(.right)
        XCTAssertEqual(pose.targetTurns, 0)
        await model.workspace.rotateDevice(.right)
        XCTAssertEqual(pose.targetTurns, -1, "the other way: landscape right")

        XCTAssertEqual(bridge.gsEvents.flatMap(\.sent), [
            .orientation(SimulatorOrientation.landscapeLeft.gsEventValue),
            .orientation(SimulatorOrientation.portraitUpsideDown.gsEventValue),
            .orientation(SimulatorOrientation.landscapeLeft.gsEventValue),
            .orientation(SimulatorOrientation.portrait.gsEventValue),
            .orientation(SimulatorOrientation.landscapeRight.gsEventValue),
        ])
        XCTAssertEqual(session.resyncs, 5)

        // A new session starts upright again.
        model.stopMirror()
        model.simulatorCanvas.attach(Self.udid)
        XCTAssertEqual(pose.targetTurns, 0)
        XCTAssertEqual(pose.presentedAngle, 0)
    }

    /// devicectl-backed rotation is T2 (§3.7): in the default set the
    /// view-only canvas does not offer Rotate, and runs no devicectl, until
    /// The attach asks devicectl about the simulator the user booted and
    /// selected (`device info details`, T2); when it answers, the
    /// running view-only session gains rotation, which turns through `device
    /// orientation set`. A later attach does not ask again. The answers are
    /// the devicectl captures (an iPhone 17 Pro on iOS 27.0).
    func testTheViewOnlyCanvasTurnsThroughDevicectlOnceT2Arrives() async throws {
        let details = SimulatorFixtures.cat("devicectl-device-info-details.json", folder: "devicectl")
        let turned = SimulatorFixtures.cat("devicectl-device-orientation-set-landscapeLeft.json", folder: "devicectl")
        let devicectl = try makeStubTool("devicectl", arms: """
          "device info details --device \(Self.udid) -j - -t 30")
            \(details) ;;
          "device orientation set landscapeLeft --device \(Self.udid) -j - -t 30")
            \(turned) ;;
        """)
        let (model, made, _) = try await readyModel(bridge: nil, devicectl: devicectl, privateSet: false)
        XCTAssertFalse(model.simulators.isPrivateSet)
        XCTAssertEqual(model.simulators.tooling.tier, .t1)

        model.simulatorCanvas.attach(Self.udid)
        await waitUntil("devicectl answered") { model.simulators.tooling.tier == .t2 }
        await waitUntil("the session can turn") {
            model.context.capabilities == .simulator(liveCanvas: false, rotatesWithoutBridge: true)
        }
        XCTAssertEqual(devicectl.calls, ["device info details --device \(Self.udid) -j - -t 30"])
        XCTAssertEqual(made.sessions.map(\.live), [false], "the same session")
        XCTAssertTrue(SimulatorDeviceMenuState(device: .apple(Self.udid), capabilities: model.context.capabilities).canRotate)

        await model.workspace.rotateDevice(.left)
        XCTAssertEqual(devicectl.calls.last, "device orientation set landscapeLeft --device \(Self.udid) -j - -t 30")
        XCTAssertEqual(made.fakes.last?.resyncs, 1, "the view-only canvas captures at once")

        model.stopMirror()
        model.simulatorCanvas.attach(Self.udid)
        XCTAssertEqual(model.context.capabilities, .simulator(liveCanvas: false, rotatesWithoutBridge: true))
        // Best effort: give a stray probe a moment to show up.
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(devicectl.calls.filter { $0.hasPrefix("device info details") }.count, 1)
    }

    /// devicectl that does not answer leaves the view-only canvas unable to
    /// turn: nothing is sent. A failed answer is not definitive, so a later
    /// attach asks again (up to `SimulatorInventory.maxDevicectlAttempts`).
    func testWithoutADevicectlAnswerTheViewOnlyCanvasDoesNotTurn() async throws {
        let devicectl = try makeStubTool("devicectl", arms: "")
        let (model, _, _) = try await readyModel(bridge: nil, devicectl: devicectl, privateSet: false)

        model.simulatorCanvas.attach(Self.udid)
        await waitUntil("devicectl was asked") { devicectl.calls.count == 1 }
        // Best effort: let the failed answer settle.
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.simulators.tooling.tier, .t1)
        XCTAssertEqual(model.context.capabilities, .simulator(liveCanvas: false, rotatesWithoutBridge: false))
        await model.workspace.rotateDevice(.left)
        model.stopMirror()
        model.simulatorCanvas.attach(Self.udid)
        try? await Task.sleep(for: .milliseconds(200))
        let ask = "device info details --device \(Self.udid) -j - -t 30"
        XCTAssertEqual(devicectl.calls, [ask, ask])
    }

    /// A boot followed on the stage starts the live canvas under the booting
    /// page (`attachForReadiness`), so at ready the stage's attach finds the
    /// simulator mirrored already: it starts no second session but still
    /// asks devicectl (T2), once. Before the merge of the two
    /// tracks it asked only when it started the session, so T2 never came
    /// for a simulator booted from the stage.
    func testTheReadyAttachAsksDevicectlWhenTheCanvasStartedEarly() async throws {
        let details = SimulatorFixtures.cat("devicectl-device-info-details.json", folder: "devicectl")
        let devicectl = try makeStubTool("devicectl", arms: """
          "device info details --device \(Self.udid) -j - -t 30")
            \(details) ;;
        """)
        let (model, made, _) = try await readyModel(devicectl: devicectl, privateSet: false)

        model.simulatorCanvas.attachForReadiness(Self.udid)
        XCTAssertEqual(made.sessions.map(\.live), [true])
        try XCTUnwrap(made.fakes.first).putFrame()
        // Best effort: attachForReadiness itself asks nothing.
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(devicectl.calls, [])

        model.simulatorCanvas.attach(Self.udid)
        await waitUntil("devicectl answered") { model.simulators.devicectlReady }
        XCTAssertEqual(made.sessions.map(\.live), [true], "the same session")
        model.simulatorCanvas.attach(Self.udid)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(devicectl.calls, ["device info details --device \(Self.udid) -j - -t 30"])
    }

    /// A boot that is not the simulator's first shows its device from the
    /// first frame the live canvas publishes (Device Hub's black device with
    /// a spinner, 1 s into a warm boot), and the flag ends with the follower.
    func testTheBootFollowerPublishesTheFirstFrameOfALaterBoot() async throws {
        let (model, made, _) = try await readyModel()
        let canvas = model.simulatorCanvas
        canvas.bootFramePollInterval = .milliseconds(10)
        let follower = Task { await canvas.followBootFrames(Self.udid) }
        await waitUntil("the live canvas started") { made.sessions.map(\.live) == [true] }
        XCTAssertFalse(canvas.bootFrameReady.contains(Self.udid), "no frame yet")
        try XCTUnwrap(made.fakes.first).putFrame()
        await waitUntil("the first frame is published") { canvas.bootFrameReady.contains(Self.udid) }
        follower.cancel()
        await follower.value
        XCTAssertFalse(canvas.bootFrameReady.contains(Self.udid), "cleared when the boot ends")
    }

    /// A first boot keeps the bare spinner while its boot has not finished,
    /// whatever the screen shows: the boot logo's progress bar reads as a home
    /// screen to the readiness check.
    func testTheBootFollowerHoldsAFirstBootUntilTheBootHasFinished() async throws {
        let (model, made, _) = try await readyModel()
        let canvas = model.simulatorCanvas
        canvas.bootFramePollInterval = .milliseconds(10)
        let follower = Task { await canvas.followBootFrames(Self.udid, isFirstBoot: true, isBootFinished: { false }) }
        await waitUntil("the live canvas started") { made.sessions.map(\.live) == [true] }
        try XCTUnwrap(made.fakes.first).putFrame()
        // Best effort: give the follower time to (not) act on the frame.
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(canvas.bootFrameReady.contains(Self.udid))
        follower.cancel()
        await follower.value
    }

    /// The view-only canvas in a private set cannot turn (no devicectl, no
    /// bridge): nothing is sent.
    func testTheViewOnlyCanvasInAPrivateSetDoesNotRotate() async throws {
        let bridge = FakeSimulatorBridge()
        let (model, made, _) = try await readyModel(bridge: bridge, verdict: .disabled)
        model.simulatorCanvas.attach(Self.udid)
        await model.workspace.rotateDevice(.left)
        XCTAssertTrue(bridge.gsEvents.isEmpty)
        XCTAssertEqual(made.fakes.first?.resyncs, 0)
    }

    /// Shake posts UIKit's notification through simctl, with the UDID.
    func testShakePostsTheNotification() async throws {
        let (model, _, simctl) = try await readyModel(bridge: nil)
        model.simulatorCanvas.attach(Self.udid)
        await model.simulatorCanvas.shake()
        XCTAssertTrue(simctl.calls.contains("spawn \(Self.udid) notifyutil -p com.apple.UIKit.SimulatorShake"), "\(simctl.calls)")
    }

    /// Slow Animations reads the state, then sets the opposite one and posts.
    func testSlowAnimationsToggleFlipsTheState() async throws {
        let (model, _, simctl) = try await readyModel(bridge: nil)
        model.simulatorCanvas.attach(Self.udid)
        XCTAssertFalse(model.simulatorCanvas.isSlowAnimationOn)
        await model.simulatorCanvas.toggleSlowAnimations()
        let name = "com.apple.UIKit.SimulatorSlowMotionAnimationState"
        XCTAssertTrue(simctl.calls.contains("spawn \(Self.udid) notifyutil -g \(name)"), "\(simctl.calls)")
        XCTAssertTrue(simctl.calls.contains("spawn \(Self.udid) notifyutil -s \(name) 1 -p \(name)"), "\(simctl.calls)")
        XCTAssertTrue(model.simulatorCanvas.isSlowAnimationOn)
    }

    /// Slow Animations lasts one boot: a listing that no longer shows the
    /// simulator booted drops its checkmark.
    func testASimulatorThatStoppedLosesItsSlowAnimationsMark() async throws {
        let (model, _, _) = try await readyModel(bridge: nil)
        model.simulatorCanvas.attach(Self.udid)
        await model.simulatorCanvas.toggleSlowAnimations()
        XCTAssertTrue(model.simulatorCanvas.slowAnimationUDIDs.contains(Self.udid))
        let shutDown = try SimulatorFixtures.entry("simctl-list-j-devices.cloned.json", udid: Self.udid)
        model.simulatorCanvas.noteListing([shutDown])
        XCTAssertTrue(model.simulatorCanvas.slowAnimationUDIDs.isEmpty)
    }

    /// Simulate Memory Warning bumps the device folder's file.
    func testSimulateMemoryWarningTouchesTheDevicesFile() async throws {
        let (model, _, _) = try await readyModel(bridge: nil)
        model.simulatorCanvas.attach(Self.udid)
        let folder = try XCTUnwrap(model.simulators.deviceFolder(udid: Self.udid))
        let file = SimulatorDebugActions.memoryWarningFile(dataDirectory: folder.appendingPathComponent("data", isDirectory: true))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        model.simulatorCanvas.simulateMemoryWarning()
        let modified = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        XCTAssertGreaterThan(modified, old)
    }

    /// The quarter turns: left goes portrait → landscape left → upside down
    /// → landscape right, for every device (an iPhone included).
    func testTheOrientationCycle() {
        typealias Canvas = SimulatorCanvasController
        XCTAssertEqual(Canvas.nextOrientation(from: .portrait, direction: .left), .landscapeLeft)
        XCTAssertEqual(Canvas.nextOrientation(from: .landscapeLeft, direction: .left), .portraitUpsideDown)
        XCTAssertEqual(Canvas.nextOrientation(from: .portraitUpsideDown, direction: .left), .landscapeRight)
        XCTAssertEqual(Canvas.nextOrientation(from: .landscapeRight, direction: .left), .portrait)
        XCTAssertEqual(Canvas.nextOrientation(from: .portrait, direction: .right), .landscapeRight)
        XCTAssertEqual(Canvas.nextOrientation(from: .landscapeRight, direction: .right), .portraitUpsideDown)
        XCTAssertEqual(Canvas.nextOrientation(from: .portraitUpsideDown, direction: .right), .landscapeLeft)
        XCTAssertEqual(Canvas.orientation(for: .counterClockwise), .landscapeLeft)
        XCTAssertEqual(Canvas.orientation(for: .clockwise), .landscapeRight)
        XCTAssertEqual(Canvas.orientation(for: nil), .portrait)
    }

    // MARK: - Menus and handoff

    /// The Device menu's simulator items: shown only for an Apple device,
    /// each on its capability.
    func testTheDeviceMenuItemsFollowTheCapabilities() {
        let apple = DeviceRef.apple(Self.udid)
        XCTAssertFalse(SimulatorDeviceMenuState(device: nil, capabilities: []).showsItems)
        XCTAssertFalse(SimulatorDeviceMenuState(device: .android("emulator-5554"), capabilities: .android(emulatorGrpc: true)).showsItems)

        let live = SimulatorDeviceMenuState(device: apple, capabilities: .simulator(liveCanvas: true, rotatesWithoutBridge: false))
        XCTAssertTrue(live.showsItems)
        XCTAssertTrue(live.canPressHome)
        XCTAssertTrue(live.canLock)
        XCTAssertTrue(live.canRotate)
        XCTAssertTrue(live.canShake)
        XCTAssertTrue(live.canDebug)

        let viewOnly = SimulatorDeviceMenuState(device: apple, capabilities: .simulator(liveCanvas: false, rotatesWithoutBridge: false))
        XCTAssertTrue(viewOnly.showsItems)
        XCTAssertFalse(viewOnly.canPressHome)
        XCTAssertFalse(viewOnly.canLock)
        XCTAssertFalse(viewOnly.canRotate)
        XCTAssertTrue(viewOnly.canShake)

        let defaultSet = SimulatorDeviceMenuState(device: apple, capabilities: .simulator(liveCanvas: false, rotatesWithoutBridge: true))
        XCTAssertTrue(defaultSet.canRotate)
    }

    /// The selected simulator's power and file items: Start while it is
    /// shut down, Shut Down and Restart while it runs, nothing while another
    /// operation runs (a boot waiting to be ready may be interrupted). They
    /// show without a mirror; the hardware items stay off then.
    func testTheDeviceMenuPowerItemsFollowTheSelectedSimulator() throws {
        let booted = try SimulatorFixtures.entry("simctl-list-j-devices.booted-after-rename.json", udid: Self.udid)
        let stopped = try SimulatorFixtures.entry("simctl-list-j-devices.cloned.json", udid: Self.udid)

        let off = SimulatorDeviceMenuState(device: nil, capabilities: [], selected: stopped)
        XCTAssertTrue(off.showsItems)
        XCTAssertEqual(off.selectedUDID, Self.udid)
        XCTAssertFalse(off.isSelectedRunning)
        XCTAssertTrue(off.canStart)
        XCTAssertFalse(off.canShutDown)
        XCTAssertFalse(off.canRestart)
        XCTAssertTrue(off.canManage)
        XCTAssertFalse(off.canPressHome, "no mirrored Apple device")

        // Device Hub disables Home, Lock and Siri for a stopped simulator,
        // even while the mirror of a previous device still answers.
        let stale = SimulatorDeviceMenuState(
            device: .apple(Self.udid),
            capabilities: .simulator(liveCanvas: true, rotatesWithoutBridge: true),
            selected: stopped
        )
        XCTAssertFalse(stale.canPressHome)
        XCTAssertFalse(stale.canLock)
        XCTAssertFalse(stale.canRotate)

        let erasing = SimulatorDeviceMenuState(device: nil, capabilities: [], selected: stopped, operation: .erasing)
        XCTAssertFalse(erasing.canStart)
        XCTAssertFalse(erasing.canManage)

        let running = SimulatorDeviceMenuState(
            device: .apple(Self.udid),
            capabilities: .simulator(liveCanvas: true, rotatesWithoutBridge: true),
            selected: booted
        )
        XCTAssertTrue(running.isSelectedRunning)
        XCTAssertFalse(running.canStart)
        XCTAssertTrue(running.canShutDown)
        XCTAssertTrue(running.canRestart)
        XCTAssertTrue(running.canPressHome)

        let waiting = SimulatorDeviceMenuState(device: nil, capabilities: [], selected: booted, operation: .starting)
        XCTAssertTrue(waiting.canShutDown, "a boot waiting to be ready may be interrupted")
        let stopping = SimulatorDeviceMenuState(device: nil, capabilities: [], selected: booted, operation: .stopping)
        XCTAssertFalse(stopping.canShutDown)
        XCTAssertFalse(stopping.canRestart)
    }

    /// Device Hub's URL on Xcode 27 (or an unknown one), none before it.
    func testTheHandoff() async throws {
        XCTAssertEqual(
            SimulatorCanvasController.handoffURL(udid: Self.udid, xcodeVersion: "27.0")?.absoluteString,
            "devices://device/open?id=\(Self.udid)"
        )
        XCTAssertNotNil(SimulatorCanvasController.handoffURL(udid: Self.udid, xcodeVersion: nil))
        XCTAssertNil(SimulatorCanvasController.handoffURL(udid: Self.udid, xcodeVersion: "26.4"))

        let (model, _, _) = try await readyModel()
        var opened: [URL] = []
        model.simulatorCanvas.openURL = { opened.append($0) }
        XCTAssertEqual(model.simulatorCanvas.handoffTitle, "Open in Device Hub")
        model.simulatorCanvas.openInAppleApp(Self.udid)
        model.simulatorCanvas.openInAppleApp("not-a-udid")
        XCTAssertEqual(opened.map(\.absoluteString), ["devices://device/open?id=\(Self.udid)"])
    }

    // MARK: - No adb

    /// The whole simulator path reaches no adb: the attach, the stats poll,
    /// the Controls poll and the device actions an Android device runs
    /// through adb, the rotation, Home, Lock, shake and the teardown.
    func testASimulatorSessionRunsNoAdb() async throws {
        let adb = try makeStubAdb(arms: "")
        let (model, made, _) = try await readyModel(adb: adb.client)
        model.simulatorCanvas.attach(Self.udid)
        let session = try XCTUnwrap(made.fakes.first)
        session.putFrame()
        await waitUntil(timeout: 3, "T3") { model.simulators.tooling.tier == .t3 }

        await model.workspace.controlsPanel.refreshControls()
        await model.workspace.capture.takeScreenshot()
        await model.workspace.mirror.power()
        await model.workspace.mirror.goHome()
        await model.workspace.mirror.goBack()
        await model.workspace.rotateDevice(.left)
        model.simulatorCanvas.home()
        model.simulatorCanvas.lock()
        await model.simulatorCanvas.shake()
        try await Task.sleep(for: .milliseconds(600))
        model.stopMirror()

        XCTAssertEqual(adb.calls, [], "no adb for a simulator")
    }

    /// A ready simulator's stage while its live view is not running: the
    /// status says so in the canvas's words and offers Show Live View,
    /// which starts the session through the simulator canvas; while the
    /// stage's attach is pending it says the live view is starting, with no
    /// button. An emulator's status keeps its words.
    func testTheAppleStatusOffersToShowTheLiveView() async throws {
        let (model, made, _) = try await readyModel()
        let apple = DeviceRef.apple(Self.udid)
        let emulator = DeviceRef.android("emulator-5554")

        XCTAssertEqual(ConnectingView.statusDescription(for: apple, isAttaching: false, failure: nil), "The live view is not running.")
        XCTAssertEqual(ConnectingView.statusDescription(for: apple, isAttaching: true, failure: nil), "Starting the live view…")
        XCTAssertTrue(ConnectingView.offersShowLiveView(for: apple, isAttaching: false))
        XCTAssertFalse(ConnectingView.offersShowLiveView(for: apple, isAttaching: true))
        XCTAssertEqual(
            ConnectingView.statusDescription(for: emulator, isAttaching: false, failure: nil),
            "Mirror is not running for this device."
        )
        XCTAssertEqual(ConnectingView.statusDescription(for: emulator, isAttaching: true, failure: nil, name: "Pixel 9"), "Connecting to Pixel 9…")
        // The title follows the line: "Connecting" only while an attach runs.
        XCTAssertEqual(ConnectingView.statusTitle(for: emulator, isAttaching: false, failure: nil), "Mirror Stopped")
        XCTAssertEqual(ConnectingView.statusTitle(for: emulator, isAttaching: true, failure: nil), "Connecting")
        XCTAssertEqual(ConnectingView.statusTitle(for: emulator, isAttaching: false, failure: "x"), "Couldn't Connect")
        XCTAssertEqual(ConnectingView.statusTitle(for: apple, isAttaching: false, failure: nil), "Live View Off")
        XCTAssertEqual(
            ConnectingView.statusDescription(for: emulator, isAttaching: false, failure: "offline", name: "Pixel 9"),
            "Could not connect to Pixel 9.\noffline"
        )
        XCTAssertFalse(ConnectingView.offersShowLiveView(for: emulator, isAttaching: false))

        XCTAssertEqual(made.sessions.count, 0)
        ConnectingView.showLiveView(apple, workspace: model.workspace)
        XCTAssertEqual(made.sessions.count, 1)
        XCTAssertEqual(model.context.device, apple)
        ConnectingView.showLiveView(apple, workspace: model.workspace)
        XCTAssertEqual(made.sessions.count, 1, "nothing new for a simulator mirrored already")
    }

    /// The pill's Capture segment and the Device menu's screenshot items act
    /// on the mirrored device: off with nothing mirrored, on with a
    /// simulator mirrored (its canvas's frame, else simctl) and with an
    /// emulator.
    func testCaptureIsOnForASimulatorAndForAnEmulator() async throws {
        let (model, _, _) = try await readyModel()
        XCTAssertFalse(model.workspace.capture.canTakeScreenshot, "nothing mirrored")

        model.simulatorCanvas.attach(Self.udid)
        XCTAssertEqual(model.context.device, .apple(Self.udid))
        XCTAssertTrue(model.workspace.capture.canTakeScreenshot)

        model.beginMirrorSession(
            FakeMirrorSession(),
            device: .android("emulator-5554"),
            port: nil,
            capabilities: .android(emulatorGrpc: false)
        )
        XCTAssertTrue(model.workspace.capture.canTakeScreenshot)
    }

    /// Only a simulator's stage takes links: an Android mirror's drop target
    /// stays files only, as it was before simulators took drops (a web link
    /// over it was accepted, then refused).
    func testOnlyASimulatorsStageTakesLinks() {
        XCTAssertEqual(StageDropTypes.accepted(by: .apple), [.fileURL, .url])
        XCTAssertEqual(StageDropTypes.accepted(by: .android), [.fileURL])
        XCTAssertEqual(StageDropTypes.accepted(by: nil), [.fileURL])
    }
}

/// Two stages over one `SimulatorCanvasMemory`: a live
/// canvas that failed in one window is not tried again in another before
/// the simulator shuts down, and a listing seen by either forgets it.
@MainActor
final class SimulatorCanvasMemorySharingTests: XCTestCase {
    private static let udid = "425BD068-3D87-4F27-BE58-EB56A58B2C3A"

    func testTwoCanvasesOverOneMemoryAgree() {
        let preferences = AppPreferences(defaults: .scratch())
        let inventory = SimulatorInventory(apple: nil, preferences: preferences)
        let memory = SimulatorCanvasMemory()
        func canvas() -> SimulatorCanvasController {
            let status = StatusCenter()
            let mirror = MirrorController(adbClient: nil, context: ActiveDeviceContext(), status: status, perfLog: nil)
            return SimulatorCanvasController(simulators: inventory, mirror: mirror, memory: memory, status: status)
        }
        let first = canvas()
        let second = canvas()

        memory.liveCanvasFailures[Self.udid] = "The live view stopped: no picture"
        memory.dtuhiddWasActive[Self.udid] = true
        XCTAssertEqual(second.liveCanvasFailures[Self.udid], "The live view stopped: no picture")
        XCTAssertEqual(second.dtuhiddWasActive[Self.udid], true)

        // Try Live View in one window clears the failure for both.
        first.retryLiveCanvas(Self.udid)
        XCTAssertNil(second.liveCanvasFailures[Self.udid])

        // A listing without the simulator booted forgets its flag for both.
        second.noteListing([])
        XCTAssertNil(first.dtuhiddWasActive[Self.udid])
    }

    func testTheModelsCanvasUsesTheAppMemory() {
        let model = AppModel.testing()
        XCTAssertTrue(model.simulatorCanvas.memory === model.simulatorCanvasMemory)
    }
}
