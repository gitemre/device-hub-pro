import XCTest
@testable import DeviceHubProKit

/// A simulator's Controls in the Kit: the devicectl and simctl commands
/// behind the rows, fed real captures, the routing, the poll's budget and
/// the models Device Hub Pro keeps itself (status bar, push payload, global
/// preferences).
///
/// Captures (2026-09-26, Xcode 27.0 27A266a, CoreSimulator 1171.7,
/// CoreDevice 642.16, JSON version 5) from `DeviceHubPro-UI-ios-controls-2`, a
/// throwaway iPhone 17 Pro (iOS 27.0, 24A434) created for them in the default
/// set (CoreDevice does not see private sets), UDID
/// B3ECBA42-7A43-4A8C-924D-C13CC6658BA4, booted, then deleted with its log
/// folder. Every devicectl call carried `--device <that UDID> -j - -t 30`
/// and every simctl call that UDID; nothing was listed. The captures hold no
/// user name or path and are byte-exact:
/// - `devicectl/`: `info appearance` with Deuteranopia at 0.6 and with
///   Grayscale; `settings appearance --color-filter on --color-filter-type
///   deuteranopia --color-filter-intensity 0.6`, `--color-filter off`,
///   `--liquid-glass-opacity 0.8`, `--look-and-feel tinted` (the answer still
///   says "Liquid Glass"), and the usage error for an intensity of 2
///   (stderr, exit 64); `info voiceover`, `settings voiceover --enable` /
///   `--disable`; `info audio`, `settings audio --volume 40` and the usage
///   error for 101 (stderr, exit 64); `settings biometrics` (a query),
///   `--enable`, `--disable`; `simulate biometrics --success` / `--failure`;
///   `process sendMemoryWarning --pid <the verifier's pid>`; `orientation
///   set faceUp`.
/// - `controls/`: `status_bar override --batteryLevel 101` (exit 22) and
///   `--wifiMode notSupported` (exit 117, usage), `status_bar list` after a
///   full override, `location start` (stderr), `privacy grant camera2 …`
///   (exit 1), `push` to the verifier (exit 211, not authorized), to
///   MobileSMS (stdout), without `aps` (exit 22) and over 4096 bytes
///   (exit 28), a `spawn defaults delete -g` of a missing key (exit 1),
///   `getenv TZ` without and with `SIMCTL_CHILD_TZ=America/New_York` at boot, and the host's
///   `.GlobalPreferences.plist` after `AppleICUForce24HourTime`,
///   `AppleLanguages (ar-EG)` and `AppleLocale ar_EG` were written.
///
/// `devicectl/devicectl-device-settings-biometrics.touch-id.query.json`
/// (2026-09-26, the same Xcode, CoreSimulator and CoreDevice) is the query
/// on `DeviceHubPro-UI-controls-fix-ipad`, a throwaway iPad (A16) on iOS 27.0,
/// UDID 22EF39AE-0150-4F90-99AF-6AC9981559B0, created in the default set for
/// it, booted, then deleted with its log folder; byte-exact.
final class AppleControlsTests: XCTestCase {
    static let udid = "B3ECBA42-7A43-4A8C-924D-C13CC6658BA4"

    private static func devicectlURL(_ name: String) -> URL { SimctlFixtureTests.url("devicectl", name) }
    private static func controlsURL(_ name: String) -> URL { SimctlFixtureTests.url("controls", name) }

    private func simulator() -> SimulatorDevice {
        SimulatorDevice(
            udid: Self.udid,
            name: "DeviceHubPro-UI-ios-controls-2",
            state: .booted,
            isAvailable: true,
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
        )
    }

    private func devicectl(_ rules: [FakeTool.Rule]) throws -> (FakeTool, DevicectlClient) {
        let fake = try FakeTool(name: "devicectl", rules: rules)
        return (fake, try DevicectlClient(devicectlURL: fake.executableURL, simulator: simulator()))
    }

    private var tail: [String] { ["--device", Self.udid, "-j", "-", "-t", "30"] }

