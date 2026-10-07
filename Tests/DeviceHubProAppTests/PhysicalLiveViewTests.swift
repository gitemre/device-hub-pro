import CoreVideo
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// A fake capture provider for the app's physical view: it records how it
/// was asked and never reaches CoreMediaIO, a capture device or the Camera
/// permission.
final class TestCaptureProvider: PhysicalScreenCaptureProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _allowCalls = 0
    private var _requestCalls = 0
    private var _deviceQueries = 0
    private var _makeCalls: [String] = []
    private var _authorization: CaptureAuthorization
    private var _devices: [PhysicalCaptureDevice]
    private var _handlers: [@Sendable () -> Void] = []
    private var _captures: [TestCapture] = []
    private let grants: Bool
    private var _audioAuthorization: CaptureAuthorization
    private var _audioRequestCalls = 0
    private let audioGrants: Bool

    init(
        authorization: CaptureAuthorization = .authorized,
        devices: [PhysicalCaptureDevice] = [],
        grants: Bool = true,
        audioAuthorization: CaptureAuthorization = .authorized,
        audioGrants: Bool = true
    ) {
        _authorization = authorization
        _devices = devices
        self.grants = grants
        _audioAuthorization = audioAuthorization
        self.audioGrants = audioGrants
    }

    var allowCalls: Int { lock.withLock { _allowCalls } }
    var requestCalls: Int { lock.withLock { _requestCalls } }
    var deviceQueries: Int { lock.withLock { _deviceQueries } }
    var makeCalls: [String] { lock.withLock { _makeCalls } }
    var captures: [TestCapture] { lock.withLock { _captures } }
    func setAuthorization(_ value: CaptureAuthorization) { lock.withLock { _authorization = value } }
    func setDevices(_ value: [PhysicalCaptureDevice]) { lock.withLock { _devices = value } }
    func announceDeviceChange() {
        let handlers = lock.withLock { _handlers }
        handlers.forEach { $0() }
    }

    func allowScreenCaptureDevices() { lock.withLock { _allowCalls += 1 } }
    func captureDevices() -> [PhysicalCaptureDevice] {
        lock.withLock {
            _deviceQueries += 1
            return _devices
        }
    }
    var authorization: CaptureAuthorization { lock.withLock { _authorization } }
    var audioAuthorization: CaptureAuthorization { lock.withLock { _audioAuthorization } }
    var audioRequestCalls: Int { lock.withLock { _audioRequestCalls } }
    func setAudioAuthorization(_ value: CaptureAuthorization) { lock.withLock { _audioAuthorization = value } }
    func requestAudioAccess() async -> Bool {
        lock.withLock {
            _audioRequestCalls += 1
            _audioAuthorization = audioGrants ? .authorized : .denied
            return audioGrants
        }
    }
    func requestAccess() async -> Bool {
        lock.withLock {
            _requestCalls += 1
            _authorization = grants ? .authorized : .denied
            return grants
        }
    }
    func makeCapture(
        uniqueID: String,
        onFrame: @escaping @Sendable (CVPixelBuffer) -> Void,
        onAudio: (@Sendable (PhysicalAudioChunk) -> Void)?,
        onDrop: @escaping @Sendable () -> Void,
        onEnd: @escaping @Sendable (PhysicalCaptureEnd) -> Void
    ) throws -> any PhysicalCaptureRunning {
        lock.withLock {
            _makeCalls.append(uniqueID)
            let capture = TestCapture(onEnd: onEnd, onAudio: onAudio)
            _captures.append(capture)
            return capture
        }
    }
    func observeDeviceChanges(_ handler: @escaping @Sendable () -> Void) -> AnyObject {
        lock.withLock { _handlers.append(handler) }
        return NSObject()
    }
}

final class TestCapture: PhysicalCaptureRunning, @unchecked Sendable {
    let onEnd: @Sendable (PhysicalCaptureEnd) -> Void
    /// The audio callback the capture was asked for; nil when no audio
    /// output would have been added.
    let onAudio: (@Sendable (PhysicalAudioChunk) -> Void)?
    private let lock = NSLock()
    private var _started = 0
    private var _stopped = 0
    init(onEnd: @escaping @Sendable (PhysicalCaptureEnd) -> Void, onAudio: (@Sendable (PhysicalAudioChunk) -> Void)? = nil) {
        self.onEnd = onEnd
        self.onAudio = onAudio
    }
    var started: Int { lock.withLock { _started } }
    var stopped: Int { lock.withLock { _stopped } }
    func start() { lock.withLock { _started += 1 } }
    func stop() { lock.withLock { _stopped += 1 } }
}

/// A sink that records what it was told: the app's tests never build the
/// real player (`PhysicalAudioPlayer`) for a session that plays.
final class TestAudioSink: PhysicalAudioSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _played = 0
    private var _stops = 0
    private var _playing: [Bool] = []
    var playedCount: Int { lock.withLock { _played } }
    var stopCount: Int { lock.withLock { _stops } }
    /// Every `setPlaying` the sink got, oldest first.
    var playingCalls: [Bool] { lock.withLock { _playing } }
    var isPlaying: Bool { lock.withLock { _playing.last ?? false } }
    func play(_ chunk: PhysicalAudioChunk) { lock.withLock { _played += 1 } }
    func setPlaying(_ playing: Bool) { lock.withLock { _playing.append(playing) } }
    func stop() { lock.withLock { _stops += 1 } }
}

/// Waits for `condition` (the physical suites' poll) and fails the test when
/// it never holds.
@MainActor
func expectEventually(
    _ condition: @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let held = await physicalWait { condition() }
    XCTAssertTrue(held, file: file, line: line)
}

final class PreviewCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// The capture device the fake provider exposes for the test iPhone: named by
/// the phone's hardware UDID, the form macOS gives it.
private func captureDevice(for entry: ApplePhysicalEntry, uniqueID: String? = nil, hasAudio: Bool = false) -> PhysicalCaptureDevice {
    PhysicalCaptureDevice(
        uniqueID: uniqueID ?? entry.device.hardwareUDID,
        localizedName: entry.name,
        modelID: "iOS Device",
        hasAudio: hasAudio
    )
}

// MARK: - Matching

/// Which capture device belongs to the enabled, listed phone: the UDID in
/// the forms it can take first; the name and model only when no capture
/// device carries the UDID, and only for one unambiguous pair; and never a
/// capture device that maps to no listed phone.
final class PhysicalCaptureMatchingTests: XCTestCase {
    private func phone(edit: ((inout [String: Any]) -> Void)? = nil) throws -> ApplePhysicalDevice {
        try PhysicalFixtures.device(edit: edit)
    }

