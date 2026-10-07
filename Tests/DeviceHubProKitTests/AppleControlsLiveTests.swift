import XCTest
@testable import DeviceHubProKit

/// A simulator's Controls through `AppleControlsBackend` — the mechanisms
/// the app's panel runs — against the iOS verifier on a real simulator,
/// behind `DHP_IOS_LIVE=1`:
///
///     DHP_IOS_LIVE=1 DHP_SIM_UDID=<default-set UDID> swift test --filter AppleControlsLiveTests
///
/// `testEveryRowRoundTripsOnAPinnedSimulator` needs a booted default-set
/// simulator named in `DHP_SIM_UDID` (devicectl does not see private
/// sets); it installs the verifier there (unless it was installed), changes
/// each row, waits for the verifier's reading, and puts back what it read
/// before (`Snapshot`): the appearance flags, the colour filter's type,
/// intensity and state, the text size, VoiceOver, the volume, the
/// enrolment, the orientation, the pasteboard's text, the language list and
/// region as they were, and the clock. The location is cleared (simctl
/// cannot read it back). A status bar override already in place is left
/// alone and its step skipped: `status_bar list` cannot be replayed exactly.
/// A live row (and the relaunch rows, which relaunch the verifier) must read
/// back within 3 s of the command's start.
/// `testSimctlRowsAndTheBootTimeZoneOnAPrivateSetSimulator` creates its own
/// simulator in a private set (T1: no devicectl), reboots it with a time
/// zone the way the app's lifecycle does, and deletes it.
final class AppleControlsLiveTests: XCTestCase {
    static let bundle = IOSVerifierLiveTests.bundle
    /// A round trip reads back within 3 s.
    static let liveBound: Duration = .seconds(3)

    private var timings: [(String, Duration)] = []

    // MARK: - T2, pinned default-set simulator

