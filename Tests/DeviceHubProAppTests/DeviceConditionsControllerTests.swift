import XCTest
import DeviceHubProKit
@testable import DeviceHubProApp

/// The Network and App conditions rows against a stub adb that answers with
/// the API 37 emulator captures (`DeviceHubProKitTests/Fixtures/api37-emulator/
/// conditions`). Arms that stand for a write answer with nothing, as the
/// real commands do; a state file lets a later read answer with the capture
/// taken after that write.
@MainActor
final class DeviceConditionsControllerTests: XCTestCase {
    private static let serial = "emulator-5554"
    /// A same-length placeholder for a USB phone's serial.
    private static let phoneSerial = "0A1B2C3D4E5F"
    /// The AVD `adb-core/emu-avd-name.txt` names.
    private static let avd = "Pixel_9_Pro_Fold"
    /// Another AVD of the capture machine (`adb-core/emulator-list-avds.stdout.txt`).
    private static let otherAvd = "Pixel_9_Pro"
    private static let music = "com.example.musicplayer"
    private static let docs = "com.example.docs"

    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("DeviceHubProKitTests/Fixtures/api37-emulator")

    private static func fixture(_ name: String) -> String {
        AdbClient.shellQuoted(fixtures.appendingPathComponent("conditions/\(name)").path)
    }

    /// A capture of the scratch API 35 emulator's speed and latency probe.
    private static func shapingFixture(_ name: String) -> String {
        AdbClient.shellQuoted(fixtures.deletingLastPathComponent()
            .appendingPathComponent("api35-emulator/shaping/\(name)").path)
    }

    /// The `adb root` calls the stub saw.
    private static func rootCalls(_ bench: Bench) -> [String] {
        bench.adb.calls.filter { $0 == "-s \(serial) root" }
    }

    private static func coreFixture(_ name: String) -> String {
        AdbClient.shellQuoted(fixtures.appendingPathComponent("adb-core/\(name)").path)
    }

    private struct Bench {
        let conditions: DeviceConditionsController
        let context: ActiveDeviceContext
        let status: StatusCenter
        let adb: StubAdb
        let state: URL

        func flag(_ name: String) -> String {
            AdbClient.shellQuoted(state.appendingPathComponent(name).path)
        }
    }