    // MARK: - devicectl documents

    func testColorFilterReadingsNameTheTypeAndIntensity() throws {
        let deuteranopia = try DevicectlJSON.decode(
            DevicectlAppearance.self,
            from: Data(contentsOf: Self.devicectlURL("devicectl-device-info-appearance.color-filter-deuteranopia.json"))
        ).value
        XCTAssertEqual(deuteranopia.colorFilter, true)
        XCTAssertEqual(deuteranopia.colorFilterType, "Deuteranopia")
        XCTAssertEqual(deuteranopia.colorFilterIntensity, 0.6)
        XCTAssertEqual(deuteranopia.colorFilterSelection, .deuteranopia)
        XCTAssertEqual(deuteranopia.contentSize, .large)
        XCTAssertEqual(deuteranopia.liquidGlassOpacity, 0.5)

        let grayscale = try DevicectlJSON.decode(
            DevicectlAppearance.self,
            from: Data(contentsOf: Self.devicectlURL("devicectl-device-info-appearance.color-filter-grayscale.json"))
        ).value
        XCTAssertEqual(grayscale.colorFilterSelection, .grayscale)
        XCTAssertNil(grayscale.colorFilterIntensity, "Grayscale has no intensity")

        let off = try DevicectlJSON.decode(
            DevicectlAppearance.self,
            from: Data(contentsOf: Self.devicectlURL("devicectl-device-settings-appearance-color-filter-off.json"))
        ).value
        XCTAssertEqual(off.colorFilter, false)
        XCTAssertNil(off.colorFilterSelection)
        // The older capture (no filter ever set) decodes as before.
        let plain = try DevicectlJSON.decode(
            DevicectlAppearance.self,
            from: Data(contentsOf: Self.devicectlURL("devicectl-device-info-appearance.json"))
        ).value
        XCTAssertEqual(plain.colorFilter, false)
        XCTAssertNil(plain.colorFilterType)
    }

    /// `--look-and-feel tinted` answers success, yet the look reads back as
    /// "Liquid Glass", the only one iOS 27.0 lists: the Controls offer the
    /// opacity, which does read back.
    func testLookAndFeelDoesNotReadBackButOpacityDoes() throws {
        let tinted = try DevicectlJSON.decode(
            DevicectlAppearance.self,
            from: Data(contentsOf: Self.devicectlURL("devicectl-device-settings-appearance-look-and-feel-tinted.json"))
        ).value
        XCTAssertEqual(tinted.lookAndFeel, "Liquid Glass")
        XCTAssertEqual(tinted.supportedLooksAndFeels, ["Liquid Glass"])
        let opacity = try DevicectlJSON.decode(
            DevicectlAppearance.self,
            from: Data(contentsOf: Self.devicectlURL("devicectl-device-settings-appearance-liquid-glass-opacity.json"))
        ).value
        XCTAssertEqual(opacity.liquidGlassOpacity, 0.8)
    }

