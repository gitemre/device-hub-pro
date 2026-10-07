import ImageIO
import XCTest
@testable import DeviceHubProKit

/// A physical iPhone's Controls against the dedicated test
/// iPhone, behind three switches (they skip unless all are set):
///
///     DHP_IOS_DEVICE_LIVE=1 DHP_IPHONE_UDID=<hardware UDID> \
///     DHP_IOS_DEVICE_VERIFIER_APP=<signed DeviceHubProVerifier.app> \
///         swift test --filter ApplePhysicalControlsLiveTests
///
/// The test runs the backend the app's panel runs (`ApplePhysicalControlsBackend`
/// over `DevicectlPhysicalClient`) for every row the phone's own capability
/// list offers: it reads the current value, sets a different one, waits for
/// the verifier (already installed on the phone; installed here only when it
/// is missing, and then removed again) to report it in `Documents/readings.json`
/// (copied out with `copy from`), and puts the value back. Every change is
/// undone in the cleanup below, which runs however the steps ended:
/// VoiceOver first (it changes how the phone answers touches, and is switched
/// off again straight after its own step as well), then the appearance flags,
/// the text size, the Liquid Glass opacity and the colour filter as read at the
/// start, the simulated location (cleared), the pasteboard text as read at the
/// start (an empty pasteboard is put back as empty text: devicectl has no way
/// to remove the item) and, for the two canaries, the orientation (portrait).
///
/// Two canaries pin what was measured on the iPhone 12 / iOS 27.0 (CoreDevice
/// 642.16): `orientation set` turns the interface of the app in front when it
/// supports the pose (the canary puts the all-orientation host app in front,
/// `com.devicehubpro.agent.host`, and reads the screenshot's aspect; the pose is
/// not read back, so the Controls row stays hidden and Rotate is the surface),
/// and `process sendMemoryWarning` fails with `NSPOSIXErrorDomain` 2 for the
/// running verifier (its row is hidden; if that changes, the test fails).
///
/// The location row needs the verifier's Location permission to read the fix
/// back; until someone taps Allow on the phone (the verifier's Location row)
/// the step only checks the command's answer and says so.
///
/// The UDID is read from the environment and is never printed.
final class ApplePhysicalControlsLiveTests: XCTestCase {
    private static let bundle = IOSVerifierLiveTests.bundle

    private var timings: [(String, Duration)] = []
    private var notes: [String] = []

    func testEveryOfferedRowRoundTripsOnTheTestIPhone() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let appPath = environment["DHP_IOS_DEVICE_VERIFIER_APP"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !appPath.isEmpty
        else {
            throw XCTSkip("set DHP_IOS_DEVICE_VERIFIER_APP to a signed DeviceHubProVerifier.app (ios/verifier/build.sh --device)")
        }
        let app = URL(fileURLWithPath: appPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: app.appendingPathComponent("embedded.mobileprovision").path) else {
            throw XCTSkip("\(appPath) is not a device build (no embedded.mobileprovision)")
        }
        let client = try await ApplePhysicalLiveTests.connectedTestIPhone().client
        let capabilities = ApplePhysicalControlsCapabilities(details: try await client.details().value)
        let backend = ApplePhysicalControlsBackend(client: client, capabilities: capabilities)

        // The rows the phone's features allow, and only those.
        let offered = AppleControl.allCases.filter { backend.route($0).isOffered }
        XCTAssertEqual(offered, [
            .appearance, .liquidGlass, .textSize, .reduceMotion, .showBorders, .reduceTransparency, .voiceOver,
            .colorFilter, .increaseContrast, .location, .clipboard,
        ])

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicehubpro-physical-controls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let wasInstalled = try await client.apps().value.apps.contains { $0.bundleIdentifier == Self.bundle }
        let snapshot = try await Snapshot.take(client)
        var pid: Int?
        var failure: Error?
        var orientationTouched = false
        let verifier = PhysicalVerifier(client: client, scratch: scratch)
        do {
            if !wasInstalled { _ = try await client.installApp(at: app) }
            let started = Date()
            let launched = try await client.launchApp(bundleID: Self.bundle, terminateExisting: true).value
            pid = launched.processIdentifier
            _ = try await ApplePhysicalLiveTests.waitForReadings(
                client: client,
                bundle: Self.bundle,
                into: scratch.appendingPathComponent("first.json"),
                launchedAfter: started.addingTimeInterval(-30)
            )
            try await roundTrips(backend, verifier: verifier, snapshot: snapshot, verifierPID: launched.processIdentifier, orientationTouched: { orientationTouched = true }, scratch: scratch)
        } catch {
            failure = error
        }

        // Put everything back, whatever happened above. VoiceOver first.
        await snapshot.restore(backend, client: client, orientationTouched: orientationTouched, scratch: scratch)
        if let pid { _ = try? await client.terminate(pid: pid) }
        if !wasInstalled {
            _ = try? await client.uninstallApp(bundleID: Self.bundle)
        }
        printReport()
        if let failure { throw failure }
    }

