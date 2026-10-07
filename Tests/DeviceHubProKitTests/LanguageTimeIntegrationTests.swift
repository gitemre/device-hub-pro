import XCTest
@testable import DeviceHubProKit

/// The Language & time mechanisms against a live emulator: each write goes
/// through the Kit and each assertion reads the effect from where Android
/// applies it (the configuration, `persist.sys.timezone`, the detectors, the
/// clock), never from the key the write touched. Every test records what it
/// changes first and puts it back in a teardown block, which runs even when an
/// assertion fails. Emulators only (`LiveTestDevices.allowed`, then
/// `isEmulator`): a phone is never touched, even when pinned.
///
/// `DHP_CAPTURE_LANGUAGE_TIME_FIXTURES=<dir>` also writes the probes'
/// commands and outputs there (`testCaptureProbeFixtures`), the source of the
/// `language-time` fixtures.
final class LanguageTimeIntegrationTests: XCTestCase {
    private func onlineEmulator() async throws -> (AdbClient, String) {
        guard let adb = AdbClient.locate() else { throw XCTSkip("adb not found") }
        let devices = try await adb.listDevices()
        guard let serial = LiveTestDevices.allowed(devices).first(where: \.isEmulator)?.serial else {
            throw XCTSkip("no online emulator")
        }
        return (adb, serial)
    }

    private func trimmed(_ adb: AdbClient, _ serial: String, _ arguments: [String]) async throws -> String {
        try await adb.shell(serial: serial, arguments).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Puts a raw settings value back: `null` deletes the key.
    private static func restoreSetting(
        _ adb: AdbClient,
        _ serial: String,
        namespace: String,
        key: String,
        raw: String
    ) async throws {
        if raw == "null" {
            _ = try await adb.shell(serial: serial, ["settings", "delete", namespace, key])
        } else {
            _ = try await adb.shell(serial: serial, ["settings", "put", namespace, key, AdbClient.shellQuoted(raw)])
        }
    }

    /// Reads until `condition` holds or about `seconds` pass.
    private func eventually(
        seconds: Int = 6,
        _ condition: () async throws -> Bool
    ) async throws -> Bool {
        for _ in 0..<(seconds * 4) {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(250))
        }
        return try await condition()
    }

    // MARK: - Language

    func testLanguageListsRoundTripAndKeepRegionalPreferences() async throws {
        let (adb, serial) = try await onlineEmulator()
        let support = try await adb.languageTimeSupport(serial: serial)
        guard support.localeHelper else { throw XCTSkip("the language helper needs API 26") }
        let before = try await adb.languageTimeReadings(serial: serial, support: support)
        let original = try XCTUnwrap(before.restorableLocales, "the configuration names a language")
        addTeardownBlock {
            _ = try await adb.setDeviceLocales(serial: serial, original, support: support)
        }

        let primary = original.first?.language == "de" ? "fr-FR" : "de-DE"
        let list = DeviceLocaleList.parse("\(primary),tr-TR,en-US-u-mu-celsius")
        let outcome = try await adb.setDeviceLocales(serial: serial, list, support: support)
        XCTAssertTrue(DeviceLocaleList.sameLanguages(outcome.applied, list), "\(outcome.applied)")
        XCTAssertTrue(outcome.settled, "a new primary language gets the settle push")

        let after = try await adb.languageTimeReadings(serial: serial, support: support)
        XCTAssertEqual(after.locales.map(DeviceLocaleList.tags), "\(primary),tr-TR,en-US")
        // The configuration drops extensions; the persisted list keeps them.
        XCTAssertEqual(after.persistedLocales.map(DeviceLocaleList.tags), DeviceLocaleList.tags(list))
        XCTAssertEqual(after.restorableLocales, list)
        let persistedPrimary = try await trimmed(adb, serial, ["getprop", "persist.sys.locale"])
        XCTAssertEqual(persistedPrimary, primary)

        // Back through the Kit, extensions and all.
        let restored = try await adb.setDeviceLocales(serial: serial, original, support: support)
        XCTAssertTrue(DeviceLocaleList.sameLanguages(restored.applied, original))
        let final = try await adb.languageTimeReadings(serial: serial, support: support)
        XCTAssertEqual(final.restorableLocales, original)
    }

