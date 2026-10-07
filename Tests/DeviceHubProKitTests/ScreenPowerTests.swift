import XCTest
@testable import DeviceHubProKit

/// The screen's on/off state and the wake action.
///
/// The fixtures under `Fixtures/api35-emulator/power/` are the byte-exact
/// output of `adb -s emulator-5554 exec-out sh -c "dumpsys power | grep
/// mWakefulness="` on an API 35 emulator (AVD `Pixel_10_Pro`,
/// `sdk_gphone64_arm64`, 2026-10-07): `-awake` with the screen on, `-asleep`
/// after `input keyevent 26` (Power). `input keyevent 224` (Wakeup) brought
/// it back to Awake, read the same way.
final class ScreenPowerTests: XCTestCase {
    static let fixtureDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/api35-emulator/power", isDirectory: true)

    static func url(_ name: String) -> URL { fixtureDirectory.appendingPathComponent(name) }

    static func text(_ name: String) throws -> String {
        try XCTUnwrap(String(data: Data(contentsOf: url(name)), encoding: .utf8))
    }

    func testTheCapturedStatesParse() throws {
        XCTAssertEqual(AndroidWakefulness.parse(dumpsysPower: try Self.text("dumpsys-power-wakefulness-awake.txt")), .awake)
        XCTAssertEqual(AndroidWakefulness.parse(dumpsysPower: try Self.text("dumpsys-power-wakefulness-asleep.txt")), .asleep)
    }

    func testOnlyAwakeAndDreamingCountAsAScreenThatIsOn() {
        XCTAssertTrue(AndroidWakefulness.awake.isScreenOn)
        XCTAssertTrue(AndroidWakefulness.dreaming.isScreenOn)
        XCTAssertFalse(AndroidWakefulness.asleep.isScreenOn)
        XCTAssertFalse(AndroidWakefulness.dozing.isScreenOn)
    }

    func testTextWithoutTheLineOrWithAnUnknownStateReadsAsUnknown() {
        XCTAssertNil(AndroidWakefulness.parse(dumpsysPower: ""))
        XCTAssertNil(AndroidWakefulness.parse(dumpsysPower: "  mWakefulnessChanging=false\n"))
        XCTAssertNil(AndroidWakefulness.parse(dumpsysPower: "  mWakefulness=Sideways\n"))
    }

    func testTheReadFiltersOnTheDevice() async throws {
        let adb = try FakeAdb([
            .init("mWakefulness=", stdoutFile: Self.url("dumpsys-power-wakefulness-asleep.txt")),
        ])
        let state = await adb.client.wakefulness(serial: "emulator-5554")
        XCTAssertEqual(state, .asleep)
        XCTAssertEqual(adb.calls.count, 1)
        XCTAssertTrue(adb.calls[0].contains("-s emulator-5554 shell dumpsys power | grep mWakefulness="), adb.calls[0])
    }

    func testAFailedReadIsUnknown() async throws {
        let adb = try FakeAdb([.init("mWakefulness=", output: "", stderr: "error: device offline", exitCode: 1)])
        let state = await adb.client.wakefulness(serial: "emulator-5554")
        XCTAssertNil(state)
    }

    func testWakingAnEmulatorAlsoDismissesItsLockScreen() async throws {
        let adb = try FakeAdb([])
        try await adb.client.wakeScreen(serial: "emulator-5554", dismissKeyguard: true)
        XCTAssertEqual(adb.calls.count, 2)
        XCTAssertTrue(adb.calls[0].hasSuffix("-s emulator-5554 shell input keyevent 224"), adb.calls[0])
        XCTAssertTrue(adb.calls[1].hasSuffix("-s emulator-5554 shell wm dismiss-keyguard"), adb.calls[1])
    }

    func testWakingAPhoneLeavesItsLockScreen() async throws {
        let adb = try FakeAdb([])
        try await adb.client.wakeScreen(serial: "aqaserial001", dismissKeyguard: false)
        XCTAssertEqual(adb.calls.count, 1)
        XCTAssertTrue(adb.calls[0].hasSuffix("-s aqaserial001 shell input keyevent 224"), adb.calls[0])
        XCTAssertFalse(adb.calls.joined().contains("dismiss-keyguard"))
    }
}
