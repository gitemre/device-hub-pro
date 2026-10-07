import XCTest
@testable import DeviceHubProKit

/// Byte-exact device output under `Fixtures/api37-emulator/status-bar`,
/// captured from emulator-5556 (AVD Pixel_9_Pro, google/sdk_gphone16k_arm64,
/// Android 17, API 37 / sdk_full 37.1, build CP31.260623.012, Google
/// SystemUI) on 2026-09-25 in three runs: the research run (20:06–20:34),
/// the spec review (20:52–21:01), whose `enter-*`, `probe-on-screenshot-
/// preset`, `probe-on-low-battery`, `exit-keys-only`, `probe-on-by-tuner-
/// gate-off`, `probe-on-stuck-after-allow` and `settings-put-missing-value`
/// captures replace the first run's (its enter script no longer sent
/// `enter`), and the review fixes (22:32: Low battery, then the gate turned
/// off, then the realign put-back: `probe-off-stale-battery-5*`,
/// `exit-realign-stale*`, `probe-off-after-realign`). No personal
/// identifiers are in them. Each `X.command.txt` is the script exactly as the
/// Kit builds it (no trailing newline); `X.txt` is its standard output.
enum StatusBarAPI37Fixture {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/api37-emulator/status-bar", isDirectory: true)

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static func text(_ name: String) throws -> String {
        let data = try Data(contentsOf: url(name))
        return try XCTUnwrap(String(data: data, encoding: .utf8), "\(name) is UTF-8")
    }

    static func snapshot(_ name: String) throws -> StatusBarDemoSnapshot {
        StatusBarDemoSnapshot.parse(try text(name))
    }
}

/// The Status bar parsers and scripts fed that output. Every expected value
/// is read off the capture itself; none is computed by the parser under test.
final class StatusBarDemoDeviceOutputTests: XCTestCase {
    private let original = StatusBarDemoOriginal(allowedRaw: "0", onRaw: "0", wasInDemoMode: false)
    private let demoCallback = "DemoModeController$demoFlowForCommand$1$callback$1"

    // MARK: - Scripts

    /// The fixtures are the output of the current scripts: a script change
    /// needs a recapture.
    func testTheFixturesComeFromTheCurrentScripts() throws {
        func fixture(_ name: String) throws -> String { try StatusBarAPI37Fixture.text(name) }
        XCTAssertEqual(try fixture("probe.command.txt"), StatusBarDemoSnapshot.probeScript)
        XCTAssertEqual(
            try fixture("enter-screenshot.command.txt"),
            StatusBarDemoScript.enter(StatusBarPreset.screenshot.commands(apiLevel: 37, handlesNotifications: false))
        )
        XCTAssertEqual(
            try fixture("enter-low-battery.command.txt"),
            StatusBarDemoScript.enter(StatusBarPreset.lowBattery.commands(apiLevel: 37, handlesNotifications: false))
        )
        XCTAssertEqual(
            try fixture("send-charging.command.txt"),
            StatusBarDemoScript.send(StatusBarPreset.charging.commands(apiLevel: 37, handlesNotifications: false))
        )
        XCTAssertEqual(
            try fixture("send-battery-saver.command.txt"),
            StatusBarDemoScript.send([.battery(level: 50, plugged: false, powerSave: true)])
        )
        XCTAssertEqual(
            try fixture("send-clock-0941.command.txt"),
            StatusBarDemoScript.send([.clock(try XCTUnwrap(DemoClockTime(hour: 9, minute: 41)))])
        )
        XCTAssertEqual(
            try fixture("exit-restore.command.txt"),
            StatusBarDemoScript.restore(for: try StatusBarAPI37Fixture.snapshot("probe-on-screenshot-preset.txt"), original: original)
        )
        XCTAssertEqual(
            try fixture("exit-restore-stuck.command.txt"),
            StatusBarDemoScript.restore(for: try StatusBarAPI37Fixture.snapshot("probe-on-not-allowed-stuck.txt"), original: original)
        )
        XCTAssertEqual(
            try fixture("exit-keys-only.command.txt"),
            StatusBarDemoScript.restore(for: try StatusBarAPI37Fixture.snapshot("probe-allowed-off.txt"), original: original)
        )
        // Out of demo mode with SystemUI's battery left at the demo 5%: the
        // realign and exit, the gate opened first.
        XCTAssertEqual(
            try fixture("exit-realign-stale.command.txt"),
            StatusBarDemoScript.restore(for: try StatusBarAPI37Fixture.snapshot("probe-off-stale-battery-5.txt"), original: original)
        )
        // What the device printed for the keys before the first run.
        XCTAssertEqual(try fixture("settings-get-demo-keys-original.txt"), "0\n0\n")
    }