    func testVoiceOverAudioBiometricsMemoryWarningAndPoseDocuments() throws {
        func decode<T: Decodable & Sendable>(_ type: T.Type, _ name: String) throws -> T {
            try DevicectlJSON.decode(type, from: Data(contentsOf: Self.devicectlURL(name))).value
        }
        XCTAssertEqual(try decode(DevicectlVoiceOver.self, "devicectl-device-info-voiceover.json").enabled, false)
        let on = try decode(DevicectlVoiceOver.self, "devicectl-device-settings-voiceover-enable.json")
        XCTAssertEqual(on.enabled, true)
        XCTAssertEqual(on.operation, "enable")
        XCTAssertEqual(try decode(DevicectlVoiceOver.self, "devicectl-device-settings-voiceover-disable.json").enabled, false)

        let audio = try decode(DevicectlAudio.self, "devicectl-device-info-audio.json")
        XCTAssertEqual(audio.volume, 60)
        XCTAssertEqual(audio.outputIsSystemDefault, true)
        XCTAssertEqual(audio.inputIsSystemDefault, true)
        XCTAssertEqual(try decode(DevicectlAudio.self, "devicectl-device-settings-audio-volume.json").volume, 40)

        let query = try decode(DevicectlBiometrics.self, "devicectl-device-settings-biometrics.query.json")
        XCTAssertEqual(query.primaryType, "Face ID")
        XCTAssertFalse(query.isEnrolled)
        XCTAssertEqual(query.operation, "query")
        XCTAssertTrue(try decode(DevicectlBiometrics.self, "devicectl-device-settings-biometrics-enable.json").isEnrolled)
        XCTAssertFalse(try decode(DevicectlBiometrics.self, "devicectl-device-settings-biometrics-disable.json").isEnrolled)
        XCTAssertEqual(
            try decode(DevicectlBiometricMatch.self, "devicectl-device-simulate-biometrics-success.json").operation,
            "simulateSuccessfulMatch"
        )
        XCTAssertEqual(
            try decode(DevicectlBiometricMatch.self, "devicectl-device-simulate-biometrics-failure.json").operation,
            "simulateFailedMatch"
        )
        XCTAssertEqual(
            try decode(DevicectlMemoryWarning.self, "devicectl-device-process-sendMemoryWarning.json").process?.processIdentifier,
            95894
        )
        let faceUp = try decode(DevicectlOrientation.self, "devicectl-device-orientation-set-faceUp.json")
        XCTAssertEqual(faceUp.deviceOrientation, "faceUp")
        XCTAssertEqual(faceUp.deviceOrientationNonFlat, "portrait")
    }

    // MARK: - devicectl commands

    func testControlsCommandsAddressTheSimulator() async throws {
        let (fake, client) = try devicectl([
            .init("info voiceover", stdoutFile: Self.devicectlURL("devicectl-device-info-voiceover.json")),
            .init("voiceover --enable", stdoutFile: Self.devicectlURL("devicectl-device-settings-voiceover-enable.json")),
            .init("info audio", stdoutFile: Self.devicectlURL("devicectl-device-info-audio.json")),
            .init("audio --volume", stdoutFile: Self.devicectlURL("devicectl-device-settings-audio-volume.json")),
            .init("biometrics --enable", stdoutFile: Self.devicectlURL("devicectl-device-settings-biometrics-enable.json")),
            .init("settings biometrics", stdoutFile: Self.devicectlURL("devicectl-device-settings-biometrics.query.json")),
            .init("simulate biometrics --success", stdoutFile: Self.devicectlURL("devicectl-device-simulate-biometrics-success.json")),
            .init("orientation set", stdoutFile: Self.devicectlURL("devicectl-device-orientation-set-faceUp.json")),
            .init("sendMemoryWarning", stdoutFile: Self.devicectlURL("devicectl-device-process-sendMemoryWarning.json")),
            .init("--color-filter-type", stdoutFile: Self.devicectlURL("devicectl-device-settings-appearance-color-filter-deuteranopia.json")),
            .init("--liquid-glass-opacity", stdoutFile: Self.devicectlURL("devicectl-device-settings-appearance-liquid-glass-opacity.json")),
        ])
        _ = try await client.voiceOver()
        try await client.setVoiceOver(true)
        _ = try await client.audio()
        try await client.setVolume(40)
        _ = try await client.biometrics()
        try await client.setBiometricsEnrolled(true)
        try await client.simulateBiometricMatch(success: true)
        try await client.setPose(.faceUp)
        try await client.sendMemoryWarning(pid: 95894)
        try await client.setAppearance(.colorFilterType(.deuteranopia, intensity: 0.6))
        try await client.setAppearance(.liquidGlassOpacity(0.8))
        XCTAssertEqual(fake.invocations, [
            ["device", "info", "voiceover"] + tail,
            ["device", "settings", "voiceover", "--enable"] + tail,
            ["device", "info", "audio"] + tail,
            ["device", "settings", "audio", "--volume", "40"] + tail,
            ["device", "settings", "biometrics"] + tail,
            ["device", "settings", "biometrics", "--enable"] + tail,
            ["device", "simulate", "biometrics", "--success"] + tail,
            ["device", "orientation", "set", "faceUp"] + tail,
            ["device", "process", "sendMemoryWarning", "--pid", "95894"] + tail,
            ["device", "settings", "appearance", "--color-filter-type", "deuteranopia", "--color-filter-intensity", "0.60"] + tail,
            ["device", "settings", "appearance", "--liquid-glass-opacity", "0.80"] + tail,
        ])
    }

