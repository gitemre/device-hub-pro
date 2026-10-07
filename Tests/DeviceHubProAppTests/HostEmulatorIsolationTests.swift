import Darwin
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// A test model never reaches an emulator VM its test did not start: not
/// through the port resolution of a mirrored stub emulator, not through
/// Start's attach to a running AVD, not through Stop's or Power On's
/// signals, and not through a fold scheduled for the previous device.
///
/// Each test runs a stand-in for an emulator someone else runs on this Mac:
/// a process `ps` lists as `qemu-system-… -avd <unique> -grpc <port>`, started
/// directly (not through an `EmulatorManager`, and not adopted), whose gRPC
/// port is a loopback listener that counts connections. On 2026-09-25 such a
/// real VM was bound by a test's mirror and folded shut. The tests do not
/// depend on what else runs on the Mac: every VM they could reach is their
/// own stand-in, whose AVD name the stub consoles answer.
@MainActor
final class HostEmulatorIsolationTests: XCTestCase {
    /// The stand-in: its AVD, its process and the listener on its port.
    private struct ForeignVM {
        let avd: String
        let process: Process
        let grpc: LoopbackListener
    }

    private let emulator = AndroidDevice.online("emulator-5554", transport: "3")

    private func startForeignVM() throws -> ForeignVM {
        let grpc = try LoopbackListener()
        let avd = "DeviceHubPro_Foreign_\(UUID().uuidString.prefix(8))"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForeignVM-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("qemu-system-foreign")
        try Data("#!/bin/sh\ntrap 'exit 0' TERM\nwhile :; do sleep 0.2; done\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let process = Process()
        process.executableURL = script
        process.arguments = ["-avd", avd, "-grpc", "\(grpc.port)"]
        try process.run()
        addTeardownBlock {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            grpc.stop()
            await EmulatorControls.closeConnections(port: grpc.port)
            try? FileManager.default.removeItem(at: directory)
            // The failed boots below write the inert emulator's log for it.
            for log in [
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Logs/DeviceHubPro/devicehubpro-emulator-\(avd).log"),
                FileManager.default.temporaryDirectory.appendingPathComponent("devicehubpro-emulator-\(avd).log"),
            ] {
                try? FileManager.default.removeItem(at: log)
            }
        }
        return ForeignVM(avd: avd, process: process, grpc: grpc)
    }

    private func fastBoots(_ model: AppModel) {
        let bootTiming = EmulatorBootController.BootTiming(
            startupGrace: .milliseconds(100),
            poll: .milliseconds(100),
            onlineTimeout: .seconds(1),
            bootTimeout: .seconds(1)
        )
        model.boot.bootTiming = bootTiming
        model.apps.bootTiming = bootTiming
    }

    /// Mirroring a stub emulator whose console names the stand-in's AVD and
    /// publishes no discovery file: the model neither lists the stand-in nor
    /// resolves the serial to its port, so no session starts and nothing
    /// connects to it. (The resolution used to read every VM on the Mac,
    /// match it by that name — or take it as the only VM running — and start
    /// a session whose controls went to its port.)
    func testMirroringAStubEmulatorNeverListsOrReachesAVMItDidNotStart() async throws {
        let vm = try startForeignVM()
        let adb = try makeStubAdb(arms: """
          "-s emulator-5554 emu avd name")
            printf '%s\\r\\nOK\\r\\n' "\(vm.avd)" ;;
        """)
        let model = AppModel.testing(adb: adb.client)
        var ports: [Int?] = []
        model.workspace.mirror.sessionFactoryOverride = { _, port in
            ports.append(port)
            return FakeMirrorSession()
        }
        model.inventory.applyWatcherSnapshot([emulator], degraded: false)

        let listed = (try? await model.emulatorManager?.runningEmulators()) ?? []
        XCTAssertFalse(listed.contains { $0.avd == vm.avd }, "the model lists a VM its test did not start: \(listed)")

        let outcome = await model.mirror(device: emulator)
        // Room for a session's workers (the sensor poll) to reach the port.
        try await Task.sleep(for: .milliseconds(500))
        model.stopMirror()

        XCTAssertEqual(ports, [], "a session started on the VM's port")
        XCTAssertNotEqual(outcome, .started)
        XCTAssertEqual(vm.grpc.connectionCount, 0, "the model connected to the VM's gRPC port")
        XCTAssertTrue(vm.process.isRunning)
    }

    /// Start of the stand-in's AVD, with a stub adb whose emulator console
    /// names it: Start does not take the stand-in for a VM of its own to
    /// attach to, so it attaches to nothing (nor boots: see below).
    func testStartNeverAttachesToAVMItDidNotStart() async throws {
        let vm = try startForeignVM()
        let adb = try makeStubAdb(arms: """
          "devices -l")
            printf 'List of devices attached\\n'
            printf 'emulator-5554          device product:sdk model:Foreign transport_id:3\\n' ;;
          "-s emulator-5554 emu avd name")
            printf '%s\\r\\nOK\\r\\n' "\(vm.avd)" ;;
        """)
        let model = AppModel.testing(adb: adb.client)
        fastBoots(model)
        var ports: [Int?] = []
        model.workspace.mirror.sessionFactoryOverride = { _, port in
            ports.append(port)
            return FakeMirrorSession()
        }

        await model.startAndMirror(avd: vm.avd)
        try await Task.sleep(for: .milliseconds(500))
        model.stopMirror()

        XCTAssertEqual(ports, [], "Start attached to a VM its test did not start")
        XCTAssertEqual(vm.grpc.connectionCount, 0, "the model connected to the VM's gRPC port")
        XCTAssertTrue(vm.process.isRunning)
    }

    /// Stop of the stand-in's AVD finds no VM of its own to stop: nothing is
    /// signalled and no console is asked to `kill`.
    func testStopNeverSignalsAVMItDidNotStart() async throws {
        let vm = try startForeignVM()
        let adb = try makeStubAdb(arms: "")
        let model = AppModel.testing(adb: adb.client)

        await model.stopEmulator(avd: vm.avd)
        // Room for a signalled VM to exit and be reaped.
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(vm.process.isRunning, "Stop signalled a VM its test did not start")
        XCTAssertTrue(adb.calls(containing: "emu kill").isEmpty, "\(adb.calls)")
    }

    /// Power On for the stand-in's AVD kills nothing: its SIGKILL goes only
    /// to a VM this process started. Nor does it launch a second VM of the
    /// AVD the stand-in runs.
    func testPowerOnNeverKillsAVMItDidNotStart() async throws {
        let vm = try startForeignVM()
        let adb = try makeStubAdb(arms: "")
        let emulator = try makeStubEmulator(avds: [vm.avd])
        let model = AppModel.testing(adb: adb.client, emulator: emulator.manager)
        fastBoots(model)
        model.setActiveAvdName(vm.avd)

        await model.powerOnDevice()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(vm.process.isRunning, "Power On killed a VM its test did not start")
        XCTAssertEqual(vm.grpc.connectionCount, 0)
        XCTAssertEqual(emulator.launches, [], "Power On launched a second VM of an AVD that is running")
        XCTAssertEqual(model.workspace.status.errorMessage, "\(vm.avd) is already running, so a second instance was not started.")
    }

    /// Start of an AVD a VM it did not start runs neither attaches (above)
    /// nor boots it: a second VM of the AVD would take the running one down,
    /// and the display repair that precedes a boot would rewrite the
    /// config.ini under it. Whether any VM runs the AVD is read from every
    /// VM on the Mac — reading `ps` reaches none — whatever the model's
    /// scope. (Seeing only its own VMs, Start used to take the AVD for
    /// stopped and boot it.)
    func testStartNeverBootsAnAvdAVMItDidNotStartRuns() async throws {
        let vm = try startForeignVM()
        let adb = try makeStubAdb(arms: "")
        let emulator = try makeStubEmulator(avds: [vm.avd])
        let model = AppModel.testing(adb: adb.client, emulator: emulator.manager)
        fastBoots(model)
        var ports: [Int?] = []
        model.workspace.mirror.sessionFactoryOverride = { _, port in
            ports.append(port)
            return FakeMirrorSession()
        }

        await model.startAndMirror(avd: vm.avd)

        XCTAssertEqual(emulator.launches, [], "Start launched a second VM of an AVD that is running")
        XCTAssertEqual(model.workspace.status.errorMessage, "\(vm.avd) is already running, so a second instance was not started.")
        XCTAssertEqual(ports, [])
        XCTAssertTrue(vm.process.isRunning)
        XCTAssertEqual(vm.grpc.connectionCount, 0)
    }

    /// Delete, rename and reset refuse an AVD that a VM runs, also one the
    /// model does not count as its own: the running check behind the file
    /// actions reads every VM, so they never pull an AVD's files from under
    /// a VM someone else runs. (With the own-process view they took it for
    /// stopped and went on to the AVD home.)
    func testFileActionsRefuseAnAvdAVMItDidNotStartRuns() async throws {
        let vm = try startForeignVM()
        let model = AppModel.testing()
        let refusal = "\"\(vm.avd)\" is running. Stop it first, then try again."

        await model.catalog.wipeAVDData(vm.avd)
        XCTAssertEqual(model.status.errorMessage, refusal)
        model.status.errorMessage = nil
        await model.catalog.deleteAVD(vm.avd)
        XCTAssertEqual(model.status.errorMessage, refusal)
        model.status.errorMessage = nil
        await model.catalog.renameAVD(vm.avd, to: "\(vm.avd)_Renamed")
        XCTAssertEqual(model.status.errorMessage, refusal)
        model.status.errorMessage = nil
        // The keyboard is read at launch: its config is never changed
        // under a running VM either.
        await model.catalog.enableHardwareKeyboard(vm.avd)
        XCTAssertEqual(model.status.errorMessage, refusal)

        XCTAssertTrue(vm.process.isRunning)
    }

    /// A fold scheduled for one device and cancelled by its teardown before
    /// it ran must not reach the next device, even when that one is a closed
    /// foldable whose port is in the context by the time the task first runs
    /// (the animation used to read the port then, and to send the posture of
    /// a closed device before it checked for cancellation).
    func testACancelledFoldNeverReachesTheNextDevicesPort() async throws {
        let next = try LoopbackListener()
        addTeardownBlock {
            next.stop()
            await EmulatorControls.closeConnections(port: next.port)
        }
        let context = ActiveDeviceContext(avdHome: nil)
        context.serial = "emulator-5580"
        context.port = 0
        let status = StatusCenter()
        let panel = DeviceControlsController(adbClient: nil, context: context, status: status)
        let hardware = EmulatorHardwareController(
            adbClient: nil,
            context: context,
            controlsPanel: panel,
            status: status
        )
        panel.controls.posture = .closed

        hardware.setPostureAnimated(.opened)
        let fold = try XCTUnwrap(hardware.postureAnimationTask)
        // The teardown of this device and the next device's session, before
        // the main actor lets the fold run.
        hardware.detach()
        context.serial = "emulator-5582"
        context.port = next.port
        panel.controls.posture = .closed

        await fold.value
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(next.connectionCount, 0, "the cancelled fold reached the next device's gRPC port")
    }
}