    // MARK: - Probes

    func testTheOffProbe() throws {
        let snapshot = try StatusBarAPI37Fixture.snapshot("probe-off.txt")
        XCTAssertEqual(snapshot.apiLevel, 37)
        XCTAssertEqual(snapshot.allowedRaw, "0")
        XCTAssertEqual(snapshot.onRaw, "0")
        XCTAssertEqual(snapshot.realBattery, RealBatteryReading(percent: 100, isPowered: false))
        let controller = try XCTUnwrap(snapshot.controller)
        XCTAssertFalse(controller.isInDemoMode)
        XCTAssertFalse(controller.isAllowed)
        XCTAssertEqual(controller.receivers["clock"], ["StatusBarDemoMode"])
        XCTAssertEqual(controller.receivers["battery"], ["BatteryControllerImplGoogle"])
        XCTAssertEqual(controller.receivers["notifications"], [])
        XCTAssertEqual(controller.receivers["status"], ["StatusBarIconControllerImpl"])
        XCTAssertEqual(controller.receivers["volume"], ["VolumeDialogComponent"])
        XCTAssertEqual(controller.receivers["network"], ["MobileContextProvider", demoCallback, demoCallback, demoCallback])
        XCTAssertEqual(controller.handles("notifications"), false)
        XCTAssertNil(controller.handles("wallpaper"), "not listed")
        XCTAssertFalse(snapshot.handlesNotifications)
        XCTAssertEqual(snapshot.systemUIBattery, DemoBatteryReading(level: 100, pluggedIn: false, powerSave: false))
        XCTAssertFalse(snapshot.isInDemoMode)
        XCTAssertFalse(snapshot.isStuck)
        XCTAssertTrue(snapshot.reportsDemoMode)
    }

    func testAllowedButOff() throws {
        let snapshot = try StatusBarAPI37Fixture.snapshot("probe-allowed-off.txt")
        XCTAssertEqual(snapshot.controller?.isAllowed, true)
        XCTAssertEqual(snapshot.controller?.isInDemoMode, false)
        XCTAssertEqual(snapshot.allowedRaw, "1")
        XCTAssertTrue(snapshot.isAllowedKey)
        XCTAssertFalse(snapshot.isInDemoMode)
    }

    func testTheScreenshotPreset() throws {
        let snapshot = try StatusBarAPI37Fixture.snapshot("probe-on-screenshot-preset.txt")
        XCTAssertTrue(snapshot.isInDemoMode)
        XCTAssertEqual(snapshot.onRaw, "1")
        XCTAssertEqual(snapshot.systemUIBattery, DemoBatteryReading(level: 100, pluggedIn: false, powerSave: false))
        XCTAssertEqual(snapshot.controller?.receivers["clock"], ["StatusBarDemoMode", demoCallback])
        XCTAssertEqual(snapshot.controller?.receivers["notifications"], [], "no receiver in demo mode either")
        XCTAssertFalse(snapshot.isStuck)
    }

    func testLowBatteryChargingAndSaver() throws {
        let readings: [(String, DemoBatteryReading)] = [
            ("probe-on-low-battery.txt", DemoBatteryReading(level: 5, pluggedIn: false, powerSave: false)),
            ("probe-on-charging-50.txt", DemoBatteryReading(level: 50, pluggedIn: true, powerSave: false)),
            ("probe-on-battery-saver-50.txt", DemoBatteryReading(level: 50, pluggedIn: false, powerSave: true)),
        ]
        for (name, battery) in readings {
            let snapshot = try StatusBarAPI37Fixture.snapshot(name)
            XCTAssertTrue(snapshot.isInDemoMode, name)
            XCTAssertEqual(snapshot.systemUIBattery, battery, name)
            XCTAssertEqual(snapshot.realBattery, RealBatteryReading(percent: 100, isPowered: false), "\(name): apps keep the real battery")
        }
    }

