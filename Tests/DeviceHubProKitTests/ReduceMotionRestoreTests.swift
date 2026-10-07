import XCTest
@testable import DeviceHubProKit

/// Reduce Motion Off gives back the animation scales the device had instead
/// of stamping 1.0 over them.
final class ReduceMotionRestoreTests: XCTestCase {
    private let serial = "emulator-5600"

    func testScalesAreReadPerKeyWithUnsetKeysNil() async throws {
        let fake = try FakeAdb([
            .init("get global window_animation_scale", output: "0.5\n"),
            .init("get global transition_animation_scale", output: "null\n"),
            .init("get global animator_duration_scale", output: "2.0\n"),
        ])
        let scales = await fake.client.animationScales(serial: serial)
        XCTAssertEqual(scales, .init(values: ["0.5", nil, "2.0"]))
        XCTAssertEqual(scales?.allZero, false)
    }

    func testOffWritesTheRememberedValuesAndDeletesUnsetKeys() async throws {
        let fake = try FakeAdb([])
        try await fake.client.setReduceMotion(
            serial: serial, enabled: false, restoring: .init(values: ["0.5", nil, "2.0"]))
        XCTAssertEqual(fake.calls, [
            "-s \(serial) shell settings put global window_animation_scale 0.5",
            "-s \(serial) shell settings delete global transition_animation_scale",
            "-s \(serial) shell settings put global animator_duration_scale 2.0",
        ])
    }

    func testOffWithoutARecordIsTheStockOne() async throws {
        let fake = try FakeAdb([])
        try await fake.client.setReduceMotion(serial: serial, enabled: false)
        XCTAssertEqual(fake.calls.count, 3)
        XCTAssertTrue(fake.calls.allSatisfy { $0.hasSuffix(" 1.0") })
    }
}
