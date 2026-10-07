import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// Smaller wirings of the model: the Apps load's cancellation, the setting
/// encodings, the install package kinds, the diagnostics status, a physical
/// device's Back, and the emulator actions' failure reporting.
@MainActor
final class ModelWiringTests: XCTestCase {
    private let phone = AndroidDevice.online("HT4CWJT01234", model: "Pixel 8")

    // MARK: Apps (app-shell F1)

    /// Leaving the Apps tab mid-load cancels it: no "CancellationError()"
    /// alert, and no `appsSerial`, so returning loads the list again.
    func testCancelledAppsLoadLeavesNothingBehind() async throws {
        let adb = try makeStubAdb(arms: """
          "-s \(phone.serial) shell pm list packages"*)
            sleep 2 ;;
        """)
        let model = AppModel.testing(adb: adb.client)

        let load = Task { await model.workspace.apps.loadApps(serial: phone.serial) }
        await waitUntil("the load never started") { !adb.calls(containing: "pm list packages").isEmpty }
        load.cancel()
        await load.value

        XCTAssertNil(model.workspace.status.errorMessage)
        XCTAssertNil(model.workspace.apps.appsSerial, "the tab must load again when it returns")
        XCTAssertFalse(model.workspace.apps.isLoadingApps)
    }

    /// A real failure still surfaces (and marks the device loaded, so the
    /// tab does not retry in a loop).
    func testFailedAppsLoadStillSurfaces() async throws {
        let adb = try makeStubAdb(arms: "")
        let model = AppModel.testing(adb: adb.client)

        await model.workspace.apps.loadApps(serial: phone.serial)

        XCTAssertNotNil(model.workspace.status.errorMessage)
        XCTAssertEqual(model.workspace.apps.appsSerial, phone.serial)
    }

    /// The Controls poll reads the TalkBack package once per device. An
    /// install or an uninstall changes that device's package set, so the
    /// next poll reads it again — and an install on another device does not.
    func testInstallAndUninstallMakeTheControlsPollReadTalkBackAgain() async throws {
        let adb = try makeStubAdb(arms: """
          "-s emulator-5554 shell pm list packages")
            printf 'package:com.google.android.marvin.talkback\\n' ;;
          "-s emulator-5554 install "*|"-s emulator-5556 install "*|"-s emulator-5554 uninstall "*)
            printf 'Success\\n' ;;
        """)
        let model = AppModel.testing(adb: adb.client)
        model.context.serial = "emulator-5554"
        let talkBackReads = { adb.calls.filter { $0 == "-s emulator-5554 shell pm list packages" }.count }

        await model.workspace.controlsPanel.refreshControls()
        await model.workspace.controlsPanel.refreshControls()
        XCTAssertEqual(talkBackReads(), 1, "read once per device")

        await install(on: "emulator-5556", model)
        await model.workspace.controlsPanel.refreshControls()
        XCTAssertEqual(talkBackReads(), 1, "another device's install changes nothing here")

        await install(on: "emulator-5554", model)
        await model.workspace.controlsPanel.refreshControls()
        XCTAssertEqual(talkBackReads(), 2, "an install makes the poll read again")

        await model.workspace.apps.uninstallApp(package: "com.example.app")
        await model.workspace.controlsPanel.refreshControls()
        XCTAssertEqual(talkBackReads(), 3, "an uninstall makes the poll read again")
        XCTAssertNil(model.workspace.status.errorMessage)
    }

    /// Installs an APK on `serial` and ends the result line's two-second
    /// hold once it shows. No such file: the install is the stub's.
    private func install(on serial: String, _ model: AppModel) async {
        let apk = URL(fileURLWithPath: "/nonexistent/app-debug.apk")
        let install = Task { await model.workspace.apps.installAPK(at: apk, serial: serial) }
        await waitUntil("the install on \(serial) never finished") {
            model.workspace.status.statusMessage == "app-debug.apk installed"
        }
        install.cancel()
        await install.value
    }

    // MARK: Install packages