    /// Values devicectl refuses as usage errors are refused before it runs;
    /// the captured usage error still surfaces when one gets through.
    func testOutOfRangeValuesAreRefusedFirst() async throws {
        let (fake, client) = try devicectl([
            .init(
                "--volume",
                stdoutFile: nil,
                stderrFile: Self.devicectlURL("devicectl-device-settings-audio-volume-101.stderr.txt"),
                exitCode: 64
            ),
        ])
        await XCTAssertThrowsErrorAsync(try await client.setVolume(101))
        await XCTAssertThrowsErrorAsync(try await client.setAppearance(.liquidGlassOpacity(1.2)))
        await XCTAssertThrowsErrorAsync(try await client.setAppearance(.colorFilterType(.protanopia, intensity: 2)))
        await XCTAssertThrowsErrorAsync(try await client.sendMemoryWarning(pid: 0))
        XCTAssertEqual(fake.invocations, [], "nothing reached devicectl")

        // Usage errors from devicectl itself (exit 64, stderr only).
        let (filterFake, filterClient) = try devicectl([
            .init(
                "--color-filter-intensity",
                stdoutFile: nil,
                stderrFile: Self.devicectlURL("devicectl-device-settings-appearance-color-filter-intensity-2.stderr.txt"),
                exitCode: 64
            ),
        ])
        do {
            _ = try await filterClient.run(
                ["device", "settings", "appearance", "--color-filter-type", "protanopia", "--color-filter-intensity", "2"],
                as: DevicectlAppearance.self
            )
            XCTFail("expected the usage error")
        } catch let error as DevicectlClientError {
            XCTAssertEqual(error, .usage(exitCode: 64, message: "Error: --color-filter-intensity must be between 0.25 and 1.0"))
        }
        withExtendedLifetime(filterFake) {}
        let direct = try DevicectlClient(devicectlURL: fake.executableURL, simulator: simulator())
        do {
            _ = try await direct.run(["device", "settings", "audio", "--volume", "101"], as: DevicectlAudio.self)
            XCTFail("expected the usage error")
        } catch let error as DevicectlClientError {
            XCTAssertEqual(error, .usage(exitCode: 64, message: "Error: Volume must be between 0 and 100"))
        }
    }

    func testAppearanceSettingArgumentsForFilterAndGlass() {
        XCTAssertEqual(
            DevicectlAppearanceSetting.colorFilterType(.grayscale, intensity: 0.6).arguments,
            ["--color-filter-type", "grayscale"],
            "Grayscale takes no intensity"
        )
        XCTAssertEqual(
            DevicectlAppearanceSetting.colorFilterType(.tritanopia, intensity: nil).arguments,
            ["--color-filter-type", "tritanopia"]
        )
        XCTAssertEqual(DevicectlAppearanceSetting.colorFilter(false).arguments, ["--color-filter", "off"])
        XCTAssertEqual(DevicectlAppearanceSetting.liquidGlassOpacity(0.25).arguments, ["--liquid-glass-opacity", "0.25"])
        XCTAssertEqual(SimulatorColorFilterType(devicectlName: "Protanopia"), .protanopia)
        XCTAssertNil(SimulatorColorFilterType(devicectlName: "Sepia"))
        XCTAssertEqual(SimulatorContentSize(devicectlName: "Accessibility Extra Large"), .accessibilityExtraLarge)
        XCTAssertNil(SimulatorContentSize(devicectlName: "Unknown"))
    }

