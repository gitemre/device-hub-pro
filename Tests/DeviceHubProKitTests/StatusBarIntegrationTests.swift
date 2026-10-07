import XCTest
@testable import DeviceHubProKit

/// SystemUI demo mode against a live emulator, through the Kit: every
/// assertion reads SystemUI's own answer (`dumpsys DemoModeController`, and
/// `BatteryController` on API 33+), never the key a write touched. Each test
/// skips when demo mode is already on (someone else's), records both keys
/// first and puts them back in a teardown block — the Kit's exit, then the
/// raw keys as a backstop — which runs even when an assertion fails. They
/// leave nothing changed; each turns demo mode on for a few seconds.
/// Emulators only (`LiveTestDevices.allowed`, then `isEmulator`): a phone is
/// never touched, even when pinned.
///
/// `DHP_CAPTURE_STATUS_BAR_FIXTURES=<dir>` also writes the probe's and
/// the scripts' commands and outputs there (`testCaptureFixtures`), the
/// source of the `status-bar` fixtures.
final class StatusBarIntegrationTests: XCTestCase {
    private func onlineEmulator() async throws -> (AdbClient, String) {
        guard let adb = AdbClient.locate() else { throw XCTSkip("adb not found") }
        let devices = try await adb.listDevices()
        guard let serial = LiveTestDevices.allowed(devices).first(where: \.isEmulator)?.serial else {
            throw XCTSkip("no online emulator")
        }
        return (adb, serial)
    }

    /// Puts a raw settings value back: nil deletes the key.
    private static func restoreKey(_ adb: AdbClient, _ serial: String, key: String, raw: String?) async throws {
        if let raw {
            _ = try await adb.shell(serial: serial, ["settings", "put", "global", key, AdbClient.shellQuoted(raw)])
        } else {
            _ = try await adb.shell(serial: serial, ["settings", "delete", "global", key])
        }
    }

    /// The device as found, and its put-back scheduled. Skips when demo mode
    /// is on already: it is not this test's to end.
    private func begin(_ adb: AdbClient, _ serial: String) async throws -> (StatusBarDemoSnapshot, StatusBarDemoOriginal) {
        let snapshot = try await adb.statusBarDemo(serial: serial)
        guard !snapshot.isInDemoMode else { throw XCTSkip("demo mode is already on (someone else's)") }
        let original = StatusBarDemoOriginal(allowedRaw: snapshot.allowedRaw, onRaw: snapshot.onRaw, wasInDemoMode: false)
        addTeardownBlock {
            _ = try? await adb.exitStatusBarDemo(serial: serial, original: original)
            // Backstop: the raw keys, the tuner first (while the gate may
            // still be open, so a 1 → 0 ends demo mode).
            try? await Self.restoreKey(adb, serial, key: StatusBarDemo.onKey, raw: original.onRaw)
            try? await Self.restoreKey(adb, serial, key: StatusBarDemo.allowedKey, raw: original.allowedRaw)
        }
        return (snapshot, original)
    }

    /// Probes until `condition` holds or about `seconds` pass; the last probe.
    private func eventually(
        _ adb: AdbClient,
        _ serial: String,
        seconds: Int = 5,
        _ condition: (StatusBarDemoSnapshot) -> Bool
    ) async throws -> StatusBarDemoSnapshot {
        var last = try await adb.statusBarDemo(serial: serial)
        for _ in 0..<(seconds * 4) where !condition(last) {
            try await Task.sleep(for: .milliseconds(250))
            last = try await adb.statusBarDemo(serial: serial)
        }
        return last
    }

    private func requireController(_ snapshot: StatusBarDemoSnapshot) throws {
        guard (snapshot.apiLevel ?? 0) >= StatusBarDemo.controllerMinimumAPI, snapshot.controller != nil else {
            throw XCTSkip("needs SystemUI's DemoModeController dump (API 31+)")
        }
    }

