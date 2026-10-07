import CryptoKit
import XCTest
@testable import DeviceHubProKit

/// Byte-exact output of the API 37 emulator under
/// `Fixtures/api37-emulator/language-time`, captured with `adb exec-out` (the
/// probes with `LanguageTimeIntegrationTests.testCaptureProbeFixtures`):
/// - `cmd-locale-help.txt`: `cmd locale help` (stdout; the command exits 255
///   and writes nothing to stderr)
/// - `cmd-locale-list-device-locales.txt`: `cmd locale list-device-locales`
/// - `helper-supported.txt`: the language helper's `supported`
/// - `am-get-config-*.txt`: `am get-config` with the device set to tr-TR,de-DE,en-US;
///   to zh-Hans-CN,he-IL,en-US-u-mu-celsius; and to ar-EG
/// - `settings-get-system-system_locales-zh-he-en.txt`: the persisted list then
/// - `helper-get-zh-he-en.txt`, `helper-set-en-US-settle.txt`: the helper's `get`
///   then, and its `set en-US,zh-Hans-CN en-US` back
/// - `support-probe*.txt`, `readings-probe*.txt`: the two probes (command and output)
/// - `cmd-time_zone_detector-get_time_zone_state.txt`
/// - `cmd-notification-list-time-zone-changed.txt`: `cmd notification list` right
///   after Automatic time zone went back on from a manually set zone
/// - the Language Restore round trip (`LanguageTimeControllerTests`): the device
///   on en-US-u-mu-celsius (`readings-probe-en-US-celsius.txt`,
///   `am-get-config-en-US-celsius.txt`), the helper's `set tr-TR,en-US tr-TR`
///   from there (`helper-set-tr-TR-settle.txt`), the device on tr-TR
///   (`readings-probe-tr-TR.txt`, `am-get-config-tr-TR.txt`) and the helper's
///   `set en-US-u-mu-celsius,tr-TR en-US-u-mu-celsius` back
///   (`helper-set-en-US-celsius-settle.txt`); the emulator then went back to en-US
/// - the Automatic time zone reset (`LanguageTimeControllerTests`): `cmd
///   notification list` without the notification (`cmd-notification-list.txt`),
///   `settings get global time_zone_notifications`, `cmd time_zone_detector
///   is_auto_detection_enabled` with the switch on and off, and, after `cmd alarm
///   set-timezone Asia/Tokyo` (which prints nothing), `get_time_zone_state` and the
///   readings probe (`*-Asia-Tokyo.txt`); the zone, the switch, the notification
///   setting and the detector state were then put back
enum LanguageTimeFixture {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/api37-emulator/language-time", isDirectory: true)

    static func text(_ name: String) throws -> String {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        return try XCTUnwrap(String(data: data, encoding: .utf8), "\(name) is UTF-8")
    }

    static func support() throws -> LanguageTimeSupport {
        LanguageTimeSupport.parse(try text("support-probe.txt"))
    }
}

final class LanguageTimeTests: XCTestCase {
    private func locales(_ tags: String) -> [DeviceLocale] { DeviceLocaleList.parse(tags) }

    // MARK: - Tags

    func testTagsAreNormalizedTheWayAndroidWritesThem() throws {
        XCTAssertEqual(DeviceLocale(tag: "iw-IL")?.tag, "he-IL", "Java's legacy code for Hebrew")
        XCTAssertEqual(DeviceLocale(tag: "in-ID")?.tag, "id-ID")
        XCTAssertEqual(DeviceLocale(tag: "ji")?.tag, "yi")
        XCTAssertEqual(DeviceLocale(tag: "zh-hans-cn")?.tag, "zh-Hans-CN")
        XCTAssertEqual(DeviceLocale(tag: "en_us")?.tag, "en-US")
        XCTAssertEqual(DeviceLocale(tag: "es-419")?.region, "419")

        let celsius = try XCTUnwrap(DeviceLocale(tag: "en-US-u-mu-celsius"))
        XCTAssertEqual(celsius.baseTag, "en-US")
        XCTAssertEqual(celsius.extensions, "u-mu-celsius")
        XCTAssertEqual(celsius.tag, "en-US-u-mu-celsius")

        XCTAssertTrue(DeviceLocale(tag: "en-XA")?.isPseudo == true)
        XCTAssertTrue(DeviceLocale(tag: "ar-XB")?.isPseudo == true)
        for garbage in ["", "1a", "en--US", "e", "tr TR", "tr-TR;reboot"] {
            XCTAssertNil(DeviceLocale(tag: garbage), garbage)
        }
    }

