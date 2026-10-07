import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The Language & time group over a stub adb answering with the API 37
/// emulator's captures (`DeviceHubProKitTests/Fixtures/api37-emulator/language-time`,
/// byte-exact): the probes that decide the rows, the poll's fences, the
/// writes' rollbacks, and what the rows say.
@MainActor
final class LanguageTimeControllerTests: XCTestCase {
    private static let serial = "emulator-5580"

    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("DeviceHubProKitTests/Fixtures/api37-emulator/language-time")

    private func fixture(_ name: String) -> String {
        AdbClient.shellQuoted(Self.fixtures.appendingPathComponent(name).path)
    }

    private func fixtureText(_ name: String) throws -> String {
        try String(contentsOf: Self.fixtures.appendingPathComponent(name), encoding: .utf8)
    }

    /// Arms answering both probes on `serial` with their captures; `extra`
    /// arms come first.
    private func probeArms(_ serial: String = LanguageTimeControllerTests.serial, extra: String = "") -> String {
        """
        \(extra)
          "-s \(serial) shell echo @@devicehubpro-lt:sdk"*)
            cat \(fixture("support-probe.txt")) ;;
          "-s \(serial) shell echo @@devicehubpro-lt:clock"*)
            cat \(fixture("readings-probe.txt")) ;;
        """
    }

    private func makeController(
        adb: AdbClient?,
        serial: String? = LanguageTimeControllerTests.serial,
        port: Int? = 5581
    ) -> (LanguageTimeController, ActiveDeviceContext, StatusCenter) {
        let context = ActiveDeviceContext()
        context.serial = serial
        context.port = port
        let status = StatusCenter()
        return (LanguageTimeController(adbClient: adb, context: context, status: status), context, status)
    }

    // MARK: - Poll and rows

    func testTheFirstPollProbesTheDeviceAndShowsEveryRow() async throws {
        let adb = try makeStubAdb(arms: probeArms())
        let (controller, _, _) = makeController(adb: adb.client)

        XCTAssertFalse(controller.showsLanguageRow, "nothing shows before the device answers")
        await controller.refresh()

        XCTAssertEqual(controller.support?.apiLevel, 37)
        XCTAssertEqual(controller.deviceLocales.count, 672)
        XCTAssertEqual(controller.readings?.timeZoneID, "Europe/Istanbul")
        XCTAssertNotNil(controller.readingsHostDate)
        for (name, shows) in [
            ("language", controller.showsLanguageRow),
            ("date & time", controller.showsDateTimeRow),
            ("time zone", controller.showsTimeZoneRow),
            ("24-hour", controller.showsTimeFormatRow),
        ] {
            XCTAssertTrue(shows, name)
        }

        await controller.refresh()
        XCTAssertEqual(adb.calls(containing: "@@devicehubpro-lt:sdk").count, 1, "support is probed once per device")
        XCTAssertEqual(adb.calls(containing: "@@devicehubpro-lt:clock").count, 2)
    }

