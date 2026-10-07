import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The emulator hardware on its own: the battery debounce and the charger,
/// the fold posture animation, the hinge sender, the console fallback
/// without gRPC, the resize presets and what `detach()` cancels and
/// forgets; then the model's old names over the one controller.
///
/// Each controller gets its own `ActiveDeviceContext`, Controls panel and
/// `StatusCenter`, wired the way `AppModel` wires them. No test sets a port
/// an emulator serves: nothing can listen on `silentPort`, so every gRPC
/// write fails and every read answers nothing. The console goes
/// through a stub adb.
@MainActor
final class EmulatorHardwareControllerTests: XCTestCase {
    private static let serial = "emulator-5580"
    /// Nothing can listen here (port 0; a user may bind port 1 on macOS).
    private static let silentPort = EmulatorManager.unreachableGrpcPort

    private struct Rig {
        let hardware: EmulatorHardwareController
        let panel: DeviceControlsController
        let context: ActiveDeviceContext
        let status: StatusCenter
        let repaints: RepaintLog
    }

    /// A controller on `adb` whose context mirrors `serial` (no port unless
    /// given), over its own Controls panel. The panel's poll holds the
    /// posture and hinge while the controller's fold workers run, and the
    /// repaint hook counts, as the model wires them.
    private func makeRig(
        adb: AdbClient? = nil,
        serial: String? = EmulatorHardwareControllerTests.serial,
        port: Int? = nil,
        avdHome: URL? = nil
    ) -> Rig {
        let context = ActiveDeviceContext(avdHome: avdHome)
        context.serial = serial
        context.port = port
        let status = StatusCenter()
        let panel = DeviceControlsController(adbClient: adb, context: context, status: status)
        let hardware = EmulatorHardwareController(
            adbClient: adb,
            context: context,
            controlsPanel: panel,
            status: status
        )
        panel.isPostureBusy = { [weak hardware] in
            guard let hardware else { return false }
            return hardware.postureAnimationTask != nil || hardware.hingeSendTask != nil
        }
        let repaints = RepaintLog()
        hardware.resync = { repaints.count += 1 }
        if let port {
            addTeardownBlock { await EmulatorControls.closeConnections(port: port) }
        }
        return Rig(hardware: hardware, panel: panel, context: context, status: status, repaints: repaints)
    }

    private static let battery = BatteryInfo(level: 80, isCharging: false, chargerName: "None", statusName: "Discharging")

    // MARK: Battery

