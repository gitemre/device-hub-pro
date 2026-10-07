import Foundation
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The physical iPhone's stage and pill at Device Hub parity (Phase
/// 9F): the banner card is gone and only a small status line can appear; the
/// three switches and the commands are an API on `PhysicalLiveViewController`
/// for the menus; Home, Rotate, Siri and the App Switcher start Control on
/// demand; the pill is Home, Screenshot and Rotate.
final class PhysicalStatusLineTests: XCTestCase {
    private func line(
        viewKind: PhysicalViewKind? = .liveCapture,
        cadence: String? = nil,
        controlIsReady: Bool = false,
        controlProgress: String? = nil,
        controlMessage: String? = nil,
        planNote: String? = nil,
        offersCameraSettings: Bool = false,
        audioNote: String? = nil
    ) -> PhysicalStatusLine {
        PhysicalStatusLine.make(
            viewKind: viewKind,
            cadence: cadence,
            controlIsReady: controlIsReady,
            controlProgress: controlProgress,
            controlMessage: controlMessage,
            planNote: planNote,
            offersCameraSettings: offersCameraSettings,
            audioNote: audioNote
        )
    }

    /// Device Hub shows nothing above the phone: a live picture, Control off,
    /// no permission trouble, means no line at all.
    func testNothingToSayMeansNoLine() {
        XCTAssertTrue(line().isEmpty)
        XCTAssertTrue(line(viewKind: nil).isEmpty, "the static panel says nothing either")
        XCTAssertTrue(line(controlIsReady: true).isEmpty, "Control running needs no line")
    }

    func testThePreviewSaysItIsViewOnlyAndHowOftenItRefreshes() {
        XCTAssertEqual(
            line(viewKind: .screenshots, cadence: "about every 1.1 s").entries,
            [.init(kind: .info, text: "View only · refreshes about every 1.1 s")]
        )
        XCTAssertEqual(
            line(viewKind: .screenshots, cadence: nil).entries,
            [.init(kind: .info, text: "View only · refreshing…")],
            "before the first measurement"
        )
        XCTAssertEqual(
            line(viewKind: .screenshots, cadence: "about every 1.5 s", controlIsReady: true).entries,
            [.init(kind: .info, text: "Controlling · refreshes about every 1.5 s")]
        )
        // The live capture never claims a cadence (the old banner said "refreshes about
        // every 1,1 s" with Live View on).
        XCTAssertTrue(line(viewKind: .liveCapture, cadence: "about every 1.1 s").isEmpty)
    }

    func testControlStartingShowsAProgressLineAndFailingShowsItsReason() {
        XCTAssertEqual(
            line(controlProgress: "Building the iPhone input runner…").entries,
            [.init(kind: .progress, text: "Building the iPhone input runner…")]
        )
        // The progress wins over an older message.
        XCTAssertEqual(
            line(controlProgress: "Starting…", controlMessage: "old").entries.map(\.kind),
            [.progress]
        )
        XCTAssertEqual(
            line(controlMessage: PhysicalControlError.noTeam.description).entries,
            [.init(kind: .message, text: PhysicalControlError.noTeam.description)]
        )
    }

    func testAPermissionHintCarriesItsSettingsButton() {
        let camera = line(
            viewKind: .screenshots, cadence: "about every 1.5 s",
            planNote: PhysicalViewPlan.cameraDeniedText, offersCameraSettings: true
        )
        XCTAssertEqual(camera.entries.map(\.kind), [.info, .info])
        XCTAssertEqual(camera.entries[0].action, nil)
        XCTAssertEqual(camera.entries[1], .init(kind: .info, text: PhysicalViewPlan.cameraDeniedText, action: .openCameraSettings))
        XCTAssertEqual(PhysicalStatusLine.Action.openCameraSettings.title, "Open Camera Settings")

        let microphone = line(audioNote: PhysicalViewPlan.microphoneDeniedText)
        XCTAssertEqual(
            microphone.entries,
            [.init(kind: .info, text: PhysicalViewPlan.microphoneDeniedText, action: .openMicrophoneSettings)]
        )
        // A note without the camera flag has no button.
        XCTAssertNil(line(planNote: "Connect the cable to see the screen live.").entries.first?.action)
    }