    private func assertKeysAreBack(_ snapshot: StatusBarDemoSnapshot, _ original: StatusBarDemoOriginal, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(snapshot.allowedRaw, original.allowedRaw, "sysui_demo_allowed", file: file, line: line)
        XCTAssertEqual(snapshot.onRaw, original.onRaw == nil ? nil : "0", "sysui_tuner_demo_on", file: file, line: line)
    }

    // MARK: - Reads

    func testTheProbeReadsSystemUI() async throws {
        let (adb, serial) = try await onlineEmulator()
        let snapshot = try await adb.statusBarDemo(serial: serial)
        XCTAssertGreaterThanOrEqual(snapshot.apiLevel ?? 0, StatusBarDemo.minimumAPI)
        XCTAssertNotNil(snapshot.realBattery)
        guard (snapshot.apiLevel ?? 0) >= StatusBarDemo.controllerMinimumAPI else { return }
        let controller = try XCTUnwrap(snapshot.controller, "DemoModeController answers on API 31+")
        for command in ["clock", "battery", "network"] {
            XCTAssertEqual(controller.handles(command), true, command)
        }
        if (snapshot.apiLevel ?? 0) >= StatusBarDemo.batteryReadbackMinimumAPI {
            XCTAssertNotNil(snapshot.systemUIBattery, "BatteryController answers on API 33+")
        }
    }

    // MARK: - Round trips

    func testDemoModeRoundTrip() async throws {
        let (adb, serial) = try await onlineEmulator()
        let (before, original) = try await begin(adb, serial)
        let api = before.apiLevel ?? 0
        if !(before.controller?.isAllowed ?? before.isAllowedKey) {
            try await adb.allowStatusBarDemo(serial: serial)
        }
        let commands = StatusBarPreset.screenshot.commands(apiLevel: api, handlesNotifications: before.handlesNotifications)
        let on = try await adb.enterStatusBarDemo(serial: serial, commands: commands)
        XCTAssertTrue(on.isInDemoMode)
        XCTAssertEqual(on.onRaw, "1")
        if api >= StatusBarDemo.batteryReadbackMinimumAPI {
            XCTAssertEqual(on.systemUIBattery, DemoBatteryReading(level: 100, pluggedIn: false, powerSave: false))
        }

        let off = try await adb.exitStatusBarDemo(serial: serial, original: original)
        XCTAssertFalse(off.isInDemoMode)
        assertKeysAreBack(off, original)
        if api >= StatusBarDemo.batteryReadbackMinimumAPI {
            let settled = try await eventually(adb, serial) { !$0.isBatteryStale }
            XCTAssertFalse(settled.isBatteryStale, "\(String(describing: settled.systemUIBattery)) vs \(String(describing: settled.realBattery))")
        }
    }

    func testTheDemoBatteryIsReadBackAndRealignedAtExit() async throws {
        let (adb, serial) = try await onlineEmulator()
        let (before, original) = try await begin(adb, serial)
        guard (before.apiLevel ?? 0) >= StatusBarDemo.batteryReadbackMinimumAPI, before.systemUIBattery != nil else {
            throw XCTSkip("needs SystemUI's BatteryController dump (API 33+)")
        }
        if !(before.controller?.isAllowed ?? false) {
            try await adb.allowStatusBarDemo(serial: serial)
        }
        let charging = try await adb.enterStatusBarDemo(
            serial: serial,
            commands: [.battery(level: 42, plugged: true, powerSave: false)]
        )
        XCTAssertEqual(charging.systemUIBattery?.level, 42)
        XCTAssertEqual(charging.systemUIBattery?.pluggedIn, true)
        XCTAssertEqual(charging.realBattery, before.realBattery, "apps keep the real battery")

        let saver = try await adb.sendStatusBarDemo(
            serial: serial,
            commands: [.battery(level: 50, plugged: false, powerSave: true)]
        )
        XCTAssertEqual(saver.systemUIBattery, DemoBatteryReading(level: 50, pluggedIn: false, powerSave: true))

        let off = try await adb.exitStatusBarDemo(serial: serial, original: original)
        XCTAssertFalse(off.isInDemoMode)
        let settled = try await eventually(adb, serial) { !$0.isBatteryStale }
        XCTAssertFalse(settled.isBatteryStale, "the exit realigned SystemUI's battery")
        XCTAssertEqual(settled.systemUIBattery?.powerSave, false)
        assertKeysAreBack(settled, original)
    }

