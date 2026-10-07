import XCTest
@testable import DeviceHubProKit

/// The Status bar rows' commands, scripts, presets and input validation,
/// without a device (the scripts against the captures:
/// `StatusBarDemoDeviceOutputTests`).
final class StatusBarDemoTests: XCTestCase {
    private let prefix = "am broadcast -a com.android.systemui.demo -e command "

    func testCommandRenderings() throws {
        let time = try XCTUnwrap(DemoClockTime(hour: 9, minute: 41))
        let renderings: [(DemoCommand, String)] = [
            (.enter, "enter"),
            (.exit, "exit"),
            (.clock(time), "clock -e hhmm 0941"),
            (.battery(level: 100, plugged: false, powerSave: false), "battery -e level 100 -e plugged false -e powersave false"),
            (.battery(level: 42, plugged: true, powerSave: nil), "battery -e level 42 -e plugged true"),
            (.battery(level: 5, plugged: nil, powerSave: true), "battery -e level 5 -e powersave true"),
            (.battery(level: 50, plugged: nil, powerSave: nil), "battery -e level 50"),
            (.wifi(.bars(4)), "network -e wifi show -e level 4 -e fully true"),
            (.wifi(.bars(1)), "network -e wifi show -e level 1 -e fully true"),
            (.wifi(.hidden), "network -e wifi hide"),
            (.mobile(.signal(level: 4, dataType: .lte)), "network -e mobile show -e datatype lte -e level 4 -e fully true"),
            (.mobile(.signal(level: 2, dataType: .fiveG)), "network -e mobile show -e datatype 5g -e level 2 -e fully true"),
            (.mobile(.hidden), "network -e mobile hide"),
            (.notifications(visible: false), "notifications -e visible false"),
            (.notifications(visible: true), "notifications -e visible true"),
        ]
        for (command, arguments) in renderings {
            XCTAssertEqual(command.shellCommand, prefix + arguments)
        }
    }

    func testClockTimeParsing() throws {
        for (text, hhmm) in [("9:41", "0941"), ("09:41", "0941"), ("0941", "0941"), (" 12:00\n", "1200"), ("23:59", "2359"), ("00:00", "0000")] {
            XCTAssertEqual(DemoClockTime(text: text)?.hhmm, hhmm, text)
        }
        for text in ["24:00", "9:60", "941", "", "  ", "9:4", "123:45", "ab:cd", "09:4x", "12345", "-1:00", "٠٩:٤١"] {
            XCTAssertNil(DemoClockTime(text: text), text)
        }
        XCTAssertNil(DemoClockTime(hour: 24, minute: 0))
        XCTAssertNil(DemoClockTime(hour: 0, minute: 60))

        let nineFortyOne = try XCTUnwrap(DemoClockTime(hour: 9, minute: 41))
        XCTAssertEqual(nineFortyOne.hhmm, "0941")
        XCTAssertEqual(nineFortyOne.label, "9:41")
        XCTAssertEqual(StatusBarDemo.screenshotClock.hhmm, "0941")
        XCTAssertEqual(StatusBarDemo.screenshotClock.label, "9:41")
    }