    func testListsParseAndIgnoreNull() {
        XCTAssertEqual(DeviceLocaleList.tags(locales("tr-TR,de-DE,en-US")), "tr-TR,de-DE,en-US")
        XCTAssertEqual(locales("null\n"), [])
        XCTAssertEqual(locales(""), [])
    }

    // MARK: - Configuration read-back

    func testTheConfigurationNamesTheLanguageList() throws {
        XCTAssertEqual(
            DeviceLocaleList.fromConfiguration(try LanguageTimeFixture.text("am-get-config-tr-de-en.txt")),
            locales("tr-TR,de-DE,en-US")
        )
        // Scripts come as b+zh+Hans+CN; the configuration carries no extensions.
        XCTAssertEqual(
            DeviceLocaleList.fromConfiguration(try LanguageTimeFixture.text("am-get-config-zh-he-en.txt")),
            locales("zh-Hans-CN,he-IL,en-US")
        )
        XCTAssertEqual(
            DeviceLocaleList.fromConfiguration(try LanguageTimeFixture.text("am-get-config-ar-EG.txt")),
            locales("ar-EG")
        )
        XCTAssertEqual(
            DeviceLocaleList.fromConfiguration(try ControlsAPI37Fixture.text("am-get-config.txt")),
            locales("en-US")
        )
    }

    func testAConfigurationWithoutALanguageHasNoList() throws {
        // The real en-US line with its locale qualifier removed.
        let line = try ControlsAPI37Fixture.text("am-get-config.txt")
            .replacingOccurrences(of: "-en-rUS", with: "")
        XCTAssertNil(DeviceLocaleList.fromConfiguration(line))
        XCTAssertNil(DeviceLocaleList.fromConfiguration("abi: arm64-v8a\n"))
    }

    func testTheRestorableListKeepsRegionalPreferencesOnlyWhenItMatches() throws {
        let configuration = try XCTUnwrap(
            DeviceLocaleList.fromConfiguration(try LanguageTimeFixture.text("am-get-config-zh-he-en.txt"))
        )
        let persisted = locales(try LanguageTimeFixture.text("settings-get-system-system_locales-zh-he-en.txt"))
        XCTAssertEqual(
            DeviceLocaleList.restorable(configuration: configuration, persisted: persisted),
            locales("zh-Hans-CN,he-IL,en-US-u-mu-celsius")
        )
        // A persisted list the configuration does not run is stale: never restored.
        XCTAssertEqual(
            DeviceLocaleList.restorable(configuration: locales("tr-TR"), persisted: persisted),
            locales("tr-TR")
        )
    }

    func testRightToLeftLanguages() {
        for tag in ["ar-EG", "he-IL", "fa-IR", "ur-PK", "ar-XB"] {
            XCTAssertTrue(DeviceLocaleList.isRightToLeft(DeviceLocale(tag: tag)!), tag)
        }
        for tag in ["en-US", "tr-TR", "en-XA", "zh-Hans-CN"] {
            XCTAssertFalse(DeviceLocaleList.isRightToLeft(DeviceLocale(tag: tag)!), tag)
        }
    }

    // MARK: - Device language lists

    func testTheHelperListsTheSameLanguagesAsTheCommand() throws {
        let command = try LanguageTimeFixture.text("cmd-locale-list-device-locales.txt")
            .components(separatedBy: .newlines).compactMap(DeviceLocale.init(tag:))
        let helper = try LanguageTimeFixture.text("helper-supported.txt")
            .components(separatedBy: .newlines).compactMap(DeviceLocale.init(tag:))
        XCTAssertEqual(command.count, 672)
        // The resource still says iw-IL / in-ID; normalized, the lists agree.
        XCTAssertTrue(try LanguageTimeFixture.text("helper-supported.txt").contains("iw-IL"))
        XCTAssertEqual(Set(helper.map(\.tag)), Set(command.map(\.tag)))
    }

