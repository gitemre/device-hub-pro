import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The Controls panel on its own, over a stub adb: which poll applies, what
/// the probes hide and bring back, the once-per-device TalkBack read, the
/// fold animation's hold on the posture and hinge, and the recovery card's
/// signal; then the model's old names over the one controller.
///
/// The stub answers with the API 37 emulator's captures under
/// `DeviceHubProKitTests/Fixtures/api37-emulator/controls`, byte-exact. No test
/// sets a port an emulator serves: the recovery test's port has nothing
/// listening, so its gRPC half answers nothing.
@MainActor
final class DeviceControlsControllerTests: XCTestCase {
    private static let serial = "emulator-5580"
    private static let otherSerial = "emulator-5582"
    /// Nothing can listen here (port 0; a user may bind port 1 on macOS).
    private static let silentPort = EmulatorManager.unreachableGrpcPort

    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("DeviceHubProKitTests/Fixtures/api37-emulator/controls")

    /// A panel on `adb` whose context mirrors `serial` (no port unless
    /// given, so the gRPC half reads nothing).
    private func makePanel(
        adb: AdbClient?,
        serial: String? = DeviceControlsControllerTests.serial,
        port: Int? = nil
    ) -> (panel: DeviceControlsController, context: ActiveDeviceContext) {
        let context = ActiveDeviceContext()
        context.serial = serial
        context.port = port
        return (DeviceControlsController(adbClient: adb, context: context, status: StatusCenter()), context)
    }

    /// A phone connected over Wi-Fi loses its link when Wi-Fi or airplane mode
    /// goes off: those two rows are not shown, the others are.
    func testAWirelessPhoneHidesWifiAndAirplaneRows() {
        for serial in ["192.168.1.20:5555", "adb-ABC123-xyz._adb-tls-connect._tcp"] {
            let (panel, _) = makePanel(adb: nil, serial: serial)
            panel.controls.wifiEnabled = true
            panel.controls.airplaneModeEnabled = false
            panel.controls.mobileDataEnabled = true
            XCTAssertFalse(panel.showsWifiRow, serial)
            XCTAssertFalse(panel.showsAirplaneModeRow, serial)
            XCTAssertNotNil(panel.controls.mobileDataEnabled)
        }
        let (usb, _) = makePanel(adb: nil, serial: "R58M123ABC")
        usb.controls.wifiEnabled = true
        usb.controls.airplaneModeEnabled = false
        XCTAssertTrue(usb.showsWifiRow)
        XCTAssertTrue(usb.showsAirplaneModeRow)
    }

    /// A Xiaomi phone that denies injected input says so with the stage
    /// banner's message instead of the volume keys failing silently.
    /// SOURCE-DERIVED: the denial's text is the scrcpy console's capture
    /// (`logcat-scrcpy-inject-denied.txt`) shape: a SecurityException naming
    /// INJECT_EVENTS.
    func testADeniedVolumeKeyRaisesTheXiaomiMessage() async throws {
        let adb = try makeStubAdb(arms: """
          "-s \(Self.serial) shell input keyevent 24")
            echo 'java.lang.SecurityException: Injecting input events requires the caller to have the INJECT_EVENTS permission.' >&2
            exit 255 ;;
          "-s \(Self.serial) shell input keyevent 25")
            exit 0 ;;
        """)
        let context = ActiveDeviceContext()
        context.serial = Self.serial
        let status = StatusCenter()
        let panel = DeviceControlsController(adbClient: adb.client, context: context, status: status)

        let ok = await panel.sendKeyEvent("25", serial: Self.serial, adb: adb.client)
        XCTAssertEqual(ok, .sent)
        XCTAssertNil(status.errorMessage)
        let denied = await panel.sendKeyEvent("24", serial: Self.serial, adb: adb.client)
        XCTAssertEqual(denied, .denied)
        XCTAssertEqual(status.errorMessage, XiaomiInputBlock.bannerText)
    }