    func testPresetsPerAPI() {
        // API 37: no mobile demo (hidden), no notifications receiver; the
        // battery comes last so its read-back shows the script was processed.
        XCTAssertEqual(StatusBarPreset.screenshot.commands(apiLevel: 37, handlesNotifications: false), [
            .clock(StatusBarDemo.screenshotClock),
            .wifi(.bars(4)),
            .mobile(.hidden),
            .battery(level: 100, plugged: false, powerSave: false),
        ])
        for preset in [StatusBarPreset.lowBattery, .charging] {
            let commands = preset.commands(apiLevel: 37, handlesNotifications: true)
            XCTAssertNotNil(commands.last?.expectedBattery, "\(preset)")
            XCTAssertFalse(commands.contains { if case .clock = $0 { return true } else { return false } }, "\(preset) keeps the clock")
        }
        XCTAssertEqual(StatusBarPreset.lowBattery.commands(apiLevel: 37, handlesNotifications: false), [
            .wifi(.bars(1)), .mobile(.hidden), .battery(level: 5, plugged: false, powerSave: false),
        ])
        XCTAssertEqual(StatusBarPreset.charging.commands(apiLevel: 37, handlesNotifications: false), [
            .wifi(.bars(2)), .mobile(.hidden), .battery(level: 50, plugged: true, powerSave: false),
        ])

        // API 33: the legacy mobile demo, and notifications where handled.
        XCTAssertEqual(StatusBarPreset.screenshot.commands(apiLevel: 33, handlesNotifications: true), [
            .clock(StatusBarDemo.screenshotClock),
            .wifi(.bars(4)),
            .mobile(.signal(level: 4, dataType: .lte)),
            .battery(level: 100, plugged: false, powerSave: false),
            .notifications(visible: false),
        ])
        XCTAssertEqual(
            StatusBarPreset.lowBattery.commands(apiLevel: 33, handlesNotifications: true)[1],
            .mobile(.signal(level: 1, dataType: .lte))
        )

        // API 29: no 5G option yet.
        XCTAssertFalse(MobileDemoIcon.options(apiLevel: 29).contains(.signal(level: 4, dataType: .fiveG)))
        XCTAssertEqual(MobileDemoIcon.options(apiLevel: 30).map(\.label), ["Full · LTE", "2 bars · LTE", "Full · 5G", "No signal", "Hidden"])

        // API 26 (Android 8.0): no powersave yet; SystemUI reads it from 8.1
        // (`BatteryControllerImpl.java`@android-8.1.0_r1 L212).
        XCTAssertEqual(
            StatusBarPreset.charging.commands(apiLevel: 26, handlesNotifications: true).last,
            .battery(level: 50, plugged: true, powerSave: nil)
        )
        XCTAssertEqual(
            StatusBarPreset.charging.commands(apiLevel: 27, handlesNotifications: true).last,
            .battery(level: 50, plugged: true, powerSave: false)
        )
        XCTAssertEqual(BatteryDemoState.options(apiLevel: 25), [.notCharging, .charging])
        XCTAssertEqual(BatteryDemoState.options(apiLevel: 26), [.notCharging, .charging])
        XCTAssertEqual(BatteryDemoState.options(apiLevel: 27), [.notCharging, .charging, .batterySaver])
        XCTAssertEqual(StatusBarPreset.allCases.map(\.label), ["Screenshot", "Low battery", "Charging"])
    }

    func testMobileOptionsFromAPI34AreHiddenOnly() {
        for api in [34, 35, 36, 37] {
            XCTAssertEqual(MobileDemoIcon.options(apiLevel: api), [.hidden], "API \(api)")
        }
        XCTAssertEqual(MobileDemoIcon.options(apiLevel: 33).count, 5)
        XCTAssertEqual(WifiDemoIcon.options.map(\.label), ["4 bars (full)", "3 bars", "2 bars", "1 bar", "Hidden"])
    }

    func testRestoreKeysPutsBackUnsetKeysByDeleting() {
        let unset = StatusBarDemoOriginal(allowedRaw: nil, onRaw: nil, wasInDemoMode: false)
        XCTAssertEqual(
            StatusBarDemoScript.restoreKeys(original: unset),
            "settings delete global sysui_tuner_demo_on; settings delete global sysui_demo_allowed; true"
        )
        let allowedTwo = StatusBarDemoOriginal(allowedRaw: "2", onRaw: "0", wasInDemoMode: false)
        XCTAssertNil(StatusBarDemoScript.allowedRestore(allowedTwo), "any nonzero value is already allowed")
        XCTAssertEqual(StatusBarDemoScript.restoreKeys(original: allowedTwo), "settings put global sysui_tuner_demo_on 0; true")
        let off = StatusBarDemoOriginal(allowedRaw: "0", onRaw: "0", wasInDemoMode: false)
        XCTAssertEqual(StatusBarDemoScript.allowedRestore(off), "settings put global sysui_demo_allowed 0")
        // A nonzero tuner value without demo mode (API 30 and older) comes
        // back as 0: 1 would enter demo mode on API 31+.
        let tunerOn = StatusBarDemoOriginal(allowedRaw: "0", onRaw: "1", wasInDemoMode: false)
        XCTAssertEqual(StatusBarDemoScript.tunerRestore(tunerOn), "settings put global sysui_tuner_demo_on 0")
        // The only device text in a script is quoted.
        let odd = StatusBarDemoOriginal(allowedRaw: "0; reboot", onRaw: "0", wasInDemoMode: false)
        XCTAssertEqual(StatusBarDemoScript.allowedRestore(odd), "settings put global sysui_demo_allowed '0; reboot'")
    }