    /// A second physical phone in the list: the fixture's phone with another
    /// hardware UDID (both places the lister reads it from), listed under the
    /// app's "every physical device" opt-in.
    private func otherPhone(udid: String, name: String? = nil) throws -> ApplePhysicalDevice {
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: try PhysicalFixtures.data("devicectl-list-devices.json")) as? [String: Any])
        var result = try XCTUnwrap(document["result"] as? [String: Any])
        var entries = try XCTUnwrap(result["devices"] as? [[String: Any]])
        let index = try XCTUnwrap(entries.firstIndex {
            ($0["hardwareProperties"] as? [String: Any])?["reality"] as? String == "physical"
        })
        var entry = entries[index]
        var legacy = entry["hardwareProperties"] as? [String: Any] ?? [:]
        legacy["udid"] = udid
        entry["hardwareProperties"] = legacy
        var properties = entry["properties"] as? [String: Any] ?? [:]
        var hardware = properties["hardware"] as? [String: Any] ?? [:]
        hardware["udid"] = udid
        properties["hardware"] = hardware
        if let name {
            var state = properties["state"] as? [String: Any] ?? [:]
            state["name"] = name
            properties["state"] = state
            var device = entry["deviceProperties"] as? [String: Any] ?? [:]
            device["name"] = name
            entry["deviceProperties"] = device
        }
        entry["properties"] = properties
        entries[index] = entry
        result["devices"] = entries
        document["result"] = result
        let edited = try JSONSerialization.data(withJSONObject: document)
        let listed = try ApplePhysicalDeviceLister.devices(fromListJSON: edited, optIn: .everyPhysicalDevice)
        return try XCTUnwrap(listed.first { $0.hardwareUDID == udid })
    }

    private func other(_ udid: String, name: String) -> PhysicalCaptureDevice {
        PhysicalCaptureDevice(uniqueID: udid, localizedName: name, modelID: "iOS Device")
    }

    func testTheUDIDMatchesInItsForms() throws {
        let device = try phone()
        let udid = device.hardwareUDID
        for form in [udid, udid.lowercased(), udid.uppercased(), udid.replacingOccurrences(of: "-", with: ""), " \(udid)\n"] {
            let found = PhysicalCaptureMatcher.match([other(form, name: "x")], for: device, among: [device])
            XCTAssertEqual(found?.basis, .uniqueID, "\(form.count)-character form")
            XCTAssertEqual(found?.device.uniqueID, form)
        }
    }

    /// The shape measured on the test phone: a per-device UUID that is none
    /// of the phone's identifiers, its name, and "iOS Device". The UDID
    /// mapping fails, so the name and model pair ties it.
    func testTheMeasuredShapeOfARealCaptureDeviceMatchesByNameAndModel() throws {
        let device = try phone()
        let name = try XCTUnwrap(device.name)
        let real = PhysicalCaptureDevice(
            uniqueID: "5A1B2C3D-4E5F-4A6B-9C7D-8E9F0A1B2C3D",
            localizedName: name,
            modelID: "iOS Device"
        )
        let found = PhysicalCaptureMatcher.match([real], for: device, among: [device])
        XCTAssertEqual(found?.device, real)
        XCTAssertEqual(found?.basis, .nameAndModel)
    }

    func testTheUDIDWinsOverANameThatOnlyLooksRight() throws {
        let device = try phone()
        let name = try XCTUnwrap(device.name)
        let byName = PhysicalCaptureDevice(uniqueID: "other-1", localizedName: name, modelID: "iOS Device")
        let byID = other(device.hardwareUDID.lowercased(), name: "Renamed")
        let found = PhysicalCaptureMatcher.match([byName, byID], for: device, among: [device])
        XCTAssertEqual(found?.device, byID)
        XCTAssertEqual(found?.basis, .uniqueID)
    }

    func testTheNameAndModelFallbackNeedsAnUnambiguousPairWhenNoUDIDMatches() throws {
        let device = try phone()
        let name = try XCTUnwrap(device.name)
        let opaque = PhysicalCaptureDevice(uniqueID: "opaque-id", localizedName: name, modelID: "iOS Device")
        let found = PhysicalCaptureMatcher.match([opaque], for: device, among: [device])
        XCTAssertEqual(found?.basis, .nameAndModel)
        XCTAssertEqual(found?.device, opaque)

        // The model may also name the phone's product type.
        let typed = PhysicalCaptureDevice(uniqueID: "opaque-id", localizedName: name.uppercased(), modelID: try XCTUnwrap(device.productType))
        XCTAssertNotNil(PhysicalCaptureMatcher.match([typed], for: device, among: [device]))

        // A different name, or a model that is not the phone's: no match.
        let renamed = PhysicalCaptureDevice(uniqueID: "opaque-id", localizedName: "Somebody else's phone", modelID: "iOS Device")
        XCTAssertNil(PhysicalCaptureMatcher.match([renamed], for: device, among: [device]))
        let foreign = PhysicalCaptureDevice(uniqueID: "opaque-id", localizedName: name, modelID: "FaceTime HD Camera")
        XCTAssertNil(PhysicalCaptureMatcher.match([foreign], for: device, among: [device]))

        // Two capture devices with the phone's name: ambiguous, so none.
        let twin = PhysicalCaptureDevice(uniqueID: "opaque-id-2", localizedName: name, modelID: "iOS Device")
        XCTAssertNil(PhysicalCaptureMatcher.match([opaque, twin], for: device, among: [device]))
    }

    func testACaptureDeviceThatIsAnotherListedPhonesIsNeverThisOnes() throws {
        let device = try phone()
        let name = try XCTUnwrap(device.name)
        // The fixture's other listed device: a second physical phone of the same name.
        let second = try otherPhone(udid: "11111111-1111111111111111", name: "Another phone")
        XCTAssertNotEqual(second.hardwareUDID, device.hardwareUDID)
        XCTAssertNotEqual(second.name, device.name)
        let theirs = PhysicalCaptureDevice(uniqueID: "11111111-1111111111111111", localizedName: name, modelID: "iOS Device")
        XCTAssertNil(PhysicalCaptureMatcher.match([theirs], for: device, among: [device, second]),
                     "a capture device that is the other listed phone's UDID is not this phone's")
    }

    func testTheNameFallbackRefusesAmbiguousListedNames() throws {
        let device = try phone()
        let name = try XCTUnwrap(device.name)
        let twin = try otherPhone(udid: "22222222-2222222222222222")
        XCTAssertNotEqual(twin.hardwareUDID, device.hardwareUDID)
        let opaque = PhysicalCaptureDevice(uniqueID: "opaque-id", localizedName: name, modelID: "iOS Device")
        XCTAssertNil(PhysicalCaptureMatcher.match([opaque], for: device, among: [device, twin]),
                     "two listed phones share the name: the name cannot pick one")
    }

    func testNoCaptureDevicesMeansNoMatch() throws {
        let device = try phone()
        XCTAssertNil(PhysicalCaptureMatcher.match([], for: device, among: [device]))
    }
}

// MARK: - The plan

/// What the stage shows for each combination of state, transport, switches
/// and permission.
@MainActor
final class PhysicalViewPlanTests: XCTestCase {
    private func plan(
        enabled: Bool = true,
        wired: Bool = true,
        shows: Bool = true,
        live: Bool = true,
        auto: Bool = true,
        screenshots: Bool = true,
        authorization: CaptureAuthorization = .authorized,
        device: Bool = true,
        failure: String? = nil,
        unpaired: Bool = false,
        nativeLive: Bool = false
    ) throws -> PhysicalViewPlan {
        let entry = try PhysicalFixtures.entry(enabled: enabled) { entry in
            if !wired {
                var properties = entry["properties"] as? [String: Any] ?? [:]
                var connection = properties["connection"] as? [String: Any] ?? [:]
                connection["transportType"] = "localNetwork"
                properties["connection"] = connection
                entry["properties"] = properties
                var legacy = entry["connectionProperties"] as? [String: Any] ?? [:]
                legacy["transportType"] = "localNetwork"
                entry["connectionProperties"] = legacy
            }
            if unpaired {
                entry["connectionProperties"] = (entry["connectionProperties"] as? [String: Any] ?? [:]).merging(["pairingState": "unpaired"]) { $1 }
                var properties = entry["properties"] as? [String: Any] ?? [:]
                var connection = properties["connection"] as? [String: Any] ?? [:]
                connection["pairingState"] = "unpaired"
                properties["connection"] = connection
                entry["properties"] = properties
            }
        }
        return PhysicalViewPlan.make(
            entry: entry,
            showsPhysicalDevices: shows,
            liveViewOn: live,
            autoRefreshOn: auto,
            screenshotSupported: screenshots,
            authorization: authorization,
            captureDevice: device ? captureDevice(for: entry) : nil,
            liveFailure: failure,
            nativeLive: nativeLive
        )
    }

