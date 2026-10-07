import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// `mirror(device:)` awaits the emulator's port resolution; an attach the
/// user left behind in the meantime (its stage task cancelled, or another
/// selection made) must end silently, and a failed one must be parked for
/// the stage's Retry.
@MainActor
final class MirrorAttachTests: XCTestCase {
    private let emulator = AndroidDevice.online("emulator-5554", transport: "3")

    /// A console whose `avd discoverypath` takes a second, so the test can
    /// act while the attach resolves.
    private func slowDiscoveryAdb() throws -> StubAdb {
        try makeStubAdb(arms: """
          "-s emulator-5554 emu avd discoverypath")
            sleep 1
            exit 1 ;;
        """)
    }

    /// The emulator is the inert one: it sees only this process's VMs, so an
    /// attach the console answers no discovery file for resolves to no port
    /// at all (never to a VM running on the Mac).
    private func model(adb: StubAdb) -> (AppModel, FakeMirrorSession) {
        let model = AppModel.testing(adb: adb.client)
        let session = FakeMirrorSession()
        model.workspace.mirror.sessionFactoryOverride = { _, _ in session }
        model.inventory.applyWatcherSnapshot([emulator], degraded: false)
        return (model, session)
    }

    /// The stage's attach task is cancelled (the user clicked another device)
    /// while the port resolves: no alert, no selection change, no session.
    func testCancelledAttachEndsSilently() async throws {
        let adb = try slowDiscoveryAdb()
        let (model, _) = model(adb: adb)
        model.deviceSelection = .device("HT4CWJT01234")

        let attach = Task { await model.mirror(device: emulator) }
        await waitUntil("the attach never reached the console") {
            !adb.calls(containing: "avd discoverypath").isEmpty
        }
        XCTAssertEqual(model.workspace.mirror.mirrorAttach, MirrorController.MirrorAttach(serial: emulator.serial, failure: nil))
        attach.cancel()
        let outcome = await attach.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertNil(model.workspace.status.errorMessage, "a cancelled attach must not raise an alert")
        XCTAssertEqual(model.deviceSelection, .device("HT4CWJT01234"))
        XCTAssertNil(model.workspace.mirror.session)
        XCTAssertNil(model.workspace.mirror.mirrorAttach, "the stage shows no attach in flight")
    }

    /// The user selected something else while the port resolved: the late
    /// result neither selects the emulator back nor alerts.
    func testSupersededAttachDoesNotStealTheStage() async throws {
        let adb = try slowDiscoveryAdb()
        let (model, _) = model(adb: adb)

        let attach = Task { await model.mirror(device: emulator) }
        await waitUntil("the attach never reached the console") {
            !adb.calls(containing: "avd discoverypath").isEmpty
        }
        model.deviceSelection = .device("HT4CWJT01234")
        let outcome = await attach.value

        XCTAssertEqual(outcome, .cancelled, "a superseded attach ends like a cancelled one")
        XCTAssertNil(model.workspace.status.errorMessage)
        XCTAssertEqual(model.deviceSelection, .device("HT4CWJT01234"))
        XCTAssertNil(model.workspace.mirror.session)
    }