    /// `adb install` takes an APK, a bundletool `.apks` set or a folder of
    /// split APKs (the Kit resolves them); anything else is refused up front.
    func testInstallablePackageKinds() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("splits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        XCTAssertTrue(AppsController.isInstallablePackage(URL(fileURLWithPath: "/tmp/app-debug.apk")))
        XCTAssertTrue(AppsController.isInstallablePackage(URL(fileURLWithPath: "/tmp/app.APKS")))
        XCTAssertTrue(AppsController.isInstallablePackage(directory), "a folder of split APKs")
        XCTAssertFalse(AppsController.isInstallablePackage(URL(fileURLWithPath: "/tmp/notes.txt")))
        XCTAssertFalse(AppsController.isInstallablePackage(URL(fileURLWithPath: "/tmp/missing-folder")))
    }

    // MARK: Setting encodings (EMC-11)

    /// `wifi_on` 2 is Wi-Fi turned back on in airplane mode: on. 3 is off
    /// because of airplane mode.
    func testWifiSettingEncodings() {
        XCTAssertTrue(DeviceControlsController.wifiIsOn(settingValue: "1"))
        XCTAssertTrue(DeviceControlsController.wifiIsOn(settingValue: "2"))
        XCTAssertFalse(DeviceControlsController.wifiIsOn(settingValue: "0"))
        XCTAssertFalse(DeviceControlsController.wifiIsOn(settingValue: "3"))
        XCTAssertFalse(DeviceControlsController.wifiIsOn(settingValue: nil))
    }

    /// `bluetooth_on` 2 means "was on when airplane mode came on", which
    /// is usually off (airplane mode turned the radio off) and on only when
    /// Android kept it on for a connected headset: the adapter decides.
    func testBluetoothSettingEncodings() {
        for airplane in [false, true] {
            XCTAssertTrue(DeviceControlsController.bluetoothIsOn(settingValue: "1", airplaneModeOn: airplane, adapterEnabled: nil))
            XCTAssertFalse(DeviceControlsController.bluetoothIsOn(settingValue: "0", airplaneModeOn: airplane, adapterEnabled: nil))
            XCTAssertFalse(DeviceControlsController.bluetoothIsOn(settingValue: nil, airplaneModeOn: airplane, adapterEnabled: nil))
            XCTAssertTrue(DeviceControlsController.bluetoothIsOn(settingValue: "2", airplaneModeOn: airplane, adapterEnabled: true))
            XCTAssertFalse(DeviceControlsController.bluetoothIsOn(settingValue: "2", airplaneModeOn: airplane, adapterEnabled: false))
        }
        XCTAssertFalse(
            DeviceControlsController.bluetoothIsOn(settingValue: "2", airplaneModeOn: true, adapterEnabled: nil),
            "airplane mode turned the radio off"
        )
        XCTAssertTrue(
            DeviceControlsController.bluetoothIsOn(settingValue: "2", airplaneModeOn: false, adapterEnabled: nil),
            "airplane mode just ended: the manager turns the radio back on"
        )
    }

    // MARK: Diagnostics

    func testDiagnosticsStatusNamesWhatTheBundleLacks() {
        let url = URL(fileURLWithPath: "/tmp/bundle.zip")
        XCTAssertEqual(
            CaptureController.diagnosticsStatus(for: DiagnosticsBundleResult(url: url, usedHostClockFallback: false)),
            "Diagnostics bundle saved"
        )
        XCTAssertEqual(
            CaptureController.diagnosticsStatus(for: DiagnosticsBundleResult(
                url: url,
                usedHostClockFallback: false,
                failedSections: ["dumpsys-meminfo", "getprop"]
            )),
            "Diagnostics bundle saved — could not collect dumpsys-meminfo, getprop (see the .error.txt files)"
        )
        XCTAssertEqual(
            CaptureController.diagnosticsStatus(for: DiagnosticsBundleResult(
                url: url,
                usedHostClockFallback: true,
                usedLogcatLineFallback: true
            )),
            "Diagnostics bundle saved — logcat holds the last \(DiagnosticsBundle.logcatFallbackLineCount) lines, not the last five minutes"
        )
        XCTAssertEqual(
            CaptureController.diagnosticsStatus(for: DiagnosticsBundleResult(url: url, usedHostClockFallback: true)),
            "Diagnostics bundle saved — device clock unavailable, the logcat window is approximate"
        )
    }