    func testAWiredReadyAuthorizedPhoneWithACaptureDeviceIsLive() throws {
        let plan = try plan()
        XCTAssertEqual(plan.mode, .live(captureDeviceID: PhysicalFixtures.udid))
        XCTAssertEqual(plan.note, .none)
        XCTAssertNil(plan.noteText)
        XCTAssertFalse(plan.needsCameraRequest)
    }

    /// The native live view rides the CoreDevice tunnel, so a phone on Wi-Fi is live too
    /// (measured 2026-10-01, 21 fps on a still screen); only the capture needs the cable.
    func testTheNativeLiveViewNeedsNoCable() throws {
        let wireless = try plan(wired: false, nativeLive: true)
        XCTAssertEqual(wireless.mode, .nativeLive)
        XCTAssertEqual(wireless.note, .none)
    }

    func testTheTransportDecidesTheCapture() throws {
        let wireless = try plan(wired: false)
        XCTAssertEqual(wireless.mode, .screenshots, "Wi-Fi: the screenshot preview")
        XCTAssertEqual(wireless.note, .notWired)
        XCTAssertEqual(wireless.noteText, "Connect the cable to see the screen live.")
        let noCapture = try plan(device: false)
        XCTAssertEqual(noCapture.mode, .screenshots)
        XCTAssertEqual(noCapture.note, .noCaptureDevice)
    }

    func testThePermissionStatesBecomeModes() throws {
        let pending = try plan(authorization: .notDetermined)
        XCTAssertTrue(pending.needsCameraRequest, "asked once, when the live view starts")
        XCTAssertEqual(pending.mode, .screenshots)
        XCTAssertEqual(pending.note, .cameraPending)
        XCTAssertNil(pending.noteText)

        for state in [CaptureAuthorization.denied, .restricted] {
            let denied = try plan(authorization: state)
            XCTAssertFalse(denied.needsCameraRequest)
            XCTAssertEqual(denied.mode, .screenshots, "the preview stands in while the screen cannot be live")
            XCTAssertEqual(denied.note, .cameraDenied)
            XCTAssertEqual(
                denied.noteText,
                "Allow Device Hub Pro under System Settings › Privacy & Security › Camera to see the screen live."
            )
            XCTAssertTrue(denied.offersCameraSettings)
        }
        // With Auto-refresh off the static panel keeps its Take Screenshot and the message.
        let staticPanel = try plan(auto: false, authorization: .denied)
        XCTAssertEqual(staticPanel.mode, .staticPanel)
        XCTAssertTrue(staticPanel.offersCameraSettings)
        XCTAssertEqual(PhysicalViewPlan.cameraSettingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
    }

    func testTheTwoSwitchesChooseBetweenLiveThePreviewAndTheStaticPanel() throws {
        XCTAssertEqual(try plan(live: false).mode, .screenshots)
        XCTAssertEqual(try plan(live: false).note, .liveViewOff)
        XCTAssertEqual(try plan(live: false, auto: false).mode, .staticPanel)
        XCTAssertEqual(try plan(wired: false, auto: false).mode, .staticPanel)
        XCTAssertEqual(try plan(auto: false).mode, .live(captureDeviceID: PhysicalFixtures.udid),
                       "Auto-refresh only governs the fallback")
        XCTAssertEqual(try plan(wired: false, screenshots: false).mode, .staticPanel,
                       "a device that reported screenshots unsupported gets no preview")
    }

    func testANonEnabledUnpairedOrHiddenDeviceGetsTheStaticPanel() throws {
        XCTAssertEqual(try plan(enabled: false).mode, .staticPanel)
        XCTAssertEqual(try plan(shows: false).mode, .staticPanel)
        XCTAssertEqual(try plan(unpaired: true).mode, .staticPanel)
        let none = PhysicalViewPlan.make(
            entry: nil, showsPhysicalDevices: true, liveViewOn: true, autoRefreshOn: true, screenshotSupported: true,
            authorization: .authorized, captureDevice: nil, liveFailure: nil
        )
        XCTAssertEqual(none.mode, .staticPanel)
    }

    func testAnEarlierLiveFailureFallsBackWithItsReason() throws {
        let plan = try plan(failure: "The iPhone's screen is no longer available.")
        XCTAssertEqual(plan.mode, .screenshots)
        XCTAssertEqual(plan.noteText, "The live view stopped: The iPhone's screen is no longer available.")
    }
}

// MARK: - The controller

/// The lifecycle of a physical device's view: when a session starts, when it
/// stops, and that no capture is ever made for a device the user did not
/// enable or while "Show physical Apple devices" is off. All on a fake
/// capture provider: no test touches AVFoundation, CoreMediaIO or the Camera.
@MainActor
final class PhysicalLiveViewControllerTests: XCTestCase {
    @MainActor
    private final class Harness {
        let controller: PhysicalLiveViewController
        let provider: TestCaptureProvider
        var inputs = PhysicalLiveViewController.Inputs()
        var active: (any MirrorSessionProtocol)?
        var begun: [(session: any MirrorSessionProtocol, device: DeviceRef, capabilities: DeviceCapabilities)] = []
        var teardowns: [MirrorController.MirrorTeardownCause] = []
        var refuseClaim = false
        var opened: [URL] = []
        var flashes: [String] = []
        var poses: [(turns: Int, animated: Bool)] = []
        var resets = 0
        let previewCaptureCount = PreviewCounter()
        var previewCaptures: Int { previewCaptureCount.value }
        var deviceScreenshots = 0
        /// The sinks the controller made, oldest first.
        var sinks: [TestAudioSink] = []
        var audioPolicy: PhysicalAudioPolicy = .plays

        init(provider: TestCaptureProvider) {
            self.provider = provider
            controller = PhysicalLiveViewController(provider: provider)
            controller.audioPolicyProvider = { [unowned self] in audioPolicy }
            controller.makeAudioSink = { [unowned self] in
                let sink = TestAudioSink()
                sinks.append(sink)
                return sink
            }
            controller.previewInterval = .milliseconds(20)
            controller.inputs = { [unowned self] in inputs }
            controller.activeSession = { [unowned self] in active }
            controller.beginSession = { [unowned self] session, device, capabilities in
                if refuseClaim { return false }
                active?.stop()
                begun.append((session, device, capabilities))
                active = session
                session.start()
                return true
            }
            controller.tearDownSession = { [unowned self] cause in
                teardowns.append(cause)
                active?.stop()
                active = nil
            }
            let counter = previewCaptureCount
            controller.screenshotCapture = { _ in
                { _ in counter.increment() }
            }
            controller.deviceScreenshot = { [unowned self] _ in
                deviceScreenshots += 1
                return Data([1, 2, 3])
            }
            controller.openURL = { [unowned self] url in opened.append(url) }
            controller.flash = { [unowned self] message in flashes.append(message) }
            controller.resetPose = { [unowned self] in resets += 1 }
            controller.settlePose = { [unowned self] turns, animated in poses.append((turns, animated)) }
        }