    /// A controller mirroring `serial` over a stub whose arms are built
    /// from the bench's state directory, followed by the console's identity
    /// (`identityArms`).
    private func bench(serial: String = serial, arms: (URL) -> String) throws -> Bench {
        let state = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConditionsState-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: state) }
        let adb = try makeStubAdb(arms: arms(state) + Self.identityArms(state))
        let context = ActiveDeviceContext()
        context.serial = serial
        let status = StatusCenter()
        let conditions = DeviceConditionsController(adbClient: adb.client, context: context, status: status)
        return Bench(conditions: conditions, context: context, status: status, adb: adb, state: state)
    }

    private static func flag(_ state: URL, _ name: String) -> String {
        AdbClient.shellQuoted(state.appendingPathComponent(name).path)
    }

    /// The emulator's network reads: the Wi-Fi probe until `svc data
    /// enable`/`svc wifi disable`, then the mobile-data probe (the
    /// no-service one after `gsm data unregistered`, until `gsm data
    /// home`); the shaping probe follows `adb root` (flag `rooted`) and the
    /// last tc write (flags `shaped`, `shaped-speed`; `moved` puts the netem
    /// on eth0, `release` makes the build non-debuggable). Once
    /// the `gone` flag exists the emulator has left: every command fails.
    private static func networkArms(_ state: URL) -> String {
        let mobile = flag(state, "mobile")
        let rooted = flag(state, "rooted")
        let shaped = flag(state, "shaped")
        let shapedSpeed = flag(state, "shaped-speed")
        let moved = flag(state, "moved")
        let release = flag(state, "release")
        let noService = flag(state, "no-service")
        let gone = "[ -f \(flag(state, "gone")) ] && exit 1;"
        return """
          "-s \(serial) shell svc wifi disable"|"-s \(serial) shell svc data enable")
            \(gone) touch \(mobile) ;;
          "-s \(serial) shell svc wifi enable"|"-s \(serial) shell svc data disable")
            \(gone) rm -f \(mobile) ;;
          "-s \(serial) shell echo @@devicehubpro:net:"*)
            \(gone)
            if [ -f \(noService) ]; then cat \(fixture("network-probe-no-service.txt"))
            elif [ -f \(mobile) ]; then cat \(fixture("network-probe-mobile-data.txt"))
            else cat \(fixture("network-probe-wifi.txt")); fi ;;
          "-s \(serial) shell echo @@devicehubpro:shape:"*)
            \(gone)
            if [ -f \(release) ]; then printf '@@devicehubpro:shape:debuggable\\n0\\n@@devicehubpro:shape:uid\\n2000\\n@@devicehubpro:shape:route\\n1.1.1.1 via 10.0.2.2 dev wlan0 table 1016 src 10.0.2.19 uid 2000\\n@@devicehubpro:shape:qdisc\\n'
            elif [ -f \(shapedSpeed) ]; then cat \(shapingFixture("probe-rooted-shaped-speed-gprs.txt"))
            elif [ -f \(shaped) ] && [ -f \(moved) ]; then sed 's/dev wlan0 root refcnt 2 limit/dev eth0 root refcnt 2 limit/' \(shapingFixture("probe-rooted-shaped-latency-gprs.txt"))
            elif [ -f \(shaped) ]; then cat \(shapingFixture("probe-rooted-shaped-latency-gprs.txt"))
            elif [ -f \(rooted) ]; then cat \(shapingFixture("probe-rooted-plain.txt"))
            else cat \(shapingFixture("probe-unrooted-plain.txt")); fi ;;
          "-s \(serial) shell id -u")
            \(gone) if [ -f \(rooted) ]; then echo 0; else echo 2000; fi ;;
          "-s \(serial) root")
            \(gone) touch \(rooted); echo 'restarting adbd as root' ;;
          "-s \(serial) unroot")
            \(gone) rm -f \(rooted); echo 'restarting adbd as non root' ;;
          "-s \(serial) wait-for-device")
            \(gone) ;;
          "-s \(serial) shell tc qdisc replace dev wlan0 root netem limit 5 rate 28800bit")
            \(gone) touch \(shapedSpeed) ;;
          "-s \(serial) shell tc qdisc replace dev wlan0 root "*)
            \(gone) touch \(shaped) ;;
          "-s \(serial) shell tc qdisc del dev wlan0 root")
            \(gone) rm -f \(shaped) \(shapedSpeed) ;;
          "-s \(serial) shell tc "*|"-s \(serial) shell ip link "*)
            \(gone) ;;
          "-s \(serial) emu gsm data unregistered")
            \(gone) touch \(noService); printf 'OK\\r\\n' ;;
          "-s \(serial) emu gsm data home")
            \(gone) rm -f \(noService); printf 'OK\\r\\n' ;;
          "-s \(serial) emu gsm "*)
            \(gone) printf 'OK\\r\\n' ;;
        """
    }

    /// The console's identity, `avd name` and `avd discoverypath`: the
    /// captured emulator process of `avd` until the flag `second-process`
    /// (a later process, captured on the same machine), and `otherAvd` once
    /// the flag `other-avd` exists. Nothing answers once `gone` exists.
    ///
    /// SOURCE-DERIVED: the `otherAvd` answer. No second AVD may be booted
    /// for a capture here (emulator-5554 only), so it is the captured
    /// answer's format (`adb-core/emu-avd-name.txt`, `<name>\r\nOK\r\n`)
    /// with the name of another AVD of the capture machine
    /// (`adb-core/emulator-list-avds.stdout.txt`).
    private static func identityArms(_ state: URL) -> String {
        let gone = flag(state, "gone")
        let secondProcess = flag(state, "second-process")
        let otherAvd = flag(state, "other-avd")
        return """
          "-s \(serial) emu avd name")
            if [ -f \(gone) ]; then exit 1
            elif [ -f \(otherAvd) ]; then printf '\(Self.otherAvd)\\r\\nOK\\r\\n'
            else cat \(coreFixture("emu-avd-name.txt")); fi ;;
          "-s \(serial) emu avd discoverypath")
            if [ -f \(gone) ]; then exit 1
            elif [ -f \(secondProcess) ]; then cat \(fixture("emu-avd-discoverypath-second-process.txt"))
            else cat \(coreFixture("emu-avd-discoverypath.txt")); fi ;;
        """
    }

    /// The bench's emulator process (`adb-core/emu-avd-discoverypath.txt`).
    private static let firstProcess = "/Users/testeruser/Library/Caches/TemporaryItems/avd/running/pid_71988.ini"

    private static func touch(_ bench: Bench, _ name: String) {
        FileManager.default.createFile(atPath: bench.state.appendingPathComponent(name).path, contents: nil)
    }

    private static func remove(_ bench: Bench, _ name: String) {
        try? FileManager.default.removeItem(at: bench.state.appendingPathComponent(name))
    }

    /// The commands that change a condition or a switch on the device.
    private static func putBackCalls(_ calls: some Sequence<String>) -> [String] {
        calls.filter { $0.contains(" emu gsm ") || $0.contains(" shell svc ") || $0.contains(" shell tc qdisc ") }
    }

    // MARK: - Gating

    func testNetworkConditionsNeedAnEmulatorAndAppRowsNeedTheirAPI() throws {
        let emulator = try bench { _ in "" }
        XCTAssertTrue(emulator.conditions.showsNetworkConditions)
        XCTAssertTrue(emulator.conditions.showsAppConditions)
        XCTAssertFalse(emulator.conditions.showsShaping, "hidden until the build is read")
        XCTAssertFalse(emulator.conditions.showsLowMemory, "hidden until the API level is known")
        emulator.conditions.apiLevel = 22
        XCTAssertFalse(emulator.conditions.showsLowMemory, "am send-trim-memory needs API 23")
        emulator.conditions.apiLevel = 23
        XCTAssertTrue(emulator.conditions.showsLowMemory)
        emulator.conditions.apiLevel = 37
        XCTAssertTrue(emulator.conditions.showsLowMemory)

        let phone = try bench(serial: Self.phoneSerial) { _ in "" }
        XCTAssertFalse(phone.conditions.showsNetworkConditions)
        XCTAssertFalse(phone.conditions.showsShaping, "tc needs root, which Device Hub Pro never asks of a phone")
        XCTAssertTrue(phone.conditions.showsAppConditions)
    }

    func testConditionsRowsFollowTheirAvailability() {
        var available = ControlsGroupAvailability()
        XCTAssertEqual(conditionsGroups(available), [])
        XCTAssertEqual(networkConditionRows(available), [])

        available.appConditions = true
        XCTAssertEqual(conditionsGroups(available), [ControlsGroup(id: .appConditions, rows: [.targetApp, .killProcess])])

        available.networkConditions = true
        available.lowMemory = true
        XCTAssertEqual(
            networkConditionRows(available),
            [.meteredMobileData, .resetConditions],
            "a build tc cannot run on (Play Store, user build) has no Speed or Connection latency row"
        )
        available.shaping = true
        XCTAssertEqual(networkConditionRows(available), [.networkSpeed, .connectionLatency, .meteredMobileData, .resetConditions])
        XCTAssertEqual(conditionsGroups(available), [
            ControlsGroup(id: .appConditions, rows: [.targetApp, .lowMemory, .killProcess]),
        ])
        // The one Network group: the switches first, then the conditions.
        XCTAssertEqual(
            controlsGroups(available).first { $0.id == .network }?.rows,
            [.wifi, .bluetooth, .airplaneMode, .mobileData, .networkSpeed, .connectionLatency, .meteredMobileData, .resetConditions]
        )
        // A phone shows the switches it supports but no conditions.
        available.networkConditions = false
        XCTAssertEqual(controlsGroups(available).first { $0.id == .network }?.rows, [.wifi, .bluetooth, .airplaneMode, .mobileData])
    }

    // MARK: - Poll

    func testRefreshReadsTheNetworkTheConsoleAndTheTarget() async throws {
        let bench = try bench { state in
            Self.networkArms(state) + """
              "-s \(Self.serial) shell echo @@devicehubpro:app:"*)
                cat \(Self.fixture("app-probe-settings-foreground.txt")) ;;
              "-s \(Self.serial) shell pm list packages -3")
                cat \(Self.coreFixture("shell-pm-list-packages-3.txt")) ;;
              "-s \(Self.serial) shell dumpsys activity activities"*)
                cat \(Self.fixture("foreground-settings.txt")) ;;
            """
        }
        bench.conditions.targetPackage = "com.android.settings"
        await bench.conditions.refresh()
        await waitUntil("the targets loaded") { !bench.conditions.isLoadingTargets }

        XCTAssertEqual(bench.conditions.network?.connectivity.dataPath, .wifi)
        XCTAssertEqual(bench.conditions.shaping?.latency, .off)
        XCTAssertTrue(bench.conditions.showsShaping, "a userdebug build")
        XCTAssertEqual(bench.conditions.targetPackage, "com.android.settings", "a listed choice stays")
        XCTAssertEqual(bench.conditions.targetSnapshot?.runningProcess?.pid, 7276)
        XCTAssertEqual(bench.conditions.apiLevel, 37)
        XCTAssertEqual(
            bench.adb.calls.count,
            5,
            "one probe, one shaping read, one app probe, and once per device the package list and the foreground app"
        )

        await bench.conditions.refresh()
        XCTAssertEqual(bench.adb.calls.count, 8, "later polls list no packages")
    }

    /// A phone has no console: only the app probe runs.
    func testAPhoneRefreshSkipsTheConsole() async throws {
        let bench = try bench(serial: Self.phoneSerial) { _ in
            """
              "-s \(Self.phoneSerial) shell echo @@devicehubpro:app:"*)
                cat \(Self.fixture("app-probe-no-target.txt")) ;;
            """
        }
        await bench.conditions.refresh()
        XCTAssertNil(bench.conditions.network)
        XCTAssertEqual(bench.conditions.apiLevel, 37)
        XCTAssertTrue(bench.adb.calls.allSatisfy { !$0.contains(" emu ") && !$0.contains("@@devicehubpro:net:") })
    }

    // MARK: - Network writes

    func testUseMobileDataRemembersTheRadiosAndWaitsForTheMobileNetwork() async throws {
        let bench = try bench { Self.networkArms($0) }
        await bench.conditions.refresh()
        await bench.conditions.useMobileData()

        XCTAssertNil(bench.status.errorMessage)
        XCTAssertEqual(bench.status.statusMessage, "Mobile data carries the traffic now", "the outcome outlives the progress line")
        XCTAssertEqual(bench.conditions.network?.connectivity.dataPath, .mobileData)
        XCTAssertEqual(
            bench.conditions.savedDataPath,
            DeviceConditionsController.SavedDataPath(wifiOn: "1", mobileData: "0")
        )
        XCTAssertNotNil(bench.conditions.savedDataPaths[Self.avd], "saved for the AVD the console names")
        XCTAssertEqual(bench.adb.calls(containing: " shell svc ").map { $0.replacingOccurrences(of: "-s \(Self.serial) shell ", with: "") }, [
            "svc wifi disable",
            "svc data enable",
        ])
    }

    func testResetPutsEveryConditionBack() async throws {
        let bench = try bench { Self.networkArms($0) }
        await bench.conditions.refresh()
        await bench.conditions.useMobileData()
        await bench.conditions.setLatency(LatencyPreset.gprs.latency)
        XCTAssertNil(bench.status.errorMessage)
        XCTAssertEqual(bench.conditions.shaping?.latency, LatencyPreset.gprs.latency)
        XCTAssertEqual(bench.conditions.rootedByDeviceHubPro, [Self.serial], "adb root restarted adbd for the write")
        XCTAssertEqual(
            bench.conditions.changedConditions[Self.serial],
            DeviceConditionsController.ChangedConsole(discoveryPath: Self.firstProcess, conditions: [.shaping])
        )

        await bench.conditions.resetNetworkConditions()

        XCTAssertNil(bench.status.errorMessage)
        XCTAssertEqual(bench.status.statusMessage, "Network conditions reset", "the outcome outlives the progress line")
        XCTAssertEqual(bench.conditions.shaping?.latency, .off)
        XCTAssertEqual(bench.conditions.shaping?.isRoot, false, "adbd is unrooted again")
        XCTAssertTrue(bench.conditions.rootedByDeviceHubPro.isEmpty)
        XCTAssertEqual(bench.conditions.network?.connectivity.dataPath, .wifi)
        XCTAssertNil(bench.conditions.savedDataPath)
        XCTAssertNil(bench.conditions.changedConditions[Self.serial], "nothing left for the disconnect to put back")
        let resetCalls = bench.adb.calls.map { $0.replacingOccurrences(of: "-s \(Self.serial) ", with: "") }
        for command in [
            "shell tc qdisc del dev wlan0 root",
            "unroot",
            "emu gsm meter on",
            "shell svc data disable",
            "shell svc wifi enable",
        ] {
            XCTAssertTrue(resetCalls.contains(command), command)
        }
    }

    /// A disconnect puts back what Device Hub Pro changed — the latency and the
    /// radios Use Mobile Data switched — through the emulator it changed
    /// them on, and leaves the rest alone.
    func testDetachPutsBackWhatDeviceHubProChanged() async throws {
        let bench = try bench { Self.networkArms($0) }
        await bench.conditions.refresh()
        await bench.conditions.useMobileData()
        await bench.conditions.setLatency(LatencyPreset.gprs.latency)
        let before = bench.adb.calls.count

        bench.conditions.detach()
        await bench.conditions.waitForPendingCleanup()

        let cleanup = bench.adb.calls.dropFirst(before).map { $0.replacingOccurrences(of: "-s \(Self.serial) ", with: "") }
        XCTAssertEqual(Set(cleanup.filter { $0.hasPrefix("emu avd ") }), ["emu avd name", "emu avd discoverypath"], "which emulator answers")
        XCTAssertEqual(cleanup.filter { !$0.hasPrefix("emu avd ") }, [
            "shell svc data disable",
            "shell svc wifi enable",
            "shell \(ShapingReading.probeScript)",
            "shell tc qdisc del dev wlan0 root",
            "shell tc filter del dev wlan0 ingress pref 49000",
            "shell tc qdisc del dev ifb0 root",
            "shell ip link set ifb0 down",
            "shell id -u",
            "reverse --list",
            "unroot",
            "wait-for-device",
            "shell id -u",
        ], "the switches, which outlast the emulator, then the tc rules, and only then the root Device Hub Pro gave adbd")
        XCTAssertTrue(bench.conditions.rootedByDeviceHubPro.isEmpty)
        XCTAssertTrue(bench.conditions.savedDataPaths.isEmpty)
        XCTAssertNil(bench.conditions.changedConditions[Self.serial])
    }

    /// The emulator is gone before the disconnect's cleanup: nothing is
    /// sent, and what it could not put back stays recorded for that
    /// emulator (the shaping) and that AVD (the switches).
    func testADetachThatCannotReachTheDeviceKeepsTheRecord() async throws {
        let bench = try bench { Self.networkArms($0) }
        await bench.conditions.refresh()
        await bench.conditions.useMobileData()
        await bench.conditions.setLatency(LatencyPreset.gprs.latency)
        Self.touch(bench, "gone")
        let before = bench.adb.calls.count

        bench.conditions.detach()
        await bench.conditions.waitForPendingCleanup()

        XCTAssertEqual(Self.putBackCalls(bench.adb.calls.dropFirst(before)), [], "no console answered")
        XCTAssertEqual(
            bench.conditions.savedDataPaths[Self.avd],
            DeviceConditionsController.SavedDataPath(wifiOn: "1", mobileData: "0")
        )
        XCTAssertEqual(
            bench.conditions.changedConditions[Self.serial],
            DeviceConditionsController.ChangedConsole(discoveryPath: Self.firstProcess, conditions: [.shaping])
        )
    }

    /// The emulator left before the cleanup, and a different AVD later
    /// takes the serial: nothing recorded for the first one reaches it —
    /// neither on its disconnect nor on Reset conditions. The console
    /// record ends with the first emulator; the switches wait for its AVD.
    func testADifferentAvdOnTheSerialGetsNoPutBack() async throws {
        let bench = try bench { Self.networkArms($0) }
        await bench.conditions.refresh()
        await bench.conditions.useMobileData()
        await bench.conditions.setLatency(LatencyPreset.gprs.latency)
        XCTAssertNil(bench.status.errorMessage)
        Self.touch(bench, "gone")
        bench.conditions.detach()
        await bench.conditions.waitForPendingCleanup()
        XCTAssertNotNil(bench.conditions.changedConditions[Self.serial])

        // Another AVD boots on the serial, in its start state.
        for name in ["gone", "mobile", "shaped", "rooted", "no-service"] {
            Self.remove(bench, name)
        }
        Self.touch(bench, "second-process")
        Self.touch(bench, "other-avd")
        bench.context.controlsGeneration &+= 1
        bench.conditions.attach()
        await bench.conditions.refresh()
        let before = bench.adb.calls.count

        bench.conditions.detach()
        await bench.conditions.waitForPendingCleanup()
        XCTAssertEqual(Self.putBackCalls(bench.adb.calls.dropFirst(before)), [], "the disconnect sends nothing")
        XCTAssertNil(bench.conditions.changedConditions[Self.serial], "the first emulator's console state ended with it")
        XCTAssertNotNil(bench.conditions.savedDataPaths[Self.avd], "the first AVD's switches wait for it")

        bench.context.controlsGeneration &+= 1
        bench.conditions.attach()
        await bench.conditions.refresh()
        let resetStart = bench.adb.calls.count
        await bench.conditions.resetNetworkConditions()
        XCTAssertNil(bench.status.errorMessage)
        let reset = Self.putBackCalls(bench.adb.calls.dropFirst(resetStart))
            .map { $0.replacingOccurrences(of: "-s \(Self.serial) ", with: "") }
        XCTAssertEqual(
            reset,
            ["emu gsm meter on"],
            "Reset sets this emulator's start state: no switches of the other AVD"
        )
        XCTAssertNotNil(bench.conditions.savedDataPaths[Self.avd])
    }

    /// The same AVD comes back in a new emulator process: the switches it
    /// keeps on its disk are restored on its disconnect, but the console
    /// latency ended with the old process and is not sent again.
    func testTheSameAvdInANewEmulatorGetsOnlyItsSwitchesBack() async throws {
        let bench = try bench { Self.networkArms($0) }
        await bench.conditions.refresh()
        await bench.conditions.useMobileData()
        await bench.conditions.setLatency(LatencyPreset.gprs.latency)
        Self.touch(bench, "gone")
        bench.conditions.detach()
        await bench.conditions.waitForPendingCleanup()

        Self.remove(bench, "gone")
        Self.remove(bench, "shaped")
        Self.remove(bench, "rooted")
        Self.touch(bench, "second-process")
        bench.context.controlsGeneration &+= 1
        bench.conditions.attach()
        await bench.conditions.refresh()
        let before = bench.adb.calls.count

        bench.conditions.detach()
        await bench.conditions.waitForPendingCleanup()
        let cleanup = Self.putBackCalls(bench.adb.calls.dropFirst(before))
            .map { $0.replacingOccurrences(of: "-s \(Self.serial) ", with: "") }
        XCTAssertEqual(cleanup, ["shell svc data disable", "shell svc wifi enable"])
        XCTAssertTrue(bench.conditions.savedDataPaths.isEmpty)
        XCTAssertNil(bench.conditions.changedConditions[Self.serial])
    }

    /// Device Hub Pro rooted adbd (the wait for it may have failed, so nothing else
    /// was recorded): the disconnect still gives the root back.
    func testDetachUnrootsEvenWhenNothingElseChanged() async throws {
        let bench = try bench { Self.networkArms($0) }
        await bench.conditions.refresh()
        Self.touch(bench, "rooted")
        bench.conditions.recordRootedByDeviceHubPro(true, serial: Self.serial)
        XCTAssertNil(bench.conditions.changedConditions[Self.serial])

        bench.conditions.detach()
        await bench.conditions.waitForPendingCleanup()

        XCTAssertTrue(bench.adb.calls.contains("-s \(Self.serial) unroot"), "\(bench.adb.calls)")
        XCTAssertTrue(bench.conditions.rootedByDeviceHubPro.isEmpty)
    }

    /// The poll's reapply meant for one device never lands on another.
    func testAReappliedProfileIsDroppedWhenAnotherDeviceIsMirrored() async throws {
        let bench = try bench { Self.networkArms($0) }
        await bench.conditions.refresh()
        let generation = bench.context.controlsGeneration
        let before = bench.adb.calls.count

        await bench.conditions.applyShaping(
            ShapingProfile(speed: .gsm), quiet: true, expecting: ("emulator-9999", generation))
        await bench.conditions.applyShaping(
            ShapingProfile(speed: .gsm), quiet: true, expecting: (Self.serial, generation &+ 1))

        XCTAssertEqual(bench.adb.calls.count, before, "nothing was sent to the device")
    }

    /// Stop (or the recovery's kill) ended the emulator: its console record
    /// goes with it.
    func testAStoppedEmulatorLeavesNoConsoleRecord() async throws {
        let bench = try bench { Self.networkArms($0) }
        await bench.conditions.refresh()
        await bench.conditions.setLatency(LatencyPreset.gprs.latency)
        XCTAssertNotNil(bench.conditions.changedConditions[Self.serial])

        bench.conditions.emulatorExited(serial: Self.serial)
        XCTAssertNil(bench.conditions.changedConditions[Self.serial])
    }

    /// A console that does not say which emulator it is gets no write:
    /// Device Hub Pro could not put the change back on it alone.
    func testAWriteNeedsTheEmulatorsIdentity() async throws {
        let bench = try bench { state in
            """
              "-s \(Self.serial) emu avd "*)
                exit 1 ;;
            """ + Self.networkArms(state)
        }
        await bench.conditions.refresh()
        await bench.conditions.setLatency(LatencyPreset.gprs.latency)
        XCTAssertEqual(bench.adb.calls(containing: "tc qdisc replace"), [])
        XCTAssertEqual(Self.rootCalls(bench), [], "adbd is not restarted for a write that cannot be put back")
        XCTAssertNotNil(bench.status.errorMessage)
        XCTAssertNil(bench.conditions.changedConditions[Self.serial])
    }

    /// The mirror moves to another device while a write waits for Android:
    /// the loop ends at once instead of reading the old device for 20 s,
    /// and the new session's status line is not touched.
    func testADeviceChangeEndsAWriteAndLeavesTheNewStatusLine() async throws {
        let bench = try bench { _ in
            """
              "-s \(Self.serial) shell svc "*)
                ;;
              "-s \(Self.serial) shell echo @@devicehubpro:net:"*)
                cat \(Self.fixture("network-probe-wifi.txt")) ;;
            """
        }
        await bench.conditions.refresh()
        let started = ContinuousClock.now
        let write = Task { await bench.conditions.useMobileData() }
        await waitUntil("the switch was sent") { !bench.adb.calls(containing: "svc data enable").isEmpty }

        bench.conditions.detach()
        bench.context.controlsGeneration &+= 1
        bench.context.serial = "emulator-5556"
        bench.status.showProgress("Starting Pixel 9…")
        await write.value

        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        XCTAssertFalse(bench.conditions.isWriting)
        XCTAssertEqual(bench.status.statusMessage, "Starting Pixel 9…")
        XCTAssertNil(bench.status.errorMessage)
    }

    /// The device takes no shaping (the read-back shows none): the row
    /// shows the read-back and raises it.
    func testAShapingTheDeviceDidNotTakeIsAnError() async throws {
        let bench = try bench { state in
            """
              "-s \(Self.serial) shell tc qdisc replace dev wlan0 root "*)
                ;;
            """ + Self.networkArms(state)
        }
        await bench.conditions.refresh()
        await bench.conditions.setLatency(LatencyPreset.gsm.latency)
        XCTAssertEqual(bench.conditions.shaping?.latency, .off)
        XCTAssertEqual(bench.status.errorMessage, "The device did not take the speed and latency: it reports no shaping.")
    }

    func testAFailingTcIsReported() async throws {
        let bench = try bench { state in
            """
              "-s \(Self.serial) shell tc qdisc replace dev wlan0 root "*)
                echo 'RTNETLINK answers: Invalid argument' >&2; exit 2 ;;
            """ + Self.networkArms(state)
        }
        await bench.conditions.refresh()
        await bench.conditions.setLatency(LatencyPreset.gsm.latency)
        XCTAssertTrue(bench.status.errorMessage?.contains("Invalid argument") == true, bench.status.errorMessage ?? "")
    }

    /// Speed goes through the same path as latency, with its own rates.
    func testSpeedShapesWithTheEmulatorsRates() async throws {
        let bench = try bench { Self.networkArms($0) }
        await bench.conditions.refresh()
        await bench.conditions.setSpeed(.gprs)
        XCTAssertNil(bench.status.errorMessage)
        XCTAssertEqual(bench.conditions.shaping?.speed, .gprs)
        XCTAssertEqual(bench.status.statusMessage, "Set speed GPRS")
        XCTAssertEqual(bench.adb.calls(containing: "tc qdisc replace dev ifb0"), [
            "-s \(Self.serial) shell tc qdisc replace dev ifb0 root netem limit 5 rate 57600bit",
        ])
        XCTAssertEqual(Self.rootCalls(bench).count, 1)
        // Latency keeps the speed: both ride one profile.
        await bench.conditions.setLatency(LatencyPreset.gprs.latency)
        XCTAssertEqual(bench.conditions.desiredShaping[Self.serial]?.speed, .gprs)
        XCTAssertEqual(bench.conditions.desiredShaping[Self.serial]?.latency, LatencyPreset.gprs.latency)
        XCTAssertEqual(Self.rootCalls(bench).count, 1, "adbd is root already: no second restart")
    }

    /// Picking None with nothing in place does not root a device.
    func testNoneOnACleanDeviceNeverRoots() async throws {
        let bench = try bench { Self.networkArms($0) }
        await bench.conditions.refresh()
        await bench.conditions.setLatency(.off)
        XCTAssertNil(bench.status.errorMessage)
        XCTAssertEqual(Self.rootCalls(bench), [])
        XCTAssertTrue(bench.conditions.rootedByDeviceHubPro.isEmpty)
    }

    /// A device that was root before is left root.
    func testADeviceThatWasRootIsNotUnrooted() async throws {
        let bench = try bench { Self.networkArms($0) }
        Self.touch(bench, "rooted")
        await bench.conditions.refresh()
        await bench.conditions.setLatency(LatencyPreset.gprs.latency)
        XCTAssertTrue(bench.conditions.rootedByDeviceHubPro.isEmpty)
        await bench.conditions.resetNetworkConditions()
        XCTAssertTrue(bench.adb.calls(containing: "unroot").isEmpty)
        XCTAssertEqual(bench.conditions.shaping?.isShaping, false)
    }

    /// A build `adb root` refuses (Play Store image, user build) shows no
    /// Speed and Connection latency row, and nothing runs `adb root` to
    /// find out.
    func testANonDebuggableBuildHidesTheRows() async throws {
        let bench = try bench { Self.networkArms($0) }
        Self.touch(bench, "release")
        await bench.conditions.refresh()
        XCTAssertEqual(bench.conditions.shaping?.debuggable, false)
        XCTAssertFalse(bench.conditions.showsShaping)
        XCTAssertEqual(Self.rootCalls(bench), [])
    }

    /// The data path moved to another interface: the poll puts the shaping
    /// where the traffic goes now and removes the old one.
    func testThePollMovesShapingToTheNewInterface() async throws {
        let bench = try bench { Self.networkArms($0) }
        await bench.conditions.refresh()
        await bench.conditions.setLatency(LatencyPreset.gprs.latency)
        Self.touch(bench, "moved")
        await bench.conditions.refresh()
        await waitUntil("the shaping left eth0") {
            !bench.adb.calls(containing: "tc qdisc del dev eth0 root").isEmpty
        }
        XCTAssertFalse(bench.adb.calls(containing: "tc qdisc replace dev wlan0").isEmpty)
    }

    func testAnInvalidCustomLatencyIsNeverSent() async throws {
        let bench = try bench { Self.networkArms($0) }
        bench.conditions.customLatencyMinimum = "0"
        bench.conditions.customLatencyMaximum = "500"
        await bench.conditions.applyCustomLatency()
        XCTAssertEqual(bench.conditions.customLatencyError, LatencyInputError.minimumBelowOne.description)
        XCTAssertTrue(bench.adb.calls(containing: "tc qdisc").isEmpty)
    }

    // MARK: - App writes

    private static func appArms(_ state: URL, before: String, after: String, trigger: String) -> String {
        let done = flag(state, "done")
        return """
          "-s \(serial) shell \(trigger)"*)
            touch \(done) ;;
          "-s \(serial) shell echo @@devicehubpro:app:"*)
            if [ -f \(done) ]; then cat \(fixture(after)); else cat \(fixture(before)); fi ;;
        """
    }

    /// SOURCE-DERIVED: the API 37 capture of the cached (frozen) music app
    /// process after a send, with its recorded level 10 replaced by the 80
    /// (COMPLETE) a background app is sent; the process lines are otherwise
    /// the capture's.
    func testLowMemorySendsCompleteToABackgroundAppAndReadsItBack() async throws {
        let capture = try String(
            contentsOf: Self.fixtures.appendingPathComponent("conditions/app-probe-music-app-trimmed.txt"),
            encoding: .utf8
        )
        let level80 = capture.replacingOccurrences(of: "trimMemoryLevel=10", with: "trimMemoryLevel=80")
        XCTAssertNotEqual(level80, capture)
        let bench = try bench { state in
            let after = state.appendingPathComponent("app-probe-music-app-level80.txt")
            try? Data(level80.utf8).write(to: after)
            let done = Self.flag(state, "sent")
            return """
              "-s \(Self.serial) shell am send-trim-memory"*)
                touch \(done) ;;
              "-s \(Self.serial) shell echo @@devicehubpro:app:"*)
                if [ -f \(done) ]; then cat \(AdbClient.shellQuoted(after.path)); else cat \(Self.fixture("app-probe-music-app-cached.txt")); fi ;;
            """
        }
        bench.conditions.targetPackage = Self.music
        await bench.conditions.simulateLowMemory()

        XCTAssertEqual(
            bench.adb.calls(containing: "send-trim-memory"),
            ["-s emulator-5554 shell am send-trim-memory --user current \(Self.music) COMPLETE"]
        )
        XCTAssertEqual(
            bench.conditions.trimOutcome,
            "Sent COMPLETE (80): the process records level 80. It is frozen, so it frees memory when the app resumes."
        )
        XCTAssertEqual(bench.conditions.lowMemoryGate, .notHigher(current: 80), "the same level again is gated")
    }

    /// Settings in the foreground: RUNNING_CRITICAL, since background levels
    /// are refused there; nothing a picker could get wrong.
    func testLowMemorySendsRunningCriticalToAForegroundApp() async throws {
        let bench = try bench { _ in
            """
              "-s \(Self.serial) shell am send-trim-memory"*)
                ;;
              "-s \(Self.serial) shell echo @@devicehubpro:app:"*)
                cat \(Self.fixture("app-probe-settings-foreground.txt")) ;;
            """
        }
        bench.conditions.targetPackage = "com.android.settings"
        await bench.conditions.simulateLowMemory()
        XCTAssertEqual(
            bench.adb.calls(containing: "send-trim-memory"),
            ["-s emulator-5554 shell am send-trim-memory --user current com.android.settings RUNNING_CRITICAL"]
        )
        XCTAssertEqual(
            bench.conditions.trimOutcome,
            "Sent RUNNING_CRITICAL (15), but the process records trim level 0."
        )
    }

    func testLowMemoryIsGatedWhileTheAppIsNotRunning() async throws {
        let bench = try bench { _ in
            """
              "-s \(Self.serial) shell echo @@devicehubpro:app:"*)
                cat \(Self.fixture("app-probe-music-app-killed.txt")) ;;
            """
        }
        bench.conditions.targetPackage = Self.music
        await bench.conditions.simulateLowMemory()
        XCTAssertEqual(bench.conditions.trimOutcome, TrimMemoryGate.notRunning.reason)
        XCTAssertTrue(bench.adb.calls(containing: "send-trim-memory").isEmpty)
    }

    func testKillIsConfirmedByThePidGoingAway() async throws {
        let bench = try bench { state in
            Self.appArms(
                state,
                before: "app-probe-music-app-cached.txt",
                after: "app-probe-music-app-killed.txt",
                trigger: "am kill"
            ) + """
              "-s \(Self.serial) shell dumpsys activity exit-info "*)
                ;;
            """
        }
        bench.conditions.targetPackage = Self.music
        await bench.conditions.killProcess()
        XCTAssertEqual(bench.adb.calls(containing: "am kill"), ["-s emulator-5554 shell am kill --user current \(Self.music)"])
        XCTAssertEqual(bench.conditions.killOutcome, "Killed. Reopen it from Recents to test state restoration.")
    }

    /// `am kill` leaves a foreground app alone and still exits 0.
    func testAKillThatLeftTheAppRunningSaysSo() async throws {
        let bench = try bench { _ in
            """
              "-s \(Self.serial) shell am kill "*)
                ;;
              "-s \(Self.serial) shell echo @@devicehubpro:app:"*)
                cat \(Self.fixture("app-probe-settings-foreground.txt")) ;;
            """
        }
        bench.conditions.targetPackage = "com.android.settings"
        await bench.conditions.killProcess()
        XCTAssertEqual(
            bench.conditions.killOutcome,
            "Still running. Only background apps can be killed this way: leave the app (Home), give Android a second, then try again."
        )
    }

    // MARK: - Target app

    func testTargetsListThirdPartyAppsAndTheForegroundApp() async throws {
        let bench = try bench { _ in
            """
              "-s \(Self.serial) shell pm list packages -3")
                cat \(Self.coreFixture("shell-pm-list-packages-3.txt")) ;;
              "-s \(Self.serial) shell dumpsys activity activities"*)
                cat \(Self.fixture("foreground-settings.txt")) ;;
              "-s \(Self.serial) shell "*)
                ;;
            """
        }
        bench.conditions.loadTargets()
        await waitUntil("the targets loaded") { !bench.conditions.isLoadingTargets }
        XCTAssertEqual(bench.conditions.foregroundPackage, "com.android.settings")
        XCTAssertEqual(bench.conditions.targetPackages, [
            "com.android.settings", "com.devicehubpro.verifier", "com.example.testing.companion",
        ])
        XCTAssertNil(bench.conditions.targetPackage, "a system app in front is listed, not picked")
    }

    /// An install or uninstall through Device Hub Pro relists the mirrored
    /// device's targets, once they were listed.
    func testAPackageChangeRelistsTheTargets() async throws {
        let bench = try bench { _ in
            """
              "-s \(Self.serial) shell pm list packages -3")
                cat \(Self.coreFixture("shell-pm-list-packages-3.txt")) ;;
              "-s \(Self.serial) shell dumpsys activity activities"*)
                cat \(Self.fixture("foreground-settings.txt")) ;;
              "-s \(Self.serial) shell echo @@devicehubpro:app:"*)
                cat \(Self.fixture("app-probe-no-target.txt")) ;;
              "-s \(Self.serial) "*)
                ;;
            """
        }
        bench.conditions.packagesChanged(serial: Self.serial)
        XCTAssertTrue(bench.adb.calls(containing: "pm list packages").isEmpty, "not listed yet: the first poll lists them")

        await bench.conditions.refresh()
        await waitUntil("the targets loaded") { !bench.conditions.isLoadingTargets }
        XCTAssertEqual(bench.adb.calls(containing: "pm list packages").count, 1)

        bench.conditions.packagesChanged(serial: "emulator-5556")
        XCTAssertFalse(bench.conditions.isLoadingTargets, "another device's change")

        bench.conditions.packagesChanged(serial: Self.serial)
        await waitUntil("the targets were listed again") { bench.adb.calls(containing: "pm list packages").count == 2 }
        await waitUntil("the targets loaded") { !bench.conditions.isLoadingTargets }
    }

    func testTheDefaultTargetPrefersAThirdPartyForegroundApp() {
        let thirdParty = ["com.example.app", "com.example.other"]
        XCTAssertEqual(
            DeviceConditionsController.defaultTarget(
                current: nil,
                thirdParty: thirdParty,
                foreground: "com.example.other",
                options: thirdParty
            ),
            "com.example.other"
        )
        XCTAssertEqual(
            DeviceConditionsController.defaultTarget(
                current: "com.example.app",
                thirdParty: thirdParty,
                foreground: "com.example.other",
                options: thirdParty
            ),
            "com.example.app",
            "a still-listed choice stays"
        )
        XCTAssertNil(DeviceConditionsController.defaultTarget(
            current: "com.gone",
            thirdParty: thirdParty,
            foreground: "com.android.settings",
            options: DeviceConditionsController.targetOptions(thirdParty: thirdParty, foreground: "com.android.settings")
        ))
    }

    // MARK: - Row text

    func testRowTextFollowsTheReadings() throws {
        XCTAssertEqual(ConditionsRowText.latencyPlaceholder(ConnectionLatency(minimumMs: 250, maximumMs: 600)), "Custom · 250–600 ms")
        XCTAssertEqual(ConditionsRowText.latencyPlaceholder(nil), "Unknown")
        XCTAssertEqual(ConditionsRowText.speedPlaceholder(ShapingReading()), "Custom")

        let cachedText = try String(contentsOf: Self.fixtures.appendingPathComponent("conditions/app-probe-music-app-cached.txt"), encoding: .utf8)
        let cached = AppConditionsSnapshot.parse(cachedText, package: Self.music)
        XCTAssertEqual(ConditionsRowText.processLine(cached, apiLevel: 37), "pid 3310 · cached · frozen · trim level 0")
        let killedText = try String(contentsOf: Self.fixtures.appendingPathComponent("conditions/app-probe-music-app-killed.txt"), encoding: .utf8)
        let killed = AppConditionsSnapshot.parse(killedText, package: Self.music)
        XCTAssertEqual(
            ConditionsRowText.processLine(killed, apiLevel: 37),
            "Not running · last exit: USER REQUESTED · KILL BACKGROUND at 2026-09-25 13:36:21.126"
        )
        // Profile 0 reads back as full signal at once, so it is not offered.
        XCTAssertEqual(SignalProfile.allCases.map(\.rawValue), [1, 2, 3, 4])
        XCTAssertEqual(SignalProfile.weak.label, "1 · 25%")
        XCTAssertEqual(
            DeviceConditionsController.shapingMessage(ShapingProfile(speed: .edge, latency: LatencyPreset.gsm.latency)),
            "Set speed EDGE, latency 150–550 ms"
        )
        XCTAssertEqual(DeviceConditionsController.shapingMessage(.neutral), "Speed and latency off")
    }
}