    // MARK: - State

    func testStateMergesWholeAndPartialAnswers() throws {
        var state = AppleControlsState()
        state.apply(.appearance(try DevicectlJSON.decode(
            DevicectlAppearance.self,
            from: Data(contentsOf: Self.devicectlURL("devicectl-device-info-appearance.color-filter-deuteranopia.json"))
        ).value))
        XCTAssertEqual(state.dark, false)
        XCTAssertEqual(state.textSize, .large)
        XCTAssertEqual(state.reduceMotion, false)
        XCTAssertEqual(state.colorFilter, .some(.deuteranopia))
        XCTAssertEqual(state.colorFilterIntensity, 0.6)
        XCTAssertEqual(state.liquidGlassOpacity, 0.5)

        // `settings appearance --reduce-motion on` carries only that field
        // (and the style): nothing else is touched.
        state.apply(.appearance(try DevicectlJSON.decode(
            DevicectlAppearance.self,
            from: Data(contentsOf: Self.devicectlURL("devicectl-device-settings-appearance-reduce-motion-on.json"))
        ).value))
        XCTAssertEqual(state.reduceMotion, true)
        XCTAssertEqual(state.dark, true)
        XCTAssertEqual(state.colorFilter, .some(.deuteranopia))
        XCTAssertEqual(state.textSize, .large)

        state.apply(.appearance(try DevicectlJSON.decode(
            DevicectlAppearance.self,
            from: Data(contentsOf: Self.devicectlURL("devicectl-device-settings-appearance-color-filter-off.json"))
        ).value))
        XCTAssertEqual(state.colorFilter, .some(nil), "off, not unread")
        XCTAssertEqual(state.colorFilterIntensity, 0.6, "the last intensity is kept for the next filter")

        state.apply(.simctlAppearance(.unknown))
        XCTAssertNil(state.dark)
        state.apply(.contentSize(.unsupported))
        XCTAssertNil(state.textSize)
        state.apply(.increaseContrast(.enabled))
        XCTAssertEqual(state.increaseContrast, true)
        state.apply(.orientation(DevicectlOrientation(
            deviceIdentifier: nil, deviceOrientation: "unknown", deviceOrientationNonFlat: nil, deviceIsOrientationLocked: false
        )))
        XCTAssertEqual(state.pose, .portrait, "an iPhone that never rotated reports unknown")
        state.apply(.biometrics(try DevicectlJSON.decode(
            DevicectlBiometrics.self,
            from: Data(contentsOf: Self.devicectlURL("devicectl-device-settings-biometrics-enable.json"))
        ).value))
        XCTAssertEqual(state.biometricType, "Face ID")
        XCTAssertEqual(state.biometricsEnrolled, true)
        XCTAssertEqual(state.supportsBiometrics, true, "the row offers enrolment and a match")
        state.apply(.biometrics(try DevicectlJSON.decode(
            DevicectlBiometrics.self,
            from: Data(contentsOf: Self.devicectlURL("devicectl-device-settings-biometrics.touch-id.query.json"))
        ).value))
        XCTAssertEqual(state.biometricType, "Touch ID")
        XCTAssertEqual(state.supportsBiometrics, true)
        XCTAssertEqual(state.biometricsEnrolled, false)
        // No capture lists no type: both device types tried answer with one
        // (iPhone 17 Pro Face ID, iPad (A16) Touch ID), and an empty list
        // has not been seen. This pins the model's rule behind the row's
        // "no Face ID, Touch ID or Optic ID" caption, not a devicectl answer.
        state.apply(.biometrics(DevicectlBiometrics(deviceIdentifier: nil, biometrics: [], operation: "query")))
        XCTAssertEqual(state.supportsBiometrics, false)
        XCTAssertNil(state.biometricType)
    }

    // MARK: - Routing and poll