    // MARK: - The round trips

    private func roundTrips(
        _ backend: ApplePhysicalControlsBackend,
        verifier: PhysicalVerifier,
        snapshot: Snapshot,
        verifierPID: Int,
        orientationTouched: () -> Void,
        scratch: URL
    ) async throws {
        let client = backend.client
        let original = snapshot.appearance

        // Display & sound.
        let dark = original.userInterfaceStyle != "dark"
        try await roundTrip("appearance", verifier, "display.appearance", dark ? "dark" : "light") {
            let answer = try await backend.apply(.appearance(dark: dark))
            XCTAssertNotNil(answer, "devicectl answers with the new style")
        }
        let size: SimulatorContentSize = original.contentSize == .small ? .large : .small
        try await roundTrip("text size", verifier, "display.textSize", size.rawValue) {
            try await backend.apply(.textSize(size))
        }
        let toggles: [(String, String, Bool?, (Bool) -> AppleControlChange)] = [
            ("reduce motion", "display.reduceMotion", original.reduceMotion, { .reduceMotion($0) }),
            ("reduce transparency", "display.reduceTransparency", original.reduceTransparency, { .reduceTransparency($0) }),
            ("show borders", "display.showBorders", original.showBorders, { .showBorders($0) }),
            ("increase contrast", "accessibility.increaseContrast", original.increaseContrast, { .increaseContrast($0) }),
        ]
        for (label, id, current, change) in toggles {
            let target = !(current ?? false)
            try await roundTrip("\(label) \(target ? "on" : "off")", verifier, id, target ? "on" : "off") {
                try await backend.apply(change(target))
            }
        }
        // The colour filter: apps can read only Grayscale.
        try await roundTrip("color filter grayscale", verifier, "accessibility.colorFilter", "grayscale") {
            try await backend.apply(.colorFilter(.grayscale, intensity: nil))
        }
        try await roundTrip("color filter off", verifier, "accessibility.colorFilter", "none") {
            try await backend.apply(.colorFilter(nil, intensity: nil))
        }
        // The appearance read confirms what the writes did.
        guard case .appearance(let polled) = try await backend.read(.devicectlAppearance) else {
            return XCTFail("the appearance read answered something else")
        }
        XCTAssertEqual(polled.contentSize, size)
        XCTAssertEqual(polled.userInterfaceStyle, dark ? "dark" : "light")
        XCTAssertEqual(polled.colorFilter, false)

        // Liquid Glass: apps cannot read it (a note row); devicectl reads it back.
        let opacity = (original.liquidGlassOpacity ?? 0.5) > 0.6 ? 0.3 : 0.8
        try await backend.apply(.liquidGlassOpacity(opacity))
        guard case .appearance(let glass) = try await backend.read(.devicectlAppearance) else { return XCTFail("no appearance") }
        XCTAssertEqual(glass.liquidGlassOpacity ?? -1, opacity, accuracy: 0.001)
        let glassRaw = try await verifier.raw("display.liquidGlass")
        XCTAssertEqual(glassRaw, "unreadable")

        // Location: a coordinate and a clear.
        try await location(backend, verifier)

        // Clipboard: copy through devicectl, paste it back, and see the
        // pasteboard's change count move in the verifier.
        try await clipboard(backend, verifier, snapshot: snapshot)

        // VoiceOver last, and off again at once.
        do {
            try await roundTrip("voiceover on", verifier, "accessibility.voiceOver", "on") {
                try await backend.apply(.voiceOver(true))
            }
        } catch {
            _ = try? await backend.apply(.voiceOver(snapshot.voiceOver))
            throw error
        }
        try await roundTrip("voiceover off", verifier, "accessibility.voiceOver", "off") {
            try await backend.apply(.voiceOver(false))
        }

        // Canary: `orientation set` turns the interface of the app in front when that app
        // supports the pose (the host app supports all four; the verifier is portrait-only,
        // which is why an earlier canary read "does not turn"). The pose itself is not read
        // back (`orientation get` and the set answer keep saying portrait), so the pixel
        // aspect of a devicectl screenshot is the evidence; then portrait is put back.
        orientationTouched()
        let hostBundle = "com.devicehubpro.agent.host"
        let apps = try await client.apps().value.apps
        if apps.contains(where: { $0.bundleIdentifier == hostBundle }) {
            let host = try await client.launchApp(bundleID: hostBundle, terminateExisting: true).value
            try await Task.sleep(for: .seconds(2))
            for (pose, landscape) in [(SimulatorDevicePose.landscapeLeft, true), (.landscapeRight, true), (.portrait, false)] {
                try await client.setOrientation(pose)
                try await Task.sleep(for: .seconds(1.5))
                let size = try await screenshotSize(client, scratch: scratch)
                XCTAssertEqual(size.width > size.height, landscape, "orientation set \(pose.rawValue) must turn the host app's interface (screenshot \(size))")
            }
            _ = try? await client.terminate(pid: host.processIdentifier)
        } else {
            notes.append("orientation: \(hostBundle) is not installed, so the canary only ran the command (install ios/agent's host app to pin that it rotates)")
            try await client.setOrientation(.landscapeLeft)
        }
        try await client.setOrientation(.portrait)

        // Canary: the memory warning does not reach the running app.
        let warningsBefore = try await verifier.raw("appConditions.memoryWarning")
        do {
            _ = try await client.sendMemoryWarning(pid: verifierPID)
            let warningsAfter = try await verifier.raw("appConditions.memoryWarning")
            XCTFail("sendMemoryWarning now succeeds (the verifier's count went \(warningsBefore) to \(warningsAfter)): offer the Memory warning row if the app receives it")
        } catch let error as DevicectlError {
            XCTAssertEqual(error.frames.first?.domain, "NSPOSIXErrorDomain")
            XCTAssertEqual(error.frames.first?.code, 2)
        }
    }