    func testPresetsResolveAgainstTheDeviceList() throws {
        let support = try LanguageTimeFixture.support()
        let presets = DeviceLocalePresets.resolved(against: support.deviceLocales).map(\.tag)
        XCTAssertEqual(presets, [
            "en-US", "en-GB", "de-DE", "fr-FR", "es-ES", "pt-BR", "ru-RU", "tr-TR",
            "ar-EG", "he-IL", "ja-JP", "zh-Hans-CN", "hi-IN", "en-XA", "ar-XB",
        ], "zh-CN is listed as zh-Hans-CN; ar-EG resolves to the plain tag, not ar-EG-u-nu-latn")

        let withoutList = DeviceLocalePresets.resolved(against: nil)
        XCTAssertFalse(withoutList.contains(where: \.isPseudo), "only some images ship the pseudo-locales")
    }

    func testNamesComeFromCLDR() {
        XCTAssertEqual(DeviceLocaleNames.nativeName(DeviceLocale(tag: "tr-TR")!), "Türkçe (Türkiye)")
        XCTAssertEqual(DeviceLocaleNames.englishName(DeviceLocale(tag: "tr-TR")!), "Turkish (Türkiye)")
        XCTAssertEqual(DeviceLocaleNames.nativeName(DeviceLocale(tag: "en-XA")!), "Pseudo (accented English)")
        XCTAssertTrue(DeviceLocaleNames.englishName(DeviceLocale(tag: "ar-EG-u-nu-latn")!).contains("Western Digits"))
    }

    // MARK: - Support probe

    func testTheSupportProbeFindsEveryVerbOnAPI37() throws {
        XCTAssertEqual(LanguageTimeSupport.probeScript(), try LanguageTimeFixture.text("support-probe.command.txt"))
        let support = try LanguageTimeFixture.support()
        XCTAssertEqual(support.apiLevel, 37)
        XCTAssertTrue(support.setDeviceLocaleCommand)
        XCTAssertTrue(support.listDeviceLocalesCommand)
        XCTAssertTrue(support.alarmSetTime)
        XCTAssertTrue(support.alarmSetTimeZone)
        XCTAssertTrue(support.timeZoneDetector)
        XCTAssertTrue(support.timeDetector)
        XCTAssertTrue(support.timeZoneStateForTests)
        XCTAssertTrue(support.localeHelper)
        XCTAssertEqual(support.deviceLocales.count, 672)
    }