    func testRoutingPrefersReadBackAndHidesWhatCannotRun() {
        let t2 = AppleControlsRouting.available(devicectl: true)
        let t1 = AppleControlsRouting.available(devicectl: false)
        XCTAssertEqual(AppleControlsRouting.route(.appearance, available: t2).mechanism?.kind, .devicectl)
        XCTAssertEqual(AppleControlsRouting.route(.appearance, available: t1).mechanism?.kind, .simctl)
        XCTAssertEqual(AppleControlsRouting.route(.textSize, available: t2).mechanism?.kind, .simctl, "one call sets any size")
        XCTAssertEqual(AppleControlsRouting.route(.increaseContrast, available: t2).mechanism?.kind, .simctl)
        for control in [AppleControl.reduceMotion, .showBorders, .reduceTransparency, .liquidGlass, .volume, .voiceOver, .colorFilter, .orientation, .biometrics] {
            XCTAssertEqual(AppleControlsRouting.route(control, available: t2).mechanism?.kind, .devicectl, "\(control)")
            let hidden = AppleControlsRouting.route(control, available: t1)
            XCTAssertFalse(hidden.isOffered, "\(control)")
            XCTAssertEqual(hidden.support, .unavailable(AppleControlsRouting.devicectlUnavailable), "\(control)")
        }
        let memory = AppleControlsRouting.route(.memoryWarning, available: t2)
        XCTAssertFalse(memory.isOffered)
        XCTAssertEqual(memory.support, .unavailable(AppleControlsRouting.memoryWarningUnavailable))
        XCTAssertEqual(AppleControlsRouting.route(.memoryWarning, available: t1).support.unavailableReason,
                       AppleControlsRouting.memoryWarningUnavailable)
        XCTAssertEqual(AppleControlsRouting.route(.language, available: t1).support, .respring)
        XCTAssertEqual(AppleControlsRouting.route(.language, available: t1).mechanism?.kind, .simUndocumented)
        XCTAssertEqual(AppleControlsRouting.route(.timeZone, available: t1).support, .reboot)
        XCTAssertEqual(AppleControlsRouting.route(.statusBar, available: t1).support, .cosmetic)
        XCTAssertEqual(AppleControlsRouting.route(.permissions, available: t1).support, .relaunchApp)
        XCTAssertEqual(AppleControlsRouting.route(.location, available: t1).mechanism?.readsBack, false)
        // Every control has at least one mechanism.
        for control in AppleControl.allCases {
            XCTAssertFalse(AppleControlsRouting.mechanisms(for: control).isEmpty, "\(control)")
        }
    }

    /// One spawn per tick: the appearance every other tick with devicectl
    /// (one read covers every field), the secondary reads in turn between.
    func testThePollSpendsOneSpawnPerTick() {
        let t2 = (0..<10).map { AppleControlsPollPlan.read(forTick: $0, devicectl: true) }
        XCTAssertEqual(t2, [
            .devicectlAppearance, .devicectlVoiceOver,
            .devicectlAppearance, .devicectlAudio,
            .devicectlAppearance, .devicectlBiometrics,
            .devicectlAppearance, .devicectlOrientation,
            .devicectlAppearance, .devicectlVoiceOver,
        ])
        let t1 = (0..<4).map { AppleControlsPollPlan.read(forTick: $0, devicectl: false) }
        XCTAssertEqual(t1, [.simctlAppearance, .simctlContentSize, .simctlIncreaseContrast, .simctlAppearance])
        XCTAssertEqual(AppleControlsPollPlan.read(forTick: -3, devicectl: true), .devicectlAppearance)
        XCTAssertEqual(AppleControlsPollPlan.initialReads(devicectl: true).count, 5)
        XCTAssertEqual(AppleControlsPollPlan.initialReads(devicectl: false), AppleControlsPollPlan.simctlReads)
        XCTAssertEqual(AppleControlsPollPlan.interval, .seconds(2))
    }

    // MARK: - Status bar

