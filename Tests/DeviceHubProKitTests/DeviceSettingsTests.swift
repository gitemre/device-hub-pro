import XCTest
@testable import DeviceHubProKit

final class DeviceSettingsTests: XCTestCase {
    // MARK: - Font scale

    func testFontScaleReadingParsesStockSteps() {
        XCTAssertEqual(FontScaleReading.parse("0.85"), .value(0.85))
        XCTAssertEqual(FontScaleReading.parse("1"), .value(1.0))
        XCTAssertEqual(FontScaleReading.parse("1.0"), .value(1.0))
        XCTAssertEqual(FontScaleReading.parse("1.15"), .value(1.15))
        XCTAssertEqual(FontScaleReading.parse("1.3"), .value(1.3))
        XCTAssertEqual(FontScaleReading.parse(" 1.30\n"), .value(1.3))
    }

    func testFontScaleReadingRejectsUnreadableOutput() {
        XCTAssertEqual(FontScaleReading.parse(""), .unreadable)
        XCTAssertEqual(FontScaleReading.parse("   "), .unreadable)
        XCTAssertEqual(FontScaleReading.parse("null"), .unreadable)
        XCTAssertEqual(FontScaleReading.parse("NULL"), .unreadable)
        XCTAssertEqual(FontScaleReading.parse("banana"), .unreadable)
        XCTAssertEqual(FontScaleReading.parse("0"), .unreadable)
        XCTAssertEqual(FontScaleReading.parse("-1.0"), .unreadable)
        XCTAssertNil(FontScaleReading.parse("banana").value)
        XCTAssertEqual(FontScaleReading.parse("1.15").value, 1.15)
    }

    func testFontScaleSnapsToStockSteps() {
        XCTAssertEqual(FontScaleStep.nearest(to: 0.85), .small)
        XCTAssertEqual(FontScaleStep.nearest(to: 1.0), .standard)
        XCTAssertEqual(FontScaleStep.nearest(to: 1.15), .large)
        XCTAssertEqual(FontScaleStep.nearest(to: 1.30), .largest)
        XCTAssertEqual(FontScaleStep.nearest(to: 0.90), .small)
        XCTAssertEqual(FontScaleStep.nearest(to: 1.07), .standard)
        XCTAssertEqual(FontScaleStep.nearest(to: 1.22), .large)
        XCTAssertEqual(FontScaleStep.nearest(to: 2.0), .largest)
        XCTAssertEqual(FontScaleStep.nearest(to: 0.5), .small)
        // Ties snap to the smaller step so the reader never rounds a size up.
        XCTAssertEqual(FontScaleStep.nearest(to: 0.925), .small)
        XCTAssertEqual(FontScaleStep.nearest(to: 1.225), .large)
    }

    func testFontScaleStepRawValuesMatchAndroidStockSteps() {
        XCTAssertEqual(FontScaleStep.classicSteps.map(\.rawValue), [0.85, 1.0, 1.15, 1.3])
        // SettingsLib entryvalues_font_size on Android 14.
        XCTAssertEqual(FontScaleStep.allCases.map(\.rawValue), [0.85, 1.0, 1.15, 1.3, 1.5, 1.8, 2.0])
    }

    func testFontScaleStepsFollowTheAPILevel() {
        XCTAssertEqual(FontScaleStep.steps(apiLevel: 33), FontScaleStep.classicSteps)
        XCTAssertEqual(FontScaleStep.steps(apiLevel: nil), FontScaleStep.classicSteps)
        XCTAssertEqual(FontScaleStep.steps(apiLevel: 34), FontScaleStep.allCases)
        XCTAssertEqual(FontScaleStep.steps(apiLevel: 36).last, .percent200)
    }

    func testTwoHundredPercentIsNotFoldedIntoLargestOnAPI34() {
        // A device at 200 % used to read as Largest, and picking Largest
        // shrank its text to 130 %.
        let steps = FontScaleStep.steps(apiLevel: 34)
        XCTAssertEqual(FontScaleStep.nearest(to: 2.0, in: steps), .percent200)
        XCTAssertEqual(FontScaleStep.nearest(to: 1.8, in: steps), .percent180)
        XCTAssertEqual(FontScaleStep.nearest(to: 1.5, in: steps), .percent150)
        XCTAssertEqual(FontScaleStep.nearest(to: 1.3, in: steps), .largest)
        XCTAssertEqual(FontScaleStep.nearest(to: 1.65, in: steps), .percent150, "ties snap down")
        XCTAssertEqual(FontScaleStep.percent200.label, "200%")
    }

    // MARK: - Reduce Motion

    func testReduceMotionIsOnOnlyWhenAllScalesAreZero() {
        XCTAssertEqual(
            ReduceMotionReading.parse(window: "0", transition: "0", animator: "0"),
            .enabled
        )
        XCTAssertEqual(
            ReduceMotionReading.parse(window: "1.0", transition: "1.0", animator: "1.0"),
            .disabled
        )
        XCTAssertEqual(
            ReduceMotionReading.parse(window: "0", transition: "0", animator: "0.5"),
            .disabled
        )
        XCTAssertEqual(
            ReduceMotionReading.parse(window: "0", transition: "1.0", animator: "0"),
            .disabled
        )
    }