    /// SOURCE-DERIVED: the help of LocaleManagerShellCommand before
    /// android-16.0.0_r4 is the captured help without the three device-locale
    /// verbs it added (set-device-locale, get-device-locale, list-device-locales).
    func testImagesBeforeAPI36Point1HaveNoDeviceLocaleCommand() throws {
        let help = try LanguageTimeFixture.text("cmd-locale-help.txt")
        let lines = help.components(separatedBy: "\n")
        let cut = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("  set-device-locale") })
        let olderHelp = lines[..<cut].joined(separator: "\n")
        let output = "@@devicehubpro-lt:sdk\n36\n@@devicehubpro-lt:locale-help\n\(olderHelp)\n@@devicehubpro-lt:locale-list\n"
        let support = LanguageTimeSupport.parse(output)
        XCTAssertFalse(support.setDeviceLocaleCommand)
        XCTAssertFalse(support.listDeviceLocalesCommand)
        XCTAssertTrue(support.canSetDeviceLanguage, "the helper still writes the language")
        XCTAssertFalse(support.alarmSetTime, "no alarm help section answered")
    }

    // MARK: - Readings probe

    func testTheReadingsProbeReadsEveryRow() throws {
        let support = try LanguageTimeFixture.support()
        XCTAssertEqual(
            LanguageTimeReadings.probeScript(support: support),
            try LanguageTimeFixture.text("readings-probe.command.txt")
        )
        let readings = LanguageTimeReadings.parse(try LanguageTimeFixture.text("readings-probe.txt"))
        XCTAssertEqual(try XCTUnwrap(readings.deviceEpochSeconds), 1_790_333_788.784255, accuracy: 0.000001)
        XCTAssertEqual(readings.utcOffsetSeconds, 3 * 3600)
        XCTAssertEqual(readings.locales, locales("en-US"))
        XCTAssertEqual(readings.persistedLocales, locales("en-US"))
        XCTAssertEqual(readings.timeZoneID, "Europe/Istanbul")
        XCTAssertEqual(readings.autoTimeZone, true)
        XCTAssertEqual(readings.autoTime, true)
        XCTAssertEqual(readings.timeFormat, .localeDefault)
        XCTAssertEqual(readings.restorableLocales, locales("en-US"))
    }

    func testDetectorsAreAskedOnlyWhereTheyExist() {
        var support = LanguageTimeSupport()
        support.apiLevel = 30
        let script = LanguageTimeReadings.probeScript(support: support)
        XCTAssertFalse(script.contains("time_zone_detector"))
        XCTAssertFalse(script.contains("time_detector"))
    }

    func testAutomaticKeysDefaultToOn() {
        XCTAssertEqual(LanguageTimeReadings.autoSetting("null"), true)
        XCTAssertEqual(LanguageTimeReadings.autoSetting("0\n"), false)
        XCTAssertNil(LanguageTimeReadings.autoSetting("maybe"))
    }

    // MARK: - Time zone and clock readings

    func testDetectorStateAndNotification() throws {
        XCTAssertEqual(
            TimeZoneDetectorState.parse(try LanguageTimeFixture.text("cmd-time_zone_detector-get_time_zone_state.txt")),
            TimeZoneDetectorState(zoneID: "Europe/Istanbul", userShouldConfirmID: true)
        )
        let list = try LanguageTimeFixture.text("cmd-notification-list-time-zone-changed.txt")
        XCTAssertTrue(TimeZoneChangeNotification.isPosted(in: list))
        let withoutIt = list.components(separatedBy: "\n").filter { !$0.contains("TimeZoneDetector") }
        XCTAssertFalse(TimeZoneChangeNotification.isPosted(in: withoutIt.joined(separator: "\n")))
    }

    func testTheResetCaptures() throws {
        XCTAssertEqual(
            TimeZoneDetectorState.parse(
                try LanguageTimeFixture.text("cmd-time_zone_detector-get_time_zone_state-Asia-Tokyo.txt")
            ),
            TimeZoneDetectorState(zoneID: "Asia/Tokyo", userShouldConfirmID: false),
            "a manual zone leaves the detector confident"
        )
        XCTAssertFalse(TimeZoneChangeNotification.isPosted(in: try LanguageTimeFixture.text("cmd-notification-list.txt")))
        XCTAssertEqual(
            LanguageTimeReadings.detectorBoolean(
                try LanguageTimeFixture.text("cmd-time_zone_detector-is_auto_detection_enabled-true.txt")
            ),
            true
        )
        XCTAssertEqual(
            LanguageTimeReadings.detectorBoolean(
                try LanguageTimeFixture.text("cmd-time_zone_detector-is_auto_detection_enabled-false.txt")
            ),
            false
        )
        XCTAssertEqual(try LanguageTimeFixture.text("settings-get-global-time_zone_notifications.txt"), "null\n")

        let tokyo = LanguageTimeReadings.parse(try LanguageTimeFixture.text("readings-probe-Asia-Tokyo.txt"))
        XCTAssertEqual(tokyo.timeZoneID, "Asia/Tokyo")
        XCTAssertEqual(tokyo.utcOffsetSeconds, 32_400)
        XCTAssertEqual(tokyo.autoTimeZone, false)

        let celsius = LanguageTimeReadings.parse(try LanguageTimeFixture.text("readings-probe-en-US-celsius.txt"))
        XCTAssertEqual(celsius.locales, locales("en-US"))
        XCTAssertEqual(celsius.restorableLocales, locales("en-US-u-mu-celsius"))
        let turkish = LanguageTimeReadings.parse(try LanguageTimeFixture.text("readings-probe-tr-TR.txt"))
        XCTAssertEqual(turkish.restorableLocales, locales("tr-TR"))
        XCTAssertEqual(
            DeviceLocaleList.fromConfiguration(try LanguageTimeFixture.text("am-get-config-tr-TR.txt")),
            locales("tr-TR")
        )

        let toTurkish = LocaleHelper.Output.parse(try LanguageTimeFixture.text("helper-set-tr-TR-settle.txt"))
        XCTAssertEqual(toTurkish.current, locales("en-US-u-mu-celsius"))
        XCTAssertEqual(toTurkish.applied, [locales("tr-TR,en-US"), locales("tr-TR")])
        let back = LocaleHelper.Output.parse(try LanguageTimeFixture.text("helper-set-en-US-celsius-settle.txt"))
        XCTAssertEqual(back.final, locales("en-US-u-mu-celsius"), "the helper keeps the extension")
    }

    func testNumericZonesAndGMTLabels() {
        XCTAssertEqual(TimeZonePresets.offsetSeconds(fromNumericZone: "+0300\n"), 10_800)
        XCTAssertEqual(TimeZonePresets.offsetSeconds(fromNumericZone: "-0330"), -12_600)
        XCTAssertEqual(TimeZonePresets.offsetSeconds(fromNumericZone: "+0545"), 20_700)
        XCTAssertNil(TimeZonePresets.offsetSeconds(fromNumericZone: "EEST"))
        XCTAssertEqual(TimeZonePresets.gmtLabel(offsetSeconds: 32_400), "GMT+09:00")
        XCTAssertEqual(TimeZonePresets.gmtLabel(offsetSeconds: -12_600), "GMT-03:30")
        XCTAssertEqual(TimeZonePresets.gmtLabel(offsetSeconds: 0), "GMT")
        for identifier in TimeZonePresets.identifiers {
            XCTAssertNotNil(TimeZone(identifier: identifier), identifier)
        }
    }

    func testTimeFormatSetting() {
        XCTAssertEqual(TimeFormatSetting.parse("24\n"), .twentyFourHour)
        XCTAssertEqual(TimeFormatSetting.parse("12"), .twelveHour)
        XCTAssertEqual(TimeFormatSetting.parse("null"), .localeDefault)
        XCTAssertNil(TimeFormatSetting.parse("13"))
        XCTAssertFalse(TimeFormatSetting.localeUses24Hour(DeviceLocale(tag: "en-US")!))
        XCTAssertTrue(TimeFormatSetting.localeUses24Hour(DeviceLocale(tag: "en-GB")!))
        XCTAssertTrue(TimeFormatSetting.localeUses24Hour(DeviceLocale(tag: "tr-TR")!))
        XCTAssertFalse(TimeFormatSetting.localeUses24Hour(DeviceLocale(tag: "hi-IN")!))
    }

    // MARK: - Helper

    func testHelperOutput() throws {
        let get = LocaleHelper.Output.parse(try LanguageTimeFixture.text("helper-get-zh-he-en.txt"))
        XCTAssertEqual(get.current, locales("zh-Hans-CN,he-IL,en-US-u-mu-celsius"))
        XCTAssertEqual(get.applied, [])

        let set = LocaleHelper.Output.parse(try LanguageTimeFixture.text("helper-set-en-US-settle.txt"))
        XCTAssertEqual(set.current, locales("zh-Hans-CN,he-IL,en-US-u-mu-celsius"))
        XCTAssertEqual(set.applied, [locales("en-US,zh-Hans-CN"), locales("en-US")])
        XCTAssertEqual(set.final, locales("en-US"))
    }

    func testHelperCommandDeletesTheDexWhateverHappens() {
        XCTAssertEqual(
            LocaleHelper.runCommand(
                devicePath: "/data/local/tmp/devicehubpro-locales-0a1b2c3d.dex",
                arguments: LocaleHelper.setArguments([locales("tr-TR,en-US"), locales("tr-TR")])
            ),
            "CLASSPATH=/data/local/tmp/devicehubpro-locales-0a1b2c3d.dex app_process / DeviceHubProLocales set tr-TR,en-US tr-TR; "
                + "status=$?; rm -f /data/local/tmp/devicehubpro-locales-0a1b2c3d.dex; exit $status"
        )
        XCTAssertNotEqual(LocaleHelper.devicePath(), LocaleHelper.devicePath(), "each run has its own file")
    }

    func testBundledHelperIsTheBuiltDex() throws {
        let data = try Data(contentsOf: try LocaleHelper.bundledDexURL())
        XCTAssertEqual(data.count, 3964)
        XCTAssertEqual(
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            "821d80041b64177599c18f25e3dd88a822e4ccd94bec4ba0dcac0cc320ea4924",
            "rebuild with Scripts/build-locale-helper.sh and update the pin and the helper README"
        )
    }

    // MARK: - Write plan

    func testANewPrimaryLanguageGetsTheSettlePushThroughTheHelper() throws {
        let support = try LanguageTimeFixture.support()
        let result = try DeviceLocaleWritePlan.plan(target: locales("tr-TR"), current: locales("en-US"), support: support)
        XCTAssertEqual(result.plan.route, .helper([locales("tr-TR,en-US"), locales("tr-TR")]))
        XCTAssertEqual(result.fallback?.route, .command(DeviceLocale(tag: "tr-TR")!))
    }

    func testTheCommandWritesWhenThePrimaryStays() throws {
        let support = try LanguageTimeFixture.support()
        let result = try DeviceLocaleWritePlan.plan(
            target: locales("en-GB"),
            current: locales("en-GB,en-US"),
            support: support
        )
        XCTAssertEqual(result.plan.route, .command(DeviceLocale(tag: "en-GB")!))
    }

    func testListsAndExtensionsGoThroughTheHelper() throws {
        let support = try LanguageTimeFixture.support()
        let list = try DeviceLocaleWritePlan.plan(target: locales("de-DE,en-US"), current: locales("en-US"), support: support)
        XCTAssertEqual(list.plan.route, .helper([locales("de-DE"), locales("de-DE,en-US")]))
        XCTAssertNil(list.fallback)

        let celsius = try DeviceLocaleWritePlan.plan(
            target: locales("en-US-u-mu-celsius"),
            current: locales("en-US"),
            support: support
        )
        XCTAssertEqual(celsius.plan.route, .helper([locales("en-US-u-mu-celsius")]), "same primary: no settle")
    }

    func testOlderImagesUseTheHelperAndTheOldestNothing() throws {
        var api30 = LanguageTimeSupport()
        api30.apiLevel = 30
        let result = try DeviceLocaleWritePlan.plan(target: locales("tr-TR"), current: locales("en-US"), support: api30)
        XCTAssertEqual(result.plan.route, .helper([locales("tr-TR,en-US"), locales("tr-TR")]))
        XCTAssertNil(result.fallback)

        var api25 = LanguageTimeSupport()
        api25.apiLevel = 25
        XCTAssertThrowsError(try DeviceLocaleWritePlan.plan(target: locales("tr-TR"), current: nil, support: api25))
        XCTAssertThrowsError(try DeviceLocaleWritePlan.plan(target: [], current: nil, support: api30))
    }

    func testSettleListsKeepTheNewPrimary() {
        XCTAssertEqual(
            DeviceLocaleWritePlan.settleList(for: locales("tr-TR"), previousPrimary: DeviceLocale(tag: "en-US")),
            locales("tr-TR,en-US")
        )
        XCTAssertEqual(
            DeviceLocaleWritePlan.settleList(for: locales("en-US,tr-TR"), previousPrimary: DeviceLocale(tag: "tr-TR")),
            locales("en-US")
        )
        XCTAssertEqual(DeviceLocaleWritePlan.settleList(for: locales("en-US"), previousPrimary: nil), locales("en-US,en-GB"))
    }

    // MARK: - Commands

    func testTimeZoneTurnsAutomaticOffFirstAndReadsTheZoneBack() async throws {
        let adb = try FakeAdb([
            .init("is_auto_detection_enabled", output: "false\n"),
            .init("getprop persist.sys.timezone", output: "Asia/Tokyo\n"),
        ])
        try await adb.client.setTimeZone(serial: "emulator-5554", identifier: "Asia/Tokyo", support: try LanguageTimeFixture.support())
        let calls = adb.calls
        let autoOff = try XCTUnwrap(calls.firstIndex(of: "-s emulator-5554 shell settings put global auto_time_zone 0"))
        let set = try XCTUnwrap(calls.firstIndex(of: "-s emulator-5554 shell cmd alarm set-timezone Asia/Tokyo"))
        XCTAssertLessThan(autoOff, set)
    }

    func testAnIgnoredTimeZoneIsReported() async throws {
        let adb = try FakeAdb([
            .init("is_auto_detection_enabled", output: "false\n"),
            .init("getprop persist.sys.timezone", output: "Europe/Istanbul\n"),
        ])
        do {
            try await adb.client.setTimeZone(serial: "emulator-5554", identifier: "Mars/Olympus", support: try LanguageTimeFixture.support())
            XCTFail("cmd alarm set-timezone ignores an unknown zone; the read-back must catch it")
        } catch let error as LanguageTimeError {
            XCTAssertEqual(error, .notApplied("the time zone Mars/Olympus"))
        }
    }

    func testArgumentsAreValidatedBeforeReachingTheShell() async throws {
        let adb = try FakeAdb([])
        let support = try LanguageTimeFixture.support()
        do {
            try await adb.client.setTimeZone(serial: "emulator-5554", identifier: "UTC; reboot", support: support)
            XCTFail("a zone with shell syntax must be refused")
        } catch let error as LanguageTimeError {
            guard case .invalidArgument = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(adb.calls, [])
    }

    func testAutomaticTimeZoneFallsBackToTheDetectorCommand() async throws {
        let adb = try FakeAdb([.init("is_auto_detection_enabled", output: "true\n")])
        do {
            try await adb.client.setAutomaticTimeZone(serial: "emulator-5554", enabled: false, support: try LanguageTimeFixture.support())
            XCTFail("a detector that never agrees must be reported")
        } catch let error as LanguageTimeError {
            XCTAssertEqual(error, .notApplied("Automatic time zone"))
        }
        XCTAssertTrue(adb.calls.contains("-s emulator-5554 shell settings put global auto_time_zone 0"))
        XCTAssertTrue(adb.calls.contains("-s emulator-5554 shell cmd time_zone_detector set_auto_detection_enabled false"))
    }

    func testAutomaticTimeConfirmedByTheDetector() async throws {
        let adb = try FakeAdb([.init("time_detector is_auto_detection_enabled", output: "true\n")])
        let outcome = try await adb.client.setAutomaticTime(
            serial: "emulator-5554",
            enabled: true,
            support: try LanguageTimeFixture.support()
        )
        XCTAssertEqual(outcome, .applied)
        XCTAssertFalse(adb.calls.contains { $0.contains("set_auto_detection_enabled") })
    }

    func testTheClockIsSetInMillisecondsComputedOnTheMac() async throws {
        XCTAssertEqual(
            AdbClient.setTimeArguments(epochMilliseconds: 1_790_336_075_793),
            ["cmd", "alarm", "set-time", "1790336075793"],
            "no device-shell arithmetic, which is 32-bit"
        )
        let target = Date().addingTimeInterval(3600)
        let adb = try FakeAdb([
            .init("time_detector is_auto_detection_enabled", output: "false\n"),
            .init("EPOCHREALTIME", output: String(format: "%.6f\n", target.timeIntervalSince1970)),
        ])
        try await adb.client.setDeviceClock(
            serial: "emulator-5554",
            epochMilliseconds: Int64(target.timeIntervalSince1970 * 1000),
            support: try LanguageTimeFixture.support()
        )
        XCTAssertTrue(adb.calls.contains("-s emulator-5554 shell settings put global auto_time 0"))
    }

    func testAClockTheDeviceIgnoredIsReported() async throws {
        let adb = try FakeAdb([
            .init("time_detector is_auto_detection_enabled", output: "false\n"),
            .init("EPOCHREALTIME", output: "1790333788.784255\n"),
        ])
        do {
            try await adb.client.setDeviceClock(
                serial: "emulator-5554",
                epochMilliseconds: 1_890_000_000_000,
                support: try LanguageTimeFixture.support()
            )
            XCTFail("set-time reports success even when the clock did not move")
        } catch let error as LanguageTimeError {
            XCTAssertEqual(error, .notApplied("the date and time"))
        }
    }

    func testTimeFormatWritesOrDeletesTheKey() {
        XCTAssertEqual(AdbClient.timeFormatArguments(.twentyFourHour), ["settings", "put", "system", "time_12_24", "24"])
        XCTAssertEqual(AdbClient.timeFormatArguments(.twelveHour), ["settings", "put", "system", "time_12_24", "12"])
        XCTAssertEqual(AdbClient.timeFormatArguments(.localeDefault), ["settings", "delete", "system", "time_12_24"])
    }

    func testTheNotificationClearRestoresTheSetting() async throws {
        let adb = try FakeAdb([
            .init("notification list", output: try LanguageTimeFixture.text("cmd-notification-list-time-zone-changed.txt")),
            .init("settings get global time_zone_notifications", output: "null\n"),
        ])
        let cleared = try await adb.client.clearTimeZoneChangeNotification(serial: "emulator-5554")
        XCTAssertTrue(cleared)
        let calls = adb.calls
        let off = try XCTUnwrap(calls.firstIndex(of: "-s emulator-5554 shell settings put global time_zone_notifications 0"))
        let restore = try XCTUnwrap(calls.firstIndex(of: "-s emulator-5554 shell settings delete global time_zone_notifications"))
        XCTAssertLessThan(off, restore)
    }
}
