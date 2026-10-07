import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// A simulator's Controls panel on stub simctl and devicectl that replay the
/// real captures (`AppleControlsTests` in the Kit has their provenance; the
/// listing is `simctl-list-j-devices.booted.json`, a booted iPhone on iOS
/// 27.0): which rows show at T1 and T2, the attach's reads, the poll's one
/// spawn per tick, the writes' routes and read-backs, and what Device Hub Pro
/// keeps itself (location, status bar, boot time zone).
@MainActor
final class AppleControlsControllerTests: XCTestCase {
    private static let booted = "95D9676B-3317-4BA5-8CF6-3CDD0488CACA"

    // MARK: - Groups

    /// A simulator's panel is Device Hub's three unlabelled cards (measured on
    /// Device Hub 27.0, an iOS 26.5 and an iOS 27.0 simulator, 2026-09-29):
    /// the colour filter only where the runtime can change it.
    func testT2OffersDeviceHubsCardsAndT1HidesTheDevicectlOnes() {
        let t2: (AppleControl) -> AppleControlRoute = {
            AppleControlsRouting.route($0, available: AppleControlsRouting.available(devicectl: true))
        }
        XCTAssertEqual(appleSimulatorCards(route: t2, colorFilterSupported: true), [
            [.appearance, .liquidGlass, .colorFilter, .textSize, .reduceMotion, .increaseContrast,
             .showBorders, .reduceTransparency, .talkBack],
            [.location],
            [.sound, .audioOutput, .audioInput],
        ])
        // iOS 26: devicectl cannot change the colour filter, and Device Hub lists no such row.
        XCTAssertEqual(
            appleSimulatorCards(route: t2, colorFilterSupported: false).first,
            [.appearance, .liquidGlass, .textSize, .reduceMotion, .increaseContrast, .showBorders, .reduceTransparency, .talkBack]
        )
        XCTAssertTrue(appleColorFilterSupported(osVersion: "27.0"))
        XCTAssertFalse(appleColorFilterSupported(osVersion: "26.5"))
        XCTAssertFalse(appleColorFilterSupported(osVersion: nil))

        let t1: (AppleControl) -> AppleControlRoute = {
            AppleControlsRouting.route($0, available: AppleControlsRouting.available(devicectl: false))
        }
        XCTAssertEqual(appleSimulatorCards(route: t1, colorFilterSupported: true), [
            [.appearance, .textSize, .increaseContrast],
            [.location],
        ])

        // The physical iPhone's grouped panel is what its route offers of these groups.
        let groups = appleControlsGroups(route: t2)
        XCTAssertEqual(groups.map(\.id), [.displayAndSound, .accessibility, .location])
        XCTAssertEqual(groups.first?.rows, [.appearance, .liquidGlass, .textSize, .reduceMotion, .showBorders, .reduceTransparency, .sound])
        XCTAssertFalse(groups.flatMap(\.rows).contains(.lowMemory), "memory warning reaches no app")
    }

    /// The groups Device Hub Pro adds below Device Hub's cards (2026-09-30): the Android
    /// panel's titles, collapsed, each only where the route and the device allow it.
    func testSimulatorGroupsFollowTheRouteAndTheDevice() {
        let t2: (AppleControl) -> AppleControlRoute = {
            AppleControlsRouting.route($0, available: AppleControlsRouting.available(devicectl: true))
        }
        let t1: (AppleControl) -> AppleControlRoute = {
            AppleControlsRouting.route($0, available: AppleControlsRouting.available(devicectl: false))
        }
        let full = appleSimulatorGroups(route: t2, supportsBiometrics: true)
        XCTAssertEqual(full.map(\.id), [.biometrics, .languageAndTime, .appConditions])
        XCTAssertEqual(full.map(\.id.title), ["Biometrics", "Language & time", "App conditions"])
        XCTAssertEqual(
            appleSimulatorPlainRows,
            [.addRootCertificate, .resetKeychain, .linkURL, .cleanStatusBar],
            "plain rows above Reset to Defaults, no group"
        )
        XCTAssertEqual(appleSimulatorPlainRows(route: t2), [.addRootCertificate, .resetKeychain, .linkURL, .cleanStatusBar])
        XCTAssertEqual(appleSimulatorTrailingRows, [.resetDefaults])
        XCTAssertEqual(full[0].rows, [.biometricsEnrolled, .biometricsMatch])
        XCTAssertEqual(full[1].rows, [.deviceLanguage, .timeFormat24, .timeZone])
        XCTAssertEqual(full[2].rows, [.targetApp, .permissions, .permissionsAccess, .pushNotification, .launchApp, .terminateApp, .memoryWarning])
        // The memory warning is the Device menu's Simulate Memory Warning as a row: iPhone and iPad
        // simulators only (it has no control to route; devicectl cannot deliver it, a phone has none).
        for family in [ControlsFamily.appleTV, .physicalApple] {
            XCTAssertFalse(
                appleSimulatorGroups(route: t2, supportsBiometrics: true, family: family).flatMap(\.rows).contains(.memoryWarning),
                "\(family)"
            )
        }
        XCTAssertTrue(appleSimulatorGroups(route: t1, supportsBiometrics: true).flatMap(\.rows).contains(.memoryWarning))
        XCTAssertTrue(AppleGroupID.allCases.allSatisfy { !$0.defaultExpanded }, "collapsed by default, like Android's QA groups")
        // A device without a biometric has no Biometrics group; an unread one still offers it.
        XCTAssertFalse(appleSimulatorGroups(route: t2, supportsBiometrics: false).map(\.id).contains(.biometrics))
        XCTAssertTrue(appleSimulatorGroups(route: t2, supportsBiometrics: nil).map(\.id).contains(.biometrics))
        // Without devicectl the biometric rows go; the simctl and preference groups stay.
        XCTAssertFalse(appleSimulatorGroups(route: t1, supportsBiometrics: true).map(\.id).contains(.biometrics))
        XCTAssertEqual(appleSimulatorGroups(route: t1, supportsBiometrics: true).count, 2)
        // Nothing here is a Device Hub card row, and the physical panel offers only what devicectl allows.
        let cards = Set(appleSimulatorCardRows.flatMap { $0 })
        XCTAssertTrue(cards.isDisjoint(with: Set(full.flatMap(\.rows))))
        XCTAssertEqual(applePhysicalGroupRows.map(\.id), [.appConditions])
        XCTAssertEqual(applePhysicalGroupRows[0].rows, [.targetApp, .launchApp, .terminateApp])
        XCTAssertEqual(applePhysicalPlainRows, [.linkURL])
        XCTAssertEqual(
            ControlsRow.applePhysicalExtraRows,
            [.targetApp, .launchApp, .terminateApp, .linkURL]
        )
        for row in ControlsRow.applePhysicalExtraRows.union(Set(full.flatMap(\.rows))) {
            XCTAssertTrue(ControlsRow.appleRows.contains(row), "\(row)")
            XCTAssertTrue(row.platforms.contains(.apple), "\(row)")
        }
    }