    // MARK: - The gate

    /// With Device Hub Pro's enter script (the tuner key at 1), turning the gate
    /// off ends demo mode: SystemUI writes the tuner key 0 itself.
    func testTurningTheGateOffEndsDeviceHubProsDemoMode() async throws {
        let (adb, serial) = try await onlineEmulator()
        let (before, _) = try await begin(adb, serial)
        try requireController(before)
        if !(before.controller?.isAllowed ?? false) {
            try await adb.allowStatusBarDemo(serial: serial)
        }
        // The clock only: no demo battery to leave behind.
        let on = try await adb.enterStatusBarDemo(serial: serial, commands: [.clock(StatusBarDemo.screenshotClock)])
        XCTAssertTrue(on.isInDemoMode)

        _ = try await adb.shell(serial: serial, ["settings", "put", "global", StatusBarDemo.allowedKey, "0"])
        let after = try await eventually(adb, serial) { !$0.isInDemoMode && $0.onRaw == "0" }
        XCTAssertFalse(after.isInDemoMode)
        XCTAssertEqual(after.onRaw, "0")
        XCTAssertFalse(after.isStuck)
    }

    /// The gate turned off under Device Hub Pro's Low battery: SystemUI leaves demo
    /// mode with the demo 5% still on its battery icon, and the Kit's
    /// put-back opens the gate for a moment to realign it.
    func testTheGateTurnedOffLeavesTheDemoBatteryAndThePutBackRealignsIt() async throws {
        let (adb, serial) = try await onlineEmulator()
        let (before, original) = try await begin(adb, serial)
        try requireController(before)
        guard (before.apiLevel ?? 0) >= StatusBarDemo.batteryReadbackMinimumAPI, before.systemUIBattery != nil,
              let real = before.realBattery, real.percent != 5
        else { throw XCTSkip("needs SystemUI's BatteryController dump (API 33+) and a real level other than 5%") }
        if !(before.controller?.isAllowed ?? false) {
            try await adb.allowStatusBarDemo(serial: serial)
        }
        let low = StatusBarPreset.lowBattery.commands(apiLevel: before.apiLevel, handlesNotifications: before.handlesNotifications)
        let on = try await adb.enterStatusBarDemo(serial: serial, commands: low)
        XCTAssertEqual(on.systemUIBattery?.level, 5)

        _ = try await adb.shell(serial: serial, ["settings", "put", "global", StatusBarDemo.allowedKey, "0"])
        let ended = try await eventually(adb, serial) { !$0.isInDemoMode && $0.controller?.isAllowed == false }
        XCTAssertFalse(ended.isInDemoMode)
        XCTAssertEqual(ended.systemUIBattery?.level, 5, "demo mode ended elsewhere leaves the demo level")
        XCTAssertTrue(StatusBarDemoScript.needsGate(for: ended))

        let off = try await adb.exitStatusBarDemo(serial: serial, original: original, expectsController: true)
        XCTAssertFalse(off.isInDemoMode)
        let settled = try await eventually(adb, serial) { !$0.isBatteryStale }
        XCTAssertFalse(settled.isBatteryStale, "the put-back realigned SystemUI's battery")
        XCTAssertFalse(settled.isInDemoMode)
        assertKeysAreBack(settled, original)
    }

