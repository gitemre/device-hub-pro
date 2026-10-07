import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The App-side decoders of device output, fed the byte-exact API 37
/// emulator captures in `Tests/DeviceHubProKitTests/Fixtures/api37-emulator/controls`
/// (see `ControlsDeviceOutputTests` in the Kit tests). Expected values are
/// what the device reported through a second command.
@MainActor
final class ControlsDeviceOutputDecoderTests: XCTestCase {
    /// `adb shell "wm size; wm density"`, the one shell
    /// `AppModel.readDisplayMetrics` runs: the Pixel 9 Pro Fold's inner
    /// display, 2076x2152 at 390 dpi. `am get-config` agreed (`390dpi`,
    /// `2152x2076`).
    func testDisplayMetricsFromWmSizeAndDensity() throws {
        let output = try fixture("wm-size-wm-density.txt")
        XCTAssertEqual(output, "Physical size: 2076x2152\nPhysical density: 390\n")
        XCTAssertEqual(
            MirrorDisplayMetrics(wmOutput: output),
            MirrorDisplayMetrics(width: 2076, height: 2152, dpi: 390)
        )
        let config = try fixture("am-get-config.txt")
        XCTAssertTrue(config.contains("-390dpi-"))
        XCTAssertTrue(config.contains("-2152x2076-"))
    }

    /// `readGlobalSettings`' decoders on `adb shell settings list global`:
    /// `wifi_on` 1 (`cmd wifi status`: "Wifi is enabled"), `bluetooth_on` 1
    /// (the manager's `State: ON`), `airplane_mode_on` 0 (`cmd connectivity
    /// airplane-mode`: "disabled").
    func testGlobalRowsFromTheRealNamespaceList() throws {
        let settings = AdbParsing.globalSettings(from: try fixture("settings-list-global.txt"))
        XCTAssertEqual(try fixture("cmd-connectivity-airplane-mode.txt"), "disabled\n")

        let airplaneModeOn = settings["airplane_mode_on"] == "1"
        XCTAssertFalse(airplaneModeOn)
        XCTAssertTrue(DeviceControlsController.wifiIsOn(settingValue: settings["wifi_on"]))
        let adapter = AdbClient.bluetoothAdapterEnabled(
            fromManagerStatus: try fixture("dumpsys-bluetooth_manager-state.txt")
        )
        XCTAssertEqual(adapter, true)
        XCTAssertTrue(
            DeviceControlsController.bluetoothIsOn(
                settingValue: settings["bluetooth_on"],
                airplaneModeOn: airplaneModeOn,
                adapterEnabled: nil
            )
        )
    }

    /// `bluetooth_on` 2 in airplane mode now takes the adapter's answer,
    /// which the API 37 status block gives again (`State: ON`), instead of
    /// the airplane-mode fallback that reads off.
    func testAirplaneModeBluetoothTakesTheRealAdapterState() throws {
        let adapter = AdbClient.bluetoothAdapterEnabled(
            fromManagerStatus: try fixture("dumpsys-bluetooth_manager-state.txt")
        )
        XCTAssertTrue(DeviceControlsController.bluetoothIsOn(settingValue: "2", airplaneModeOn: true, adapterEnabled: adapter))
    }

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("DeviceHubProKitTests/Fixtures/api37-emulator/controls")
            .appendingPathComponent(name)
        return try XCTUnwrap(String(data: try Data(contentsOf: url), encoding: .utf8), name)
    }
}