    func testTheLinesKeepTheirOrder() {
        let all = line(
            viewKind: .screenshots, cadence: "about every 1.5 s", controlMessage: "Tap a text field first",
            planNote: "Connect the cable to see the screen live.", audioNote: "mic"
        )
        XCTAssertEqual(all.entries.map(\.text), [
            "Tap a text field first",
            "View only · refreshes about every 1.5 s",
            "Connect the cable to see the screen live.",
            "mic",
        ])
    }
}

/// The banner card is gone, in the sources: nothing draws the old switches over the
/// phone. (A source scan, like the other Apple guards; the physical views are
/// SwiftUI and never rendered in a test.)
final class PhysicalBannerGoneSourceTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheBannerAndItsSwitchesAreGone() throws {
        let folder = Self.root.appendingPathComponent("Sources/DeviceHubProApp", isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                for word in ["PhysicalViewBanner", "PhysicalViewControls", "PhysicalControlRow", "PhysicalAudioButton"]
                where trimmed.contains(word) {
                    offenders.append("\(url.lastPathComponent): \(word)")
                }
                if trimmed.contains("Toggle(\"Live View\"") || trimmed.contains("Toggle(\"Auto-refresh\"")
                    || trimmed.contains("Toggle(\"Control\"") {
                    offenders.append("\(url.lastPathComponent): a switch over the phone")
                }
            }
        }
        XCTAssertEqual(offenders, [])
    }

    /// The team is detected, never typed, so Settings
    /// has no Team ID field and says nothing about one.
    func testSettingsHasNoTeamIDField() throws {
        let settings = try source("Sources/DeviceHubProApp/SettingsView.swift")
        XCTAssertFalse(settings.localizedCaseInsensitiveContains("Team ID"))
        XCTAssertFalse(settings.contains("physicalControlTeamID"))
        XCTAssertFalse(settings.contains("TeamIDField"))
    }

    func testNoViewOnlyNoteRemainsOnTheStaticPanel() throws {
        let views = try source("Sources/DeviceHubProApp/Apple/PhysicalDeviceViews.swift")
        XCTAssertFalse(views.contains("The screen is view only: nothing you do here reaches the device."))
        XCTAssertFalse(views.contains("Set your Development Team ID in Settings"), "the team note is Control's reason, not a permanent card")
    }

    /// The stage draws the small status line where the banner was.
    func testTheStageDrawsTheStatusLine() throws {
        let stage = try source("Sources/DeviceHubProApp/DeviceStageView.swift")
        XCTAssertTrue(stage.contains("PhysicalStatusLineView(session: physical)"))
    }

    /// The physical pill has no Record button: the record button is drawn only
    /// where the pill is not a physical iPhone's.
    func testThePhysicalPillHasNoRecordButton() throws {
        let pill = try source("Sources/DeviceHubProApp/EmulatorControlsView.swift")
        XCTAssertTrue(pill.contains("if !isPhysicalPill {"))
        let recordIndex = try XCTUnwrap(pill.range(of: "accessibilityTitle: workspace.media.isRecording ? \"Stop Recording\" : \"Record\""))
        let guardIndex = try XCTUnwrap(pill.range(of: "if !isPhysicalPill {"))
        XCTAssertLessThan(guardIndex.lowerBound, recordIndex.lowerBound, "the guard opens before the Record button")
    }
}

/// The pill's states for a physical iPhone: Home and Rotate are on whenever
/// Control could start (a team is set) or already runs, and off with the
/// reason otherwise.
@MainActor
final class PhysicalPillStateTests: XCTestCase {
    func testTheStaticRuleIsTheReason() {
        typealias Pill = DeviceControlPill
        XCTAssertTrue(Pill.physicalActionAvailable(reason: nil))
        XCTAssertFalse(Pill.physicalActionAvailable(reason: PhysicalControlError.noTeam.description))
    }

    @MainActor
    private final class Harness {
        let live = PhysicalLiveViewController(provider: TestCaptureProvider())
        let control = PhysicalControlController()
        var entry: ApplePhysicalEntry?
        var team: String? = "ABCDE12345"
        var session: PhysicalScreenshotSession?
        var testControl = TestControl()
        var factoryCalls = 0
        var factoryError: PhysicalControlError?
        var reported: (@Sendable (PhysicalControlSnapshot) -> Void)?
        var preferences: (live: Bool, refresh: Bool) = (true, true)
        var screenshots = 0
        var setPoses: [SimulatorDevicePose] = []