    func testShorteningTheListKeepsThePrimaryThroughTheCommand() async throws {
        let (adb, serial) = try await onlineEmulator()
        let support = try await adb.languageTimeSupport(serial: serial)
        guard support.localeHelper, support.setDeviceLocaleCommand else {
            throw XCTSkip("needs the helper and cmd locale set-device-locale (API 36.1+)")
        }
        let current = try await adb.languageTimeReadings(serial: serial, support: support)
        let original = try XCTUnwrap(current.restorableLocales)
        addTeardownBlock {
            _ = try await adb.setDeviceLocales(serial: serial, original, support: support)
        }

        let pair = DeviceLocaleList.parse("en-GB,en-US")
        _ = try await adb.setDeviceLocales(serial: serial, pair, support: support)
        let single = DeviceLocaleList.parse("en-GB")
        let outcome = try await adb.setDeviceLocales(serial: serial, single, support: support)
        XCTAssertTrue(outcome.usedCommand, "the primary stays, so cmd locale set-device-locale writes it")
        XCTAssertFalse(outcome.settled)
        let applied = try await adb.shell(serial: serial, ["am", "get-config"])
        XCTAssertEqual(DeviceLocaleList.fromConfiguration(applied).map(DeviceLocaleList.tags), "en-GB")
        let deviceLocale = try await trimmed(adb, serial, ["cmd", "locale", "get-device-locale"])
        XCTAssertEqual(deviceLocale, "en-GB")
    }

    func testForceRTLAppliesLiveThroughTheRepush() async throws {
        let (adb, serial) = try await onlineEmulator()
        let support = try await adb.languageTimeSupport(serial: serial)
        guard support.localeHelper else { throw XCTSkip("the re-push needs API 26") }
        let readings = try await adb.languageTimeReadings(serial: serial, support: support)
        guard let primary = readings.locales?.first, !DeviceLocaleList.isRightToLeft(primary) else {
            throw XCTSkip("needs a left-to-right language")
        }
        let key = try await trimmed(adb, serial, ["settings", "get", "global", "debug.force_rtl"])
        let property = try await trimmed(adb, serial, ["getprop", "debug.force_rtl"])
        addTeardownBlock {
            try await Self.restoreSetting(adb, serial, namespace: "global", key: "debug.force_rtl", raw: key)
            _ = try await adb.shell(serial: serial, ["setprop", "debug.force_rtl", property.isEmpty ? "false" : property])
            try await adb.repushDeviceLocales(serial: serial)
        }

        for enabled in [true, false, true] {
            let outcome = try await adb.setToggle(serial: serial, toggle: .forceRTL, enabled: enabled)
            XCTAssertEqual(outcome, .applied, "Force RTL \(enabled) applies at once")
            let config = try await adb.shell(serial: serial, ["am", "get-config"])
            XCTAssertEqual(DeviceEffects.configurationIsRTL(config), enabled, config)
            let effect = try await adb.deviceEffects(serial: serial).forceRTL
            XCTAssertEqual(effect?.support, .live)
            XCTAssertEqual(effect?.isPending, false)
        }

        // The key written back to 0 alone (the property stays true, nothing
        // re-pushes): the device still runs right to left, so the row reads
        // Off with a restart pending instead of a plain, live Off.
        _ = try await adb.shell(serial: serial, ["settings", "put", "global", "debug.force_rtl", "0"])
        let config = try await adb.shell(serial: serial, ["am", "get-config"])
        XCTAssertEqual(DeviceEffects.configurationIsRTL(config), true, config)
        let mismatch = try await adb.deviceEffects(serial: serial).forceRTL
        XCTAssertEqual(mismatch?.reading, .off)
        XCTAssertEqual(mismatch?.support, .afterRestart)
        XCTAssertEqual(mismatch?.isPending, true)
    }

    // MARK: - Time zone

