import XCTest
@testable import DeviceHubProApp

/// Device-menu enablement that depends on the focused model's private state.
/// The visual states need the app frontmost (morning capture pass); the logic
/// lives in pure helpers so it stays pinned here.
@MainActor
final class MenuStateTests: XCTestCase {
    func testStopEmulatorIsEnabledForEmulatorSerials() {
        XCTAssertTrue(AppModel.canStopActiveEmulator(activeSerial: "emulator-5554"))
        XCTAssertTrue(AppModel.canStopActiveEmulator(activeSerial: "emulator-5556"))
    }

    func testStopEmulatorIsDisabledForPhysicalDevices() {
        XCTAssertFalse(AppModel.canStopActiveEmulator(activeSerial: "FCA44402"))
        XCTAssertFalse(AppModel.canStopActiveEmulator(activeSerial: "192.168.1.5:5555"))
    }

    func testStopEmulatorIsDisabledWithoutAnActiveDevice() {
        XCTAssertFalse(AppModel.canStopActiveEmulator(activeSerial: nil))
    }
}
