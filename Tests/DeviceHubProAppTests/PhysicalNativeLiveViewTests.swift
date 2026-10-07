import CoreVideo
import XCTest
@testable import DeviceHubProKit
@testable import DeviceHubProApp

/// The opt-in native live view in the physical view controller: it stands in
/// for the CoreMediaIO capture without touching it (no Camera prompt), and any
/// failure falls back to the capture with one status message. Fake streams and
/// a fake capture provider: no device, no private framework.
@MainActor
final class PhysicalNativeLiveViewTests: XCTestCase {
    private final class FailingStream: NativeMirroring, @unchecked Sendable {
        let error: NativeMirrorError?
        init(error: NativeMirrorError?) { self.error = error }
        func start() async throws { if let error { throw error } }
        func stop() {}
    }

    private final class IdleLease: FastInputLease, @unchecked Sendable {
        func start() async throws {}
        func stop() async {}
        func terminateNow() {}
    }

    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: NativeMirrorError?
        init(_ value: NativeMirrorError?) { self.value = value }
        var error: NativeMirrorError? {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    private final class DelayLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Duration] = []
        func add(_ d: Duration) { lock.withLock { values.append(d) } }
        var all: [Duration] { lock.withLock { values } }
    }

    @MainActor
    private final class Harness {
        let box: ErrorBox
        let delays = DelayLog()
        let controller: PhysicalLiveViewController
        let provider: TestCaptureProvider
        var inputs = PhysicalLiveViewController.Inputs()
        var active: (any MirrorSessionProtocol)?
        var flashes: [String] = []
        var teardowns: [MirrorController.MirrorTeardownCause] = []
        var nativeMade = 0
        /// When set, the native session tracks the pose with it.
        var tracker: PhysicalInterfaceOrientationTracker?
        var poses: [(turns: Int, animated: Bool)] = []

        init(provider: TestCaptureProvider, streamError: NativeMirrorError?) {
            self.provider = provider
            box = ErrorBox(streamError)
            let box = box
            controller = PhysicalLiveViewController(provider: provider)
            controller.inputs = { [unowned self] in inputs }
            controller.activeSession = { [unowned self] in active }
            controller.beginSession = { [unowned self] session, _, _ in
                active?.stop()
                active = session
                session.start()
                return true
            }
            controller.tearDownSession = { [unowned self] cause in
                teardowns.append(cause)
                active?.stop()
                active = nil
            }
            let delays = delays
            controller.retrySleep = { delays.add($0) }
            controller.screenshotCapture = { _ in { _ in } }
            controller.flash = { [unowned self] message in flashes.append(message) }
            controller.settlePose = { [unowned self] turns, animated in poses.append((turns, animated)) }
            controller.makeNativeSession = { [unowned self] entry in
                nativeMade += 1
                let endpoint = NativeMirrorEndpoint(
                    coreDeviceIdentifier: PhysicalFixtures.coreDeviceIdentifier, interface: "utun4",
                    hostAddress: "fd00::2", deviceAddress: "fd00::1", productType: "iPhone13,2"
                )
                return PhysicalNativeMirrorSession(
                    hardwareUDID: entry.udid,
                    endpointProvider: { endpoint },
                    lease: IdleLease(),
                    makeStream: { _, _, _ in FailingStream(error: box.error) },
                    orientationTracker: tracker,
                    sleep: { _ in }
                )
            }
        }
    }

    private func harness(native: Bool, streamError: NativeMirrorError? = nil, deviceHasAudio: Bool = false,
                         audioAuthorization: CaptureAuthorization = .authorized) throws -> Harness {
        let entry = try PhysicalFixtures.entry(enabled: true)
        let provider = TestCaptureProvider(
            authorization: .notDetermined,
            devices: [PhysicalCaptureDevice(uniqueID: entry.device.hardwareUDID, localizedName: entry.name, modelID: "iOS Device", hasAudio: deviceHasAudio)],
            audioAuthorization: audioAuthorization
        )
        let harness = Harness(provider: provider, streamError: streamError)
        harness.inputs = PhysicalLiveViewController.Inputs(
            entry: entry, listed: [entry.device], isWindowVisible: true, showsPhysicalDevices: true,
            liveViewOn: true, nativeLiveViewOn: native, autoRefreshOn: true, screenshotSupported: true
        )
        addTeardownBlock { @MainActor in harness.active?.stop() }
        return harness
    }

    private final class PoseWorld: @unchecked Sendable {
        private let lock = NSLock()
        private var _device = PhysicalControlOrientation.portrait
        var device: PhysicalControlOrientation { get { lock.withLock { _device } } set { lock.withLock { _device = newValue } } }
    }

    /// Reproduced live 2026-10-01 (iPhone 12, home screen): Rotate from portrait reached
    /// landscape left, but upside down left the chrome and the picture upright. With the
    /// tracker, the control controller and the live view wired as in the app, the chrome
    /// settles on every pose of the walk (2 turns for upside down) and the native session's
    /// picture is turned with it, while the phone reports portrait in passing.
    func testRotatingThroughUpsideDownSettlesTheChromeAndTheNativePicture() async throws {
        let world = PoseWorld()
        let harness = try harness(native: true)
        harness.tracker = PhysicalInterfaceOrientationTracker(
            reads: .init(deviceOrientation: { world.device }, screenshotSize: { CGSize(width: 1170, height: 2532) }),
            // The poll loop idles (its interval is a second); the settle wait is skipped.
            sleep: { duration in if duration >= .seconds(1) { try await Task.sleep(for: duration) } }
        )
        harness.controller.reconcile()
        let session = try XCTUnwrap(harness.active as? PhysicalNativeMirrorSession)
        await expectEventually { session.stagePose == .portrait }

        let control = PhysicalControlController()
        control.inputs = { PhysicalControlController.Inputs(entry: harness.inputs.entry, team: nil) }
        control.viewSession = { _ in session }
        control.setDeviceOrientation = { _, _ in }
        harness.controller.knownChromeTurns = { control.knownChromeTurns }
        harness.poses.removeAll()

        let tracker = try XCTUnwrap(harness.tracker)
        // Rotate left, left, left, then back right, right, right.
        let walk: [(RotationDirection, PhysicalControlOrientation, Int)] = [
            (.left, .landscapeLeft, 1), (.left, .portraitUpsideDown, 2), (.left, .landscapeRight, 3),
            (.right, .portraitUpsideDown, 2), (.right, .landscapeLeft, 1), (.right, .portrait, 0),
        ]
        for (direction, pose, turns) in walk {
            await control.rotate(direction)?.value
            XCTAssertEqual(session.stagePose, pose)
            await expectEventually { harness.poses.last?.turns == turns }
            // The picture's frame shape follows the pose, as the real frames do.
            let landscape = turns % 2 == 1
            session.frames.put(Frame(data: Data(count: 4 * 4 * 4), width: landscape ? 4 : 2, height: landscape ? 2 : 4, seq: 1))
            await expectEventually { harness.poses.last?.turns == turns }
            // The phone says portrait in passing, then the pose.
            world.device = .portrait
            await tracker.poll()
            XCTAssertEqual(session.stagePose, pose, "a transient read does not undo \(pose.rawValue)")
            world.device = pose
            await tracker.poll()
            XCTAssertEqual(harness.poses.last?.turns, turns)
        }
        XCTAssertFalse(harness.poses.isEmpty)
    }

    func testTheNativeViewNeverTouchesCoreMediaIOAvFoundationOrTheCamera() throws {
        let harness = try harness(native: true)
        harness.controller.reconcile()
        XCTAssertTrue(harness.active is PhysicalNativeMirrorSession)
        XCTAssertEqual(harness.controller.plan.mode, .nativeLive)
        XCTAssertEqual(harness.provider.allowCalls, 0)
        XCTAssertEqual(harness.provider.deviceQueries, 0)
        XCTAssertEqual(harness.provider.requestCalls, 0, "no Camera prompt")
        XCTAssertTrue(harness.provider.makeCalls.isEmpty)
        XCTAssertTrue(harness.controller.showsSession(for: PhysicalFixtures.udid))
        harness.controller.reconcile()
        XCTAssertEqual(harness.nativeMade, 1, "one session per device")
    }

    func testWithTheOptionOffTheCaptureIsUsedAsBefore() throws {
        let harness = try harness(native: false)
        harness.controller.reconcile()
        XCTAssertFalse(harness.active is PhysicalNativeMirrorSession)
        XCTAssertEqual(harness.nativeMade, 0)
        XCTAssertEqual(harness.provider.allowCalls, 1)
    }

    func testAFailedStartFallsBackToTheCaptureWithOneMessage() async throws {
        let failure = NativeMirrorError(code: 3000, message: "CoreDevice gave no media service")
        let harness = try harness(native: true, streamError: failure)
        harness.controller.reconcile()
        let native = try XCTUnwrap(harness.active as? PhysicalNativeMirrorSession)
        await expectEventually { !native.isRunning }
        XCTAssertEqual(native.lastError, failure.message)

        harness.controller.sessionStopped(native)
        XCTAssertEqual(harness.flashes.count, 1)
        XCTAssertEqual(harness.teardowns, [.transportFatal])
        XCTAssertFalse(harness.active is PhysicalNativeMirrorSession, "the preview took over")
        XCTAssertEqual(harness.controller.plan.mode, .screenshots)
        XCTAssertEqual(harness.provider.allowCalls, 0, "the Camera is not authorized: no capture path")
        XCTAssertEqual(harness.provider.requestCalls, 0, "never a Camera prompt")
        XCTAssertEqual(harness.nativeMade, 1)
    }

    func testARetryIsNotStartedByAPlainReconcile() async throws {
        let failure = NativeMirrorError(code: 3000, message: "no media service")
        let harness = try harness(native: true, streamError: failure)
        harness.controller.retrySleep = { _ in try await Task.sleep(for: .seconds(60)) }
        harness.controller.reconcile()
        let native = try XCTUnwrap(harness.active as? PhysicalNativeMirrorSession)
        await expectEventually { !native.isRunning }
        harness.controller.sessionStopped(native)
        harness.controller.reconcile()
        XCTAssertEqual(harness.nativeMade, 1)
        // Toggling the option gives it another go at once.
        harness.inputs.nativeLiveViewOn = false
        harness.controller.reconcile()
        harness.inputs.nativeLiveViewOn = true
        harness.controller.reconcile()
        XCTAssertEqual(harness.nativeMade, 2)
    }

    func testAStallWithTheCameraAuthorizedMayUseTheCapture() async throws {
        let failure = NativeMirrorError(code: 3000, message: "no frames")
        let harness = try harness(native: true, streamError: failure)
        harness.provider.setAuthorization(.authorized)
        harness.controller.retrySleep = { _ in try await Task.sleep(for: .seconds(60)) }
        harness.controller.reconcile()
        let native = try XCTUnwrap(harness.active as? PhysicalNativeMirrorSession)
        await expectEventually { !native.isRunning }
        harness.controller.sessionStopped(native)
        XCTAssertEqual(harness.provider.allowCalls, 1)
        XCTAssertEqual(harness.provider.requestCalls, 0)
        XCTAssertTrue(harness.flashes.first?.contains("standard live view") == true)
    }

    /// Seen 2026-09-30: with the Camera granted, a stalled native view fell
    /// back to the capture, which asked for the Microphone for the phone's
    /// audio. With the native view preferred it never asks.
    func testAStandInCaptureNeverAsksForTheMicrophone() async throws {
        let failure = NativeMirrorError(code: 7000, message: "no frames")
        let harness = try harness(native: true, streamError: failure, deviceHasAudio: true, audioAuthorization: .notDetermined)
        harness.provider.setAuthorization(.authorized)
        harness.controller.retrySleep = { _ in try await Task.sleep(for: .seconds(60)) }
        harness.controller.reconcile()
        let native = try XCTUnwrap(harness.active as? PhysicalNativeMirrorSession)
        await expectEventually { !native.isRunning }
        harness.controller.sessionStopped(native)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(harness.provider.allowCalls, 1, "the capture stands in")
        XCTAssertEqual(harness.provider.audioRequestCalls, 0, "no Microphone prompt")
        XCTAssertEqual(harness.provider.requestCalls, 0, "no Camera prompt")
    }

    func testRetriesFollowTheBackoffWithOneMessageAndASuccessReturnsToNative() async throws {
        let failure = NativeMirrorError(code: 3000, message: "no media service")
        let harness = try harness(native: true, streamError: failure)
        harness.controller.reconcile()
        for round in 1...5 {
            let native = try XCTUnwrap(harness.active as? PhysicalNativeMirrorSession)
            await expectEventually { !native.isRunning }
            harness.controller.sessionStopped(native)
            await expectEventually { harness.nativeMade == round + 1 }
        }
        XCTAssertEqual(harness.delays.all, [.seconds(3), .seconds(6), .seconds(12), .seconds(30), .seconds(30)])
        XCTAssertEqual(harness.flashes.count, 1, "one message, not one per retry")
        XCTAssertEqual(harness.provider.requestCalls, 0)
        XCTAssertEqual(harness.provider.allowCalls, 0)

        harness.box.error = nil
        let last = try XCTUnwrap(harness.active as? PhysicalNativeMirrorSession)
        await expectEventually { !last.isRunning }
        harness.controller.sessionStopped(last)
        await expectEventually { harness.active is PhysicalNativeMirrorSession && harness.controller.plan.mode == .nativeLive }
        XCTAssertTrue(harness.active?.isRunning == true)
    }

    func testTurningTheOptionOffCancelsTheRetryAndRestoresTheCapture() async throws {
        let failure = NativeMirrorError(code: 3000, message: "no media service")
        let harness = try harness(native: true, streamError: failure)
        harness.controller.retrySleep = { _ in try await Task.sleep(for: .seconds(60)) }
        harness.controller.reconcile()
        let native = try XCTUnwrap(harness.active as? PhysicalNativeMirrorSession)
        await expectEventually { !native.isRunning }
        harness.controller.sessionStopped(native)
        harness.inputs.nativeLiveViewOn = false
        harness.controller.reconcile()
        XCTAssertEqual(harness.provider.allowCalls, 1, "today's capture path")
        XCTAssertEqual(harness.nativeMade, 1)
    }

    func testAWiFiPhoneOrABuildWithoutTheHookStaysOnTheCapture() throws {
        let harness = try harness(native: true)
        harness.controller.makeNativeSession = nil
        harness.controller.reconcile()
        XCTAssertFalse(harness.active is PhysicalNativeMirrorSession)
        XCTAssertEqual(harness.provider.allowCalls, 1)
    }

    func testThePlanPrefersTheNativeViewOverTheCameraGate() throws {
        let entry = try PhysicalFixtures.entry(enabled: true)
        let plan = PhysicalViewPlan.make(
            entry: entry, showsPhysicalDevices: true, liveViewOn: true, autoRefreshOn: true, screenshotSupported: true,
            authorization: .denied, captureDevice: nil, liveFailure: nil, nativeLive: true
        )
        XCTAssertEqual(plan.mode, .nativeLive)
        XCTAssertNil(plan.noteText)
        XCTAssertFalse(plan.offersCameraSettings)
        XCTAssertTrue(plan.mode.isLive)
    }
}