    func testExitLeavesAnAllowedDeviceAllowed() {
        let allowed = StatusBarDemoOriginal(allowedRaw: "1", onRaw: "0", wasInDemoMode: true)
        let script = StatusBarDemoScript.exit(
            forceAllow: false,
            realBattery: RealBatteryReading(percent: 80, isPowered: true),
            original: allowed
        )
        XCTAssertEqual(script, [
            prefix + "battery -e level 80 -e plugged true",
            prefix + "exit",
            "settings put global sysui_tuner_demo_on 0",
            "true",
        ].joined(separator: "; "))
        XCTAssertFalse(script.contains("sysui_demo_allowed"))
    }

    func testEnterNeverSendsTheEnterBroadcast() {
        for preset in StatusBarPreset.allCases {
            for api in [23, 30, 33, 37] {
                let script = StatusBarDemoScript.enter(preset.commands(apiLevel: api, handlesNotifications: true))
                XCTAssertTrue(script.hasPrefix("settings put global sysui_tuner_demo_on 1; "), script)
                XCTAssertFalse(script.contains("-e command enter"), script)
                XCTAssertTrue(script.hasSuffix("; true"), script)
            }
        }
        XCTAssertEqual(
            StatusBarDemoScript.send([.wifi(.hidden)]),
            prefix + "network -e wifi hide; true"
        )
    }

    func testBatteryReadBackMatching() {
        let command = DemoCommand.battery(level: 50, plugged: true, powerSave: false)
        XCTAssertTrue(command.batteryApplied(DemoBatteryReading(level: 50, pluggedIn: true, powerSave: false)))
        XCTAssertFalse(command.batteryApplied(DemoBatteryReading(level: 50, pluggedIn: false, powerSave: false)))
        XCTAssertFalse(command.batteryApplied(DemoBatteryReading(level: 5, pluggedIn: true, powerSave: false)))
        // Values left out of the command match anything.
        XCTAssertTrue(
            DemoCommand.battery(level: 50, plugged: nil, powerSave: nil)
                .batteryApplied(DemoBatteryReading(level: 50, pluggedIn: true, powerSave: true))
        )
        XCTAssertEqual(
            DemoBatteryReading(level: 50, pluggedIn: true, powerSave: true).label,
            "50%, charging, battery saver"
        )
        XCTAssertEqual(DemoBatteryReading(level: 100, pluggedIn: false, powerSave: false).label, "100%, not charging")
    }

    func testErrorTexts() {
        XCTAssertEqual(
            StatusBarDemoError.batteryNotApplied(
                shown: DemoBatteryReading(level: 5, pluggedIn: false, powerSave: false),
                expected: DemoBatteryReading(level: 100, pluggedIn: false, powerSave: false)
            ).description,
            "SystemUI shows 5%, not charging instead of 100%, not charging."
        )
        XCTAssertEqual(
            StatusBarDemoError.settingRefused("Bad arguments").description,
            "The device refused settings put global sysui_demo_allowed 1: Bad arguments. Some phones let adb change settings only after an extra Developer options switch."
        )
        XCTAssertEqual(StatusBarDemoError.invalidTime.description, "Enter a time from 00:00 to 23:59.")
        XCTAssertEqual(StatusBarDemoError.invalidBatteryLevel.description, "Enter a level from 0 to 100.")
        XCTAssertEqual(
            StatusBarDemoError.notExited.description,
            "SystemUI is still in demo mode after exit.",
            "no retry promise: only the caller knows whether it keeps a record"
        )
    }