    func testDemoModeSomeoneElseStarted() throws {
        let snapshot = try StatusBarAPI37Fixture.snapshot("probe-on-by-broadcast-tuner-off.txt")
        XCTAssertTrue(snapshot.isInDemoMode)
        XCTAssertEqual(snapshot.onRaw, "0")
        XCTAssertFalse(snapshot.isOnKey)
        XCTAssertFalse(snapshot.isStuck)
    }

    func testTheStuckStates() throws {
        // Entered by the broadcast alone, then the gate turned off.
        let broadcast = try StatusBarAPI37Fixture.snapshot("probe-on-not-allowed-stuck.txt")
        XCTAssertTrue(broadcast.isStuck)
        XCTAssertEqual(broadcast.allowedRaw, "0")
        XCTAssertEqual(broadcast.onRaw, "0")
        // sysui_tuner_demo_on = 1 written without the gate: demo mode anyway.
        let tuner = try StatusBarAPI37Fixture.snapshot("probe-on-by-tuner-gate-off.txt")
        XCTAssertTrue(tuner.isStuck)
        XCTAssertTrue(tuner.isOnKey)
        XCTAssertFalse(tuner.isAllowedKey)
        // Once the gate is back, commands (and exit) work again.
        let allowed = try StatusBarAPI37Fixture.snapshot("probe-on-stuck-after-allow.txt")
        XCTAssertFalse(allowed.isStuck)
        XCTAssertTrue(allowed.isInDemoMode)
    }

    /// Demo mode ended elsewhere (here the gate turned off under Device Hub Pro's
    /// Low battery) leaves SystemUI's battery at the demo 5%; the realign
    /// put-back brings it back to the real 100%.
    func testDemoModeEndedElsewhereLeavesTheDemoBattery() throws {
        let stale = try StatusBarAPI37Fixture.snapshot("probe-off-stale-battery-5.txt")
        XCTAssertFalse(stale.isInDemoMode)
        XCTAssertEqual(stale.controller?.isAllowed, false)
        XCTAssertEqual(stale.onRaw, "0", "SystemUI wrote the tuner key 0 when the gate closed")
        XCTAssertEqual(stale.systemUIBattery, DemoBatteryReading(level: 5, pluggedIn: false, powerSave: false))
        XCTAssertEqual(stale.realBattery, RealBatteryReading(percent: 100, isPowered: false))
        XCTAssertTrue(stale.isBatteryStale)
        XCTAssertTrue(stale.batteryNeedsRealign(whenUnread: false), "SystemUI reports it: the reading decides")
        XCTAssertTrue(StatusBarDemoScript.needsGate(for: stale), "the realign's broadcasts need the gate")

        let allowed = try StatusBarAPI37Fixture.snapshot("probe-off-stale-battery-5-allowed.txt")
        XCTAssertEqual(allowed.controller?.isAllowed, true)
        XCTAssertFalse(allowed.isInDemoMode)
        XCTAssertTrue(allowed.isBatteryStale)
        XCTAssertFalse(StatusBarDemoScript.needsGate(for: allowed))

        let after = try StatusBarAPI37Fixture.snapshot("probe-off-after-realign.txt")
        XCTAssertFalse(after.isInDemoMode)
        XCTAssertFalse(after.isBatteryStale, "realigned")
        XCTAssertEqual(after.systemUIBattery, DemoBatteryReading(level: 100, pluggedIn: false, powerSave: false))
        XCTAssertTrue(original.keysAreBack(in: after))
        XCTAssertFalse(original.keysAreBack(in: allowed), "the gate is still open there")

        let answer = "Broadcasting: Intent { act=com.android.systemui.demo flg=0x400000 (has extras) }\nBroadcast completed: result=0\n"
        XCTAssertEqual(try StatusBarAPI37Fixture.text("exit-realign-stale.txt"), String(repeating: answer, count: 2))
    }

