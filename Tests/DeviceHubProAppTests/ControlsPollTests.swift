import AppKit
import SwiftUI
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The Controls poll and the state it feeds: the recovery card's signal,
/// the Location draft, stale polls across a device switch and the TalkBack
/// package read.
@MainActor
final class ControlsPollTests: XCTestCase {
    private let phoneA = AndroidDevice.online("HT4CWJT0000A", model: "Pixel A")
    private let phoneB = AndroidDevice.online("HT4CWJT0000B", model: "Pixel B")

    private func model(adb: AdbClient) -> AppModel {
        let model = AppModel.testing(adb: adb)
        model.workspace.mirror.sessionFactoryOverride = { _, _ in FakeMirrorSession() }
        model.inventory.applyWatcherSnapshot([phoneA, phoneB], degraded: false)
        return model
    }

    // MARK: Recovery card (F1)

    /// A physical mirror has no gRPC state at all; that absence is not "the
    /// device powered off".
    func testPhysicalMirrorNeverNeedsRecovery() async {
        let model = model(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        await model.mirror(device: phoneA)
        model.workspace.controlsPanel.controlsLoaded = true

        XCTAssertFalse(model.workspace.controlsPanel.needsRecovery, "empty emulator fields on a phone must not show 'Device powered off'")
    }

    /// Only an explicit signal counts: the emulator reports its guest not
    /// booted (or its channel stays silent for several polls).
    func testEmulatorNeedsRecoveryOnlyOnAnExplicitSignal() async {
        let model = model(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        await model.mirror(device: phoneA)
        // A port nothing can serve (never 8554, the first emulator's): any
        // Controls call this model makes fails at once.
        model.workspace.context.port = EmulatorManager.unreachableGrpcPort
        addTeardownBlock { @MainActor in model.stopMirror() }

        XCTAssertFalse(model.workspace.controlsPanel.needsRecovery, "before the first poll lands nothing is known")
        model.workspace.controlsPanel.controlsLoaded = true
        XCTAssertFalse(model.workspace.controlsPanel.needsRecovery, "missing fields alone are no signal")
        model.workspace.controlsPanel.controls.isBooted = false
        XCTAssertTrue(model.workspace.controlsPanel.needsRecovery)
        XCTAssertEqual(model.workspace.controlsPanel.recoveryReason, .poweredOff)
    }

    // MARK: Location draft (F2)

    /// The sheet's draft is the device's fix when it opens, and the user's
    /// from then on: a poll never overwrites what they type.
    func testLocationDraftIsNotOverwrittenWhileTheSheetIsOpen() {
        let model = AppModel.testing(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        model.workspace.controlsPanel.controls.location = GpsFix(latitude: 37.422, longitude: -122.084)

        model.workspace.location.isLocationSheetPresented = true
        XCTAssertEqual(model.workspace.location.locationLatText, "37.4220")
        XCTAssertEqual(model.workspace.location.locationLngText, "-122.0840")

        model.workspace.location.locationLatText = "48.8566"
        model.workspace.location.primeLocationDraft(from: GpsFix(latitude: 1, longitude: 2))
        XCTAssertEqual(model.workspace.location.locationLatText, "48.8566", "a poll must not replace the typed latitude")

        model.workspace.location.isLocationSheetPresented = false
        model.workspace.location.primeLocationDraft(from: GpsFix(latitude: 1, longitude: 2))
        XCTAssertEqual(model.workspace.location.locationLatText, "1.0000", "closed, the draft follows the device again")
    }

    // MARK: Stale polls (F10)

    /// A poll whose reads were still running when the user switched devices
    /// applies nothing to the new device's panel.
    func testPollStartedForThePreviousDeviceAppliesNothing() async throws {
        let adb = try makeStubAdb(arms: """
          "-s \(phoneA.serial) shell"*)
            sleep 1
            exit 1 ;;
        """)
        let model = model(adb: adb.client)
        await model.mirror(device: phoneA)

        let poll = Task { await model.workspace.controlsPanel.refreshControls() }
        await waitUntil("the poll never reached device A") {
            !adb.calls(containing: "-s \(self.phoneA.serial) shell").isEmpty
        }
        await model.mirror(device: phoneB)
        await poll.value

        XCTAssertEqual(model.activeDeviceSerial, phoneB.serial)
        XCTAssertFalse(model.workspace.controlsPanel.controlsLoaded, "device A's reads must not mark device B's panel loaded")
    }

    /// The gRPC half of a poll replaces only its own fields: the adb-backed
    /// rows survive a poll that skipped the settings (a write in flight).
    func testEmulatorFieldsMergeWithoutBlankingSettingsRows() {
        var state = DeviceControlsState()
        state.wifiEnabled = true
        state.airplaneModeEnabled = false
        state.appearance = .mode(.dark)
        state.dataSaverEnabled = true
        var read = DeviceControlsState()
        read.isBooted = true
        read.hingeAngle = 90

        DeviceControlsController.mergeEmulatorFields(read, into: &state)

        XCTAssertEqual(state.wifiEnabled, true)
        XCTAssertEqual(state.airplaneModeEnabled, false)
        XCTAssertEqual(state.appearance, .mode(.dark))
        XCTAssertEqual(state.dataSaverEnabled, true)
        XCTAssertEqual(state.isBooted, true)
        XCTAssertEqual(state.hingeAngle, 90)
    }

    // MARK: Bluetooth in airplane mode (EMC-11)

    /// Airplane mode turned on with Bluetooth on persists `bluetooth_on` 2
    /// and turns the radio off: the row reads the adapter and says Off (a
    /// tap then turns Bluetooth on). Wi-Fi's 2 is the airplane override: On.
    /// The stubs answer only the production status command, with what its
    /// `grep -m 1` prints: phone A the API 26-36 line `  state: OFF`
    /// (SOURCE-DERIVED, BluetoothManagerService.dump), phone B the byte-exact
    /// API 37 emulator line (`dumpsys-bluetooth_manager-state.txt`).
    func testBluetoothTwoInAirplaneModeReadsTheAdapter() async throws {
        let statusCommand = AdbClient.bluetoothStatusCommand
        let realStateLine = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("DeviceHubProKitTests/Fixtures/api37-emulator/controls")
            .appendingPathComponent("dumpsys-bluetooth_manager-state.txt")
        XCTAssertEqual(try String(contentsOf: realStateLine, encoding: .utf8), "  State:         ON\n")
        let adb = try makeStubAdb(arms: """
          "-s \(phoneA.serial) shell settings list global")
            printf 'airplane_mode_on=1\\nbluetooth_on=2\\nwifi_on=2\\n' ;;
          "-s \(phoneA.serial) shell \(statusCommand)")
            printf '  state: OFF\\n' ;;
          "-s \(phoneB.serial) shell settings list global")
            printf 'airplane_mode_on=1\\nbluetooth_on=2\\n' ;;
          "-s \(phoneB.serial) shell \(statusCommand)")
            cat \(AdbClient.shellQuoted(realStateLine.path)) ;;
        """)
        let model = model(adb: adb.client)

        await model.mirror(device: phoneA)
        await model.workspace.controlsPanel.refreshControls()
        XCTAssertEqual(model.workspace.controlsPanel.controls.airplaneModeEnabled, true)
        XCTAssertEqual(model.workspace.controlsPanel.controls.bluetoothEnabled, false, "airplane mode turned the radio off")
        XCTAssertEqual(model.workspace.controlsPanel.controls.wifiEnabled, true)

        await model.mirror(device: phoneB)
        await model.workspace.controlsPanel.refreshControls()
        XCTAssertEqual(model.workspace.controlsPanel.controls.bluetoothEnabled, true, "kept on for a connected headset")
    }

    /// Only `bluetooth_on` 2 costs the extra adapter read.
    func testBluetoothAdapterIsReadOnlyForTheAmbiguousSetting() async throws {
        let adb = try makeStubAdb(arms: """
          "-s \(phoneA.serial) shell settings list global")
            printf 'airplane_mode_on=1\\nbluetooth_on=1\\n' ;;
        """)
        let model = model(adb: adb.client)
        await model.mirror(device: phoneA)

        await model.workspace.controlsPanel.refreshControls()

        XCTAssertEqual(model.workspace.controlsPanel.controls.bluetoothEnabled, true)
        XCTAssertTrue(adb.calls(containing: "bluetooth_manager").isEmpty, "\(adb.calls)")
    }

    // MARK: Occlusion gating

    /// A fully occluded or miniaturized window stops the Controls poll
    /// (`ControlsView`'s `.task`, gated on `DeviceWorkspace.window.isWindowVisible`):
    /// hosting the real view, the poll runs while the window is visible,
    /// stops while `isWindowVisible` is false, and resumes once it is true
    /// again — without a live window (occlusion state is driven by the
    /// window server, not reproducible headless in a unit test), the flag
    /// is set directly, the same signal `WorkspaceWindowVisibilityTracking`
    /// would write from a real occlusion-state change.
    func testOcclusionGatingStopsAndResumesTheControlsPoll() async throws {
        let adb = try makeStubAdb(arms: """
          "-s \(phoneA.serial) shell settings list global")
            printf 'airplane_mode_on=0\\n' ;;
        """)
        let model = model(adb: adb.client)
        await model.mirror(device: phoneA)
        addTeardownBlock { @MainActor in model.stopMirror() }

        let host = NSHostingView(
            rootView: ControlsView().environment(model).environment(model.workspace)
        )
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        func callCount() -> Int { adb.calls(containing: "settings list global").count }

        await waitUntil("the poll never ran while visible") { callCount() > 0 }

        model.workspace.window.isWindowVisible = false
        let countWhenHidden = callCount()
        // More than one 2 s poll interval, to give a still-running poll a
        // chance to fire and prove the gate did not hold.
        try await Task.sleep(for: .milliseconds(2500))
        XCTAssertEqual(callCount(), countWhenHidden, "a hidden window must not keep polling")

        model.workspace.window.isWindowVisible = true
        await waitUntil("the poll never resumed once visible again") { callCount() > countWhenHidden }
    }

    // MARK: TalkBack package (F20)

    /// `pm list packages` runs once per device, not on every 2 s poll.
    func testTalkBackPackageIsReadOncePerDevice() async throws {
        let adb = try makeStubAdb(arms: """
          "-s \(phoneA.serial) shell pm list packages")
            printf 'package:com.android.settings\\npackage:com.google.android.marvin.talkback\\n' ;;
        """)
        let model = model(adb: adb.client)
        await model.mirror(device: phoneA)

        await model.workspace.controlsPanel.refreshControls()
        await model.workspace.controlsPanel.refreshControls()
        await model.workspace.controlsPanel.refreshControls()

        XCTAssertEqual(model.workspace.controlsPanel.deviceSettings.talkBackPackage, "com.google.android.marvin.talkback")
        XCTAssertEqual(adb.calls(containing: "pm list packages").count, 1, "\(adb.calls)")
    }
}