    private func screenshotSize(_ client: DevicectlPhysicalClient, scratch: URL) async throws -> CGSize {
        let url = scratch.appendingPathComponent("orientation-\(UUID().uuidString).png")
        _ = try await client.screenshot(to: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return CGSize(
            width: try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int),
            height: try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        )
    }

    private func location(_ backend: ApplePhysicalControlsBackend, _ verifier: PhysicalVerifier) async throws {
        let permissions = try await verifier.raw("appConditions.permissions")
        let granted = permissions.contains("location=authorized")
        let start = ContinuousClock.now
        let set = try await backend.client.setLocation(latitude: 41.0082, longitude: 28.9784).value
        XCTAssertEqual(set.latitude, 41.0082)
        XCTAssertEqual(set.longitude, 28.9784)
        if granted {
            try await verifier.wait("location.lastFix", equals: "41.00820,28.97840", label: "location")
            record("location", since: start)
        } else {
            notes.append("location: the command answered; the verifier could not read the fix (its Location permission is \(permissions.split(separator: ",").first ?? "unknown"): tap Allow on the phone once)")
        }
        let cleared = try await backend.client.clearLocation().value
        XCTAssertTrue(cleared.cleared)
    }

    private func clipboard(
        _ backend: ApplePhysicalControlsBackend,
        _ verifier: PhysicalVerifier,
        snapshot: Snapshot
    ) async throws {
        guard snapshot.pasteboard != nil else {
            notes.append("clipboard: skipped, the phone's pasteboard could not be read as text, so it could not be put back")
            return
        }
        let before = try await verifier.raw("clipboard.pasteboard")
        let text = "devicehubpro-controls-live-\(UUID().uuidString.prefix(8))"
        let start = ContinuousClock.now
        try await backend.apply(.pasteboard(text))
        let pasted = try await backend.pasteboardText()
        XCTAssertEqual(pasted, text)
        try await verifier.wait("clipboard.pasteboard", differsFrom: before, label: "clipboard")
        record("clipboard", since: start)
    }