    func testReduceMotionTreatsUnsetScalesAsAnimationsOn() {
        // `settings get` prints null for a scale that was never written, and
        // the framework treats that as the 1.0 default.
        XCTAssertEqual(
            ReduceMotionReading.parse(window: "null", transition: "null", animator: "null"),
            .disabled
        )
        XCTAssertEqual(
            ReduceMotionReading.parse(window: "0", transition: "0", animator: "null"),
            .disabled
        )
        XCTAssertEqual(
            ReduceMotionReading.parse(window: "null", transition: "1.0", animator: "1.0"),
            .disabled
        )
    }

    func testReduceMotionIsUnreadableForEmptyOrGarbageScales() {
        XCTAssertEqual(
            ReduceMotionReading.parse(window: "", transition: "0", animator: "0"),
            .unreadable
        )
        XCTAssertEqual(
            ReduceMotionReading.parse(window: "0", transition: "banana", animator: "0"),
            .unreadable
        )
        XCTAssertEqual(
            ReduceMotionReading.parse(window: "0", transition: "0", animator: "n/a"),
            .unreadable
        )
    }

    // MARK: - Boolean toggles

    func testToggleReadingParsesBooleans() {
        XCTAssertEqual(SettingsToggleReading.parse("1"), .on)
        XCTAssertEqual(SettingsToggleReading.parse("true"), .on)
        XCTAssertEqual(SettingsToggleReading.parse("0"), .off)
        XCTAssertEqual(SettingsToggleReading.parse("false"), .off)
        XCTAssertEqual(SettingsToggleReading.parse(" 1\n"), .on)
        XCTAssertEqual(SettingsToggleReading.parse("TRUE"), .on)
    }

    func testToggleReadingTreatsUnsetAsTheCallerDefault() {
        XCTAssertEqual(SettingsToggleReading.parse("null"), .off)
        XCTAssertEqual(SettingsToggleReading.parse("NULL"), .off)
        XCTAssertEqual(SettingsToggleReading.parse("null", whenUnset: .on), .on)
    }

    func testToggleReadingRejectsGarbageAndEmpty() {
        XCTAssertEqual(SettingsToggleReading.parse(""), .unreadable)
        XCTAssertEqual(SettingsToggleReading.parse("   "), .unreadable)
        XCTAssertEqual(SettingsToggleReading.parse("banana"), .unreadable)
        XCTAssertEqual(SettingsToggleReading.parse("2"), .unreadable)
    }

    // MARK: - Media volume

    func testMediaVolumeParsesLegacyAndMediaSessionOutput() {
        XCTAssertEqual(
            DeviceSettingsParsing.mediaVolume(from: "Volume is 5 in range [0..15]"),
            MediaVolumeReading(index: 5, minimum: 0, maximum: 15)
        )
        XCTAssertEqual(
            DeviceSettingsParsing.mediaVolume(from: "[V] volume is 0 in range [1..7]"),
            MediaVolumeReading(index: 0, minimum: 1, maximum: 7)
        )
        XCTAssertEqual(
            DeviceSettingsParsing.mediaVolume(
                from: "[V] will control stream=3 (STREAM_MUSIC)\n[V] volume is 12 in range [0..15]\n"
            ),
            MediaVolumeReading(index: 12, minimum: 0, maximum: 15)
        )
    }

    func testMediaVolumeRejectsUnreadableOutput() {
        XCTAssertNil(DeviceSettingsParsing.mediaVolume(from: ""))
        XCTAssertNil(DeviceSettingsParsing.mediaVolume(from: "null"))
        XCTAssertNil(DeviceSettingsParsing.mediaVolume(from: "[V] will get volume"))
        XCTAssertNil(DeviceSettingsParsing.mediaVolume(from: "Volume is banana in range [0..15]"))
        XCTAssertNil(DeviceSettingsParsing.mediaVolume(from: "Volume is 5"))
        XCTAssertNil(DeviceSettingsParsing.mediaVolume(from: "Volume is 5 in range [0..]"))
    }

    // MARK: - TalkBack

    func testTalkBackPackageDetection() {
        let packages = ["com.android.settings", "com.google.android.marvin.talkback"]
        XCTAssertEqual(
            DeviceSettingsParsing.talkBackPackage(fromPackages: packages),
            "com.google.android.marvin.talkback"
        )
        // An OEM build ships under its own id.
        XCTAssertEqual(
            DeviceSettingsParsing.talkBackPackage(
                fromPackages: ["com.samsung.android.accessibility.talkback"]
            ),
            "com.samsung.android.accessibility.talkback"
        )
        // The overlay is a companion package, not the accessibility service.
        XCTAssertNil(
            DeviceSettingsParsing.talkBackPackage(
                fromPackages: ["com.google.android.marvin.talkbackoverlay"]
            )
        )
        XCTAssertNil(DeviceSettingsParsing.talkBackPackage(fromPackages: []))
        XCTAssertNil(DeviceSettingsParsing.talkBackPackage(fromPackages: ["com.android.settings"]))
    }

