import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

final class DeviceSettingsPanelModelTests: XCTestCase {
    // MARK: - Group order, defaults and gating

    private func fullAvailability() -> ControlsGroupAvailability {
        var available = ControlsGroupAvailability()
        available.canUseEmulatorControls = true
        available.appearance = true
        available.textSize = true
        available.reduceMotion = true
        available.increaseContrast = true
        available.showBorders = true
        available.talkBack = true
        available.colorFilter = true
        available.sound = true
        available.forceRTL = true
        available.showTaps = true
        available.backgroundANRs = true
        available.fingerprint = true
        available.dataSaver = true
        available.deviceLanguage = true
        available.dateTime = true
        available.timeZone = true
        available.timeFormat24 = true
        available.networkConditions = true
        available.shaping = true
        available.appConditions = true
        available.lowMemory = true
        available.links = true
        available.statusBar = true
        return available
    }

    func testGroupOrderFollowsTheDesignedIA() {
        XCTAssertEqual(
            controlsGroups(fullAvailability()).map(\.id),
            [
                .network, .appConditions, .power, .location,
                .languageAndTime, .displayAndSound, .accessibility,
                .debugAndInput, .biometrics,
            ]
        )
    }

    /// The Fingerprint touch is a Biometrics group of its own, last, and only where the
    /// emulator's console answers (the Device menu's Simulate ▸ Fingerprint Touch has the same gate).
    func testFingerprintIsAnEmulatorOnlyBiometricsRow() {
        let group = controlsGroups(fullAvailability()).last
        XCTAssertEqual(group?.id, .biometrics)
        XCTAssertEqual(group?.rows, [.fingerprint])
        XCTAssertEqual(ControlsGroupID.biometrics.title, "Biometrics")
        var phone = fullAvailability()
        phone.fingerprint = false
        XCTAssertFalse(controlsGroups(phone).contains { $0.id == .biometrics })
    }

    /// The enum lists its cases in display order, as its doc says: every
    /// group shows with full availability, in `allCases` order.
    func testGroupIDsAreDeclaredInDisplayOrder() {
        XCTAssertEqual(controlsGroups(fullAvailability()).map(\.id), ControlsGroupID.allCases)
    }

    func testPassGroupsAreCollapsedByDefault() {
        for id in ControlsGroupID.allCases {
            let expected = ![
                ControlsGroupID.displayAndSound, .accessibility, .debugAndInput,
                .appConditions, .biometrics,
            ].contains(id)
            XCTAssertEqual(id.defaultExpanded, expected, "\(id)")
        }
    }

    /// Every Android row, once; the iOS-only rows never (a simulator's
    /// panel lists them, `AppleControlsControllerTests`).
    func testEveryRowAppearsExactlyOnceWithFullAvailability() {
        let rows = controlsGroups(fullAvailability()).flatMap(\.rows) + controlsTrailingRows(fullAvailability())
        let android = ControlsRow.allCases.filter { $0.platforms.contains(.android) }
        XCTAssertEqual(rows.count, android.count)
        XCTAssertEqual(Set(rows), Set(android))
        XCTAssertTrue(Set(rows).isDisjoint(with: ControlsRow.iosOnly))
    }

    /// The URL row is a plain row at the bottom (no Links group), above Clean status bar.
    func testTheLinkURLRowIsAPlainRowAboveCleanStatusBar() {
        XCTAssertEqual(controlsTrailingRows(fullAvailability()), [.linkURL, .cleanStatusBar])
        var noDevice = fullAvailability()
        noDevice.links = false
        XCTAssertEqual(controlsTrailingRows(noDevice), [.cleanStatusBar])
    }

    func testNetworkRowsFollowTheDesignedOrder() {
        let network = controlsGroups(fullAvailability()).first { $0.id == .network }
        XCTAssertEqual(
            network?.rows,
            [.wifi, .bluetooth, .airplaneMode, .mobileData, .dataSaver,
             .networkSpeed, .connectionLatency, .meteredMobileData, .resetConditions]
        )
    }

    func testLanguageAndTimeRowsFollowTheDesignedOrder() {
        let group = controlsGroups(fullAvailability()).first { $0.id == .languageAndTime }
        XCTAssertEqual(
            group?.rows,
            [.deviceLanguage, .forceRTL, .dateTime, .timeZone, .timeFormat24]
        )
        XCTAssertEqual(ControlsGroupID.languageAndTime.title, "Language & time")
        XCTAssertTrue(ControlsGroupID.languageAndTime.defaultExpanded)
    }

    func testAccessibilityRowsFollowTheDesignedOrder() {
        let group = controlsGroups(fullAvailability()).first { $0.id == .accessibility }
        XCTAssertEqual(
            group?.rows,
            [.talkBack, .colorFilter, .increaseContrast],
            "Device Hub puts its color filter picker just before Increase Contrast"
        )
    }

    func testColorFilterRowsShowOnAnyDevice() {
        var available = ControlsGroupAvailability()
        available.colorFilter = true
        // No emulator needed: a phone shows them too.
        XCTAssertEqual(controlsGroups(available).first { $0.id == .accessibility }?.rows, [.colorFilter])
    }

    func testLanguageAndTimeFollowsItsProbesOnAnyDevice() {
        var available = ControlsGroupAvailability()
        available.dateTime = true
        available.timeFormat24 = true
        // No emulator needed: the group shows on a phone too, with only the
        // rows its probe found.
        let group = controlsGroups(available).first { $0.id == .languageAndTime }
        XCTAssertEqual(group?.rows, [.dateTime, .timeFormat24])
        XCTAssertEqual(controlsGroups(available).map(\.id), [.network, .power, .languageAndTime])
    }

