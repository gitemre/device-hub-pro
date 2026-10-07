import XCTest
@testable import DeviceHubProKit

/// The iOS verifier (`ios/verifier`) against a real simulator, behind
/// `DHP_IOS_LIVE=1`: Device Hub Pro's mechanisms write, the verifier reads
/// what an app sees and writes `Documents/readings.json`, and the test reads
/// that back through `simctl get_app_container`.
///
///     DHP_IOS_LIVE=1 swift test --filter IOSVerifierLiveTests
///
/// The verifier is built with `ios/verifier/build.sh` unless
/// `DHP_IOS_VERIFIER_APP` names a built `DeviceHubProVerifier.app`. With
/// `DHP_IOS_VERIFIER_READINGS_DIR` set, a failing test leaves the last
/// readings.json and a screenshot there (CI uploads them).
///
/// `testSimctlRoundTripsOnAPrivateSetSimulator` creates its own iPhone in a
/// private device set (`LiveTestSimulators`) and deletes it afterwards.
/// `testDevicectlRoundTripsOnAPinnedSimulator` needs a booted default-set
/// simulator named in `DHP_SIM_UDID` (CoreDevice does not see private
/// sets); it installs the verifier there, puts back every setting it
/// changes (read before the first change, put back whether the round
/// trips pass or fail: the appearance flags, the colour filter's type,
/// intensity and state, the text size, VoiceOver, the volume and the
/// enrolment) and uninstalls the verifier.
final class IOSVerifierLiveTests: XCTestCase {
    static let bundle = "com.devicehubpro.verifier"

    /// A change must reach the verifier within this bound; the times are
    /// printed (`IOS-VERIFIER`) and the design's goal is 3 s.
    static let roundTripBound: Duration = .seconds(10)

    private var timings: [(String, Duration)] = []

    // MARK: simctl, private set

    func testSimctlRoundTripsOnAPrivateSetSimulator() async throws {
        let toolchain = try await LiveTestSimulators.toolchain()
        let app = try await iosVerifierApp(toolchain: toolchain)
        let session = try LiveTestSimulators.Session(toolchain: toolchain)
        var verifier: VerifierReader?
        do {
            let device = try await session.createDevice(name: "DeviceHubPro-Live-Verifier")
            print("IOS-VERIFIER created \(device.udid) in \(session.setDirectory.path)")
            let reader = VerifierReader(simctl: session.simctl, udid: device.udid)
            verifier = reader
            try await simctlRoundTrips(
                simctl: session.simctl, udid: device.udid, app: app, verifier: reader,
                dataDirectory: device.dataPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            )
        } catch {
            await verifier?.keepEvidence(name: "simctl")
            let leftovers = await session.tearDown()
            XCTAssertEqual(leftovers, [])
            throw error
        }
        let leftovers = await session.tearDown()
        XCTAssertEqual(leftovers, [])
        printTimings()
    }