    /// A slider drag moves the level at once but writes it only after the
    /// 200 ms debounce, and only its last value: each drag cancels the
    /// write the previous one scheduled, which then writes nothing.
    func testBatteryDragsCoalesceIntoOneWriteAfterTheDebounce() async throws {
        let rig = makeRig(port: Self.silentPort)
        rig.panel.controls.battery = Self.battery

        rig.hardware.setBatteryLevel(60)
        let first = try XCTUnwrap(rig.hardware.batteryApplyTask)
        rig.hardware.setBatteryLevel(40)
        let second = try XCTUnwrap(rig.hardware.batteryApplyTask)
        let lastDrag = ContinuousClock.now
        rig.hardware.setBatteryLevel(20)
        let last = try XCTUnwrap(rig.hardware.batteryApplyTask)

        XCTAssertEqual(rig.panel.controls.battery?.level, 20, "the row follows the drag at once")
        XCTAssertTrue(first.isCancelled)
        XCTAssertTrue(second.isCancelled)
        XCTAssertFalse(last.isCancelled)

        await first.value
        await second.value
        XCTAssertNil(rig.status.statusMessage, "a superseded drag writes nothing")

        await last.value
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - lastDrag, .milliseconds(200), "the write waits for the debounce")
        // Nothing listens on the port, so the one write is refused.
        XCTAssertEqual(rig.status.statusMessage, "The emulator rejected the battery level")
        XCTAssertEqual(rig.panel.controls.battery?.level, 20)
    }

    /// Without a port (a physical device) the level only moves the row:
    /// no write is scheduled, and the charger is left alone.
    func testWithoutAPortNothingIsScheduled() async {
        let rig = makeRig()
        rig.panel.controls.battery = Self.battery

        rig.hardware.setBatteryLevel(30)
        await rig.hardware.toggleCharging()

        XCTAssertEqual(rig.panel.controls.battery?.level, 30)
        XCTAssertNil(rig.hardware.batteryApplyTask)
        XCTAssertEqual(rig.panel.controls.battery?.isCharging, false)
        XCTAssertNil(rig.status.statusMessage)
    }

    /// A charger change the emulator refuses puts the row back.
    func testARefusedChargerChangeRollsBack() async {
        let rig = makeRig(port: Self.silentPort)
        rig.panel.controls.battery = Self.battery

        await rig.hardware.toggleCharging()

        XCTAssertEqual(rig.panel.controls.battery, Self.battery)
    }

    // MARK: Fold

    /// Opening from fully closed sets the posture first (the emulator only
    /// powers the inner display once it changes) and the angle only after
    /// it settled: the emulator's reported angle, or the posture's own when
    /// it reports none. That path ends without a repaint.
    func testOpeningFromClosedSetsThePostureBeforeTheAngle() async throws {
        let rig = makeRig(port: Self.silentPort)
        rig.panel.controls.posture = .closed
        rig.panel.controls.hingeAngle = 0

        rig.hardware.setPostureAnimated(.opened)
        let animation = try XCTUnwrap(rig.hardware.postureAnimationTask)
        XCTAssertTrue(rig.panel.isPostureBusy(), "the animation owns the posture")

        await waitUntil("the animation never set the posture") { rig.panel.controls.posture == .opened }
        XCTAssertEqual(rig.panel.controls.hingeAngle, 0, "the angle waits for the posture to settle")

        await animation.value
        XCTAssertEqual(rig.panel.controls.posture, .opened)
        XCTAssertEqual(rig.panel.controls.hingeAngle, PostureKind.opened.hingeAngle)
        XCTAssertNil(rig.hardware.postureAnimationTask)
        XCTAssertFalse(rig.panel.isPostureBusy())
        XCTAssertEqual(rig.repaints.count, 0)
    }

    /// Without a port the fold toggle goes through the console's `posture`
    /// command, shows the posture it asked for, and then refreshes the
    /// panel, whose poll leaves the posture to the animation.
    func testWithoutAPortTheFoldGoesThroughTheConsoleThenRefreshes() async throws {
        let adb = try makeStubAdb(arms: """
          "-s \(Self.serial) emu posture 3"|"-s \(Self.serial) emu posture 1")
            printf 'OK\\r\\n' ;;
        """)
        let rig = makeRig(adb: adb.client)
        rig.panel.controls.posture = .closed

        rig.hardware.toggleFold()
        let opening = try XCTUnwrap(rig.hardware.postureAnimationTask)
        await opening.value

        XCTAssertEqual(adb.calls.first, "-s \(Self.serial) emu posture 3", "\(adb.calls)")
        XCTAssertFalse(adb.calls(containing: "shell settings list").isEmpty, "no refresh after the posture: \(adb.calls)")
        XCTAssertTrue(rig.panel.controlsLoaded)
        XCTAssertEqual(rig.panel.controls.posture, .opened)
        XCTAssertNil(rig.hardware.postureAnimationTask)

        let before = adb.calls.count
        rig.hardware.toggleFold()
        let closing = try XCTUnwrap(rig.hardware.postureAnimationTask)
        await closing.value

        XCTAssertEqual(adb.calls.dropFirst(before).first, "-s \(Self.serial) emu posture 1", "\(adb.calls)")
        XCTAssertEqual(rig.panel.controls.posture, .closed)
        XCTAssertEqual(rig.repaints.count, 0)
    }

    /// Slider changes while a send is out only queue their angle: the one
    /// sender sends the latest, drains, repaints once and lets go of its
    /// handle.
    func testTheHingeSenderDrainsThenRepaintsOnce() async throws {
        let rig = makeRig(port: Self.silentPort)

        rig.hardware.setHingeAngle(30)
        let sender = try XCTUnwrap(rig.hardware.hingeSendTask)
        rig.hardware.setHingeAngle(60)
        rig.hardware.setHingeAngle(90)

        XCTAssertEqual(rig.hardware.hingeSendTask, sender, "a drag already sending only queues its angle")
        XCTAssertEqual(rig.panel.controls.hingeAngle, 90)
        XCTAssertTrue(rig.panel.isPostureBusy(), "the sender owns the hinge")

        await sender.value
        XCTAssertEqual(rig.repaints.count, 1, "drained: one repaint")
        XCTAssertNil(rig.hardware.hingeSendTask)
        XCTAssertFalse(rig.panel.isPostureBusy())
        XCTAssertEqual(rig.panel.controls.hingeAngle, 90)
    }

    /// A slider change cancels the posture animation; without a port it
    /// only moves the angle (the slider needs gRPC).
    func testAHingeChangeCancelsThePostureAnimation() throws {
        let rig = makeRig()

        rig.hardware.setPostureAnimated(.opened)
        let animation = try XCTUnwrap(rig.hardware.postureAnimationTask)
        rig.hardware.setHingeAngle(45)

        XCTAssertTrue(animation.isCancelled)
        XCTAssertNil(rig.hardware.postureAnimationTask)
        XCTAssertNil(rig.hardware.hingeSendTask)
        XCTAssertEqual(rig.panel.controls.hingeAngle, 45)
    }

    /// The fold gates: a half-opened posture or a hinge sensor in the
    /// active AVD's config makes the device foldable, and the fold strip
    /// shows only while a device is mirrored.
    func testFoldableFromThePostureOrTheAvdHinge() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("AvdHome-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let fold = home.appendingPathComponent("Fold_API_35.avd", isDirectory: true)
        try FileManager.default.createDirectory(at: fold, withIntermediateDirectories: true)
        try Data("hw.sensor.hinge.count=1\n".utf8).write(to: fold.appendingPathComponent("config.ini"))
        let rig = makeRig(avdHome: home)

        XCTAssertFalse(rig.hardware.isFoldable)
        XCTAssertFalse(rig.hardware.showsFoldControls)

        rig.panel.controls.posture = .halfOpened
        XCTAssertTrue(rig.hardware.isFoldable)
        XCTAssertTrue(rig.hardware.showsFoldControls)

        rig.panel.controls.posture = .closed
        rig.context.avdName = "Fold_API_35"
        XCTAssertTrue(rig.hardware.isFoldable)
        XCTAssertTrue(rig.hardware.showsFoldControls)

        rig.context.serial = nil
        XCTAssertFalse(rig.hardware.showsFoldControls, "nothing mirrored, no fold strip")
    }

    // MARK: Resize

    /// A resize the emulator refuses sets the error and selects nothing.
    func testARefusedResizeSetsTheErrorAndKeepsNoSelection() async throws {
        let adb = try makeStubAdb(arms: "")
        let rig = makeRig(adb: adb.client)

        await rig.hardware.applyResizePreset(ResizePreset(index: 2, name: "tablet"))

        XCTAssertNil(rig.hardware.selectedResizePreset)
        XCTAssertTrue(
            rig.status.errorMessage?.hasPrefix("Could not resize the display") == true,
            rig.status.errorMessage ?? ""
        )
        XCTAssertEqual(adb.calls, ["-s \(Self.serial) emu resize-display 2"])
    }

    /// Without the session's AVD name, the presets ask the model's lookup
    /// for a listed emulator's AVD, and only a resizable one has its
    /// console asked for the presets.
    func testPresetsAskTheListedEmulatorsAvdThroughTheLookup() async throws {
        let adb = try makeStubAdb(arms: """
          "-s \(Self.serial) emu resize-display")
            printf 'KO usage: "resize-display <index>" 0: phone\\t1: unfolded\\r\\n' ;;
        """)
        let rig = makeRig(adb: adb.client)
        rig.hardware.isResizableAvd = { $0 == "Resizable_API_35" }
        rig.hardware.devicesSource = { [AndroidDevice.online(Self.serial)] }
        let asked = SerialLog()
        rig.hardware.avdNameLookup = { device in
            asked.serials.append(device.serial)
            return "Resizable_API_35"
        }

        await rig.hardware.refreshResizePresets()

        XCTAssertEqual(asked.serials, [Self.serial])
        XCTAssertEqual(rig.hardware.resizePresets, [
            ResizePreset(index: 0, name: "phone"),
            ResizePreset(index: 1, name: "unfolded"),
        ])

        rig.hardware.avdNameLookup = { _ in "Pixel_API_35" }
        let reads = adb.calls(containing: "emu resize-display").count
        await rig.hardware.refreshResizePresets()

        XCTAssertEqual(rig.hardware.resizePresets, [])
        XCTAssertEqual(adb.calls(containing: "emu resize-display").count, reads, "a phone AVD's console is not asked")
    }

    // MARK: Detach

    /// `detach()` cancels the battery write, the hinge sender, the posture
    /// animation and the preset read, and forgets the presets and the
    /// selection: a preset answer still out never lands.
    func testDetachCancelsTheWorkersAndForgetsThePresets() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Presets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let inFlight = directory.appendingPathComponent("in-flight")
        let release = directory.appendingPathComponent("release")
        // The preset read waits for `release` before it answers.
        let adb = try makeStubAdb(arms: """
          "-s \(Self.serial) emu resize-display")
            touch \(AdbClient.shellQuoted(inFlight.path))
            while [ ! -e \(AdbClient.shellQuoted(release.path)) ]; do sleep 0.05; done
            printf 'KO usage: "resize-display <index>" 0: phone\\t1: unfolded\\r\\n' ;;
        """)
        let rig = makeRig(adb: adb.client, port: Self.silentPort)
        rig.context.avdName = "Resizable_API_35"
        rig.hardware.isResizableAvd = { _ in true }
        rig.hardware.resizePresets = [ResizePreset(index: 0, name: "phone")]
        rig.hardware.selectedResizePreset = 0

        rig.hardware.startResizePresetsLoad()
        let load = try XCTUnwrap(rig.hardware.resizePresetsTask)
        await waitUntil("the preset read never started") {
            FileManager.default.fileExists(atPath: inFlight.path)
        }
        rig.hardware.setBatteryLevel(42)
        rig.hardware.setHingeAngle(90)
        rig.hardware.setPostureAnimated(.opened)
        let battery = try XCTUnwrap(rig.hardware.batteryApplyTask)
        let hinge = try XCTUnwrap(rig.hardware.hingeSendTask)
        let posture = try XCTUnwrap(rig.hardware.postureAnimationTask)

        rig.hardware.detach()
        FileManager.default.createFile(atPath: release.path, contents: nil)

        XCTAssertTrue(battery.isCancelled, "a pending battery write must not land on the next device")
        XCTAssertTrue(hinge.isCancelled)
        XCTAssertTrue(posture.isCancelled)
        XCTAssertTrue(load.isCancelled)
        XCTAssertNil(rig.hardware.batteryApplyTask)
        XCTAssertNil(rig.hardware.hingeSendTask)
        XCTAssertNil(rig.hardware.postureAnimationTask)
        XCTAssertNil(rig.hardware.resizePresetsTask)
        XCTAssertEqual(rig.hardware.resizePresets, [])
        XCTAssertNil(rig.hardware.selectedResizePreset)

        await load.value
        XCTAssertEqual(rig.hardware.resizePresets, [], "the cancelled read offers nothing")
        await battery.value
        await hinge.value
        XCTAssertEqual(rig.repaints.count, 0, "a cancelled sender does not repaint")
        XCTAssertNil(rig.status.statusMessage, "a cancelled battery write reports nothing")
    }

    // MARK: Model wiring

    /// The model's old names read and write the one controller, the fold
    /// strip's driver reads its hinge angle, its hooks reach the model's
    /// session, device list and AVD names, the Controls poll's posture hold
    /// reads it, and the teardown hub detaches it.
    func testModelNamesForwardToTheControllerAndTeardownDetachesIt() async throws {
        let adb = try makeStubAdb(arms: """
          "-s \(Self.serial) emu avd name")
            printf 'Fold_API_35\\r\\nOK\\r\\n' ;;
        """)
        let model = AppModel.testing(adb: adb.client)
        let session = RepaintCountingSession()
        model.workspace.mirror.sessionFactoryOverride = { _, _ in session }
        let phone = AndroidDevice.online("HT4CWJT0000A", model: "Pixel A")
        let emulator = AndroidDevice.online(Self.serial)
        model.inventory.applyWatcherSnapshot([phone, emulator], degraded: false)
        await model.mirror(device: phone)

        model.workspace.hardware.selectedResizePreset = 1
        XCTAssertEqual(model.hardware.selectedResizePreset, 1)
        model.hardware.resizePresets = [ResizePreset(index: 1, name: "unfolded")]
        XCTAssertEqual(model.workspace.hardware.resizePresets, [ResizePreset(index: 1, name: "unfolded")])
        model.workspace.hardware.isResizableAvd = { $0 == "Fold_API_35" }
        XCTAssertTrue(model.hardware.isResizableAvd("Fold_API_35"))
        model.workspace.controlsPanel.controls.hingeAngle = 12
        XCTAssertEqual(model.hardware.hingeAngle, 12)
        let driver: any FoldControlDriving = model.hardware
        XCTAssertEqual(driver.hingeAngle, 12)
        model.workspace.controlsPanel.controls.posture = .halfOpened
        XCTAssertTrue(model.workspace.hardware.isFoldable)
        XCTAssertTrue(model.workspace.hardware.showsFoldControls)

        await model.hardware.resync()
        XCTAssertEqual(session.resyncs, 1, "the repaint hook reaches the mirrored session")
        XCTAssertEqual(model.hardware.devicesSource().map(\.serial), [phone.serial, emulator.serial])
        let avd = await model.hardware.avdNameLookup(emulator)
        XCTAssertEqual(avd, "Fold_API_35")

        XCTAssertFalse(model.controlsPanel.isPostureBusy())
        model.workspace.hardware.setPostureAnimated(.opened)
        XCTAssertEqual(model.workspace.hardware.postureAnimationTask, model.hardware.postureAnimationTask)
        XCTAssertTrue(model.controlsPanel.isPostureBusy(), "the animation owns the posture")

        model.stopMirror()

        XCTAssertNil(model.hardware.postureAnimationTask)
        XCTAssertFalse(model.controlsPanel.isPostureBusy(), "the teardown cancels the animation")
        XCTAssertEqual(model.hardware.resizePresets, [])
        XCTAssertNil(model.hardware.selectedResizePreset)
        XCTAssertFalse(model.workspace.hardware.showsFoldControls)
    }
}

/// Counts the controller's repaints.
@MainActor
private final class RepaintLog {
    var count = 0
}

/// The serials a hook was asked about, in order.
@MainActor
private final class SerialLog {
    var serials: [String] = []
}

/// A mirror session that only counts its repaints (`resync`).
private final class RepaintCountingSession: MirrorSessionProtocol, @unchecked Sendable {
    let frames = FrameStore()
    let transport: MirrorTransport = .h264

    private let lock = NSLock()
    private var _resyncs = 0

    var resyncs: Int {
        lock.withLock { _resyncs }
    }

    var lastError: String? { nil }
    var isRunning: Bool { true }

    func start() {}
    func stop() {}

    func resync() async {
        lock.withLock { _resyncs += 1 }
    }

    func stats() async -> MirrorStats {
        MirrorStats(fps: 0, totalFrames: 0, dropped: 0, averageLatencyMs: 0)
    }

    func send(_ command: TouchCommand) {}
    func send(contacts: [TouchCommand]) {}
    func send(_ command: KeyboardCommand) {}
}