    func testTheStatusBarSendsTheWholeSet() throws {
        let state = SimulatorStatusBarState(operatorName: "Device Hub Pro")
        XCTAssertEqual(state.overrideArguments, [
            "--time", "9:41", "--dataNetwork", "5g", "--wifiMode", "active", "--wifiBars", "3",
            "--cellularMode", "active", "--cellularBars", "4", "--operatorName", "Device Hub Pro",
            "--batteryState", "charged", "--batteryLevel", "100",
        ])
        XCTAssertNoThrow(try state.validate())
        var bad = state
        bad.batteryLevel = 101
        XCTAssertThrowsError(try bad.validate()) { XCTAssertEqual($0 as? SimulatorStatusBarState.Problem, .batteryLevel(101)) }
        bad = state
        bad.time = "9:41 AM"
        XCTAssertThrowsError(try bad.validate())
        XCTAssertTrue(SimulatorStatusBarState.isClockTime("09:41"))
        XCTAssertTrue(SimulatorStatusBarState.isClockTime("23:59"))
        XCTAssertFalse(SimulatorStatusBarState.isClockTime("24:00"))
        XCTAssertFalse(SimulatorStatusBarState.isClockTime("12:34:56"))
        XCTAssertFalse(SimulatorStatusBarState.isClockTime("١٢:٣٤"))
    }

    /// `status_bar list` after the full override reads back into the model;
    /// an empty list is no override.
    func testTheListReadsBackIntoTheModel() throws {
        let text = try String(contentsOf: Self.controlsURL("simctl-status_bar-list.override-controls.stdout.txt"), encoding: .utf8)
        let list = SimctlParsing.statusBarOverrides(from: text)
        let state = try XCTUnwrap(SimulatorStatusBarState.fromList(list, over: SimulatorStatusBarState(dataNetwork: .hide, batteryLevel: 7)))
        XCTAssertEqual(state, SimulatorStatusBarState(time: "09:41", operatorName: "Device Hub Pro"))
        let empty = try String(contentsOf: Self.controlsURL("simctl-status_bar-list.empty.stdout.txt"), encoding: .utf8)
        XCTAssertNil(SimulatorStatusBarState.fromList(SimctlParsing.statusBarOverrides(from: empty), over: state))
    }

    func testPresets() {
        let base = SimulatorStatusBarState(time: "10:10", operatorName: "Carrier")
        let low = SimulatorStatusBarPreset.lowBattery.applied(to: base)
        XCTAssertEqual(low.batteryLevel, 5)
        XCTAssertEqual(low.batteryState, .discharging)
        XCTAssertEqual(low.time, "10:10")
        XCTAssertEqual(low.operatorName, "Carrier")
        XCTAssertEqual(SimulatorStatusBarPreset.matching(low), .lowBattery)
        XCTAssertEqual(SimulatorStatusBarPreset.matching(SimulatorStatusBarPreset.screenshot.applied(to: base)), .screenshot)
        var custom = low
        custom.batteryLevel = 33
        XCTAssertNil(SimulatorStatusBarPreset.matching(custom))
        for preset in SimulatorStatusBarPreset.allCases {
            XCTAssertNoThrow(try preset.applied(to: base).validate(), "\(preset)")
        }
    }

    // MARK: - Push, preferences

