import XCTest
@testable import DeviceHubProKit

/// The pure state→panel mapping for the canvas (spec §6.4). Device Hub had
/// no unhealthy device to reference, so these panels are Android-designed.
final class CanvasStatusTests: XCTestCase {
    private func physical(_ state: String) -> AndroidDevice {
        AndroidDevice(
            serial: "R58M12345",
            state: state,
            model: "Pixel 8",
            product: "husky",
            device: "husky"
        )
    }

    // MARK: - Booting

    func testBootingAVDResolvesToBooting() {
        let status = CanvasStatus.resolve(
            device: nil,
            isEmulator: true,
            booting: true
        )
        XCTAssertEqual(status, .booting(label: "Starting…"))
    }

    func testDefaultBootingLabelMatchesTheSpec() {
        XCTAssertEqual(CanvasStatus.defaultBootingLabel, "Starting…")
    }

    func testBootingLabelPassesThrough() {
        let status = CanvasStatus.resolve(
            device: nil,
            isEmulator: true,
            booting: true,
            bootingLabel: "Waiting for Android to finish booting…"
        )
        XCTAssertEqual(status, .booting(label: "Waiting for Android to finish booting…"))
    }

    func testBootingWinsOverANonOnlineAdbState() {
        let status = CanvasStatus.resolve(
            device: AndroidDevice(serial: "emulator-5554", state: "offline"),
            isEmulator: true,
            booting: true
        )
        XCTAssertEqual(status, .booting(label: "Starting…"))
    }

    // MARK: - Emulator fall-through

    func testStoppedAVDResolvesToNormal() {
        let status = CanvasStatus.resolve(device: nil, isEmulator: true, booting: false)
        XCTAssertEqual(status, .normal)
    }

    func testEmulatorStatesAreLeftToTheAVDDetail() {
        let status = CanvasStatus.resolve(
            device: AndroidDevice(serial: "emulator-5554", state: "offline"),
            isEmulator: true,
            booting: false
        )
        XCTAssertEqual(status, .normal)
    }

    // MARK: - Physical devices

    func testOfflinePhysicalDeviceIsUnreachable() {
        let status = CanvasStatus.resolve(
            device: physical("offline"),
            isEmulator: false,
            booting: false
        )
        XCTAssertEqual(status, .unreachable)
    }

    func testUnauthorizedPhysicalDeviceAsksForDebuggingApproval() {
        let status = CanvasStatus.resolve(
            device: physical("unauthorized"),
            isEmulator: false,
            booting: false
        )
        XCTAssertEqual(status, .unauthorized)
    }

    func testOnlinePhysicalDeviceKeepsTheNormalDetail() {
        let status = CanvasStatus.resolve(
            device: physical("device"),
            isEmulator: false,
            booting: false
        )
        XCTAssertEqual(status, .normal)
    }

    func testUnknownPhysicalStatesFallBackToUnreachable() {
        for state in ["no permissions", "bootloader", "recovery", "sideload"] {
            let status = CanvasStatus.resolve(
                device: physical(state),
                isEmulator: false,
                booting: false
            )
            XCTAssertEqual(status, .unreachable, "state \(state)")
        }
    }

    func testNoDeviceAndNotBootingIsNormal() {
        let status = CanvasStatus.resolve(device: nil, isEmulator: false, booting: false)
        XCTAssertEqual(status, .normal)
    }
}