    func testTimeZoneRoundTripAndTheAutomaticReset() async throws {
        let (adb, serial) = try await onlineEmulator()
        let support = try await adb.languageTimeSupport(serial: serial)
        guard support.alarmSetTimeZone else { throw XCTSkip("cmd alarm set-timezone needs API 28") }
        let zone = try await trimmed(adb, serial, ["getprop", "persist.sys.timezone"])
        let autoKey = try await trimmed(adb, serial, ["settings", "get", "global", "auto_time_zone"])
        let explicitKey = try await trimmed(adb, serial, ["settings", "get", "global", "auto_time_zone_explicit"])
        let notificationsKey = try await trimmed(adb, serial, ["settings", "get", "global", "time_zone_notifications"])
        let detectorState = support.timeZoneStateForTests
            ? try await adb.timeZoneDetectorState(serial: serial)
            : nil
        addTeardownBlock {
            if autoKey != "0" {
                let zoneBefore = try await adb.shell(serial: serial, ["getprop", "persist.sys.timezone"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try await adb.setAutomaticTimeZone(serial: serial, enabled: true, support: support)
                for _ in 0..<20 {
                    let now = try await adb.shell(serial: serial, ["getprop", "persist.sys.timezone"])
                    if now.trimmingCharacters(in: .whitespacesAndNewlines) == zone { break }
                    try await Task.sleep(for: .milliseconds(250))
                }
                _ = try await adb.clearTimeZoneChangeNotification(
                    serial: serial,
                    waitingUpTo: zoneBefore == zone ? .zero : .seconds(5)
                )
            } else {
                try await adb.setTimeZone(serial: serial, identifier: zone, support: support)
            }
            try await Self.restoreSetting(adb, serial, namespace: "global", key: "auto_time_zone", raw: autoKey)
            try await Self.restoreSetting(adb, serial, namespace: "global", key: "auto_time_zone_explicit", raw: explicitKey)
            try await Self.restoreSetting(adb, serial, namespace: "global", key: "time_zone_notifications", raw: notificationsKey)
            if let detectorState {
                try await adb.restoreTimeZoneDetectorState(serial: serial, detectorState)
            }
        }

        let target = zone == "Asia/Tokyo" ? "Asia/Kolkata" : "Asia/Tokyo"
        try await adb.setTimeZone(serial: serial, identifier: target, support: support)
        let readings = try await adb.languageTimeReadings(serial: serial, support: support)
        XCTAssertEqual(readings.timeZoneID, target)
        XCTAssertEqual(readings.utcOffsetSeconds, target == "Asia/Tokyo" ? 9 * 3600 : 19_800)
        XCTAssertEqual(readings.autoTimeZone, false, "choosing a zone turns Automatic time zone off")

        do {
            try await adb.setTimeZone(serial: serial, identifier: "Mars/Olympus", support: support)
            XCTFail("an unknown zone is ignored by the device and must be reported")
        } catch let error as LanguageTimeError {
            XCTAssertEqual(error, .notApplied("the time zone Mars/Olympus"))
        }
        let unchanged = try await trimmed(adb, serial, ["getprop", "persist.sys.timezone"])
        XCTAssertEqual(unchanged, target)

        guard autoKey != "0" else { return }
        // The reset: Automatic time zone on brings the network zone back, and
        // the notification Android posts for that change is cleared.
        try await adb.setAutomaticTimeZone(serial: serial, enabled: true, support: support)
        let back = try await eventually {
            try await self.trimmed(adb, serial, ["getprop", "persist.sys.timezone"]) != target
        }
        XCTAssertTrue(back, "the detector moves the zone back to the network's")
        let cleared = try await adb.clearTimeZoneChangeNotification(serial: serial, waitingUpTo: .seconds(5))
        if (support.apiLevel ?? 0) >= 37 {
            XCTAssertTrue(cleared, "API 37 posts \"Time zone changed\" for the automatic change")
        }
        let list = try await adb.shell(serial: serial, ["cmd", "notification", "list"])
        XCTAssertFalse(TimeZoneChangeNotification.isPosted(in: list), list)
        let notificationsAfter = try await trimmed(adb, serial, ["settings", "get", "global", "time_zone_notifications"])
        XCTAssertEqual(notificationsAfter, notificationsKey, "the notification setting is back as it was")
    }

    // MARK: - Clock

    func testDeviceClockRoundTrip() async throws {
        let (adb, serial) = try await onlineEmulator()
        let support = try await adb.languageTimeSupport(serial: serial)
        guard support.alarmSetTime else { throw XCTSkip("cmd alarm set-time needs API 28") }
        let autoKey = try await trimmed(adb, serial, ["settings", "get", "global", "auto_time"])
        addTeardownBlock {
            if autoKey == "0" {
                try await adb.setDeviceClock(
                    serial: serial,
                    epochMilliseconds: Int64(Date().timeIntervalSince1970 * 1000),
                    support: support
                )
            }
            try await adb.setAutomaticTime(serial: serial, enabled: autoKey != "0", support: support)
            try await Self.restoreSetting(adb, serial, namespace: "global", key: "auto_time", raw: autoKey)
        }

        let target = Date().addingTimeInterval(3600)
        try await adb.setDeviceClock(
            serial: serial,
            epochMilliseconds: Int64(target.timeIntervalSince1970 * 1000),
            support: support
        )
        let readings = try await adb.languageTimeReadings(serial: serial, support: support)
        let offset = try XCTUnwrap(readings.deviceEpochSeconds) - Date().timeIntervalSince1970
        XCTAssertEqual(offset, 3600, accuracy: 5, "the device clock is an hour ahead")
        XCTAssertEqual(readings.autoTime, false, "setting the clock turns Automatic date & time off")

        guard autoKey != "0" else { return }
        try await adb.setAutomaticTime(serial: serial, enabled: true, support: support)
        let synced = try await eventually {
            let now = try await adb.languageTimeReadings(serial: serial, support: support)
            return abs((now.deviceEpochSeconds ?? 0) - Date().timeIntervalSince1970) < 3
        }
        XCTAssertTrue(synced, "Automatic date & time steps the clock back to network time")
    }

    // MARK: - 24-hour time

    func testTimeFormatRoundTrip() async throws {
        let (adb, serial) = try await onlineEmulator()
        let support = try await adb.languageTimeSupport(serial: serial)
        let raw = try await trimmed(adb, serial, ["settings", "get", "system", "time_12_24"])
        addTeardownBlock {
            try await Self.restoreSetting(adb, serial, namespace: "system", key: "time_12_24", raw: raw)
        }

        for setting in [TimeFormatSetting.twentyFourHour, .twelveHour, .localeDefault] {
            try await adb.setTimeFormat(serial: serial, setting)
            let readings = try await adb.languageTimeReadings(serial: serial, support: support)
            XCTAssertEqual(readings.timeFormat, setting)
        }
    }

    // MARK: - Fixture capture

    /// Writes the support and readings probes' commands and outputs to
    /// `DHP_CAPTURE_LANGUAGE_TIME_FIXTURES` (read-only on the device).
    func testCaptureProbeFixtures() async throws {
        guard let path = ProcessInfo.processInfo.environment["DHP_CAPTURE_LANGUAGE_TIME_FIXTURES"],
              !path.isEmpty
        else { throw XCTSkip("set DHP_CAPTURE_LANGUAGE_TIME_FIXTURES to capture") }
        let (adb, serial) = try await onlineEmulator()
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let supportScript = LanguageTimeSupport.probeScript()
        let supportOutput = try await adb.shell(serial: serial, [supportScript])
        try Data(supportScript.utf8).write(to: directory.appendingPathComponent("support-probe.command.txt"))
        try Data(supportOutput.utf8).write(to: directory.appendingPathComponent("support-probe.txt"))

        let support = LanguageTimeSupport.parse(supportOutput)
        let readingsScript = LanguageTimeReadings.probeScript(support: support)
        let readingsOutput = try await adb.shell(serial: serial, [readingsScript])
        try Data(readingsScript.utf8).write(to: directory.appendingPathComponent("readings-probe.command.txt"))
        try Data(readingsOutput.utf8).write(to: directory.appendingPathComponent("readings-probe.txt"))
    }
}
