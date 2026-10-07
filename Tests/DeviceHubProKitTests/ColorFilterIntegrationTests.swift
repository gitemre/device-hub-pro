import XCTest
@testable import DeviceHubProKit

/// The Color Filter and Color inversion mechanisms against a live emulator:
/// each write goes through the Kit, and each assertion reads the effect from
/// where Android applies it, SurfaceFlinger's composed color matrix
/// (`dumpsys SurfaceFlinger --comp-displays`, Android 13 and newer), against
/// `ColorTransformModel`'s port of ColorDisplayService and the Daltonizer.
/// Below Android 13 only the keys are asserted.
///
/// `setUp` snapshots the four secure rows (`LiveSecureRowSnapshot`: value
/// and `is_preserved_in_restore`) and the Quick Settings tile lists, which
/// AOSP SystemUI extends on a first enable on API 28–34, from one whole-table
/// `content query` (each `content` run starts app_process, about a second on
/// the API 37 emulator). The teardown block,
/// which runs even when an assertion fails, puts the Intensity key to 7 first
/// when a test touched it (SurfaceFlinger ignores the -1 a deleted key sends
/// and keeps its last level), restores every changed row exactly, and checks
/// the rows and the matrix are back. Emulators only (`LiveTestDevices.allowed`,
/// then `isEmulator`): a phone is never touched, even when pinned. The writes
/// tint the emulator's host frame for a moment.
///
/// `DHP_CAPTURE_COLOR_FILTER_FIXTURES=<dir>` also writes the readings
/// probe's commands and its output in every state the unit tests use
/// (`testCaptureProbeFixtures`), the source of the `color-filters` fixtures.
///
/// `setUp` throws `LiveSecureRowSnapshot`'s "unreadable rows" only for a
/// table it cannot parse; before Android 11 the rows have no
/// `is_preserved_in_restore` column and read as not preserved.
final class ColorFilterIntegrationTests: XCTestCase {
    private static let tileKeys = ["sysui_qs_tiles", "qs_auto_tiles"]

    private var adb: AdbClient!
    private var serial = ""
    private var support = ColorFilterSupport(apiLevel: 0)

    override func setUp() async throws {
        try await super.setUp()
        guard let adb = AdbClient.locate() else { throw XCTSkip("adb not found") }
        let devices = try await adb.listDevices()
        guard let serial = LiveTestDevices.allowed(devices).first(where: \.isEmulator)?.serial else {
            throw XCTSkip("no online emulator")
        }
        let support = try await adb.colorFilterSupport(serial: serial)
        self.adb = adb
        self.serial = serial
        self.support = support

        let snapshot = try await LiveSecureRowSnapshot.read(adb, serial: serial, keys: Self.rowKeys + Self.tileKeys)
        let rows = Array(snapshot.prefix(Self.rowKeys.count))
        let tiles = Array(snapshot.dropFirst(Self.rowKeys.count))
        let before = try await adb.colorFilterReadings(serial: serial, support: support)
        addTeardownBlock {
            try await Self.restore(adb, serial, support, rows: rows, tiles: tiles, display: before.display)
        }
    }

    private static let rowKeys = ColorFilterSettingKey.allCases.map(\.rawValue)

    /// Puts every changed row back and checks the device is as it was.
    private static func restore(
        _ adb: AdbClient,
        _ serial: String,
        _ support: ColorFilterSupport,
        rows: [LiveSecureRowSnapshot],
        tiles: [LiveSecureRowSnapshot],
        display: DisplayTransformReading?
    ) async throws {
        let current = try await LiveSecureRowSnapshot.read(adb, serial: serial, keys: rowKeys + tileKeys)
        let changed = zip(rows + tiles, current).filter { $0.0 != $0.1 }
        if !changed.isEmpty {
            try await restore(adb, serial, changed: changed)
            let restored = try await LiveSecureRowSnapshot.read(adb, serial: serial, keys: rowKeys + tileKeys)
            for (original, now) in zip(rows, restored) {
                XCTAssertEqual(now, original, "the row is back, is_preserved_in_restore included")
            }
            for (original, now) in zip(tiles, restored.dropFirst(rows.count)) {
                XCTAssertEqual(now.state.value, original.state.value, "\(original.key) is back")
            }
        }
        try await assertMatrix(adb, serial, support, display)
    }