    /// Reset to Defaults: only what differs from the default is listed, unread
    /// values count as changed, Liquid Glass only where the two looks exist.
    func testResetToDefaultsListsWhatDiffers() {
        let t2: (AppleControl) -> AppleControlRoute = {
            AppleControlsRouting.route($0, available: AppleControlsRouting.available(devicectl: true))
        }
        var state = AppleControlsState()
        // Nothing read yet: every offered step is listed (colour filter and looks need the runtime).
        XCTAssertEqual(
            appleResetSteps(route: t2, state: state, colorFilterSupported: false, statusBarActive: nil, location: nil),
            [.appearance, .textSize, .reduceMotion, .increaseContrast, .showBorders, .reduceTransparency, .voiceOver]
        )
        state.dark = false
        state.textSize = .large
        state.reduceMotion = false
        state.increaseContrast = false
        state.showBorders = false
        state.reduceTransparency = false
        state.voiceOver = false
        state.colorFilter = .some(nil)
        state.supportedLooks = [.clear, .tinted]
        state.lookAndFeel = .clear
        XCTAssertEqual(
            appleResetSteps(route: t2, state: state, colorFilterSupported: true, statusBarActive: false, location: nil),
            [], "already at the defaults"
        )
        state.dark = true
        state.textSize = .extraLarge
        state.colorFilter = .some(.grayscale)
        state.lookAndFeel = .tinted
        XCTAssertEqual(
            appleResetSteps(
                route: t2, state: state, colorFilterSupported: true, statusBarActive: true,
                location: .scenario("City Run")
            ),
            [.appearance, .textSize, .colorFilter, .liquidGlass, .statusBar, .location]
        )
        // iOS 26 cannot change the colour filter; the iOS 27 Liquid Glass slider is checked below.
        state.supportedLooks = [.clear]
        XCTAssertEqual(
            appleResetSteps(route: t2, state: state, colorFilterSupported: false, statusBarActive: nil, location: nil),
            [.appearance, .textSize]
        )
        // iOS 27: the slider's default is the 0.5 a fresh iOS 27 simulator reports (measured 2026-09-30).
        XCTAssertEqual(appleLiquidGlassDefaultOpacity, 0.5)
        state.liquidGlassOpacity = 0.85
        XCTAssertEqual(
            appleResetSteps(route: t2, state: state, colorFilterSupported: false, statusBarActive: nil, location: nil),
            [.appearance, .textSize, .liquidGlassOpacity]
        )
        state.liquidGlassOpacity = 0.5
        XCTAssertEqual(
            appleResetSteps(route: t2, state: state, colorFilterSupported: false, statusBarActive: nil, location: nil),
            [.appearance, .textSize]
        )
        // A text size of the accessibility range leaves Larger Accessibility Sizes on after Large:
        // Reset turns it off too (measured 2026-09-30 on an iOS 27.0 simulator).
        state.largerAccessibilitySizes = true
        XCTAssertEqual(
            appleResetSteps(route: t2, state: state, colorFilterSupported: false, statusBarActive: nil, location: nil),
            [.appearance, .textSize, .largerAccessibilitySizes]
        )
        state.largerAccessibilitySizes = false
        XCTAssertEqual(
            AppleResetStep.allCases.map(\.title).first,
            "appearance: Light"
        )
    }

    /// Values that did not fit the row at the default inspector width (measured live 2026-09-30:
    /// "English…States)", "5G · 4 b…") are shortened; the popover keeps the full names.
    func testRowValuesAreShortEnoughForTheDefaultInspectorWidth() throws {
        XCTAssertEqual(AppleControlsText.languageValueName(try XCTUnwrap(DeviceLocale(tag: "en-US"))), "English (US)")
        XCTAssertEqual(AppleControlsText.languageValueName(try XCTUnwrap(DeviceLocale(tag: "de-DE"))), "Deutsch (DE)")
        XCTAssertEqual(AppleControlsText.languageValueName(try XCTUnwrap(DeviceLocale(tag: "tr-TR"))), "Türkçe (Türkiye)", "short enough as it is")
    }