    /// SOURCE-DERIVED: no API 30 or API 27 image was available, so their
    /// answers to the support probe (`support-probe.command.txt`) are derived
    /// from AOSP:
    /// - neither starts a `locale` service (SystemServer, android-11.0.0_r1 and
    ///   android-8.1.0_r1), so `cmd locale help` prints `cmd: Can't find
    ///   service: locale` (frameworks/native cmds/cmd/cmd.cpp in both tags);
    /// - API 30's `cmd alarm help` lists `  set-time TIME` and `  set-timezone TZ`
    ///   (AlarmManagerService.ShellCmd.onHelp, android-11.0.0_r1), while the
    ///   API 27 AlarmManagerService has no shell command (android-8.1.0_r1);
    /// - API 30's time_zone_detector shell offers only the two suggest verbs
    ///   (TimeZoneDetectorShellCommand, android-11.0.0_r1), its TimeDetectorService
    ///   has no shell command, and API 27 has neither service, so both greps
    ///   print nothing.
    func testRowsOfMissingMechanismsStayHidden() async throws {
        let api30 = """
        @@devicehubpro-lt:sdk
        30
        @@devicehubpro-lt:locale-help
        cmd: Can't find service: locale
        @@devicehubpro-lt:locale-list
        @@devicehubpro-lt:alarm-help
          set-time TIME
          set-timezone TZ
        @@devicehubpro-lt:tzd-help
        @@devicehubpro-lt:td-help

        """
        let api27 = """
        @@devicehubpro-lt:sdk
        27
        @@devicehubpro-lt:locale-help
        cmd: Can't find service: locale
        @@devicehubpro-lt:locale-list
        @@devicehubpro-lt:alarm-help
        @@devicehubpro-lt:tzd-help
        @@devicehubpro-lt:td-help

        """
        for (api, answer, setsTheClock) in [(30, api30, true), (27, api27, false)] {
            let probe = FileManager.default.temporaryDirectory
                .appendingPathComponent("lt-support-\(api)-\(UUID().uuidString).txt")
            try Data(answer.utf8).write(to: probe)
            addTeardownBlock { try? FileManager.default.removeItem(at: probe) }
            let adb = try makeStubAdb(arms: """
              "-s \(Self.serial) shell echo @@devicehubpro-lt:sdk"*)
                cat \(AdbClient.shellQuoted(probe.path)) ;;
              "-s \(Self.serial) shell echo @@devicehubpro-lt:clock"*)
                cat \(fixture("readings-probe.txt")) ;;
            """)
            let (controller, _, _) = makeController(adb: adb.client)
            await controller.refresh()

            XCTAssertEqual(controller.support?.apiLevel, api)
            XCTAssertTrue(controller.showsLanguageRow, "API \(api): the helper writes the language from API 26")
            XCTAssertEqual(controller.showsDateTimeRow, setsTheClock, "API \(api): cmd alarm set-time from API 28")
            XCTAssertEqual(controller.showsTimeZoneRow, setsTheClock, "API \(api): cmd alarm set-timezone from API 28")
            XCTAssertTrue(controller.showsTimeFormatRow, "API \(api)")
        }
    }

    func testThreeFailedReadsHideTheRowsAndAnAnswerBringsThemBack() async throws {
        let gate = FileManager.default.temporaryDirectory.appendingPathComponent("lt-gate-\(UUID().uuidString)")
        let adb = try makeStubAdb(arms: """
          "-s \(Self.serial) shell echo @@devicehubpro-lt:sdk"*)
            cat \(fixture("support-probe.txt")) ;;
          "-s \(Self.serial) shell echo @@devicehubpro-lt:clock"*)
            [ -f \(AdbClient.shellQuoted(gate.path)) ] || exit 1
            cat \(fixture("readings-probe.txt")) ;;
        """)
        let (controller, _, _) = makeController(adb: adb.client)
        for _ in 0..<3 { await controller.refresh() }
        XCTAssertNil(controller.readings)
        XCTAssertFalse(controller.showsTimeFormatRow)

        try Data().write(to: gate)
        defer { try? FileManager.default.removeItem(at: gate) }
        await controller.refresh()
        XCTAssertTrue(controller.showsTimeFormatRow)
        XCTAssertEqual(controller.readings?.autoTime, true)
    }

    func testAPollForThePreviousDeviceAppliesNothing() async throws {
        let adb = try makeStubAdb(arms: probeArms(extra: """
          "-s \(Self.serial) shell echo @@devicehubpro-lt:clock"*)
            sleep 1
            cat \(fixture("readings-probe.txt")) ;;
        """))
        let (controller, context, _) = makeController(adb: adb.client)
        await controller.refresh()
        controller.detach()
        XCTAssertNil(controller.readings)

        let poll = Task { await controller.refresh() }
        await waitUntil { adb.calls(containing: "@@devicehubpro-lt:clock").count >= 2 }
        context.serial = "emulator-5582"
        context.controlsGeneration += 1
        await poll.value
        XCTAssertNil(controller.readings, "the answer belongs to the device the panel left")
    }

    // MARK: - Writes