    // MARK: - Round trip and reporting

    private func roundTrip(
        _ label: String,
        _ verifier: PhysicalVerifier,
        _ id: String,
        _ expected: String,
        change: () async throws -> some Any
    ) async throws {
        let start = ContinuousClock.now
        _ = try await change()
        try await verifier.wait(id, equals: expected, label: label)
        record(label, since: start)
    }

    private func record(_ label: String, since start: ContinuousClock.Instant) {
        timings.append((label, ContinuousClock.now - start))
    }

    private func printReport() {
        for (label, duration) in timings {
            let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            print("PHYSICAL-CONTROLS \(label): \(String(format: "%.2f", seconds)) s (command start to the verifier's reading)")
        }
        for note in notes { print("PHYSICAL-CONTROLS \(note)") }
    }
}

/// What the phone had before the test, and how to put it back.
private struct Snapshot {
    let appearance: DevicectlAppearance
    let voiceOver: Bool
    /// The pasteboard's text (empty for an empty item); nil when it could not
    /// be read as text, in which case the test leaves it alone.
    let pasteboard: String?

    static func take(_ client: DevicectlPhysicalClient) async throws -> Snapshot {
        let appearance = try await client.appearance().value
        let voiceOver = try await client.voiceover().value.enabled
        // Best effort: a phone with nothing (or nothing textual) on its pasteboard.
        let pasteboard = try? await client.pasteboardText().text
        return Snapshot(appearance: appearance, voiceOver: voiceOver, pasteboard: pasteboard)
    }

    /// Every change the test can have made, undone, VoiceOver first. Each
    /// step runs even when an earlier one failed; a failure is reported.
    func restore(
        _ backend: ApplePhysicalControlsBackend,
        client: DevicectlPhysicalClient,
        orientationTouched: Bool,
        scratch: URL
    ) async {
        func attempt(_ label: String, _ step: () async throws -> some Any) async {
            do {
                _ = try await step()
            } catch {
                XCTFail("could not restore \(label): \(error)")
            }
        }
        await attempt("VoiceOver") { try await client.setVoiceOver(voiceOver) }
        if let style = appearance.userInterfaceStyle {
            await attempt("the appearance") { try await client.setAppearance(.dark(style == "dark")) }
        }
        if let size = appearance.contentSize {
            await attempt("the text size") { try await client.setAppearance(.textSize(size)) }
        }
        let flags: [(String, Bool?, (Bool) -> DevicectlAppearanceSetting)] = [
            ("Reduce Motion", appearance.reduceMotion, { .reduceMotion($0) }),
            ("Reduce Transparency", appearance.reduceTransparency, { .reduceTransparency($0) }),
            ("Show Borders", appearance.showBorders, { .showBorders($0) }),
            ("Increase Contrast", appearance.increaseContrast, { .increaseContrast($0) }),
        ]
        for (label, value, setting) in flags {
            if let value { await attempt(label) { try await client.setAppearance(setting(value)) } }
        }
        if let opacity = appearance.liquidGlassOpacity {
            await attempt("Liquid Glass") { try await client.setAppearance(.liquidGlassOpacity(opacity)) }
        }
        if let filter = appearance.colorFilterSelection {
            await attempt("the color filter") {
                try await client.setAppearance(.colorFilterType(filter, intensity: appearance.colorFilterIntensity))
            }
        } else if appearance.colorFilter == false {
            await attempt("the color filter") { try await client.setAppearance(.colorFilter(false)) }
        }
        if orientationTouched {
            await attempt("the orientation") { try await client.setOrientation(.portrait) }
        }
        await attempt("the location") { try await client.clearLocation() }
        if let text = pasteboard {
            if text.isEmpty {
                // devicectl cannot remove the pasteboard's item: empty text it is.
                let empty = scratch.appendingPathComponent("empty.txt")
                await attempt("the pasteboard") {
                    try Data().write(to: empty)
                    return try await client.run(
                        DevicectlPhysicalControl.pasteboardCopy.words + ["--file", empty.path],
                        as: DevicectlPasteboardCopy.self
                    )
                }
            } else {
                await attempt("the pasteboard") { try await client.copyToPasteboard(text) }
            }
        }
        // Read it all back: the phone is as it was found.
        if let after = try? await client.appearance().value {
            XCTAssertEqual(after.userInterfaceStyle, appearance.userInterfaceStyle, "appearance restored")
            XCTAssertEqual(after.contentSize, appearance.contentSize, "text size restored")
            XCTAssertEqual(after.reduceMotion, appearance.reduceMotion, "Reduce Motion restored")
            XCTAssertEqual(after.reduceTransparency, appearance.reduceTransparency, "Reduce Transparency restored")
            XCTAssertEqual(after.showBorders, appearance.showBorders, "Show Borders restored")
            XCTAssertEqual(after.increaseContrast, appearance.increaseContrast, "Increase Contrast restored")
            XCTAssertEqual(after.colorFilter, appearance.colorFilter, "color filter restored")
            XCTAssertEqual(after.liquidGlassOpacity ?? -1, appearance.liquidGlassOpacity ?? -1, accuracy: 0.001, "Liquid Glass restored")
        } else {
            XCTFail("could not read the appearance back after restoring it")
        }
        if let after = try? await client.voiceover().value {
            XCTAssertEqual(after.enabled, voiceOver, "VoiceOver restored")
        } else {
            XCTFail("could not read VoiceOver back after restoring it")
        }
        if let text = pasteboard, let after = try? await client.pasteboardText().text {
            XCTAssertEqual(after, text, "the pasteboard text restored")
        }
    }
}