    /// The Permissions row's value never runs past 13 characters (the room at the default
    /// width) and the two location services stay distinguishable.
    func testPermissionValuesFitTheRow() {
        for service in SimulatorPrivacyService.allCases {
            XCTAssertLessThanOrEqual(service.valueTitle.count, 13, service.title)
        }
        XCTAssertNotEqual(SimulatorPrivacyService.location.valueTitle, SimulatorPrivacyService.locationAlways.valueTitle)
        XCTAssertEqual(SimulatorPrivacyService.photos.valueTitle, "Photos")
    }

    /// The honesty rule: no Android-only row is ever offered on a simulator.
    func testAndroidOnlyRowsAreNeverOffered() {
        let androidOnly: [ControlsRow] = [
            .wifi, .bluetooth, .airplaneMode, .mobileData, .dataSaver, .battery, .charging, .batterySaver,
            .forceRTL, .showTaps, .backgroundANRs,
            .dateTime, .networkSpeed, .connectionLatency, .killProcess,
            .lowMemory,
        ]
        for row in androidOnly {
            XCTAssertEqual(row.platforms, [.android], "\(row)")
            XCTAssertFalse(ControlsRow.appleRows.contains(row), "\(row)")
        }
        for row in ControlsRow.iosOnly {
            XCTAssertEqual(row.platforms, [.apple], "\(row)")
        }
    }

    func testCaptionsAndTexts() {
        XCTAssertNil(appleSupportCaption(.live))
        XCTAssertNil(appleSupportCaption(.unavailable("x")))
        XCTAssertEqual(appleSupportCaption(.reboot), "Applies when Device Hub Pro starts or restarts this simulator.")
        XCTAssertNotNil(appleSupportCaption(.cosmetic))
        XCTAssertNotNil(appleSupportCaption(.respring))
        XCTAssertEqual(AppleControlsText.textSizeName(.large), "Large (default)")
        XCTAssertEqual(AppleControlsText.colorFilterShortTitle(.deuteranopia), "Deuteranopia")
        XCTAssertEqual(AppleLocationChoice.coordinate(name: nil, latitude: 41.0082, longitude: 28.9784).title, "41.0082, 28.9784")
        XCTAssertTrue(AppleLanguageOptions.all.contains { $0.tag == "tr-TR" })
        XCTAssertFalse(AppleLanguageOptions.all.contains { $0.region == nil })
        XCTAssertTrue(appleControlsOffered(platform: "iOS"))
        XCTAssertTrue(appleControlsOffered(platform: "tvOS"), "measured on a tvOS 27.0 simulator (ControlsFamily.appleTV)")
        XCTAssertFalse(appleControlsOffered(platform: "watchOS"), "no watchOS runtime to measure on")
        XCTAssertFalse(appleControlsOffered(platform: "visionOS"))
        XCTAssertFalse(appleControlsOffered(platform: nil))
        XCTAssertTrue(appleGroupDefaultExpanded(.displayAndSound))
    }

    // MARK: - Controller on stubs

    /// `getenv`: the running boot's `TZ` answer; by default the boot that
    /// took America/New_York.
    private func simctl(extra: String = "", getenv: String? = nil) throws -> StubTool {
        let controls = SimulatorFixtures.root.appendingPathComponent("controls")
        func cat(_ name: String) -> String { "cat " + SimulatorFixtures.quoted(controls.appendingPathComponent(name).path) }
        return try makeStubTool("simctl", arms: """
          *"list -j devices")
            \(SimulatorFixtures.cat("simctl-list-j-devices.booted.json")) ;;
          *"list -j runtimes")
            \(SimulatorFixtures.cat("simctl-list-j-runtimes.json")) ;;
          *"list -j devicetypes")
            \(SimulatorFixtures.cat("simctl-list-j-devicetypes.json")) ;;
          *"getenv \(Self.booted) TZ")
            \(getenv ?? cat("simctl-getenv-TZ.stdout.txt")) ;;
          *"status_bar \(Self.booted) list")
            \(cat("simctl-status_bar-list.empty.stdout.txt")) ;;
          *"location \(Self.booted) list")
            \(cat("simctl-location-list.stdout.txt")) ;;
          *"push \(Self.booted) com.devicehubpro.verifier -")
            \(cat("simctl-push-not-authorized.stderr.txt")) >&2; exit 211 ;;
          \(extra)
          *" \(Self.booted) "*)
            exit 0 ;;
        """)
    }

    private func devicectl() throws -> StubTool {
        let folder = "devicectl"
        return try makeStubTool("devicectl", arms: """
          "device info details --device "*)
            \(SimulatorFixtures.cat("devicectl-device-info-details.json", folder: folder)) ;;
          "device info appearance --device "*)
            \(SimulatorFixtures.cat("devicectl-device-info-appearance.color-filter-deuteranopia.json", folder: folder)) ;;
          "device info voiceover --device "*)
            \(SimulatorFixtures.cat("devicectl-device-info-voiceover.json", folder: folder)) ;;
          "device info audio --device "*)
            \(SimulatorFixtures.cat("devicectl-device-info-audio.json", folder: folder)) ;;
          "device settings biometrics --device "*)
            \(SimulatorFixtures.cat("devicectl-device-settings-biometrics.query.json", folder: folder)) ;;
          "device orientation get --device "*)
            \(SimulatorFixtures.cat("devicectl-device-orientation-get.json", folder: folder)) ;;
          "device settings appearance --reduce-motion on --device "*)
            \(SimulatorFixtures.cat("devicectl-device-settings-appearance-reduce-motion-on.json", folder: folder)) ;;
          "device settings voiceover --enable --device "*)
            \(SimulatorFixtures.cat("devicectl-device-settings-voiceover-enable.json", folder: folder)) ;;
          "device simulate biometrics --success --device "*)
            \(SimulatorFixtures.cat("devicectl-device-simulate-biometrics-success.json", folder: folder)) ;;
          "device simulate biometrics --failure --device "*)
            \(SimulatorFixtures.cat("devicectl-device-simulate-biometrics-failure.json", folder: folder)) ;;
        """)
    }