        var liveSession: PhysicalScreenCaptureSession? { active as? PhysicalScreenCaptureSession }
        var previewSession: PhysicalScreenshotSession? { active as? PhysicalScreenshotSession }
    }

    private func harness(
        enabled: Bool = true,
        wired: Bool = true,
        shows: Bool = true,
        authorization: CaptureAuthorization = .authorized,
        withCaptureDevice: Bool = true,
        grants: Bool = true,
        carriesAudio: Bool = false,
        audioAuthorization: CaptureAuthorization = .authorized,
        audioGrants: Bool = true
    ) throws -> Harness {
        let entry = try PhysicalFixtures.entry(enabled: enabled) { entry in
            if !wired {
                var properties = entry["properties"] as? [String: Any] ?? [:]
                var connection = properties["connection"] as? [String: Any] ?? [:]
                connection["transportType"] = "localNetwork"
                properties["connection"] = connection
                entry["properties"] = properties
                entry["connectionProperties"] = (entry["connectionProperties"] as? [String: Any] ?? [:]).merging(["transportType": "localNetwork"]) { $1 }
            }
        }
        let provider = TestCaptureProvider(
            authorization: authorization,
            devices: withCaptureDevice ? [captureDevice(for: entry, hasAudio: carriesAudio)] : [],
            grants: grants,
            audioAuthorization: audioAuthorization,
            audioGrants: audioGrants
        )
        let harness = Harness(provider: provider)
        harness.inputs = PhysicalLiveViewController.Inputs(
            entry: entry,
            listed: [entry.device],
            isWindowVisible: true,
            showsPhysicalDevices: shows,
            liveViewOn: true,
            autoRefreshOn: true,
            screenshotSupported: true
        )
        addTeardownBlock { @MainActor in harness.active?.stop() }
        return harness
    }

    // MARK: Start

    func testASelectedReadyWiredAuthorizedPhoneStartsTheLiveCapture() throws {
        let harness = try harness()
        harness.controller.reconcile()
        XCTAssertEqual(harness.begun.count, 1)
        let begun = try XCTUnwrap(harness.begun.first)
        XCTAssertEqual(begun.device, .physicalApple(PhysicalFixtures.udid))
        XCTAssertEqual(begun.capabilities, [.mirror, .screenshot, .record], "a picture, its screenshot and recording; no input")
        let live = try XCTUnwrap(harness.liveSession)
        XCTAssertEqual(live.captureDeviceID, PhysicalFixtures.udid)
        XCTAssertEqual(harness.provider.allowCalls, 1)
        XCTAssertEqual(harness.controller.plan.mode, .live(captureDeviceID: PhysicalFixtures.udid))
        XCTAssertEqual(harness.resets, 1, "the chrome starts upright")
        XCTAssertTrue(harness.controller.showsSession(for: PhysicalFixtures.udid))
        XCTAssertTrue(harness.controller.showsSession(for: PhysicalFixtures.udid.lowercased()))

        // Reconciling again changes nothing: one capture per device.
        harness.controller.reconcile()
        harness.controller.reconcile()
        XCTAssertEqual(harness.begun.count, 1)
    }

    // MARK: Never without the user's say

    func testNoCaptureForADeviceThatIsNotEnabled() throws {
        let harness = try harness(enabled: false)
        harness.controller.reconcile()
        XCTAssertTrue(harness.begun.isEmpty)
        XCTAssertEqual(harness.provider.allowCalls, 0, "CoreMediaIO is not touched for a device the user did not enable")
        XCTAssertEqual(harness.provider.deviceQueries, 0)
        XCTAssertEqual(harness.provider.requestCalls, 0)
        XCTAssertTrue(harness.provider.makeCalls.isEmpty)
        XCTAssertEqual(harness.controller.plan.mode, .staticPanel)
    }

    func testWithThePreferenceOffTheCMIOPropertyIsNeverSet() throws {
        let harness = try harness(shows: false)
        harness.controller.reconcile()
        harness.controller.reconcile()
        XCTAssertTrue(harness.begun.isEmpty)
        XCTAssertEqual(harness.provider.allowCalls, 0)
        XCTAssertEqual(harness.provider.deviceQueries, 0)
        XCTAssertEqual(harness.provider.requestCalls, 0)
        XCTAssertTrue(harness.provider.makeCalls.isEmpty)
    }

    func testNothingIsSetWhenNoPhysicalDeviceIsSelected() throws {
        let harness = try harness()
        harness.inputs.entry = nil
        harness.controller.reconcile()
        XCTAssertEqual(harness.provider.allowCalls, 0)
        XCTAssertTrue(harness.begun.isEmpty)
    }

    func testLiveViewOffNeverSetsTheCMIOPropertyAndUsesThePreview() throws {
        let harness = try harness()
        harness.inputs.liveViewOn = false
        harness.controller.reconcile()
        XCTAssertEqual(harness.provider.allowCalls, 0)
        XCTAssertNotNil(harness.previewSession, "the preview stands in without the capture")
        XCTAssertTrue(harness.provider.makeCalls.isEmpty)
    }

    // MARK: Stop edges

    func testAHiddenWindowKeepsTheRunningSessionAndDoesNotRestartIt() throws {
        let harness = try harness()
        harness.controller.reconcile()
        let first = try XCTUnwrap(harness.liveSession)
        harness.inputs.isWindowVisible = false
        harness.controller.reconcile()
        XCTAssertNotNil(harness.active, "occlusion or a background app does not end the session")
        XCTAssertTrue(first.isRunning)
        XCTAssertTrue(harness.teardowns.isEmpty)
        XCTAssertTrue(harness.controller.showsSession(for: PhysicalFixtures.udid))

        harness.inputs.isWindowVisible = true
        harness.controller.reconcile()
        XCTAssertTrue(first === harness.liveSession, "the same session shows again, no new first frame to wait for")
        XCTAssertEqual(harness.begun.count, 1)
        XCTAssertTrue(harness.teardowns.isEmpty)
    }

    func testAHiddenWindowDoesNotStartASession() throws {
        let harness = try harness()
        harness.inputs.isWindowVisible = false
        harness.controller.reconcile()
        XCTAssertNil(harness.active)
        XCTAssertTrue(harness.begun.isEmpty)

        harness.inputs.isWindowVisible = true
        harness.controller.reconcile()
        XCTAssertNotNil(harness.liveSession)
    }

    func testDeselectingStopsTheCapture() throws {
        let harness = try harness()
        harness.controller.reconcile()
        XCTAssertNotNil(harness.active)
        harness.inputs.entry = nil
        harness.controller.reconcile()
        XCTAssertNil(harness.active)
        XCTAssertEqual(harness.teardowns, [.userStop])
    }

    func testDisablingTheDeviceStopsTheCapture() throws {
        let harness = try harness()
        harness.controller.reconcile()
        let disabled = try PhysicalFixtures.entry(enabled: false)
        harness.inputs.entry = disabled
        harness.controller.reconcile()
        XCTAssertNil(harness.active)
        XCTAssertEqual(harness.teardowns, [.userStop])
    }

