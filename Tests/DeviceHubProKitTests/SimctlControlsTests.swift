import XCTest
@testable import DeviceHubProKit

/// The simctl commands behind a simulator's Controls and
/// `AppleControlsBackend`'s routing, on fake tools that replay the captures
/// described in `AppleControlsTests`.
final class SimctlControlsTests: XCTestCase {
    private static let udid = AppleControlsTests.udid

    private static func controlsURL(_ name: String) -> URL { SimctlFixtureTests.url("controls", name) }
    private static func devicectlURL(_ name: String) -> URL { SimctlFixtureTests.url("devicectl", name) }

    private func simctl(_ rules: [FakeTool.Rule]) throws -> (FakeTool, SimctlClient) {
        let fake = try FakeTool(name: "simctl", rules: rules)
        return (fake, SimctlClient(simctlURL: fake.executableURL))
    }

    func testStatusBarLocationPrivacyAndPushArgv() async throws {
        let (fake, client) = try simctl([
            .init("location \(Self.udid) start", stdoutFile: nil, stderrFile: Self.controlsURL("simctl-location-start.stderr.txt")),
            .init("push", stdoutFile: Self.controlsURL("simctl-push.stdout.txt")),
        ])
        let udid = Self.udid
        try await client.overrideStatusBar(udid: udid, SimulatorStatusBarState(operatorName: "All"))
        try await client.runLocationScenario(udid: udid, name: "City Run")
        try await client.startLocationRoute(
            udid: udid,
            waypoints: [(41.0082, 28.9784), (41.0151, 28.9795)],
            speed: 20
        )
        try await client.clearLocation(udid: udid)
        try await client.setPrivacy(udid: udid, .grant, service: .photos, bundleIdentifier: "com.devicehubpro.verifier")
        let answer = try await client.push(
            udid: udid,
            bundleIdentifier: "com.apple.MobileSMS",
            payload: try SimulatorPushPayload(#"{"aps":{"alert":"Hi"}}"#)
        )
        XCTAssertEqual(answer, "Notification sent to 'com.apple.MobileSMS'")
        try await client.respring(udid: udid)
        XCTAssertEqual(fake.invocations, [
            ["status_bar", udid, "override", "--time", "9:41", "--dataNetwork", "5g", "--wifiMode", "active",
             "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4", "--operatorName", "All",
             "--batteryState", "charged", "--batteryLevel", "100"],
            ["location", udid, "run", "City Run"],
            ["location", udid, "start", "--speed=20", "--interval=1", "41.008200,28.978400", "41.015100,28.979500"],
            ["location", udid, "clear"],
            ["privacy", udid, "grant", "photos", "com.devicehubpro.verifier"],
            ["push", udid, "com.apple.MobileSMS", "-"],
            ["spawn", udid, "launchctl", "kickstart", "-k", "user/foreground/com.apple.SpringBoard"],
        ])
    }

    func testValuesSimctlWouldTakeAreCheckedFirst() async throws {
        let (fake, client) = try simctl([])
        let udid = Self.udid
        var badTime = SimulatorStatusBarState()
        badTime.time = "12:34:56"
        await XCTAssertThrowsErrorAsync(try await client.overrideStatusBar(udid: udid, badTime))
        await XCTAssertThrowsErrorAsync(try await client.startLocationRoute(udid: udid, waypoints: [(1, 1)]))
        await XCTAssertThrowsErrorAsync(try await client.startLocationRoute(udid: udid, waypoints: [(1, 1), (999, 1)]))
        await XCTAssertThrowsErrorAsync(try await client.runLocationScenario(udid: udid, name: "--help"))
        await XCTAssertThrowsErrorAsync(try await client.setPrivacy(udid: udid, .grant, service: .photos, bundleIdentifier: "-x"))
        await XCTAssertThrowsErrorAsync(try await client.writeGlobalDefault(udid: udid, key: "-g", .bool(true)))
        await XCTAssertThrowsErrorAsync(try await client.environmentVariable(udid: udid, name: "A B"))
        await XCTAssertThrowsErrorAsync(try await client.push(
            udid: "booted",
            bundleIdentifier: "com.apple.MobileSMS",
            payload: try SimulatorPushPayload(SimulatorPushPayload.template)
        ))
        XCTAssertEqual(fake.invocations, [])
    }

    /// The captured failures decode to what the rows say about them.
    func testCapturedFailures() async throws {
        let (fake, client) = try simctl([
            .init("--batteryLevel", stdoutFile: nil, stderrFile: Self.controlsURL("simctl-status_bar-override-battery-level-101.stderr.txt"), exitCode: 22),
            .init("com.devicehubpro.verifier -", stdoutFile: nil, stderrFile: Self.controlsURL("simctl-push-not-authorized.stderr.txt"), exitCode: 211),
            .init("camera2", stdoutFile: nil, stderrFile: Self.controlsURL("simctl-privacy-grant-unknown-service.stderr.txt"), exitCode: 1),
        ])
        do {
            // The model refuses 101 itself; `checked` shows what simctl says.
            _ = try await client.checked(["status_bar", Self.udid, "override", "--batteryLevel", "101"])
            XCTFail("expected a failure")
        } catch let failure as SimctlFailure {
            XCTAssertEqual(failure.kind, .invalidArgument)
            XCTAssertEqual(failure.underlying.first?.code, 22)
        }
        do {
            try await client.push(udid: Self.udid, bundleIdentifier: "com.devicehubpro.verifier", payload: try SimulatorPushPayload(SimulatorPushPayload.template))
            XCTFail("expected 2003")
        } catch let failure as SimctlFailure {
            XCTAssertTrue(failure.isPushNotAuthorized)
            XCTAssertEqual(failure.error, SimctlErrorReference(domain: "UNErrorDomain", code: 2003))
        }
        do {
            _ = try await client.checked(["privacy", Self.udid, "grant", "camera2", "com.devicehubpro.verifier"])
            XCTFail("expected a failure")
        } catch let failure as SimctlFailure {
            XCTAssertFalse(failure.isPushNotAuthorized)
            XCTAssertEqual(failure.error?.code, 1)
        }
        withExtendedLifetime(fake) {}
    }

    /// simctl's own refusals decode as the rows expect: a push without
    /// `aps` (22) and one over 4096 bytes (28, a misleading "No space left on
    /// device"), both refused before simctl by `SimulatorPushPayload`, and
    /// the `notSupported` Wi-Fi mode simctl's help omits (usage, 117), which
    /// `SimulatorWiFiMode` cannot express.
    func testSimctlsRefusalsDecode() {
        func failure(_ name: String, _ exitCode: Int32) throws -> SimctlFailure {
            SimctlErrors.failure(
                arguments: ["x"],
                exitCode: exitCode,
                standardError: try String(contentsOf: Self.controlsURL(name), encoding: .utf8)
            )
        }
        XCTAssertEqual(try failure("simctl-push-missing-aps.stderr.txt", 22).kind, .invalidArgument)
        XCTAssertEqual(try failure("simctl-push-missing-aps.stderr.txt", 22).underlying.first?.code, 22)
        XCTAssertEqual(try failure("simctl-push-too-large.stderr.txt", 28).error?.code, 28)
        XCTAssertEqual(try failure("simctl-status_bar-override-wifi-mode-notSupported.stderr.txt", 117).kind, .usage)
        XCTAssertNil(SimulatorWiFiMode(rawValue: "notSupported"))
    }

    /// `defaults delete` of a key that is not there counts as done; `getenv`
    /// answers nil when the boot took the Mac's zone (stderr, exit 0).
    func testGlobalDefaultsAndBootEnvironment() async throws {
        let (fake, client) = try simctl([
            .init("defaults delete -g AppleICUForce12HourTime", stdoutFile: nil,
                  stderrFile: Self.controlsURL("simctl-spawn-defaults-delete-missing-key.stderr.txt"), exitCode: 1),
            .init("getenv \(Self.udid) TZ", stdoutFile: Self.controlsURL("simctl-getenv-TZ.stdout.txt")),
        ])
        let udid = Self.udid
        try await client.writeGlobalDefault(udid: udid, key: "AppleLanguages", .stringArray(["all"]))
        try await client.writeGlobalDefault(udid: udid, key: "AppleLocale", .string("tr_TR"))
        try await client.writeGlobalDefault(udid: udid, key: "AppleICUForce24HourTime", .bool(true))
        try await client.deleteGlobalDefault(udid: udid, key: "AppleICUForce12HourTime")
        let zone = try await client.environmentVariable(udid: udid, name: "TZ")
        XCTAssertEqual(zone, "America/New_York")
        XCTAssertEqual(fake.invocations, [
            ["spawn", udid, "defaults", "write", "-g", "AppleLanguages", "-array", "all"],
            ["spawn", udid, "defaults", "write", "-g", "AppleLocale", "-string", "tr_TR"],
            ["spawn", udid, "defaults", "write", "-g", "AppleICUForce24HourTime", "-bool", "true"],
            ["spawn", udid, "defaults", "delete", "-g", "AppleICUForce12HourTime"],
            ["getenv", udid, "TZ"],
        ])

        let (unsetFake, unset) = try simctl([
            .init("getenv", stdoutFile: nil, stderrFile: Self.controlsURL("simctl-getenv-TZ.not-set.stderr.txt")),
        ])
        let none = try await unset.environmentVariable(udid: udid, name: "TZ")
        XCTAssertNil(none)
        withExtendedLifetime(unsetFake) {}
    }

    // MARK: - Backend

    private func backend(devicectl rules: [FakeTool.Rule]?, simctl simctlRules: [FakeTool.Rule] = []) throws
        -> (backend: AppleControlsBackend, simctl: FakeTool, devicectl: FakeTool?) {
        let simctlFake = try FakeTool(name: "simctl", rules: simctlRules)
        let simctl = SimctlClient(simctlURL: simctlFake.executableURL)
        var devicectlFake: FakeTool?
        var devicectl: DevicectlClient?
        if let rules {
            let fake = try FakeTool(name: "devicectl", rules: rules)
            devicectlFake = fake
            devicectl = try DevicectlClient(
                devicectlURL: fake.executableURL,
                simulator: SimulatorDevice(
                    udid: Self.udid, name: "x", state: .booted, isAvailable: true,
                    deviceTypeIdentifier: nil, runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
                )
            )
        }
        let backend = try AppleControlsBackend(udid: Self.udid, simctl: simctl, devicectl: devicectl, dataDirectory: nil)
        return (backend, simctlFake, devicectlFake)
    }

    /// At T2 appearance goes through devicectl and its answer is the read-back;
    /// the text size and contrast stay on simctl; a language writes both keys.
    func testTheBackendRoutesEachChange() async throws {
        let (backend, simctl, devicectl) = try backend(devicectl: [
            .init("--mode dark", stdoutFile: Self.devicectlURL("devicectl-device-settings-appearance-mode-dark.json")),
            .init("--reduce-motion on", stdoutFile: Self.devicectlURL("devicectl-device-settings-appearance-reduce-motion-on.json")),
            .init("voiceover --enable", stdoutFile: Self.devicectlURL("devicectl-device-settings-voiceover-enable.json")),
        ])
        let dark = try await backend.apply(.appearance(dark: true))
        guard case .appearance(let answer)? = dark else { return XCTFail("\(String(describing: dark))") }
        XCTAssertEqual(answer.userInterfaceStyle, "dark")
        let motion = try await backend.apply(.reduceMotion(true))
        XCTAssertNotNil(motion)
        let voiceOver = try await backend.apply(.voiceOver(true))
        XCTAssertEqual(voiceOver, .voiceOver(true))
        let size = try await backend.apply(.textSize(.accessibilityLarge))
        XCTAssertNil(size, "simctl answers nothing; the poll reads it back")
        try await backend.apply(.increaseContrast(true))
        try await backend.apply(.language(try XCTUnwrap(DeviceLocale(tag: "tr-TR"))))
        try await backend.apply(.timeFormat(.twentyFourHour))
        let udid = Self.udid
        XCTAssertEqual(devicectl?.invocations.map { Array($0.prefix(5)) }, [
            ["device", "settings", "appearance", "--mode", "dark"],
            ["device", "settings", "appearance", "--reduce-motion", "on"],
            ["device", "settings", "voiceover", "--enable", "--device"],
        ])
        XCTAssertEqual(simctl.invocations, [
            ["ui", udid, "content_size", "accessibility-large"],
            ["ui", udid, "increase_contrast", "enabled"],
            ["spawn", udid, "defaults", "write", "-g", "AppleLanguages", "-array", "tr-TR"],
            ["spawn", udid, "defaults", "write", "-g", "AppleLocale", "-string", "tr_TR"],
            ["spawn", udid, "defaults", "delete", "-g", "AppleICUForce12HourTime"],
            ["spawn", udid, "defaults", "write", "-g", "AppleICUForce24HourTime", "-bool", "true"],
            ["spawn", udid, "notifyutil", "-p", "AppleTimePreferencesChangedNotification"],
        ])
    }

    /// Without devicectl (T1) the appearance falls back to simctl and the
    /// devicectl-only rows refuse with the reason the panel shows.
    func testWithoutDevicectl() async throws {
        let (backend, simctl, _) = try backend(devicectl: nil)
        let answer = try await backend.apply(.appearance(dark: false))
        XCTAssertEqual(answer, .simctlAppearance(.light))
        do {
            try await backend.apply(.reduceMotion(true))
            XCTFail("expected unavailable")
        } catch let error as AppleControlsError {
            XCTAssertEqual(error, .unavailable(.reduceMotion, AppleControlsRouting.devicectlUnavailable))
        }
        XCTAssertEqual(simctl.invocations, [["ui", Self.udid, "appearance", "light"]])
        XCTAssertFalse(backend.route(.voiceOver).isOffered)
        XCTAssertTrue(backend.route(.statusBar).isOffered)
    }

    /// A devicectl client for another simulator is refused.
    func testTheBackendIsBoundToOneSimulator() throws {
        let fake = try FakeTool(name: "devicectl", rules: [])
        let other = try DevicectlClient(
            devicectlURL: fake.executableURL,
            simulator: SimulatorDevice(
                udid: "A89AEB35-14AC-4482-BA79-2DEB4D80A4B6", name: "x", state: .booted, isAvailable: true,
                deviceTypeIdentifier: nil, runtimeIdentifier: "r"
            )
        )
        let simctl = SimctlClient(simctlURL: fake.executableURL)
        XCTAssertThrowsError(try AppleControlsBackend(udid: Self.udid, simctl: simctl, devicectl: other, dataDirectory: nil))
        XCTAssertThrowsError(try AppleControlsBackend(udid: "booted", simctl: simctl, devicectl: nil, dataDirectory: nil))
    }
}
