import XCTest
@testable import DeviceHubProKit

/// The Status bar writes against a stub adb that answers with the API 37
/// captures (`Fixtures/api37-emulator/status-bar`). Arms that stand for a
/// write answer as the device did; a state directory lets a later probe
/// answer with the capture taken after that write.
final class StatusBarDemoCommandTests: XCTestCase {
    private let serial = "emulator-5554"

    private var probeCall: String { "-s \(serial) shell \(StatusBarDemoSnapshot.probeScript)" }
    private var allowCall: String { "-s \(serial) shell settings put global sysui_demo_allowed 1" }
    private var original: StatusBarDemoOriginal { StatusBarDemoOriginal(allowedRaw: "0", onRaw: "0", wasInDemoMode: false) }

    private func shellCall(_ fixture: String) throws -> String {
        "-s \(serial) shell " + (try StatusBarAPI37Fixture.text(fixture))
    }

    func testAllowWritesTheKeyAndWaitsForSystemUI() async throws {
        let adb = try StatusBarStubAdb { stub in
            """
              "-s \(serial) shell settings put global sysui_demo_allowed 1")
                cat \(stub.fixture("settings-put-sysui_demo_allowed-1.txt")) ;;
              *"echo @@devicehubpro:sb:api"*)
                cat \(stub.fixture("probe-allowed-off.txt")) ;;
            """
        }
        let snapshot = try await adb.client.allowStatusBarDemo(serial: serial)
        XCTAssertEqual(snapshot.controller?.isAllowed, true)
        XCTAssertEqual(adb.calls, [allowCall, probeCall])
    }

    func testAGateSystemUIDoesNotTakeIsReported() async throws {
        let adb = try StatusBarStubAdb { stub in
            """
              *"echo @@devicehubpro:sb:api"*)
                cat \(stub.fixture("probe-off.txt")) ;;
            """
        }
        do {
            try await adb.client.allowStatusBarDemo(serial: serial, settle: StatusBarDemoSettle(attempts: 2, delay: .zero))
            XCTFail("a gate SystemUI does not report must throw")
        } catch let error as StatusBarDemoError {
            XCTAssertEqual(error, .notAllowed)
        }
        XCTAssertEqual(adb.calls, [allowCall, probeCall, probeCall])
    }