    func testTalkBackServiceComponent() {
        XCTAssertEqual(
            TalkBack.serviceComponent(for: "com.google.android.marvin.talkback"),
            "com.google.android.marvin.talkback/com.google.android.marvin.talkback.TalkBackService"
        )
        XCTAssertEqual(
            TalkBack.serviceComponent(for: "com.samsung.android.accessibility.talkback"),
            "com.samsung.android.accessibility.talkback/com.samsung.android.accessibility.talkback.TalkBackService"
        )
    }

    // MARK: - VoiceOver (TalkBack) reading

    func testVoiceOverRequiresEnabledFlagAndServiceEntry() {
        let component = TalkBack.serviceComponent(for: TalkBack.gmsPackageID)
        XCTAssertEqual(
            VoiceOverReading.parse(
                enabled: "1",
                services: component,
                talkBackComponent: component
            ),
            .on
        )
        XCTAssertEqual(
            VoiceOverReading.parse(
                enabled: "1",
                services: "com.example.testing.companion/.tier2.TreeAccessibilityService:\(component)",
                talkBackComponent: component
            ),
            .on
        )
        // Enabled flag alone is not enough: another service may be the one on.
        XCTAssertEqual(
            VoiceOverReading.parse(
                enabled: "1",
                services: "com.example.testing.companion/.tier2.TreeAccessibilityService",
                talkBackComponent: component
            ),
            .off
        )
        // A lingering service entry with the flag off reads as off.
        XCTAssertEqual(
            VoiceOverReading.parse(enabled: "0", services: component, talkBackComponent: component),
            .off
        )
        XCTAssertEqual(
            VoiceOverReading.parse(
                enabled: "1",
                services: "null",
                talkBackComponent: component
            ),
            .off
        )
        XCTAssertEqual(VoiceOverReading.parse(enabled: "null", services: "null", talkBackComponent: component), .off)
    }

    func testVoiceOverIsUnreadableWhenTheEnableFlagIsUnreadable() {
        let component = TalkBack.serviceComponent(for: TalkBack.gmsPackageID)
        XCTAssertEqual(
            VoiceOverReading.parse(enabled: "banana", services: component, talkBackComponent: component),
            .unreadable
        )
        XCTAssertEqual(
            VoiceOverReading.parse(enabled: "", services: component, talkBackComponent: component),
            .unreadable
        )
    }

    // MARK: - Accessibility service list

    func testAccessibilityServicesAddingPreservesOtherServices() {
        let component = "com.google.android.marvin.talkback/com.google.android.marvin.talkback.TalkBackService"
        XCTAssertEqual(
            AccessibilityServices.adding(component, to: "io.example/.Service"),
            "io.example/.Service:\(component)"
        )
        XCTAssertEqual(
            AccessibilityServices.adding(component, to: "null"),
            component
        )
        // Already present: the list is unchanged (no duplicate entry).
        XCTAssertEqual(
            AccessibilityServices.adding(component, to: component),
            component
        )
    }

    func testAccessibilityServicesRemovingKeepsOthersAndHandlesTheLastEntry() {
        let component = "com.google.android.marvin.talkback/com.google.android.marvin.talkback.TalkBackService"
        XCTAssertEqual(
            AccessibilityServices.removing(component, from: "io.example/.Service:\(component)"),
            "io.example/.Service"
        )
        XCTAssertEqual(
            AccessibilityServices.removing(component, from: component),
            ""
        )
        XCTAssertEqual(
            AccessibilityServices.removing(component, from: "null"),
            ""
        )
    }

    func testTalkBackWriteAbortsWhenTheServiceListCannotBeRead() async throws {
        let adb = try FakeAdb([
            .init("settings get secure enabled_accessibility_services", output: "", exitCode: 255),
        ])
        do {
            try await adb.client.setTalkBack(
                serial: "emulator-5554",
                enabled: true,
                packageID: TalkBack.gmsPackageID
            )
            XCTFail("a failed read must abort the write")
        } catch {}
        XCTAssertFalse(
            adb.calls.contains { $0.contains("settings put") || $0.contains("settings delete") },
            "rebuilding the list from nothing would switch the other services off: \(adb.calls)"
        )
    }

    func testTalkBackWritePreservesTheOtherServices() async throws {
        let other = "io.example/.AutomationService"
        let adb = try FakeAdb([
            .init("settings get secure enabled_accessibility_services", output: "\(other)\n"),
        ])
        try await adb.client.setTalkBack(
            serial: "emulator-5554",
            enabled: true,
            packageID: TalkBack.gmsPackageID
        )
        let component = TalkBack.serviceComponent(for: TalkBack.gmsPackageID)
        XCTAssertTrue(adb.calls.contains(
            "-s emulator-5554 shell settings put secure enabled_accessibility_services \(other):\(component)"
        ), "\(adb.calls)")
    }

    // MARK: - Availability probe