    /// The gate on when Device Hub Pro first wrote, then turned off under its Low
    /// battery (as Developer options ▸ Enable demo mode off does): the
    /// realign opens the gate for its broadcasts and closes it again, as it
    /// was left, rather than back on as first found.
    func testTheRealignClosesAGateTurnedOffSinceTheFirstWrite() async throws {
        let (adb, serial) = try await onlineEmulator()
        let (before, _) = try await begin(adb, serial)
        try requireController(before)
        guard (before.apiLevel ?? 0) >= StatusBarDemo.batteryReadbackMinimumAPI, before.systemUIBattery != nil,
              let real = before.realBattery, real.percent != 5
        else { throw XCTSkip("needs SystemUI's BatteryController dump (API 33+) and a real level other than 5%") }
        let open = try await adb.allowStatusBarDemo(serial: serial, expectsController: true)
        let foundOn = StatusBarDemoOriginal(allowedRaw: open.allowedRaw, onRaw: open.onRaw, wasInDemoMode: false)
        XCTAssertNil(StatusBarDemoScript.allowedRestore(foundOn), "the gate was on at the first write")
        let low = StatusBarPreset.lowBattery.commands(apiLevel: before.apiLevel, handlesNotifications: before.handlesNotifications)
        let on = try await adb.enterStatusBarDemo(serial: serial, commands: low, expectsController: true)
        XCTAssertEqual(on.systemUIBattery?.level, 5)

        _ = try await adb.shell(serial: serial, ["settings", "put", "global", StatusBarDemo.allowedKey, "0"])
        let ended = try await eventually(adb, serial) { !$0.isInDemoMode && $0.controller?.isAllowed == false }
        XCTAssertFalse(ended.isInDemoMode)
        XCTAssertEqual(ended.systemUIBattery?.level, 5, "demo mode ended elsewhere leaves the demo level")
        XCTAssertTrue(StatusBarDemoScript.needsGate(for: ended))

        let off = try await adb.exitStatusBarDemo(
            serial: serial,
            original: foundOn,
            realignBattery: true,
            expectsController: true
        )
        XCTAssertFalse(off.isInDemoMode)
        XCTAssertEqual(off.allowedRaw, ended.allowedRaw, "closed again, as it was turned off")
        let settled = try await eventually(adb, serial) { !$0.isBatteryStale }
        XCTAssertFalse(settled.isBatteryStale, "the put-back realigned SystemUI's battery")
        XCTAssertFalse(settled.isInDemoMode)
        XCTAssertEqual(settled.controller?.isAllowed, false, "SystemUI reads the gate closed")
    }

    /// Demo mode another tool entered with the broadcast alone (the tuner key
    /// stays 0), then the gate turned off: stuck, and the Kit's exit ends it.
    func testExitWorksFromBroadcastEnteredDemoModeWithTheGateOff() async throws {
        let (adb, serial) = try await onlineEmulator()
        let (before, original) = try await begin(adb, serial)
        try requireController(before)
        if !(before.controller?.isAllowed ?? false) {
            try await adb.allowStatusBarDemo(serial: serial)
        }
        _ = try await adb.shell(serial: serial, [DemoCommand.enter.shellCommand])
        let entered = try await eventually(adb, serial) { $0.isInDemoMode }
        XCTAssertTrue(entered.isInDemoMode)
        XCTAssertFalse(entered.isOnKey, "the broadcast leaves the tuner key alone")

        _ = try await adb.shell(serial: serial, ["settings", "put", "global", StatusBarDemo.allowedKey, "0"])
        let stuck = try await eventually(adb, serial) { $0.isStuck }
        XCTAssertTrue(stuck.isStuck)

        let off = try await adb.exitStatusBarDemo(serial: serial, original: original)
        XCTAssertFalse(off.isInDemoMode)
        assertKeysAreBack(off, original)
    }

    /// `sysui_tuner_demo_on` = 1 without the gate: SystemUI enters demo mode
    /// anyway and ignores every command; the Kit's exit ends it.
    func testTunerOnWithoutTheGateIsStuckAndExits() async throws {
        let (adb, serial) = try await onlineEmulator()
        let (before, original) = try await begin(adb, serial)
        try requireController(before)
        if before.controller?.isAllowed == true {
            _ = try await adb.shell(serial: serial, ["settings", "put", "global", StatusBarDemo.allowedKey, "0"])
            _ = try await eventually(adb, serial) { $0.controller?.isAllowed == false }
        }
        _ = try await adb.shell(serial: serial, ["settings", "put", "global", StatusBarDemo.onKey, "1"])
        let stuck = try await eventually(adb, serial) { $0.isInDemoMode }
        XCTAssertTrue(stuck.isInDemoMode)
        XCTAssertEqual(stuck.controller?.isAllowed, false)
        XCTAssertTrue(stuck.isStuck)

        let off = try await adb.exitStatusBarDemo(serial: serial, original: original)
        XCTAssertFalse(off.isInDemoMode)
        assertKeysAreBack(off, original)
    }