    func testTurningThePreferenceOffStopsTheCapture() throws {
        let harness = try harness()
        harness.controller.reconcile()
        harness.inputs.showsPhysicalDevices = false
        harness.controller.reconcile()
        XCTAssertNil(harness.active)
    }

    func testAnotherSessionInTheWorkspaceIsNotOurs() throws {
        let harness = try harness()
        harness.inputs.entry = nil
        harness.active = SimulatorScreenshotSession(udid: "SIM", capture: { _ in })
        harness.controller.reconcile()
        XCTAssertTrue(harness.teardowns.isEmpty, "a simulator's session is never torn down by the physical view")
        XCTAssertNotNil(harness.active)
    }

    /// The phone was unplugged: the session ends itself, the hub tears it
    /// down as a disconnect, the preview takes over and the live capture is
    /// not retried until a capture device appears or disappears.
    func testAnUnpluggedPhoneFallsBackToThePreviewAndRetriesOnlyOnADeviceChange() async throws {
        let harness = try harness()
        harness.controller.reconcile()
        let live = try XCTUnwrap(harness.liveSession)
        await expectEventually { harness.provider.captures.first?.started == 1 }
        try XCTUnwrap(harness.provider.captures.first).onEnd(.disconnected)
        XCTAssertFalse(live.isRunning)

        harness.controller.sessionStopped(live)
        XCTAssertEqual(harness.teardowns, [.disconnected])
        XCTAssertFalse(harness.flashes.isEmpty)
        XCTAssertNotNil(harness.previewSession, "the screenshot preview takes over")
        XCTAssertEqual(harness.controller.plan.note, .liveFailed(PhysicalScreenCaptureSession.disconnectedMessage))

        harness.controller.reconcile()
        XCTAssertNotNil(harness.previewSession, "not retried on every reconcile")
        XCTAssertEqual(harness.provider.makeCalls.count, 1)

        // The phone comes back: a capture device changes and the live view tries again.
        harness.provider.announceDeviceChange()
        await expectEventually { harness.liveSession != nil }
        XCTAssertEqual(harness.provider.makeCalls.count, 2)
    }

    // MARK: Fallbacks

    func testWiFiUsesThePreviewAndNeverTheCapture() throws {
        let harness = try harness(wired: false)
        harness.controller.reconcile()
        XCTAssertNotNil(harness.previewSession)
        XCTAssertEqual(harness.controller.plan.note, .notWired)
        XCTAssertEqual(harness.provider.allowCalls, 0, "no capture lookup for a phone that is not on USB")
        XCTAssertTrue(harness.provider.makeCalls.isEmpty)
        XCTAssertEqual(harness.begun.first?.device, .physicalApple(PhysicalFixtures.udid))
    }

    func testAutoRefreshOffLeavesTheStaticPanelWhereLiveIsNotPossible() throws {
        let harness = try harness(wired: false)
        harness.inputs.autoRefreshOn = false
        harness.controller.reconcile()
        XCTAssertNil(harness.active)
        XCTAssertTrue(harness.begun.isEmpty)
        XCTAssertEqual(harness.controller.plan.mode, .staticPanel)
    }

    func testAPreviewOfADeviceThatCannotBeAskedIsNotStarted() throws {
        let harness = try harness(wired: false)
        harness.controller.screenshotCapture = { _ in nil }
        harness.controller.reconcile()
        XCTAssertNil(harness.active)
    }

    func testSwitchingFromThePreviewToLiveReplacesTheSession() throws {
        let harness = try harness(withCaptureDevice: false)
        harness.controller.reconcile()
        XCTAssertNotNil(harness.previewSession)
        XCTAssertEqual(harness.controller.plan.note, .noCaptureDevice)

        harness.provider.setDevices([captureDevice(for: try XCTUnwrap(harness.inputs.entry))])
        harness.provider.announceDeviceChange()
        harness.controller.reconcile()
        XCTAssertNotNil(harness.liveSession, "a capture device appeared: the live view replaces the preview")
        XCTAssertEqual(harness.begun.count, 2)
    }

    /// macOS enumerates a phone's screen a moment after the switch is set,
    /// and the connect notification may have passed: the capture devices are
    /// looked at again shortly, a bounded number of times.
    func testACaptureDeviceThatShowsUpLaterIsFoundWithoutANotification() async throws {
        let harness = try harness(withCaptureDevice: false)
        harness.controller.lookupRetryInterval = .milliseconds(20)
        harness.controller.reconcile()
        XCTAssertNotNil(harness.previewSession)
        let queriesAtStart = harness.provider.deviceQueries

        harness.provider.setDevices([captureDevice(for: try XCTUnwrap(harness.inputs.entry))])
        await expectEventually { harness.liveSession != nil }
        XCTAssertGreaterThan(harness.provider.deviceQueries, queriesAtStart)
    }

    func testTheLookupRetriesAreBounded() async throws {
        let harness = try harness(withCaptureDevice: false)
        harness.controller.lookupRetryInterval = .milliseconds(5)
        harness.controller.reconcile()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertLessThanOrEqual(
            harness.provider.deviceQueries,
            PhysicalLiveViewController.maximumLookupRetries + 2,
            "a phone with no capture device is not polled forever"
        )
    }

    // MARK: The Camera permission

    func testACameraNotYetAskedIsRequestedOnceAndThenTheLiveViewStarts() async throws {
        let harness = try harness(authorization: .notDetermined)
        harness.controller.reconcile()
        XCTAssertEqual(harness.controller.plan.note, .cameraPending)
        XCTAssertNotNil(harness.previewSession, "the preview shows while the prompt is up")
        await expectEventually { harness.liveSession != nil }
        XCTAssertEqual(harness.provider.requestCalls, 1)
        harness.controller.reconcile()
        XCTAssertEqual(harness.provider.requestCalls, 1, "asked once")
    }

    func testADeniedCameraKeepsThePreviewAndOnlyOffersTheSettingsPane() async throws {
        let harness = try harness(authorization: .notDetermined, grants: false)
        harness.controller.reconcile()
        await expectEventually { harness.controller.plan.note == .cameraDenied }
        XCTAssertNil(harness.liveSession)
        XCTAssertNotNil(harness.previewSession)
        XCTAssertEqual(harness.controller.authorization, .denied)
        XCTAssertTrue(harness.provider.makeCalls.isEmpty, "no capture without the permission")

        XCTAssertTrue(harness.opened.isEmpty, "nothing opens by itself")
        harness.controller.openCameraSettings()
        XCTAssertEqual(harness.opened.map(\.absoluteString), ["x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"])
    }

    func testARestrictedCameraNeverAsksAndNeverCaptures() throws {
        let harness = try harness(authorization: .restricted)
        harness.controller.reconcile()
        XCTAssertEqual(harness.provider.requestCalls, 0)
        XCTAssertTrue(harness.provider.makeCalls.isEmpty)
        XCTAssertEqual(harness.controller.plan.note, .cameraDenied)
    }

    // MARK: One capture per device