    func testEveryRowRoundTripsOnAPinnedSimulator() async throws {
        let toolchain = try await LiveTestSimulators.toolchain()
        let device = try await LiveTestSimulators.pinnedDefaultSetSimulator(toolchain: toolchain)
        guard device.isBooted else { throw XCTSkip("DHP_SIM_UDID \(device.udid) is not booted") }
        let simctl = try XCTUnwrap(toolchain.makeSimctlClient())
        let devicectl = try XCTUnwrap(try toolchain.makeDevicectlClient(for: device), "devicectl is not usable")
        let backend = try AppleControlsBackend(
            udid: device.udid,
            simctl: simctl,
            devicectl: devicectl,
            dataDirectory: device.dataPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
        XCTAssertTrue(backend.hasDevicectl)
        let app = try await iosVerifierApp(toolchain: toolchain)
        let udid = device.udid
        let verifier = VerifierReader(simctl: simctl, udid: udid)
        let hadVerifier = (try? await simctl.appInfo(udid: udid, bundleIdentifier: Self.bundle)) != nil
        let snapshot = try await Snapshot.take(backend)
        do {
            try await simctl.install(udid: udid, app: app)
            try await simctl.checked(["privacy", udid, "grant", "location", Self.bundle])
            let pid = try await simctl.launch(udid: udid, bundleIdentifier: Self.bundle, terminateRunning: true)
            _ = try await verifier.waitForDocument(timeout: .seconds(60))
            try await roundTrips(backend, verifier: verifier, snapshot: snapshot, verifierPID: pid)
        } catch {
            await verifier.keepEvidence(name: "controls")
            await snapshot.restore(backend)
            if !hadVerifier { try? await simctl.uninstall(udid: udid, bundleIdentifier: Self.bundle) }
            throw error
        }
        await snapshot.restore(backend)
        if !hadVerifier { try await simctl.uninstall(udid: udid, bundleIdentifier: Self.bundle) }
        printTimings()
    }

    private func roundTrips(
        _ backend: AppleControlsBackend,
        verifier: VerifierReader,
        snapshot: Snapshot,
        verifierPID: Int
    ) async throws {
        let udid = backend.udid
        // Display & sound.
        let dark = snapshot.appearance.userInterfaceStyle != "dark"
        try await roundTrip("appearance", verifier, "display.appearance", dark ? "dark" : "light") {
            let answer = try await backend.apply(.appearance(dark: dark))
            XCTAssertNotNil(answer, "devicectl answers with the new style")
        }
        try await roundTrip("text size", verifier, "display.textSize", "extra-large") {
            try await backend.apply(.textSize(.extraLarge))
        }
        let toggles: [(String, String, (Bool) -> AppleControlChange)] = [
            ("reduce motion", "display.reduceMotion", { .reduceMotion($0) }),
            ("show borders", "display.showBorders", { .showBorders($0) }),
            ("reduce transparency", "display.reduceTransparency", { .reduceTransparency($0) }),
            ("voiceover", "accessibility.voiceOver", { .voiceOver($0) }),
            ("increase contrast", "accessibility.increaseContrast", { .increaseContrast($0) }),
        ]
        for (label, id, change) in toggles {
            try await roundTrip("\(label) on", verifier, id, "on") { try await backend.apply(change(true)) }
            try await roundTrip("\(label) off", verifier, id, "off") { try await backend.apply(change(false)) }
        }
        let volume = snapshot.volume == 30 ? 70 : 30
        try await roundTrip("volume", verifier, "display.sound", String(volume)) {
            try await backend.apply(.volume(volume))
        }
        try await roundTrip("color filter grayscale", verifier, "accessibility.colorFilter", "grayscale") {
            try await backend.apply(.colorFilter(.grayscale, intensity: nil))
        }
        try await roundTrip("color filter off", verifier, "accessibility.colorFilter", "none") {
            try await backend.apply(.colorFilter(nil, intensity: nil))
        }
        // The appearance poll reads back what the writes did.
        guard case .appearance(let polled) = try await backend.read(.devicectlAppearance) else {
            return XCTFail("the appearance read answered something else")
        }
        XCTAssertEqual(polled.contentSize, .extraLarge)
        XCTAssertEqual(polled.userInterfaceStyle, dark ? "dark" : "light")

        // Liquid Glass: apps cannot read it (a note row); devicectl reads it back.
        try await backend.apply(.liquidGlassOpacity(0.8))
        guard case .appearance(let glass) = try await backend.read(.devicectlAppearance) else { return XCTFail("no appearance") }
        XCTAssertEqual(glass.liquidGlassOpacity ?? 0, 0.8, accuracy: 0.001)
        let glassReading = try await verifier.raw("display.liquidGlass")
        XCTAssertEqual(glassReading, "unreadable")

        // Location, sensors, advanced.
        try await roundTrip("location", verifier, "location.lastFix", "41.00820,28.97840") {
            try await backend.apply(.location(latitude: 41.0082, longitude: 28.9784))
        }
        for pose in [SimulatorDevicePose.landscapeLeft, .faceUp, .portrait] {
            try await roundTrip("orientation \(pose.rawValue)", verifier, "sensors.orientation", pose.rawValue) {
                try await backend.apply(.orientation(pose))
            }
        }
        let biometrics = try await verifier.raw("advanced.biometrics")
        if let type = biometrics.split(separator: ":").first, type != "none" {
            let enrolled = biometrics.hasSuffix(":enrolled")
            try await roundTrip("biometrics enrolment", verifier, "advanced.biometrics", "\(type):\(enrolled ? "notEnrolled" : "enrolled")") {
                try await backend.apply(.biometricsEnrolled(!enrolled))
            }
        }

        // App conditions: push (the verifier never asked to post, so simctl
        // answers 2003, yet the app in front receives it) and permissions
        // (granting photos ends the app; the relaunch reads it).
        try await roundTrip("push", verifier, "appConditions.push", "Device Hub Pro — Controls push") {
            do {
                try await backend.apply(.push(
                    bundleIdentifier: Self.bundle,
                    payload: try SimulatorPushPayload(#"{"aps":{"alert":{"title":"Device Hub Pro","body":"Controls push"}}}"#)
                ))
            } catch let failure as SimctlFailure where failure.isPushNotAuthorized {
                print("CONTROLS-LIVE push answered 2003 (not authorized), as measured")
            }
        }
        try await roundTrip("permissions grant photos + relaunch", verifier, "appConditions.permissions", where: { $0.contains("photos=authorized") }) {
            try await backend.apply(.privacy(.grant, .photos, bundleIdentifier: Self.bundle))
            _ = try await backend.simctl.launch(udid: udid, bundleIdentifier: Self.bundle, terminateRunning: true)
        }
        let pasteboard = try await verifier.raw("clipboard.pasteboard")
        try await roundTrip("clipboard", verifier, "clipboard.pasteboard", where: { $0 != pasteboard }) {
            try await backend.apply(.pasteboard("Device Hub Pro controls \(UUID().uuidString)"))
        }

        // Language & time.
        let hours = try await verifier.raw("languageTime.timeFormat24")
        let setting: TimeFormatSetting = hours == "24" ? .twelveHour : .twentyFourHour
        try await roundTrip("24-hour time", verifier, "languageTime.timeFormat24", setting == .twentyFourHour ? "24" : "12") {
            try await backend.apply(.timeFormat(setting))
        }
        let language = try XCTUnwrap(DeviceLocale(tag: "ar-EG"))
        try await roundTrip("language + relaunch", verifier, "languageTime.language", "ar-EG") {
            try await backend.apply(.language(language))
            _ = try await backend.simctl.launch(udid: udid, bundleIdentifier: Self.bundle, terminateRunning: true)
        }
        let preferences = try XCTUnwrap(try backend.readGlobalPreferences(), "the host file holds the global preferences")
        XCTAssertEqual(preferences.languages.first, "ar-EG")
        XCTAssertEqual(preferences.locale, "ar_EG")
        XCTAssertEqual(preferences.timeFormat, setting)

        // Status bar: the whole set in one call is drawn only (note rows).
        // An override the simulator already had is not the test's to replace.
        if snapshot.statusBarWasClear {
            try await backend.apply(.statusBar(SimulatorStatusBarPreset.lowBattery.applied(to: SimulatorStatusBarState())))
            let listed = try await backend.readStatusBar(over: SimulatorStatusBarState())
            XCTAssertEqual(listed?.batteryLevel, 5)
            XCTAssertEqual(listed?.batteryState, .discharging)
            try await Task.sleep(for: .seconds(2))
            let batteryLevel = try await verifier.raw("statusBar.batteryLevel")
            let batteryState = try await verifier.raw("statusBar.batteryState")
            XCTAssertEqual(batteryLevel, "-1")
            XCTAssertEqual(batteryState, "unknown")
        } else {
            print("CONTROLS-LIVE status bar skipped: the simulator already has an override the test could not put back")
        }

        // Canary: devicectl's memory warning answers success but reaches no
        // app (CoreDevice 642.16). If this starts failing, a Memory warning
        // row can be offered (AppleControlsRouting.memoryWarningUnavailable).
        let pid = try await currentPID(backend.simctl, udid: udid) ?? verifierPID
        let warnings = try await verifier.raw("appConditions.memoryWarning")
        try await backend.devicectl?.sendMemoryWarning(pid: pid)
        try await Task.sleep(for: .seconds(3))
        let warningsAfter = try await verifier.raw("appConditions.memoryWarning")
        XCTAssertEqual(warningsAfter, warnings, "a memory warning now reaches the app")
    }

    /// The verifier's pid from `launchctl list` (it changed with the relaunches).
    private func currentPID(_ simctl: SimctlClient, udid: String) async throws -> Int? {
        try await simctl.launchdJobs(udid: udid)
            .first { $0.label.contains("UIKitApplication:\(Self.bundle)") }?.pid
    }

    // MARK: - T1, private set

    func testSimctlRowsAndTheBootTimeZoneOnAPrivateSetSimulator() async throws {
        let toolchain = try await LiveTestSimulators.toolchain()
        let app = try await iosVerifierApp(toolchain: toolchain)
        let session = try LiveTestSimulators.Session(toolchain: toolchain)
        var verifier: VerifierReader?
        do {
            let device = try await session.createDevice(name: "DeviceHubPro-Live-Controls")
            let udid = device.udid
            let reader = VerifierReader(simctl: session.simctl, udid: udid)
            verifier = reader
            let backend = try AppleControlsBackend(
                udid: udid,
                simctl: session.simctl,
                devicectl: nil,
                dataDirectory: device.dataPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            )
            // T1: the devicectl rows are not offered; the appearance falls back to simctl.
            XCTAssertFalse(backend.route(.reduceMotion).isOffered)
            XCTAssertEqual(backend.route(.appearance).mechanism?.kind, .simctl)

            try await session.simctl.bootStatus(udid: udid, bootIfNeeded: true)
            try await Task.sleep(for: .seconds(10))
            try await session.simctl.install(udid: udid, app: app)
            try await session.simctl.checked(["privacy", udid, "grant", "location", Self.bundle])
            _ = try await session.simctl.launch(udid: udid, bundleIdentifier: Self.bundle, terminateRunning: true)
            _ = try await reader.waitForDocument(timeout: .seconds(60))

            try await roundTrip("simctl appearance dark", reader, "display.appearance", "dark") {
                let answer = try await backend.apply(.appearance(dark: true))
                XCTAssertEqual(answer, .simctlAppearance(.dark))
            }
            let simctlAppearance = try await backend.read(.simctlAppearance)
            XCTAssertEqual(simctlAppearance, .simctlAppearance(.dark))
            try await roundTrip("simctl text size", reader, "display.textSize", "accessibility-medium") {
                try await backend.apply(.textSize(.accessibilityMedium))
            }
            let simctlSize = try await backend.read(.simctlContentSize)
            XCTAssertEqual(simctlSize, .contentSize(.accessibilityMedium))
            try await roundTrip("location scenario", reader, "location.lastFix", where: { $0 != "none" }) {
                try await backend.apply(.location(latitude: 35.6812, longitude: 139.7671))
            }

            // The time zone: taken at boot, as the app's lifecycle boots a
            // simulator (`SimctlClient.boot(udid:timeZone:)`), and read back
            // with getenv; the kept location is set again after the boot.
            let bootZone = try await backend.readBootTimeZone()
            XCTAssertNil(bootZone, "a plain boot takes the Mac's zone")
            try await roundTrip("time zone at boot + location again", reader, "languageTime.timeZone", "Asia/Tokyo", bound: .seconds(180)) {
                try await session.simctl.shutdown(udid: udid)
                try await session.simctl.boot(udid: udid, timeZone: "Asia/Tokyo")
                try await session.simctl.bootStatus(udid: udid)
                try await Task.sleep(for: .seconds(5))
                try await backend.apply(.location(latitude: 35.6812, longitude: 139.7671))
                _ = try await session.simctl.launch(udid: udid, bundleIdentifier: Self.bundle, terminateRunning: true)
            }
            let rebootZone = try await backend.readBootTimeZone()
            XCTAssertEqual(rebootZone, "Asia/Tokyo")
            try await roundTrip("location after the boot", reader, "location.lastFix", "35.68120,139.76710", bound: .seconds(30)) {}
        } catch {
            await verifier?.keepEvidence(name: "controls-private")
            let leftovers = await session.tearDown()
            XCTAssertEqual(leftovers, [])
            throw error
        }
        let leftovers = await session.tearDown()
        XCTAssertEqual(leftovers, [])
        printTimings()
    }

    // MARK: - Helpers

    private func roundTrip(
        _ label: String,
        _ verifier: VerifierReader,
        _ id: String,
        _ raw: String,
        bound: Duration = AppleControlsLiveTests.liveBound,
        change: () async throws -> Void
    ) async throws {
        try await roundTrip(label, verifier, id, where: { $0 == raw }, bound: bound, expected: raw, change: change)
    }

    private func roundTrip(
        _ label: String,
        _ verifier: VerifierReader,
        _ id: String,
        where matches: @escaping @Sendable (String) -> Bool,
        bound: Duration = AppleControlsLiveTests.liveBound,
        expected: String = "a new value",
        change: () async throws -> Void
    ) async throws {
        let clock = ContinuousClock()
        let started = clock.now
        try await change()
        let issued = clock.now - started
        // Wait past the bound to tell a slow row from a broken one.
        let last = try await verifier.wait(for: id, bound: bound + .seconds(7), matches)
        let total = clock.now - started
        guard let last, matches(last) else {
            throw VerifierReader.Failure.timedOut(label: label, id: id, expected: expected, last: last)
        }
        timings.append((label, total))
        print("CONTROLS-LIVE \(label): \(id) = \(last) after \(Self.seconds(total)) (command \(Self.seconds(issued)))")
        XCTAssertLessThanOrEqual(total, bound, "\(label) read back after \(Self.seconds(total))")
    }

    private func printTimings() {
        let lines = timings.map { "  \($0.0): \(Self.seconds($0.1))" }
        print("CONTROLS-LIVE round trips (command start → reading), \(timings.count):\n" + lines.joined(separator: "\n"))
    }

    private static func seconds(_ duration: Duration) -> String {
        String(format: "%.2f s", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }
}

/// What the pinned simulator had before the test, put back afterwards.
private struct Snapshot: Sendable {
    let appearance: DevicectlAppearance
    let voiceOver: Bool
    let volume: Int?
    let biometricsEnrolled: Bool?
    /// The host's global preferences; nil when the file is not there (the
    /// keys the test writes were absent).
    let preferences: SimulatorGlobalPreferences?
    let contentSize: SimulatorContentSize?
    let pose: SimulatorDevicePose?
    /// `simctl pbpaste`; nil when it could not be read.
    let pasteboard: String?
    /// Whether `status_bar list` read no override: only then does the test
    /// set one (and clear it afterwards).
    let statusBarWasClear: Bool

    static func take(_ backend: AppleControlsBackend) async throws -> Snapshot {
        let devicectl = try XCTUnwrap(backend.devicectl)
        let appearance = try await devicectl.appearance().value
        let orientation = try? await devicectl.orientation().value.deviceOrientation
        let statusBar = try? await backend.simctl.statusBarOverrides(udid: backend.udid)
        return Snapshot(
            appearance: appearance,
            voiceOver: try await devicectl.voiceOver().value.enabled,
            volume: try await devicectl.audio().value.volume,
            biometricsEnrolled: try? await devicectl.biometrics().value.isEnrolled,
            preferences: try backend.readGlobalPreferences(),
            contentSize: try await backend.simctl.contentSize(udid: backend.udid),
            pose: orientation.flatMap(SimulatorDevicePose.init(devicectlName:)),
            pasteboard: try? await backend.simctl.pasteboard(udid: backend.udid),
            statusBarWasClear: statusBar?.isEmpty == true
        )
    }

    /// Best effort, each step on its own: a failed step is reported, the
    /// others still run.
    func restore(_ backend: AppleControlsBackend) async {
        var changes: [AppleControlChange] = []
        if let style = appearance.userInterfaceStyle { changes.append(.appearance(dark: style == "dark")) }
        if let on = appearance.reduceMotion { changes.append(.reduceMotion(on)) }
        if let on = appearance.reduceTransparency { changes.append(.reduceTransparency(on)) }
        if let on = appearance.showBorders { changes.append(.showBorders(on)) }
        if let on = appearance.increaseContrast { changes.append(.increaseContrast(on)) }
        if let opacity = appearance.liquidGlassOpacity { changes.append(.liquidGlassOpacity(opacity)) }
        if let contentSize, SimulatorContentSize.settable.contains(contentSize) { changes.append(.textSize(contentSize)) }
        changes.append(.voiceOver(voiceOver))
        if let volume { changes.append(.volume(volume)) }
        if let biometricsEnrolled { changes.append(.biometricsEnrolled(biometricsEnrolled)) }
        // An iPhone that never rotated reads "unknown": upright.
        changes.append(.orientation(pose ?? .portrait))
        changes.append(.clearLocation)
        if statusBarWasClear { changes.append(.statusBar(nil)) }
        changes.append(.timeFormat(preferences?.timeFormat ?? .localeDefault))
        if let pasteboard { changes.append(.pasteboard(pasteboard)) }
        for change in changes {
            do {
                try await backend.apply(change)
            } catch {
                XCTFail("could not restore \(change): \(error)")
            }
        }
        // The filter's type and intensity, and whether it is on.
        if let devicectl = backend.devicectl {
            await restoreColorFilter(devicectl, to: appearance)
        }
        // The whole language list and the region as they were (`.language`
        // writes one language and derives the region from it); a key that
        // was not there is deleted.
        let simctl = backend.simctl
        let udid = backend.udid
        do {
            if let languages = preferences?.languages, !languages.isEmpty {
                try await simctl.writeGlobalDefault(udid: udid, key: "AppleLanguages", .stringArray(languages))
            } else {
                try await simctl.deleteGlobalDefault(udid: udid, key: "AppleLanguages")
            }
            if let locale = preferences?.locale {
                try await simctl.writeGlobalDefault(udid: udid, key: "AppleLocale", .string(locale))
            } else {
                try await simctl.deleteGlobalDefault(udid: udid, key: "AppleLocale")
            }
        } catch {
            XCTFail("could not restore the language and region: \(error)")
        }
        // The larger-accessibility switch simctl turned on for a size.
        if let larger = appearance.largerAccessibilitySizesEnabled {
            _ = try? await backend.devicectl?.setAppearance(.largerAccessibilitySizes(larger))
        }
        _ = try? await backend.simctl.setPrivacy(udid: backend.udid, .reset, service: .photos, bundleIdentifier: IOSVerifierLiveTests.bundle)
    }
}