    func testProbeGatedRowsDisappearIndividually() {
        var available = fullAvailability()
        available.showTaps = false
        let rows = controlsGroups(available).flatMap(\.rows)
        XCTAssertFalse(rows.contains(.showTaps))
        XCTAssertTrue(rows.contains(.backgroundANRs))
    }

    func testEmptySettingsGroupsAreOmitted() {
        var available = ControlsGroupAvailability()
        XCTAssertEqual(
            controlsGroups(available).map(\.id),
            [.network, .power]
        )

        available.showBorders = true
        XCTAssertTrue(controlsGroups(available).map(\.id).contains(.displayAndSound))
    }

    func testEmulatorGroupsNeedAnEmulator() {
        var available = fullAvailability()
        available.canUseEmulatorControls = false
        let ids = controlsGroups(available).map(\.id)
        XCTAssertFalse(ids.contains(.location))
    }

    // MARK: - Appearance popup

    func testAppearancePopupSelectionForEveryMode() {
        for mode in AppearanceMode.allCases {
            let model = appearancePopupModel(for: .mode(mode))
            XCTAssertEqual(model.selectableModes, AppearanceMode.allCases)
            XCTAssertEqual(model.selection, mode)
            XCTAssertNil(model.placeholderTitle)
            XCTAssertTrue(model.help.isEmpty)
        }
    }

    func testAppearancePopupKeepsCustomPlaceholderAndRawToken() {
        let model = appearancePopupModel(for: .unmapped("custom_schedule"))

        XCTAssertEqual(model.selectableModes, AppearanceMode.allCases)
        XCTAssertNil(model.selection)
        XCTAssertEqual(model.placeholderTitle, "Custom")
        XCTAssertTrue(model.help.contains("custom_schedule"))
    }

    func testAppearancePopupMarksUnknownForUnreadableAndNil() {
        for reading: AppearanceReading? in [.unreadable, nil] {
            let model = appearancePopupModel(for: reading)
            XCTAssertEqual(model.selectableModes, AppearanceMode.allCases)
            XCTAssertNil(model.selection)
            XCTAssertEqual(model.placeholderTitle, "Unknown")
        }
    }

    // MARK: - Toggle effects

    func testLiveAndKeyDrivenTogglesShowNoCaption() {
        XCTAssertEqual(toggleRowStatus(for: nil), .plain)
        XCTAssertEqual(toggleRowStatus(for: ToggleEffect(reading: .on, support: .live)), .plain)
    }

    func testAnAfterRestartToggleSaysWhenItLands() {
        let settled = toggleRowStatus(for: ToggleEffect(reading: .off, support: .afterRestart))
        XCTAssertEqual(settled.caption, "Applies after the device restarts.")
        XCTAssertEqual(settled.accessibilityStatus, "applies after the device restarts")
    }

    func testAPendingRestartShowsTheKitNote() {
        let pending = toggleRowStatus(for: ToggleEffect(
            reading: .on,
            support: .afterRestart,
            isPending: true,
            note: "Force RTL applies after the device restarts."
        ))
        XCTAssertEqual(pending.caption, "Restart pending: Force RTL applies after the device restarts.")
        XCTAssertEqual(pending.accessibilityStatus, "restart pending")
    }

    // MARK: - Battery saver

    func testBatterySaverIsAPlainSwitchWithoutACharger() {
        let row = batterySaverRowModel(
            saverEnabled: true,
            effect: ToggleEffect(reading: .on, support: .live),
            devicePowered: false,
            emulatorCharging: false
        )
        XCTAssertEqual(row, BatterySaverRowModel(value: true, isEnabled: true, caption: nil, offersChargingOff: false))
    }

    func testBatterySaverIsDisabledWhileTheEmulatorCharges() {
        let note = "Battery saver can't turn on while the device is charging."
        let row = batterySaverRowModel(
            saverEnabled: false,
            effect: ToggleEffect(reading: .off, support: .live, note: note),
            devicePowered: true,
            emulatorCharging: true
        )
        XCTAssertEqual(row, BatterySaverRowModel(value: false, isEnabled: false, caption: note, offersChargingOff: true))
    }

    func testTheEmulatorChargerWinsOverAStaleBatteryDump() {
        // Charging was just switched on through gRPC; the next effects poll
        // has not landed, so the dump still says unplugged and saver on.
        let justPlugged = batterySaverRowModel(
            saverEnabled: true,
            effect: ToggleEffect(reading: .on, support: .live),
            devicePowered: false,
            emulatorCharging: true
        )
        XCTAssertEqual(justPlugged.value, false, "Android turns saver off on a charger")
        XCTAssertFalse(justPlugged.isEnabled)
        XCTAssertNotNil(justPlugged.caption)

        // And the other way round: Turn Charging Off enables the row at once.
        let justUnplugged = batterySaverRowModel(
            saverEnabled: false,
            effect: nil,
            devicePowered: true,
            emulatorCharging: false
        )
        XCTAssertTrue(justUnplugged.isEnabled)
        XCTAssertNil(justUnplugged.caption)
    }

    func testAPhysicalDeviceOnACableCannotTurnChargingOffFromHere() {
        let row = batterySaverRowModel(
            saverEnabled: false,
            effect: nil,
            devicePowered: true,
            emulatorCharging: nil
        )
        XCTAssertFalse(row.isEnabled)
        XCTAssertFalse(row.offersChargingOff, "only an emulator's charger is a setting")
        XCTAssertEqual(row.caption, "Battery saver can't turn on while the device is charging.")
    }

    func testAnUnreadBatterySaverStaysUnknownAndDisabled() {
        let row = batterySaverRowModel(saverEnabled: nil, effect: nil, devicePowered: nil, emulatorCharging: nil)
        XCTAssertNil(row.value)
        XCTAssertFalse(row.isEnabled)
    }
}