    func testSettingsProbeHidesTheRowAfterConsecutiveFailures() {
        var probe = SettingsProbe()
        XCTAssertTrue(probe.isAvailable)

        for _ in 0..<10 {
            probe.record(answered: true)
        }
        XCTAssertTrue(probe.isAvailable)
        XCTAssertEqual(probe.consecutiveFailures, 0)

        for _ in 0..<SettingsProbe.failureLimit {
            probe.record(answered: false)
        }
        XCTAssertFalse(probe.isAvailable)
        XCTAssertEqual(probe.consecutiveFailures, SettingsProbe.failureLimit)

        probe.record(answered: true)
        XCTAssertTrue(probe.isAvailable)

        // A transient failure between answers never hides the row.
        probe.record(answered: false)
        probe.record(answered: true)
        XCTAssertEqual(probe.consecutiveFailures, 0)
        XCTAssertTrue(probe.isAvailable)
    }

    func testSettingsProbeResetOnDeviceSwitch() {
        var probe = SettingsProbe()
        probe.record(answered: false)
        probe.record(answered: false)
        probe.reset()
        probe.record(answered: false)

        XCTAssertEqual(probe.consecutiveFailures, 1, "a device switch must not inherit old failures")
        XCTAssertTrue(probe.isAvailable)
    }

    // MARK: - Developer toggles

    func testDeviceToggleMapsEveryRowToItsSetting() {
        let expected: [(DeviceToggle, String, String)] = [
            (.showTaps, "system", "show_touches"),
            (.forceRTL, "global", "debug.force_rtl"),
            (.showBackgroundANRs, "secure", "anr_show_background"),
            (.wifiVerboseLogging, "global", "wifi_verbose_logging_enabled"),
            (.mobileDataAlwaysActive, "global", "mobile_data_always_on"),
        ]
        XCTAssertEqual(DeviceToggle.allCases.count, expected.count)
        for (toggle, namespace, key) in expected {
            XCTAssertEqual(toggle.namespace, namespace, "\(toggle)")
            XCTAssertEqual(toggle.key, key, "\(toggle)")
            XCTAssertFalse(toggle.label.isEmpty, "\(toggle)")
        }
    }