    func testPushPayloadIsCheckedLikeSimctl() throws {
        XCTAssertNoThrow(try SimulatorPushPayload(SimulatorPushPayload.template))
        XCTAssertThrowsError(try SimulatorPushPayload("  ")) { XCTAssertEqual($0 as? SimulatorPushPayload.Problem, .empty) }
        XCTAssertThrowsError(try SimulatorPushPayload(#"{"x":1}"#)) { XCTAssertEqual($0 as? SimulatorPushPayload.Problem, .missingAPS) }
        XCTAssertThrowsError(try SimulatorPushPayload(#"[1]"#)) { XCTAssertEqual($0 as? SimulatorPushPayload.Problem, .notAnObject) }
        XCTAssertThrowsError(try SimulatorPushPayload(#"{"aps": "#)) {
            guard case .notJSON? = $0 as? SimulatorPushPayload.Problem else { return XCTFail("\($0)") }
        }
        let big = #"{"aps":{"alert":"a"},"pad":""# + String(repeating: "x", count: 4100) + #""}"#
        XCTAssertThrowsError(try SimulatorPushPayload(big)) {
            XCTAssertEqual($0 as? SimulatorPushPayload.Problem, .tooLarge(bytes: big.utf8.count))
        }
        // UTF-8 bytes count, not characters: 4096 ş-es are 8192 bytes.
        let turkish = #"{"aps":{"alert":""# + String(repeating: "ş", count: 2040) + #""}}"#
        XCTAssertThrowsError(try SimulatorPushPayload(turkish))
    }

    /// Without an override the switch shows the locale's own clock (a fresh
    /// simulator inherits the Mac's region); an override wins over it.
    func testTheEffectiveClockFollowsTheLocaleUntilOverridden() {
        let mac = Locale(identifier: "en_US")
        XCTAssertTrue(SimulatorGlobalPreferences(locale: "tr_TR").uses24HourClock(fallback: mac))
        XCTAssertTrue(SimulatorGlobalPreferences(locale: "de_DE").uses24HourClock(fallback: mac))
        XCTAssertFalse(SimulatorGlobalPreferences(locale: "en_US").uses24HourClock(fallback: mac))
        XCTAssertFalse(SimulatorGlobalPreferences(locale: nil).uses24HourClock(fallback: mac), "no AppleLocale: the Mac's region")
        XCTAssertTrue(SimulatorGlobalPreferences(locale: nil).uses24HourClock(fallback: Locale(identifier: "tr_TR")))
        XCTAssertFalse(SimulatorGlobalPreferences(locale: "tr_TR", force12Hour: true).uses24HourClock(fallback: mac))
        XCTAssertTrue(SimulatorGlobalPreferences(locale: "en_US", force24Hour: true).uses24HourClock(fallback: mac))
    }

    func testGlobalPreferencesReadFromTheHostFile() throws {
        let arabic = try SimulatorGlobalPreferences.parse(Data(contentsOf: Self.controlsURL("GlobalPreferences.ar_EG-24h.plist")))
        XCTAssertEqual(arabic.languages, ["ar-EG"])
        XCTAssertEqual(arabic.locale, "ar_EG")
        XCTAssertEqual(arabic.timeFormat, .twentyFourHour)
        let english = try SimulatorGlobalPreferences.parse(Data(contentsOf: SimctlFixtureTests.url("bridge", "GlobalPreferences.en_US.plist")))
        XCTAssertEqual(english.timeFormat, .localeDefault)
        XCTAssertFalse(english.languages.isEmpty)

        XCTAssertEqual(SimulatorGlobalPreferences(force12Hour: true).timeFormat, .twelveHour)
        XCTAssertEqual(SimulatorGlobalPreferences(force24Hour: true, force12Hour: true).timeFormat, .twentyFourHour)
        XCTAssertEqual(SimulatorGlobalPreferences.timeFormatWrites(.twentyFourHour).map(\.key), ["AppleICUForce12HourTime", "AppleICUForce24HourTime"])
        XCTAssertEqual(SimulatorGlobalPreferences.timeFormatWrites(.twentyFourHour).map(\.value), [nil, true])
        XCTAssertEqual(SimulatorGlobalPreferences.timeFormatWrites(.localeDefault).map(\.value), [nil, nil])
        XCTAssertEqual(SimulatorGlobalPreferences.localeIdentifier(for: try XCTUnwrap(DeviceLocale(tag: "tr-TR"))), "tr_TR")
        XCTAssertEqual(SimulatorGlobalPreferences.localeIdentifier(for: try XCTUnwrap(DeviceLocale(tag: "zh-Hans-CN"))), "zh_CN")
        XCTAssertNil(SimulatorGlobalPreferences.localeIdentifier(for: try XCTUnwrap(DeviceLocale(tag: "fr"))))

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AppleControls-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertNil(try SimulatorGlobalPreferences.read(dataDirectory: folder), "a device that never booted")
    }
}