        init(entry: ApplePhysicalEntry) {
            self.entry = entry
            session = PhysicalScreenshotSession(hardwareUDID: PhysicalFixtures.udid, interval: .milliseconds(20)) { _ in }
            session?.frames.put(Frame(data: Data(count: 117 * 253 * 4), width: 117, height: 253, seq: 1))
            control.softMessageDuration = .milliseconds(60)
            control.readyPollInterval = .milliseconds(5)
            control.setDeviceOrientation = { [unowned self] _, pose in self.setPoses.append(pose) }
            control.inputs = { [unowned self] in PhysicalControlController.Inputs(entry: self.entry, team: self.team) }
            control.viewSession = { [unowned self] _ in self.session }
            control.makeControl = { [unowned self] _, _, onChange in
                self.factoryCalls += 1
                self.reported = onChange
                if let error = self.factoryError { throw error }
                return self.testControl
            }
            live.control = control
            live.inputs = { [unowned self] in
                PhysicalLiveViewController.Inputs(
                    entry: self.entry,
                    liveViewOn: self.preferences.live,
                    autoRefreshOn: self.preferences.refresh
                )
            }
            live.setLiveViewPreference = { [unowned self] on in self.preferences.live = on }
            live.setAutoRefreshPreference = { [unowned self] on in self.preferences.refresh = on }
            live.captureScreenshot = { [unowned self] in self.screenshots += 1 }
        }
    }

    private func makeHarness() throws -> Harness {
        let harness = Harness(entry: try PhysicalFixtures.entry())
        addTeardownBlock { @MainActor in _ = harness.control.stop(quit: false) }
        return harness
    }

    // MARK: The switches (menu API)

    /// The switches keep their old defaults and preferences: Live View and
    /// Auto-refresh on, Control off; the setters write the preferences.
    func testTheSwitchesReadAndWriteThePreferences() throws {
        let h = try makeHarness()
        XCTAssertTrue(h.live.liveViewEnabled)
        XCTAssertTrue(h.live.autoRefreshEnabled)
        XCTAssertFalse(h.live.controlEnabled)

        h.live.setLiveView(false)
        h.live.setAutoRefresh(false)
        XCTAssertEqual(h.preferences.live, false)
        XCTAssertEqual(h.preferences.refresh, false)
        XCTAssertFalse(h.live.liveViewEnabled)
        XCTAssertFalse(h.live.autoRefreshEnabled)
        h.live.setLiveView(true)
        XCTAssertTrue(h.live.liveViewEnabled)
        XCTAssertFalse(h.live.autoRefreshEnabled, "the two are independent")
    }

    func testTheRealPreferencesKeepTheirDefaults() {
        let preferences = AppPreferences(defaults: .scratch())
        XCTAssertTrue(preferences.physicalLiveViewEnabled)
        XCTAssertTrue(preferences.physicalAutoRefreshEnabled)
        preferences.setPhysicalLiveViewEnabled(false)
        XCTAssertFalse(preferences.physicalLiveViewEnabled)
        XCTAssertTrue(preferences.physicalAutoRefreshEnabled)
    }

    func testControlAvailabilityIsNilWhenItCanStartAndTheReasonOtherwise() throws {
        let h = try makeHarness()
        XCTAssertNil(h.live.controlAvailability)

        h.team = nil
        XCTAssertNil(h.live.controlAvailability, "the team is resolved when the runner is needed")

        h.session = nil
        XCTAssertNotNil(h.live.controlAvailability, "no picture, no Control")

        // Without a control controller there is a reason too.
        h.live.control = nil
        XCTAssertNotNil(h.live.controlAvailability)
    }

    func testSetControlTurnsItOnAndOff() async throws {
        let h = try makeHarness()
        h.live.setControl(true)
        XCTAssertTrue(h.live.controlEnabled, "starting counts as on")
        await expectEventually { h.control.isReady }
        XCTAssertNil(h.live.controlAvailability, "on: nothing is unavailable")
        h.live.setControl(false)
        XCTAssertFalse(h.live.controlEnabled)
    }

    // MARK: On demand

