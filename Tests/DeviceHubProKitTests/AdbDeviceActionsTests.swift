import XCTest
@testable import DeviceHubProKit

/// The phone row's Restart, Collect Bug Report… and Disconnect… argv, run
/// against a fake `adb` (nothing reaches a device).
final class AdbDeviceActionsTests: XCTestCase {
    func testRebootBugReportAndDisconnectUseExplicitSerials() async throws {
        let adb = try FakeAdb([])
        try await adb.client.reboot(serial: "SERIAL1")
        try await adb.client.bugReport(serial: "SERIAL1", into: URL(fileURLWithPath: "/tmp/aqa-bugreport"))
        try await adb.client.disconnect(serial: "192.168.1.5:5555")
        XCTAssertEqual(adb.calls, [
            "-s SERIAL1 reboot",
            "-s SERIAL1 bugreport /tmp/aqa-bugreport",
            "disconnect 192.168.1.5:5555",
        ])
    }

    func testOnlyWirelessSerialsCanBeDisconnected() {
        XCTAssertTrue(AdbClient.isWirelessSerial("192.168.1.5:5555"))
        XCTAssertTrue(AdbClient.isWirelessSerial("adb-R58M123-abcdef._adb-tls-connect._tcp"))
        XCTAssertFalse(AdbClient.isWirelessSerial("R58M123ABC"))
        XCTAssertFalse(AdbClient.isWirelessSerial("emulator-5554"))
    }
}