    func testDeviceToggleLabelsAreDistinct() {
        let labels = DeviceToggle.allCases.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count)
    }

    func testDeviceSettingsStateReadsAndWritesEveryToggle() {
        var state = DeviceSettingsState()
        for toggle in DeviceToggle.allCases {
            XCTAssertNil(state.reading(for: toggle), "\(toggle) starts nil")
        }
        for toggle in DeviceToggle.allCases {
            state.setReading(.on, for: toggle)
        }
        for toggle in DeviceToggle.allCases {
            XCTAssertEqual(state.reading(for: toggle), .on, "\(toggle) round-trips")
        }
    }

    // MARK: - Device effects (the rows that are not settings keys)

    private func probeOutput(
        sdk: String,
        layout: String = "",
        rtlKey: String = "null",
        rtlProperty: String = "",
        config: String = "config: mcc310-mnc260-en-rUS-ldltr-sw411dp-w411dp-h867dp-normal-long-port-notnight-420dpi-v34",
        wifiVerbose: String = "",
        wifiVerboseDump: String? = nil,
        wifiVerboseKey: String = "null",
        lowPower: String = "0",
        battery: String = "  AC powered: false\n  USB powered: false\n  Wireless powered: false"
    ) -> String {
        var lines = [
            "@@devicehubpro:sdk", sdk,
            "@@devicehubpro:layout", layout,
            "@@devicehubpro:rtl-key", rtlKey,
            "@@devicehubpro:rtl-prop", rtlProperty,
            "@@devicehubpro:config", config,
            "@@devicehubpro:wifi-verbose", wifiVerbose,
        ]
        if let wifiVerboseDump {
            lines += ["@@devicehubpro:wifi-verbose-dump", wifiVerboseDump]
        }
        lines += [
            "@@devicehubpro:wifi-verbose-key", wifiVerboseKey,
            "@@devicehubpro:low-power", lowPower,
            "@@devicehubpro:battery", battery,
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    func testEffectsAreReadFromTheRealMechanismsOnAPI34() {
        let effects = DeviceEffects.parse(probeOutput(
            sdk: "34",
            layout: "true",
            rtlKey: "1",
            rtlProperty: "true",
            wifiVerbose: "enabled",
            wifiVerboseKey: "0",
            lowPower: "1",
            battery: "  AC powered: true\n  USB powered: false\n  Wireless powered: false\n  Dock powered: false"
        ))

        XCTAssertEqual(effects.apiLevel, 34)
        XCTAssertEqual(effects.showBorders, ToggleEffect(reading: .on, support: .live))
        // The Wi-Fi module's own state wins over the stale Global key.
        XCTAssertEqual(effects.wifiVerboseLogging, ToggleEffect(reading: .on, support: .live))
        XCTAssertEqual(effects.unsupportedToggles, [])

        // Force RTL: stored, but the configuration is still LTR.
        XCTAssertEqual(effects.forceRTL?.reading, .on)
        XCTAssertEqual(effects.forceRTL?.support, .afterRestart)
        XCTAssertEqual(effects.forceRTL?.isPending, true)

        // Battery saver is off on a charger, although low_power says 1.
        XCTAssertEqual(effects.batterySaver?.reading, .off)
        XCTAssertEqual(effects.isPowered, true)
        XCTAssertNotNil(effects.batterySaver?.note)
    }

    func testOlderImagesUseTheirOwnMechanisms() {
        let effects = DeviceEffects.parse(probeOutput(
            sdk: "29",
            wifiVerboseDump: "Verbose logging is off",
            wifiVerboseKey: "1"
        ))

        XCTAssertEqual(effects.showBorders?.reading, .off, "an unset debug.layout is off")
        // Before API 30 the Wi-Fi service reads the key only at start-up.
        XCTAssertEqual(effects.wifiVerboseLogging?.reading, .on)
        XCTAssertEqual(effects.wifiVerboseLogging?.support, .afterRestart)
        XCTAssertEqual(effects.wifiVerboseLogging?.isPending, true)
        XCTAssertEqual(effects.unsupportedToggles, [])
    }

    func testForceRTLIsNotPendingOnceTheConfigurationIsRTL() {
        let rtl = DeviceEffects.parse(probeOutput(
            sdk: "34",
            rtlKey: "1",
            config: "config: mcc310-en-rUS-ldrtl-sw411dp-port-v34"
        ))
        XCTAssertEqual(rtl.forceRTL?.reading, .on)
        XCTAssertEqual(rtl.forceRTL?.isPending, false)

        let off = DeviceEffects.parse(probeOutput(sdk: "34", rtlKey: "0"))
        XCTAssertEqual(off.forceRTL?.reading, .off)
        XCTAssertEqual(off.forceRTL?.isPending, false)
    }

    func testBatterySaverIsOnOnlyWhenRequestedWithoutACharger() {
        XCTAssertEqual(
            DeviceEffects.batterySaver(key: "1", isPowered: false),
            ToggleEffect(reading: .on, support: .live)
        )
        XCTAssertEqual(DeviceEffects.batterySaver(key: "0", isPowered: false)?.reading, .off)
        XCTAssertEqual(DeviceEffects.batterySaver(key: "null", isPowered: false)?.reading, .off, "unset is off")
        XCTAssertEqual(DeviceEffects.batterySaver(key: "1", isPowered: nil)?.reading, .on)

        // The state machine refused it on the charger but left the key at 1.
        let refused = DeviceEffects.batterySaver(key: "1", isPowered: true)
        XCTAssertEqual(refused?.reading, .off)
        XCTAssertNotNil(refused?.note)

        XCTAssertEqual(DeviceEffects.batterySaver(key: "", isPowered: false)?.reading, .unreadable)
        XCTAssertNil(DeviceEffects.batterySaver(key: nil, isPowered: false))
    }

    func testTheChargerIsReadFromTheBatteryService() {
        let usb = "Current Battery Service state:\n  AC powered: false\n  USB powered: true\n  Wireless powered: false\n"
        XCTAssertEqual(DeviceEffects.isPowered(fromBatteryDump: usb), true)
        XCTAssertEqual(DeviceEffects.isPowered(fromBatteryDump: "  AC powered: false\n  USB powered: false\n  Dock powered: false"), false)
        XCTAssertEqual(DeviceEffects.isPowered(fromBatteryDump: "  Dock powered: true"), true, "API 33's dock charger")
        XCTAssertNil(DeviceEffects.isPowered(fromBatteryDump: ""))
        XCTAssertNil(DeviceEffects.isPowered(fromBatteryDump: "Can't find service: battery"))
    }

    func testLayoutDirectionIsReadFromTheConfiguration() {
        XCTAssertEqual(DeviceEffects.configurationIsRTL("config: en-rUS-ldrtl-sw411dp"), true)
        XCTAssertEqual(DeviceEffects.configurationIsRTL("config: en-rUS-ldltr-sw411dp"), false)
        XCTAssertNil(DeviceEffects.configurationIsRTL(""))
        XCTAssertNil(DeviceEffects.configurationIsRTL("abi: arm64-v8a"))
    }

    func testPropertyReadingTreatsUnsetAsOff() {
        XCTAssertEqual(DeviceEffects.propertyReading("true\n"), .on)
        XCTAssertEqual(DeviceEffects.propertyReading("1"), .on)
        XCTAssertEqual(DeviceEffects.propertyReading("false"), .off)
        XCTAssertEqual(DeviceEffects.propertyReading(""), .off)
        XCTAssertEqual(DeviceEffects.propertyReading("maybe"), .unreadable)
    }

    func testTheProbeIsOneShellLine() {
        for slow in [false, true] {
            XCTAssertFalse(DeviceEffects.probeScript(includingSlowSources: slow).contains("\n"), "one shell line")
            XCTAssertFalse(DeviceEffects.probeScript(includingSlowSources: slow).contains("SurfaceFlinger"))
        }
    }

    func testThePolledProbeRunsNoLargeDump() throws {
        // The Controls poll runs this every two seconds.
        let polled = DeviceEffects.probeScript(includingSlowSources: false)
        XCTAssertFalse(polled.contains("dumpsys wifi"))
        XCTAssertFalse(polled.contains("dumpsys power"))
        XCTAssertTrue(polled.contains("settings get global low_power"))
        XCTAssertTrue(polled.contains("dumpsys battery"), "the battery service's dump is a few lines")

        // The slow source is gated on the device to the images that need it.
        let slow = DeviceEffects.probeScript(includingSlowSources: true)
        let dump = try XCTUnwrap(slow.range(of: "dumpsys wifi"))
        let gate = try XCTUnwrap(slow.range(of: "if [ \"$sdk\" -lt 31 ]; then"))
        XCTAssertLessThan(gate.upperBound, dump.lowerBound)
        XCTAssertFalse(slow.contains("dumpsys power"))
    }

    func testTheWifiDumpIsReadOncePerLifetimeAndAfterAWrite() async throws {
        let adb = try FakeAdb([
            // First matching rule wins: the probe with the dump, then the
            // polled probe without it.
            .init("dumpsys wifi", output: probeOutput(sdk: "30", wifiVerboseDump: "Verbose logging is on")),
            .init("@@devicehubpro:sdk", output: probeOutput(sdk: "30")),
            .init("getprop ro.build.version.sdk", output: "30\n"),
        ])
        let serial = "emulator-5554"
        let start = ContinuousClock.now
        func probes() -> [String] { adb.calls.filter { $0.contains("@@devicehubpro:sdk") } }

        let first = try await adb.client.deviceEffects(serial: serial, now: start)
        XCTAssertEqual(first.wifiVerboseLogging, ToggleEffect(reading: .on, support: .live))
        XCTAssertTrue(probes().last?.contains("dumpsys wifi") ?? false, "a new device reads the dump")

        // The next polls reuse it.
        let polled = try await adb.client.deviceEffects(serial: serial, now: start + .seconds(2))
        XCTAssertFalse(probes().last?.contains("dumpsys wifi") ?? true, "a poll must not dump Wi-Fi again")
        XCTAssertEqual(polled.wifiVerboseLogging?.reading, .on, "the cached dump still answers the row")

        // A write refreshes it for the reconcile that follows.
        try await adb.client.setToggle(serial: serial, toggle: .wifiVerboseLogging, enabled: false)
        _ = try await adb.client.deviceEffects(serial: serial, now: .now)
        XCTAssertTrue(probes().last?.contains("dumpsys wifi") ?? false, "a write re-reads the dump")

        // And so does its age.
        _ = try await adb.client.deviceEffects(serial: serial, now: .now + DeviceEffectsCache.lifetime + .seconds(1))
        XCTAssertTrue(probes().last?.contains("dumpsys wifi") ?? false)
        XCTAssertEqual(probes().count, 4)
    }

    func testStateTakesTheNonKeyRowsFromTheEffects() {
        var effects = DeviceEffects()
        effects.showBorders = ToggleEffect(reading: .on, support: .live)
        effects.wifiVerboseLogging = ToggleEffect(reading: .unreadable, support: .unsupported("no"))

        var state = DeviceSettingsState()
        state.showTaps = .on
        state.apply(effects)
        XCTAssertEqual(state.showBorders, .on)
        XCTAssertNil(state.forceRTL, "an effect the device did not answer stays unknown")
        XCTAssertEqual(state.unsupportedToggles, [.wifiVerboseLogging])
        XCTAssertEqual(state.showTaps, .on, "key-driven rows are left alone")

        state.apply(nil)
        XCTAssertNil(state.showBorders)
        XCTAssertEqual(state.unsupportedToggles, [])
    }

    func testStateKeepsTheEffectsSoRowsCanShowHowTheyLand() {
        var effects = DeviceEffects()
        effects.forceRTL = ToggleEffect(
            reading: .on,
            support: .afterRestart,
            isPending: true,
            note: "Force RTL applies after the device restarts."
        )
        effects.isPowered = true

        var state = DeviceSettingsState()
        XCTAssertNil(state.effects)
        XCTAssertNil(state.effect(for: .forceRTL))

        state.apply(effects)
        XCTAssertEqual(state.effect(for: .forceRTL)?.support, .afterRestart)
        XCTAssertEqual(state.effect(for: .forceRTL)?.isPending, true)
        XCTAssertNil(state.effect(for: .showTaps), "key-driven toggles carry no effect")
        XCTAssertEqual(state.effects?.isPowered, true)

        state.apply(nil)
        XCTAssertNil(state.effects, "an unanswered read drops the stale snapshot")
    }

    func testOnlyTheNonKeyTogglesReadDeviceEffects() {
        XCTAssertEqual(
            Set(DeviceToggle.allCases.filter(\.readsDeviceEffect)),
            [.forceRTL, .wifiVerboseLogging]
        )
    }

    func testTheEffectsProbeRunsInOneRoundTrip() async throws {
        let adb = try FakeAdb([
            .init("@@devicehubpro:sdk", output: probeOutput(sdk: "34", layout: "true")),
        ])
        let effects = try await adb.client.deviceEffects(serial: "emulator-5554")
        XCTAssertEqual(effects.showBorders?.reading, .on)
        XCTAssertEqual(adb.calls.count, 1)
    }

    // MARK: - Toggle writes

    func testShowBordersSetsThePropertyAndPokesRunningApps() async throws {
        let adb = try FakeAdb([])
        try await adb.client.setDebugLayout(serial: "emulator-5554", enabled: true)
        XCTAssertEqual(adb.calls, [
            "-s emulator-5554 shell setprop debug.layout true",
            "-s emulator-5554 shell service call activity 1599295570",
        ])
    }

    func testForceRTLWritesTheKeyAndThePropertyAndReportsARestart() async throws {
        let adb = try FakeAdb([
            .init("am get-config", output: "config: en-rUS-ldltr-sw411dp-v34\n"),
        ])
        let outcome = try await adb.client.setToggle(serial: "emulator-5554", toggle: .forceRTL, enabled: true)
        XCTAssertEqual(outcome, .appliesAfterRestart)
        XCTAssertTrue(adb.calls.contains("-s emulator-5554 shell settings put global debug.force_rtl 1"))
        XCTAssertTrue(adb.calls.contains("-s emulator-5554 shell setprop debug.force_rtl true"))
        XCTAssertEqual(
            outcome.statusMessage(label: "Force RTL", enabled: true),
            "Force RTL turned on — applies after the device restarts"
        )
    }

    func testForceRTLAlreadyInEffectIsApplied() async throws {
        let adb = try FakeAdb([.init("am get-config", output: "config: ar-rEG-ldrtl-v34\n")])
        let outcome = try await adb.client.setToggle(serial: "emulator-5554", toggle: .forceRTL, enabled: true)
        XCTAssertEqual(outcome, .applied)
    }

    func testForceRTLRepushesTheLanguagesOnAPI26AndNewer() async throws {
        let adb = try FakeAdb([
            .init("@@devicehubpro-lt:sdk", output: try LanguageTimeFixture.text("support-probe.txt")),
            .init("getprop ro.build.version.sdk", output: "37\n"),
            .init("DeviceHubProLocales repush", output: "current en-US\napplied en-US\n"),
            .init("am get-config", output: try ControlsAPI37Fixture.text("am-get-config.txt")),
        ])
        let outcome = try await adb.client.setToggle(serial: "emulator-5554", toggle: .forceRTL, enabled: true)
        XCTAssertEqual(outcome, .applied, "the fixture's configuration is ldrtl")
        let calls = adb.calls
        XCTAssertTrue(calls.contains { $0.hasPrefix("-s emulator-5554 push ") && $0.contains("devicehubpro-locales") })
        XCTAssertTrue(calls.contains { $0.contains("app_process / DeviceHubProLocales repush") && $0.contains("rm -f /data/local/tmp/devicehubpro-locales-") })
        let property = try XCTUnwrap(calls.firstIndex(of: "-s emulator-5554 shell setprop debug.force_rtl true"))
        let repush = try XCTUnwrap(calls.firstIndex { $0.contains("DeviceHubProLocales repush") })
        XCTAssertLessThan(property, repush, "the property first, then the push that recomputes the direction")
    }

    func testForceRTLIsLiveFromAPI26() {
        XCTAssertEqual(
            DeviceEffects.forceRTL(key: "1", property: "true", config: "config: en-rUS-ldrtl-v37", api: 37),
            ToggleEffect(reading: .on, support: .live)
        )
        let failed = DeviceEffects.forceRTL(key: "1", property: "true", config: "config: en-rUS-ldltr-v37", api: 37)
        XCTAssertEqual(failed?.support, .afterRestart)
        XCTAssertEqual(failed?.isPending, true)
        XCTAssertEqual(failed?.note, "Force RTL did not apply live; it applies after the device restarts.")
        XCTAssertEqual(
            DeviceEffects.forceRTL(key: "0", property: "false", config: "config: en-rUS-ldltr-v25", api: 25)?.support,
            .afterRestart
        )
    }

    /// The emulator's own state while this was written: `settings get global
    /// debug.force_rtl` → `0`, `getprop debug.force_rtl` → `true` and `am
    /// get-config` → the controls fixture (`en-rUS-ldrtl`). Force RTL reads
    /// off, yet the device runs right to left with a left-to-right language:
    /// the row must say so rather than show a plain, live Off.
    func testForceRTLOffOnARightToLeftDeviceIsPending() throws {
        let config = try ControlsAPI37Fixture.text("am-get-config.txt")
        let effect = try XCTUnwrap(DeviceEffects.forceRTL(key: "0", property: "true", config: config, api: 37))
        XCTAssertEqual(effect.reading, .off)
        XCTAssertEqual(effect.support, .afterRestart)
        XCTAssertTrue(effect.isPending)
        XCTAssertEqual(effect.note, "The device stays right to left until it restarts.")
        // Before API 26 the same mismatch waits for a restart as well.
        XCTAssertEqual(
            DeviceEffects.forceRTL(key: "0", property: "true", config: config, api: 25)?.isPending,
            true
        )
    }

    /// An RTL language lays the device out right to left with Force RTL off;
    /// that is the expected direction, not a pending change.
    func testForceRTLOffWithARightToLeftLanguageIsNotPending() throws {
        let config = try LanguageTimeFixture.text("am-get-config-ar-EG.txt")
        XCTAssertEqual(
            DeviceEffects.forceRTL(key: "0", property: "false", config: config, api: 37),
            ToggleEffect(reading: .off, support: .live)
        )
        XCTAssertEqual(
            DeviceEffects.forceRTL(key: "1", property: "true", config: config, api: 37),
            ToggleEffect(reading: .on, support: .live)
        )
    }

    func testWifiVerboseLoggingUsesTheWifiServiceOnAPI30AndNewer() async throws {
        let adb = try FakeAdb([.init("getprop ro.build.version.sdk", output: "34\n")])
        let outcome = try await adb.client.setToggle(serial: "emulator-5554", toggle: .wifiVerboseLogging, enabled: true)
        XCTAssertEqual(outcome, .applied)
        XCTAssertTrue(adb.calls.contains("-s emulator-5554 shell cmd wifi set-verbose-logging enabled"))
        XCTAssertFalse(adb.calls.contains { $0.contains("wifi_verbose_logging_enabled") })
    }

    func testWifiVerboseLoggingUsesTheKeyBeforeAPI30() async throws {
        let adb = try FakeAdb([.init("getprop ro.build.version.sdk", output: "29\n")])
        let outcome = try await adb.client.setToggle(serial: "emulator-5554", toggle: .wifiVerboseLogging, enabled: false)
        XCTAssertEqual(outcome, .appliesAfterRestart)
        XCTAssertTrue(adb.calls.contains("-s emulator-5554 shell settings put global wifi_verbose_logging_enabled 0"))
    }

    func testKeyDrivenTogglesStillWriteTheirKey() async throws {
        let adb = try FakeAdb([])
        let outcome = try await adb.client.setToggle(serial: "emulator-5554", toggle: .showTaps, enabled: true)
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(adb.calls, ["-s emulator-5554 shell settings put system show_touches 1"])
    }

    func testBatterySaverIsRefusedOnACharger() async throws {
        let adb = try FakeAdb([
            .init("dumpsys battery", output: "  AC powered: true\n  USB powered: false\n"),
        ])
        do {
            try await adb.client.setBatterySaver(serial: "emulator-5554", enabled: true)
            XCTFail("Android refuses battery saver while powered; the row must not claim it")
        } catch let error as DeviceSettingsError {
            XCTAssertEqual(error, .batterySaverRefusedWhileCharging)
        }
        XCTAssertFalse(adb.calls.contains { $0.contains("set-mode") || $0.contains("low_power") })
    }

    func testBatterySaverGoesThroughPowerManager() async throws {
        let adb = try FakeAdb([
            .init("dumpsys battery", output: "  AC powered: false\n  USB powered: false\n"),
        ])
        try await adb.client.setBatterySaver(serial: "emulator-5554", enabled: true)
        XCTAssertTrue(adb.calls.contains("-s emulator-5554 shell cmd power set-mode 1"))
        XCTAssertFalse(adb.calls.contains { $0.contains("low_power") })

        let off = try FakeAdb([])
        try await off.client.setBatterySaver(serial: "emulator-5554", enabled: false)
        XCTAssertEqual(off.calls, ["-s emulator-5554 shell cmd power set-mode 0"], "turning it off never needs the charger check")
    }

    func testBatterySaverFallsBackToTheKeyWithoutCmdPower() async throws {
        let adb = try FakeAdb([
            .init("dumpsys battery", output: "  AC powered: false\n"),
            .init("cmd power set-mode", output: "", exitCode: 255),
        ])
        try await adb.client.setBatterySaver(serial: "emulator-5554", enabled: true)
        XCTAssertTrue(adb.calls.contains("-s emulator-5554 shell settings put global low_power 1"))
    }

    // MARK: - Data Saver

    /// The `dumpsys netpolicy` wording (`Restrict background: false` on the
    /// API 37 emulator); `cmd netpolicy get` itself answers with the status
    /// wording below.
    func testDataSaverReadingParsesNetpolicyOutput() {
        XCTAssertEqual(
            DataSaverReading.parse("Restrict background: true\n"),
            .on
        )
        XCTAssertEqual(
            DataSaverReading.parse("Restrict background: false\n"),
            .off
        )
        XCTAssertEqual(
            DataSaverReading.parse("[V] Restrict background: TRUE"),
            .on
        )
        XCTAssertEqual(DataSaverReading.parse("Restrict background: false").isOn, false)
        XCTAssertEqual(DataSaverReading.parse("Restrict background: true").isOn, true)
    }

    func testDataSaverReadingParsesTheStatusWording() {
        // `cmd netpolicy get restrict-background` has answered with the
        // status wording since API 24 (NetworkPolicyManagerShellCommand);
        // the API 37 emulator's byte-exact answer is in
        // ControlsDeviceOutputTests.testDataSaverQuery.
        XCTAssertEqual(
            DataSaverReading.parse("Restrict background status: enabled\n"),
            .on
        )
        XCTAssertEqual(
            DataSaverReading.parse("Restrict background status: disabled\n"),
            .off
        )
        XCTAssertEqual(
            DataSaverReading.parse("Restrict background status: ENABLED").isOn,
            true
        )
    }

    func testDataSaverReadingRejectsUnreadableOutput() {
        XCTAssertEqual(DataSaverReading.parse(""), .unreadable)
        XCTAssertEqual(DataSaverReading.parse("banana"), .unreadable)
        XCTAssertEqual(DataSaverReading.parse("Restrict background: maybe"), .unreadable)
        XCTAssertNil(DataSaverReading.parse("banana").isOn)
    }
}