/// Copies the verifier's `Documents/readings.json` off the phone until a row
/// reads what a test waits for.
private final class PhysicalVerifier: Sendable {
    /// A live row reads back within this long of its command (each wait
    /// includes copies of about a second each).
    static let bound: Duration = .seconds(20)

    let client: DevicectlPhysicalClient
    let scratch: URL

    init(client: DevicectlPhysicalClient, scratch: URL) {
        self.client = client
        self.scratch = scratch
    }

    private func document() async throws -> VerifierReader.Document {
        let file = scratch.appendingPathComponent("readings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await client.copyFrom(
            domain: .appDataContainer(bundleID: IOSVerifierLiveTests.bundle),
            source: "Documents/readings.json",
            to: file
        )
        return try JSONDecoder().decode(VerifierReader.Document.self, from: try Data(contentsOf: file))
    }

    func raw(_ id: String) async throws -> String {
        guard let raw = try await document().rows[id]?.raw else { throw VerifierReader.Failure.noDocument }
        return raw
    }

    func wait(_ id: String, equals expected: String, label: String) async throws {
        try await wait(id, label: label, expected: expected) { $0 == expected }
    }

    func wait(_ id: String, differsFrom old: String, label: String) async throws {
        try await wait(id, label: label, expected: "a value other than \(old)") { $0 != old }
    }

    private func wait(_ id: String, label: String, expected: String, where matches: (String) -> Bool) async throws {
        let deadline = ContinuousClock.now + Self.bound
        var last: String?
        var refronted = false
        let started = ContinuousClock.now
        while ContinuousClock.now < deadline {
            if let raw = try? await document().rows[id]?.raw {
                last = raw
                if matches(raw) { return }
            }
            // A phone that dimmed and locked suspends the verifier: bring it
            // to the front once (launching a running app only fronts it).
            if !refronted, ContinuousClock.now - started > .seconds(8) {
                refronted = true
                _ = try? await client.launchApp(bundleID: IOSVerifierLiveTests.bundle, terminateExisting: false)
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw VerifierReader.Failure.timedOut(label: label, id: id, expected: expected, last: last)
    }
}