    /// SOURCE-DERIVED: a SettingsProvider refusal's stderr, from
    /// `BasicShellCommandHandler.exec` (modules-utils android-15.0.0_r36 L95
    /// `int res = -1`, hence exit 255; L104–107 print an empty line,
    /// "Exception occurred while executing '<cmd>':" and the stack trace) and
    /// `SettingsProvider.enforceHasAtLeastOnePermission` (android-15.0.0_r36
    /// L2405–2413, called from `mutateGlobalSetting` L1545). No device here
    /// refuses `settings put global`, so no capture exists; the two frames
    /// are `Throwable.printStackTrace`'s tab-`at` lines for those methods.
    func testARefusalKeepsOnlyTheExceptionLine() {
        let stderr = [
            "",
            "Exception occurred while executing 'put':",
            "java.lang.SecurityException: Permission denial, must have one of: [android.permission.WRITE_SECURE_SETTINGS]",
            "\tat com.android.providers.settings.SettingsProvider.enforceHasAtLeastOnePermission(SettingsProvider.java:2412)",
            "\tat com.android.providers.settings.SettingsProvider.mutateGlobalSetting(SettingsProvider.java:1545)",
            "",
        ].joined(separator: "\n")
        let reason = StatusBarDemoError.refusalReason(standardError: stderr)
        XCTAssertEqual(
            reason,
            "java.lang.SecurityException: Permission denial, must have one of: [android.permission.WRITE_SECURE_SETTINGS]"
        )
        XCTAssertFalse(StatusBarDemoError.settingRefused(reason).description.contains("\tat "))
        // Without an exception line: the first line with text.
        XCTAssertEqual(StatusBarDemoError.refusalReason(standardError: "Bad arguments\n"), "Bad arguments")
        XCTAssertEqual(StatusBarDemoError.refusalReason(standardError: "\n  Invalid user: 999\n"), "Invalid user: 999")
        XCTAssertEqual(StatusBarDemoError.refusalReason(standardError: ""), "")
    }

    // MARK: - Put-back

    /// The keys read back as the put-back writes them: the tuner key off,
    /// and the gate off where the put-back writes it.
    func testKeysAreBackOnlyAsThePutBackWritesThem() {
        let foundOff = StatusBarDemoOriginal(allowedRaw: "0", onRaw: "0", wasInDemoMode: false)
        func keys(_ allowed: String?, _ on: String?) -> StatusBarDemoSnapshot {
            StatusBarDemoSnapshot(apiLevel: 37, allowedRaw: allowed, onRaw: on)
        }
        XCTAssertTrue(foundOff.keysAreBack(in: keys("0", "0")))
        XCTAssertTrue(foundOff.keysAreBack(in: keys(nil, nil)), "deleted reads as off")
        XCTAssertFalse(foundOff.keysAreBack(in: keys("1", "0")), "a refused gate write")
        XCTAssertFalse(foundOff.keysAreBack(in: keys("0", "1")), "a refused tuner write")
        let unset = StatusBarDemoOriginal(allowedRaw: nil, onRaw: nil, wasInDemoMode: false)
        XCTAssertTrue(unset.keysAreBack(in: keys(nil, "0")), "SystemUI writes the tuner key 0 itself when the gate closes")
        XCTAssertFalse(unset.keysAreBack(in: keys("1", nil)))
        // A gate found open is not written, so not checked.
        let foundOpen = StatusBarDemoOriginal(allowedRaw: "1", onRaw: "0", wasInDemoMode: false)
        XCTAssertTrue(foundOpen.keysAreBack(in: keys("1", "0")))
        XCTAssertTrue(foundOpen.keysAreBack(in: keys("0", "0")))
    }

