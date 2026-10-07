import XCTest
@testable import DeviceHubProKit

/// The Controls parsers fed byte-exact output captured from the API 37
/// emulator (Pixel 9 Pro Fold image, `emulator-5554`) with the exact command
/// each production call site runs. Every expected value is what the device
/// itself reported, cross-checked with a second command where one exists
/// (named in the test); none is computed by the parser under test.
///
/// Recapture a fixture with the command named in its test, e.g.
/// `adb -s emulator-5554 shell cmd uimode night > cmd-uimode-night.txt`.
final class ControlsDeviceOutputTests: XCTestCase {
    // MARK: - DeviceEffects probe

    /// The fixtures are the output of the current probe script, byte for
    /// byte: a script change needs a recapture.
    func testTheProbeFixturesComeFromTheCurrentProbeScript() throws {
        XCTAssertEqual(
            try ControlsAPI37Fixture.text("device-effects-probe-slow.command.txt"),
            DeviceEffects.probeScript(includingSlowSources: true)
        )
        XCTAssertEqual(
            try ControlsAPI37Fixture.text("device-effects-probe.command.txt"),
            DeviceEffects.probeScript(includingSlowSources: false)
        )
    }

    /// `adb shell "<DeviceEffects.probeScript(includingSlowSources: true)>"`.
    func testTheSlowProbeReadsWhatTheDeviceReports() throws {
        let output = try ControlsAPI37Fixture.text("device-effects-probe-slow.txt")
        let sections = DeviceEffects.sections(from: output)
        XCTAssertEqual(Set(sections.keys), Set(DeviceEffects.Section.allCases), "every marker came back")
        // Gated off on API 31+: `cmd wifi is-verbose-logging` answers there.
        XCTAssertEqual(sections[.wifiVerboseDump], "")

        let effects = DeviceEffects.parse(output)
        assertAPI37EmulatorEffects(effects)
    }

    /// `adb shell "<DeviceEffects.probeScript(includingSlowSources: false)>"`,
    /// the two-second poll: the same readings without the Wi-Fi dump.
    func testThePolledProbeReadsWhatTheDeviceReports() throws {
        let output = try ControlsAPI37Fixture.text("device-effects-probe.txt")
        XCTAssertNil(DeviceEffects.sections(from: output)[.wifiVerboseDump])
        assertAPI37EmulatorEffects(DeviceEffects.parse(output))
    }

    /// The probe through `AdbClient.deviceEffects(serial:)`: one round trip.
    func testTheProbeRunsThroughTheClient() async throws {
        let adb = try FakeAdb([
            .init("@@devicehubpro:sdk", output: try ControlsAPI37Fixture.text("device-effects-probe-slow.txt")),
        ])
        let effects = try await adb.client.deviceEffects(serial: "emulator-5554")
        assertAPI37EmulatorEffects(effects)
        XCTAssertEqual(adb.calls.count, 1)
    }

    /// What the emulator reported while the fixtures were captured, each
    /// from its own command:
    /// - `getprop ro.build.version.sdk` → `37`
    /// - `getprop debug.layout` → `false`
    /// - `service call SurfaceFlinger 1034 i32 2` → `Parcel(\t00000000 …)`,
    ///   and `settings get system show_refresh_rate` → `0`
    /// - `settings get global debug.force_rtl` → `1`, `getprop
    ///   debug.force_rtl` → `true`, `am get-config` → `…-ldrtl-…`
    /// - `cmd wifi is-verbose-logging` → `disabled` while `settings get
    ///   global wifi_verbose_logging_enabled` still says `1` (stale key)
    /// - `settings get global wifi_scan_throttle_enabled` → `null`
    /// - `settings get global low_power` → `0`; `dumpsys battery` → `AC
    ///   powered: true`
    private func assertAPI37EmulatorEffects(
        _ effects: DeviceEffects,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(effects.apiLevel, 37, file: file, line: line)
        XCTAssertEqual(effects.showBorders, ToggleEffect(reading: .off, support: .live), file: file, line: line)
        XCTAssertEqual(
            effects.forceRTL,
            ToggleEffect(reading: .on, support: .live, isPending: false, note: nil),
            "requested and already in the configuration; API 37 applies it live (the language re-push)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            effects.wifiVerboseLogging,
            ToggleEffect(reading: .off, support: .live),
            "the Wi-Fi service's answer wins over the stale Global key",
            file: file,
            line: line
        )
        XCTAssertEqual(effects.isPowered, true, file: file, line: line)
        XCTAssertEqual(
            effects.batterySaver,
            ToggleEffect(
                reading: .off,
                support: .live,
                note: "Battery saver can't turn on while the device is charging."
            ),
            file: file,
            line: line
        )
        XCTAssertEqual(effects.unsupportedToggles, [], file: file, line: line)
    }