    func testADeviceAnotherWindowShowsIsNotCapturedTwice() throws {
        let harness = try harness()
        harness.refuseClaim = true
        harness.controller.reconcile()
        XCTAssertTrue(harness.begun.isEmpty)
        XCTAssertEqual(harness.controller.plan.note, .shownElsewhere)
        XCTAssertEqual(harness.controller.plan.noteText, "This device's screen is shown in another window.")
        harness.controller.reconcile()
        XCTAssertEqual(harness.controller.plan.note, .shownElsewhere)
    }

    // MARK: The health poll and Take Screenshot

    func testTheHealthPollReadsTheErrorAndThePreviewsMeasuredCadence() async throws {
        let harness = try harness(wired: false)
        harness.controller.reconcile()
        let preview = try XCTUnwrap(harness.previewSession)
        preview.setShown(true)
        await expectEventually { harness.previewCaptures >= 1 }
        harness.controller.noteHealth(of: preview)
        XCTAssertNil(harness.controller.cadenceText, "no cadence before two pictures")
    }

    func testTakeScreenshotPrefersTheLiveFrameAndFallsBackToTheDevice() async throws {
        let harness = try harness()
        harness.controller.reconcile()
        let live = try XCTUnwrap(harness.liveSession)
        // No frame yet: the device's own screenshot.
        let fromDevice = await harness.controller.screenshotPNG(udid: PhysicalFixtures.udid)
        XCTAssertEqual(fromDevice, Data([1, 2, 3]))
        XCTAssertEqual(harness.deviceScreenshots, 1)

        live.frames.put(Frame(data: Data(count: 4 * 4 * 4), width: 4, height: 4, seq: 1))
        let livePNG = await harness.controller.screenshotPNG(udid: PhysicalFixtures.udid)
        let png = try XCTUnwrap(livePNG)
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "a PNG of the live frame")
        XCTAssertEqual(harness.deviceScreenshots, 1, "the live frame was used, not a second device call")
    }

    // MARK: Orientation

    func testALandscapeFrameTurnsTheChromeAndTheFirstOneDoesNotAnimate() async throws {
        let harness = try harness()
        harness.controller.reconcile()
        let live = try XCTUnwrap(harness.liveSession)
        live.frames.put(Frame(data: Data(count: 16 * 8 * 4), width: 16, height: 8, seq: 1))
        await expectEventually { !harness.poses.isEmpty }
        XCTAssertEqual(harness.poses.first?.turns, 1)
        XCTAssertEqual(harness.poses.first?.animated, false, "a session that starts on a turned phone rests there")

        live.frames.put(Frame(data: Data(count: 8 * 16 * 4), width: 8, height: 16, seq: 2))
        await expectEventually { harness.poses.count >= 2 }
        XCTAssertEqual(harness.poses.last?.turns, 0)
        XCTAssertEqual(harness.poses.last?.animated, true)
    }

    // MARK: Audio

    /// Only a capture device that carries audio (the muxed device of a
    /// phone) gets a sink and an audio output; a video-only device gets
    /// neither.
    func testAudioIsAskedForOnlyWhenTheCaptureDeviceCarriesIt() async throws {
        // The fake capture is made on the session's own queue after
        // `reconcile` returns: wait for it, or a loaded run reads nil.
        let silent = try harness(carriesAudio: false)
        silent.controller.reconcile()
        let silentLive = try XCTUnwrap(silent.liveSession)
        XCTAssertNil(silentLive.audioSink)
        XCTAssertTrue(silent.sinks.isEmpty, "no player is made for a device without audio")
        await expectEventually { silent.provider.captures.first != nil }
        XCTAssertNil(silent.provider.captures.first?.onAudio, "no audio output is added")
        XCTAssertFalse(silent.controller.hasAudio)

        let muxed = try harness(carriesAudio: true)
        muxed.controller.reconcile()
        let live = try XCTUnwrap(muxed.liveSession)
        XCTAssertNotNil(live.audioSink)
        XCTAssertEqual(muxed.sinks.count, 1)
        await expectEventually { muxed.provider.captures.first != nil }
        XCTAssertNotNil(muxed.provider.captures.first?.onAudio, "the capture adds an audio output")
        XCTAssertTrue(muxed.controller.hasAudio)
        XCTAssertTrue(muxed.controller.audioIsPlaying)
        XCTAssertEqual(muxed.sinks.first?.playingCalls.last, true)
    }

    /// The screenshot preview has no audio, whatever the device carries.
    func testThePreviewHasNoAudio() throws {
        let harness = try harness(wired: false, carriesAudio: true)
        harness.controller.reconcile()
        XCTAssertNotNil(harness.previewSession)
        XCTAssertTrue(harness.sinks.isEmpty)
        XCTAssertFalse(harness.controller.hasAudio)
    }

    /// The workspace's policy (Settings' audio mode, the key window) is what
    /// switches the phone's audio on and off.
    func testThePolicySwitchesThePhonesAudioOnAndOff() throws {
        let harness = try harness(carriesAudio: true)
        harness.controller.reconcile()
        let sink = try XCTUnwrap(harness.sinks.first)
        XCTAssertTrue(sink.isPlaying)

        harness.audioPolicy = .disabledInSettings
        harness.controller.applyAudio()
        XCTAssertFalse(sink.isPlaying, "muted when the audio mode is Disabled")
        XCTAssertEqual(harness.controller.audioPolicy, .disabledInSettings)
        XCTAssertFalse(harness.controller.audioIsPlaying)

        harness.audioPolicy = .otherWindowFocused
        harness.controller.applyAudio()
        XCTAssertFalse(sink.isPlaying, "another window is the key window")
        XCTAssertEqual(harness.controller.audioPolicy, .otherWindowFocused)

        harness.audioPolicy = .plays
        harness.controller.applyAudio()
        XCTAssertTrue(sink.isPlaying, "focus came back")
        XCTAssertTrue(harness.controller.audioIsPlaying)
        XCTAssertEqual(harness.sinks.count, 1, "the policy never restarts the session")
        XCTAssertEqual(harness.begun.count, 1)
    }

    /// A phone whose window is not the focused one never plays, even before
    /// the first policy change: the policy is read as the session starts.
    func testASessionStartedUnderASilencingPolicyStartsMuted() throws {
        let harness = try harness(carriesAudio: true)
        harness.audioPolicy = .otherWindowFocused
        harness.controller.reconcile()
        XCTAssertEqual(harness.sinks.first?.playingCalls.last, false)
        XCTAssertFalse(harness.controller.audioIsPlaying)
    }

    /// The banner's mute toggle, which the policy cannot override upward.
    func testTheMuteToggleSilencesAndRestoresThePhone() throws {
        let harness = try harness(carriesAudio: true)
        harness.controller.reconcile()
        let sink = try XCTUnwrap(harness.sinks.first)

        harness.controller.toggleAudioMuted()
        XCTAssertTrue(harness.controller.isAudioMuted)
        XCTAssertFalse(sink.isPlaying)
        XCTAssertFalse(harness.controller.audioIsPlaying)

        harness.audioPolicy = .disabledInSettings
        harness.controller.toggleAudioMuted()
        XCTAssertFalse(harness.controller.isAudioMuted)
        XCTAssertFalse(sink.isPlaying, "unmuting does not override a Disabled audio mode")

        harness.audioPolicy = .plays
        harness.controller.applyAudio()
        XCTAssertTrue(sink.isPlaying)
    }