    /// A leftover record whose device is not in demo mode: the keys alone,
    /// so SystemUI never enters demo mode on the way.
    func testALeftoverRestoreOutsideDemoModeStaysOutOfDemoMode() async throws {
        let (adb, serial) = try await onlineEmulator()
        let (before, original) = try await begin(adb, serial)
        try requireController(before)
        let allowed = try await adb.allowStatusBarDemo(serial: serial)
        XCTAssertFalse(allowed.isInDemoMode)
        XCTAssertEqual(
            StatusBarDemoScript.restore(for: allowed, original: original),
            StatusBarDemoScript.restoreKeys(original: original)
        )

        let restored = try await adb.exitStatusBarDemo(serial: serial, original: original)
        var probes = [restored]
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(250))
            probes.append(try await adb.statusBarDemo(serial: serial))
        }
        XCTAssertFalse(probes.contains(where: \.isInDemoMode), "never in demo mode")
        if let last = probes.last {
            assertKeysAreBack(last, original)
        }
    }

    // MARK: - Fixtures

    /// Writes the `status-bar` fixtures' sources: the probe and each script,
    /// with their outputs, from a device that starts outside demo mode.
    func testCaptureFixtures() async throws {
        guard let path = ProcessInfo.processInfo.environment["DHP_CAPTURE_STATUS_BAR_FIXTURES"], !path.isEmpty else {
            throw XCTSkip("set DHP_CAPTURE_STATUS_BAR_FIXTURES=<dir> to capture")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (adb, serial) = try await onlineEmulator()
        let (before, original) = try await begin(adb, serial)
        let api = before.apiLevel ?? 0

        func write(_ name: String, _ text: String) throws {
            try Data(text.utf8).write(to: directory.appendingPathComponent(name))
        }
        func probe(_ name: String) async throws {
            try write(name, try await adb.shell(serial: serial, [StatusBarDemoSnapshot.probeScript]))
        }
        func run(_ name: String, _ script: String) async throws {
            try write("\(name).command.txt", script)
            try write("\(name).txt", try await adb.shell(serial: serial, [script]))
        }

        try write("probe.command.txt", StatusBarDemoSnapshot.probeScript)
        try await probe("probe-off.txt")
        try await adb.allowStatusBarDemo(serial: serial)
        try await probe("probe-allowed-off.txt")

        let screenshot = StatusBarPreset.screenshot.commands(apiLevel: api, handlesNotifications: before.handlesNotifications)
        try await run("enter-screenshot", StatusBarDemoScript.enter(screenshot))
        _ = try await eventually(adb, serial) { $0.isInDemoMode }
        try await probe("probe-on-screenshot-preset.txt")

        let charging = StatusBarPreset.charging.commands(apiLevel: api, handlesNotifications: before.handlesNotifications)
        try await run("send-charging", StatusBarDemoScript.send(charging))
        _ = try await eventually(adb, serial) { $0.systemUIBattery?.pluggedIn == true }
        try await probe("probe-on-charging-50.txt")

        try await run("send-battery-saver", StatusBarDemoScript.send([.battery(level: 50, plugged: false, powerSave: true)]))
        _ = try await eventually(adb, serial) { $0.systemUIBattery?.powerSave == true }
        try await probe("probe-on-battery-saver-50.txt")

        try await run("send-clock-0941", StatusBarDemoScript.send([.clock(try XCTUnwrap(DemoClockTime(hour: 9, minute: 41)))]))

        let current = try await adb.statusBarDemo(serial: serial)
        try await run("exit-restore", StatusBarDemoScript.restore(for: current, original: original))
        _ = try await eventually(adb, serial) { !$0.isInDemoMode }
        try await probe("probe-off-after-restore.txt")
    }
}
