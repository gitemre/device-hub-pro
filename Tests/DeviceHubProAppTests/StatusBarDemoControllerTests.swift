import XCTest
import DeviceHubProKit
@testable import DeviceHubProApp

/// The Status bar group against a stub adb that answers with the API 37
/// emulator captures (`DeviceHubProKitTests/Fixtures/api37-emulator/status-bar`).
/// The probe arm answers with the capture of the state the write arms left
/// (flags in a state directory), as `DeviceConditionsControllerTests` does.
/// The stub's serial is a placeholder: no device is addressed.
@MainActor
final class StatusBarDemoControllerTests: XCTestCase {
    private static let serial = "emulator-5554"
    /// A same-length placeholder for a USB phone's serial.
    private static let phoneSerial = "0A1B2C3D4E5F"
    private static let avd = "Pixel_9_Pro"

    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("DeviceHubProKitTests/Fixtures/api37-emulator/status-bar")

    private static func fixture(_ name: String) -> String {
        AdbClient.shellQuoted(fixtures.appendingPathComponent(name).path)
    }

    private static func fixtureText(_ name: String) throws -> String {
        try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8)
    }

    /// `adb-core/emu-avd-name.txt`, which names this AVD.
    private static let consoleAvd = "Pixel_9_Pro_Fold"
    private static var avdNameCall: String { "-s \(serial) emu avd name" }

    private static func coreFixture(_ name: String) -> String {
        AdbClient.shellQuoted(
            fixtures.deletingLastPathComponent().appendingPathComponent("adb-core").appendingPathComponent(name).path
        )
    }

    private static var probeCall: String { "-s \(serial) shell \(StatusBarDemoSnapshot.probeScript)" }
    private static var allowCall: String { "-s \(serial) shell settings put global sysui_demo_allowed 1" }

    private static func scriptCall(_ fixture: String, serial: String = StatusBarDemoControllerTests.serial) throws -> String {
        "-s \(serial) shell " + (try fixtureText(fixture))
    }

    private struct Bench {
        let conditions: DeviceConditionsController
        let context: ActiveDeviceContext
        let status: StatusCenter
        let adb: StubAdb
        let state: URL

        @MainActor var statusBar: StatusBarDemoController { conditions.statusBar }

        func touch(_ name: String) {
            FileManager.default.createFile(atPath: state.appendingPathComponent(name).path, contents: nil)
        }

        func remove(_ name: String) {
            try? FileManager.default.removeItem(at: state.appendingPathComponent(name))
        }

        func has(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: state.appendingPathComponent(name).path)
        }

        /// The calls made after `start`.
        func calls(after start: Int) -> [String] {
            Array(adb.calls.dropFirst(start))
        }

        /// The calls that touch demo mode (the probe included).
        func demoCalls(after start: Int) -> [String] {
            calls(after: start).filter { $0.contains("sysui_") || $0.contains("am broadcast") || $0.contains("@@devicehubpro:sb:") }
        }
    }

    private static func flag(_ state: URL, _ name: String) -> String {
        AdbClient.shellQuoted(state.appendingPathComponent(name).path)
    }

    /// The device's demo-mode state, driven by flags:
    /// - `gone`: every command fails (the device left);
    /// - `stuck` (with `allowed` once the gate was opened): SystemUI in demo
    ///   mode with the gate off, entered by the broadcast alone;
    /// - `broadcast` (and `charging` after a send): someone else's demo mode;
    /// - `on` / `allowed`: Device Hub Pro's enter script / the gate.
    /// `slow-enter` makes the enter script take half a second and leave
    /// `entered` behind when it finishes; an exit script seen before that
    /// leaves `early`. `slow-avd` makes the console's `avd name` take 2 s;
    /// `stuck-broadcast` keeps someone else's demo mode on through Device Hub Pro's
    /// exit (SystemUI ignoring it). `silent-enter` makes the enter script
    /// leave `silent`: every probe is then SystemUI not answering (cut before
    /// its `controller` marker, a byte trim of the capture, as
    /// `StatusBarDemoCommandTests.testASilentSystemUIIsNotTrusted` does).
    /// `no-battery-dump` cuts every probe before its `battery` marker (a
    /// SystemUI that does not report its battery, as on API 31–32).
    private static func arms(_ state: URL, serial: String = StatusBarDemoControllerTests.serial) -> String {
        let gone = "[ -f \(flag(state, "gone")) ] && exit 1;"
        let on = flag(state, "on")
        let allowed = flag(state, "allowed")
        let stuck = flag(state, "stuck")
        let broadcast = flag(state, "broadcast")
        let charging = flag(state, "charging")
        let slow = flag(state, "slow-enter")
        let entered = flag(state, "entered")
        let early = flag(state, "early")
        let slowAvd = flag(state, "slow-avd")
        let stuckBroadcast = flag(state, "stuck-broadcast")
        let silentEnter = flag(state, "silent-enter")
        let silent = flag(state, "silent")
        let noBatteryDump = flag(state, "no-battery-dump")
        return """
          "-s \(serial) shell echo @@devicehubpro:sb:api"*)
            \(gone)
            cut='^@@devicehubpro:sb:none'
            if [ -f \(noBatteryDump) ]; then cut='^@@devicehubpro:sb:battery'; fi
            if [ -f \(silent) ]; then cut='^@@devicehubpro:sb:controller'; fi
            {
            if [ -f \(stuck) ]; then
              if [ -f \(allowed) ]; then cat \(fixture("probe-on-stuck-after-allow.txt")); else cat \(fixture("probe-on-not-allowed-stuck.txt")); fi
            elif [ -f \(broadcast) ]; then
              if [ -f \(charging) ]; then cat \(fixture("probe-on-charging-50.txt")); else cat \(fixture("probe-on-by-broadcast-tuner-off.txt")); fi
            elif [ -f \(on) ]; then cat \(fixture("probe-on-screenshot-preset.txt"))
            elif [ -f \(allowed) ]; then cat \(fixture("probe-allowed-off.txt"))
            else cat \(fixture("probe-off.txt")); fi
            } | sed "/$cut/,"'$d' ;;
          "-s \(serial) shell settings put global sysui_demo_allowed 1")
            \(gone) touch \(allowed) ;;
          "-s \(serial) shell settings put global sysui_tuner_demo_on 1; "*)
            \(gone)
            if [ -f \(slow) ]; then sleep 0.5; fi
            if [ -f \(silentEnter) ]; then touch \(silent); fi
            touch \(on) \(entered); cat \(fixture("enter-screenshot.txt")) ;;
          "-s \(serial) shell settings put global sysui_demo_allowed 1; am broadcast "*)
            \(gone) rm -f \(stuck) \(allowed); cat \(fixture("exit-restore-stuck.txt")) ;;
          "-s \(serial) shell am broadcast -a com.android.systemui.demo -e command battery -e level 100 -e plugged false; am broadcast -a com.android.systemui.demo -e command exit; "*)
            \(gone)
            if [ ! -f \(entered) ]; then touch \(early); fi
            if [ ! -f \(stuckBroadcast) ]; then rm -f \(broadcast); fi
            rm -f \(on) \(allowed); cat \(fixture("exit-restore.txt")) ;;
          "-s \(serial) shell settings put global sysui_tuner_demo_on 0; "*)
            \(gone) rm -f \(on) \(allowed) ;;
          "-s \(serial) shell am broadcast "*)
            \(gone) touch \(charging); cat \(fixture("send-charging.txt")) ;;
          "-s \(serial) emu avd name")
            if [ -f \(slowAvd) ]; then sleep 2; fi
            cat \(coreFixture("emu-avd-name.txt")) ;;
        """
    }

    private func bench(
        serial: String = serial,
        avdName: String? = avd,
        recordStore: StatusBarDemoRecordStore? = nil
    ) throws -> Bench {
        let state = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusBarState-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: state) }
        let adb = try makeStubAdb(arms: Self.arms(state, serial: serial))
        let context = ActiveDeviceContext()
        context.serial = serial
        context.avdName = avdName
        let status = StatusCenter()
        let conditions = DeviceConditionsController(
            adbClient: adb.client,
            context: context,
            status: status,
            statusBarRecords: recordStore
        )
        conditions.statusBar.settle = StatusBarDemoSettle(attempts: 3, delay: .zero)
        // What `AppModel.beginMirrorSession` does for the group once the
        // context names the device (the conditions' own attach would add
        // its memory-factor reset to every call log).
        conditions.statusBar.attach()
        return Bench(conditions: conditions, context: context, status: status, adb: adb, state: state)
    }

    /// What `AppModel.tearDownMirror` does around a disconnect, in its
    /// order: the generation moves on first (a poll of the device being left
    /// applies nothing), then `detach()` while the context still names the
    /// device, then the context forgets it.
    private func disconnect(_ bench: Bench) async {
        bench.context.controlsGeneration &+= 1
        bench.conditions.detach()
        bench.context.clear()
        await bench.conditions.waitForPendingCleanup()
    }

    /// A new session of the same AVD on the serial.
    private func reconnect(_ bench: Bench) {
        bench.context.serial = Self.serial
        bench.context.avdName = Self.avd
        bench.context.controlsGeneration &+= 1
        bench.conditions.attach()
    }

    private let original = StatusBarDemoOriginal(allowedRaw: "0", onRaw: "0", wasInDemoMode: false)

    // MARK: - Gating

    func testTheGroupShowsOnceTheProbeAnswers() async throws {
        let bench = try bench()
        XCTAssertFalse(bench.statusBar.showsGroup, "hidden until the probe answers")
        XCTAssertNil(bench.statusBar.demoModeRow.value)

        await bench.statusBar.refresh()
        XCTAssertTrue(bench.statusBar.showsGroup)
        XCTAssertEqual(bench.statusBar.apiLevel, 37)
        XCTAssertEqual(bench.statusBar.demoModeRow.value, false)
        XCTAssertTrue(bench.statusBar.hasReportedController)
        XCTAssertEqual(bench.adb.calls, [Self.probeCall], "one round trip per poll")

        var available = ControlsGroupAvailability()
        available.statusBar = bench.statusBar.showsGroup
        XCTAssertEqual(controlsTrailingRows(available), [.cleanStatusBar])
        XCTAssertEqual(controlsTrailingRows(ControlsGroupAvailability()), [])
    }

    func testThreeFailedProbesHideTheGroup() async throws {
        let bench = try bench()
        await bench.statusBar.refresh()
        bench.touch("gone")
        await bench.statusBar.refresh()
        await bench.statusBar.refresh()
        XCTAssertTrue(bench.statusBar.showsGroup, "two failures are tolerated")
        XCTAssertNil(bench.statusBar.demoModeRow.value, "unknown, not a stale value")
        XCTAssertEqual(bench.statusBar.demoModeRow.caption, StatusBarRowText.readFailed, "not the off caption")
        await bench.statusBar.refresh()
        XCTAssertFalse(bench.statusBar.showsGroup)

        bench.remove("gone")
        await bench.statusBar.refresh()
        XCTAssertTrue(bench.statusBar.showsGroup, "back on the next answer")
    }

    // MARK: - Demo mode

    func testTurningOnAllowsEntersAndSetsTheScreenshotPreset() async throws {
        let bench = try bench()
        await bench.statusBar.refresh()
        let start = bench.adb.calls.count

        await bench.statusBar.setDemoMode(true)

        XCTAssertNil(bench.status.errorMessage)
        XCTAssertEqual(bench.calls(after: start), [
            Self.probeCall,
            Self.allowCall,
            Self.probeCall,
            try Self.scriptCall("enter-screenshot.command.txt"),
            Self.probeCall,
        ])
        let screenshot = StatusBarPreset.screenshot.commands(apiLevel: 37, handlesNotifications: false)
        var expected = StatusBarDemoSent.entered(screenshot)
        expected.preset = .screenshot
        XCTAssertEqual(bench.statusBar.sent, expected)
        XCTAssertEqual(bench.statusBar.sent.clock?.label, "9:41")
        XCTAssertEqual(bench.statusBar.sent.notificationIconsVisible, true, "API 37 has no receiver to hide them")
        XCTAssertEqual(bench.statusBar.records, [Self.avd: StatusBarDemoRecord(original)])
        XCTAssertEqual(bench.status.statusMessage, "Status bar demo mode on (Screenshot preset)")
        XCTAssertEqual(bench.statusBar.demoModeRow, StatusBarDemoModeRowModel(value: true, caption: StatusBarRowText.onByDeviceHubPro))
        XCTAssertFalse(bench.statusBar.isWriting)
    }

    func testTurningOffPutsBackAndRealignsTheBattery() async throws {
        let bench = try bench()
        await bench.statusBar.refresh()
        await bench.statusBar.setDemoMode(true)
        let start = bench.adb.calls.count

        await bench.statusBar.setDemoMode(false)

        XCTAssertNil(bench.status.errorMessage)
        XCTAssertEqual(bench.calls(after: start), [
            Self.probeCall,
            try Self.scriptCall("exit-restore.command.txt"),
            Self.probeCall,
        ], "the recorded keys, no extra read")
        XCTAssertTrue(bench.statusBar.records.isEmpty)
        XCTAssertEqual(bench.statusBar.sent, StatusBarDemoSent())
        XCTAssertEqual(bench.statusBar.demoModeRow.value, false)
        XCTAssertEqual(bench.status.statusMessage, "Status bar demo mode off")
    }

    /// Someone else's demo mode with the gate off: turning it off opens the
    /// gate for a moment and puts it back to off, as it was found.
    func testTurningOffFromTheStuckStateAllowsFirst() async throws {
        let bench = try bench()
        bench.touch("stuck")
        await bench.statusBar.refresh()
        XCTAssertEqual(bench.statusBar.demoModeRow, StatusBarDemoModeRowModel(value: true, caption: StatusBarRowText.stuck))
        let start = bench.adb.calls.count

        await bench.statusBar.setDemoMode(false)

        XCTAssertNil(bench.status.errorMessage)
        XCTAssertEqual(bench.calls(after: start), [
            Self.probeCall,
            Self.probeCall,
            Self.allowCall,
            Self.probeCall,
            try Self.scriptCall("exit-restore-stuck.command.txt"),
            Self.probeCall,
        ], "a read of the keys as found, then the Kit's exit")
        XCTAssertTrue(bench.statusBar.records.isEmpty)
        XCTAssertEqual(bench.statusBar.demoModeRow.value, false)
    }

    // MARK: - Disconnect

    func testDetachRestoresOnTheDeviceBeingLeft() async throws {
        let bench = try bench()
        await bench.statusBar.refresh()
        await bench.statusBar.setDemoMode(true)
        let start = bench.adb.calls.count

        await disconnect(bench)

        XCTAssertEqual(bench.demoCalls(after: start), [
            Self.probeCall,
            try Self.scriptCall("exit-restore.command.txt"),
            Self.probeCall,
        ])
        XCTAssertTrue(bench.statusBar.records.isEmpty)
        XCTAssertFalse(bench.has("on"))
        XCTAssertNil(bench.statusBar.snapshot, "the device's readings are gone")
    }

    /// An enter script still running when the mirror goes away lands before
    /// the put-back, never after it.
    func testDetachWaitsForAnInFlightWrite() async throws {
        let bench = try bench()
        await bench.statusBar.refresh()
        bench.touch("slow-enter")
        let enterCall = try Self.scriptCall("enter-screenshot.command.txt")
        let write = Task { await bench.statusBar.setDemoMode(true) }
        await waitUntil("the enter script started") { bench.adb.calls.contains(enterCall) }

        await disconnect(bench)
        await write.value

        let calls = bench.adb.calls
        let exitCall = try Self.scriptCall("exit-restore.command.txt")
        let enterIndex = try XCTUnwrap(calls.firstIndex(of: enterCall))
        let exitIndex = try XCTUnwrap(calls.firstIndex(of: exitCall), "the put-back ran")
        XCTAssertLessThan(enterIndex, exitIndex)
        XCTAssertFalse(bench.has("early"), "the exit ran after the enter script finished")
        XCTAssertFalse(bench.has("on"))
        XCTAssertTrue(bench.statusBar.records.isEmpty)
    }

    func testADetachThatCannotReachTheDeviceKeepsTheRecord() async throws {
        let bench = try bench()
        await bench.statusBar.refresh()
        await bench.statusBar.setDemoMode(true)
        bench.touch("gone")

        await disconnect(bench)

        XCTAssertEqual(bench.statusBar.records, [Self.avd: StatusBarDemoRecord(original)], "kept for the AVD's next session")
    }

    /// The AVD comes back (restarted: `sysui_demo_allowed` is still 1 on its
    /// disk, `sysui_tuner_demo_on` reset to 0 and SystemUI out of demo mode):
    /// its first probe puts the keys back, with no broadcast.
    func testTheNextAttachOfThatAvdPutsTheKeysBack() async throws {
        let bench = try bench()
        await bench.statusBar.refresh()
        await bench.statusBar.setDemoMode(true)
        bench.touch("gone")
        await disconnect(bench)
        bench.remove("gone")
        bench.remove("on")
        XCTAssertTrue(bench.has("allowed"))

        reconnect(bench)
        let start = bench.adb.calls.count
        await bench.statusBar.refresh()
        await waitUntil("the leftover record was put back") { bench.statusBar.records.isEmpty }
        await waitUntil("the write ended") { !bench.statusBar.isWriting }

        // (The conditions' connect-time memory-factor reset runs beside it.)
        XCTAssertEqual(bench.demoCalls(after: start), [
            Self.probeCall,
            Self.probeCall,
            try Self.scriptCall("exit-keys-only.command.txt"),
            Self.probeCall,
        ])
        XCTAssertFalse(bench.calls(after: start).contains { $0.contains("am broadcast") })
        XCTAssertFalse(bench.has("allowed"))
        XCTAssertEqual(bench.statusBar.snapshot?.isAllowedKey, false)
    }

    /// A leftover record never marked ended (a crash, or quit's bound cut the
    /// put-back, and demo mode was ended elsewhere while Device Hub Pro was not
    /// running) on a SystemUI that does not report its battery (API 31–32;
    /// here the API 37 probe cut before its `battery` marker, a byte trim):
    /// out of demo mode the put-back realigns the battery, as the
    /// disconnect's does, rather than putting back the keys alone.
    func testALeftoverPutBackRealignsWhereTheBatteryIsUnread() async throws {
        let bench = try bench()
        bench.statusBar.record(original, key: Self.avd)
        bench.touch("allowed")
        bench.touch("no-battery-dump")

        await bench.statusBar.refresh()
        await waitUntil("the leftover record was put back") { bench.statusBar.records.isEmpty }
        await waitUntil("the write ended") { !bench.statusBar.isWriting }

        XCTAssertNil(bench.statusBar.snapshot?.systemUIBattery, "no battery dump")
        XCTAssertEqual(bench.demoCalls(after: 0), [
            Self.probeCall,
            Self.probeCall,
            try Self.scriptCall("exit-restore.command.txt"),
            Self.probeCall,
        ])
        XCTAssertFalse(bench.has("allowed"))
    }

    func testSomeoneElsesDemoModeIsLeftOnAtDetach() async throws {
        // A record Device Hub Pro made when it wrote into a demo mode that was on
        // already (someone else's), kept across a relaunch.
        let store = StatusBarDemoRecordStore(defaults: UserDefaults.scratch())
        store.save([Self.avd: StatusBarDemoRecord(StatusBarDemoOriginal(allowedRaw: "1", onRaw: "0", wasInDemoMode: true))])
        let bench = try bench(recordStore: store)
        bench.touch("broadcast")
        await bench.statusBar.refresh()
        XCTAssertEqual(
            bench.statusBar.demoModeRow,
            StatusBarDemoModeRowModel(value: true, caption: StatusBarRowText.onNotByDeviceHubPro)
        )
        XCTAssertFalse(bench.statusBar.ownsDemoMode)
        let start = bench.adb.calls.count

        await disconnect(bench)

        XCTAssertEqual(bench.demoCalls(after: start), [], "no calls at detach")
        XCTAssertTrue(bench.statusBar.records.isEmpty)
    }

    /// Device Hub Pro's demo mode ended elsewhere (Developer options: the tuner key
    /// 0 and `exit`) and someone else's started after it: the Demo mode row
    /// no longer calls it Device Hub Pro's, the disconnect leaves it on, and the
    /// gate Device Hub Pro opened goes back once demo mode is off.
    func testADemoModeStartedAfterDeviceHubProsEndedIsSomeoneElses() async throws {
        let bench = try bench()
        await bench.statusBar.refresh()
        await bench.statusBar.setDemoMode(true)
        XCTAssertTrue(bench.statusBar.ownsDemoMode)

        // Ended elsewhere: the gate Device Hub Pro opened stays at 1.
        bench.remove("on")
        await bench.statusBar.refresh()
        XCTAssertEqual(bench.statusBar.records[Self.avd], StatusBarDemoRecord(original, demoModeEnded: true))
        XCTAssertFalse(bench.statusBar.ownsDemoMode)

        // Someone else's demo mode.
        bench.touch("broadcast")
        await bench.statusBar.refresh()
        XCTAssertEqual(
            bench.statusBar.demoModeRow,
            StatusBarDemoModeRowModel(value: true, caption: StatusBarRowText.onNotByDeviceHubPro)
        )
        let start = bench.adb.calls.count
        await disconnect(bench)
        XCTAssertEqual(bench.demoCalls(after: start), [Self.probeCall], "a look, no exit")
        XCTAssertTrue(bench.has("broadcast"), "left on")
        XCTAssertEqual(bench.statusBar.records[Self.avd]?.demoModeEnded, true, "the gate waits")

        // Their demo mode ended: the next session puts the gate back.
        bench.remove("broadcast")
        reconnect(bench)
        let next = bench.adb.calls.count
        await bench.statusBar.refresh()
        await waitUntil("the gate was put back") { bench.statusBar.records.isEmpty }
        await waitUntil("the write ended") { !bench.statusBar.isWriting }
        XCTAssertEqual(bench.demoCalls(after: next), [
            Self.probeCall,
            Self.probeCall,
            Self.probeCall,
            try Self.scriptCall("exit-keys-only.command.txt"),
            Self.probeCall,
        ])
        XCTAssertFalse(bench.has("allowed"))
    }

    /// Enable demo mode was on at Device Hub Pro's first write, and the user turned
    /// it off later, which ended Device Hub Pro's demo mode: a re-enter opens the
    /// gate again for Device Hub Pro's own broadcasts, and the put-back closes it
    /// as the user left it instead of keeping the "on" first found.
    func testAGateTheUserClosedStaysClosedAfterAReEnter() async throws {
        let bench = try bench()
        bench.touch("allowed")
        await bench.statusBar.refresh()
        await bench.statusBar.setDemoMode(true)
        XCTAssertEqual(bench.statusBar.records[Self.avd]?.original.allowedRaw, "1", "the gate as first found")

        // Developer options ▸ Enable demo mode off: SystemUI leaves demo mode.
        bench.remove("on")
        bench.remove("allowed")
        await bench.statusBar.refresh()
        XCTAssertEqual(bench.statusBar.records[Self.avd]?.original.allowedRaw, "0", "the gate as the user left it")
        XCTAssertEqual(bench.statusBar.records[Self.avd]?.demoModeEnded, true)

        await bench.statusBar.setDemoMode(true)
        XCTAssertNil(bench.status.errorMessage)
        XCTAssertTrue(bench.has("allowed"), "Device Hub Pro opened the gate for its enter")
        let start = bench.adb.calls.count
        await bench.statusBar.setDemoMode(false)

        XCTAssertNil(bench.status.errorMessage)
        let exits = bench.demoCalls(after: start).filter { $0.contains("command exit") }
        XCTAssertEqual(exits.count, 1, "\(bench.demoCalls(after: start))")
        XCTAssertTrue(exits.allSatisfy { $0.contains("sysui_demo_allowed 0") }, "the put-back closes the gate: \(exits)")
        XCTAssertTrue(bench.statusBar.records.isEmpty)
    }

    /// Device Hub Pro entering again makes the ended record its own again.
    func testEnteringAgainOwnsTheDemoModeAgain() async throws {
        let bench = try bench()
        await bench.statusBar.refresh()
        await bench.statusBar.setDemoMode(true)
        bench.remove("on")
        await bench.statusBar.refresh()
        XCTAssertFalse(bench.statusBar.ownsDemoMode)

        await bench.statusBar.setDemoMode(true)
        XCTAssertNil(bench.status.errorMessage)
        XCTAssertEqual(bench.statusBar.records, [Self.avd: StatusBarDemoRecord(original)], "the keys as first found")
        XCTAssertTrue(bench.statusBar.ownsDemoMode)
    }

    /// Entering again after Device Hub Pro's demo mode ended elsewhere, with
    /// SystemUI silent through the whole read-back (seen on emulator-5556):
    /// the enter script ran, so the demo mode it left is Device Hub Pro's own, and
    /// the disconnect ends it rather than waiting for it as someone else's.
    func testAReEnterWhoseReadBackStaysSilentIsStillDeviceHubPros() async throws {
        let bench = try bench()
        await bench.statusBar.refresh()
        await bench.statusBar.setDemoMode(true)
        bench.remove("on")
        await bench.statusBar.refresh()
        XCTAssertEqual(bench.statusBar.records[Self.avd], StatusBarDemoRecord(original, demoModeEnded: true))

        bench.touch("silent-enter")
        await bench.statusBar.setDemoMode(true)
        XCTAssertEqual(bench.status.errorMessage, StatusBarDemoError.systemUINotAnswering.description)
        XCTAssertTrue(bench.has("on"), "the enter script ran")
        XCTAssertEqual(bench.statusBar.records, [Self.avd: StatusBarDemoRecord(original)], "Device Hub Pro's own again")

        // SystemUI answers again, in the demo mode the script left.
        bench.remove("silent")
        await bench.statusBar.refresh()
        XCTAssertEqual(
            bench.statusBar.demoModeRow,
            StatusBarDemoModeRowModel(value: true, caption: StatusBarRowText.onByDeviceHubPro)
        )
        let start = bench.adb.calls.count
        await disconnect(bench)
        XCTAssertEqual(bench.demoCalls(after: start), [
            Self.probeCall,
            try Self.scriptCall("exit-restore.command.txt"),
            Self.probeCall,
        ])
        XCTAssertFalse(bench.has("on"), "ended at disconnect")
        XCTAssertTrue(bench.statusBar.records.isEmpty)
    }

    /// Turning off demo mode Device Hub Pro did not start records the keys first,
    /// so an exit SystemUI ignores is tried again at disconnect, as the
    /// message says.
    func testAFailedExitOfSomeoneElsesDemoModeIsTriedAgainAtDisconnect() async throws {
        let bench = try bench()
        bench.touch("broadcast")
        bench.touch("stuck-broadcast")
        await bench.statusBar.refresh()

        await bench.statusBar.setDemoMode(false)
        XCTAssertEqual(
            bench.status.errorMessage,
            StatusBarDemoError.notExited.description + " Device Hub Pro tries again when it disconnects."
        )
        let found = StatusBarDemoOriginal(allowedRaw: "1", onRaw: "0", wasInDemoMode: false)
        XCTAssertEqual(bench.statusBar.records, [Self.avd: StatusBarDemoRecord(found)])

        bench.remove("stuck-broadcast")
        await disconnect(bench)
        XCTAssertFalse(bench.has("broadcast"), "ended at disconnect")
        XCTAssertTrue(bench.statusBar.records.isEmpty)
    }

    /// A poll cancelled while the console names the AVD caches nothing: the
    /// next poll asks again and puts the leftover record back under the AVD
    /// name, never under the serial.
    func testACancelledAvdLookupIsAskedAgain() async throws {
        let bench = try bench(avdName: nil)
        bench.statusBar.record(original, key: Self.consoleAvd)
        bench.touch("on")
        bench.touch("allowed")
        bench.touch("slow-avd")

        let poll = Task { await bench.statusBar.refresh() }
        await waitUntil("the console lookup started") { bench.adb.calls.contains(Self.avdNameCall) }
        poll.cancel()
        await poll.value
        XCTAssertEqual(bench.statusBar.records, [Self.consoleAvd: StatusBarDemoRecord(original)])
        XCTAssertTrue(bench.has("on"), "nothing put back yet")
        XCTAssertFalse(bench.adb.calls.contains { $0.contains("am broadcast") })

        bench.remove("slow-avd")
        await bench.statusBar.refresh()
        await waitUntil("the leftover record was put back") { bench.statusBar.records.isEmpty }
        await waitUntil("the write ended") { !bench.statusBar.isWriting }
        XCTAssertTrue(bench.adb.calls.contains(try Self.scriptCall("exit-restore.command.txt")))
        XCTAssertFalse(bench.has("on"))
        XCTAssertFalse(bench.statusBar.ownsDemoMode)
    }

    /// The records outlive the app: a relaunch after a crash (no detach)
    /// finishes the put-back on the device's first answer.
    func testARelaunchFinishesThePutBack() async throws {
        let defaults = UserDefaults.scratch()
        let store = StatusBarDemoRecordStore(defaults: defaults)

        let bench = try bench(recordStore: store)
        await bench.statusBar.refresh()
        await bench.statusBar.setDemoMode(true)
        XCTAssertEqual(store.load(), [Self.avd: StatusBarDemoRecord(original)])

        // The app quits without its put-back; a new one starts.
        let context = ActiveDeviceContext()
        context.serial = Self.serial
        context.avdName = Self.avd
        let relaunched = DeviceConditionsController(
            adbClient: bench.adb.client,
            context: context,
            status: StatusCenter(),
            statusBarRecords: store
        )
        relaunched.statusBar.settle = StatusBarDemoSettle(attempts: 3, delay: .zero)
        XCTAssertEqual(relaunched.statusBar.records, [Self.avd: StatusBarDemoRecord(original)])
        relaunched.statusBar.attach()
        await relaunched.statusBar.refresh()
        await waitUntil("the put-back ran") { relaunched.statusBar.records.isEmpty }
        await waitUntil("the write ended") { !relaunched.statusBar.isWriting }
        XCTAssertFalse(bench.has("on"))
        XCTAssertFalse(bench.has("allowed"))
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertNil(defaults.data(forKey: StatusBarDemoRecordStore.key))
    }

    /// A record under an emulator's serial (its AVD name was unreadable)
    /// never outlives the app, and goes when that emulator exits: another
    /// AVD may take the serial.
    func testARecordUnderAnEmulatorSerialIsNotKept() throws {
        let store = StatusBarDemoRecordStore(defaults: UserDefaults.scratch())
        let record = StatusBarDemoRecord(original)
        store.save([Self.serial: record, Self.avd: record, Self.phoneSerial: record])
        XCTAssertEqual(store.load(), [Self.avd: record, Self.phoneSerial: record])

        let bench = try bench()
        bench.statusBar.record(original, key: Self.serial)
        bench.statusBar.record(original, key: Self.avd)
        bench.conditions.emulatorExited(serial: Self.serial)
        XCTAssertEqual(bench.statusBar.records, [Self.avd: record])
    }

    /// Without a record nothing is sent on attach or detach, and no console
    /// is asked for the AVD: the conditions tests' call logs stay as they
    /// were.
    func testAttachAndDetachWithoutARecordIssueNoCommands() async throws {
        let bench = try bench(avdName: nil)
        bench.statusBar.attach()
        bench.statusBar.detach()
        await bench.statusBar.waitForPendingCleanup()
        XCTAssertEqual(bench.adb.calls, [])

        bench.context.serial = Self.serial
        bench.statusBar.attach()
        await bench.statusBar.refresh()
        let start = bench.adb.calls.count
        bench.statusBar.detach()
        await bench.statusBar.waitForPendingCleanup()
        XCTAssertEqual(bench.calls(after: start), [])
        XCTAssertFalse(bench.adb.calls.contains { $0.contains("emu avd") })
    }

    func testAPhoneKeepsItsRecordUnderItsSerial() async throws {
        let bench = try bench(serial: Self.phoneSerial, avdName: nil)
        XCTAssertTrue(bench.statusBar.isPhysical)
        let session = try XCTUnwrap(bench.statusBar.currentSession)
        let key = await bench.statusBar.deviceKey(for: session, avdName: nil)
        XCTAssertEqual(key, Self.phoneSerial)
        XCTAssertFalse(bench.adb.calls.contains { $0.contains("emu avd") }, "no console on a phone")
    }

    // MARK: - AppModel's teardown

    /// A phone mirrored by a real `AppModel` (a fake session in place of
    /// scrcpy; the placeholder serial answered by the same arms), put into
    /// demo mode by Device Hub Pro. `AppModel.tearDownMirror` moves the controls
    /// generation on before it detaches the conditions, so these pin the
    /// put-back to the session the demo mode was entered in, whatever the
    /// generation reads at detach.
    private func phoneInDemoMode() async throws -> (model: AppModel, adb: StubAdb, state: URL) {
        let state = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusBarState-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: state) }
        let adb = try makeStubAdb(arms: Self.arms(state, serial: Self.phoneSerial))
        let model = AppModel.testing(adb: adb.client)
        addTeardownBlock { @MainActor in model.inventory.stopDeviceLifecycle() }
        model.workspace.mirror.sessionFactoryOverride = { _, _ in FakeMirrorSession() }
        let phone = AndroidDevice.online(Self.phoneSerial, model: "Pixel 8")
        model.inventory.applyWatcherSnapshot([phone], degraded: false)
        await model.mirror(device: phone)
        XCTAssertEqual(model.activeDeviceSerial, Self.phoneSerial)

        let statusBar = model.conditions.statusBar
        statusBar.settle = StatusBarDemoSettle(attempts: 3, delay: .zero)
        await statusBar.refresh()
        await statusBar.setDemoMode(true)
        XCTAssertNil(model.workspace.status.errorMessage)
        XCTAssertTrue(statusBar.ownsDemoMode)
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.appendingPathComponent("on").path))
        return (model, adb, state)
    }

    /// The exit script ran on the phone being left, the keys went back and
    /// no record waits for its next session.
    private func assertDemoModeEnded(
        _ model: AppModel,
        _ adb: StubAdb,
        _ state: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let exitCall = try Self.scriptCall("exit-restore.command.txt", serial: Self.phoneSerial)
        XCTAssertTrue(adb.calls.contains(exitCall), "the put-back ran: \(adb.calls)", file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("on").path), "demo mode ended", file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("allowed").path), "the gate closed again", file: file, line: line)
        XCTAssertTrue(model.conditions.statusBar.records.isEmpty, "no record left behind", file: file, line: line)
    }

    func testStopMirrorEndsDeviceHubProsDemoMode() async throws {
        let (model, adb, state) = try await phoneInDemoMode()

        model.stopMirror()
        await model.conditions.waitForPendingCleanup()

        try assertDemoModeEnded(model, adb, state)
    }

    func testQuitEndsDeviceHubProsDemoMode() async throws {
        let (model, adb, state) = try await phoneInDemoMode()

        await model.prepareForTermination()

        try assertDemoModeEnded(model, adb, state)
    }

    /// Mirroring another device tears the first session down (`.replaced`).
    func testMirroringAnotherDeviceEndsDemoModeOnTheOneLeft() async throws {
        let (model, adb, state) = try await phoneInDemoMode()
        let phone = AndroidDevice.online(Self.phoneSerial, model: "Pixel 8")
        // Another same-length placeholder; the stub answers nothing for it.
        let other = AndroidDevice.online("9Z8Y7X6W5V4U", model: "Pixel 7")
        model.inventory.applyWatcherSnapshot([phone, other], degraded: false)

        await model.mirror(device: other)
        await model.conditions.waitForPendingCleanup()

        XCTAssertEqual(model.activeDeviceSerial, other.serial)
        try assertDemoModeEnded(model, adb, state)
    }
}