    /// The user's mute survives the session (a reconnect): the next session
    /// starts muted.
    func testTheMuteOutlivesTheSession() throws {
        let harness = try harness(carriesAudio: true)
        harness.controller.reconcile()
        harness.controller.toggleAudioMuted()
        harness.inputs.entry = nil
        harness.controller.reconcile()
        XCTAssertNil(harness.active)
        harness.inputs.entry = try PhysicalFixtures.entry()
        harness.controller.reconcile()
        XCTAssertEqual(harness.sinks.count, 2)
        XCTAssertEqual(harness.sinks.last?.playingCalls.last, false, "still muted")
    }

    /// The audio is silent while the window is hidden and the session lives on.
    func testTheAudioPausesWhileTheWindowIsHidden() throws {
        let harness = try harness(carriesAudio: true)
        harness.controller.reconcile()
        let sink = try XCTUnwrap(harness.sinks.first)
        XCTAssertTrue(sink.isPlaying)

        harness.inputs.isWindowVisible = false
        harness.controller.reconcile()
        XCTAssertNotNil(harness.active)
        XCTAssertFalse(sink.isPlaying)
        XCTAssertFalse(harness.controller.audioIsPlaying)

        harness.inputs.isWindowVisible = true
        harness.controller.reconcile()
        XCTAssertTrue(sink.isPlaying)
    }

    /// The Microphone permission undecided: the live view runs video only, asks
    /// once, and the session is replaced by one with audio when it is granted.
    func testAnUndecidedMicrophoneRunsVideoOnlyAsksOnceAndThenGetsAudio() async throws {
        let harness = try harness(carriesAudio: true, audioAuthorization: .notDetermined)
        harness.controller.reconcile()
        let first = try XCTUnwrap(harness.liveSession)
        XCTAssertNil(first.audioSink, "no audio output before the permission")
        XCTAssertNil(harness.provider.captures.first?.onAudio)
        XCTAssertTrue(harness.sinks.isEmpty)

        await expectEventually { harness.sinks.count == 1 }
        XCTAssertEqual(harness.provider.audioRequestCalls, 1)
        XCTAssertEqual(harness.begun.count, 2, "the video-only session was replaced")
        XCTAssertFalse(first.isRunning)
        let second = try XCTUnwrap(harness.liveSession)
        XCTAssertNotNil(second.audioSink)
        XCTAssertTrue(harness.controller.audioIsPlaying)
        XCTAssertNil(harness.controller.audioNoteText)

        harness.controller.reconcile()
        harness.controller.reconcile()
        XCTAssertEqual(harness.provider.audioRequestCalls, 1, "asked once")
        XCTAssertEqual(harness.begun.count, 2)
    }

    func testADeniedMicrophoneAnswerKeepsTheVideoAndSaysWhereToAllowIt() async throws {
        let harness = try harness(carriesAudio: true, audioAuthorization: .notDetermined, audioGrants: false)
        harness.controller.reconcile()
        await expectEventually { harness.provider.audioRequestCalls == 1 }
        await expectEventually { harness.controller.audioAuthorization == .denied }
        XCTAssertEqual(harness.begun.count, 1, "the video session is left alone")
        XCTAssertNil(try XCTUnwrap(harness.liveSession).audioSink)
        XCTAssertFalse(harness.controller.hasAudio)
        XCTAssertEqual(harness.controller.audioNoteText, PhysicalViewPlan.microphoneDeniedText)
    }

    func testAMicrophoneAlreadyDeniedNeverAsksAndOnlyOffersTheSettingsPane() throws {
        for status in [CaptureAuthorization.denied, .restricted] {
            let harness = try harness(carriesAudio: true, audioAuthorization: status)
            harness.controller.reconcile()
            XCTAssertNil(try XCTUnwrap(harness.liveSession).audioSink, "\(status)")
            XCTAssertNil(harness.provider.captures.first?.onAudio)
            XCTAssertEqual(harness.provider.audioRequestCalls, 0)
            XCTAssertEqual(harness.controller.audioNoteText, PhysicalViewPlan.microphoneDeniedText)
            harness.controller.openMicrophoneSettings()
            XCTAssertEqual(harness.opened, [PhysicalViewPlan.microphoneSettingsURL])
            XCTAssertEqual(
                PhysicalViewPlan.microphoneSettingsURL.absoluteString,
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            )
        }
    }

    /// A capture device without audio is never a reason to ask for the
    /// Microphone.
    func testADeviceWithoutAudioNeverAsksForTheMicrophone() async throws {
        let harness = try harness(carriesAudio: false, audioAuthorization: .notDetermined)
        harness.controller.reconcile()
        harness.controller.reconcile()
        XCTAssertEqual(harness.provider.audioRequestCalls, 0)
        XCTAssertNil(harness.controller.audioNoteText)
        XCTAssertEqual(harness.begun.count, 1)
    }

    func testAnUnpluggedPhoneStopsItsAudio() async throws {
        let harness = try harness(carriesAudio: true)
        harness.controller.reconcile()
        let sink = try XCTUnwrap(harness.sinks.first)
        let stops = sink.stopCount
        // The capture is made on a task the reconcile starts: under the
        // whole suite's load it is not there yet on the very next line.
        await expectEventually { harness.provider.captures.first != nil }
        let capture = try XCTUnwrap(harness.provider.captures.first)
        await expectEventually { capture.started == 1 }
        capture.onEnd(.disconnected)
        await expectEventually { !harness.liveSession!.isRunning }
        harness.controller.sessionStopped(try XCTUnwrap(harness.liveSession))
        XCTAssertGreaterThan(sink.stopCount, stops)
        XCTAssertFalse(harness.controller.hasAudio)
    }
}

// MARK: - In a workspace

/// A physical view session in a real workspace: it is a physical device's
/// view, never a simulator; window close ends it; Take Screenshot reads its
/// frame; nothing turns it.
@MainActor
final class PhysicalViewWorkspaceTests: XCTestCase {
    private func startSession(_ model: AppModel, provider: TestCaptureProvider) throws -> PhysicalScreenCaptureSession {
        let session = PhysicalScreenCaptureSession(
            hardwareUDID: PhysicalFixtures.udid,
            captureDeviceID: PhysicalFixtures.udid,
            provider: provider
        )
        let began = model.workspace.beginMirrorSession(
            session,
            device: .physicalApple(PhysicalFixtures.udid),
            port: nil,
            capabilities: PhysicalLiveViewController.capabilities
        )
        XCTAssertTrue(began)
        addTeardownBlock { session.stop() }
        return session
    }

    func testAPhysicalViewIsNotASimulatorAndWindowCloseEndsIt() async throws {
        let model = AppModel.testing()
        let provider = TestCaptureProvider()
        let session = try startSession(model, provider: provider)
        let context = model.workspace.context

        XCTAssertEqual(context.device, .physicalApple(PhysicalFixtures.udid))
        XCTAssertTrue(context.isPhysicalView)
        XCTAssertNil(context.simulatorDevice, "the simulator-only paths leave it alone")
        XCTAssertNil(context.serial)
        XCTAssertNil(context.port)
        XCTAssertTrue(model.workspace.capture.canTakeScreenshot)
        XCTAssertFalse(session.supportsHardwareKeys)
        XCTAssertFalse(model.workspace.context.capabilities.contains(.touch))
        XCTAssertFalse(model.workspace.context.capabilities.contains(.rotate))
        XCTAssertTrue(model.workspace.context.capabilities.contains(.record), "Record works for the live session")

        // Nothing turns it, and no simulator call was made for it.
        await model.workspace.rotateDevice(.left)
        XCTAssertEqual(model.workspace.context.device, .physicalApple(PhysicalFixtures.udid))

        model.workspace.tearDownMirror(cause: .windowClosed)
        XCTAssertFalse(session.isRunning, "window close stops the capture")
        XCTAssertNil(model.workspace.mirror.session)
        XCTAssertNil(context.device)
        XCTAssertFalse(context.isPhysicalView)
    }