    /// The device's `settings` tool failing (exit 255, reason on stderr) is a
    /// refusal; adb's own failure (exit 1) is not.
    func testARefusedSettingIsReported() async throws {
        let refused = try StatusBarStubAdb { stub in
            """
              "-s \(serial) shell settings put global sysui_demo_allowed 1")
                cat \(stub.fixture("settings-put-missing-value.stderr.txt")) >&2; exit 255 ;;
            """
        }
        do {
            try await refused.client.allowStatusBarDemo(serial: serial)
            XCTFail("a refusal must throw")
        } catch let error as StatusBarDemoError {
            XCTAssertEqual(error, .settingRefused("Bad arguments"))
        }
        XCTAssertEqual(refused.calls, [allowCall], "nothing is read back after a refusal")

        let gone = try StatusBarStubAdb { _ in
            """
              "-s \(serial) shell settings put global sysui_demo_allowed 1")
                printf 'adb: device offline\\n' >&2; exit 1 ;;
            """
        }
        do {
            try await gone.client.allowStatusBarDemo(serial: serial)
            XCTFail("a transport failure must throw")
        } catch let error as AdbError {
            guard case .commandFailed(_, let exitCode, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(exitCode, 1)
        }
    }

    func testEnterReadsBackDemoModeAndTheBattery() async throws {
        let screenshot = StatusBarPreset.screenshot.commands(apiLevel: 37, handlesNotifications: false)
        func stub(probe: String) throws -> StatusBarStubAdb {
            try StatusBarStubAdb { stub in
                """
                  "-s \(self.serial) shell settings put global sysui_tuner_demo_on 1; "*)
                    cat \(stub.fixture("enter-screenshot.txt")) ;;
                  *"echo @@devicehubpro:sb:api"*)
                    cat \(stub.fixture(probe)) ;;
                """
            }
        }

        let entered = try stub(probe: "probe-on-screenshot-preset.txt")
        let snapshot = try await entered.client.enterStatusBarDemo(serial: serial, commands: screenshot)
        XCTAssertTrue(snapshot.isInDemoMode)
        XCTAssertEqual(entered.calls, [try shellCall("enter-screenshot.command.txt"), probeCall])

        let ignored = try stub(probe: "probe-allowed-off.txt")
        do {
            try await ignored.client.enterStatusBarDemo(serial: serial, commands: screenshot, settle: .immediate)
            XCTFail("demo mode SystemUI does not report must throw")
        } catch let error as StatusBarDemoError {
            XCTAssertEqual(error, .notEntered)
        }

        let otherBattery = try stub(probe: "probe-on-low-battery.txt")
        do {
            try await otherBattery.client.enterStatusBarDemo(serial: serial, commands: screenshot, settle: .immediate)
            XCTFail("a battery SystemUI does not show must throw")
        } catch let error as StatusBarDemoError {
            XCTAssertEqual(error, .batteryNotApplied(
                shown: DemoBatteryReading(level: 5, pluggedIn: false, powerSave: false),
                expected: DemoBatteryReading(level: 100, pluggedIn: false, powerSave: false)
            ))
        }
    }

    /// Stuck (demo mode with the gate off): the gate is opened and confirmed
    /// before `exit`, which SystemUI would ignore otherwise; the script still
    /// carries the put (it is built from the probe before).
    func testExitFromTheStuckStateAllowsFirst() async throws {
        let adb = try StatusBarStubAdb { stub in
            """
              "-s \(self.serial) shell settings put global sysui_demo_allowed 1")
                touch \(stub.flag("allowed")) ;;
              "-s \(self.serial) shell settings put global sysui_demo_allowed 1; am broadcast "*)
                touch \(stub.flag("exited")); cat \(stub.fixture("exit-restore-stuck.txt")) ;;
              *"echo @@devicehubpro:sb:api"*)
                if [ -f \(stub.flag("exited")) ]; then cat \(stub.fixture("probe-off-after-stuck-restore.txt"))
                elif [ -f \(stub.flag("allowed")) ]; then cat \(stub.fixture("probe-on-stuck-after-allow.txt"))
                else cat \(stub.fixture("probe-on-not-allowed-stuck.txt")); fi ;;
            """
        }
        let after = try await adb.client.exitStatusBarDemo(serial: serial, original: original)
        XCTAssertFalse(after.isInDemoMode)
        XCTAssertEqual(adb.calls, [
            probeCall,
            allowCall,
            probeCall,
            try shellCall("exit-restore-stuck.command.txt"),
            probeCall,
        ])
    }

    /// Not in demo mode: the keys alone, no broadcast (a battery realign
    /// would enter demo mode while the gate is 1), read back until they are.
    func testExitOutsideDemoModeOnlyPutsBackTheKeys() async throws {
        let adb = try StatusBarStubAdb { stub in
            """
              "-s \(self.serial) shell settings put global sysui_tuner_demo_on 0; "*)
                touch \(stub.flag("restored")); cat \(stub.fixture("exit-keys-only.txt")) ;;
              *"echo @@devicehubpro:sb:api"*)
                if [ -f \(stub.flag("restored")) ]; then cat \(stub.fixture("probe-off-after-restore.txt"))
                else cat \(stub.fixture("probe-allowed-off.txt")); fi ;;
            """
        }
        let after = try await adb.client.exitStatusBarDemo(serial: serial, original: original)
        XCTAssertEqual(adb.calls, [probeCall, try shellCall("exit-keys-only.command.txt"), probeCall])
        XCTAssertFalse(adb.calls.contains { $0.contains("am broadcast") })
        XCTAssertTrue(original.keysAreBack(in: after))
    }

    /// The scripts end with `true`, so a refused `settings` write exits 0:
    /// the keys are read back, the put-back is tried once more, and
    /// `keysNotRestored` is thrown (the caller keeps its record).
    func testKeysThatDoNotComeBackAreReported() async throws {
        let adb = try StatusBarStubAdb { stub in
            """
              *"echo @@devicehubpro:sb:api"*)
                cat \(stub.fixture("probe-allowed-off.txt")) ;;
            """
        }
        do {
            try await adb.client.exitStatusBarDemo(serial: serial, original: original, settle: .immediate)
            XCTFail("keys that did not come back must throw")
        } catch let error as StatusBarDemoError {
            XCTAssertEqual(error, .keysNotRestored)
        }
        let keys = try shellCall("exit-keys-only.command.txt")
        XCTAssertEqual(adb.calls, [probeCall, keys, probeCall, keys, probeCall])
    }

    /// Demo mode ended elsewhere (the gate turned off) with SystemUI's
    /// battery left at the demo 5%: the gate is opened and confirmed, then
    /// the realign, `exit` and the keys.
    func testExitRealignsABatteryDemoModeLeftBehind() async throws {
        let adb = try StatusBarStubAdb { stub in
            """
              "-s \(self.serial) shell settings put global sysui_demo_allowed 1")
                touch \(stub.flag("allowed")) ;;
              "-s \(self.serial) shell settings put global sysui_demo_allowed 1; am broadcast "*)
                touch \(stub.flag("realigned")); cat \(stub.fixture("exit-realign-stale.txt")) ;;
              *"echo @@devicehubpro:sb:api"*)
                if [ -f \(stub.flag("realigned")) ]; then cat \(stub.fixture("probe-off-after-realign.txt"))
                elif [ -f \(stub.flag("allowed")) ]; then cat \(stub.fixture("probe-off-stale-battery-5-allowed.txt"))
                else cat \(stub.fixture("probe-off-stale-battery-5.txt")); fi ;;
            """
        }
        let after = try await adb.client.exitStatusBarDemo(serial: serial, original: original)
        XCTAssertFalse(after.isBatteryStale)
        XCTAssertEqual(adb.calls, [
            probeCall,
            allowCall,
            probeCall,
            try shellCall("exit-realign-stale.command.txt"),
            probeCall,
        ])
    }

    /// The same realign where the gate was on at Device Hub Pro's first write and
    /// turned off since (Developer options ▸ Enable demo mode off ends demo
    /// mode and leaves the demo 5%): the gate the realign opens for its
    /// broadcasts closes again, as the probe before read it, rather than
    /// staying on as first found; a gate still on after that is not back.
    func testARealignClosesAGateTurnedOffSinceTheFirstWrite() async throws {
        let foundOn = StatusBarDemoOriginal(allowedRaw: "1", onRaw: "0", wasInDemoMode: false)
        func stub(realignedProbe: String) throws -> StatusBarStubAdb {
            try StatusBarStubAdb { stub in
                """
                  "-s \(self.serial) shell settings put global sysui_demo_allowed 1")
                    touch \(stub.flag("allowed")) ;;
                  "-s \(self.serial) shell settings put global sysui_demo_allowed 1; am broadcast "*)
                    touch \(stub.flag("realigned")); cat \(stub.fixture("exit-realign-stale.txt")) ;;
                  *"echo @@devicehubpro:sb:api"*)
                    if [ -f \(stub.flag("realigned")) ]; then cat \(stub.fixture(realignedProbe))
                    elif [ -f \(stub.flag("allowed")) ]; then cat \(stub.fixture("probe-off-stale-battery-5-allowed.txt"))
                    else cat \(stub.fixture("probe-off-stale-battery-5.txt")); fi ;;
                """
            }
        }
        let realign = try shellCall("exit-realign-stale.command.txt")

        let closes = try stub(realignedProbe: "probe-off-after-realign.txt")
        let after = try await closes.client.exitStatusBarDemo(
            serial: serial,
            original: foundOn,
            realignBattery: true,
            expectsController: true
        )
        XCTAssertFalse(after.isBatteryStale)
        XCTAssertFalse(after.isAllowedKey, "closed again")
        XCTAssertEqual(closes.calls, [probeCall, allowCall, probeCall, realign, probeCall])

        // The gate write refused (the scripts end with `true`): the second
        // try closes it again too, then `keysNotRestored`.
        let staysOn = try stub(realignedProbe: "probe-allowed-off.txt")
        do {
            try await staysOn.client.exitStatusBarDemo(
                serial: serial,
                original: foundOn,
                realignBattery: true,
                expectsController: true,
                settle: .immediate
            )
            XCTFail("a gate left on must not read as back")
        } catch let error as StatusBarDemoError {
            XCTAssertEqual(error, .keysNotRestored)
        }
        XCTAssertEqual(staysOn.calls, [
            probeCall, allowCall, probeCall, realign, probeCall, try shellCall("exit-keys-only.command.txt"), probeCall,
        ])
    }

    /// The stuck state's gate not taking: the keys go back (best effort)
    /// before the error, so the gate Device Hub Pro wrote does not stay at 1.
    func testAForcedGateThatDoesNotTakePutsTheKeysBack() async throws {
        let adb = try StatusBarStubAdb { stub in
            """
              *"echo @@devicehubpro:sb:api"*)
                cat \(stub.fixture("probe-on-not-allowed-stuck.txt")) ;;
            """
        }
        do {
            try await adb.client.exitStatusBarDemo(serial: serial, original: original, settle: .immediate)
            XCTFail("a gate SystemUI does not take must throw")
        } catch let error as StatusBarDemoError {
            XCTAssertEqual(error, .notAllowed)
        }
        XCTAssertEqual(adb.calls, [probeCall, allowCall, probeCall, try shellCall("exit-keys-only.command.txt")])
    }

    /// A SystemUI that reported `DemoModeController` and prints nothing now
    /// did not answer: with `expectsController` its probe is taken again,
    /// a read-back is not settled by it, and an exit never runs the
    /// no-report script. The silent probe is `probe-on-screenshot-preset.txt`
    /// cut before its `controller` marker (a byte trim of the capture), as
    /// seen once on emulator-5556 while other sessions used it.
    func testASilentSystemUIIsNotTrusted() async throws {
        let full = try StatusBarAPI37Fixture.text("probe-on-screenshot-preset.txt")
        let marker = try XCTUnwrap(full.range(of: "@@devicehubpro:sb:controller\n"))
        func stub(answersAfter silentProbes: Int?) throws -> StatusBarStubAdb {
            let adb = try StatusBarStubAdb { stub in
                let silent = AdbClient.shellQuoted(stub.state.appendingPathComponent("silent.txt").path)
                let count = AdbClient.shellQuoted(stub.state.appendingPathComponent("count").path)
                let limit = silentProbes.map(String.init) ?? "1000000"
                return """
                  "-s \(self.serial) shell am broadcast "*)
                    cat \(stub.fixture("send-clock-0941.txt")) ;;
                  *"echo @@devicehubpro:sb:api"*)
                    printf x >> \(count)
                    if [ "$(wc -c < \(count) | tr -d ' ')" -le \(limit) ]; then cat \(silent)
                    else cat \(stub.fixture("probe-on-screenshot-preset.txt")); fi ;;
                """
            }
            try Data(full[..<marker.lowerBound].utf8).write(to: adb.directory.appendingPathComponent("silent.txt"))
            return adb
        }
        let settle = StatusBarDemoSettle(attempts: 3, delay: .zero)

        let once = try stub(answersAfter: 1)
        let answered = try await once.client.statusBarDemo(serial: serial, expectsController: true, settle: settle)
        XCTAssertNotNil(answered.controller)
        XCTAssertEqual(once.calls, [probeCall, probeCall])
        let trusted = try stub(answersAfter: 1)
        let silent = try await trusted.client.statusBarDemo(serial: serial, expectsController: false, settle: settle)
        XCTAssertNil(silent.controller, "without the expectation one probe is trusted")

        let clock = try XCTUnwrap(DemoClockTime(hour: 9, minute: 41))
        let mute = try stub(answersAfter: nil)
        do {
            try await mute.client.sendStatusBarDemo(serial: serial, commands: [.clock(clock)], expectsController: true, settle: settle)
            XCTFail("a silent SystemUI must not settle a read-back")
        } catch let error as StatusBarDemoError {
            XCTAssertEqual(error, .systemUINotAnswering)
        }
        let muteExit = try stub(answersAfter: nil)
        do {
            try await muteExit.client.exitStatusBarDemo(serial: serial, original: original, expectsController: true, settle: settle)
            XCTFail("a silent SystemUI must not choose the no-report script")
        } catch let error as StatusBarDemoError {
            XCTAssertEqual(error, .systemUINotAnswering)
        }
        XCTAssertEqual(muteExit.calls, [probeCall, probeCall, probeCall], "no script ran")
    }

    /// The settle budget is a time limit too: a slow probe that never
    /// settles stops once the limit has passed, however many attempts are
    /// left.
    func testTheSettleLimitBoundsSlowProbes() async throws {
        let adb = try StatusBarStubAdb { stub in
            """
              *"echo @@devicehubpro:sb:api"*)
                sleep 0.2; cat \(stub.fixture("probe-off.txt")) ;;
            """
        }
        let started = ContinuousClock.now
        do {
            try await adb.client.allowStatusBarDemo(
                serial: serial,
                settle: StatusBarDemoSettle(attempts: 50, delay: .zero, limit: .milliseconds(500))
            )
            XCTFail("a gate SystemUI does not report must throw")
        } catch let error as StatusBarDemoError {
            XCTAssertEqual(error, .notAllowed)
        }
        let elapsed = ContinuousClock.now - started
        XCTAssertLessThan(elapsed, .seconds(2))
        let probes = adb.calls.filter { $0 == probeCall }.count
        XCTAssertGreaterThanOrEqual(probes, 2)
        XCTAssertLessThanOrEqual(probes, 4, "the limit, not the 50 attempts")
    }

    /// SystemUI still in demo mode after the exit: one more try from the last
    /// probe, then `notExited`.
    func testAnExitSystemUIIgnoresIsTriedOnceMore() async throws {
        let adb = try StatusBarStubAdb { stub in
            """
              *"echo @@devicehubpro:sb:api"*)
                cat \(stub.fixture("probe-on-screenshot-preset.txt")) ;;
            """
        }
        do {
            try await adb.client.exitStatusBarDemo(serial: serial, original: original, settle: .immediate)
            XCTFail("an exit SystemUI ignored must throw")
        } catch let error as StatusBarDemoError {
            XCTAssertEqual(error, .notExited)
        }
        let exitScript = try shellCall("exit-restore.command.txt")
        XCTAssertEqual(adb.calls, [probeCall, exitScript, probeCall, exitScript, probeCall])
    }

    func testSendReadsBackTheBattery() async throws {
        let charging = StatusBarPreset.charging.commands(apiLevel: 37, handlesNotifications: false)
        func stub(probe: String) throws -> StatusBarStubAdb {
            try StatusBarStubAdb { stub in
                """
                  "-s \(self.serial) shell am broadcast "*)
                    cat \(stub.fixture("send-charging.txt")) ;;
                  *"echo @@devicehubpro:sb:api"*)
                    cat \(stub.fixture(probe)) ;;
                """
            }
        }

        let taken = try stub(probe: "probe-on-charging-50.txt")
        let snapshot = try await taken.client.sendStatusBarDemo(serial: serial, commands: charging)
        XCTAssertEqual(snapshot.systemUIBattery, DemoBatteryReading(level: 50, pluggedIn: true, powerSave: false))
        XCTAssertEqual(taken.calls, [try shellCall("send-charging.command.txt"), probeCall])

        let mismatch = try stub(probe: "probe-on-low-battery.txt")
        do {
            try await mismatch.client.sendStatusBarDemo(serial: serial, commands: charging, settle: .immediate)
            XCTFail("a battery SystemUI does not show must throw")
        } catch let error as StatusBarDemoError {
            XCTAssertEqual(error, .batteryNotApplied(
                shown: DemoBatteryReading(level: 5, pluggedIn: false, powerSave: false),
                expected: DemoBatteryReading(level: 50, pluggedIn: true, powerSave: false)
            ))
        }

        let ended = try stub(probe: "probe-off.txt")
        do {
            try await ended.client.sendStatusBarDemo(serial: serial, commands: charging, settle: .immediate)
            XCTFail("a command outside demo mode must throw")
        } catch let error as StatusBarDemoError {
            XCTAssertEqual(error, .notInDemoMode)
        }
    }

    func testAProbeWithoutAnAPILevelThrows() async throws {
        let adb = try StatusBarStubAdb { _ in
            """
              *"echo @@devicehubpro:sb:api"*)
                printf '@@devicehubpro:sb:api\\n' ;;
            """
        }
        do {
            _ = try await adb.client.statusBarDemo(serial: serial)
            XCTFail("an unreadable API level must throw")
        } catch is AdbError {}
    }
}

/// A fake adb whose arms are `case "$*" in` branches, written with the
/// stub's `fixture(_:)` (a status-bar capture) and `flag(_:)` (a file in its
/// state directory) paths. Every call is logged; unmatched calls exit 0
/// silently.
final class StatusBarStubAdb {
    let client: AdbClient
    let directory: URL
    private let callsURL: URL

    init(arms: (StatusBarStubAdb.Paths) -> String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusBarStubAdb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        callsURL = directory.appendingPathComponent("calls.log")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(callsURL.path)"
        case "$*" in
        \(arms(Paths(state: directory)))
          *) exit 0 ;;
        esac
        exit 0
        """
        let adbURL = directory.appendingPathComponent("adb")
        try Data(script.utf8).write(to: adbURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adbURL.path)
        client = AdbClient(adbURL: adbURL)
    }

    deinit {
        // Best effort: a leftover temporary directory must not fail a test.
        try? FileManager.default.removeItem(at: directory)
    }

    struct Paths {
        let state: URL

        func fixture(_ name: String) -> String {
            AdbClient.shellQuoted(StatusBarAPI37Fixture.url(name).path)
        }

        func flag(_ name: String) -> String {
            AdbClient.shellQuoted(state.appendingPathComponent("flag-\(name)").path)
        }
    }

    var calls: [String] {
        ((try? String(contentsOf: callsURL, encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .map(String.init)
    }
}
