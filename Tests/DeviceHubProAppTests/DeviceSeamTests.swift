import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The platform-neutral device seam (iOS): what the session hub
/// records about the mirrored device, and the hazards an Apple device met
/// before it (§4 R1–R2): the adb pollers firing with its UDID, and the
/// Android lifecycle reading it missing from adb as a disconnect.
///
/// No transport and no device: the sessions are fakes the model's session
/// factory hands out or the test begins itself (a `FakeMirrorSession`
/// stands in for a simulator's), adb is a stub that logs every call and
/// answers nothing, and the emulator's port is one nothing can serve.
@MainActor
final class DeviceSeamTests: XCTestCase {
    private let emulator = AndroidDevice.online("emulator-5554", transport: "3")
    private let phone = AndroidDevice.online("HT4CWJT01234", transport: "7", model: "Pixel 8")
    /// Apple simulators by UDIDs no simulator has.
    private let simulator = DeviceRef.apple("00000000-0000-4000-8000-00000000A001")
    private let otherSimulator = DeviceRef.apple("00000000-0000-4000-8000-00000000A002")

    // MARK: - Android sessions

    /// An emulator's session names an Android device with the gRPC bucket;
    /// the adb serial and the port are derived from it as before.
    func testAnEmulatorSessionNamesAnAndroidDeviceWithTheGrpcBucket() async throws {
        let adb = try makeStubAdb(arms: "")
        let model = AppModel.testing(adb: adb.client)
        model.workspace.mirror.sessionFactoryOverride = { _, _ in FakeMirrorSession() }
        model.inventory.applyWatcherSnapshot([emulator], degraded: false)
        model.grpcPorts.store(EmulatorManager.unreachableGrpcPort, for: emulator.serial)

        let outcome = await model.mirror(device: emulator)

        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(model.context.device, .android(emulator.serial))
        XCTAssertEqual(model.context.capabilities, .android(emulatorGrpc: true))
        XCTAssertEqual(model.activeDeviceSerial, emulator.serial)
        XCTAssertEqual(model.workspace.context.port, EmulatorManager.unreachableGrpcPort)

        model.stopMirror()
        XCTAssertNil(model.context.device)
        XCTAssertEqual(model.context.capabilities, [])
    }

    /// A phone's scrcpy session names an Android device without the gRPC
    /// bucket or a port.
    func testAPhoneSessionNamesAnAndroidDeviceWithoutTheGrpcBucket() async throws {
        let adb = try makeStubAdb(arms: "")
        let model = AppModel.testing(adb: adb.client)
        model.workspace.mirror.sessionFactoryOverride = { serial, _ in FakePhysicalSession(serial: serial) }
        model.inventory.applyWatcherSnapshot([phone], degraded: false)

        let outcome = await model.mirror(device: phone)

        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(model.context.device, .android(phone.serial))
        XCTAssertEqual(model.context.capabilities, .android(emulatorGrpc: false))
        XCTAssertEqual(model.activeDeviceSerial, phone.serial)
        XCTAssertNil(model.workspace.context.port)
        model.stopMirror()
    }

    // MARK: - Apple sessions (R1, R2)

    /// One Controls poll cycle as `ControlsView` runs it, the screenshot,
    /// every key and device action of the Device menu and the pill, the
    /// rotation, and the mirror's display metrics and shapes: each goes
    /// through adb (or the emulator console) for an Android device.
    private func runThePollersAndActions(_ model: AppModel) async throws {
        await model.workspace.controlsPanel.refreshControls()
        await model.workspace.hardware.refreshResizePresets()
        await model.conditions.refresh()
        await model.conditions.statusBar.refresh()
        await model.workspace.capture.takeScreenshot()
        await model.workspace.capture.copyScreenshotToClipboard()
        await model.workspace.mirror.power()
        await model.workspace.mirror.showPowerMenu()
        await model.workspace.mirror.volumeUp()
        await model.workspace.mirror.volumeDown()
        await model.workspace.mirror.muteAudio()
        await model.workspace.mirror.goBack()
        await model.workspace.mirror.goHome()
        await model.workspace.mirror.openRecents()
        await model.workspace.mirror.splitScreen()
        await model.workspace.mirror.openAssistant()
        await model.workspace.mirror.switchToPreviousApp()
        await model.workspace.mirror.restartAndroid()
        await model.workspace.mirror.shutdownAndroid()
        await model.workspace.mirror.releaseRotationLock()
        await model.workspace.rotateDevice(.left)
        await model.workspace.mirror.loadMirrorDisplayMetrics(for: model.workspace.mirror.mirrorViewState)
        await model.mirror.loadDisplayShapes(for: model.workspace.mirror.mirrorViewState)
        // The stats poll's interval is 500 ms: let it run twice.
        try await Task.sleep(for: .milliseconds(1100))
    }

