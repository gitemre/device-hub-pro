import XCTest
@testable import DeviceHubProKit

/// Byte-exact output of the API 37 emulator (emulator-5556, Pixel_9_Pro AVD,
/// sdk_full 37.1) under `Fixtures/api37-emulator/color-filters`:
/// - `readings-probe*.txt`: `adb -s <serial> shell "<script>"` with the two
///   scripts in `readings-probe.command.txt` (with the SurfaceFlinger section)
///   and `readings-probe-keys-only.command.txt`, written by
///   `ColorFilterIntegrationTests.testCaptureProbeFixtures`. Each state was set
///   from a clean start (the four secure keys deleted): `off` (keys absent;
///   also with the keys-only script), `grayscale` (enabled 1, mode 0),
///   `protanopia` / `deuteranopia` / `tritanopia` (1/11, 1/12, 1/13),
///   `deuteranopia-intensity-{0,3,10,7}` (1/12 with the Intensity key),
///   `deuteranopia-intensity-deleted` (the key put to 7, then deleted:
///   SurfaceFlinger keeps 0.7), `mode-unset` (switch on, mode deleted),
///   `mode-garbage` (mode `abc`), `mode-99` / `mode-minus-1` / `mode-10` /
///   `mode-21`, `none-mode-kept` (11, then enabled 0), `inversion` (inversion
///   only), `inversion-grayscale` / `inversion-protanopia`,
///   `protanopia-inversion-off` (inversion 1 then 0 with 11 on),
///   `simulate-{protanopia,deuteranopia,tritanopia}` (modes 1/2/3),
///   `grayscale-recording` (grayscale while `screenrecord --time-limit 3
///   --output-format=h264 -` adds a virtual display), and the values Android
///   parses its own way: `mode-empty` (mode `''`), `mode-space-11` (` 11`),
///   `mode-overflow` (`2147483659`), each with the switch on,
///   `enabled-space-1` (switch ` 1`), `inversion-empty` (inversion `''`)
///   and `inversion-2` (inversion `2`, which API 37 does not draw)
/// - `readings-probe-invalid-user.txt`: the probe with every `settings get`
///   given `--user 99`, a user the emulator does not have
///   (`readings-probe-invalid-user.command.txt`): each exits 255 and prints
///   nothing, so each key's failure marker follows its section
/// - `dumpsys-SurfaceFlinger-comp-displays{,-tritanopia}.txt`: `adb -s <serial>
///   shell "dumpsys SurfaceFlinger --comp-displays"` with no filter and with
///   Tritanopia on (the research captures)
/// - `content-query-secure-*.txt`: `content query --uri
///   content://settings/secure/<key>` for a key that is absent
///   (`accessibility_display_daltonizer`), a NULL row
///   (`accessibility_display_inversion_enabled`), a fresh value row and the same
///   row after a second put (`accessibility_display_daltonizer_enabled`)
/// - `settings-put-bogusns.stderr.txt`: the standard error of `adb -s <serial>
///   shell settings put bogusns x 1` (exit 255, nothing on stdout)
/// The display id is the emulator's hardware hash and ScreenRecorder's id is
/// random; nothing personal is in them. The API level is the controls
/// fixture `getprop-ro.build.version.sdk.txt`.
enum ColorFilterFixture {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/api37-emulator/color-filters", isDirectory: true)

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    static func text(_ name: String) throws -> String {
        let data = try Data(contentsOf: url(name))
        return try XCTUnwrap(String(data: data, encoding: .utf8), "\(name) is UTF-8")
    }

    /// `readings-probe-<state>.txt`, parsed.
    static func readings(_ state: String) throws -> ColorFilterReadings {
        ColorFilterReadings.parse(try text("readings-probe-\(state).txt"), apiLevel: api37)
    }

    /// The dumped matrix line of `readings-probe-<state>.txt`.
    static func matrixLine(_ state: String) throws -> String {
        try XCTUnwrap(
            try text("readings-probe-\(state).txt").components(separatedBy: "\n")
                .first { $0.contains("colorTransformMatrix=") },
            state
        )
    }

    /// Every capture with the SurfaceFlinger section.
    static let displayStates = [
        "off", "grayscale", "protanopia", "deuteranopia", "tritanopia",
        "deuteranopia-intensity-0", "deuteranopia-intensity-3", "deuteranopia-intensity-7",
        "deuteranopia-intensity-10", "deuteranopia-intensity-deleted",
        "mode-unset", "mode-garbage", "mode-99", "mode-minus-1", "mode-10", "mode-21",
        "none-mode-kept", "inversion", "inversion-grayscale", "inversion-protanopia",
        "protanopia-inversion-off", "simulate-protanopia", "simulate-deuteranopia",
        "simulate-tritanopia", "grayscale-recording",
        "mode-empty", "mode-space-11", "mode-overflow", "enabled-space-1", "inversion-empty", "inversion-2",
    ]

    static let api37 = 37
}

final class ColorFiltersTests: XCTestCase {
    // MARK: - Probe