    // MARK: Physical Back

    /// A physical mirror's Back goes through the scrcpy session (BACK, or
    /// POWER on a dark screen), not through an `adb shell input` process.
    func testPhysicalBackUsesTheScrcpySession() async throws {
        let adb = try makeStubAdb(arms: "")
        let delivered = InputLog()
        let physical = PhysicalMirrorSession(
            serial: phone.serial,
            inputRunner: { arguments in await delivered.append(arguments) },
            launchConnection: {
                // Never connects within the test: input takes the fallback.
                try await Task.sleep(for: .seconds(5))
                throw CancellationError()
            }
        )
        let model = AppModel.testing(adb: adb.client)
        model.workspace.mirror.sessionFactoryOverride = { _, _ in physical }
        model.inventory.applyWatcherSnapshot([phone], degraded: false)
        await model.mirror(device: phone)
        XCTAssertTrue(model.workspace.mirror.activePhysicalSession === physical)

        await model.workspace.mirror.goBack()

        let deadline = Date().addingTimeInterval(3)
        var entries: [[String]] = []
        while Date() < deadline, entries.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
            entries = await delivered.entries
        }
        XCTAssertEqual(entries, [PhysicalInput.backArguments(serial: phone.serial)])
        XCTAssertTrue(adb.calls(containing: "keyevent").isEmpty, "no adb key event: \(adb.calls)")
        model.stopMirror()
    }

    // MARK: Emulator action failures (F18)

    /// A resize the emulator refuses is reported and not shown as applied.
    func testRefusedResizeIsReportedAndNotSelected() async throws {
        let adb = try makeStubAdb(arms: "")
        let model = AppModel.testing(adb: adb.client)
        model.workspace.mirror.sessionFactoryOverride = { _, _ in FakeMirrorSession() }
        model.inventory.applyWatcherSnapshot([phone], degraded: false)
        await model.mirror(device: phone)

        await model.workspace.hardware.applyResizePreset(ResizePreset(index: 2, name: "Foldable"))

        XCTAssertNil(model.workspace.hardware.selectedResizePreset)
        XCTAssertTrue(model.workspace.status.errorMessage?.hasPrefix("Could not resize the display") == true, model.workspace.status.errorMessage ?? "")
    }

    // MARK: Workspace selection

    /// The selection lives on the workspace: written through the model it
    /// reads back from either, and the multi-selection still follows a
    /// primary outside it.
    func testSelectionWritesThroughToTheWorkspace() {
        let model = AppModel.testing()
        model.selectAllRows([.avd("A"), .avd("B")])
        XCTAssertTrue(model.workspace.multiSelection.isMultiple)

        model.deviceSelection = .device(phone.serial)

        XCTAssertEqual(model.workspace.deviceSelection, .device(phone.serial))
        XCTAssertEqual(model.workspace.multiSelection, model.multiSelection)
        XCTAssertFalse(model.multiSelection.isMultiple, "a primary outside the rows replaces them")

        model.workspace.deviceSelection = .avd("A")
        XCTAssertEqual(model.deviceSelection, .avd("A"))
    }

    /// A selection change still reaches the hot-plug lifecycle through the
    /// workspace's hook.
    func testSelectionChangeReachesTheWorkspaceHook() {
        let model = AppModel.testing()
        var calls = 0
        let wired = model.workspace.selectionChanged
        model.workspace.selectionChanged = { calls += 1; wired() }

        model.deviceSelection = .avd("A")
        model.deviceSelection = .avd("A")

        XCTAssertEqual(calls, 2, "every write is noted, as before")
    }
}

/// Collects fallback input invocations across the session's queue.
private actor InputLog {
    private(set) var entries: [[String]] = []

    func append(_ arguments: [String]) {
        entries.append(arguments)
    }
}