    /// A default-set inventory whose devicectl answers (T2 when `devicectl`).
    private func controller(simctl: StubTool, devicectl: StubTool?) async throws -> (AppleControlsController, SimulatorInventory, AppPreferences) {
        let developer = try makeTemporaryFolder("developer")
        let set = try makeTemporaryFolder("set")
        let toolchain = AppleToolchain(
            developerDirectory: developer,
            xcodeVersion: "27.0",
            xcodeBuild: "27A266a",
            firstLaunchComplete: true,
            simctl: .init(binary: simctl.url, installedVersion: nil, expectedVersion: nil, needsFirstLaunch: false, isOverride: true),
            devicectl: devicectl.map {
                .init(binary: $0.url, installedVersion: "642.16", expectedVersion: "642.16", needsFirstLaunch: false)
            } ?? .missing
        )
        let tooling = AppleTooling(
            probe: { toolchain },
            deviceSet: nil,
            devicesDirectory: set,
            logsDirectory: try makeTemporaryFolder("logs")
        )
        let preferences = AppPreferences(defaults: .scratch())
        let inventory = SimulatorInventory(apple: tooling, preferences: preferences)
        addTeardownBlock { @MainActor in inventory.stop() }
        await inventory.refresh()
        let controller = AppleControlsController(
            simulators: inventory,
            preferences: preferences,
            memory: AppleDeviceMemory(preferences: preferences),
            status: StatusCenter()
        )
        return (controller, inventory, preferences)
    }

    private func devicectlCalls(_ stub: StubTool) -> [String] {
        stub.calls.map { $0.replacingOccurrences(of: " --device \(Self.booted) -j - -t 30", with: "") }
    }

    /// T2: the attach reads every row once (devicectl's five reads, the boot
    /// zone, the status bar, the scenarios); then each poll tick spends one
    /// spawn, the appearance every other tick.
    func testAttachReadsEverythingThenPollsOneSpawnPerTick() async throws {
        let simctl = try simctl()
        let devicectl = try devicectl()
        let (controller, _, _) = try await controller(simctl: simctl, devicectl: devicectl)
        await controller.attach(Self.booted)

        XCTAssertTrue(controller.isLoaded)
        XCTAssertTrue(controller.hasDevicectl)
        XCTAssertEqual(controller.state.dark, false)
        XCTAssertEqual(controller.state.colorFilter, .some(.deuteranopia))
        XCTAssertEqual(controller.state.voiceOver, false)
        XCTAssertEqual(controller.state.volume, 60)
        XCTAssertEqual(controller.state.biometricType, "Face ID")
        XCTAssertEqual(controller.state.pose, .portrait)
        XCTAssertEqual(controller.bootTimeZone, .some("America/New_York"))
        XCTAssertEqual(controller.statusBarActive, false)
        XCTAssertEqual(controller.locationScenarios, ["City Run", "City Bicycle Ride", "Freeway Drive", "Apple"])
        XCTAssertTrue(controller.groups.flatMap(\.rows).contains(.reduceTransparency))
        XCTAssertEqual(Set(devicectlCalls(devicectl)), [
            "device info details", "device info appearance", "device info voiceover", "device info audio",
            "device settings biometrics", "device orientation get",
        ])

        let before = devicectl.calls.count + simctl.calls.count
        for _ in 0..<4 { await controller.pollTick() }
        let after = Array(devicectlCalls(devicectl).suffix(4))
        XCTAssertEqual(after, ["device info appearance", "device info voiceover", "device info appearance", "device info audio"])
        XCTAssertEqual(devicectl.calls.count + simctl.calls.count - before, 4, "one spawn per tick")
    }

    /// A devicectl write's answer is the read-back; simctl rows update from
    /// what they were told.
    func testWritesRouteAndReadBack() async throws {
        let simctl = try simctl()
        let devicectl = try devicectl()
        let (controller, _, _) = try await controller(simctl: simctl, devicectl: devicectl)
        await controller.attach(Self.booted)

        await controller.setReduceMotion(true)
        XCTAssertEqual(controller.state.reduceMotion, true)
        XCTAssertEqual(controller.state.dark, true, "the answer carries the style")
        await controller.setVoiceOver(true)
        XCTAssertEqual(controller.state.voiceOver, true)
        await controller.setTextSize(.accessibilityLarge)
        XCTAssertEqual(controller.state.textSize, .accessibilityLarge)
        await controller.setIncreaseContrast(true)
        XCTAssertEqual(controller.state.increaseContrast, true)
        XCTAssertTrue(simctl.calls.contains("ui \(Self.booted) content_size accessibility-large"))
        XCTAssertTrue(simctl.calls.contains("ui \(Self.booted) increase_contrast enabled"))
        XCTAssertTrue(devicectlCalls(devicectl).contains("device settings appearance --reduce-motion on"))
    }

