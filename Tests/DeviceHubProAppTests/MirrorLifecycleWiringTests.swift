import Darwin
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The model's side of the session lifecycle: which stops reach the decider
/// (only the user's), what a teardown leaves behind, and the VM liveness
/// probe behind an emulator's adb absence.
@MainActor
final class MirrorLifecycleWiringTests: XCTestCase {
    private let phone = AndroidDevice.online("HT4CWJT01234", model: "Pixel 8")

    /// A model mirroring `phone` over a fake session, with the lifecycle
    /// running (its watcher's adb is `/usr/bin/false`, so it reports nothing
    /// on its own).
    private func mirroringModel() async -> (AppModel, FakeMirrorSession) {
        let model = AppModel.testing(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        addTeardownBlock { @MainActor in model.inventory.stopDeviceLifecycle() }
        let session = FakeMirrorSession()
        model.workspace.mirror.sessionFactoryOverride = { _, _ in session }
        model.inventory.startDeviceLifecycle()
        model.inventory.applyWatcherSnapshot([phone], degraded: false)
        await model.mirror(device: phone)
        XCTAssertEqual(model.activeDeviceSerial, phone.serial)
        return (model, session)
    }

    /// Stop Mirror is the user's stop: the lifecycle forgets the device, so
    /// unplugging it afterwards neither ghosts its row nor arms a resume.
    func testUserStopMirrorEndsTheEpisode() async {
        let (model, session) = await mirroringModel()

        model.stopMirror()
        XCTAssertEqual(session.stopCount, 1)
        model.workspace.lifecycleIfRunning?.handle(.snapshot(devices: [], degraded: false))

        XCTAssertNil(model.inventory.ghostSerial(for: model.workspace.id), "a stopped mirror must not leave a 'waiting to reconnect' ghost")
        XCTAssertNil(model.workspace.reconnect, "and no reconnect episode")
    }

    /// The lifecycle's own teardown (the device left) is not the user's
    /// stop: the episode it opens keeps its ghost.
    func testLifecycleTeardownKeepsTheEpisode() async {
        let (model, session) = await mirroringModel()

        model.workspace.lifecycleIfRunning?.handle(.snapshot(devices: [], degraded: false))

        XCTAssertEqual(session.stopCount, 1, "the device left: its session is torn down")
        XCTAssertNil(model.activeDeviceSerial)
        XCTAssertEqual(model.inventory.ghostSerial(for: model.workspace.id), phone.serial, "the reconnect episode is still under way")
    }

    // MARK: Per-device state (F5, F14)

    /// A console answer about the previous session's emulator never names
    /// the next session's AVD.
    func testStaleAvdNameAnswerIsIgnored() async {
        let (model, _) = await mirroringModel()
        let stale = model.mirrorSessionGeneration - 1

        model.applyActiveAvdName("Old_AVD", serial: phone.serial, generation: stale)
        XCTAssertNil(model.activeAvdName)

        model.applyActiveAvdName("Pixel_API_35", serial: phone.serial, generation: model.mirrorSessionGeneration)
        XCTAssertEqual(model.activeAvdName, "Pixel_API_35")

        model.stopMirror()
        XCTAssertNil(model.activeAvdName, "a torn-down mirror names no AVD (Stop Emulator, Power On use it)")
    }

    /// Teardown cancels the per-device workers and forgets per-device state,
    /// so none of it reaches (or shows on) the next device.
    func testTeardownCancelsPerDeviceWorkersAndState() async {
        let (model, _) = await mirroringModel()
        // A port nothing can serve: the battery write, should it ever get
        // out, fails instead of resetting the first emulator's (8554).
        model.workspace.context.port = EmulatorManager.unreachableGrpcPort
        model.workspace.hardware.setBatteryLevel(42)
        XCTAssertNotNil(model.workspace.hardware.batteryApplyTask)
        model.workspace.extras.isVmPaused = true
        model.workspace.hardware.selectedResizePreset = 2

        model.stopMirror()

        XCTAssertNil(model.workspace.hardware.batteryApplyTask, "a pending battery write must not land on the next device")
        XCTAssertFalse(model.workspace.extras.isVmPaused)
        XCTAssertNil(model.workspace.hardware.selectedResizePreset)
    }

    // MARK: Emulator stream health

    /// An emulator stream that fails shows a warning (the session reconnects
    /// on its own and is never torn down for it); frames clear it.
    func testEmulatorStreamErrorIsANonFatalWarning() async {
        let (model, session) = await mirroringModel()

        model.workspace.mirror.noteEmulatorStream(isStreaming: false, lastError: "stream ended")
        XCTAssertEqual(model.workspace.mirror.mirrorStreamWarning, "stream ended")
        XCTAssertEqual(session.stopCount, 0, "the mirror stays up")

        model.workspace.mirror.noteEmulatorStream(isStreaming: false, lastError: nil)
        XCTAssertEqual(model.workspace.mirror.mirrorStreamWarning, "stream ended", "reconnecting without a new error keeps it")

        model.workspace.mirror.noteEmulatorStream(isStreaming: true, lastError: "stream ended")
        XCTAssertNil(model.workspace.mirror.mirrorStreamWarning, "frames flow again")

        model.workspace.mirror.noteEmulatorStream(isStreaming: false, lastError: "again")
        model.stopMirror()
        XCTAssertNil(model.workspace.mirror.mirrorStreamWarning)
    }

    // MARK: VM liveness

    /// The liveness hook answers from the process list for the AVD behind
    /// the serial, and "gone" for a serial whose AVD is unknown.
    func testEmulatorLivenessFollowsTheVMProcess() async throws {
        let avd = "DeviceHubPro_Liveness_\(UUID().uuidString.prefix(8))"
        let vm = try startFakeEmulatorProcess(avd: avd)
        // The process list is read with `ps` (this process's VMs only); the
        // binary is never run.
        let model = AppModel.testing(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        model.catalog.avdCards = [
            AvdCard(name: avd, displayName: avd, target: nil, skin: nil, isRunning: true, serial: "emulator-5580"),
        ]

        let running = await model.inventory.isEmulatorVMRunning(serial: "emulator-5580")
        XCTAssertTrue(running, "the VM for the card's AVD is in the process list")
        let unknown = await model.inventory.isEmulatorVMRunning(serial: "emulator-5590")
        XCTAssertFalse(unknown, "an unknown AVD answers 'gone', as before the hook")

        vm.terminate()
        vm.waitUntilExit()
        let gone = await model.inventory.isEmulatorVMRunning(serial: "emulator-5580")
        XCTAssertFalse(gone, "the VM exited")
    }

    /// A process `EmulatorManager.runningEmulators()` lists as a VM for
    /// `avd`: a shell script named `qemu-system-…`, run with `-avd` (and a
    /// port nothing serves), adopted as this process's own so the test
    /// model's own-process scope sees it.
    private func startFakeEmulatorProcess(avd: String) throws -> Process {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeVM-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("qemu-system-fake")
        try Data("#!/bin/sh\nwhile :; do sleep 0.2; done\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let process = Process()
        process.executableURL = script
        process.arguments = ["-avd", avd, "-grpc", "\(EmulatorManager.unreachableGrpcPort)"]
        try process.run()
        EmulatorManager.adoptProcess(process.processIdentifier, avd: avd)
        addTeardownBlock {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? FileManager.default.removeItem(at: directory)
        }
        return process
    }
}