    // MARK: - The probe's sources, one command each

    /// `adb shell am get-config`, the whole output `applyForceRTL` reads.
    func testConfigurationLayoutDirection() throws {
        let config = try ControlsAPI37Fixture.text("am-get-config.txt")
        XCTAssertEqual(DeviceEffects.configurationIsRTL(config), true)
    }

    /// `adb shell cmd wifi is-verbose-logging`.
    func testWifiVerboseLoggingQuery() throws {
        let answer = try ControlsAPI37Fixture.text("cmd-wifi-is-verbose-logging.txt")
        XCTAssertEqual(answer, "disabled\n")
        XCTAssertEqual(DeviceEffects.wifiVerboseState(answer), false)
    }

    /// The slow source, `adb shell "dumpsys wifi 2>/dev/null | grep 'Verbose
    /// logging is' | head -n 1"`. The probe runs it only below API 31; the
    /// API 37 Wi-Fi service still prints the same line (WifiServiceImpl's
    /// dump), and it agreed with `cmd wifi is-verbose-logging` (`disabled`).
    func testWifiDumpVerboseLine() throws {
        let line = try ControlsAPI37Fixture.text("dumpsys-wifi-verbose-logging-line.txt")
        XCTAssertEqual(line, "Verbose logging is off\n")
        XCTAssertEqual(DeviceEffects.wifiVerboseState(line), false)
        // On API 30 the dump is the row's live reading, whatever the key says.
        XCTAssertEqual(
            DeviceEffects.wifiVerboseLogging(api: 30, state: line, key: "1"),
            ToggleEffect(reading: .off, support: .live)
        )
    }

    /// `adb shell getprop debug.layout` / `debug.force_rtl`.
    func testDebugProperties() throws {
        XCTAssertEqual(DeviceEffects.propertyReading(try ControlsAPI37Fixture.text("getprop-debug.layout.txt")), .off)
        XCTAssertEqual(DeviceEffects.propertyReading(try ControlsAPI37Fixture.text("getprop-debug.force_rtl.txt")), .on)
    }

    /// `adb shell dumpsys battery`, the whole dump `applyBatterySaver` reads
    /// before enabling saver. The emulator's charger is AC (`AC powered:
    /// true`, the others false).
    func testChargerFromTheWholeBatteryDump() throws {
        let dump = try ControlsAPI37Fixture.text("dumpsys-battery.txt")
        XCTAssertEqual(DeviceEffects.isPowered(fromBatteryDump: dump), true)
    }

    /// `AdbClient.apiLevel(serial:)` on `adb shell getprop ro.build.version.sdk`.
    func testAPILevel() async throws {
        let adb = try FakeAdb([
            .init("getprop ro.build.version.sdk", output: try ControlsAPI37Fixture.text("getprop-ro.build.version.sdk.txt")),
        ])
        let level = try await adb.client.apiLevel(serial: "emulator-5554")
        XCTAssertEqual(level, 37)
    }

    // MARK: - Settings namespaces