    func testAFailedTimeZoneWriteRollsBackAndSaysWhy() async throws {
        let adb = try makeStubAdb(arms: probeArms(extra: """
          "-s \(Self.serial) shell cmd time_zone_detector get_time_zone_state")
            cat \(fixture("cmd-time_zone_detector-get_time_zone_state.txt")) ;;
          "-s \(Self.serial) shell settings put global auto_time_zone 0")
            exit 0 ;;
          "-s \(Self.serial) shell cmd time_zone_detector is_auto_detection_enabled")
            echo false ;;
          "-s \(Self.serial) shell cmd alarm set-timezone Mars/Olympus")
            exit 0 ;;
          "-s \(Self.serial) shell getprop persist.sys.timezone")
            echo Europe/Istanbul ;;
        """))
        let (controller, _, status) = makeController(adb: adb.client)
        await controller.refresh()

        await controller.setTimeZone("Mars/Olympus")
        XCTAssertEqual(controller.readings?.timeZoneID, "Europe/Istanbul", "rolled back")
        XCTAssertEqual(controller.readings?.autoTimeZone, true)
        XCTAssertEqual(status.errorMessage, "The device did not apply the time zone Mars/Olympus.")
        XCTAssertTrue(controller.writeFence.isIdle)
    }

    /// A write that fails after the panel moved to another device rolls
    /// nothing back onto it: its rows are that device's, not this one's.
    func testAWriteFinishingAfterADeviceSwitchRollsNothingBack() async throws {
        let adb = try makeStubAdb(arms: probeArms(extra: """
          "-s \(Self.serial) shell cmd time_zone_detector get_time_zone_state")
            cat \(fixture("cmd-time_zone_detector-get_time_zone_state.txt")) ;;
          "-s \(Self.serial) shell settings put global auto_time_zone 0")
            exit 0 ;;
          "-s \(Self.serial) shell cmd time_zone_detector is_auto_detection_enabled")
            echo false ;;
          "-s \(Self.serial) shell cmd alarm set-timezone Mars/Olympus")
            sleep 1
            exit 0 ;;
          "-s \(Self.serial) shell getprop persist.sys.timezone")
            echo Europe/Istanbul ;;
        """))
        let (controller, context, _) = makeController(adb: adb.client)
        await controller.refresh()

        let write = Task { await controller.setTimeZone("Mars/Olympus") }
        await waitUntil { adb.calls(containing: "set-timezone").count >= 1 }
        context.serial = "emulator-5582"
        context.controlsGeneration += 1
        controller.detach()
        await write.value
        XCTAssertNil(controller.readings, "the other device's rows are not overwritten by the old device's rollback")
    }

    /// The records kept per serial belong to the AVD that was on it.
    func testAnotherAvdOnTheSerialDoesNotInheritTheRecordedLanguages() async throws {
        let adb = try makeStubAdb(arms: probeArms())
        let (controller, context, _) = makeController(adb: adb.client)
        context.avdName = "Pixel_9"
        await controller.refresh()
        await controller.setTimeFormat(.twentyFourHour)
        controller.emulatorExited(serial: Self.serial)
        XCTAssertNil(controller.originalLocales[Self.serial])
    }