    func testAfterRestore() throws {
        for name in ["probe-off-after-restore.txt", "probe-off-after-stuck-restore.txt"] {
            let snapshot = try StatusBarAPI37Fixture.snapshot(name)
            XCTAssertFalse(snapshot.isInDemoMode, name)
            XCTAssertEqual(snapshot.controller?.isAllowed, false, name)
            XCTAssertEqual(snapshot.allowedRaw, "0", name)
            XCTAssertEqual(snapshot.onRaw, "0", name)
            XCTAssertEqual(snapshot.realBattery, RealBatteryReading(percent: 100, isPowered: false), name)
            XCTAssertEqual(snapshot.systemUIBattery, DemoBatteryReading(level: 100, pluggedIn: false, powerSave: false), "\(name): realigned")
        }
    }

    // MARK: - Full dumps

    func testFullDumpsParseLikeTheProbe() throws {
        func controller(_ name: String) throws -> DemoModeControllerReading? {
            DemoModeControllerReading.parse(try StatusBarAPI37Fixture.text(name))
        }
        let off = try XCTUnwrap(try controller("dumpsys-DemoModeController-off-not-allowed.txt"))
        XCTAssertFalse(off.isInDemoMode)
        XCTAssertFalse(off.isAllowed)
        // Taken before the run's first demo mode: one network receiver. The
        // later probes also list the demo flows' three callbacks.
        XCTAssertEqual(off.receivers["network"], ["MobileContextProvider"])
        XCTAssertEqual(off.receivers["notifications"], [])
        XCTAssertEqual(
            Set(off.receivers.keys),
            Set(try XCTUnwrap(try StatusBarAPI37Fixture.snapshot("probe-off.txt").controller).receivers.keys),
            "the probe's grep keeps every command"
        )
        let afterEnter = try XCTUnwrap(try controller("dumpsys-DemoModeController-after-enter-not-allowed.txt"))
        XCTAssertFalse(afterEnter.isInDemoMode, "enter is ignored while the gate is off")
        XCTAssertFalse(afterEnter.isAllowed)
        let broadcast = try XCTUnwrap(try controller("dumpsys-DemoModeController-on-by-broadcast.txt"))
        XCTAssertTrue(broadcast.isInDemoMode)
        XCTAssertTrue(broadcast.isAllowed)
        XCTAssertEqual(broadcast.receivers.count, 8, "the receivers=[…] line is not a command")
        XCTAssertNil(broadcast.receivers["receivers"])
        let restarted = try XCTUnwrap(try controller("dumpsys-DemoModeController-after-emulator-restart.txt"))
        XCTAssertTrue(restarted.isAllowed, "sysui_demo_allowed outlives the emulator process")
        XCTAssertFalse(restarted.isInDemoMode)
        XCTAssertEqual(restarted.receivers["network"], ["MobileContextProvider"])

        XCTAssertNil(try controller("dumpsys-systemui-unknown-target.txt"), "an unknown target prints only the header")
        XCTAssertNil(DemoBatteryReading.parse(try StatusBarAPI37Fixture.text("dumpsys-systemui-unknown-target.txt")))

        XCTAssertEqual(
            DemoBatteryReading.parse(try StatusBarAPI37Fixture.text("dumpsys-BatteryController-demo-42-plugged.txt")),
            DemoBatteryReading(level: 42, pluggedIn: true, powerSave: false)
        )
        XCTAssertEqual(
            DemoBatteryReading.parse(try StatusBarAPI37Fixture.text("dumpsys-BatteryController-off.txt")),
            DemoBatteryReading(level: 100, pluggedIn: false, powerSave: false)
        )
        XCTAssertEqual(
            RealBatteryReading.parse(try StatusBarAPI37Fixture.text("dumpsys-battery.txt")),
            RealBatteryReading(percent: 100, isPowered: false)
        )
    }