    /// Every key a Controls row reads, from `adb shell settings list
    /// <namespace>`, matches `adb shell settings get <namespace> <key>`
    /// (`null` there is a key the list does not name, or names as `null`).
    func testTheNamespaceListsAgreeWithSettingsGet() throws {
        let keys: [String: [String]] = [
            "global": [
                "airplane_mode_on", "wifi_on", "bluetooth_on", "mobile_data", "low_power",
                "window_animation_scale", "transition_animation_scale", "animator_duration_scale",
                "mobile_data_always_on", "debug.force_rtl", "wifi_verbose_logging_enabled",
                "wifi_scan_throttle_enabled",
            ],
            "system": [
                "font_scale", "show_touches", "pointer_location", "accelerometer_rotation",
                "user_rotation", "show_refresh_rate",
            ],
            "secure": [
                "high_text_contrast_enabled", "accessibility_enabled", "enabled_accessibility_services",
                "anr_show_background", "ui_night_mode",
            ],
        ]
        for (namespace, names) in keys {
            let list = AdbParsing.globalSettings(from: try ControlsAPI37Fixture.text("settings-list-\(namespace).txt"))
            for key in names {
                let get = try ControlsAPI37Fixture.text("settings-get/\(namespace)-\(key).txt")
                XCTAssertEqual(
                    list[key] ?? "null",
                    get.trimmingCharacters(in: .newlines),
                    "\(namespace) \(key)"
                )
            }
        }
    }

    /// The values the Controls rows decode from the three lists, as
    /// `settings get` answered them: font_scale 1.3, show_touches 1,
    /// pointer_location unset, the three animation scales 1,
    /// mobile_data_always_on 0, high_text_contrast_enabled 0,
    /// anr_show_background 1, accessibility_enabled 0 with no services.
    func testTheRowsDecodeTheNamespaceLists() throws {
        let global = AdbParsing.globalSettings(from: try ControlsAPI37Fixture.text("settings-list-global.txt"))
        let system = AdbParsing.globalSettings(from: try ControlsAPI37Fixture.text("settings-list-system.txt"))
        let secure = AdbParsing.globalSettings(from: try ControlsAPI37Fixture.text("settings-list-secure.txt"))

        XCTAssertEqual(global["airplane_mode_on"], "0")
        XCTAssertEqual(global["wifi_on"], "1")
        XCTAssertEqual(global["bluetooth_on"], "1")
        XCTAssertEqual(global["mobile_data"], "0")
        XCTAssertEqual(
            ReduceMotionReading.parse(
                window: global["window_animation_scale"] ?? "null",
                transition: global["transition_animation_scale"] ?? "null",
                animator: global["animator_duration_scale"] ?? "null"
            ),
            .disabled
        )
        XCTAssertEqual(SettingsToggleReading.parse(global["mobile_data_always_on"] ?? "null"), .off)

        XCTAssertEqual(FontScaleReading.parse(system["font_scale"] ?? "null"), .value(1.3))
        XCTAssertEqual(SettingsToggleReading.parse(system["show_touches"] ?? "null"), .on)
        XCTAssertNil(system["pointer_location"], "unset on this image")
        XCTAssertEqual(SettingsToggleReading.parse(system["pointer_location"] ?? "null"), .off)
        // A value holding `=` keeps everything after the first one.
        XCTAssertEqual(system["alarm_alert"], "content://media/internal/audio/media/21?title=Cesium&canonical=1")

        XCTAssertEqual(SettingsToggleReading.parse(secure["high_text_contrast_enabled"] ?? "null"), .off)
        XCTAssertEqual(SettingsToggleReading.parse(secure["anr_show_background"] ?? "null"), .on)
        XCTAssertEqual(secure["enabled_accessibility_services"], "null", "listed with a null value")
        XCTAssertEqual(
            VoiceOverReading.parse(
                enabled: secure["accessibility_enabled"] ?? "null",
                services: secure["enabled_accessibility_services"] ?? "null",
                talkBackComponent: TalkBack.serviceComponent(for: TalkBack.gmsPackageID)
            ),
            .off
        )
    }

