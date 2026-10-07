import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// An emulator whose host screenshot path wedged answers nothing over gRPC
/// while adb stays healthy. Nothing on the attach path may wait for it for
/// good, and a mirror that never gets a first frame says so.
@MainActor
final class StuckEmulatorTests: XCTestCase {
    private static let serial = "emulator-5554"

    // MARK: Bounded attach

    /// A port resolution that never answers ends the attach with a reason
    /// within the timeout, and the reason is parked on the stage.
    func testAHangingPortResolutionFailsTheAttach() async throws {
        let adb = try makeStubAdb(arms: "")
        let model = AppModel.testing(adb: adb.client)
        model.workspace.mirror.attachTimeout = .milliseconds(150)
        model.grpcPorts.consoleAvdName = { _ in
            // Never answers: the console read is stuck behind the wedged VM.
            try? await Task.sleep(for: .seconds(120))
            return nil
        }
        let started = ContinuousClock.now

        let outcome = await model.mirror(device: .online(Self.serial, transport: "3"))

        guard case .failed(let message) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(message.contains("didn't answer in time"), message)
        XCTAssertEqual(model.workspace.mirror.mirrorAttach?.serial, Self.serial)
        XCTAssertNotNil(model.workspace.mirror.mirrorAttach?.failure)
        XCTAssertEqual(model.workspace.status.errorMessage, message)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        XCTAssertNil(model.workspace.mirror.session)
    }

    /// Attaching to a running AVD reads adb; when adb's device list never
    /// answers, Start still ends: busy is released and the failure shows.
    func testAHangingAttachReleasesBusy() async throws {
        let target = "Stuck_\(UUID().uuidString.prefix(6))"
        let emulator = try makeStubEmulator(avds: [target])
        let port = try makeOwnedGrpcPort()
        let adb = try makeStubAdb(arms: """
          "devices -l")
            exec sleep 30 ;;
          "track-devices"*)
            exec sleep 30 ;;
        """)
        _ = try emulator.manager.launch(avd: target, grpcPort: port)
        await waitUntil("the VM never started") { !emulator.launches.isEmpty }
        let model = AppModel.testing(adb: adb.client, emulator: emulator.manager)
        addTeardownBlock { @MainActor in model.inventory.stopDeviceLifecycle() }
        model.workspace.mirror.attachTimeout = .milliseconds(200)

        await model.startAndMirror(avd: target)

        XCTAssertFalse(model.isBusy, "busy is balanced even though the attach never got an answer")
        XCTAssertEqual(
            model.workspace.status.errorMessage,
            MirrorController.attachTimedOutMessage(target)
        )
    }

    // MARK: First-frame watchdog

    private func startedModel(online: Bool = true) -> (AppModel, FakeMirrorSession) {
        let model = AppModel.testing()
        let session = FakeMirrorSession()
        model.workspace.mirror.sessionFactoryOverride = { _, _ in session }
        model.workspace.mirror.firstFrameTimeout = .milliseconds(120)
        model.workspace.mirror.statsPollInterval = .milliseconds(20)
        model.workspace.mirror.isDeviceOnline = { _ in online }
        model.workspace.startSession(serial: Self.serial, port: 8554)
        addTeardownBlock { @MainActor in model.stopMirror() }
        return (model, session)
    }

    /// No frame within the window: the stage's stuck-screen state shows; the
    /// first frame clears it.
    func testNoFirstFrameShowsTheStuckStateAndAFrameClearsIt() async {
        let (model, session) = startedModel()
        XCTAssertFalse(model.workspace.mirror.emulatorScreenStalled)

        await waitUntil("the watchdog never fired") { model.workspace.mirror.emulatorScreenStalled }

        session.reportedFrames = 3
        await waitUntil("a frame did not clear it") { !model.workspace.mirror.emulatorScreenStalled }
    }

    /// A frame inside the window never raises it.
    func testAFrameInTimeKeepsTheStageClear() async throws {
        let (model, session) = startedModel()
        session.reportedFrames = 1

        try await Task.sleep(for: .milliseconds(400))

        XCTAssertFalse(model.workspace.mirror.emulatorScreenStalled)
    }

    /// A device adb does not list online is not "stuck": the lifecycle's
    /// own waiting panel covers it.
    func testAnOfflineDeviceIsNotReportedAsStuck() async throws {
        let (model, _) = startedModel(online: false)

        try await Task.sleep(for: .milliseconds(400))

        XCTAssertFalse(model.workspace.mirror.emulatorScreenStalled)
    }

    /// The stage's strings.
    func testTheStuckPanelCopy() {
        XCTAssertEqual(EmulatorScreenStalledPanel.title, "The emulator isn't sending its screen")
        XCTAssertEqual(
            EmulatorScreenStalledPanel.detail,
            "Its display stream stopped responding. Restarting the emulator fixes it."
        )
    }
}