    /// Language Restore over the emulator's captures: the device on
    /// en-US-u-mu-celsius, set to tr-TR (the helper's settle push first), then
    /// restored. Every answer is the capture of that command in that state.
    func testLanguageRestorePutsTheCapturedListBack() async throws {
        let state = try stateDirectory()
        let turkish = AdbClient.shellQuoted(state.appendingPathComponent("tr-TR").path)
        let adb = try makeStubAdb(arms: probeArms(extra: """
          "-s \(Self.serial) push "*)
            exit 0 ;;
          "-s \(Self.serial) shell CLASSPATH="*"DeviceHubProLocales set tr-TR,en-US tr-TR;"*)
            touch \(turkish)
            cat \(fixture("helper-set-tr-TR-settle.txt")) ;;
          "-s \(Self.serial) shell CLASSPATH="*"DeviceHubProLocales set en-US-u-mu-celsius,tr-TR en-US-u-mu-celsius;"*)
            rm -f \(turkish)
            cat \(fixture("helper-set-en-US-celsius-settle.txt")) ;;
          "-s \(Self.serial) shell am get-config")
            if [ -f \(turkish) ]; then cat \(fixture("am-get-config-tr-TR.txt")); else cat \(fixture("am-get-config-en-US-celsius.txt")); fi ;;
          "-s \(Self.serial) shell echo @@devicehubpro-lt:clock"*)
            if [ -f \(turkish) ]; then cat \(fixture("readings-probe-tr-TR.txt")); else cat \(fixture("readings-probe-en-US-celsius.txt")); fi ;;
        """))
        let (controller, _, status) = makeController(adb: adb.client)
        await controller.refresh()
        let original = DeviceLocaleList.parse("en-US-u-mu-celsius")
        XCTAssertEqual(controller.readings?.restorableLocales, original)
        XCTAssertNil(controller.restorableOriginal, "nothing to restore before the panel changes the list")

        await controller.setDeviceLanguage(DeviceLocale(tag: "tr-TR")!)
        XCTAssertNil(status.errorMessage)
        XCTAssertEqual(controller.originalLocales[Self.serial], original, "the regional preference is kept")
        XCTAssertEqual(controller.readings?.locales, DeviceLocaleList.parse("tr-TR"))
        XCTAssertEqual(controller.restorableOriginal, original)
        XCTAssertEqual(
            adb.calls(containing: "DeviceHubProLocales set").count, 1,
            "one helper run carries the settle push and the target"
        )

        await controller.restoreDeviceLanguages()
        XCTAssertNil(status.errorMessage)
        XCTAssertEqual(
            adb.calls(containing: "DeviceHubProLocales set en-US-u-mu-celsius,tr-TR en-US-u-mu-celsius;").count, 1,
            "the captured list goes back with its extension"
        )
        XCTAssertEqual(controller.readings?.locales, DeviceLocaleList.parse("en-US"))
        XCTAssertNil(controller.restorableOriginal, "the list is back, so Restore hides")
        XCTAssertEqual(controller.originalLocales[Self.serial], original, "kept for a later change")
    }

    // MARK: - Automatic time zone reset

    /// A fresh directory for a stub's state files.
    private func stateDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lt-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// A stub device whose zone, Automatic time zone switch and "Time zone
    /// changed" notification follow the writes, each answer a capture of that
    /// command in that state: `set-timezone` moves the zone, Automatic time
    /// zone on brings back the network zone (Europe/Istanbul), and the
    /// notification stays posted until `time_zone_notifications` goes to 0.
    private func zoneStub(startingIn zone: String, automatic: Bool) throws -> StubAdb {
        let state = try stateDirectory()
        let zoneFile = AdbClient.shellQuoted(state.appendingPathComponent("zone").path)
        let autoFile = AdbClient.shellQuoted(state.appendingPathComponent("auto").path)
        let clearedFile = AdbClient.shellQuoted(state.appendingPathComponent("cleared").path)
        try Data("\(zone)\n".utf8).write(to: state.appendingPathComponent("zone"))
        if automatic { try Data().write(to: state.appendingPathComponent("auto")) }
        return try makeStubAdb(arms: probeArms(extra: """
          "-s \(Self.serial) shell echo @@devicehubpro-lt:clock"*)
            case "$(cat \(zoneFile))" in
              Asia/Tokyo) cat \(fixture("readings-probe-Asia-Tokyo.txt")) ;;
              *) cat \(fixture("readings-probe.txt")) ;;
            esac ;;
          "-s \(Self.serial) shell cmd time_zone_detector get_time_zone_state")
            case "$(cat \(zoneFile))" in
              Asia/Tokyo) cat \(fixture("cmd-time_zone_detector-get_time_zone_state-Asia-Tokyo.txt")) ;;
              *) cat \(fixture("cmd-time_zone_detector-get_time_zone_state.txt")) ;;
            esac ;;
          "-s \(Self.serial) shell settings put global auto_time_zone 0")
            rm -f \(autoFile) ;;
          "-s \(Self.serial) shell settings put global auto_time_zone 1")
            touch \(autoFile)
            echo Europe/Istanbul > \(zoneFile) ;;
          "-s \(Self.serial) shell cmd time_zone_detector is_auto_detection_enabled")
            if [ -f \(autoFile) ]; then
              cat \(fixture("cmd-time_zone_detector-is_auto_detection_enabled-true.txt"))
            else
              cat \(fixture("cmd-time_zone_detector-is_auto_detection_enabled-false.txt"))
            fi ;;
          "-s \(Self.serial) shell cmd alarm set-timezone "*)
            echo "$*" | awk '{ print $NF }' > \(zoneFile) ;;
          "-s \(Self.serial) shell getprop persist.sys.timezone")
            cat \(zoneFile) ;;
          "-s \(Self.serial) shell cmd notification list")
            if [ -f \(clearedFile) ]; then
              cat \(fixture("cmd-notification-list.txt"))
            else
              cat \(fixture("cmd-notification-list-time-zone-changed.txt"))
            fi ;;
          "-s \(Self.serial) shell settings get global time_zone_notifications")
            cat \(fixture("settings-get-global-time_zone_notifications.txt")) ;;
          "-s \(Self.serial) shell settings put global time_zone_notifications 0")
            touch \(clearedFile) ;;
          "-s \(Self.serial) shell settings delete global time_zone_notifications")
            exit 0 ;;
          "-s \(Self.serial) shell cmd time_zone_detector set_time_zone_state_for_tests "*)
            exit 0 ;;
        """))
    }