    func testAnnotateScreenshotOpensTheEditorOnTheLiveFrame() async throws {
        let model = AppModel.testing()
        let provider = TestCaptureProvider()
        let session = try startSession(model, provider: provider)
        session.frames.put(Frame(data: Data(count: 4 * 4 * 4), width: 4, height: 4, seq: 1))

        await model.workspace.capture.annotateScreenshot()

        let request = try XCTUnwrap(model.workspace.capture.annotationEditRequest)
        XCTAssertEqual(Array(request.png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testAQuitStopsTheCaptureBeforeTheProcessEnds() async throws {
        let model = AppModel.testing()
        let provider = TestCaptureProvider()
        let session = try startSession(model, provider: provider)
        await expectEventually { provider.captures.first?.started == 1 }
        model.workspace.tearDownMirror(cause: .quit)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(provider.captures.first?.stopped, 1, "the quit's stop waits for the capture to stop")
    }

    // MARK: Audio policy

    private func multiWindowModel() -> AppModel {
        AppModel.testing(launch: LaunchOptions(environment: ["DHP_MULTIWINDOW": "1"]))
    }

    /// The emulator audio setting: a phone plays in "Emulator" and "In-app"
    /// alike (it has no player of its own) and is silent only when Disabled.
    func testOnlyADisabledAudioModeSilencesThePhone() {
        let model = AppModel.testing()
        for mode in [EmulatorAudioMode.enabled, .inApp] {
            model.setEmulatorAudioMode(mode)
            XCTAssertEqual(model.workspace.physicalAudioPolicy, .plays, "\(mode)")
        }
        model.setEmulatorAudioMode(.disabled)
        XCTAssertEqual(model.workspace.physicalAudioPolicy, .disabledInSettings)
    }

    /// The phone's audio follows the key window with multiple windows: the
    /// focused workspace plays, the others are silent; without the flag
    /// every workspace plays.
    func testThePhonesAudioFollowsTheKeyWindow() {
        let model = multiWindowModel()
        let second = DeviceWorkspace(services: model.services)
        model.registry.register(second)

        XCTAssertNil(model.registry.focusedID)
        XCTAssertEqual(model.workspace.physicalAudioPolicy, .plays, "nothing became key yet")
        XCTAssertEqual(second.physicalAudioPolicy, .plays)

        model.registry.focusedID = model.workspace.id
        XCTAssertEqual(model.workspace.physicalAudioPolicy, .plays)
        XCTAssertEqual(second.physicalAudioPolicy, .otherWindowFocused)

        model.registry.focusedID = second.id
        XCTAssertEqual(model.workspace.physicalAudioPolicy, .otherWindowFocused)
        XCTAssertEqual(second.physicalAudioPolicy, .plays)

        let single = AppModel.testing()
        let other = DeviceWorkspace(services: single.services)
        single.registry.register(other)
        single.registry.focusedID = single.workspace.id
        XCTAssertEqual(other.physicalAudioPolicy, .plays, "single-window mode: focus never silences another workspace")
    }

    /// End to end in a workspace: a focus change and a Settings change move
    /// the phone's audio without touching the session.
    func testAFocusChangeAndTheSettingsModeMoveThePhonesAudio() throws {
        let model = multiWindowModel()
        let second = DeviceWorkspace(services: model.services)
        model.registry.register(second)
        model.registry.focusedID = model.workspace.id

        let sink = TestAudioSink()
        let session = PhysicalScreenCaptureSession(
            hardwareUDID: PhysicalFixtures.udid,
            captureDeviceID: PhysicalFixtures.udid,
            provider: TestCaptureProvider(),
            audioSink: sink
        )
        addTeardownBlock { session.stop() }
        XCTAssertTrue(model.workspace.beginMirrorSession(
            session,
            device: .physicalApple(PhysicalFixtures.udid),
            port: nil,
            capabilities: PhysicalLiveViewController.capabilities
        ))
        XCTAssertTrue(sink.isPlaying, "the focused workspace's phone plays")
        XCTAssertTrue(model.workspace.physicalLive.hasAudio)

        model.registry.focusedID = second.id
        XCTAssertFalse(sink.isPlaying, "focus moved to another window")
        XCTAssertTrue(session.isRunning, "the session is untouched")

        model.registry.focusedID = model.workspace.id
        XCTAssertTrue(sink.isPlaying)

        model.setEmulatorAudioMode(.disabled)
        XCTAssertFalse(sink.isPlaying, "Disabled mutes the phone")
        XCTAssertEqual(model.workspace.physicalLive.audioPolicy, .disabledInSettings)

        model.setEmulatorAudioMode(.inApp)
        XCTAssertTrue(sink.isPlaying)

        let stops = sink.stopCount
        model.workspace.tearDownMirror(cause: .userStop)
        XCTAssertGreaterThan(sink.stopCount, stops, "the audio stops with the session")
        XCTAssertFalse(model.workspace.physicalLive.hasAudio)
    }

    /// The physical view's preferences default on and persist.
    func testTheTwoSwitchesDefaultOnAndPersist() {
        let defaults = UserDefaults.scratch()
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.physicalLiveViewEnabled)
        XCTAssertTrue(preferences.physicalAutoRefreshEnabled)
        preferences.setPhysicalLiveViewEnabled(false)
        preferences.setPhysicalAutoRefreshEnabled(false)
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.physicalLiveViewEnabled)
        XCTAssertFalse(reloaded.physicalAutoRefreshEnabled)
    }
}

// MARK: - Source guards

/// The capture provider that reaches hardware is made in one place, and the
/// CoreMediaIO switch is set by one caller.
final class PhysicalLiveViewSourceGuardTests: XCTestCase {
    private func hits(of pattern: String) throws -> [String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/DeviceHubProApp", isDirectory: true)
        var hits: [String] = []
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
                let code = String(line)
                guard !code.trimmingCharacters(in: .whitespaces).hasPrefix("//"), code.contains(pattern) else { continue }
                hits.append(url.lastPathComponent)
            }
        }
        return hits
    }

    func testOnlyTheLiveEnvironmentMakesTheHardwareCaptureProvider() throws {
        XCTAssertEqual(try hits(of: "AVFoundationScreenCaptureProvider("), ["AppEnvironment.swift"])
    }

    func testOnlyThePhysicalViewControllerAllowsScreenCaptureDevices() throws {
        XCTAssertEqual(try hits(of: ".allowScreenCaptureDevices()"), ["PhysicalLiveViewController.swift"])
    }

    /// A test environment has the inert provider: no CoreMediaIO, no device.
    @MainActor
    func testATestEnvironmentGetsTheInertProvider() {
        let environment = AppEnvironment.testing()
        XCTAssertTrue(environment.screenCapture is InertScreenCaptureProvider)
        XCTAssertTrue(environment.screenCapture.captureDevices().isEmpty)
        XCTAssertEqual(environment.screenCapture.authorization, .denied)
    }
}