    /// R2: with an Apple device mirrored, the pollers and the Android key
    /// paths send nothing to adb: its serial is nil, so each one's `guard`
    /// stops it. The same run with an Android device reaches adb.
    func testAnAppleDeviceGetsNoAdbCallFromThePollersOrTheKeys() async throws {
        let adb = try makeStubAdb(arms: "")
        let model = AppModel.testing(adb: adb.client)
        let session = FakeMirrorSession()
        model.beginMirrorSession(session, device: simulator, port: nil, capabilities: [.mirror, .touch, .keyboard])
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(model.context.device, simulator)
        XCTAssertNil(model.activeDeviceSerial, "an Apple device has no adb serial")

        try await runThePollersAndActions(model)
        model.stopMirror()

        XCTAssertEqual(adb.calls, [], "no adb call for an Apple device")
        XCTAssertNil(model.status.errorMessage)

        // The same run on an Android phone does reach adb: the stub logs.
        model.beginMirrorSession(
            FakeMirrorSession(),
            device: .android(phone.serial),
            port: nil,
            capabilities: .android(emulatorGrpc: false)
        )
        try await runThePollersAndActions(model)
        model.stopMirror()
        for call in ["input keyevent 3", "wm size", "screencap", "settings get system accelerometer_rotation"] {
            XCTAssertFalse(adb.calls(containing: call).isEmpty, "\(call) never reached adb: \(adb.calls)")
        }
    }