    private static let restoreIstanbul =
        "-s \(serial) shell cmd time_zone_detector set_time_zone_state_for_tests --zone_id Europe/Istanbul --user_should_confirm_id true"

    /// The zone moves back to the one captured before the pick: the posted
    /// notification is cleared (its setting put back), then the detector's
    /// state is restored; the capture is used once.
    func testAutomaticTimeZoneResetClearsTheNotificationAndRestoresTheDetector() async throws {
        let adb = try zoneStub(startingIn: "Europe/Istanbul", automatic: true)
        let (controller, _, status) = makeController(adb: adb.client)
        controller.zoneChangePollInterval = .milliseconds(10)
        await controller.refresh()

        await controller.setTimeZone("Asia/Tokyo")
        XCTAssertNil(status.errorMessage)
        XCTAssertEqual(controller.readings?.timeZoneID, "Asia/Tokyo")
        XCTAssertEqual(adb.calls(containing: "get_time_zone_state").count, 1, "the state before the pick is captured")

        await controller.setAutomaticTimeZone(true)
        XCTAssertNil(status.errorMessage)
        XCTAssertEqual(controller.readings?.timeZoneID, "Europe/Istanbul")
        let calls = adb.calls
        let silenced = try XCTUnwrap(calls.firstIndex(of: "-s \(Self.serial) shell settings put global time_zone_notifications 0"))
        let putBack = try XCTUnwrap(calls.firstIndex(of: "-s \(Self.serial) shell settings delete global time_zone_notifications"))
        let restored = try XCTUnwrap(calls.firstIndex(of: Self.restoreIstanbul))
        XCTAssertLessThan(silenced, putBack, "the setting was null, so it is deleted again")
        XCTAssertLessThan(putBack, restored, "the notification first, then the detector state")

        let before = adb.calls.count
        await controller.setAutomaticTimeZone(true)
        let again = adb.calls.dropFirst(before)
        XCTAssertFalse(again.contains { $0.contains("cmd notification list") }, "the capture was consumed")
        XCTAssertFalse(again.contains { $0.contains("shell cmd time_zone_detector set_time_zone_state_for_tests") }, "the capture was consumed")
    }