    /// `adb shell settings get secure enabled_accessibility_services`, the
    /// list `setTalkBack` edits: `null`, no services.
    func testAccessibilityServiceListWhenNoneIsEnabled() throws {
        let raw = try ControlsAPI37Fixture.text("settings-get/secure-enabled_accessibility_services.txt")
        XCTAssertEqual(raw, "null\n")
        XCTAssertEqual(AccessibilityServices.parse(raw), [])
        XCTAssertEqual(
            AccessibilityServices.adding(TalkBack.serviceComponent(for: TalkBack.gmsPackageID), to: raw),
            "com.google.android.marvin.talkback/com.google.android.marvin.talkback.TalkBackService"
        )
    }

    /// `adb shell pm list packages`: the image ships GMS TalkBack next to
    /// its `talkbackoverlay` companion.
    func testTalkBackPackageFromThePackageList() throws {
        let packages = AdbParsing.packages(from: try ControlsAPI37Fixture.text("pm-list-packages.txt"))
        XCTAssertTrue(packages.contains("com.google.android.marvin.talkbackoverlay"))
        XCTAssertEqual(DeviceSettingsParsing.talkBackPackage(fromPackages: packages), "com.google.android.marvin.talkback")
    }

    // MARK: - Commands with their own rows

    /// `adb shell cmd netpolicy get restrict-background`. Every version
    /// since API 24 answers with the status wording
    /// (NetworkPolicyManagerShellCommand.getRestrictBackground); `dumpsys
    /// netpolicy` agreed: `Restrict background: false`.
    func testDataSaverQuery() throws {
        let answer = try ControlsAPI37Fixture.text("cmd-netpolicy-get-restrict-background.txt")
        XCTAssertEqual(answer, "Restrict background status: disabled\n")
        XCTAssertEqual(DataSaverReading.parse(answer), .off)
    }

    /// `adb shell cmd uimode night`; `settings get secure ui_night_mode`
    /// agreed: `2` (MODE_NIGHT_YES).
    func testAppearanceQuery() throws {
        let answer = try ControlsAPI37Fixture.text("cmd-uimode-night.txt")
        XCTAssertEqual(answer, "Night mode: yes\n")
        XCTAssertEqual(AdbParsing.appearanceReading(from: answer), .mode(.dark))
    }

    /// `adb shell cmd media_session volume --stream 3 --get`; `dumpsys
    /// audio` agreed: STREAM_MUSIC `Min: 0`, `Max: 15`, `streamVolume:15`.
    func testMediaVolumeQuery() throws {
        let answer = try ControlsAPI37Fixture.text("cmd-media_session-volume-stream-3-get.txt")
        XCTAssertEqual(
            DeviceSettingsParsing.mediaVolume(from: answer),
            MediaVolumeReading(index: 15, minimum: 0, maximum: 15)
        )
    }

    /// The legacy `media` binary is gone on API 37 (`adb shell media volume
    /// --stream 3 --get` exits 127 with the stderr in
    /// `media-volume-stream-3-get.stderr.txt`), so the reading comes from
    /// the `cmd media_session` fallback.
    func testMediaVolumeFallsBackWhenTheLegacyBinaryIsMissing() async throws {
        let stderr = try ControlsAPI37Fixture.text("media-volume-stream-3-get.stderr.txt")
        XCTAssertEqual(stderr, "/system/bin/sh: media: inaccessible or not found\n")
        let adb = try FakeAdb([
            .init("shell media volume", exitCode: 127),
            .init(
                "shell cmd media_session volume",
                output: try ControlsAPI37Fixture.text("cmd-media_session-volume-stream-3-get.txt")
            ),
        ])
        let reading = try await adb.client.mediaVolumeReading(serial: "emulator-5554")
        XCTAssertEqual(reading, MediaVolumeReading(index: 15, minimum: 0, maximum: 15))
    }
}