    /// A failed attach is surfaced once and parked on the stage with its
    /// reason, so the stage offers Retry instead of spinning.
    func testFailedAttachIsParkedForRetry() async {
        let model = AppModel.testing(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        let offline = AndroidDevice(serial: "emulator-5556", state: "offline")

        let outcome = await model.mirror(device: offline)

        XCTAssertEqual(outcome, .failed("emulator-5556 is offline."), "the outcome carries the raised message")
        XCTAssertEqual(model.workspace.status.errorMessage, "emulator-5556 is offline.")
        XCTAssertEqual(
            model.workspace.mirror.mirrorAttach,
            MirrorController.MirrorAttach(serial: "emulator-5556", failure: "emulator-5556 is offline.")
        )

        model.deviceSelection = .device("HT4CWJT01234")
        XCTAssertNil(model.workspace.mirror.mirrorAttach, "moving on clears the parked failure")
    }

    /// A physical device's attach reports its outcome too: without adb it
    /// fails with the reason it parks, with adb its scrcpy session starts.
    func testPhysicalAttachReportsItsOutcome() async throws {
        let phone = AndroidDevice.online("HT4CWJT01234", transport: "7")
        let withoutAdb = AppModel.testing()
        let failed = await withoutAdb.mirror(device: phone)
        XCTAssertEqual(failed, .failed(AdbError.adbNotFound.description))
        XCTAssertEqual(withoutAdb.workspace.mirror.mirrorAttach?.failure, AdbError.adbNotFound.description)

        let adb = try makeStubAdb(arms: "")
        let model = AppModel.testing(adb: adb.client)
        model.workspace.mirror.sessionFactoryOverride = { serial, _ in FakePhysicalSession(serial: serial) }
        model.inventory.applyWatcherSnapshot([phone], degraded: false)
        let started = await model.mirror(device: phone)
        XCTAssertEqual(started, .started)
        XCTAssertEqual(model.activeDeviceSerial, phone.serial)
        model.stopMirror()
    }

    /// Attaching a mirror leaves the device's rotation settings alone (it
    /// used to switch auto-rotate back on for every emulator session).
    func testAttachDoesNotTouchTheRotationLock() async throws {
        let discovery = FileManager.default.temporaryDirectory
            .appendingPathComponent("discovery-\(UUID().uuidString).ini")
        let port = try makeOwnedGrpcPort()
        try Data("grpc.port=\(port)\n".utf8).write(to: discovery)
        addTeardownBlock { try? FileManager.default.removeItem(at: discovery) }
        let adb = try makeStubAdb(arms: """
          "-s emulator-5554 emu avd discoverypath")
            printf '%s\\r\\nOK\\r\\n' "\(discovery.path)" ;;
          "-s emulator-5554 emu avd name")
            printf 'Pixel_API_35\\r\\nOK\\r\\n' ;;
        """)
        let (model, session) = model(adb: adb)
        var ports: [Int?] = []
        model.workspace.mirror.sessionFactoryOverride = { _, port in
            ports.append(port)
            return session
        }

        let outcome = await model.mirror(device: emulator)
        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(ports, [port], "the discovery file's port is the one mirrored")
        XCTAssertEqual(model.activeDeviceSerial, emulator.serial)
        // Give any fire-and-forget work of the attach a moment to run.
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(
            adb.calls(containing: "accelerometer_rotation").isEmpty,
            "attaching must not read or rewrite the rotation lock: \(adb.calls)"
        )
        XCTAssertTrue(adb.calls(containing: "user-rotation").isEmpty)
        model.stopMirror()
    }

    // MARK: Resize presets

    private static let consolePresets = [
        ResizePreset(index: 0, name: "phone"),
        ResizePreset(index: 1, name: "unfolded"),
        ResizePreset(index: 2, name: "tablet"),
    ]

    /// A console that answers the attach as `avd` and answers the preset
    /// read the way every emulator does, with its KO usage line (the bytes
    /// of AdbCoreFixtureTests' `emu-resize-display.txt`). Once `gate`
    /// exists, each preset answer touches `inFlight` and then takes a
    /// second.
    private func presetsAdb(avd: String = "Resizable_API_35", gate: URL, inFlight: URL) throws -> StubAdb {
        let discovery = FileManager.default.temporaryDirectory
            .appendingPathComponent("discovery-\(UUID().uuidString).ini")
        let port = try makeOwnedGrpcPort()
        try Data("grpc.port=\(port)\n".utf8).write(to: discovery)
        addTeardownBlock { try? FileManager.default.removeItem(at: discovery) }
        return try makeStubAdb(arms: """
          "-s emulator-5554 emu avd discoverypath")
            printf '%s\\r\\nOK\\r\\n' "\(discovery.path)" ;;
          "-s emulator-5554 emu avd name")
            printf '\(avd)\\r\\nOK\\r\\n' ;;
          "-s emulator-5554 emu resize-display")
            if [ -e "\(gate.path)" ]; then touch "\(inFlight.path)"; sleep 1; fi
            printf 'KO usage: "resize-display <index>" 0: phone\\t1: unfolded\\t2: tablet\\r\\n' ;;
        """)
    }

    /// Points the model's resizability check at an AVD home holding a
    /// resizable AVD (`Resizable_API_35`, whose `hw.resizable.configs` lists
    /// its sizes) and a phone AVD (`Pixel_API_35`, without the key).
    private func useFixtureAvds(on model: AppModel) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("AvdHome-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let configs = [
            "Resizable_API_35": """
            hw.device.name=resizable
            hw.resizable.configs=phone-0-1080-2400-420, foldable-1-2208-1840-420, tablet-2-2560-1600-320, desktop-3-1920-1080-160

            """,
            "Pixel_API_35": """
            hw.device.name=pixel_9_pro
            hw.sensor.hinge.resizable.config=1

            """,
        ]
        for (name, config) in configs {
            let directory = home.appendingPathComponent("\(name).avd", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(config.utf8).write(to: directory.appendingPathComponent("config.ini"))
        }
        model.workspace.hardware.isResizableAvd = { AvdConfig.isResizable(avdName: $0, avdHome: home) }
    }

    /// A resizable AVD offers the presets its console lists, although the
    /// console answers the read with KO.
    func testResizableAvdOffersTheConsolePresets() async throws {
        let files = try scratchFiles()
        let adb = try presetsAdb(gate: files.gate, inFlight: files.inFlight)
        let (model, _) = model(adb: adb)
        try useFixtureAvds(on: model)
        await model.mirror(device: emulator)

        await model.workspace.hardware.refreshResizePresets()

        XCTAssertEqual(model.workspace.hardware.resizePresets, Self.consolePresets)
        model.stopMirror()
    }

    /// A phone AVD's console gives the identical answer, but the AVD has no
    /// resizable display: it offers no presets, and the console is not
    /// asked for them.
    func testNonResizableAvdOffersNoPresets() async throws {
        let files = try scratchFiles()
        let adb = try presetsAdb(avd: "Pixel_API_35", gate: files.gate, inFlight: files.inFlight)
        let (model, _) = model(adb: adb)
        try useFixtureAvds(on: model)
        await model.mirror(device: emulator)

        await model.workspace.hardware.refreshResizePresets()
        // The session start's own read runs as a detached task.
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(model.workspace.hardware.resizePresets, [])
        XCTAssertTrue(
            adb.calls(containing: "emu resize-display").isEmpty,
            "a phone AVD needs no preset read: \(adb.calls)"
        )
        model.stopMirror()
    }

    private func scratchFiles() throws -> (gate: URL, inFlight: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Presets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (directory.appendingPathComponent("gate"), directory.appendingPathComponent("in-flight"))
    }

    /// Mirror on the emulator already mirrored (like the stage's Retry, or
    /// Start of the mirrored AVD) tears the session down and starts the
    /// next one on the same serial within one main-actor turn. ControlsView
    /// reloads the presets only when the serial changes, so the session
    /// start must reload what the teardown cleared, or the Resize row
    /// stays hidden until the user switches devices.
    func testReattachToTheSameEmulatorReloadsTheResizePresets() async throws {
        let files = try scratchFiles()
        let adb = try presetsAdb(gate: files.gate, inFlight: files.inFlight)
        let (model, _) = model(adb: adb)
        try useFixtureAvds(on: model)
        await model.mirror(device: emulator)
        await model.workspace.hardware.refreshResizePresets()
        XCTAssertEqual(model.workspace.hardware.resizePresets.map(\.index), [0, 1, 2])

        await model.mirror(device: emulator)
        XCTAssertEqual(model.activeDeviceSerial, emulator.serial)

        await waitUntil("the re-attached emulator offers no resize presets") {
            !model.workspace.hardware.resizePresets.isEmpty
        }
        XCTAssertEqual(model.workspace.hardware.resizePresets.map(\.index), [0, 1, 2])
        model.stopMirror()
    }

    /// A preset read still running when its session ends lands nowhere: a
    /// slow answer must not show one emulator's presets on the next device.
    func testLatePresetAnswerDoesNotOutliveItsSession() async throws {
        let files = try scratchFiles()
        let adb = try presetsAdb(gate: files.gate, inFlight: files.inFlight)
        let (model, _) = model(adb: adb)
        try useFixtureAvds(on: model)
        await model.mirror(device: emulator)
        FileManager.default.createFile(atPath: files.gate.path, contents: nil)

        let load = Task { await model.workspace.hardware.refreshResizePresets() }
        await waitUntil("the preset read never started") {
            FileManager.default.fileExists(atPath: files.inFlight.path)
        }
        model.stopMirror()
        await load.value

        XCTAssertTrue(model.workspace.hardware.resizePresets.isEmpty, "\(model.workspace.hardware.resizePresets)")
    }
}