    private func simctlRoundTrips(
        simctl: SimctlClient, udid: String, app: URL, verifier: VerifierReader, dataDirectory: URL?
    ) async throws {
        try await simctl.bootStatus(udid: udid, bootIfNeeded: true)
        // "Booted" comes before SpringBoard settles.
        try await Task.sleep(for: .seconds(10))
        try await simctl.install(udid: udid, app: app)
        try await simctl.checked(["privacy", udid, "grant", "location", Self.bundle])
        try await simctl.launch(udid: udid, bundleIdentifier: Self.bundle, terminateRunning: true)
        let first = try await verifier.waitForDocument(timeout: .seconds(60))
        XCTAssertEqual(first.schema, 1)
        print("IOS-VERIFIER first readings: \(first.rows.count) rows, system \(first.system)")

        // Display & sound, Accessibility: simctl ui.
        try await roundTrip("appearance dark", verifier, "display.appearance", "dark") {
            try await simctl.setAppearance(udid: udid, .dark)
        }
        try await roundTrip("appearance light", verifier, "display.appearance", "light") {
            try await simctl.setAppearance(udid: udid, .light)
        }
        try await roundTrip("content size xxl", verifier, "display.textSize", "extra-extra-large") {
            try await simctl.setContentSize(udid: udid, .extraExtraLarge)
        }
        try await roundTrip("content size large", verifier, "display.textSize", "large") {
            try await simctl.setContentSize(udid: udid, .large)
        }
        try await roundTrip("increase contrast on", verifier, "accessibility.increaseContrast", "on") {
            try await simctl.setIncreaseContrast(udid: udid, enabled: true)
        }
        try await roundTrip("increase contrast off", verifier, "accessibility.increaseContrast", "off") {
            try await simctl.setIncreaseContrast(udid: udid, enabled: false)
        }

        // Location.
        try await roundTrip("location set", verifier, "location.lastFix", "37.33000,-122.03000") {
            try await simctl.setLocation(udid: udid, latitude: 37.33, longitude: -122.03)
        }

        // Slow Animations (Device menu): the notification's state plus a post.
        // The verifier times a 0.1 s animation every 2 s.
        try await roundTrip("slow animations on", verifier, "display.slowAnimations", "on") {
            try await simctl.setSlowAnimations(udid: udid, enabled: true)
        }
        let slowState = try await simctl.slowAnimationsEnabled(udid: udid)
        XCTAssertTrue(slowState, "the state reads back")
        try await roundTrip("slow animations off", verifier, "display.slowAnimations", "off") {
            try await simctl.setSlowAnimations(udid: udid, enabled: false)
        }
        let slowStateAfter = try await simctl.slowAnimationsEnabled(udid: udid)
        XCTAssertFalse(slowStateAfter)

        // Simulate Memory Warning (Device menu): the device's file's mtime.
        let dataDirectory = try XCTUnwrap(dataDirectory, "the listing carries the device's data path")
        let warningsBefore = try await verifier.raw("appConditions.memoryWarning")
        let countBefore = Int(warningsBefore) ?? 0
        try await roundTrip("memory warning", verifier, "appConditions.memoryWarning", where: { (Int($0) ?? 0) > countBefore }) {
            try SimulatorDebugActions.simulateMemoryWarning(dataDirectory: dataDirectory)
        }

        // Rows the iOS Controls still have to map (Registry.awaitingControlsRow).
        // simctl openurl is not here: iOS asks "Open in “AQA Verifier”?"
        // before a custom-scheme link reaches the app, so it needs a tap.
        let pasteboardBefore = try await verifier.raw("clipboard.pasteboard")
        try await roundTrip("pbcopy", verifier, "clipboard.pasteboard", where: { $0 != pasteboardBefore }) {
            try await simctl.setPasteboard(udid: udid, text: "Device Hub Pro verifier \(UUID().uuidString)")
        }
        // simctl push answers UNErrorDomain 2003 ("Source is not authorized",
        // exit 211) for an app that never asked for notifications, yet the
        // app in front still receives it.
        let payload = FileManager.default.temporaryDirectory.appendingPathComponent("devicehubpro-verifier-push-\(UUID().uuidString).json")
        try Data(#"{"aps":{"alert":{"title":"Device Hub Pro","body":"Verifier push check"}}}"#.utf8).write(to: payload)
        defer { try? FileManager.default.removeItem(at: payload) }
        var pushExit: Int32 = 0
        try await roundTrip("push", verifier, "appConditions.push", "Device Hub Pro — Verifier push check") {
            pushExit = try await simctl.run(["push", udid, Self.bundle, payload.path]).exitCode
        }
        print("IOS-VERIFIER simctl push exit \(pushExit)")
        // simctl privacy ends the app for photos; the new status shows once it opens again.
        try await roundTrip("privacy grant photos + relaunch", verifier, "appConditions.permissions", where: { $0.contains("photos=authorized") }) {
            try await simctl.checked(["privacy", udid, "grant", "photos", Self.bundle])
            try await simctl.launch(udid: udid, bundleIdentifier: Self.bundle, terminateRunning: true)
        }

        // Status bar: the override is drawn only; apps keep reading -1 (Note rows).
        try await simctl.checked(["status_bar", udid, "override", "--batteryLevel", "42", "--batteryState", "charging"])
        let overrides = try await simctl.statusBarOverrides(udid: udid)
        print("IOS-VERIFIER status bar overrides: \(overrides)")
        try await Task.sleep(for: .seconds(3))
        let afterOverride = try await verifier.document()
        XCTAssertEqual(afterOverride?.rows["statusBar.batteryLevel"]?.raw, "-1")
        XCTAssertEqual(afterOverride?.rows["statusBar.batteryState"]?.raw, "unknown")
        try await simctl.clearStatusBar(udid: udid)

        // 24-hour time: the preference plus the notification that makes
        // processes reread it. The inherited region decides the start.
        let hourFormat = try await verifier.raw("languageTime.timeFormat24")
        let (key, expected) = hourFormat == "24" ? ("AppleICUForce12HourTime", "12") : ("AppleICUForce24HourTime", "24")
        try await roundTrip("\(key) + notify", verifier, "languageTime.timeFormat24", expected) {
            try await simctl.checked(["spawn", udid, "defaults", "write", "-g", key, "-bool", "true"])
            try await simctl.postDarwinNotification(udid: udid, name: "AppleTimePreferencesChangedNotification")
        }

        // Language: an app sees a new language when it relaunches.
        try await roundTrip("language ar-EG + relaunch", verifier, "languageTime.language", "ar-EG") {
            try await simctl.checked(["spawn", udid, "defaults", "write", "-g", "AppleLanguages", "-array", "ar-EG"])
            try await simctl.launch(udid: udid, bundleIdentifier: Self.bundle, terminateRunning: true)
        }

        // Time zone: taken at boot (SIMCTL_CHILD_TZ). Last, as it reboots.
        let zone = try await verifier.raw("languageTime.timeZone") == "Asia/Tokyo" ? "America/New_York" : "Asia/Tokyo"
        try await roundTrip("time zone \(zone) at boot", verifier, "languageTime.timeZone", zone, bound: .seconds(180)) {
            try await simctl.shutdown(udid: udid)
            try await simctl.boot(udid: udid, timeZone: zone)
            try await simctl.bootStatus(udid: udid)
            try await Task.sleep(for: .seconds(5))
            try await simctl.launch(udid: udid, bundleIdentifier: Self.bundle, terminateRunning: true)
        }
    }

    // MARK: devicectl, pinned default-set simulator

    func testDevicectlRoundTripsOnAPinnedSimulator() async throws {
        let toolchain = try await LiveTestSimulators.toolchain()
        let device = try await LiveTestSimulators.pinnedDefaultSetSimulator(toolchain: toolchain)
        guard device.isBooted else { throw XCTSkip("DHP_SIM_UDID \(device.udid) is not booted") }
        let devicectl = try XCTUnwrap(try toolchain.makeDevicectlClient(for: device), "devicectl is not usable")
        let simctl = try XCTUnwrap(toolchain.makeSimctlClient())
        let app = try await iosVerifierApp(toolchain: toolchain)
        let udid = device.udid
        let verifier = VerifierReader(simctl: simctl, udid: udid)
        let before = try await DevicectlBefore.take(devicectl)
        let hadVerifier = (try? await simctl.appInfo(udid: udid, bundleIdentifier: Self.bundle)) != nil
        do {
            try await simctl.install(udid: udid, app: app)
            try await simctl.checked(["privacy", udid, "grant", "location", Self.bundle])
            try await simctl.launch(udid: udid, bundleIdentifier: Self.bundle, terminateRunning: true)
            _ = try await verifier.waitForDocument(timeout: .seconds(60))
            try await devicectlRoundTrips(devicectl: devicectl, verifier: verifier)
        } catch {
            await verifier.keepEvidence(name: "devicectl")
            await restore(devicectl: devicectl, to: before)
            if !hadVerifier { try? await simctl.uninstall(udid: udid, bundleIdentifier: Self.bundle) }
            throw error
        }
        await restore(devicectl: devicectl, to: before)
        if !hadVerifier { try await simctl.uninstall(udid: udid, bundleIdentifier: Self.bundle) }
        printTimings()
    }

    private func devicectlRoundTrips(devicectl: DevicectlClient, verifier: VerifierReader) async throws {
        let toggles: [(String, String, DevicectlAppearanceSetting, DevicectlAppearanceSetting)] = [
            ("reduce motion", "display.reduceMotion", .reduceMotion(true), .reduceMotion(false)),
            ("reduce transparency", "display.reduceTransparency", .reduceTransparency(true), .reduceTransparency(false)),
            ("show borders", "display.showBorders", .showBorders(true), .showBorders(false)),
            ("increase contrast", "accessibility.increaseContrast", .increaseContrast(true), .increaseContrast(false)),
        ]
        for (label, id, setting, off) in toggles {
            try await roundTrip("devicectl \(label) on", verifier, id, "on") {
                try await devicectl.setAppearance(setting)
            }
            try await roundTrip("devicectl \(label) off", verifier, id, "off") {
                try await devicectl.setAppearance(off)
            }
        }
        try await roundTrip("devicectl dark", verifier, "display.appearance", "dark") {
            try await devicectl.setAppearance(.dark(true))
        }
        try await roundTrip("devicectl text size xl", verifier, "display.textSize", "extra-large") {
            try await devicectl.setAppearance(.textSize(.extraLarge))
        }
        try await roundTrip("devicectl grayscale", verifier, "accessibility.colorFilter", "grayscale") {
            _ = try await devicectl.run(
                ["device", "settings", "appearance", "--color-filter", "on", "--color-filter-type", "grayscale"],
                as: DevicectlAppearance.self
            )
        }
        try await roundTrip("devicectl color filter off", verifier, "accessibility.colorFilter", "none") {
            try await devicectl.setAppearance(.colorFilter(false))
        }
        try await roundTrip("devicectl voiceover on", verifier, "accessibility.voiceOver", "on") {
            _ = try await devicectl.run(["device", "settings", "voiceover", "--enable"], as: DevicectlIgnoredResult.self)
        }
        try await roundTrip("devicectl voiceover off", verifier, "accessibility.voiceOver", "off") {
            _ = try await devicectl.run(["device", "settings", "voiceover", "--disable"], as: DevicectlIgnoredResult.self)
        }
        // Enrolment: the row reads LAContext's answer. Put back what was there.
        let biometrics = try await verifier.raw("advanced.biometrics")
        if let type = biometrics.split(separator: ":").first, type != "none" {
            let enrolled = biometrics.hasSuffix(":enrolled")
            let flipped = "\(type):\(enrolled ? "notEnrolled" : "enrolled")"
            try await roundTrip("devicectl biometrics flipped", verifier, "advanced.biometrics", flipped) {
                _ = try await devicectl.run(
                    ["device", "settings", "biometrics", enrolled ? "--disable" : "--enable"],
                    as: DevicectlIgnoredResult.self
                )
            }
            try await roundTrip("devicectl biometrics back", verifier, "advanced.biometrics", biometrics) {
                _ = try await devicectl.run(
                    ["device", "settings", "biometrics", enrolled ? "--enable" : "--disable"],
                    as: DevicectlIgnoredResult.self
                )
            }
        }
        // Volume: put the old level back afterwards.
        let volume = try await verifier.raw("display.sound")
        let target = volume == "30" ? "70" : "30"
        try await roundTrip("devicectl volume \(target)", verifier, "display.sound", target) {
            _ = try await devicectl.run(["device", "settings", "audio", "--volume", target], as: DevicectlIgnoredResult.self)
        }
        try await roundTrip("devicectl volume back", verifier, "display.sound", volume) {
            _ = try await devicectl.run(["device", "settings", "audio", "--volume", volume], as: DevicectlIgnoredResult.self)
        }
        // Not here: devicectl process sendMemoryWarning answers success on a
        // simulator, but the app receives no memory warning (CoreDevice 642.16).
    }

    /// What the round trips change, read before the first one.
    private struct DevicectlBefore: Sendable {
        let appearance: DevicectlAppearance
        let voiceOver: Bool
        let volume: Int?
        let biometricsEnrolled: Bool?

        static func take(_ devicectl: DevicectlClient) async throws -> DevicectlBefore {
            DevicectlBefore(
                appearance: try await devicectl.appearance().value,
                voiceOver: try await devicectl.voiceOver().value.enabled,
                volume: try await devicectl.audio().value.volume,
                // A device type without biometrics answers no enrolment.
                biometricsEnrolled: try? await devicectl.biometrics().value.isEnrolled
            )
        }
    }

    /// Puts every field this test may change back to `before`, one flag per
    /// call (CoreDevice applies a call all or nothing). Runs after the
    /// round trips whether they passed or not, so a failure halfway leaves
    /// nothing changed (VoiceOver, volume and enrolment go back only through
    /// their "off"/"back" steps otherwise).
    private func restore(devicectl: DevicectlClient, to before: DevicectlBefore) async {
        let appearance = before.appearance
        var settings: [DevicectlAppearanceSetting] = []
        if let style = appearance.userInterfaceStyle { settings.append(.dark(style == "dark")) }
        if let on = appearance.reduceMotion { settings.append(.reduceMotion(on)) }
        if let on = appearance.reduceTransparency { settings.append(.reduceTransparency(on)) }
        if let on = appearance.showBorders { settings.append(.showBorders(on)) }
        if let on = appearance.increaseContrast { settings.append(.increaseContrast(on)) }
        if let size = appearance.textSize.flatMap(SimulatorContentSize.init(devicectlName:)) {
            settings.append(.textSize(size))
        }
        for setting in settings {
            do {
                try await devicectl.setAppearance(setting)
            } catch {
                XCTFail("could not restore \(setting): \(error)")
            }
        }
        await restoreColorFilter(devicectl, to: appearance)
        do {
            try await devicectl.setVoiceOver(before.voiceOver)
            if let volume = before.volume { try await devicectl.setVolume(volume) }
            if let enrolled = before.biometricsEnrolled { try await devicectl.setBiometricsEnrolled(enrolled) }
        } catch {
            XCTFail("could not restore VoiceOver, the volume or the enrolment: \(error)")
        }
    }

    // MARK: Helpers

    private func roundTrip(
        _ label: String,
        _ verifier: VerifierReader,
        _ id: String,
        _ raw: String,
        bound: Duration = IOSVerifierLiveTests.roundTripBound,
        change: () async throws -> Void
    ) async throws {
        try await roundTrip(label, verifier, id, where: { $0 == raw }, bound: bound, expected: raw, change: change)
    }

    private func roundTrip(
        _ label: String,
        _ verifier: VerifierReader,
        _ id: String,
        where matches: @escaping @Sendable (String) -> Bool,
        bound: Duration = IOSVerifierLiveTests.roundTripBound,
        expected: String = "a new value",
        change: () async throws -> Void
    ) async throws {
        let clock = ContinuousClock()
        let started = clock.now
        try await change()
        let issued = clock.now - started
        let last = try await verifier.wait(for: id, bound: bound, matches)
        let total = clock.now - started
        guard let last, matches(last) else {
            throw VerifierReader.Failure.timedOut(label: label, id: id, expected: expected, last: last)
        }
        timings.append((label, total))
        print("IOS-VERIFIER \(label): \(id) = \(last) after \(Self.seconds(total)) (command \(Self.seconds(issued)))")
    }

    private func printTimings() {
        let lines = timings.map { "  \($0.0): \(Self.seconds($0.1))" }
        print("IOS-VERIFIER round trips (command start → reading):\n" + lines.joined(separator: "\n"))
    }

    private static func seconds(_ duration: Duration) -> String {
        String(format: "%.2f s", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

extension XCTestCase {
    /// `DHP_IOS_VERIFIER_APP`, or a fresh build from ios/verifier/build.sh
    /// in a temporary folder the test removes afterwards.
    func iosVerifierApp(toolchain: AppleToolchain) async throws -> URL {
        if let path = ProcessInfo.processInfo.environment["DHP_IOS_VERIFIER_APP"], !path.isEmpty {
            let app = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: app.appendingPathComponent("DeviceHubProVerifier").path) else {
                throw XCTSkip("DHP_IOS_VERIFIER_APP \(path) holds no built verifier")
            }
            return app
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicehubpro-ios-verifier-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            // Best effort: a leftover build folder is only disk space.
            try? FileManager.default.removeItem(at: out)
        }
        var environment: [String: String] = [:]
        if let developer = toolchain.developerDirectory {
            environment["DEVELOPER_DIR"] = developer.path
        }
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [IOSVerifierLiveTests.repositoryRoot.appendingPathComponent("ios/verifier/build.sh").path, "--out", out.path],
            environment: environment,
            timeout: .seconds(600)
        )
        guard result.exitCode == 0 else {
            throw VerifierReader.Failure.buildFailed(result.standardErrorText + result.standardOutputText)
        }
        return out.appendingPathComponent("DeviceHubProVerifier.app", isDirectory: true)
    }
}

/// Puts the colour filter back as `before` read it: its type and intensity
/// (`--color-filter-type` alone turns the filter on, measured), then off
/// again if it was off. `--color-filter on` alone would bring back the last
/// filter used, which the round trips changed.
func restoreColorFilter(_ devicectl: DevicectlClient, to before: DevicectlAppearance) async {
    do {
        if let name = before.colorFilterType, let type = SimulatorColorFilterType(devicectlName: name) {
            try await devicectl.setAppearance(.colorFilterType(type, intensity: type.hasIntensity ? before.colorFilterIntensity : nil))
        }
        if before.colorFilter != true {
            try await devicectl.setAppearance(.colorFilter(false))
        }
    } catch {
        XCTFail("could not restore the colour filter: \(error)")
    }
}

/// A `devicectl` result whose body the test does not read.
struct DevicectlIgnoredResult: Decodable, Sendable {}

/// Reads the verifier's `Documents/readings.json` from the host.
final class VerifierReader: Sendable {
    struct Document: Decodable, Sendable {
        struct Row: Decodable, Sendable {
            let value: String
            let raw: String
            let changes: Int
        }

        let schema: Int
        let system: String
        let writtenAt: String
        let rows: [String: Row]
    }

    enum Failure: Error, CustomStringConvertible {
        case timedOut(label: String, id: String, expected: String, last: String?)
        case noDocument
        case buildFailed(String)

        var description: String {
            switch self {
            case .timedOut(let label, let id, let expected, let last):
                return "\(label): \(id) never read \(expected) (last \(last ?? "nothing"))"
            case .noDocument:
                return "the verifier wrote no readings.json"
            case .buildFailed(let output):
                return "ios/verifier/build.sh failed: \(output)"
            }
        }
    }

    let simctl: SimctlClient
    let udid: String

    init(simctl: SimctlClient, udid: String) {
        self.simctl = simctl
        self.udid = udid
    }

    func fileURL() async throws -> URL {
        let container = try await simctl.appContainerPath(
            udid: udid,
            bundleIdentifier: IOSVerifierLiveTests.bundle,
            container: .data
        )
        return URL(fileURLWithPath: container).appendingPathComponent("Documents/readings.json")
    }

    /// The current document, or nil while there is none (or it is mid-write).
    func document() async throws -> Document? {
        guard let data = try? Data(contentsOf: try await fileURL()) else { return nil }
        return try? JSONDecoder().decode(Document.self, from: data)
    }

    func raw(_ id: String) async throws -> String {
        guard let raw = try await document()?.rows[id]?.raw else {
            throw Failure.noDocument
        }
        return raw
    }

    func waitForDocument(timeout: Duration) async throws -> Document {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let document = try await document(), !document.rows.isEmpty {
                return document
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw Failure.noDocument
    }

    /// Polls until the row's token matches or the bound passes; returns the
    /// last token seen.
    func wait(for id: String, bound: Duration, _ matches: (String) -> Bool) async throws -> String? {
        let deadline = ContinuousClock.now + bound
        var last: String?
        while ContinuousClock.now < deadline {
            last = try await document()?.rows[id]?.raw ?? last
            if let last, matches(last) { return last }
            try await Task.sleep(for: .milliseconds(100))
        }
        return last
    }

    /// Copies the last readings and a screenshot to
    /// `DHP_IOS_VERIFIER_READINGS_DIR` (and prints the readings).
    func keepEvidence(name: String) async {
        let url = try? await fileURL()
        let data = url.flatMap { try? Data(contentsOf: $0) }
        print("IOS-VERIFIER last readings.json:\n" + (data.map { String(decoding: $0, as: UTF8.self) } ?? "none"))
        guard let directory = ProcessInfo.processInfo.environment["DHP_IOS_VERIFIER_READINGS_DIR"],
              !directory.isEmpty else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        // Best effort: the evidence must not hide the test's own failure.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data?.write(to: folder.appendingPathComponent("\(name)-readings.json"))
        try? await simctl.screenshot(udid: udid, to: folder.appendingPathComponent("\(name)-screen.png"), timeout: .seconds(20))
    }
}