    private static func restore(
        _ adb: AdbClient,
        _ serial: String,
        changed: [(original: LiveSecureRowSnapshot, now: LiveSecureRowSnapshot)]
    ) async throws {
        let level = ColorFilterSettingKey.level.rawValue
        if changed.contains(where: { $0.original.key == level }) {
            // SurfaceFlinger ignores the -1 a deleted key sends and keeps its
            // last level: send the default before the row goes back, and give
            // ColorDisplayService's observer time to pass it on.
            _ = try await adb.shell(serial: serial, ["settings put secure \(level) 7"])
            try await Task.sleep(for: .milliseconds(500))
        }
        var scripts: [String] = []
        for (original, now) in changed {
            if tileKeys.contains(original.key) {
                // The tile lists belong to SystemUI, which may rewrite a
                // deleted list at once: only their value goes back, with a
                // plain put.
                switch original.state {
                case .absent:
                    scripts.append("settings delete secure \(original.key)")
                case .row(let value, _):
                    if now.state.value != value, let value {
                        scripts.append("settings put secure \(original.key) \(AdbClient.shellQuoted(value))")
                    }
                }
            } else if let script = original.restoreScript {
                scripts.append(script)
            } else {
                XCTFail("no known restore for \(original)")
            }
        }
        if !scripts.isEmpty {
            _ = try await adb.shell(serial: serial, [scripts.joined(separator: "; ")])
        }
    }