    /// A gate found open and closed since, which a put-back opens itself for
    /// its broadcasts, goes back to the closed value read before, and is
    /// checked; any other gate goes back as found.
    func testAGateThePutBackOpensItselfIsClosedAgain() {
        func keys(_ allowed: String?, _ on: String?) -> StatusBarDemoSnapshot {
            StatusBarDemoSnapshot(apiLevel: 37, allowedRaw: allowed, onRaw: on)
        }
        let foundOpen = StatusBarDemoOriginal(allowedRaw: "1", onRaw: "0", wasInDemoMode: false)
        let closed = foundOpen.closingTheGate(as: keys("0", "0"))
        XCTAssertEqual(closed, StatusBarDemoOriginal(allowedRaw: "0", onRaw: "0", wasInDemoMode: false))
        XCTAssertEqual(StatusBarDemoScript.allowedRestore(closed), "settings put global sysui_demo_allowed 0")
        XCTAssertFalse(closed.keysAreBack(in: keys("1", "0")), "the gate the put-back opened is still on")
        XCTAssertTrue(closed.keysAreBack(in: keys("0", "0")))
        let deleted = foundOpen.closingTheGate(as: keys(nil, "0"))
        XCTAssertEqual(StatusBarDemoScript.allowedRestore(deleted), "settings delete global sysui_demo_allowed")
        XCTAssertEqual(foundOpen.closingTheGate(as: keys("1", "0")), foundOpen, "still on: nothing to close")
        let foundOff = StatusBarDemoOriginal(allowedRaw: "0", onRaw: nil, wasInDemoMode: false)
        XCTAssertEqual(foundOff.closingTheGate(as: keys(nil, "0")), foundOff, "found off: back as found")
    }

    /// No DemoModeController section (API 30 and older, or a SystemUI
    /// without the dumpable): the realign and exit, never the gate. Android
    /// 11 needs the realign (SOURCE-DERIVED: android-11.0.0_r48
    /// `BatteryControllerImpl.java` L99–104, L358–361).
    func testTheNoReportRestoreRealignsTheBattery() {
        let original = StatusBarDemoOriginal(allowedRaw: "0", onRaw: "0", wasInDemoMode: false)
        let api30 = StatusBarDemoSnapshot(
            apiLevel: 30,
            allowedRaw: "1",
            onRaw: "1",
            realBattery: RealBatteryReading(percent: 80, isPowered: false)
        )
        XCTAssertEqual(StatusBarDemoScript.restore(for: api30, original: original), [
            prefix + "battery -e level 80 -e plugged false",
            prefix + "exit",
            "settings put global sysui_tuner_demo_on 0",
            "settings put global sysui_demo_allowed 0",
            "true",
        ].joined(separator: "; "))
        XCTAssertFalse(StatusBarDemoScript.needsGate(for: api30, realignBattery: true), "nothing reports the gate")
        // Without a real battery reading there is nothing to send.
        var unread = api30
        unread.realBattery = nil
        XCTAssertEqual(
            StatusBarDemoScript.restore(for: unread, original: original),
            StatusBarDemoScript.exit(forceAllow: false, realBattery: nil, original: original)
        )
    }

    /// API 31–32: SystemUI reports demo mode but not its battery, so a
    /// put-back out of demo mode realigns only when told (Device Hub Pro's demo
    /// mode ended elsewhere), opening the gate first when it is off.
    func testARealignOutOfDemoModeWhereTheBatteryIsUnread() {
        let original = StatusBarDemoOriginal(allowedRaw: "0", onRaw: "0", wasInDemoMode: false)
        let api32 = StatusBarDemoSnapshot(
            apiLevel: 32,
            allowedRaw: "0",
            onRaw: "0",
            realBattery: RealBatteryReading(percent: 100, isPowered: false),
            controller: DemoModeControllerReading(isInDemoMode: false, isAllowed: false)
        )
        XCTAssertEqual(
            StatusBarDemoScript.restore(for: api32, original: original),
            StatusBarDemoScript.restoreKeys(original: original)
        )
        XCTAssertFalse(StatusBarDemoScript.needsGate(for: api32))
        XCTAssertEqual(
            StatusBarDemoScript.restore(for: api32, original: original, realignBattery: true),
            StatusBarDemoScript.exit(forceAllow: true, realBattery: api32.realBattery, original: original)
        )
        XCTAssertTrue(StatusBarDemoScript.needsGate(for: api32, realignBattery: true))
    }

    func testTheStandardSettleIsBoundedInTime() {
        XCTAssertEqual(StatusBarDemoSettle.standard.limit, .seconds(3))
        XCTAssertNil(StatusBarDemoSettle.immediate.limit)
        XCTAssertEqual(StatusBarDemoSettle.immediate.attempts, 1)
    }
}