    /// A pick of the zone the network also gives: turning Automatic time zone
    /// back on moves nothing, so there is no notification to clear, and the
    /// detector state still goes back (the zone is the captured one).
    func testAutomaticTimeZoneResetWithoutAZoneChangeOnlyRestoresTheDetector() async throws {
        let adb = try zoneStub(startingIn: "Europe/Istanbul", automatic: true)
        let (controller, _, status) = makeController(adb: adb.client)
        controller.zoneChangePollInterval = .milliseconds(10)
        await controller.refresh()

        await controller.setTimeZone("Europe/Istanbul")
        await controller.setAutomaticTimeZone(true)
        XCTAssertNil(status.errorMessage)
        XCTAssertEqual(controller.readings?.timeZoneID, "Europe/Istanbul")
        XCTAssertTrue(adb.calls(containing: "cmd notification list").isEmpty, "the zone did not move")
        XCTAssertTrue(adb.calls(containing: "time_zone_notifications").isEmpty)
        XCTAssertEqual(adb.calls.filter { $0 == Self.restoreIstanbul }.count, 1)
    }

    /// The device was on a manual Asia/Tokyo before the panel picked a zone:
    /// Automatic time zone on moves it to the network zone, so the
    /// notification is cleared, but the captured Tokyo state is not put back
    /// over the network zone.
    func testAutomaticTimeZoneResetKeepsTheDetectorWhenTheZoneDiffersFromTheCapture() async throws {
        let adb = try zoneStub(startingIn: "Asia/Tokyo", automatic: false)
        let (controller, _, status) = makeController(adb: adb.client)
        controller.zoneChangePollInterval = .milliseconds(10)
        await controller.refresh()
        XCTAssertEqual(controller.readings?.autoTimeZone, false)

        await controller.setTimeZone("Asia/Tokyo")
        await controller.setAutomaticTimeZone(true)
        XCTAssertNil(status.errorMessage)
        XCTAssertEqual(controller.readings?.timeZoneID, "Europe/Istanbul")
        XCTAssertEqual(adb.calls(containing: "settings put global time_zone_notifications 0").count, 1)
        XCTAssertTrue(
            adb.calls(containing: "shell cmd time_zone_detector set_time_zone_state_for_tests").isEmpty,
            "Tokyo is not put back over the network zone"
        )
    }

    // MARK: - Language search

    /// The pickers' cached keys answer as the uncached match does, over the
    /// device's whole captured list.
    func testTheLanguageSearchIndexMatchesLikeTheNames() async throws {
        let adb = try makeStubAdb(arms: probeArms())
        let (controller, _, _) = makeController(adb: adb.client)
        XCTAssertFalse(controller.languageSearch.matches(DeviceLocale(tag: "tr-TR")!, query: "xyz"))
        await controller.refresh()
        let locales = controller.deviceLocales
        XCTAssertEqual(locales.count, 672)
        XCTAssertEqual(controller.languageSearch.count, 672, "keyed once, when the list arrives")
        for query in ["turk", "TÜRK", "tr-tr", "German", "deutsch", "arab", "hans", "celsius", "(", "zz"] {
            XCTAssertEqual(
                locales.filter { controller.languageSearch.matches($0, query: query) },
                locales.filter { languageMatches($0, query: query) },
                query
            )
        }
        XCTAssertTrue(controller.languageSearch.matches(DeviceLocale(tag: "de-DE")!, query: "Deutsch"))
        XCTAssertFalse(
            controller.languageSearch.matches(DeviceLocale(tag: "de-DE")!, query: "Germany) de"),
            "a query never spans two fields"
        )
        controller.detach()
        XCTAssertEqual(controller.languageSearch.count, 0)
    }

    func testDetachForgetsTheDeviceButKeepsItsOriginalLanguages() async throws {
        let adb = try makeStubAdb(arms: probeArms())
        let (controller, _, _) = makeController(adb: adb.client)
        await controller.refresh()
        controller.detach()
        XCTAssertNil(controller.support)
        XCTAssertNil(controller.readings)
        XCTAssertTrue(controller.deviceLocales.isEmpty)
        XCTAssertFalse(controller.showsLanguageRow)
    }

    // MARK: - Row models