    /// SurfaceFlinger's matrix is the one before the test.
    private static func assertMatrix(
        _ adb: AdbClient,
        _ serial: String,
        _ support: ColorFilterSupport,
        _ display: DisplayTransformReading?
    ) async throws {
        if let matrix = display?.matrix {
            var restored: ColorTransformMatrix?
            for _ in 0..<20 {
                restored = try await adb.colorFilterReadings(serial: serial, support: support).display?.matrix
                if restored?.approximatelyEquals(matrix) == true { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(restored?.approximatelyEquals(matrix) == true, "SurfaceFlinger's matrix is back: \(String(describing: restored))")
        }
    }

    // MARK: - Helpers

    /// SurfaceFlinger's matrix from a plain `--comp-displays` dump, outside the
    /// Kit's probe.
    private func dumpedMatrix() async throws -> ColorTransformMatrix? {
        let dump = try await adb.shell(serial: serial, ["dumpsys", "SurfaceFlinger", "--comp-displays"])
        return DisplayTransformReading.parse(section: dump)?.matrix
    }

    /// The level SurfaceFlinger runs at: the Intensity key's, else 0.7.
    private func level(_ readings: ColorFilterReadings) -> Double {
        support.intensityKey ? readings.intensity.map { Double($0) / 10 } ?? 0.7 : 0.7
    }

    /// Asserts the write's check and, independently, the dumped matrix.
    private func assertDrawn(
        _ outcome: ColorFilterWriteOutcome,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        guard support.readsDisplayMatrix else {
            XCTAssertEqual(outcome.check, .unavailable, label, file: file, line: line)
            return
        }
        guard case .applied = outcome.check else {
            return XCTFail("\(label): \(outcome.check)", file: file, line: line)
        }
        let expected = try XCTUnwrap(ColorTransformModel.expected(outcome.readings, level: level(outcome.readings)))
        let dumped = try await dumpedMatrix()
        XCTAssertTrue(
            dumped?.approximatelyEquals(expected) == true,
            "\(label): dumped \(String(describing: dumped)), expected \(expected)",
            file: file,
            line: line
        )
    }

    // MARK: - Filters

    func testEachFilterIsDrawnBySurfaceFlinger() async throws {
        for option in [ColorFilterOption.grayscale, .protanopia, .deuteranopia, .tritanopia, .none] {
            let outcome = try await adb.setColorFilter(serial: serial, option, support: support)
            XCTAssertEqual(outcome.readings.setting, .filter(option), option.title)
            try await assertDrawn(outcome, option.title)
        }
    }

    func testSwitchingBetweenFiltersSettlesOnTheNewMatrix() async throws {
        for option in [ColorFilterOption.grayscale, .protanopia, .tritanopia] {
            let outcome = try await adb.setColorFilter(serial: serial, option, support: support)
            XCTAssertEqual(outcome.readings.setting, .filter(option))
            try await assertDrawn(outcome, option.title)
        }
    }

    func testNoneKeepsTheModeLikeSettings() async throws {
        _ = try await adb.setColorFilter(serial: serial, .protanopia, support: support)
        let off = try await adb.setColorFilter(serial: serial, .none, support: support)
        let mode = try await adb.shell(serial: serial, ["settings", "get", "secure", ColorFilterSettingKey.mode.rawValue])
        XCTAssertEqual(mode.trimmingCharacters(in: .whitespacesAndNewlines), "11", "None turns only the switch off")
        XCTAssertEqual(off.readings.setting, .filter(.none))
        try await assertDrawn(off, "None")
        if support.readsDisplayMatrix, off.readings.inversion == false {
            let dumped = try await dumpedMatrix()
            XCTAssertTrue(dumped?.approximatelyEquals(.identity) == true, "\(String(describing: dumped))")
        }
    }

    /// Settings' Intensity (API 35+): the Kit never writes it, but the check
    /// decodes the level the device runs at.
    func testTheCheckFollowsAnIntensityTheDeviceSet() async throws {
        guard support.intensityKey else { throw XCTSkip("the Intensity key needs API 35") }
        _ = try await adb.setColorFilter(serial: serial, .deuteranopia, support: support)
        _ = try await adb.shell(serial: serial, ["settings put secure \(ColorFilterSettingKey.level.rawValue) 3"])
        var check: ColorTransformCheck?
        for _ in 0..<20 {
            check = try await adb.colorFilterReadings(serial: serial, support: support).check(apiLevel: support.apiLevel)
            if check == .applied(level: 0.3) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(check, .applied(level: 0.3))
    }

    /// Values Android parses its own way: `Integer.parseInt` of the stored
    /// string, untrimmed, in 32 bits, else the key's default. The readings
    /// must name what SurfaceFlinger draws, so each check is applied.
    func testOddValuesReadAsAndroidParsesThem() async throws {
        guard support.readsDisplayMatrix else { throw XCTSkip("the check needs API 33") }
        let enabled = ColorFilterSettingKey.enabled.rawValue
        let mode = ColorFilterSettingKey.mode.rawValue
        let inversion = ColorFilterSettingKey.inversion.rawValue
        let cases: [(label: String, puts: [(String, String)], setting: DaltonizerSetting, inverted: Bool)] = [
            ("empty mode", [(mode, ""), (enabled, "1")], .filter(.deuteranopia), false),
            ("spaced mode", [(mode, " 11"), (enabled, "1")], .filter(.deuteranopia), false),
            ("mode past Int32", [(mode, "2147483659"), (enabled, "1")], .filter(.deuteranopia), false),
            ("signed mode", [(mode, "+11"), (enabled, "1")], .filter(.protanopia), false),
            ("spaced switch", [(mode, "11"), (enabled, " 1")], .filter(.none), false),
            ("empty inversion", [(enabled, "0"), (inversion, "")], .filter(.none), false),
            ("signed inversion", [(enabled, "0"), (inversion, "+1")], .filter(.none), true),
            // Any non-zero value through API 36 (AOSP), 1 only on API 37.
            ("inversion 2", [(enabled, "0"), (inversion, "2")], .filter(.none), support.apiLevel < 37),
        ]
        for (label, puts, setting, inverted) in cases {
            let script = puts.map { "settings put secure \($0.0) \(AdbClient.shellQuoted($0.1))" }.joined(separator: "; ")
            _ = try await adb.shell(serial: serial, [script])
            var readings = try await adb.colorFilterReadings(serial: serial, support: support)
            for _ in 0..<20 where !readings.check(apiLevel: support.apiLevel).isApplied {
                try await Task.sleep(for: .milliseconds(100))
                readings = try await adb.colorFilterReadings(serial: serial, support: support)
            }
            XCTAssertEqual(readings.setting, setting, label)
            XCTAssertEqual(readings.inversion, inverted, label)
            XCTAssertTrue(readings.check(apiLevel: support.apiLevel).isApplied, "\(label): \(readings.check(apiLevel: support.apiLevel))")
        }
    }

    // MARK: - Fixture capture

    /// The states `ColorFiltersTests` reads, each set from a clean start
    /// (the four keys deleted) and captured with the final probe once two
    /// reads agree. The setUp snapshot and the teardown put everything back.
    func testCaptureProbeFixtures() async throws {
        guard let path = ProcessInfo.processInfo.environment["DHP_CAPTURE_COLOR_FILTER_FIXTURES"],
              !path.isEmpty
        else { throw XCTSkip("set DHP_CAPTURE_COLOR_FILTER_FIXTURES to capture") }
        guard support.readsDisplayMatrix else { throw XCTSkip("the captures need API 33") }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func write(_ text: String, _ name: String) throws {
            try Data(text.utf8).write(to: directory.appendingPathComponent(name))
        }
        let script = ColorFilterReadings.probeScript(support: support)
        let keysOnly = ColorFilterReadings.probeScript(support: ColorFilterSupport(apiLevel: 32))
        try write(script, "readings-probe.command.txt")
        try write(keysOnly, "readings-probe-keys-only.command.txt")
        // The probe with a user that does not exist: every `settings get`
        // exits 255 ("Invalid user: 99", SettingsService) and prints nothing.
        let invalidUser = script.replacingOccurrences(of: "settings get ", with: "settings --user 99 get ")
        try write(invalidUser, "readings-probe-invalid-user.command.txt")

        let enabled = ColorFilterSettingKey.enabled.rawValue
        let mode = ColorFilterSettingKey.mode.rawValue
        let level = ColorFilterSettingKey.level.rawValue
        let inversion = ColorFilterSettingKey.inversion.rawValue
        func put(_ key: String, _ value: String) -> String { "settings put secure \(key) \(AdbClient.shellQuoted(value))" }
        let filter = { (value: String) in [put(mode, value), put(enabled, "1")] }
        let reset = ColorFilterSettingKey.allCases.map { "settings delete secure \($0.rawValue)" }

        let states: [(name: String, commands: [String])] = [
            ("off", []),
            ("grayscale", filter("0")),
            ("protanopia", filter("11")),
            ("deuteranopia", filter("12")),
            ("tritanopia", filter("13")),
            ("deuteranopia-intensity-0", filter("12") + [put(level, "0")]),
            ("deuteranopia-intensity-3", filter("12") + [put(level, "3")]),
            ("deuteranopia-intensity-10", filter("12") + [put(level, "10")]),
            ("deuteranopia-intensity-7", filter("12") + [put(level, "7")]),
            ("deuteranopia-intensity-deleted", filter("12") + [put(level, "7"), "settings delete secure \(level)"]),
            ("mode-unset", [put(enabled, "1")]),
            ("mode-garbage", filter("abc")),
            ("mode-99", filter("99")),
            ("mode-minus-1", filter("-1")),
            ("mode-10", filter("10")),
            ("mode-21", filter("21")),
            ("none-mode-kept", filter("11") + [put(enabled, "0")]),
            ("inversion", [put(inversion, "1")]),
            ("inversion-grayscale", [put(inversion, "1")] + filter("0")),
            ("inversion-protanopia", [put(inversion, "1")] + filter("11")),
            ("protanopia-inversion-off", filter("11") + [put(inversion, "1"), put(inversion, "0")]),
            ("simulate-protanopia", filter("1")),
            ("simulate-deuteranopia", filter("2")),
            ("simulate-tritanopia", filter("3")),
            ("mode-empty", filter("")),
            ("mode-space-11", filter(" 11")),
            ("mode-overflow", filter("2147483659")),
            ("enabled-space-1", [put(enabled, " 1")]),
            ("inversion-empty", [put(inversion, "")]),
            ("inversion-2", [put(inversion, "2")]),
        ]
        for state in states {
            _ = try await adb.shell(serial: serial, [(reset + state.commands).joined(separator: "; ")])
            try write(try await settledProbe(script), "readings-probe-\(state.name).txt")
            if state.name == "off" {
                try write(try await settledProbe(keysOnly), "readings-probe-keys-only-off.txt")
                let failed = try await settledProbe(invalidUser)
                XCTAssertTrue(failed.contains("@@devicehubpro-cf:enabled-failed"), failed)
                try write(failed, "readings-probe-invalid-user.txt")
            }
        }

        // Grayscale while screenrecord adds a virtual display.
        _ = try await adb.shell(serial: serial, [(reset + filter("0")).joined(separator: "; ")])
        let adb = self.adb!
        let serial = self.serial
        let recording = Task {
            try await adb.shell(serial: serial, ["screenrecord --time-limit 3 --output-format=h264 - > /dev/null"])
        }
        var withRecorder = ""
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(150))
            withRecorder = try await adb.shell(serial: serial, [script])
            if withRecorder.contains("(virtual") { break }
        }
        XCTAssertTrue(withRecorder.contains("(virtual"), "screenrecord's display is listed")
        try write(withRecorder, "readings-probe-grayscale-recording.txt")
        _ = try? await recording.value
    }

    /// The probe's output once two reads in a row agree (the matrix follows a
    /// put within 0.07 s on the emulator).
    private func settledProbe(_ script: String) async throws -> String {
        try await Task.sleep(for: .milliseconds(300))
        var previous = try await adb.shell(serial: serial, [script])
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(100))
            let next = try await adb.shell(serial: serial, [script])
            if next == previous { return next }
            previous = next
        }
        XCTFail("the probe did not settle")
        return previous
    }
}

private extension ColorTransformCheck {
    var isApplied: Bool {
        if case .applied = self { return true }
        return false
    }
}