    /// T1 (devicectl missing): the appearance falls back to simctl's three
    /// `ui` reads, one per tick, and the devicectl rows are hidden.
    func testWithoutDevicectl() async throws {
        let simctl = try simctl()
        let (controller, _, _) = try await controller(simctl: simctl, devicectl: nil)
        await controller.attach(Self.booted)
        XCTAssertFalse(controller.hasDevicectl)
        XCTAssertFalse(controller.groups.flatMap(\.rows).contains(.reduceMotion))
        let reads = simctl.calls.filter { $0.hasPrefix("ui ") }
        XCTAssertEqual(Set(reads), [
            "ui \(Self.booted) appearance", "ui \(Self.booted) content_size", "ui \(Self.booted) increase_contrast",
        ])
        let before = simctl.calls.count
        await controller.pollTick()
        await controller.pollTick()
        XCTAssertEqual(Array(simctl.calls.dropFirst(before)), ["ui \(Self.booted) appearance", "ui \(Self.booted) content_size"])
    }

    /// simctl has no location read-back: the controller keeps the choice and
    /// sets it again when the simulator is ready after a boot Device Hub Pro
    /// started.
    func testTheLocationIsKeptAndSetAgainAfterABoot() async throws {
        let simctl = try simctl()
        let (controller, _, _) = try await controller(simctl: simctl, devicectl: nil)
        await controller.attach(Self.booted)
        await controller.setLocation(.coordinate(name: "İstanbul", latitude: 41.0082, longitude: 28.9784))
        XCTAssertEqual(controller.location?.title, "İstanbul")
        XCTAssertEqual(simctl.calls.filter { $0.hasPrefix("location") && !$0.hasSuffix("list") }, [
            "location \(Self.booted) set 41.008200,28.978400",
        ])
        controller.simulatorBecameReady(Self.booted, bootStartedHere: true)
        try await waitUntil { simctl.calls.filter { $0.contains("set 41.008200,28.978400") }.count == 2 }

        await controller.setLocation(.scenario("City Run"))
        await controller.setLocation(nil)
        XCTAssertNil(controller.location)
        XCTAssertEqual(simctl.calls.suffix(2), ["location \(Self.booted) run City Run", "location \(Self.booted) clear"])
        controller.simulatorBecameReady(Self.booted, bootStartedHere: true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(simctl.calls.last, "location \(Self.booted) clear", "nothing kept, nothing set")
    }

    /// A boot Device Hub Pro only followed (Xcode's Run, Simulator.app, a script,
    /// a Refresh) gets no location: a kept scenario is not started over on
    /// someone else's boot, and the row stops showing a choice that boot
    /// does not have.
    func testAFollowedBootGetsNoLocation() async throws {
        let simctl = try simctl()
        let (controller, _, _) = try await controller(simctl: simctl, devicectl: nil)
        await controller.attach(Self.booted)
        await controller.setLocation(.scenario("City Run"))
        XCTAssertEqual(controller.location, .scenario("City Run"))
        let sent = simctl.calls.filter { $0.hasPrefix("location") && !$0.hasSuffix(" list") }
        XCTAssertEqual(sent, ["location \(Self.booted) run City Run"])

        controller.simulatorBecameReady(Self.booted, bootStartedHere: false)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(simctl.calls.filter { $0.hasPrefix("location") && !$0.hasSuffix(" list") }, sent, "no location call")
        XCTAssertNil(controller.location)

        // A later boot Device Hub Pro starts has nothing to set either.
        controller.simulatorBecameReady(Self.booted, bootStartedHere: true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(simctl.calls.filter { $0.hasPrefix("location") && !$0.hasSuffix(" list") }, sent)
    }

    /// Clean status bar sends the whole Screenshot look in one call and clear removes it.
    func testCleanStatusBarSendsTheWholeSet() async throws {
        let simctl = try simctl()
        let (controller, _, _) = try await controller(simctl: simctl, devicectl: nil)
        await controller.attach(Self.booted)
        XCTAssertFalse(simctl.calls.contains { $0.contains("override") }, "off: nothing is sent")
        await controller.setCleanStatusBar(true)
        XCTAssertEqual(simctl.calls.last, "status_bar \(Self.booted) override --time 9:41 --dataNetwork 5g --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 --operatorName  --batteryState charged --batteryLevel 100", "the Screenshot look over a fresh model")
        await controller.setCleanStatusBar(false)
        XCTAssertEqual(simctl.calls.last, "status_bar \(Self.booted) clear")
        XCTAssertEqual(controller.statusBarActive, false)
    }

    /// A write that ends after the user selected another simulator changes
    /// only the simulator it was for: the other's Override stays as read,
    /// and its rows are not held busy by the first one's write.
    func testAWriteThatEndsAfterASwitchLeavesTheOtherSimulatorAlone() async throws {
        let simctl = try simctl(extra: """
          *"status_bar \(Self.booted) override "*)
            sleep 1 ; exit 0 ;;
        """)
        let (controller, _, _) = try await controller(simctl: simctl, devicectl: nil)
        await controller.attach(Self.booted)
        XCTAssertEqual(controller.statusBarActive, false)
        let write = Task { await controller.setStatusBarActive(true) }
        try await waitUntil { controller.isBusy(.statusBar) }

        // Another simulator (not listed: the attach stops before its reads).
        let other = "00000000-0000-4000-8000-000000000002"
        await controller.attach(other)
        XCTAssertFalse(controller.isBusy(.statusBar), "the first simulator's write holds only its own row")
        await write.value
        XCTAssertEqual(controller.udid, other)
        XCTAssertNil(controller.statusBarActive, "the other simulator's Override is its own")
        XCTAssertEqual(controller.statusBar, SimulatorStatusBarState())
        XCTAssertEqual(controller.busyControls, [:])

        // The write itself landed for the simulator it was for.
        XCTAssertTrue(simctl.calls.contains { $0.hasPrefix("status_bar \(Self.booted) override ") })
        await controller.attach(Self.booted)
        XCTAssertEqual(controller.statusBarActive, false, "read again from the device (the stub lists none)")
    }

    /// "Source is not authorized" is not an alert: the app in front still
    /// receives the push, and the row says so.
    func testAPushToAnAppThatNeverAskedIsExplained() async throws {
        let simctl = try simctl()
        let (controller, _, _) = try await controller(simctl: simctl, devicectl: nil)
        await controller.attach(Self.booted)
        controller.targetBundle = "com.devicehubpro.verifier"
        controller.pushText = #"{"x":1}"#
        await controller.sendPush()
        XCTAssertEqual(controller.pushNote, SimulatorPushPayload.Problem.missingAPS.description)
        XCTAssertFalse(simctl.calls.contains { $0.hasPrefix("push") }, "checked before simctl")
        controller.pushText = SimulatorPushPayload.template
        var sentPushes: [SentPush] = []
        controller.onPushSent = { sentPushes.append($0) }
        await controller.sendPush()
        XCTAssertEqual(sentPushes.map(\.bundleIdentifier), ["com.devicehubpro.verifier"], "simctl took it: Resend Last Push may enable")
        XCTAssertTrue(controller.pushNote?.contains("never asked to post notifications") == true, controller.pushNote ?? "")
        XCTAssertTrue(simctl.calls.contains("push \(Self.booted) com.devicehubpro.verifier -"))
    }

    /// The Push sheet closes on a push simctl took and stays open (with the
    /// note or the alert) otherwise.
    func testSendPushReportsWhetherTheSheetMayClose() async throws {
        let simctl = try simctl()
        let (controller, _, _) = try await controller(simctl: simctl, devicectl: nil)
        await controller.attach(Self.booted)
        controller.pushText = SimulatorPushPayload.template
        controller.targetBundle = "com.devicehubpro.other"
        let sent = await controller.sendPush()
        XCTAssertTrue(sent)
        XCTAssertTrue(controller.pushNote?.hasPrefix("Sent to") == true, controller.pushNote ?? "")
        controller.targetBundle = "com.devicehubpro.verifier"
        let refused = await controller.sendPush()
        XCTAssertFalse(refused, "not authorized keeps the sheet open on its note")
        controller.pushText = "{"
        let malformed = await controller.sendPush()
        XCTAssertFalse(malformed)
        controller.targetBundle = nil
        let none = await controller.sendPush()
        XCTAssertFalse(none)
    }

    /// One wording for the searchable popups on both platforms.
    func testSearchPromptsShareOneWording() {
        XCTAssertEqual(DHSearchPrompt.languages, "Search languages")
        XCTAssertEqual(DHSearchPrompt.timeZones, "Search time zones")
    }

    /// A language change writes both keys and asks for a respring, which
    /// restarts SpringBoard in the simulator's foreground domain; a boot
    /// shows the language everywhere too.
    func testALanguageChangeAsksForARespring() async throws {
        let simctl = try simctl()
        let (controller, _, _) = try await controller(simctl: simctl, devicectl: nil)
        await controller.attach(Self.booted)
        XCTAssertFalse(controller.respringSuggested)
        await controller.setLanguage(try XCTUnwrap(DeviceLocale(tag: "de-DE")))
        XCTAssertTrue(controller.respringSuggested)
        XCTAssertEqual(controller.state.preferences?.languages, ["de-DE"])
        XCTAssertEqual(controller.state.preferences?.locale, "de_DE")
        await controller.respring()
        XCTAssertFalse(controller.respringSuggested)
        XCTAssertEqual(Array(simctl.calls.suffix(3)), [
            "spawn \(Self.booted) defaults write -g AppleLanguages -array de-DE",
            "spawn \(Self.booted) defaults write -g AppleLocale -string de_DE",
            "spawn \(Self.booted) launchctl kickstart -k user/foreground/com.apple.SpringBoard",
        ])
        await controller.setLanguage(try XCTUnwrap(DeviceLocale(tag: "fr-FR")))
        XCTAssertTrue(controller.respringSuggested)
        controller.simulatorBecameReady(Self.booted, bootStartedHere: false)
        XCTAssertFalse(controller.respringSuggested, "any boot shows the language")
    }

    /// The boot zone is kept per simulator and handed to the boots the
    /// lifecycle starts (`SIMCTL_CHILD_TZ`); the running boot's zone decides
    /// whether the row asks for a restart.
    func testTheTimeZoneGoesToTheBootsDeviceHubProStarts() async throws {
        // This test's own folder (removed at teardown): a file left by an
        // earlier or a concurrent run cannot answer for this boot.
        let zones = try makeTemporaryFolder("tz")
        let simctl = try simctl(extra: """
          *"boot 00000000-0000-4000-8000-000000000001")
            printf '%s' "$SIMCTL_CHILD_TZ" > \(SimulatorFixtures.quoted(zones.path))/boot-$$ ; exit 1 ;;
        """)
        let (controller, _, preferences) = try await controller(simctl: simctl, devicectl: nil)
        await controller.attach(Self.booted)
        XCTAssertTrue(controller.needsRestartForTimeZone, "the boot took New York; no choice means the Mac's zone")
        controller.setTimeZone("America/New_York")
        XCTAssertEqual(controller.timeZone(for: Self.booted), "America/New_York")
        XCTAssertFalse(controller.needsRestartForTimeZone)
        controller.setTimeZone("Asia/Tokyo")
        XCTAssertTrue(controller.needsRestartForTimeZone)
        XCTAssertEqual(preferences.simulatorTimeZones, [Self.booted: "Asia/Tokyo"])

        // The lifecycle's boot passes the zone to simctl.
        let lifecycle = SimulatorLifecycleController(status: StatusCenter())
        lifecycle.simctlSource = { SimctlClient(simctlURL: simctl.url) }
        lifecycle.timeZoneSource = { udid in udid == "00000000-0000-4000-8000-000000000001" ? "Europe/Paris" : nil }
        await lifecycle.boot("00000000-0000-4000-8000-000000000001")
        let written = try FileManager.default.contentsOfDirectory(at: zones, includingPropertiesForKeys: nil)
        XCTAssertEqual(written.count, 1, "one boot")
        let zone = try written.first.map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertEqual(zone, "Europe/Paris")
    }

    /// The usual boot takes no zone (Xcode's, or Device Hub Pro's with none
    /// chosen): `getenv` prints "'TZ' not found" on stderr and exits 0
    /// (the capture; measured again on 2026-09-26, a fresh iPhone 17 Pro on
    /// iOS 27.0, byte for byte). The row reads the Mac's zone and offers
    /// Restart once a zone is chosen; a failed read offers nothing.
    func testABootWithoutAZoneOffersRestartOnceOneIsChosen() async throws {
        let controls = SimulatorFixtures.root.appendingPathComponent("controls")
        let notSet = "cat " + SimulatorFixtures.quoted(controls.appendingPathComponent("simctl-getenv-TZ.not-set.stderr.txt").path) + " >&2; exit 0"
        let simctl = try simctl(getenv: notSet)
        let (controller, _, _) = try await controller(simctl: simctl, devicectl: nil)
        await controller.attach(Self.booted)
        XCTAssertEqual(controller.bootTimeZone, .some(nil), "read: the Mac's zone")
        XCTAssertFalse(controller.needsRestartForTimeZone, "no choice, no zone")
        controller.setTimeZone("Asia/Tokyo")
        XCTAssertTrue(controller.needsRestartForTimeZone)
        controller.setTimeZone(nil)
        XCTAssertFalse(controller.needsRestartForTimeZone)

        let failing = try self.simctl(getenv: "exit 1")
        let (unread, _, _) = try await self.controller(simctl: failing, devicectl: nil)
        await unread.attach(Self.booted)
        XCTAssertNil(unread.bootTimeZone, "not read")
        unread.setTimeZone("Asia/Tokyo")
        XCTAssertFalse(unread.needsRestartForTimeZone, "an unread boot zone asks for nothing")
    }

    // MARK: - The biometric result waits

    /// A prompt signal the test drives.
    private final class StubPromptSignal: BiometricPromptSignal, @unchecked Sendable {
        private let lock = NSLock()
        private var up: Bool?
        private var presented = false
        private var waiters: [CheckedContinuation<Void, Error>] = []
        private var _starts = 0
        init(up: Bool?) { self.up = up }
        var starts: Int { lock.withLock { _starts } }
        func isPromptUp() async -> Bool? { lock.withLock { up } }
        func waitForPrompt() async throws {
            lock.withLock { _starts += 1 }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let done = lock.withLock { () -> Bool in
                        if presented { return true }
                        waiters.append(continuation)
                        return false
                    }
                    if done { continuation.resume() }
                }
            } onCancel: {
                let pending = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
                    defer { waiters = [] }
                    return waiters
                }
                for waiter in pending { waiter.resume(throwing: CancellationError()) }
            }
        }
        func present() {
            let pending = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
                presented = true
                defer { waiters = [] }
                return waiters
            }
            for waiter in pending { waiter.resume() }
        }
    }

    private func matchCalls(_ devicectl: StubTool) -> [String] {
        devicectlCalls(devicectl).filter { $0.hasPrefix("device simulate biometrics") }
    }

    /// A prompt that is up already: today's behaviour, sent at once, nothing pending.
    func testABiometricResultIsSentAtOnceWhenAPromptIsUp() async throws {
        let (controller, devicectl) = try await attachedForBiometrics(signal: StubPromptSignal(up: true))
        await controller.simulateBiometricMatch(success: true)
        XCTAssertEqual(matchCalls(devicectl), ["device simulate biometrics --success"])
        XCTAssertNil(controller.pendingBiometric)
    }

    /// No prompt: the request is pending, shows as such, and goes when the prompt comes.
    func testABiometricResultWaitsForThePromptAndIsSentWhenItComes() async throws {
        let signal = StubPromptSignal(up: false)
        let (controller, devicectl) = try await attachedForBiometrics(signal: signal)
        let request = Task { await controller.simulateBiometricMatch(success: false) }
        try await waitUntil { controller.pendingBiometric != nil }
        XCTAssertEqual(controller.pendingBiometric, .init(success: false, udid: Self.booted))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(matchCalls(devicectl), [], "nothing is sent before the prompt")
        signal.present()
        await request.value
        XCTAssertEqual(matchCalls(devicectl), ["device simulate biometrics --failure"])
        XCTAssertNil(controller.pendingBiometric)
    }

    func testAPendingBiometricResultTimesOut() async throws {
        let (controller, devicectl) = try await attachedForBiometrics(signal: StubPromptSignal(up: false))
        controller.biometricTimeout = .milliseconds(200)
        await controller.simulateBiometricMatch(success: true)
        XCTAssertEqual(matchCalls(devicectl), [])
        XCTAssertNil(controller.pendingBiometric)
    }

    func testAPendingBiometricResultCanBeCancelled() async throws {
        let signal = StubPromptSignal(up: false)
        let (controller, devicectl) = try await attachedForBiometrics(signal: signal)
        let request = Task { await controller.simulateBiometricMatch(success: true) }
        try await waitUntil { controller.pendingBiometric != nil }
        controller.cancelPendingBiometric()
        await request.value
        XCTAssertNil(controller.pendingBiometric)
        signal.present()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(matchCalls(devicectl), [], "a prompt after the cancel gets nothing")
    }

    /// Selecting another device (an attach) or leaving (a detach) drops the request.
    func testSwitchingDeviceDropsAPendingBiometricResult() async throws {
        let signal = StubPromptSignal(up: false)
        let (controller, devicectl) = try await attachedForBiometrics(signal: signal)
        let request = Task { await controller.simulateBiometricMatch(success: true) }
        try await waitUntil { controller.pendingBiometric != nil }
        let token = await controller.attach(Self.booted)
        await request.value
        XCTAssertNil(controller.pendingBiometric)
        signal.present()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(matchCalls(devicectl), [])
        controller.detach(token)
    }

    private func attachedForBiometrics(signal: StubPromptSignal) async throws -> (AppleControlsController, StubTool) {
        let simctl = try simctl()
        let devicectl = try devicectl()
        let (controller, _, _) = try await controller(simctl: simctl, devicectl: devicectl)
        await controller.attach(Self.booted)
        controller.biometricSignalOverride = { _ in signal }
        controller.biometricSettle = .milliseconds(10)
        return (controller, devicectl)
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Two Controls panels over one `AppleDeviceMemory`: what
/// Device Hub Pro keeps per simulator is the app's, not a window's, so a second
/// window's panel shows what the first one kept.
@MainActor
final class AppleDeviceMemorySharingTests: XCTestCase {
    private static let udid = "425BD068-3D87-4F27-BE58-EB56A58B2C3A"

    private func twoPanels() -> (AppleControlsController, AppleControlsController, AppleDeviceMemory) {
        let preferences = AppPreferences(defaults: .scratch())
        let inventory = SimulatorInventory(apple: nil, preferences: preferences)
        let memory = AppleDeviceMemory(preferences: preferences)
        let first = AppleControlsController(simulators: inventory, preferences: preferences, memory: memory, status: StatusCenter())
        let second = AppleControlsController(simulators: inventory, preferences: preferences, memory: memory, status: StatusCenter())
        return (first, second, memory)
    }

    func testTwoPanelsOverOneMemoryAgree() {
        let (first, second, memory) = twoPanels()
        var bar = SimulatorStatusBarState()
        bar.time = "9:41"

        first.noteBatchChange(.location(latitude: 41.0, longitude: 29.0), udid: Self.udid)
        first.noteBatchChange(.statusBar(bar), udid: Self.udid)
        memory.markBusy(.voiceOver, on: Self.udid)
        memory.setTimeZone("Europe/Istanbul", udid: Self.udid)

        XCTAssertEqual(second.locations[Self.udid], .coordinate(name: nil, latitude: 41.0, longitude: 29.0))
        XCTAssertEqual(second.statusBars[Self.udid]?.time, "9:41")
        XCTAssertEqual(second.busyControls[Self.udid], [.voiceOver])
        XCTAssertEqual(second.timeZone(for: Self.udid), "Europe/Istanbul")
        XCTAssertEqual(first.locations, second.locations)

        // A boot started elsewhere drops the kept location, for both.
        second.simulatorBecameReady(Self.udid, bootStartedHere: false)
        XCTAssertNil(first.locations[Self.udid])
        memory.clearBusy(.voiceOver, on: Self.udid)
        XCTAssertEqual(first.busyControls, [:])
    }

    /// The model hands its one memory to the panel it builds, and the
    /// lifecycle's boot zone reads that memory.
    func testTheModelsPanelUsesTheAppMemory() {
        let model = AppModel.testing()
        XCTAssertTrue(model.appleControls.memory === model.appleDeviceMemory)
        model.appleDeviceMemory.setTimeZone("Asia/Tokyo", udid: Self.udid)
        XCTAssertEqual(model.appleControls.timeZone(for: Self.udid), "Asia/Tokyo")
    }
}

@MainActor
final class DeviceRowAccessibilityTests: XCTestCase {
    func testLabelHasNoStrayDotOrDoubleSpace() {
        XCTAssertEqual(
            DeviceRowAccessibility.label(title: "AQA Verify", subtitle: "Simulator", memoryBytes: 3 << 30, osLabel: "iOS 27.0"),
            "AQA Verify, Simulator, 3.0 GB in use, iOS 27.0")
        XCTAssertEqual(
            DeviceRowAccessibility.label(title: "AQA Verify", subtitle: "Simulator", memoryBytes: nil, osLabel: "iOS 27.0"),
            "AQA Verify, Simulator, iOS 27.0")
    }

    func testTooltipIsOneSentenceWithEmulatorNote() {
        XCTAssertEqual(DeviceRowAccessibility.tooltip(memoryBytes: 3 << 30, isAndroidEmulator: false), "Memory in use: 3.0 GB")
        XCTAssertEqual(DeviceRowAccessibility.tooltip(memoryBytes: 5 << 30, isAndroidEmulator: false), "Memory in use: 5.0 GB (high)")
        XCTAssertTrue(DeviceRowAccessibility.tooltip(memoryBytes: 3 << 30, isAndroidEmulator: true).contains("Activity Monitor"))
        XCTAssertEqual(DeviceRowAccessibility.tooltip(memoryBytes: nil, isAndroidEmulator: true), "")
    }
}