    /// Stub arms answering every poll read on `serial` with its capture.
    /// `settings list system` answers only while `systemAnswers` exists;
    /// the device-effects probe has no arm and fails (it feeds no probe).
    private func answeringArms(_ serial: String, systemAnswers: URL? = nil) -> String {
        func fixture(_ name: String) -> String {
            AdbClient.shellQuoted(Self.fixtures.appendingPathComponent(name).path)
        }
        let systemGate = systemAnswers.map { "[ -f \(AdbClient.shellQuoted($0.path)) ] || exit 1\n    " } ?? ""
        return """
          "-s \(serial) shell settings list global")
            cat \(fixture("settings-list-global.txt")) ;;
          "-s \(serial) shell settings list system")
            \(systemGate)cat \(fixture("settings-list-system.txt")) ;;
          "-s \(serial) shell settings list secure")
            cat \(fixture("settings-list-secure.txt")) ;;
          "-s \(serial) shell cmd media_session volume --stream 3 --get")
            cat \(fixture("cmd-media_session-volume-stream-3-get.txt")) ;;
          "-s \(serial) shell cmd uimode night")
            cat \(fixture("cmd-uimode-night.txt")) ;;
          "-s \(serial) shell cmd netpolicy get restrict-background")
            cat \(fixture("cmd-netpolicy-get-restrict-background.txt")) ;;
          "-s \(serial) shell pm list packages")
            cat \(fixture("pm-list-packages.txt")) ;;
        """
    }

    // MARK: Stale polls

    /// A poll whose reads were still running when the hubs moved the panel
    /// to another device (a generation bump and a new serial) applies
    /// nothing: not the loaded flag, not the gRPC half, not the settings.
    func testPollStartedForThePreviousDeviceAppliesNothing() async throws {
        let adb = try makeStubAdb(arms: """
          "-s \(Self.serial) shell"*)
            sleep 1
            exit 1 ;;
        """)
        let (panel, context) = makePanel(adb: adb.client)
        panel.controls.hingeAngle = 90
        panel.deviceSettings.talkBackPackage = "com.google.android.marvin.talkback"

        let poll = Task { await panel.refreshControls() }
        await waitUntil("the poll never reached the first device") {
            !adb.calls(containing: "-s \(Self.serial) shell").isEmpty
        }
        context.controlsGeneration &+= 1
        context.serial = Self.otherSerial
        await poll.value

        XCTAssertFalse(panel.controlsLoaded, "the first device's reads must not mark the next one's panel loaded")
        XCTAssertEqual(panel.controls.hingeAngle, 90, "an empty gRPC half must not be merged")
        XCTAssertEqual(panel.deviceSettings.talkBackPackage, "com.google.android.marvin.talkback")
        XCTAssertEqual(panel.emulatorUnresponsivePolls, 0)
    }

    /// A re-attach to the same serial is a new session too: the bumped
    /// generation alone drops the poll.
    func testPollOutlivedByItsSessionAppliesNothing() async throws {
        let adb = try makeStubAdb(arms: """
          "-s \(Self.serial) shell"*)
            sleep 1
            exit 1 ;;
        """)
        let (panel, context) = makePanel(adb: adb.client)

        let poll = Task { await panel.refreshControls() }
        await waitUntil("the poll never reached the device") {
            !adb.calls(containing: "-s \(Self.serial) shell").isEmpty
        }
        context.controlsGeneration &+= 1
        await poll.value

        XCTAssertFalse(panel.controlsLoaded)
    }

    // MARK: Probes

    /// Three failed `settings list system` reads hide Text Size and the
    /// three system developer toggles, and only those rows; the next answer
    /// brings them back.
    func testThreeFailedNamespaceReadsHideExactlyTheirRows() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceControls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let systemAnswers = directory.appendingPathComponent("system-answers")
        let adb = try makeStubAdb(arms: answeringArms(Self.serial, systemAnswers: systemAnswers))
        let (panel, _) = makePanel(adb: adb.client)
        let systemToggles = DeviceToggle.allCases.filter { $0.namespace == "system" }
        XCTAssertEqual(Set(systemToggles), [.showTaps])