    func testTheProbeScriptsAreTheCapturedCommands() throws {
        XCTAssertEqual(
            ColorFilterReadings.probeScript(support: ColorFilterSupport(apiLevel: 37)),
            try ColorFilterFixture.text("readings-probe.command.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        )
        XCTAssertEqual(
            ColorFilterReadings.probeScript(support: ColorFilterSupport(apiLevel: 32)),
            try ColorFilterFixture.text("readings-probe-keys-only.command.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func testReadingsParseTheSettingAsColorDisplayServiceDoes() throws {
        func setting(_ state: String) throws -> DaltonizerSetting? { try ColorFilterFixture.readings(state).setting }
        XCTAssertEqual(try setting("off"), .filter(.none))
        XCTAssertEqual(try setting("grayscale"), .filter(.grayscale))
        XCTAssertEqual(try setting("protanopia"), .filter(.protanopia))
        XCTAssertEqual(try setting("deuteranopia"), .filter(.deuteranopia))
        XCTAssertEqual(try setting("tritanopia"), .filter(.tritanopia))
        XCTAssertEqual(try setting("mode-unset"), .filter(.deuteranopia), "an unset mode is 12")
        XCTAssertEqual(try setting("mode-garbage"), .filter(.deuteranopia), "an unparseable mode is 12")
        XCTAssertEqual(try setting("none-mode-kept"), .filter(.none), "the switch decides")
        XCTAssertEqual(try setting("mode-99"), .unmapped(99))
        XCTAssertEqual(try setting("mode-minus-1"), .unmapped(-1))
        XCTAssertEqual(try setting("mode-10"), .unmapped(10))
        XCTAssertEqual(try setting("mode-21"), .unmapped(21))
        XCTAssertEqual(try setting("simulate-protanopia"), .simulation(.protanopia))
        XCTAssertEqual(try setting("simulate-deuteranopia"), .simulation(.deuteranopia))
        XCTAssertEqual(try setting("simulate-tritanopia"), .simulation(.tritanopia))

        let kept = try ColorFilterFixture.readings("none-mode-kept")
        XCTAssertEqual(kept.modeRaw, "11", "None keeps the mode")
        XCTAssertFalse(kept.hasTransformSet)

        XCTAssertEqual(try ColorFilterFixture.readings("off").inversion, false)
        XCTAssertEqual(try ColorFilterFixture.readings("inversion").inversion, true)
        XCTAssertEqual(try ColorFilterFixture.readings("protanopia-inversion-off").inversion, false)
        XCTAssertTrue(try ColorFilterFixture.readings("inversion").hasTransformSet)
        XCTAssertTrue(try ColorFilterFixture.readings("mode-99").hasTransformSet, "an unmapped mode is still set")

        XCTAssertEqual(try ColorFilterFixture.readings("deuteranopia-intensity-3").intensity, 3)
        XCTAssertEqual(try ColorFilterFixture.readings("deuteranopia-intensity-10").intensity, 10)
        XCTAssertEqual(try ColorFilterFixture.readings("deuteranopia-intensity-0").intensity, 0)
        XCTAssertEqual(try ColorFilterFixture.readings("deuteranopia-intensity-7").intensity, 7)
        XCTAssertNil(try ColorFilterFixture.readings("deuteranopia-intensity-deleted").intensity)

        let off = try ColorFilterFixture.readings("off")
        let grayscale = off.writing(.grayscale)
        XCTAssertEqual(grayscale.setting, .filter(.grayscale))
        XCTAssertNil(grayscale.display, "the matrix is unknown until the read-back")
        let protanopia = try ColorFilterFixture.readings("protanopia")
        let none = protanopia.writing(.none)
        XCTAssertEqual(none.setting, .filter(.none))
        XCTAssertEqual(none.modeRaw, "11", "None keeps the mode, as the Settings switch does")
        XCTAssertEqual(off.writingInversion(true).inversion, true)
        XCTAssertEqual(off.writingInversion(true).setting, .filter(.none))
    }

    /// `settings get` prints an empty line for an empty value, and Android
    /// reads it as the key's default: the switch and inversion off, the
    /// mode 12 (SurfaceFlinger draws Deuteranomaly correction in the capture).
    func testAnEmptyValueIsAValue() throws {
        let mode = try ColorFilterFixture.readings("mode-empty")
        XCTAssertEqual(mode.modeRaw, "")
        XCTAssertEqual(mode.setting, .filter(.deuteranopia))
        XCTAssertEqual(mode.check(apiLevel: 37), .applied(level: 0.7))

        let inversion = try ColorFilterFixture.readings("inversion-empty")
        XCTAssertEqual(inversion.inversionRaw, "")
        XCTAssertEqual(inversion.inversion, false)
        XCTAssertFalse(inversion.hasTransformSet)
        XCTAssertEqual(inversion.check(apiLevel: 37), .applied(level: nil))
    }

    /// A `settings get` that exits non-zero prints its section's failure
    /// marker: that key is unreadable, not empty.
    func testAFailedReadIsUnreadable() throws {
        let failed = try ColorFilterFixture.readings("invalid-user")
        XCTAssertNil(failed.enabledRaw)
        XCTAssertNil(failed.modeRaw)
        XCTAssertNil(failed.levelRaw)
        XCTAssertNil(failed.inversionRaw)
        XCTAssertNil(failed.setting)
        XCTAssertNil(failed.inversion)
        XCTAssertEqual(failed.display, .matrix(.identity), "the display section is read on its own")
        XCTAssertEqual(failed.check(apiLevel: 37), .unavailable)

        // Test-side truncation of a real capture: a probe cut off after the
        // switch's marker leaves the other sections missing.
        let text = try ColorFilterFixture.text("readings-probe-off.txt")
        let modeMarker = try XCTUnwrap(text.range(of: "@@devicehubpro-cf:mode"))
        let cut = ColorFilterReadings.parse(String(text[..<modeMarker.lowerBound]), apiLevel: 37)
        XCTAssertEqual(cut.enabledRaw, "null")
        XCTAssertNil(cut.modeRaw, "no section")
        XCTAssertNil(cut.setting)
    }

    /// SOURCE-DERIVED: no API 24–25 image was available. `settings` there is
    /// SettingsCmd (android-7.0.0_r1): `run()` catches a settings provider
    /// failure ("Could not find settings provider"), prints "Error while
    /// accessing settings provider" to standard error and returns, and `main`
    /// catches every other exception, so the read exits 0, prints nothing on
    /// standard output and no failure marker is echoed. An answered read
    /// always prints a line (`System.out.println(getForUser(…))`). The output
    /// is the API 37 keys-only capture with the `null` lines of the enabled
    /// and inversion sections removed (test-side edit): those two reads failed.
    private static func failedReadsOnAPI24To25() throws -> String {
        var output = try ColorFilterFixture.text("readings-probe-keys-only-off.txt")
        for marker in ["@@devicehubpro-cf:enabled", "@@devicehubpro-cf:inversion"] {
            let answered = try XCTUnwrap(output.range(of: "\(marker)\nnull\n"), marker)
            output.replaceSubrange(answered, with: "\(marker)\n")
        }
        XCTAssertFalse(output.contains("-failed"), "exit 0: no failure marker")
        return output
    }

    /// SOURCE-DERIVED (`failedReadsOnAPI24To25`): a section with no line is a
    /// read that failed, so the rows read Unknown rather than None and off.
    func testAReadThatPrintsNoLineIsUnreadable() throws {
        let output = try Self.failedReadsOnAPI24To25()
        for apiLevel in [24, 25] {
            let readings = ColorFilterReadings.parse(output, apiLevel: apiLevel)
            XCTAssertNil(readings.enabledRaw, "no line")
            XCTAssertNil(readings.inversionRaw, "no line")
            XCTAssertEqual(readings.modeRaw, "null", "the reads that answered still count")
            XCTAssertEqual(readings.levelRaw, "null")
            XCTAssertNil(readings.setting, "Unknown, not None")
            XCTAssertNil(readings.inversion, "Unknown, not off")
            XCTAssertFalse(readings.hasTransformSet)
            XCTAssertEqual(readings.check(apiLevel: apiLevel), .unavailable)
        }

        // No line is not one empty line: the empty value is a real capture.
        let markers = ColorFilterReadings.Section.allCases.map(\.marker)
        let inversion = "@@devicehubpro-cf:inversion"
        XCTAssertEqual(ColorFilterReadings.sections(output, markers: markers)[inversion], [])
        XCTAssertEqual(
            ColorFilterReadings.sections(try ColorFilterFixture.text("readings-probe-inversion-empty.txt"), markers: markers)[inversion],
            [""]
        )
    }

    /// Settings' getIntForUser parses the stored string as it is, with
    /// `Integer.parseInt`, and uses the default when that throws.
    func testValuesParseAsIntegerParseInt() throws {
        let spacedMode = try ColorFilterFixture.readings("mode-space-11")
        XCTAssertEqual(spacedMode.modeRaw, " 11", "kept as printed")
        XCTAssertEqual(spacedMode.setting, .filter(.deuteranopia), "\" 11\" throws: the mode is 12")
        XCTAssertEqual(spacedMode.check(apiLevel: 37), .applied(level: 0.7), "SurfaceFlinger draws Deuteranomaly")

        let spacedSwitch = try ColorFilterFixture.readings("enabled-space-1")
        XCTAssertEqual(spacedSwitch.enabledRaw, " 1")
        XCTAssertEqual(spacedSwitch.setting, .filter(.none), "\" 1\" throws: the switch is off")
        XCTAssertFalse(spacedSwitch.hasTransformSet)
        XCTAssertEqual(spacedSwitch.check(apiLevel: 37), .applied(level: nil))

        let overflow = try ColorFilterFixture.readings("mode-overflow")
        XCTAssertEqual(overflow.setting, .filter(.deuteranopia), "past Int32: the mode is 12")
        XCTAssertEqual(overflow.check(apiLevel: 37), .applied(level: 0.7))

        // API 37 inverts for 1 only; through API 36 any non-zero value
        // inverts (ColorDisplayService android-16.0.0_r1), so the same keys
        // read as inverted there and SurfaceFlinger's identity as not applied.
        let two = try ColorFilterFixture.readings("inversion-2")
        XCTAssertEqual(two.inversionRaw, "2")
        XCTAssertEqual(two.inversion, false)
        XCTAssertEqual(two.check(apiLevel: 37), .applied(level: nil))
        var twoOnAPI36 = two
        twoOnAPI36.apiLevel = 36
        XCTAssertEqual(twoOnAPI36.inversion, true)
        XCTAssertEqual(twoOnAPI36.check(apiLevel: 36), .notApplied)
        XCTAssertEqual(ColorFilterReadings(apiLevel: nil).writingInversion(true).inversion, true)
        for (support, value, inverts) in [(37, 1, true), (37, 2, false), (37, -1, false), (37, 0, false), (36, 2, true), (24, -1, true), (24, 0, false)] {
            XCTAssertEqual(ColorFilterSupport(apiLevel: support).invertsColors(value), inverts, "API \(support), \(value)")
        }

        // Integer.parseInt's rules (java.lang.Integer; Character.digit).
        let cases: [(String, Int?)] = [
            ("11", 11), ("+11", 11), ("-1", -1), ("0", 0), ("007", 7),
            ("2147483647", 2147483647), ("-2147483648", -2147483648),
            ("2147483648", nil), ("-2147483649", nil), ("2147483659", nil),
            (" 11", nil), ("11 ", nil), ("11\n", nil), ("", nil), ("+", nil), ("-", nil), ("+-1", nil),
            ("null", nil), ("abc", nil), ("1.0", nil), ("0x10", nil), ("1_0", nil),
            ("\u{0661}\u{0661}", 11), ("\u{FF11}\u{FF13}", 13), ("\u{1D7CF}", nil),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(DaltonizerSetting.settingInt(raw), expected, raw.debugDescription)
        }
    }

    // MARK: - Display section

    func testTheDisplaySectionPicksTheFirstEnabledPhysicalDisplay() throws {
        XCTAssertEqual(try ColorFilterFixture.readings("off").display, .matrix(.identity))

        let recording = try ColorFilterFixture.text("readings-probe-grayscale-recording.txt")
        XCTAssertTrue(recording.contains("(virtual, \"ScreenRecorder\")"))
        XCTAssertEqual(
            ColorFilterReadings.parse(recording, apiLevel: 37).display?.matrix,
            try ColorFilterFixture.readings("grayscale").display?.matrix,
            "the physical display's matrix; ScreenRecorder's is ignored"
        )

        XCTAssertNil(try ColorFilterFixture.readings("keys-only-off").display, "no SurfaceFlinger section")

        let fullIdentity = try ColorFilterFixture.text("dumpsys-SurfaceFlinger-comp-displays.txt")
        XCTAssertEqual(DisplayTransformReading.parse(section: fullIdentity), .matrix(.identity))
        let fullTritanopia = try ColorFilterFixture.text("dumpsys-SurfaceFlinger-comp-displays-tritanopia.txt")
        XCTAssertEqual(
            DisplayTransformReading.parse(section: fullTritanopia)?.matrix,
            try ColorFilterFixture.readings("tritanopia").display?.matrix
        )
    }

    /// SOURCE-DERIVED: the grayscale capture with `isEnabled=true` replaced by
    /// `isEnabled=false`, the line a powered-off display prints
    /// (OutputCompositionState.cpp android-13.0.0_r83 `dumpVal(out, "isEnabled",
    /// isEnabled)`; DisplayDevice.cpp `setCompositionEnabled(mPowerMode != OFF)`).
    /// Turning the shared emulator's screen off was not allowed.
    func testADisplayThatIsOffReadsAsDisplayOff() throws {
        let off = try ColorFilterFixture.text("readings-probe-grayscale.txt")
            .replacingOccurrences(of: "isEnabled=true", with: "isEnabled=false")
        XCTAssertEqual(ColorFilterReadings.parse(off, apiLevel: 37).display, .displayOff)
        XCTAssertNil(DisplayTransformReading.parse(section: "Display 1 (virtual, \"x\")\n   colorTransformMatrix=\(ColorTransformMatrix.identity)"))
    }

    // MARK: - Matrix

    func testTheMatrixParserReadsSurfaceFlingersDump() throws {
        for state in ColorFilterFixture.displayStates {
            let line = try ColorFilterFixture.matrixLine(state)
            let matrix = try XCTUnwrap(ColorTransformMatrix.parse(line: line), state)
            XCTAssertEqual(matrix[3, 3], 1, state)
        }
        let tritanopia = try XCTUnwrap(ColorTransformMatrix.parse(line: try ColorFilterFixture.matrixLine("tritanopia")))
        XCTAssertEqual(tritanopia[0, 1], -0.806)
        XCTAssertEqual(tritanopia[2, 0], 0, "-0.000 reads as zero")
        XCTAssertEqual(tritanopia.description, "[[1.000,-0.806,0.806,0.000][0.000,0.379,0.621,0.000][0.000,0.105,0.895,0.000][0.000,0.000,0.000,1.000]]")

        // Test-side truncation of a real line: anything but the whole matrix is refused.
        let line = try ColorFilterFixture.matrixLine("protanopia")
        XCTAssertNil(ColorTransformMatrix.parse(line: String(line.dropLast(10))))
        XCTAssertNil(ColorTransformMatrix.parse(line: line.replacingOccurrences(of: "[0.000,0.000,0.000,1.000]", with: "")))
        XCTAssertNil(ColorTransformMatrix.parse(line: "isEnabled=true isSecure=true usesDeviceComposition=true"))
    }

    func testTheDaltonizerPortMatchesSurfaceFlinger() throws {
        let levels: [String: Double] = [
            "deuteranopia-intensity-0": 0, "deuteranopia-intensity-3": 0.3, "deuteranopia-intensity-10": 1.0,
        ]
        for state in ColorFilterFixture.displayStates {
            let readings = try ColorFilterFixture.readings(state)
            let dumped = try XCTUnwrap(readings.display?.matrix, state)
            let expected = try XCTUnwrap(ColorTransformModel.expected(readings, level: levels[state] ?? 0.7), state)
            XCTAssertTrue(dumped.approximatelyEquals(expected), "\(state): dumped \(dumped), model \(expected)")
        }
        XCTAssertTrue(
            try XCTUnwrap(ColorFilterFixture.readings("inversion-grayscale").display?.matrix)
                .approximatelyEquals(ColorTransformModel.grayscale * ColorTransformModel.inversion),
            "DisplayTransformManager multiplies level 200 by level 300"
        )
    }

    // MARK: - Check

    func testChecksOnTheCapturedStates() throws {
        func check(_ state: String, apiLevel: Int = ColorFilterFixture.api37) throws -> ColorTransformCheck {
            try ColorFilterFixture.readings(state).check(apiLevel: apiLevel)
        }
        for state in [
            "protanopia", "deuteranopia", "tritanopia", "mode-unset", "mode-garbage",
            "mode-empty", "mode-space-11", "mode-overflow",
        ] {
            XCTAssertEqual(try check(state), .applied(level: 0.7), state)
        }
        for state in [
            "off", "grayscale", "mode-99", "mode-minus-1", "mode-10", "mode-21", "none-mode-kept",
            "inversion", "inversion-grayscale", "simulate-protanopia", "simulate-deuteranopia",
            "simulate-tritanopia", "grayscale-recording", "enabled-space-1", "inversion-empty", "inversion-2",
        ] {
            XCTAssertEqual(try check(state), .applied(level: nil), state)
        }
        XCTAssertEqual(try check("inversion-protanopia"), .applied(level: 0.7))
        XCTAssertEqual(try check("protanopia-inversion-off"), .applied(level: 0.7))
        XCTAssertEqual(try check("deuteranopia-intensity-3"), .applied(level: 0.3))
        XCTAssertEqual(try check("deuteranopia-intensity-0"), .applied(level: 0.0))
        XCTAssertEqual(try check("deuteranopia-intensity-10"), .applied(level: 1.0))
        XCTAssertEqual(try check("deuteranopia-intensity-7"), .applied(level: 0.7))
        XCTAssertEqual(try check("deuteranopia-intensity-deleted"), .applied(level: 0.7))
        XCTAssertEqual(try check("deuteranopia-intensity-3", apiLevel: 34), .combined, "no Intensity before API 35")
    }

    /// Settings from one capture and the display from another, each parsed
    /// from its own file (no spliced text).
    func testNotAppliedCombinedAndDisplayOffFromRealReadings() throws {
        var ignored = try ColorFilterFixture.readings("protanopia")
        ignored.display = try ColorFilterFixture.readings("off").display
        XCTAssertEqual(ignored.check(apiLevel: 37), .notApplied)

        var other = try ColorFilterFixture.readings("off")
        other.display = try ColorFilterFixture.readings("grayscale").display
        XCTAssertEqual(other.check(apiLevel: 37), .combined)

        // SOURCE-DERIVED display-off section (see testADisplayThatIsOffReadsAsDisplayOff).
        let displayOff = ColorFilterReadings.parse(
            try ColorFilterFixture.text("readings-probe-grayscale.txt")
                .replacingOccurrences(of: "isEnabled=true", with: "isEnabled=false"),
            apiLevel: 37
        ).display
        for state in ["off", "protanopia", "inversion"] {
            var readings = try ColorFilterFixture.readings(state)
            readings.display = displayOff
            XCTAssertEqual(readings.check(apiLevel: 37), .displayOff, state)
        }

        XCTAssertEqual(try ColorFilterFixture.readings("keys-only-off").check(apiLevel: 37), .unavailable)
    }

    func testSupportGatesTheDisplayReadByAPI() throws {
        // `settings --user current` from android-7.0.0_r1 (SettingsCmd);
        // android-6.0.1_r81's takes only a number.
        XCTAssertFalse(ColorFilterSupport(apiLevel: 23).offersRows)
        XCTAssertTrue(ColorFilterSupport(apiLevel: 24).offersRows)
        // An unspecified user is user 0 through android-9.0.0_r61 and the
        // current user from android-10.0.0_r1 (SettingsService).
        XCTAssertEqual(ColorFilterSupport(apiLevel: 24).settingsCommand, ["settings", "--user", "current"])
        XCTAssertEqual(ColorFilterSupport(apiLevel: 28).settingsCommand, ["settings", "--user", "current"])
        XCTAssertEqual(ColorFilterSupport(apiLevel: 29).settingsCommand, ["settings"])
        XCTAssertEqual(ColorFilterSupport(apiLevel: 37).settingsCommand, ["settings"])
        // `--comp-displays` with display-kind headers: android-13.0.0_r1
        // (SurfaceFlinger::dumpCompositionDisplays; CompositionEngine Display::dump).
        XCTAssertFalse(ColorFilterSupport(apiLevel: 32).readsDisplayMatrix)
        XCTAssertTrue(ColorFilterSupport(apiLevel: 33).readsDisplayMatrix)
        // accessibility_display_daltonizer_saturation_level: android-15.0.0_r36.
        XCTAssertFalse(ColorFilterSupport(apiLevel: 34).intensityKey)
        XCTAssertTrue(ColorFilterSupport(apiLevel: 35).intensityKey)
        XCTAssertEqual(ColorFilterReadings.candidateLevels(apiLevel: 34, intensity: 3), [0.7])
        XCTAssertEqual(
            ColorFilterReadings.candidateLevels(apiLevel: 35, intensity: 3),
            [0.3, 0.7, 0.1, 0.2, 0.4, 0.5, 0.6, 0.8, 0.9, 1.0]
        )
        XCTAssertEqual(
            ColorFilterReadings.candidateLevels(apiLevel: 37, intensity: nil),
            [0.7, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.8, 0.9, 1.0],
            "0.0 only when the key says 0"
        )
        XCTAssertEqual(ColorFilterReadings.candidateLevels(apiLevel: 37, intensity: 0).first, 0.0)
    }

    // MARK: - Writes

    private static let serial = "emulator-5580"

    private func support() throws -> ColorFilterSupport {
        let sdk = try String(contentsOf: ControlsAPI37Fixture.directory.appendingPathComponent("getprop-ro.build.version.sdk.txt"), encoding: .utf8)
        return ColorFilterSupport(apiLevel: try XCTUnwrap(Int(sdk.trimmingCharacters(in: .whitespacesAndNewlines))))
    }

    func testTheSupportIsTheAPILevel() async throws {
        let adb = try FakeAdb([
            .init("getprop ro.build.version.sdk", stdoutFile: ControlsAPI37Fixture.directory.appendingPathComponent("getprop-ro.build.version.sdk.txt")),
        ])
        let support = try await adb.client.colorFilterSupport(serial: Self.serial)
        XCTAssertEqual(support, ColorFilterSupport(apiLevel: 37))
        XCTAssertTrue(support.readsDisplayMatrix)
        XCTAssertTrue(support.intensityKey)
    }

    func testWritesRunTheSettingsCommandsAndReadBack() async throws {
        let protanopia = try FakeAdb([
            .init("echo @@devicehubpro-cf:enabled", stdoutFile: ColorFilterFixture.url("readings-probe-protanopia.txt")),
        ])
        let outcome = try await protanopia.client.setColorFilter(serial: Self.serial, .protanopia, support: try support(), delay: .zero)
        XCTAssertEqual(outcome.check, .applied(level: 0.7))
        XCTAssertEqual(outcome.readings.setting, .filter(.protanopia))
        XCTAssertEqual(protanopia.tool.invocations.first, [
            "-s", Self.serial, "shell",
            "settings put secure accessibility_display_daltonizer 11 && settings put secure accessibility_display_daltonizer_enabled 1",
        ], "the mode first, in one shell line")
        XCTAssertEqual(protanopia.calls.count, 2, "one write, one read")
        XCTAssertEqual(protanopia.tool.invocations.last?.last, ColorFilterReadings.probeScript(support: ColorFilterSupport(apiLevel: 37)))

        let none = try FakeAdb([
            .init("echo @@devicehubpro-cf:enabled", stdoutFile: ColorFilterFixture.url("readings-probe-none-mode-kept.txt")),
        ])
        let off = try await none.client.setColorFilter(serial: Self.serial, .none, support: try support(), delay: .zero)
        XCTAssertEqual(off.check, .applied(level: nil))
        XCTAssertEqual(none.tool.invocations.first, [
            "-s", Self.serial, "shell", "settings", "put", "secure", "accessibility_display_daltonizer_enabled", "0",
        ], "None turns only the switch off")

        let inversion = try FakeAdb([
            .init("echo @@devicehubpro-cf:enabled", stdoutFile: ColorFilterFixture.url("readings-probe-inversion.txt")),
        ])
        let inverted = try await inversion.client.setColorInversion(serial: Self.serial, enabled: true, support: try support(), delay: .zero)
        XCTAssertEqual(inverted.check, .applied(level: nil))
        XCTAssertEqual(inverted.readings.inversion, true)
        XCTAssertEqual(inversion.tool.invocations.first, [
            "-s", Self.serial, "shell", "settings", "put", "secure", "accessibility_display_inversion_enabled", "1",
        ])
    }

    func testTheReadBackWaitsForTheMatrixToFollow() async throws {
        // The keys already say Protanopia while SurfaceFlinger still shows the
        // previous filter's matrix (grayscale): combined, so read again.
        var stale = try ColorFilterFixture.readings("protanopia")
        stale.display = try ColorFilterFixture.readings("grayscale").display
        XCTAssertEqual(stale.check(apiLevel: 37), .combined)
        let answers = [stale, try ColorFilterFixture.readings("protanopia")]
        var reads = 0
        let outcome = try await ColorFilterReadBack.settle(target: .filter(.protanopia), apiLevel: 37, attempts: 6, delay: .zero) {
            defer { reads += 1 }
            return answers[min(reads, answers.count - 1)]
        }
        XCTAssertEqual(outcome.check, .applied(level: 0.7))
        XCTAssertEqual(reads, 2)

        // A matrix that never follows: the last read, reported as it is.
        var tries = 0
        let never = try await ColorFilterReadBack.settle(target: .filter(.protanopia), apiLevel: 37, attempts: 3, delay: .zero) {
            tries += 1
            return stale
        }
        XCTAssertEqual(never.check, .combined)
        XCTAssertEqual(tries, 3)

        // Every read failing: the last error.
        do {
            _ = try await ColorFilterReadBack.settle(target: .inversion(true), apiLevel: 37, attempts: 2, delay: .zero) {
                throw ColorFilterError.notKept("a test read")
            }
            XCTFail("every read failed")
        } catch let error as ColorFilterError {
            XCTAssertEqual(error, .notKept("a test read"))
        }
    }

    func testAWriteTheDeviceDoesNotKeepThrows() async throws {
        let adb = try FakeAdb([
            .init("echo @@devicehubpro-cf:enabled", stdoutFile: ColorFilterFixture.url("readings-probe-off.txt")),
        ])
        do {
            try await adb.client.setColorFilter(serial: Self.serial, .grayscale, support: try support(), attempts: 4, delay: .zero)
            XCTFail("the keys still read off")
        } catch let error as ColorFilterError {
            XCTAssertEqual(error, .notKept("the color filter: secure accessibility_display_daltonizer_enabled reads null"))
            XCTAssertEqual(
                error.description,
                "The device did not keep the color filter: secure accessibility_display_daltonizer_enabled reads null."
            )
        }
        XCTAssertEqual(adb.calls(containing: "@@devicehubpro-cf:enabled").count, 4, "every attempt read")

        let inversion = try FakeAdb([
            .init("echo @@devicehubpro-cf:enabled", stdoutFile: ColorFilterFixture.url("readings-probe-protanopia-inversion-off.txt")),
        ])
        do {
            try await inversion.client.setColorInversion(serial: Self.serial, enabled: true, support: try support(), attempts: 2, delay: .zero)
            XCTFail("inversion reads 0")
        } catch let error as ColorFilterError {
            XCTAssertEqual(error, .notKept("color inversion: secure accessibility_display_inversion_enabled reads 0"))
        }

        // An empty or spaced value is quoted.
        let empty = try FakeAdb([
            .init("echo @@devicehubpro-cf:enabled", stdoutFile: ColorFilterFixture.url("readings-probe-inversion-empty.txt")),
        ])
        do {
            try await empty.client.setColorInversion(serial: Self.serial, enabled: true, support: try support(), attempts: 1, delay: .zero)
            XCTFail("inversion reads empty")
        } catch let error as ColorFilterError {
            XCTAssertEqual(error, .notKept("color inversion: secure accessibility_display_inversion_enabled reads \"\""))
        }
        let spaced = try FakeAdb([
            .init("echo @@devicehubpro-cf:enabled", stdoutFile: ColorFilterFixture.url("readings-probe-enabled-space-1.txt")),
        ])
        do {
            try await spaced.client.setColorFilter(serial: Self.serial, .deuteranopia, support: try support(), attempts: 1, delay: .zero)
            XCTFail("the switch reads off")
        } catch let error as ColorFilterError {
            XCTAssertEqual(error, .notKept("the color filter: secure accessibility_display_daltonizer_enabled reads \" 1\""))
        }

        // The switch is on but another mode came back: the mode key is named.
        let mode = try FakeAdb([
            .init("echo @@devicehubpro-cf:enabled", stdoutFile: ColorFilterFixture.url("readings-probe-tritanopia.txt")),
        ])
        do {
            try await mode.client.setColorFilter(serial: Self.serial, .protanopia, support: try support(), attempts: 1, delay: .zero)
            XCTFail("the mode reads 13")
        } catch let error as ColorFilterError {
            XCTAssertEqual(error, .notKept("the color filter: secure accessibility_display_daltonizer reads 13"))
        }
    }

    /// SOURCE-DERIVED (`failedReadsOnAPI24To25`): a write whose read-back
    /// prints no line for the key names it as unreadable.
    func testAWriteWhoseReadBackPrintsNoLineCantBeRead() async throws {
        let output = try Self.failedReadsOnAPI24To25()
        let support = ColorFilterSupport(apiLevel: 25)
        let filter = try FakeAdb([.init("echo @@devicehubpro-cf:enabled", output: output)])
        do {
            try await filter.client.setColorFilter(serial: Self.serial, .protanopia, support: support, attempts: 1, delay: .zero)
            XCTFail("the switch can't be read")
        } catch let error as ColorFilterError {
            XCTAssertEqual(error, .notKept("the color filter: secure accessibility_display_daltonizer_enabled can't be read"))
        }
        let inversion = try FakeAdb([.init("echo @@devicehubpro-cf:enabled", output: output)])
        do {
            try await inversion.client.setColorInversion(serial: Self.serial, enabled: true, support: support, attempts: 1, delay: .zero)
            XCTFail("inversion can't be read")
        } catch let error as ColorFilterError {
            XCTAssertEqual(error, .notKept("color inversion: secure accessibility_display_inversion_enabled can't be read"))
        }
    }

    /// `settings put` exits 255 when it refuses a write; `adb shell` passes the
    /// status on. The answer is the emulator's real refusal
    /// (`settings-put-bogusns.stderr.txt`: `settings put bogusns x 1`, exit
    /// 255, nothing on stdout), replayed for the daltonizer put.
    func testAFailedPutSurfacesTheAdbError() async throws {
        let adb = try FakeAdb([
            .init(
                "settings put secure accessibility_display_daltonizer 0",
                stdoutFile: nil,
                stderrFile: ColorFilterFixture.url("settings-put-bogusns.stderr.txt"),
                exitCode: 255
            ),
        ])
        do {
            try await adb.client.setColorFilter(serial: Self.serial, .grayscale, support: try support(), delay: .zero)
            XCTFail("the put failed")
        } catch let error as AdbError {
            guard case .commandFailed(_, let exitCode, let message) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(exitCode, 255)
            XCTAssertTrue(message.contains("Invalid namespace"))
        }
        XCTAssertTrue(adb.calls(containing: "@@devicehubpro-cf").isEmpty, "no read-back after a failed put")
    }

    /// SOURCE-DERIVED: no API 24–28 image was available. The argv comes from
    /// the `settings` sources: `--user current` names the foreground user in
    /// SettingsCmd android-7.0.0_r1 and android-7.1.2_r39 and SettingsService
    /// android-8.1.0_r81 and android-9.0.0_r61 (without it they use user 0,
    /// while AccessibilityManagerService applies the current user's keys).
    /// The answer is the API 37 keys-only capture: `settings get` prints its
    /// value with `println` whatever the user option.
    func testAPI24To28AddressTheForegroundUser() async throws {
        XCTAssertEqual(
            ColorFilterReadings.probeScript(support: ColorFilterSupport(apiLevel: 28)),
            "echo @@devicehubpro-cf:enabled; settings --user current get secure accessibility_display_daltonizer_enabled || echo @@devicehubpro-cf:enabled-failed; "
                + "echo @@devicehubpro-cf:mode; settings --user current get secure accessibility_display_daltonizer || echo @@devicehubpro-cf:mode-failed; "
                + "echo @@devicehubpro-cf:level; settings --user current get secure accessibility_display_daltonizer_saturation_level || echo @@devicehubpro-cf:level-failed; "
                + "echo @@devicehubpro-cf:inversion; settings --user current get secure accessibility_display_inversion_enabled || echo @@devicehubpro-cf:inversion-failed; "
                + "true"
        )
        let keysOnly = ColorFilterFixture.url("readings-probe-keys-only-off.txt")
        for apiLevel in [24, 28] {
            let support = ColorFilterSupport(apiLevel: apiLevel)
            let filter = try FakeAdb([.init("echo @@devicehubpro-cf:enabled", stdoutFile: keysOnly)])
            do {
                try await filter.client.setColorFilter(serial: Self.serial, .protanopia, support: support, attempts: 1, delay: .zero)
                XCTFail("the keys still read off")
            } catch let error as ColorFilterError {
                XCTAssertEqual(error, .notKept("the color filter: secure accessibility_display_daltonizer_enabled reads null"))
            }
            XCTAssertEqual(filter.tool.invocations, [
                [
                    "-s", Self.serial, "shell",
                    "settings --user current put secure accessibility_display_daltonizer 11 && settings --user current put secure accessibility_display_daltonizer_enabled 1",
                ],
                ["-s", Self.serial, "shell", ColorFilterReadings.probeScript(support: support)],
            ], "API \(apiLevel)")

            let none = try FakeAdb([.init("echo @@devicehubpro-cf:enabled", stdoutFile: keysOnly)])
            let off = try await none.client.setColorFilter(serial: Self.serial, .none, support: support, delay: .zero)
            XCTAssertEqual(off.check, .unavailable)
            XCTAssertEqual(none.tool.invocations.first, [
                "-s", Self.serial, "shell", "settings", "--user", "current", "put", "secure", "accessibility_display_daltonizer_enabled", "0",
            ])

            let inversion = try FakeAdb([.init("echo @@devicehubpro-cf:enabled", stdoutFile: keysOnly)])
            let inversionOff = try await inversion.client.setColorInversion(serial: Self.serial, enabled: false, support: support, delay: .zero)
            XCTAssertEqual(inversionOff.readings.inversion, false)
            XCTAssertEqual(inversion.tool.invocations.first, [
                "-s", Self.serial, "shell", "settings", "--user", "current", "put", "secure", "accessibility_display_inversion_enabled", "0",
            ])
        }
    }

    func testBelowAPI33TheKeysAreTheReadBack() async throws {
        let adb = try FakeAdb([
            .init("echo @@devicehubpro-cf:enabled", stdoutFile: ColorFilterFixture.url("readings-probe-keys-only-off.txt")),
        ])
        let outcome = try await adb.client.setColorFilter(serial: Self.serial, .none, support: ColorFilterSupport(apiLevel: 32), delay: .zero)
        XCTAssertEqual(outcome.check, .unavailable)
        XCTAssertEqual(adb.tool.invocations.last?.last, ColorFilterReadings.probeScript(support: ColorFilterSupport(apiLevel: 32)))
        XCTAssertEqual(adb.calls.count, 2, "the keys settle at once")
    }

    // MARK: - Live restore

    func testTheLiveRestoreParserReadsContentQueryRows() throws {
        let absent = try XCTUnwrap(LiveSecureRowSnapshot.parse(
            try ColorFilterFixture.text("content-query-secure-absent.txt"),
            key: "accessibility_display_daltonizer"
        ))
        XCTAssertEqual(absent.state, .absent)
        XCTAssertEqual(absent.restoreScript, "settings delete secure accessibility_display_daltonizer")

        let null = try XCTUnwrap(LiveSecureRowSnapshot.parse(
            try ColorFilterFixture.text("content-query-secure-null-row.txt"),
            key: "accessibility_display_inversion_enabled"
        ))
        XCTAssertEqual(null.state, .row(value: nil, preservedInRestore: false))
        XCTAssertEqual(
            null.restoreScript,
            "settings delete secure accessibility_display_inversion_enabled; content call --uri content://settings --method PUT_secure --arg accessibility_display_inversion_enabled --extra _overrideable_by_restore:b:true"
        )

        let fresh = try XCTUnwrap(LiveSecureRowSnapshot.parse(
            try ColorFilterFixture.text("content-query-secure-value-row.txt"),
            key: "accessibility_display_daltonizer_enabled"
        ))
        XCTAssertEqual(fresh.state, .row(value: "0", preservedInRestore: false))
        XCTAssertEqual(
            fresh.restoreScript,
            "settings delete secure accessibility_display_daltonizer_enabled; settings put secure accessibility_display_daltonizer_enabled 0"
        )

        let preserved = try XCTUnwrap(LiveSecureRowSnapshot.parse(
            try ColorFilterFixture.text("content-query-secure-value-row-preserved.txt"),
            key: "accessibility_display_daltonizer_enabled"
        ))
        XCTAssertEqual(preserved.state, .row(value: "0", preservedInRestore: true))
        XCTAssertEqual(fresh.state == preserved.state, false, "_id is ignored, the flag is not")
        XCTAssertEqual(
            preserved.restoreScript,
            "settings delete secure accessibility_display_daltonizer_enabled; settings put secure accessibility_display_daltonizer_enabled 0; settings put secure accessibility_display_daltonizer_enabled 0"
        )

        XCTAssertNil(LiveSecureRowSnapshot.parse(
            try ColorFilterFixture.text("content-query-secure-value-row.txt"),
            key: "accessibility_display_daltonizer"
        ), "another key's row")

        // SOURCE-DERIVED: an API 28/29 row, the captures without the
        // `is_preserved_in_restore` column. SettingsProvider's ALL_COLUMNS
        // is {_ID, NAME, VALUE} in android-9.0.0_r1 and android-10.0.0_r1
        // (the column arrives in android-11.0.0_r1), and Content.java
        // (android-9.0.0_r61) prints the row as `name=value` pairs joined by
        // ", ". No API 28/29 image was available.
        func withoutFlag(_ name: String) throws -> String {
            try ColorFilterFixture.text(name)
                .replacingOccurrences(of: ", is_preserved_in_restore=false", with: "")
                .replacingOccurrences(of: ", is_preserved_in_restore=true", with: "")
        }
        let oldValue = try XCTUnwrap(LiveSecureRowSnapshot.parse(
            try withoutFlag("content-query-secure-value-row.txt"),
            key: "accessibility_display_daltonizer_enabled"
        ))
        XCTAssertEqual(oldValue.state, .row(value: "0", preservedInRestore: false))
        XCTAssertEqual(
            oldValue.restoreScript,
            "settings delete secure accessibility_display_daltonizer_enabled; settings put secure accessibility_display_daltonizer_enabled 0"
        )
        let oldNull = try XCTUnwrap(LiveSecureRowSnapshot.parse(
            try withoutFlag("content-query-secure-null-row.txt"),
            key: "accessibility_display_inversion_enabled"
        ))
        XCTAssertEqual(oldNull.state, .row(value: nil, preservedInRestore: false))
        XCTAssertEqual(
            LiveSecureRowSnapshot.rows(try withoutFlag("content-query-secure-value-row.txt") + (try withoutFlag("content-query-secure-null-row.txt"))),
            [
                "accessibility_display_daltonizer_enabled": .row(value: "0", preservedInRestore: false),
                "accessibility_display_inversion_enabled": .row(value: nil, preservedInRestore: false),
            ],
            "a whole table"
        )
        XCTAssertNil(LiveSecureRowSnapshot(key: "k", state: .row(value: nil, preservedInRestore: true)).restoreScript)
    }
}

private extension FakeAdb {
    func calls(containing text: String) -> [String] {
        calls.filter { $0.contains(text) }
    }
}