    /// Home without Control on starts it, then presses.
    func testHomeStartsControlOnDemandThenPresses() async throws {
        let h = try makeHarness()
        XCTAssertFalse(h.control.isOn)
        h.live.pressHome()
        await expectEventually { h.testControl.calls.contains(.press(.home)) }
        XCTAssertEqual(h.factoryCalls, 1)
        XCTAssertTrue(h.control.isReady)
        // The next Home does not start it again.
        h.live.pressHome()
        await expectEventually { h.testControl.calls.filter { $0 == .press(.home) }.count == 2 }
        XCTAssertEqual(h.factoryCalls, 1)
    }

    func testRotateTurnsThroughDevicectlWithoutStartingControl() async throws {
        let h = try makeHarness()
        h.live.rotate(left: true)
        await expectEventually { h.setPoses == [.landscapeLeft] }
        XCTAssertEqual(h.factoryCalls, 0, "no runner")
        XCTAssertFalse(h.control.isOn)
        XCTAssertTrue(h.testControl.calls.isEmpty)

        h.live.rotate(left: false)
        await expectEventually { h.setPoses == [.landscapeLeft, .portrait] }
        XCTAssertNil(h.live.rotationAvailability)
    }

    /// Without any team (none stored, none detected) the runner never starts and
    /// nothing is pressed; the reason is the status line's message.
    func testWithoutATeamNothingStartsAndTheReasonShows() async throws {
        let h = try makeHarness()
        h.team = nil
        h.live.pressHome()
        await expectEventually { h.control.message == PhysicalControlError.noTeam.description }
        XCTAssertEqual(h.factoryCalls, 0)
        XCTAssertTrue(h.testControl.calls.isEmpty)
    }

    /// Control that fails to start (no Xcode, no profile) runs no action.
    func testAFailedStartRunsNoAction() async throws {
        let h = try makeHarness()
        h.factoryError = .launchFailed("Xcode was not found")
        h.live.pressHome()
        await expectEventually { h.control.message != nil }
        XCTAssertFalse(h.control.isOn)
        XCTAssertTrue(h.testControl.calls.isEmpty)
        XCTAssertTrue(h.control.message?.contains("Xcode was not found") == true)
    }

    /// The status line shows Control starting while an on-demand action waits for it.
    func testTheStatusLineSeesControlStartingOnDemand() async throws {
        let h = try makeHarness()
        let gate = OpenControlGate()
        h.testControl.startGate = { await gate.wait() }
        h.live.pressHome()
        await expectEventually { h.control.progressText != nil }
        let starting = PhysicalStatusLine.make(
            viewKind: .screenshots,
            cadence: "about every 1.5 s",
            controlIsReady: h.control.isReady,
            controlProgress: h.control.progressText,
            controlMessage: h.control.message,
            planNote: nil,
            offersCameraSettings: false,
            audioNote: nil
        )
        XCTAssertEqual(starting.entries.first?.kind, .progress)
        XCTAssertTrue(h.testControl.calls.isEmpty, "nothing is pressed before the runner answers")
        await gate.open()
        await expectEventually { h.testControl.calls.contains(.press(.home)) }
    }

    // MARK: Siri and the App Switcher

    func testSiriAndTheAppSwitcherGoThroughTheRunner() async throws {
        let h = try makeHarness()
        h.live.activateSiri()
        await expectEventually { h.testControl.calls.contains(.siri(nil)) }
        h.live.showAppSwitcher()
        await expectEventually { h.testControl.calls.contains(.appSwitcher) }
        XCTAssertEqual(h.factoryCalls, 1, "the first one started Control on demand")
    }

    /// A phone without the Siri route says so, softly, and Control stays on.
    func testUnsupportedSiriIsASoftNote() async throws {
        let h = try makeHarness()
        await turnOn(h)
        h.testControl.actionFailure = .unsupported("Siri is not available through the input runner on this iPhone.")
        h.live.activateSiri()
        await expectEventually { h.control.message?.contains("Siri is not available") == true }
        XCTAssertTrue(h.control.isReady, "Control stays on")
    }

    func testTakeScreenshotUsesTheWorkspacesCaptureFlow() async throws {
        let h = try makeHarness()
        h.live.takeScreenshot()
        await expectEventually { h.screenshots == 1 }
        XCTAssertEqual(h.factoryCalls, 0, "a screenshot never starts Control")
    }

    private func turnOn(_ h: Harness) async {
        h.control.setOn(true)
        await expectEventually { h.control.isReady }
    }
}

private actor OpenControlGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
