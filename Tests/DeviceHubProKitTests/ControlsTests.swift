import XCTest
@testable import DeviceHubProKit

final class ControlsTests: XCTestCase {
    func testSavedLocationRoundTrip() throws {
        let locations = SavedLocation.defaults
        let data = try JSONEncoder().encode(locations)
        let decoded = try JSONDecoder().decode([SavedLocation].self, from: data)

        XCTAssertEqual(decoded, locations)
        XCTAssertEqual(decoded.first?.name, "Ankara")
        XCTAssertEqual(decoded.map(\.name), ["Ankara", "İstanbul", "İzmir", "Paris", "New York"])
        XCTAssertEqual(decoded.count, 5)
    }

    func testPostureMapping() {
        XCTAssertEqual(PostureKind.from(protobufValue: 1), .closed)
        XCTAssertEqual(PostureKind.from(protobufValue: 2), .halfOpened)
        XCTAssertEqual(PostureKind.from(protobufValue: 3), .opened)
        XCTAssertNil(PostureKind.from(protobufValue: 0))
        XCTAssertNil(PostureKind.from(protobufValue: 4))
        XCTAssertEqual(PostureKind.closed.hingeAngle, 0)
        XCTAssertEqual(PostureKind.halfOpened.hingeAngle, 90)
        XCTAssertEqual(PostureKind.opened.hingeAngle, 180)
    }

    func testInnerOuterDisplaySelection() {
        var state = DeviceControlsState()
        state.displays = [
            DisplayInfo(id: 0, width: 1080, height: 2424, dpi: 390),
            DisplayInfo(id: 1, width: 2076, height: 2152, dpi: 390),
        ]

        XCTAssertEqual(state.innerDisplay?.id, 1)
        XCTAssertEqual(state.outerDisplay?.id, 0)
        // Two displays alone do not make a device foldable (e.g. an extra
        // virtual display), but a half-opened posture does.
        XCTAssertFalse(state.isFoldable)

        var single = DeviceControlsState()
        single.displays = [DisplayInfo(id: 0, width: 1080, height: 2340, dpi: 440)]
        XCTAssertNil(single.outerDisplay)
        XCTAssertFalse(single.isFoldable)
    }

    func testFoldabilityIsDrivenByHingePosture() {
        var state = DeviceControlsState()

        state.posture = .closed
        XCTAssertFalse(state.isFoldable, "a non-foldable also reports a closed posture")
        state.posture = .opened
        XCTAssertFalse(state.isFoldable)
        state.posture = .halfOpened
        XCTAssertTrue(state.isFoldable)

        // Posture and hinge angle are answered by every emulator, so they must
        // not be enough on their own.
        var flat = DeviceControlsState()
        flat.hingeAngle = 0
        XCTAssertFalse(flat.isFoldable)
    }

    func testAppearanceProbeCountsOnlyCommandFailures() {
        var probe = AppearanceProbe()
        XCTAssertTrue(probe.isAvailable)

        // An answered read proves the command exists, even when the mode has
        // no Light/Dark/System counterpart — the row must stay.
        for _ in 0..<10 {
            probe.record(.success(.unmapped("custom_schedule")))
        }
        XCTAssertTrue(probe.isAvailable)
        XCTAssertEqual(probe.consecutiveFailures, 0)

        // A failing command counts, and the row hides after the limit.
        for _ in 0..<AppearanceProbe.failureLimit {
            probe.record(.failure(AdbError.adbNotFound))
        }
        XCTAssertFalse(probe.isAvailable)
        XCTAssertEqual(probe.consecutiveFailures, AppearanceProbe.failureLimit)

        // Any answer — even an unrepresentable one — clears the streak.
        probe.record(.success(.unmapped("custom_bedtime")))
        XCTAssertTrue(probe.isAvailable)

        // A transient failure between answers never hides the row.
        probe.record(.failure(AdbError.adbNotFound))
        probe.record(.success(.mode(.dark)))
        XCTAssertEqual(probe.consecutiveFailures, 0)
        XCTAssertTrue(probe.isAvailable)
    }

    // MARK: - Battery

    private func battery(
        level: Int32 = 80,
        charger: Android_Emulation_Control_BatteryState.BatteryCharger = .ac,
        status: Android_Emulation_Control_BatteryState.BatteryStatus = .charging,
        health: Android_Emulation_Control_BatteryState.BatteryHealth = .overheated,
        hasBattery: Bool = true
    ) -> Android_Emulation_Control_BatteryState {
        .with {
            $0.hasBattery_p = hasBattery
            $0.isPresent = hasBattery
            $0.chargeLevel = level
            $0.charger = charger
            $0.status = status
            $0.health = health
        }
    }

    func testBatteryLevelChangeKeepsChargerAndHealth() throws {
        let next = try XCTUnwrap(BatteryUpdate.state(from: battery(), level: 42, charging: true))
        XCTAssertEqual(next.chargeLevel, 42)
        XCTAssertEqual(next.charger, .ac, "an AC charger must not become USB")
        XCTAssertEqual(next.status, .charging)
        XCTAssertEqual(next.health, .overheated, "a simulated health state survives the slider")
        XCTAssertTrue(next.isPresent)
    }

    func testUnpluggingDropsOnlyTheCharger() throws {
        let next = try XCTUnwrap(BatteryUpdate.state(from: battery(), level: 80, charging: false))
        XCTAssertEqual(next.charger, .none)
        XCTAssertEqual(next.status, .discharging)
        XCTAssertEqual(next.health, .overheated)
    }

    func testPluggingInFromNoChargerUsesTheEmulatorsACDefault() throws {
        let unplugged = battery(charger: .none, status: .discharging)
        let next = try XCTUnwrap(BatteryUpdate.state(from: unplugged, level: 50, charging: true))
        XCTAssertEqual(next.charger, .ac)
        XCTAssertEqual(next.status, .charging)

        let wireless = battery(charger: .wireless, status: .notCharging)
        XCTAssertEqual(
            BatteryUpdate.state(from: wireless, level: 50, charging: true)?.charger,
            .wireless
        )
    }

    func testAFullBatteryMovedBelow100IsChargingAgain() throws {
        let full = battery(level: 100, status: .full)
        XCTAssertEqual(BatteryUpdate.state(from: full, level: 100, charging: true)?.status, .full)
        XCTAssertEqual(BatteryUpdate.state(from: full, level: 70, charging: true)?.status, .charging)
    }

    func testAnEmulatorWithoutABatteryIsLeftAlone() {
        XCTAssertNil(BatteryUpdate.state(from: battery(hasBattery: false), level: 100, charging: true))
    }

    func testBatteryLevelIsClamped() {
        XCTAssertEqual(BatteryUpdate.state(from: battery(), level: 140, charging: true)?.chargeLevel, 100)
        XCTAssertEqual(BatteryUpdate.state(from: battery(), level: -5, charging: true)?.chargeLevel, 0)
    }

    func testAppearanceProbeResetOnDeviceSwitch() {
        var probe = AppearanceProbe()
        probe.record(.failure(AdbError.adbNotFound))
        probe.record(.failure(AdbError.adbNotFound))
        probe.reset()
        probe.record(.failure(AdbError.adbNotFound))

        XCTAssertEqual(probe.consecutiveFailures, 1, "a device switch must not inherit old failures")
        XCTAssertTrue(probe.isAvailable)
    }
}
