import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// Stop AVD on the mirrored emulator ends the mirror, whose disconnect puts
/// back the network conditions Device Hub Pro set (`DeviceConditionsController.
/// detach()`). Those put-backs go through the VM's console and adb shell, so
/// they must land before the console `kill`: it shuts the VM down and saves
/// its quick-boot state as it is.
@MainActor
final class ConditionsEmulatorStopTests: XCTestCase {
    private static let serial = "emulator-5556"

    func testStopPutsTheConditionsBackBeforeTheConsoleKill() async throws {
        let target = "Conditions_\(UUID().uuidString.prefix(6))"
        let emulator = try makeStubEmulator(avds: [target])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConditionsStop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let discovery = directory.appendingPathComponent("discovery.ini")
        let port = try makeOwnedGrpcPort()
        try Data("grpc.port=\(port)\n".utf8).write(to: discovery)
        // The memory-factor reset takes as long as on a device (a few hundred
        // ms), so a kill that does not wait for the cleanup overtakes it;
        // the console `kill` ends the stub VM the way the emulator ends.
        let adb = try makeStubAdb(arms: """
          "devices -l")
            printf 'List of devices attached\\n'
            printf '\(Self.serial)          device product:sdk model:Target transport_id:8\\n' ;;
          "-s \(Self.serial) emu avd name")
            printf '%s\\r\\nOK\\r\\n' "\(target)" ;;
          "-s \(Self.serial) emu avd discoverypath")
            printf '%s\\r\\nOK\\r\\n' "\(discovery.path)" ;;
          "-s \(Self.serial) shell if [ "*"am memory-factor reset"*)
            sleep 0.5 ;;
          "-s \(Self.serial) emu gsm meter on")
            printf 'OK\\r\\n' ;;
          "-s \(Self.serial) emu kill")
            kill -TERM $(cat "\(emulator.pidsURL.path)")
            printf 'OK\\r\\n' ;;
          "track-devices"*)
            exec sleep 30 ;;
        """)
        // The VM runs before the Start (as if started earlier or elsewhere).
        _ = try emulator.manager.launch(avd: target, grpcPort: port)
        await waitUntil("the VM never started") { !emulator.launches.isEmpty }
        let model = AppModel.testing(adb: adb.client, emulator: emulator.manager)
        addTeardownBlock { @MainActor in model.inventory.stopDeviceLifecycle() }
        model.workspace.mirror.sessionFactoryOverride = { _, _ in FakeMirrorSession() }

        await model.startAndMirror(avd: target)
        XCTAssertEqual(model.activeDeviceSerial, Self.serial)
        // The mirror changed the meter on this VM.
        let instance = EmulatorInstance(avdName: target, discoveryPath: discovery.path)
        model.conditions.markChanged(.meter, serial: Self.serial, instance: instance)

        await model.stopEmulator(avd: target)

        XCTAssertNil(model.workspace.status.errorMessage)
        let calls = adb.calls
        let putBack = try XCTUnwrap(calls.firstIndex(of: "-s \(Self.serial) emu gsm meter on"), "\(calls)")
        let kill = try XCTUnwrap(calls.firstIndex(of: "-s \(Self.serial) emu kill"), "\(calls)")
        XCTAssertLessThan(putBack, kill, "the meter is put back before the VM saves its state and exits")
        XCTAssertNil(model.conditions.changedConditions[Self.serial], "nothing is kept for the stopped VM")
    }
}