    func testLanguageValues() {
        XCTAssertEqual(languageValueText(DeviceLocaleList.parse("tr-TR")), "Türkçe (TR)")
        XCTAssertEqual(languageValueText(DeviceLocaleList.parse("tr-TR,de-DE,en-US")), "Türkçe (TR) +2")
        XCTAssertEqual(languageValueText(DeviceLocaleList.parse("en-XA")), "Pseudo (accented English)")
        XCTAssertEqual(languageValueText(nil), "Unknown")
        XCTAssertEqual(languageDetail(DeviceLocale(tag: "tr-TR")!), "Turkish (Türkiye) · tr-TR")
        XCTAssertTrue(languageMatches(DeviceLocale(tag: "tr-TR")!, query: "turk"), "accent-insensitive")
        XCTAssertTrue(languageMatches(DeviceLocale(tag: "tr-TR")!, query: "tr-tr"))
        XCTAssertTrue(languageMatches(DeviceLocale(tag: "de-DE")!, query: "German"))
        XCTAssertFalse(languageMatches(DeviceLocale(tag: "de-DE")!, query: "Japanese"))
    }

    func testLanguageCaptionWarnsWhenAListIsReplaced() {
        XCTAssertNil(languageCaption(current: DeviceLocaleList.parse("en-US")))
        XCTAssertTrue(languageCaption(current: DeviceLocaleList.parse("en-US,de-DE"))?.contains("replaces the list (en-US,de-DE)") == true)
        XCTAssertTrue(languageCaption(current: DeviceLocaleList.parse("en-US-u-mu-celsius"))?.contains("regional preferences") == true)
    }

    func testTimeZoneValues() {
        XCTAssertEqual(timeZoneValueText(identifier: "Asia/Tokyo"), "Tokyo")
        XCTAssertEqual(timeZoneValueText(identifier: "America/Argentina/Buenos_Aires"), "Buenos Aires")
        XCTAssertEqual(timeZoneValueText(identifier: "Etc/UTC"), "UTC")
        XCTAssertEqual(timeZoneValueText(identifier: nil), "Unknown")
        XCTAssertEqual(timeZoneHelpText(identifier: "Asia/Tokyo", offsetSeconds: 32_400), "The device reports Asia/Tokyo (GMT+09:00).")
        XCTAssertNil(timeZoneHelpText(identifier: nil, offsetSeconds: nil))
        XCTAssertEqual(timeZoneDetail("Asia/Kolkata"), "GMT+05:30")
        XCTAssertTrue(timeZoneMatches("America/New_York", query: "new york"))
        XCTAssertFalse(timeZoneMatches("America/New_York", query: "tokyo"))
    }

    func testClockValues() throws {
        let readings = LanguageTimeReadings.parse(try fixtureText("readings-probe.txt"))
        XCTAssertEqual(
            deviceClockText(
                deviceEpochSeconds: readings.deviceEpochSeconds,
                zoneIdentifier: readings.timeZoneID,
                offsetSeconds: readings.utcOffsetSeconds,
                locale: Locale(identifier: "en_GB")
            ),
            "25 Sep at 13:56"
        )
        XCTAssertEqual(clockOffsetText(seconds: 1.4), "In step with the Mac")
        XCTAssertEqual(clockOffsetText(seconds: 3605), "1 h ahead of the Mac")
        XCTAssertEqual(clockOffsetText(seconds: 90_000), "1 day 1 h ahead of the Mac")
        XCTAssertEqual(clockOffsetText(seconds: -300), "5 min behind the Mac")
        XCTAssertEqual(clockOffsetText(seconds: 42), "42 s ahead of the Mac")
    }

    func testTimeFormatTitles() {
        XCTAssertEqual(timeFormatTitle(.localeDefault, locales: DeviceLocaleList.parse("en-US")), "Locale default (12-hour)")
        XCTAssertEqual(timeFormatTitle(.localeDefault, locales: DeviceLocaleList.parse("tr-TR")), "Locale default (24-hour)")
        XCTAssertEqual(timeFormatValueTitle(.localeDefault), "Automatic")
        XCTAssertEqual(timeFormatValueTitle(.twentyFourHour), "24-hour")
        XCTAssertEqual(timeFormatTitle(.localeDefault, locales: nil), "Locale default")
        XCTAssertEqual(timeFormatTitle(.twentyFourHour, locales: nil), "24-hour")
    }
}
