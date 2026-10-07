import DeviceHubProKit
import Foundation
import XCTest
@testable import DeviceHubProApp

/// The active device's identity, shared by the model and its per-device
/// features: the hinge count follows the AVD, `clear()` forgets the device
/// but not the generations, and the model's old names read and write it.
@MainActor
final class ActiveDeviceContextTests: XCTestCase {
    /// An AVD home with a foldable (`Fold`, one hinge) and a phone (`Phone`,
    /// no hinge key).
    private func avdHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActiveDeviceContext-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        try writeConfig("hw.sensor.hinge.count=1\nhw.lcd.width=2076\n", avd: "Fold", home: home)
        try writeConfig("hw.lcd.width=1080\n", avd: "Phone", home: home)
        return home
    }

    private func writeConfig(_ text: String, avd: String, home: URL) throws {
        let directory = home.appendingPathComponent("\(avd).avd", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: directory.appendingPathComponent("config.ini"))
    }

    func testAvdNameSetsTheHingeCount() throws {
        let context = ActiveDeviceContext(avdHome: try avdHome())
        XCTAssertEqual(context.hingeCount, 0)

        context.avdName = "Fold"
        XCTAssertEqual(context.hingeCount, 1)
        context.avdName = "Phone"
        XCTAssertEqual(context.hingeCount, 0, "a config.ini without the hinge key declares none")
        context.avdName = "Fold"
        context.avdName = "No_Such_AVD"
        XCTAssertEqual(context.hingeCount, 0, "an unknown AVD has no config.ini, so no hinge")
        context.avdName = "Fold"
        context.avdName = nil
        XCTAssertEqual(context.hingeCount, 0, "no AVD, no hinge")
    }

    /// config.ini is read when the AVD is set, not on every read of the
    /// count (view bodies read `isFoldable` on every Controls poll).
    func testHingeCountIsReadWhenTheAvdIsSet() throws {
        let home = try avdHome()
        let context = ActiveDeviceContext(avdHome: home)
        context.avdName = "Fold"

        try writeConfig("hw.lcd.width=2076\n", avd: "Fold", home: home)
        XCTAssertEqual(context.hingeCount, 1, "the count is the one read when the AVD became known")
        context.avdName = "Fold"
        XCTAssertEqual(context.hingeCount, 0, "setting the AVD again reads it again")
    }

    func testClearForgetsTheDeviceButNotTheGenerations() throws {
        let context = ActiveDeviceContext(avdHome: try avdHome())
        context.serial = "emulator-5554"
        context.port = 8554
        context.avdName = "Fold"
        context.sessionGeneration = 3
        context.controlsGeneration = 7

        context.clear()

        XCTAssertNil(context.serial)
        XCTAssertNil(context.port)
        XCTAssertNil(context.avdName)
        XCTAssertEqual(context.hingeCount, 0)
        XCTAssertEqual(context.sessionGeneration, 3, "the hubs bump the generations themselves")
        XCTAssertEqual(context.controlsGeneration, 7)
    }

    /// The serial is adb-only: an Apple device leaves it nil, so every adb
    /// path's `guard let serial` no-ops for it, and setting a serial names
    /// an Android device.
    func testTheSerialIsTheAndroidDevicesOnly() {
        let context = ActiveDeviceContext()

        context.device = .apple("00000000-0000-0000-0000-000000000000")
        context.capabilities = [.mirror]
        XCTAssertNil(context.serial)

        context.serial = "emulator-5554"
        XCTAssertEqual(context.device, .android("emulator-5554"))
        XCTAssertEqual(context.serial, "emulator-5554")

        context.clear()
        XCTAssertNil(context.device)
        XCTAssertEqual(context.capabilities, [])
    }

    /// The teardown hub bumps the controls generation with a wrapping add,
    /// so the counter can never trap, and the session generation with it.
    func testTeardownWrapsTheControlsGeneration() {
        let model = AppModel.testing()
        model.context.controlsGeneration = .max
        let session = model.mirrorSessionGeneration

        model.stopMirror()

        XCTAssertEqual(model.context.controlsGeneration, 0)
        XCTAssertEqual(model.mirrorSessionGeneration, session + 1)
        XCTAssertEqual(model.context.sessionGeneration, model.mirrorSessionGeneration)
    }

    /// The model's names are views of the one shared context, so a feature
    /// holding the context sees exactly what the model sees.
    func testModelNamesReadAndWriteTheSharedContext() {
        let model = AppModel.testing()

        // A port nothing can serve: never a real emulator's.
        let port = EmulatorManager.unreachableGrpcPort
        model.workspace.context.port = port
        XCTAssertEqual(model.context.port, port)
        XCTAssertTrue(model.workspace.controlsPanel.canUseEmulatorControls)

        model.context.serial = "emulator-5554"
        XCTAssertEqual(model.activeDeviceSerial, "emulator-5554")

        model.stopMirror()
        XCTAssertNil(model.context.serial)
        XCTAssertNil(model.context.port)
        XCTAssertNil(model.workspace.context.port)
        XCTAssertNil(model.activeDeviceSerial)
    }
}