        for failure in 1...SettingsProbe.failureLimit {
            XCTAssertTrue(panel.showsTextSizeRow, "hidden before failure \(failure)")
            await panel.refreshControls()
        }

        XCTAssertEqual(adb.calls(containing: "settings list system").count, 3)
        XCTAssertFalse(panel.showsTextSizeRow)
        for toggle in DeviceToggle.allCases {
            XCTAssertEqual(panel.showsToggle(toggle), !systemToggles.contains(toggle), "\(toggle)")
        }
        assertTheOtherRowsShow(panel)

        FileManager.default.createFile(atPath: systemAnswers.path, contents: nil)
        await panel.refreshControls()

        XCTAssertTrue(panel.showsTextSizeRow, "one answer brings the row back")
        for toggle in DeviceToggle.allCases {
            XCTAssertTrue(panel.showsToggle(toggle), "\(toggle)")
        }
        XCTAssertEqual(panel.deviceSettings.fontScale, .value(1.3))
        XCTAssertEqual(panel.deviceSettings.showTaps, .on)
        assertTheOtherRowsShow(panel)
    }

    /// Every row the answering reads feed, TalkBack included (the capture
    /// lists `com.google.android.marvin.talkback`).
    private func assertTheOtherRowsShow(
        _ panel: DeviceControlsController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(panel.showsAppearanceSection, file: file, line: line)
        XCTAssertTrue(panel.showsReduceMotionRow, file: file, line: line)
        XCTAssertTrue(panel.showsIncreaseContrastRow, file: file, line: line)
        XCTAssertTrue(panel.showsShowBordersRow, file: file, line: line)
        XCTAssertTrue(panel.showsTalkBackRow, file: file, line: line)
        XCTAssertTrue(panel.showsSoundRow, file: file, line: line)
        XCTAssertTrue(panel.showsDataSaverRow, file: file, line: line)
    }

    /// Moving to another device starts every failure count over.
    func testAnotherDeviceStartsTheFailureCountsOver() async throws {
        // No arms: every read fails on both devices.
        let adb = try makeStubAdb(arms: "")
        let (panel, context) = makePanel(adb: adb.client)
        // The slow rows (appearance, data saver) are read every 10 s in the
        // app; here every refresh reads them.
        panel.slowRowInterval = .zero
        for _ in 1...SettingsProbe.failureLimit {
            await panel.refreshControls()
        }
        XCTAssertFalse(panel.showsTextSizeRow)
        XCTAssertFalse(panel.showsAppearanceSection)
        XCTAssertFalse(panel.showsDataSaverRow)
        XCTAssertFalse(panel.showsToggle(.forceRTL))

        context.controlsGeneration &+= 1
        context.serial = Self.otherSerial
        await panel.refreshControls()

        XCTAssertTrue(panel.showsTextSizeRow, "one failure on the new device hides nothing")
        XCTAssertTrue(panel.showsAppearanceSection)
        XCTAssertTrue(panel.showsDataSaverRow)
        XCTAssertTrue(panel.showsToggle(.forceRTL))
    }

    // MARK: TalkBack package

    /// `pm list packages` runs once per device and again once the
    /// device's package set changed (Apps' `packagesChanged`); a change on
    /// another device costs nothing.
    func testTalkBackIsReadOncePerDeviceAndAgainAfterPackagesChanged() async throws {
        let adb = try makeStubAdb(arms: answeringArms(Self.serial) + "\n" + answeringArms(Self.otherSerial))
        let (panel, context) = makePanel(adb: adb.client)
        let reads = { (serial: String) in adb.calls(containing: "-s \(serial) shell pm list packages").count }

        await panel.refreshControls()
        await panel.refreshControls()
        XCTAssertEqual(reads(Self.serial), 1)
        XCTAssertEqual(panel.deviceSettings.talkBackPackage, "com.google.android.marvin.talkback")
        XCTAssertTrue(panel.showsTalkBackRow)

        panel.forgetTalkBackPackage(ifSerial: Self.otherSerial)
        await panel.refreshControls()
        XCTAssertEqual(reads(Self.serial), 1, "another device's install is not this one's")

        panel.forgetTalkBackPackage(ifSerial: Self.serial)
        await panel.refreshControls()
        await panel.refreshControls()
        XCTAssertEqual(reads(Self.serial), 2, "\(adb.calls)")
        XCTAssertEqual(panel.deviceSettings.talkBackPackage, "com.google.android.marvin.talkback")

        context.controlsGeneration &+= 1
        context.serial = Self.otherSerial
        await panel.refreshControls()
        await panel.refreshControls()
        XCTAssertEqual(reads(Self.otherSerial), 1, "the next device reads its own, once")
        XCTAssertEqual(reads(Self.serial), 2)
    }

    // MARK: Slow rows

    /// The slow rows (appearance, data saver) are read on a device's first
    /// beat, not on the beats after it, and a beat that skips them leaves the
    /// last values; another device reads them on its own first beat.
    func testSlowRowsAreReadOnANewDevicesFirstBeatAndKeptBetweenReads() async throws {
        let adb = try makeStubAdb(arms: answeringArms(Self.serial) + "\n" + answeringArms(Self.otherSerial))
        let (panel, context) = makePanel(adb: adb.client)
        let uimode = { (serial: String) in adb.calls(containing: "-s \(serial) shell cmd uimode night").count }
        let netpolicy = { (serial: String) in adb.calls(containing: "-s \(serial) shell cmd netpolicy get restrict-background").count }

        await panel.refreshControls()
        XCTAssertEqual(uimode(Self.serial), 1, "a new device reads the slow rows on its first beat")
        XCTAssertEqual(netpolicy(Self.serial), 1)
        let appearance = try XCTUnwrap(panel.controls.appearance)
        let dataSaver = panel.controls.dataSaverEnabled
        XCTAssertNotNil(dataSaver)

        await panel.refreshControls()
        await panel.refreshControls()
        XCTAssertEqual(uimode(Self.serial), 1, "the beats in between read only the fast rows")
        XCTAssertEqual(netpolicy(Self.serial), 1)
        XCTAssertEqual(panel.controls.appearance, appearance, "a beat that did not read keeps the last value")
        XCTAssertEqual(panel.controls.dataSaverEnabled, dataSaver)

        context.controlsGeneration &+= 1
        context.serial = Self.otherSerial
        await panel.refreshControls()
        XCTAssertEqual(uimode(Self.otherSerial), 1, "the next device reads its slow rows at once")
        XCTAssertEqual(netpolicy(Self.otherSerial), 1)
        XCTAssertEqual(uimode(Self.serial), 1)
    }

    // MARK: Reduce Motion

    /// Arms for a device whose three animation scales read `values`
    /// ("null" = unset), plus the writes it accepts.
    private func scaleArms(_ serial: String, _ values: [String]) -> String {
        var arms = ""
        for (key, value) in zip(AdbClient.animationScaleKeys, values) {
            arms += "  \"-s \(serial) shell settings get global \(key)\") echo \(value) ;;\n"
        }
        arms += "  \"-s \(serial) shell settings put global \"*) exit 0 ;;\n"
        arms += "  \"-s \(serial) shell settings delete global \"*) exit 0 ;;\n"
        return arms
    }

    /// Reduce Motion reads the user's scales once per On (not again while it
    /// is already on), Off writes them back (a key that was unset is deleted)
    /// and forgets them, so the next On reads afresh.
    func testReduceMotionRemembersTheScalesAndOffRestoresThem() async throws {
        let adb = try makeStubAdb(arms: scaleArms(Self.serial, ["0.5", "1.5", "null"]))
        let (panel, _) = makePanel(adb: adb.client)
        let reads = { adb.calls(containing: "-s \(Self.serial) shell settings get global").count }

        await panel.setReduceMotion(true)
        XCTAssertEqual(reads(), 3)
        XCTAssertEqual(panel.animationScalesBeforeReduceMotion[Self.serial]?.values, ["0.5", "1.5", nil])
        await panel.setReduceMotion(true)
        XCTAssertEqual(reads(), 3, "already remembered: no second read")

        await panel.setReduceMotion(false)
        XCTAssertEqual(reads(), 3, "Off reads nothing")
        let writes = adb.calls.filter { $0.contains("settings put global") || $0.contains("settings delete global") }
        XCTAssertEqual(Array(writes.suffix(3)), [
            "-s \(Self.serial) shell settings put global window_animation_scale 0.5",
            "-s \(Self.serial) shell settings put global transition_animation_scale 1.5",
            "-s \(Self.serial) shell settings delete global animator_duration_scale",
        ])
        XCTAssertNil(panel.animationScalesBeforeReduceMotion[Self.serial])

        await panel.setReduceMotion(true)
        XCTAssertEqual(reads(), 6, "the next On reads the scales afresh")
        await panel.setReduceMotion(false)
        XCTAssertEqual(reads(), 6)
    }

    /// A device whose scales already read 0 (an earlier Reduce Motion left
    /// them) records nothing, so Off writes the stock 1.0.
    func testAllZeroScalesAreNotRememberedAndOffWritesTheStockValue() async throws {
        let adb = try makeStubAdb(arms: scaleArms(Self.serial, ["0", "0", "0"]))
        let (panel, _) = makePanel(adb: adb.client)

        await panel.setReduceMotion(true)
        XCTAssertNil(panel.animationScalesBeforeReduceMotion[Self.serial])
        await panel.setReduceMotion(false)
        let puts = adb.calls.filter { $0.contains("settings put global") }.suffix(3)
        XCTAssertEqual(Array(puts), AdbClient.animationScaleKeys.map { "-s \(Self.serial) shell settings put global \($0) 1.0" })
    }

    /// The remembered scales are per serial.
    func testTheRememberedScalesArePerSerial() async throws {
        let adb = try makeStubAdb(arms: scaleArms(Self.serial, ["0.5", "0.5", "0.5"]) + scaleArms(Self.otherSerial, ["2", "2", "2"]))
        let (panel, context) = makePanel(adb: adb.client)

        await panel.setReduceMotion(true)
        context.controlsGeneration &+= 1
        context.serial = Self.otherSerial
        await panel.setReduceMotion(true)
        XCTAssertEqual(panel.animationScalesBeforeReduceMotion[Self.serial]?.values, ["0.5", "0.5", "0.5"])
        XCTAssertEqual(panel.animationScalesBeforeReduceMotion[Self.otherSerial]?.values, ["2", "2", "2"])

        await panel.setReduceMotion(false)
        XCTAssertNil(panel.animationScalesBeforeReduceMotion[Self.otherSerial])
        XCTAssertNotNil(panel.animationScalesBeforeReduceMotion[Self.serial], "the other device's record stays")
        let lastWindow = adb.calls.last { $0.contains("settings put global window_animation_scale") }
        XCTAssertEqual(lastWindow, "-s \(Self.otherSerial) shell settings put global window_animation_scale 2")
    }

    // MARK: Fold animation

    /// While the posture animation or the hinge sender runs, a poll keeps
    /// the posture and hinge angle they set; otherwise the gRPC half
    /// replaces them (here with nothing: there is no port).
    func testPollLeavesThePostureAndHingeAloneWhilePostureIsBusy() async throws {
        let adb = try makeStubAdb(arms: answeringArms(Self.serial))
        let (panel, _) = makePanel(adb: adb.client)
        panel.isPostureBusy = { true }
        panel.controls.posture = .halfOpened
        panel.controls.hingeAngle = 90

        await panel.refreshControls()

        XCTAssertTrue(panel.controlsLoaded)
        XCTAssertEqual(panel.controls.posture, .halfOpened)
        XCTAssertEqual(panel.controls.hingeAngle, 90)
        XCTAssertEqual(panel.controls.wifiEnabled, true, "the rest of the poll still applies")

        panel.isPostureBusy = { false }
        await panel.refreshControls()

        XCTAssertNil(panel.controls.posture)
        XCTAssertNil(panel.controls.hingeAngle)
    }

    // MARK: Recovery

    /// Three polls in a row with a silent gRPC channel count as powered
    /// off, but only while a session runs on an emulator port.
    func testThreeSilentPollsSetNeedsRecovery() async throws {
        let adb = try makeStubAdb(arms: answeringArms(Self.serial))
        let port = Self.silentPort
        let (panel, context) = makePanel(adb: adb.client, port: port)
        addTeardownBlock { await EmulatorControls.closeConnections(port: port) }
        panel.hasSession = { true }

        for poll in 1...DeviceControlsController.unresponsivePollsForRecovery {
            XCTAssertFalse(panel.needsRecovery, "before silent poll \(poll)")
            await panel.refreshControls()
            XCTAssertEqual(panel.emulatorUnresponsivePolls, poll)
        }

        XCTAssertTrue(panel.needsRecovery)
        // Silence is a stuck emulator, not a dead battery: the card must not
        // blame the battery (it read 100 % on the stuck emulator it was found on).
        XCTAssertEqual(panel.recoveryReason, .unresponsive)
        XCTAssertFalse(panel.recoveryReason?.caption.contains("battery") ?? true)
        panel.hasSession = { false }
        XCTAssertFalse(panel.needsRecovery, "no session, no recovery card")
        panel.hasSession = { true }
        context.port = nil
        XCTAssertFalse(panel.needsRecovery, "a physical device has no gRPC state to miss")

        panel.detach()
        XCTAssertEqual(panel.emulatorUnresponsivePolls, 0)
        XCTAssertFalse(panel.controlsLoaded)
    }

    /// A physical device's polls never count as silent.
    func testPollsWithoutAPortNeverCountAsSilent() async throws {
        let adb = try makeStubAdb(arms: answeringArms(Self.serial))
        let (panel, _) = makePanel(adb: adb.client)
        panel.hasSession = { true }

        for _ in 1...DeviceControlsController.unresponsivePollsForRecovery {
            await panel.refreshControls()
        }

        XCTAssertEqual(panel.emulatorUnresponsivePolls, 0)
        XCTAssertFalse(panel.needsRecovery)
    }

    // MARK: Write fence

    private static let phone = AndroidDevice.online("HT4CWJT0000A", model: "Pixel A")

    /// A model mirroring `phone` (no gRPC port) over `adb`, with `others`
    /// online too.
    private func mirroringModel(adb: AdbClient, others: [AndroidDevice] = []) async -> AppModel {
        let model = AppModel.testing(adb: adb)
        model.workspace.mirror.sessionFactoryOverride = { _, _ in FakeMirrorSession() }
        model.inventory.applyWatcherSnapshot([Self.phone] + others, degraded: false)
        await model.mirror(device: Self.phone)
        XCTAssertEqual(model.activeDeviceSerial, Self.phone.serial)
        return model
    }

    /// A settings write that starts and ends while a poll's reads are out
    /// (its global read takes a second) owns the settings rows: the poll
    /// still applies its gRPC half and marks the panel loaded, but drops
    /// every settings row, and the next poll applies them again.
    func testPollOverlappedByAFinishedWriteDropsItsSettingsRows() async throws {
        let serial = Self.phone.serial
        let global = AdbClient.shellQuoted(Self.fixtures.appendingPathComponent("settings-list-global.txt").path)
        let adb = try makeStubAdb(arms: """
          "-s \(serial) shell settings list global")
            sleep 1
            cat \(global) ;;
          "-s \(serial) shell settings put system font_scale 1.3")
            ;;
        \(answeringArms(serial))
        """)
        let model = await mirroringModel(adb: adb.client)

        let poll = Task { await model.workspace.controlsPanel.refreshControls() }
        await waitUntil("the poll never started its global read") {
            !adb.calls(containing: "settings list global").isEmpty
        }
        await model.workspace.controlsPanel.setTextSize(.largest)
        XCTAssertEqual(model.workspace.controlsPanel.deviceSettings.fontScale, .value(1.3), "the write's reconcile landed")
        await poll.value

        XCTAssertTrue(model.workspace.controlsPanel.controlsLoaded)
        XCTAssertNil(model.workspace.controlsPanel.controls.wifiEnabled, "the overlapped poll's global rows are dropped")
        XCTAssertNil(model.workspace.controlsPanel.deviceSettings.talkBackPackage, "and so is its package read")
        XCTAssertEqual(model.workspace.controlsPanel.deviceSettings.fontScale, .value(1.3))

        await model.workspace.controlsPanel.refreshControls()

        XCTAssertEqual(model.workspace.controlsPanel.controls.wifiEnabled, true)
        XCTAssertEqual(model.workspace.controlsPanel.deviceSettings.talkBackPackage, "com.google.android.marvin.talkback")
        model.stopMirror()
    }

    /// A poll that starts while a settings write is in flight reads no
    /// settings at all; it still marks the panel loaded.
    func testPollDuringAWriteReadsNoSettings() async throws {
        let serial = Self.phone.serial
        let adb = try makeStubAdb(arms: """
          "-s \(serial) shell settings put system font_scale 1.3")
            sleep 1 ;;
        \(answeringArms(serial))
        """)
        let model = await mirroringModel(adb: adb.client)

        let write = Task { await model.workspace.controlsPanel.setTextSize(.largest) }
        await waitUntil("the write never reached the device") {
            !adb.calls(containing: "settings put system font_scale").isEmpty
        }
        await model.workspace.controlsPanel.refreshControls()

        XCTAssertTrue(model.workspace.controlsPanel.controlsLoaded)
        XCTAssertTrue(adb.calls(containing: "settings list").isEmpty, "\(adb.calls)")
        XCTAssertTrue(adb.calls(containing: "pm list packages").isEmpty, "\(adb.calls)")
        XCTAssertNil(model.workspace.controlsPanel.controls.wifiEnabled)
        XCTAssertEqual(model.workspace.controlsPanel.deviceSettings.fontScale, .value(1.3), "the optimistic value stands")

        await write.value
        XCTAssertEqual(adb.calls(containing: "settings list system").count, 1, "the write's own reconcile")
        model.stopMirror()
    }

    // MARK: Device switch

    /// The next device's panel shows none of the previous device's settings
    /// while its first poll is out: ControlsView renders the groups under
    /// the loading card, so a stale TalkBack row or text size would show on
    /// a device that may have neither.
    func testNextDeviceShowsNoStaleSettingsRowsWhileLoading() async throws {
        let phoneB = AndroidDevice.online("HT4CWJT0000B", model: "Pixel B")
        let adb = try makeStubAdb(arms: answeringArms(Self.phone.serial))
        let model = await mirroringModel(adb: adb.client, others: [phoneB])
        await model.workspace.controlsPanel.refreshControls()
        XCTAssertTrue(model.workspace.controlsPanel.showsTalkBackRow)
        XCTAssertEqual(model.workspace.controlsPanel.deviceSettings.fontScale, .value(1.3))
        XCTAssertEqual(model.workspace.controlsPanel.deviceSettings.showTaps, .on)
        XCTAssertNotNil(model.workspace.controlsPanel.deviceSettings.mediaVolume)

        await model.mirror(device: phoneB)

        XCTAssertEqual(model.activeDeviceSerial, phoneB.serial)
        XCTAssertFalse(model.workspace.controlsPanel.controlsLoaded, "the loading card is up")
        XCTAssertFalse(model.workspace.controlsPanel.showsTalkBackRow, "the previous device's TalkBack row must not show")
        XCTAssertNil(model.workspace.controlsPanel.deviceSettings.talkBackPackage)
        XCTAssertNil(model.workspace.controlsPanel.deviceSettings.fontScale)
        XCTAssertNil(model.workspace.controlsPanel.deviceSettings.showTaps)
        XCTAssertNil(model.workspace.controlsPanel.deviceSettings.mediaVolume)
        model.stopMirror()
    }

    /// `detach()` empties the settings rows with the rest of the panel.
    func testDetachEmptiesTheSettingsRows() {
        let (panel, _) = makePanel(adb: nil)
        panel.deviceSettings.talkBackPackage = "com.google.android.marvin.talkback"
        panel.deviceSettings.fontScale = .value(1.3)
        panel.controls.wifiEnabled = true
        panel.controlsLoaded = true

        panel.detach()

        XCTAssertNil(panel.deviceSettings.talkBackPackage)
        XCTAssertNil(panel.deviceSettings.fontScale)
        XCTAssertFalse(panel.showsTalkBackRow)
        XCTAssertNil(panel.controls.wifiEnabled)
        XCTAssertFalse(panel.controlsLoaded)
    }

    // MARK: Model wiring

    /// The model's old names read and write the one controller, its hooks
    /// reach the session, the fold workers and the Location draft, and the
    /// teardown hub detaches it.
    func testModelNamesForwardToTheControllerAndTeardownDetachesIt() async {
        let model = AppModel.testing(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        model.workspace.mirror.sessionFactoryOverride = { _, _ in FakeMirrorSession() }
        let phone = AndroidDevice.online("HT4CWJT0000A", model: "Pixel A")
        model.inventory.applyWatcherSnapshot([phone], degraded: false)

        model.workspace.controlsPanel.controls.wifiEnabled = true
        XCTAssertEqual(model.controlsPanel.controls.wifiEnabled, true)
        model.controlsPanel.deviceSettings.talkBackPackage = "com.google.android.marvin.talkback"
        XCTAssertEqual(model.workspace.controlsPanel.deviceSettings.talkBackPackage, "com.google.android.marvin.talkback")
        model.workspace.controlsPanel.controlsLoaded = true
        XCTAssertTrue(model.controlsPanel.controlsLoaded)

        XCTAssertFalse(model.controlsPanel.hasSession())
        await model.mirror(device: phone)
        XCTAssertTrue(model.controlsPanel.hasSession())

        XCTAssertFalse(model.controlsPanel.isPostureBusy())
        model.workspace.hardware.setPostureAnimated(.closed)
        XCTAssertTrue(model.controlsPanel.isPostureBusy(), "the animation owns the posture")

        model.controlsPanel.locationPolled(GpsFix(latitude: 1, longitude: 2))
        XCTAssertEqual(model.workspace.location.locationLatText, "1.0000")

        model.workspace.controlsPanel.controls.wifiEnabled = true
        model.workspace.controlsPanel.controlsLoaded = true
        model.stopMirror()

        XCTAssertFalse(model.controlsPanel.hasSession())
        XCTAssertFalse(model.controlsPanel.isPostureBusy(), "the teardown cancels the animation")
        XCTAssertNil(model.workspace.controlsPanel.controls.wifiEnabled)
        XCTAssertFalse(model.workspace.controlsPanel.controlsLoaded)
    }
}