    /// R1: an Apple device is not the lifecycle's to decide. It is never in
    /// an adb snapshot, and a mirror the lifecycle knew of would be torn
    /// down on the next one and left behind as a ghost `AndroidDevice`
    /// carrying the UDID, with the reconnect panel.
    func testAnAppleSessionStaysOutOfTheAndroidLifecycle() async {
        let model = AppModel.testing(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        addTeardownBlock { @MainActor in model.inventory.stopDeviceLifecycle() }
        model.inventory.startDeviceLifecycle()
        let session = FakeMirrorSession()
        model.beginMirrorSession(session, device: simulator, port: nil, capabilities: [.mirror])

        model.workspace.lifecycleIfRunning?.handle(.snapshot(devices: [], degraded: false))

        XCTAssertTrue(model.workspace.mirror.session === session, "the session keeps running")
        XCTAssertEqual(session.stopCount, 0)
        XCTAssertEqual(model.context.device, simulator)
        XCTAssertNil(model.inventory.ghostSerial(for: model.workspace.id))
        XCTAssertNil(model.workspace.reconnect)
        XCTAssertFalse(model.inventory.devices.contains { $0.serial == simulator.id }, "no ghost row for the UDID")

        model.stopMirror()
        model.workspace.lifecycleIfRunning?.handle(.snapshot(devices: [], degraded: false))
        XCTAssertEqual(session.stopCount, 1)
        XCTAssertNil(model.inventory.ghostSerial(for: model.workspace.id))
        XCTAssertTrue(model.inventory.devices.isEmpty)
    }

    /// R1 from a running Android session: an Apple session that replaces a
    /// phone's ends the phone's lifecycle episode, as an Android start does.
    /// Otherwise the phone's later unplug would tear the Apple session down
    /// (its recording ending as interrupted), leave the phone's ghost row and
    /// reconnect panel, and its replug would resume the phone over the
    /// stage, even after the user stopped the Apple session.
    func testAnAppleSessionEndsTheEpisodeOfTheAndroidSessionItReplaces() async {
        let model = AppModel.testing(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        addTeardownBlock { @MainActor in model.inventory.stopDeviceLifecycle() }
        // A resume, were one to run, gets a fake session, not scrcpy.
        model.workspace.mirror.sessionFactoryOverride = { serial, _ in FakePhysicalSession(serial: serial) }
        model.inventory.startDeviceLifecycle()
        model.workspace.lifecycleIfRunning?.handle(.snapshot(devices: [phone], degraded: false))
        XCTAssertEqual(model.deviceSelection, .device(phone.serial), "a resume of the phone would pass its intent check")
        let phoneSession = FakeMirrorSession()
        model.beginMirrorSession(
            phoneSession,
            device: .android(phone.serial),
            port: nil,
            capabilities: .android(emulatorGrpc: false)
        )
        let session = FakeMirrorSession()
        model.beginMirrorSession(session, device: simulator, port: nil, capabilities: [.mirror])
        XCTAssertEqual(phoneSession.stopCount, 1)

        // The phone is unplugged, then plugged back in.
        model.workspace.lifecycleIfRunning?.handle(.snapshot(devices: [], degraded: false))
        XCTAssertTrue(model.workspace.mirror.session === session, "the Apple session keeps running")
        XCTAssertEqual(session.stopCount, 0)
        XCTAssertNil(model.inventory.ghostSerial(for: model.workspace.id))
        XCTAssertNil(model.workspace.reconnect)
        XCTAssertFalse(model.inventory.devices.contains { $0.serial == phone.serial }, "no ghost row for the phone")
        model.workspace.lifecycleIfRunning?.handle(.snapshot(devices: [phone], degraded: false))
        // The default policy would run attempt 1 after 500 ms. Best effort:
        // sleep only fails on cancellation; the assertion still follows.
        try? await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(model.workspace.mirror.session === session, "nothing resumes the phone over the Apple session")
        XCTAssertEqual(model.context.device, simulator)

        // With the Apple session stopped, the phone coming and going is just
        // a device coming and going.
        model.stopMirror()
        model.workspace.lifecycleIfRunning?.handle(.snapshot(devices: [], degraded: false))
        model.workspace.lifecycleIfRunning?.handle(.snapshot(devices: [phone], degraded: false))
        XCTAssertEqual(session.stopCount, 1)
        XCTAssertNil(model.inventory.ghostSerial(for: model.workspace.id))
        XCTAssertNil(model.workspace.reconnect)
        XCTAssertNil(model.workspace.mirror.session, "the stopped phone is not resumed")
    }

    /// The rest of the Android half stays off an Apple session too: the gRPC
    /// port cache (an entry under the device's id survives), the port and
    /// the AVD (a port passed along is not recorded, so the teardown has no
    /// connection to close), and the Controls conditions' attach and detach.
    /// Without an adb serial their only effect is clearing the conditions'
    /// per-device state, so a value planted there tells whether either ran.
    func testAnAppleSessionLeavesTheGrpcCacheThePortAndTheConditionsAlone() async throws {
        let adb = try makeStubAdb(arms: "")
        let model = AppModel.testing(adb: adb.client)
        let port = EmulatorManager.unreachableGrpcPort
        model.grpcPorts.store(port, for: simulator.id)
        let first = FakeMirrorSession()
        model.beginMirrorSession(first, device: simulator, port: port, avdName: "Pixel_9", capabilities: [.mirror])
        XCTAssertNil(model.workspace.context.port, "an Apple device has no gRPC port")
        XCTAssertNil(model.activeAvdName)
        XCTAssertEqual(model.context.capabilities, [.mirror])
        model.conditions.trimOutcome = "planted"

        // Replaces the first session: its teardown, then the second's begin.
        let second = FakeMirrorSession()
        model.beginMirrorSession(second, device: otherSimulator, port: nil, capabilities: [.mirror])
        XCTAssertEqual(first.stopCount, 1)
        XCTAssertEqual(model.context.device, otherSimulator)
        model.stopMirror()

        XCTAssertEqual(second.stopCount, 1)
        XCTAssertEqual(model.conditions.trimOutcome, "planted", "the conditions were neither attached nor detached")
        XCTAssertEqual(model.grpcPorts.port(for: simulator.id), port, "the port cache was not touched")
        XCTAssertNil(model.context.device)
        XCTAssertEqual(model.context.capabilities, [])
        XCTAssertEqual(adb.calls, [])
    }

    /// The counterpart on an Android phone: the conditions attach and detach (the planted state is
    /// cleared), and the teardown drops the serial's cached port.
    func testAnAndroidSessionStillRunsTheAndroidHalf() async throws {
        let adb = try makeStubAdb(arms: "")
        let model = AppModel.testing(adb: adb.client)
        model.beginMirrorSession(
            FakeMirrorSession(),
            device: .android(phone.serial),
            port: nil,
            capabilities: .android(emulatorGrpc: false)
        )
        model.grpcPorts.store(EmulatorManager.unreachableGrpcPort, for: phone.serial)
        model.conditions.trimOutcome = "planted"

        model.stopMirror()

        XCTAssertNil(model.conditions.trimOutcome, "the conditions were detached")
        XCTAssertNil(model.grpcPorts.port(for: phone.serial), "the serial's cached port was dropped")
    }

    // MARK: - Refresh without adb (R3)

    /// R3: a Mac without adb refreshes without an alert, however often it
    /// refreshes; the toolbar's warning (`adbIsAvailable`) is what says adb
    /// is missing. The Android side shows what it showed before: no rows,
    /// no AVDs, and no smoke-test hook runs.
    func testRefreshWithoutAdbRaisesNoAlert() async {
        let model = AppModel.testing(launch: LaunchOptions(autoPair: true))

        await model.refresh()
        await model.refresh()

        XCTAssertNil(model.status.errorMessage)
        XCTAssertFalse(model.adbIsAvailable)
        XCTAssertNil(model.workspace.lifecycleIfRunning, "no watcher without adb")
        XCTAssertTrue(model.inventory.devices.isEmpty)
        XCTAssertTrue(model.catalog.avds.isEmpty)
        XCTAssertFalse(model.workspace.window.isPairSheetPresented)
    }

    /// With adb, a failed device listing still raises its alert as before.
    func testRefreshWithAFailingAdbStillRaisesItsAlert() async {
        let model = AppModel.testing(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        addTeardownBlock { @MainActor in model.inventory.stopDeviceLifecycle() }

        await model.refresh()

        XCTAssertNotNil(model.status.errorMessage)
    }
}