    /// `am broadcast` answers the same whether SystemUI took the command or
    /// ignored it: the read-back is the only proof.
    func testBroadcastsAnswerAlikeWhetherTakenOrNot() throws {
        let answer = "Broadcasting: Intent { act=com.android.systemui.demo flg=0x400000 (has extras) }\nBroadcast completed: result=0\n"
        XCTAssertEqual(try StatusBarAPI37Fixture.text("am-broadcast-enter-not-allowed.txt"), answer, "ignored: the gate was off")
        XCTAssertEqual(try StatusBarAPI37Fixture.text("am-broadcast-exit-not-allowed.txt"), answer, "ignored: the gate was off")
        XCTAssertEqual(try StatusBarAPI37Fixture.text("enter-screenshot.txt"), String(repeating: answer, count: 4), "taken")
        XCTAssertEqual(try StatusBarAPI37Fixture.text("exit-restore.txt"), String(repeating: answer, count: 2))
        XCTAssertEqual(try StatusBarAPI37Fixture.text("exit-keys-only.txt"), "", "settings put prints nothing")
        XCTAssertEqual(try StatusBarAPI37Fixture.text("settings-put-sysui_demo_allowed-1.txt"), "")
    }

    /// Stands in for API 30 and older and a vendor SystemUI without the
    /// dumpable: `probe-off.txt` with its `controller` and `battery` sections
    /// trimmed (a byte trim of the capture; everything before
    /// `@@devicehubpro:sb:controller` is kept as captured).
    func testAProbeWithoutSystemUISections() throws {
        let full = try StatusBarAPI37Fixture.text("probe-off.txt")
        let marker = try XCTUnwrap(full.range(of: "@@devicehubpro:sb:controller\n"))
        let snapshot = StatusBarDemoSnapshot.parse(String(full[..<marker.lowerBound]))
        XCTAssertEqual(snapshot.apiLevel, 37)
        XCTAssertNil(snapshot.controller)
        XCTAssertNil(snapshot.systemUIBattery)
        XCTAssertFalse(snapshot.reportsDemoMode)
        XCTAssertFalse(snapshot.isInDemoMode, "from sysui_tuner_demo_on")
        XCTAssertTrue(snapshot.handlesNotifications, "unknown, so the row stays usable")
        XCTAssertFalse(snapshot.isStuck)
        // The realign and exit without the gate: Android 11 re-registers its
        // battery receiver with no sticky replay as 12+ do (SOURCE-DERIVED:
        // android-11.0.0_r48 BatteryControllerImpl.java L99–104, L358–361).
        XCTAssertEqual(
            StatusBarDemoScript.restore(for: snapshot, original: original),
            StatusBarDemoScript.exit(
                forceAllow: false,
                realBattery: RealBatteryReading(percent: 100, isPowered: false),
                original: original
            )
        )
        XCTAssertTrue(snapshot.answers(expectingController: false))
        XCTAssertFalse(snapshot.answers(expectingController: true), "API 37: a SystemUI that reported before did not answer")

        var tunerOn = snapshot
        tunerOn.onRaw = "1"
        XCTAssertTrue(tunerOn.isInDemoMode, "the key stands for SystemUI's answer")
    }

    /// SOURCE-DERIVED: the Android 12–14 dump format, from
    /// `DemoModeController.kt`@android-12.0.0_r34 L179–198 and
    /// @android-14.0.0_r75 L208–224 (`"$cmd : ["` + each receiver's
    /// `simpleName` + `","` + `"]"`, with a space before the bracket). No
    /// image of those releases may be booted for a capture here.
    func testTheAndroid12To14DumpFormat() throws {
        let text = "      isInDemoMode=true\n      isDemoModeAllowed=true\n    bars : [StatusBarDemoMode ]\n    notifications : [NotificationIconAreaController ]\n    battery : [BatteryControllerImpl ]\n"
        let reading = try XCTUnwrap(DemoModeControllerReading.parse(text))
        XCTAssertTrue(reading.isInDemoMode)
        XCTAssertTrue(reading.isAllowed)
        XCTAssertEqual(reading.handles("notifications"), true)
        XCTAssertEqual(reading.receivers["bars"], ["StatusBarDemoMode"])
        XCTAssertEqual(reading.receivers["battery"], ["BatteryControllerImpl"])

        let empty = try XCTUnwrap(DemoModeControllerReading.parse("      isInDemoMode=false\n    notifications : [ ]\n"))
        XCTAssertEqual(empty.receivers["notifications"], [])
        XCTAssertEqual(empty.handles("notifications"), false)
        XCTAssertFalse(empty.isAllowed, "a missing isDemoModeAllowed= reads as not allowed")
    }
}
