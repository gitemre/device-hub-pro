import Foundation
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// A fake control session for the app's tests: it never starts a process,
/// opens a socket or reaches a device.
final class TestControl: PhysicalControlling, @unchecked Sendable {
    enum Call: Hashable {
        case tap(CGPoint)
        case swipe(CGPoint, CGPoint)
        case type(String, String)
        case press(PhysicalControlButton)
        case setOrientation(PhysicalControlOrientation)
        case siri(String?)
        case appSwitcher
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _starts = 0
    private var _stops = 0
    private var _terminations = 0
    private var _orientation: PhysicalControlOrientation = .portrait
    /// Thrown by `start()`.
    var startError: PhysicalControlError?
    /// Awaited by `start()` before it returns.
    var startGate: (@Sendable () async -> Void)?
    /// Thrown by the next action, once.
    var actionFailure: PhysicalControlError?
    var foreground: String? = "com.apple.mobilenotes"

    var calls: [Call] { lock.withLock { _calls } }
    var starts: Int { lock.withLock { _starts } }
    var stops: Int { lock.withLock { _stops } }
    var terminations: Int { lock.withLock { _terminations } }
    var orientationNow: PhysicalControlOrientation {
        get { lock.withLock { _orientation } }
        set { lock.withLock { _orientation = newValue } }
    }

    private func record(_ call: Call) throws {
        lock.withLock { _calls.append(call) }
        let failure = lock.withLock { () -> PhysicalControlError? in
            defer { actionFailure = nil }
            return actionFailure
        }
        if let failure { throw failure }
    }

    func start() async throws {
        lock.withLock { _starts += 1 }
        await startGate?()
        if let startError { throw startError }
    }

    func stop() async { lock.withLock { _stops += 1 } }
    func terminateNow() { lock.withLock { _terminations += 1 } }
    func snapshot() async -> PhysicalControlSnapshot { PhysicalControlSnapshot(state: .ready, orientation: orientationNow) }
    func portraitSize() async -> CGSize? { CGSize(width: 390, height: 844) }
    func tap(_ point: CGPoint) async throws { try record(.tap(point)) }
    func swipe(from: CGPoint, to: CGPoint, duration: TimeInterval) async throws { try record(.swipe(from, to)) }
    func type(_ text: String, bundleID: String) async throws { try record(.type(text, bundleID)) }
    func press(_ button: PhysicalControlButton) async throws { try record(.press(button)) }
    func setOrientation(_ orientation: PhysicalControlOrientation) async throws -> PhysicalControlOrientation {
        try record(.setOrientation(orientation))
        orientationNow = orientation
        return orientation
    }
    func orientation() async throws -> PhysicalControlOrientation { orientationNow }
    func activateSiri(text: String?) async throws { try record(.siri(text)) }
    func showAppSwitcher() async throws { try record(.appSwitcher) }
    func foreground(ids: [String]) async throws -> [String] { foreground.map { [$0] } ?? [] }
    func foregroundApp() async throws -> String? { foreground }
}

/// A fake fast input session for the app's tests: records what is sent and
/// never starts a helper.
final class TestFast: FastInputControlling, @unchecked Sendable {
    enum Call: Equatable { case down, move, up, edge, button(PhysicalControlButton), hid(Int, Int, Bool), appSwitcher, keys([Int]) }
    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _stops = 0
    private var _terminations = 0
    /// Calls that throw.
    var failOn: Set<String> = []
    var calls: [Call] { lock.withLock { _calls } }
    var stops: Int { lock.withLock { _stops } }
    var terminations: Int { lock.withLock { _terminations } }

    private func record(_ call: Call, _ name: String) throws {
        lock.withLock { _calls.append(call) }
        if failOn.contains(name) { throw FastInputError.commandFailed(code: 1, message: "scripted") }
    }
    func down(_ point: CGPoint) async throws { try record(.down, "down") }
    func move(_ point: CGPoint) async throws { try record(.move, "move") }
    func up(_ point: CGPoint) async throws { try record(.up, "up") }
    func edge(_ phase: FastInputEdgePhase, _ point: CGPoint) async throws { try record(.edge, "edge") }
    func button(_ button: PhysicalControlButton) async throws { try record(.button(button), "button") }
    func hid(page: Int, usage: Int, down: Bool) async throws { try record(.hid(page, usage, down), "hid") }
    func appSwitcher() async throws { try record(.appSwitcher, "appSwitcher") }
    func key(usage: Int, action: FastInputKeyAction) async throws {}
    func keys(_ usages: [Int]) async throws { try record(.keys(usages), "keys") }
    func stop() async { lock.withLock { _stops += 1 } }
    func terminateNow() { lock.withLock { _terminations += 1 } }
}

private actor OpenGate {
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

/// "Control this iPhone" in the app: off by default,
/// only for an enabled, Ready device with a team and a showing view; turning
/// it on routes the view's input to the control session; any failure falls
/// back to view only with the reason; it stops with the view.
@MainActor
final class PhysicalControlControllerTests: XCTestCase {
    @MainActor
    private final class Harness {
        let controller = PhysicalControlController()
        var entry: ApplePhysicalEntry?
        var team: String? = "ABCDE12345"
        var session: PhysicalScreenshotSession?
        let control = TestControl()
        var factoryCalls: [(udid: String, team: String)] = []
        var factoryError: PhysicalControlError?
        var reportChange: (@Sendable (PhysicalControlSnapshot) -> Void)?
        var poses: [(turns: Int, animated: Bool)] = []
        var capabilities: [Bool] = []
        var flashes: [String] = []
        /// The poses `devicectl device orientation set` was asked for, and the reads of `get`.
        var setPoses: [SimulatorDevicePose] = []
        var getReads = 0
        var fastEnabled = false
        var fastError: FastInputError?
        var fastMakes = 0
        let fast = TestFast()

        init(entry: ApplePhysicalEntry?) {
            self.entry = entry
            session = Harness.makeSession()
            controller.softMessageDuration = .milliseconds(60)
            controller.inputs = { [unowned self] in
                PhysicalControlController.Inputs(entry: self.entry, team: self.team)
            }
            controller.viewSession = { [unowned self] _ in self.session }
            controller.makeControl = { [unowned self] entry, team, onChange in
                factoryCalls.append((entry.udid, team))
                reportChange = onChange
                if let factoryError { throw factoryError }
                return control
            }
            controller.settlePose = { [unowned self] turns, animated in poses.append((turns, animated)) }
            controller.setControlCapabilities = { [unowned self] on in capabilities.append(on) }
            controller.flash = { [unowned self] message in flashes.append(message) }
            controller.deviceOrientation = { [unowned self] _ in getReads += 1; return .portrait }
            controller.setDeviceOrientation = { [unowned self] _, pose in setPoses.append(pose) }
            controller.fastInputEnabled = { [unowned self] in fastEnabled }
            controller.makeFastInput = { [unowned self] _ in
                fastMakes += 1
                if let fastError { throw fastError }
                return fast
            }
        }

        static func makeSession() -> PhysicalScreenshotSession {
            let session = PhysicalScreenshotSession(hardwareUDID: PhysicalFixtures.udid, interval: .milliseconds(20)) { _ in }
            // A portrait picture of the phone's shape.
            session.frames.put(Frame(data: Data(count: 117 * 253 * 4), width: 117, height: 253, seq: 1))
            return session
        }
    }

    private func makeHarness(enabled: Bool = true, entry: ApplePhysicalEntry? = nil) throws -> Harness {
        let harness = Harness(entry: try entry ?? PhysicalFixtures.entry(enabled: enabled))
        addTeardownBlock { @MainActor in _ = harness.controller.stop(quit: false) }
        return harness
    }

    private func turnOn(_ harness: Harness, file: StaticString = #filePath, line: UInt = #line) async {
        harness.controller.setOn(true)
        await expectEventually({ harness.controller.isReady }, file: file, line: line)
    }

    // MARK: Automatic fast input

    func testFastInputStartsByItselfWhenTheViewShowsAndNeedsNoTeamOrRunner() async throws {
        let harness = try makeHarness()
        harness.team = nil
        harness.fastEnabled = true
        XCTAssertFalse(harness.controller.isOn, "nothing starts before the view is synced")
        harness.controller.syncWithView()
        await expectEventually { harness.controller.isReady }
        XCTAssertEqual(harness.fastMakes, 1)
        XCTAssertNotNil(harness.controller.fastInput)
        XCTAssertTrue(harness.factoryCalls.isEmpty, "the runner never starts on its own")
        XCTAssertEqual(harness.capabilities, [true])
        let session = try XCTUnwrap(harness.session)
        session.send(contacts: [TouchCommand(phase: .down, x: 58, y: 126)])
        session.send(contacts: [TouchCommand(phase: .up, x: 58, y: 126)])
        await expectEventually { harness.fast.calls.count == 2 }
        // More syncs change nothing.
        harness.controller.syncWithView()
        XCTAssertEqual(harness.fastMakes, 1)
    }

    func testNothingStartsWithFastInputOffOrForADeviceThatIsNotSelectedEnabledReadyShowing() async throws {
        let harness = try makeHarness()
        harness.controller.syncWithView()
        XCTAssertFalse(harness.controller.isOn)
        harness.fastEnabled = true
        harness.session = nil
        harness.controller.syncWithView()
        XCTAssertFalse(harness.controller.isOn, "no live view yet")
        harness.session = Harness.makeSession()
        harness.entry = nil
        harness.controller.syncWithView()
        XCTAssertFalse(harness.controller.isOn, "no selection")
        let disabled = try makeHarness(enabled: false)
        disabled.fastEnabled = true
        disabled.controller.syncWithView()
        XCTAssertFalse(disabled.controller.isOn)
        XCTAssertEqual(harness.fastMakes + disabled.fastMakes, 0)
    }

    func testTheAutomaticSessionStopsWhenTheViewEndsOrTheDeviceIsDeselected() async throws {
        let harness = try makeHarness()
        harness.fastEnabled = true
        harness.controller.syncWithView()
        await expectEventually { harness.controller.isReady }
        harness.entry = nil
        harness.controller.syncWithView()
        XCTAssertFalse(harness.controller.isOn)
        await expectEventually { harness.fast.stops == 1 }
        harness.entry = try PhysicalFixtures.entry(enabled: true)
        harness.controller.syncWithView()
        await expectEventually { harness.controller.isReady }
        await harness.controller.viewSessionEnded(quit: false)?.value
        XCTAssertFalse(harness.controller.isOn)
        XCTAssertEqual(harness.fast.stops, 2)
    }

    func testAnAutomaticStartFailureIsSaidInlineNotRetriedAndRetryWorks() async throws {
        let harness = try makeHarness()
        harness.team = nil
        harness.fastEnabled = true
        harness.fastError = .tunnelNotConnected
        harness.controller.syncWithView()
        await expectEventually { harness.controller.inputFailure != nil }
        XCTAssertTrue(harness.controller.inputFailure?.contains(FastInputError.tunnelNotConnected.description) == true)
        XCTAssertFalse(harness.controller.isOn)
        XCTAssertTrue(harness.factoryCalls.isEmpty, "no runner fallback")
        XCTAssertEqual(harness.fastMakes, 1)
        harness.controller.syncWithView()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(harness.fastMakes, 1, "not retried by itself")
        harness.fastError = nil
        harness.controller.retryInput()
        await expectEventually { harness.controller.isReady }
        XCTAssertNil(harness.controller.inputFailure)
        XCTAssertEqual(harness.fastMakes, 2)
    }

    func testAnAutomaticFailureIsForgottenWhenTheDeviceLeaves() async throws {
        let harness = try makeHarness()
        harness.fastEnabled = true
        harness.fastError = .tunnelNotConnected
        harness.controller.syncWithView()
        await expectEventually { harness.controller.inputFailure != nil }
        harness.entry = nil
        harness.controller.syncWithView()
        XCTAssertNil(harness.controller.inputFailure)
    }

    func testAMidSessionFastInputErrorWithoutATeamSaysViewOnlyWithRetry() async throws {
        let harness = try makeHarness()
        harness.team = nil
        harness.fastEnabled = true
        harness.fast.failOn = ["move"]
        harness.controller.syncWithView()
        await expectEventually { harness.controller.isReady }
        let session = try XCTUnwrap(harness.session)
        session.send(contacts: [TouchCommand(phase: .down, x: 58, y: 126)])
        session.send(contacts: [TouchCommand(phase: .move, x: 60, y: 130)])
        await expectEventually { harness.controller.inputFailure != nil }
        XCTAssertFalse(harness.controller.isOn)
        XCTAssertTrue(harness.flashes.contains("iPhone input stopped: view only"))
    }

    // MARK: Fast input

    func testFastInputIsNotStartedUnlessTheSettingIsOn() async throws {
        let harness = try makeHarness()
        await turnOn(harness)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(harness.fastMakes, 0)
        XCTAssertNil(harness.controller.fastInput)
        let session = try XCTUnwrap(harness.session)
        session.send(contacts: [TouchCommand(phase: .down, x: 58, y: 126)])
        session.send(contacts: [TouchCommand(phase: .up, x: 58, y: 126)])
        await expectEventually { !harness.control.calls.isEmpty }
        XCTAssertTrue(harness.fast.calls.isEmpty)
    }

    func testFastInputCarriesControlWithNoRunner() async throws {
        let harness = try makeHarness()
        harness.fastEnabled = true
        await turnOn(harness)
        XCTAssertNotNil(harness.controller.fastInput)
        XCTAssertEqual(harness.fastMakes, 1)
        XCTAssertEqual(harness.control.starts, 0, "the runner does not start with Control")
        XCTAssertTrue(harness.factoryCalls.isEmpty)
        let session = try XCTUnwrap(harness.session)
        session.send(contacts: [TouchCommand(phase: .down, x: 58, y: 126)])
        session.send(contacts: [TouchCommand(phase: .move, x: 60, y: 130)])
        session.send(contacts: [TouchCommand(phase: .up, x: 60, y: 130)])
        session.send(button: .home, isDown: true)
        await expectEventually { harness.fast.calls.count == 4 }
        XCTAssertEqual(harness.fast.calls, [.down, .move, .up, .hid(0x0C, 0x40, true)])
        // The menus' Home, the App Switcher and typing go the same way.
        harness.controller.press(.volumeUp)
        await expectEventually { harness.fast.calls.last == .button(.volumeUp) }
        harness.controller.showAppSwitcher()
        await expectEventually { harness.fast.calls.last == .appSwitcher }
        XCTAssertTrue(session.acceptsPhysicalKeys)
        session.send(physical: .key(code: 0, isDown: true, modifiers: 0))
        session.send(physical: .key(code: 0, isDown: false, modifiers: 0))
        await expectEventually { harness.fast.calls.suffix(2) == [.keys([0x04]), .keys([])] }
        XCTAssertTrue(harness.control.calls.isEmpty)
        XCTAssertTrue(harness.factoryCalls.isEmpty, "still no runner")
    }

    func testTheChromeButtonsStartFastInputOnDemandWhenTheAutomaticStartFailed() async throws {
        let harness = try makeHarness()
        harness.controller.syncWithView()
        XCTAssertFalse(harness.controller.chromeButtonsAvailable, "fast input is off")
        harness.fastEnabled = true
        harness.fastError = .tunnelNotConnected
        harness.controller.syncWithView()
        await expectEventually { harness.controller.inputFailure != nil }
        XCTAssertEqual(harness.fastMakes, 1, "the automatic start failed")
        XCTAssertTrue(harness.controller.chromeButtonsAvailable)
        XCTAssertFalse(harness.controller.isOn)
        harness.fastError = nil
        let session = try XCTUnwrap(harness.session)
        XCTAssertTrue(session.acceptsButtons)
        session.send(button: .side, isDown: true)
        session.send(button: .side, isDown: false)
        await expectEventually { harness.fast.calls.count == 2 }
        XCTAssertEqual(harness.fast.calls, [.hid(0x0C, 0x30, true), .hid(0x0C, 0x30, false)])
        XCTAssertEqual(harness.fastMakes, 2)
        XCTAssertEqual(harness.control.starts, 0, "no runner, no Control")
        // The menu's Home is a click of the same path.
        harness.controller.pressFromMenu(.home)
        await expectEventually { harness.fast.calls.count == 4 }
        XCTAssertEqual(harness.fast.calls.suffix(2), [.hid(0x0C, 0x40, true), .hid(0x0C, 0x40, false)])
        XCTAssertEqual(harness.fastMakes, 2)
        // The view ending ends the on-demand session.
        let ended = harness.controller.viewSessionEnded(quit: false)
        await ended?.value
        XCTAssertFalse(harness.controller.chromeButtonsAvailable)
        await expectEventually { harness.fast.stops == 1 }
    }

    func testTheRunnerStartsOnDemandForSiriButNotForRotate() async throws {
        let harness = try makeHarness()
        harness.fastEnabled = true
        await turnOn(harness)
        XCTAssertEqual(harness.control.starts, 0)
        await harness.controller.rotate(.left)?.value
        XCTAssertEqual(harness.setPoses, [.landscapeLeft])
        XCTAssertEqual(harness.control.starts, 0, "Rotate goes through devicectl, not the runner")
        XCTAssertTrue(harness.factoryCalls.isEmpty)
        harness.controller.activateSiri()
        await expectEventually { harness.control.calls.contains(.siri(nil)) }
        XCTAssertEqual(harness.control.starts, 1, "started once, then reused")
        XCTAssertTrue(harness.controller.isReady)
    }

    func testTypingFallsBackToTheRunnerWhenFastInputFailsOnAKey() async throws {
        let harness = try makeHarness()
        harness.fastEnabled = true
        harness.fast.failOn = ["keys"]
        await turnOn(harness)
        try XCTUnwrap(harness.session).send(physical: .key(code: 0, isDown: true, modifiers: 0))
        await expectEventually { harness.controller.fastInput == nil }
        try XCTUnwrap(harness.session).send(.text("a"))
        await expectEventually { harness.control.calls.contains(.type("a", "com.apple.mobilenotes")) }
        XCTAssertNil(harness.controller.fastInput)
    }

    func testARunnerThatCannotStartOnDemandLeavesFastInputOn() async throws {
        let harness = try makeHarness()
        harness.fastEnabled = true
        await turnOn(harness)
        harness.factoryError = .launchFailed("scripted")
        harness.controller.activateSiri()
        await expectEventually { harness.controller.message != nil }
        XCTAssertTrue(harness.controller.isReady, "Control stays on")
        XCTAssertNotNil(harness.controller.fastInput)
    }

    func testFastInputEndsWithControl() async throws {
        let harness = try makeHarness()
        harness.fastEnabled = true
        await turnOn(harness)
        await expectEventually { harness.controller.fastInput != nil }
        let task = harness.controller.stop(quit: false)
        await task?.value
        XCTAssertEqual(harness.fast.stops, 1)
        XCTAssertNil(harness.controller.fastInput)
    }

    func testQuitEndsFastInputAtOnce() async throws {
        let harness = try makeHarness()
        harness.fastEnabled = true
        await turnOn(harness)
        await expectEventually { harness.controller.fastInput != nil }
        let task = harness.controller.stop(quit: true)
        XCTAssertEqual(harness.fast.terminations, 1)
        await task?.value
    }

    func testAFastInputStartFailureSaysSoOnceAndTheRunnerCarriesOn() async throws {
        let harness = try makeHarness()
        harness.fastEnabled = true
        harness.fastError = .tunnelNotConnected
        await turnOn(harness)
        await expectEventually { harness.flashes.contains("Fast input unavailable, using the standard input") }
        XCTAssertTrue(harness.controller.isReady, "Control stays on")
        XCTAssertEqual(harness.controller.message, FastInputError.tunnelNotConnected.description)
        XCTAssertNil(harness.controller.fastInput)
        let session = try XCTUnwrap(harness.session)
        session.send(contacts: [TouchCommand(phase: .down, x: 58, y: 126)])
        session.send(contacts: [TouchCommand(phase: .up, x: 58, y: 126)])
        await expectEventually { !harness.control.calls.isEmpty }
    }

    func testAFastInputErrorMidSessionStopsItAndFallsBackToTheRunner() async throws {
        let harness = try makeHarness()
        harness.fastEnabled = true
        harness.fast.failOn = ["move"]
        await turnOn(harness)
        await expectEventually { harness.controller.fastInput != nil }
        let session = try XCTUnwrap(harness.session)
        session.send(contacts: [TouchCommand(phase: .down, x: 58, y: 126)])
        session.send(contacts: [TouchCommand(phase: .move, x: 60, y: 130)])
        session.send(contacts: [TouchCommand(phase: .up, x: 60, y: 130)])
        await expectEventually { harness.flashes.contains("Fast input stopped, using the standard input") }
        await expectEventually { harness.fast.stops == 1 }
        XCTAssertNil(harness.controller.fastInput)
        XCTAssertTrue(harness.controller.isReady)
        XCTAssertEqual(harness.flashes.filter { $0.hasPrefix("Fast input stopped") }.count, 1)
        session.send(contacts: [TouchCommand(phase: .down, x: 58, y: 126)])
        session.send(contacts: [TouchCommand(phase: .up, x: 58, y: 126)])
        await expectEventually { !harness.control.calls.isEmpty }
        guard case .tap? = harness.control.calls.first else { return XCTFail("\(harness.control.calls)") }
    }

    // MARK: Off by default, and when it is unavailable

    func testControlIsOffByDefaultAndMakesNothing() throws {
        let harness = try makeHarness()
        XCTAssertEqual(harness.controller.phase, .off)
        XCTAssertFalse(harness.controller.isOn)
        XCTAssertFalse(harness.controller.isReady)
        XCTAssertFalse(harness.controller.isBusy)
        XCTAssertNil(harness.controller.message)
        XCTAssertEqual(harness.factoryCalls.count, 0)
        XCTAssertFalse(try XCTUnwrap(harness.session).inputRoute.isActive, "the view drops every input")
        XCTAssertFalse(try XCTUnwrap(harness.session).acceptsButtons)
        XCTAssertNil(harness.controller.unavailableReason, "an enabled Ready device with a team and a view can be controlled")
    }

    func testAnUnavailableReasonNamesWhatIsMissing() throws {
        var harness = try makeHarness()
        harness.team = nil
        XCTAssertNil(harness.controller.unavailableReason, "the team is resolved when the runner is needed, not before")

        harness = try self.makeHarness()
        harness.session = nil
        XCTAssertNotNil(harness.controller.unavailableReason)
        XCTAssertTrue(try XCTUnwrap(harness.controller.unavailableReason).contains("live view"))

        // A device the user did not enable.
        harness = try self.makeHarness(enabled: false)
        XCTAssertNotNil(harness.controller.unavailableReason)

        // Not Ready (unpaired).
        let unpaired = try PhysicalFixtures.entry(enabled: true) { entry in
            entry["connectionProperties"] = (entry["connectionProperties"] as? [String: Any] ?? [:]).merging(["pairingState": "unpaired"]) { $1 }
            var properties = entry["properties"] as? [String: Any] ?? [:]
            var connection = properties["connection"] as? [String: Any] ?? [:]
            connection["pairingState"] = "unpaired"
            properties["connection"] = connection
            entry["properties"] = properties
        }
        harness = try self.makeHarness(entry: unpaired)
        XCTAssertNotEqual(unpaired.state, .ready)
        XCTAssertNotNil(harness.controller.unavailableReason)

        // No device selected.
        harness = try self.makeHarness()
        harness.entry = nil
        XCTAssertNotNil(harness.controller.unavailableReason)
    }

    func testTurningOnWithoutAnyTeamSaysWhyAndBuildsNothing() async throws {
        let harness = try makeHarness()
        harness.team = nil
        harness.controller.setOn(true)
        await expectEventually { harness.controller.message == PhysicalControlError.noTeam.description }
        XCTAssertFalse(harness.controller.isOn)
        XCTAssertEqual(harness.factoryCalls.count, 0, "no runner, no build")
        XCTAssertFalse(harness.capabilities.contains(true), "the control capabilities never turned on")
    }

    func testTheRunnerAsksTheResolverForItsTeamAtTheMomentItIsNeeded() async throws {
        let harness = try makeHarness()
        harness.team = nil
        var asked = 0
        harness.controller.teamResolver = { asked += 1; return "ZZZZZ99999" }
        XCTAssertEqual(asked, 0, "nothing resolves on appearance")
        await turnOn(harness)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(harness.factoryCalls.first?.team, "ZZZZZ99999")
    }

    func testADisabledDeviceGetsNoControlAtAll() throws {
        let harness = try makeHarness(enabled: false)
        harness.controller.setOn(true)
        XCTAssertEqual(harness.controller.phase, .off)
        XCTAssertEqual(harness.factoryCalls.count, 0)
        XCTAssertFalse(try XCTUnwrap(harness.session).inputRoute.isActive)
    }

    // MARK: Turning it on

    func testTurningOnStartsTheRunnerAndRoutesTheViewsInput() async throws {
        let harness = try makeHarness()
        harness.controller.setOn(true)
        XCTAssertEqual(harness.controller.phase, .preparing("Preparing the input runner…"), "progress shows at once")
        XCTAssertTrue(harness.controller.isOn)
        XCTAssertNotNil(harness.controller.progressText)
        XCTAssertFalse(harness.controller.isReady)

        await expectEventually { harness.controller.isReady }
        XCTAssertEqual(harness.factoryCalls.count, 1)
        XCTAssertEqual(harness.factoryCalls.first?.udid, PhysicalFixtures.udid)
        XCTAssertEqual(harness.factoryCalls.first?.team, "ABCDE12345")
        XCTAssertEqual(harness.control.starts, 1)
        XCTAssertEqual(harness.capabilities, [true], "the workspace gains touch, keyboard, rotate and buttons")
        let session = try XCTUnwrap(harness.session)
        XCTAssertTrue(session.inputRoute.isActive)
        XCTAssertTrue(session.acceptsButtons, "the Apple chrome's buttons are offered")
        XCTAssertNil(harness.controller.progressText)

        // A click on the picture is one tap, mapped to the phone's points.
        session.send(contacts: [TouchCommand(phase: .down, x: 58, y: 126)])
        session.send(contacts: [TouchCommand(phase: .up, x: 58, y: 126)])
        await expectEventually { !harness.control.calls.isEmpty }
        guard case .tap(let point)? = harness.control.calls.first else { return XCTFail("\(harness.control.calls)") }
        XCTAssertEqual(point.x, 58 / 117 * 390, accuracy: 0.01)
        XCTAssertEqual(point.y, 126 / 253 * 844, accuracy: 0.01)

        // A typed key reaches the phone as one type call.
        session.send(.text("a"))
        await expectEventually({ harness.control.calls.contains(.type("a", "com.apple.mobilenotes")) })

        // A drag is one swipe on mouse-up.
        session.send(contacts: [TouchCommand(phase: .down, x: 58, y: 200)])
        session.send(contacts: [TouchCommand(phase: .move, x: 58, y: 100)])
        session.send(contacts: [TouchCommand(phase: .up, x: 58, y: 50)])
        await expectEventually({ harness.control.calls.contains { if case .swipe = $0 { return true } else { return false } } })

        // The chrome's Home and volume buttons.
        session.send(button: .home, isDown: true)
        session.send(button: .volumeUp, isDown: true)
        await expectEventually({ harness.control.calls.contains(.press(.volumeUp)) })
        XCTAssertTrue(harness.control.calls.contains(.press(.home)))
    }

    func testTurningItOnTwiceMakesOneSession() async throws {
        let harness = try makeHarness()
        harness.controller.setOn(true)
        harness.controller.setOn(true)
        await expectEventually { harness.controller.isReady }
        XCTAssertEqual(harness.factoryCalls.count, 1)
        XCTAssertEqual(harness.control.starts, 1)
    }

    func testTurningItOffStopsTheRunnerAndDropsTheRoute() async throws {
        let harness = try makeHarness()
        await turnOn(harness)
        let session = try XCTUnwrap(harness.session)
        let stop = harness.controller.end(reason: nil)
        XCTAssertEqual(harness.controller.phase, .off)
        XCTAssertFalse(session.inputRoute.isActive, "view only again")
        XCTAssertEqual(harness.capabilities, [true, false])
        await stop?.value
        XCTAssertEqual(harness.control.stops, 1)
        XCTAssertNil(harness.controller.message)

        // And on again: a new session.
        await turnOn(harness)
        XCTAssertEqual(harness.factoryCalls.count, 2)
    }

    func testTurningItOffBeforeItStartedStopsTheSessionAndNeverRoutes() async throws {
        let harness = try makeHarness()
        let gate = OpenGate()
        harness.control.startGate = { await gate.wait() }
        harness.controller.setOn(true)
        await expectEventually { harness.control.starts == 1 }
        let stop = harness.controller.end(reason: nil)
        await gate.open()
        await stop?.value
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(harness.controller.phase, .off)
        XCTAssertFalse(try XCTUnwrap(harness.session).inputRoute.isActive, "a start that finishes late routes nothing")
        XCTAssertEqual(harness.control.stops, 1)
        XCTAssertEqual(harness.capabilities.filter { $0 }.count, 0)
    }

    // MARK: The session's own reports

    func testTheSessionsProgressAndBusyFlagShowInTheBanner() async throws {
        let harness = try makeHarness()
        let gate = OpenGate()
        harness.control.startGate = { await gate.wait() }
        harness.controller.setOn(true)
        await expectEventually { harness.reportChange != nil && harness.control.starts == 1 }
        let report = try XCTUnwrap(harness.reportChange)
        report(PhysicalControlSnapshot(state: .preparing("Building the iPhone input runner…"), revision: 1))
        await expectEventually { harness.controller.phase == .preparing("Building the iPhone input runner…") }
        report(PhysicalControlSnapshot(state: .starting("Installing the input runner on the iPhone…"), revision: 2))
        await expectEventually { harness.controller.phase == .starting("Installing the input runner on the iPhone…") }
        XCTAssertEqual(harness.controller.progressText, "Installing the input runner on the iPhone…")
        await gate.open()
        await expectEventually { harness.controller.isReady }

        report(PhysicalControlSnapshot(state: .ready, isBusy: true, revision: 3))
        await expectEventually { harness.controller.isBusy }
        report(PhysicalControlSnapshot(state: .ready, isBusy: false, revision: 4))
        await expectEventually { !harness.controller.isBusy }
        // An older report that arrives late is ignored.
        report(PhysicalControlSnapshot(state: .ready, isBusy: true, revision: 2))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(harness.controller.isBusy)
    }

    // MARK: Failure: back to view only, with the reason

    func testAStartThatFailsTurnsControlOffAndSaysWhy() async throws {
        let harness = try makeHarness()
        harness.control.startError = .startTimedOut(seconds: 30)
        harness.controller.setOn(true)
        await expectEventually { harness.controller.phase == .off && harness.controller.message != nil }
        XCTAssertEqual(harness.controller.message, PhysicalControlError.startTimedOut(seconds: 30).description)
        XCTAssertTrue(harness.controller.message?.contains("Is the iPhone unlocked?") == true)
        XCTAssertFalse(try XCTUnwrap(harness.session).inputRoute.isActive)
        XCTAssertEqual(harness.flashes, ["iPhone control stopped: view only"])
        await expectEventually { harness.control.stops == 1 }
    }

    func testAFactoryThatCannotMakeASessionSaysWhy() async throws {
        let harness = try makeHarness()
        harness.factoryError = .runnerSourcesMissing
        harness.controller.setOn(true)
        await expectEventually { harness.controller.phase == .off && harness.controller.message != nil }
        XCTAssertEqual(harness.controller.message, PhysicalControlError.runnerSourcesMissing.description)
        XCTAssertEqual(harness.control.starts, 0)
    }

    func testAFailedSnapshotTurnsControlOff() async throws {
        let harness = try makeHarness()
        await turnOn(harness)
        let report = try XCTUnwrap(harness.reportChange)
        report(PhysicalControlSnapshot(state: .failed(.runnerExited("boom")), revision: 100))
        await expectEventually { harness.controller.phase == .off }
        XCTAssertTrue(harness.controller.message?.contains("boom") == true)
        XCTAssertFalse(try XCTUnwrap(harness.session).inputRoute.isActive)
        XCTAssertEqual(harness.capabilities, [true, false])
    }

    func testAnActionThatFailsTurnsControlOffAndASoftOneDoesNot() async throws {
        let harness = try makeHarness()
        await turnOn(harness)
        let session = try XCTUnwrap(harness.session)

        // Busy: a note, Control stays on, and the note fades.
        harness.control.actionFailure = .busy
        session.send(contacts: [TouchCommand(phase: .down, x: 10, y: 10)])
        session.send(contacts: [TouchCommand(phase: .up, x: 10, y: 10)])
        await expectEventually { harness.controller.message == PhysicalControlError.busy.description }
        XCTAssertTrue(harness.controller.isReady)
        await expectEventually { harness.controller.message == nil }

        // The runner refused the tap: view only again.
        harness.control.actionFailure = .actionFailed(status: 500, message: "boom")
        session.send(contacts: [TouchCommand(phase: .down, x: 10, y: 10)])
        session.send(contacts: [TouchCommand(phase: .up, x: 10, y: 10)])
        await expectEventually { harness.controller.phase == .off }
        XCTAssertTrue(harness.controller.message?.contains("boom") == true)
        XCTAssertFalse(session.inputRoute.isActive)
        await expectEventually { harness.control.stops == 1 }
    }

    func testNoAppInTheForegroundSaysTapATextFieldFirst() async throws {
        let harness = try makeHarness()
        harness.control.foreground = nil
        await turnOn(harness)
        try XCTUnwrap(harness.session).send(.text("x"))
        await expectEventually({ harness.controller.message == "Tap a text field first" }, file: #filePath, line: #line)
        XCTAssertTrue(harness.controller.isReady, "Control stays on")
        XCTAssertEqual(harness.control.calls, [], "nothing was typed")
    }

    // MARK: It stops with the view

    func testItEndsWhenTheViewSessionIsGone() async throws {
        let harness = try makeHarness()
        await turnOn(harness)
        harness.session = nil
        harness.controller.syncWithView()
        XCTAssertEqual(harness.controller.phase, .off)
        await expectEventually { harness.control.stops == 1 }
        XCTAssertNil(harness.controller.message, "the view ended; Control has nothing to complain about")
    }

    func testItEndsWhenTheDeviceIsDisabledNotReadyOrAnotherIsSelected() async throws {
        for change in ["disabled", "deselected", "other"] {
            let harness = try makeHarness()
            await turnOn(harness)
            switch change {
            case "disabled": harness.entry = try PhysicalFixtures.entry(enabled: false)
            case "deselected": harness.entry = nil
            default:
                // Another listed phone (the app's "every physical device" listing).
                var document = try XCTUnwrap(JSONSerialization.jsonObject(with: try PhysicalFixtures.data("devicectl-list-devices.json")) as? [String: Any])
                var result = try XCTUnwrap(document["result"] as? [String: Any])
                var entries = try XCTUnwrap(result["devices"] as? [[String: Any]])
                let index = try XCTUnwrap(entries.firstIndex {
                    ($0["hardwareProperties"] as? [String: Any])?["reality"] as? String == "physical"
                })
                var entry = entries[index]
                var legacy = entry["hardwareProperties"] as? [String: Any] ?? [:]
                legacy["udid"] = "11111111-1111111111111111"
                entry["hardwareProperties"] = legacy
                var properties = entry["properties"] as? [String: Any] ?? [:]
                var hardware = properties["hardware"] as? [String: Any] ?? [:]
                hardware["udid"] = "11111111-1111111111111111"
                properties["hardware"] = hardware
                entry["properties"] = properties
                entries[index] = entry
                result["devices"] = entries
                document["result"] = result
                let edited = try JSONSerialization.data(withJSONObject: document)
                let listed = try ApplePhysicalDeviceLister.devices(fromListJSON: edited, optIn: .everyPhysicalDevice)
                let other = try XCTUnwrap(listed.first { $0.hardwareUDID == "11111111-1111111111111111" })
                harness.entry = ApplePhysicalEntry(device: other, isEnabled: true)
            }
            harness.controller.syncWithView()
            XCTAssertEqual(harness.controller.phase, .off, change)
            XCTAssertFalse(try XCTUnwrap(harness.session).inputRoute.isActive, change)
            await expectEventually { harness.control.stops == 1 }
        }
    }

    func testAReplacementSessionOfTheSameDeviceKeepsControl() async throws {
        let harness = try makeHarness()
        await turnOn(harness)
        let old = try XCTUnwrap(harness.session)
        let replacement = Harness.makeSession()
        harness.session = replacement
        harness.controller.syncWithView()
        XCTAssertEqual(harness.controller.phase, .on)
        XCTAssertTrue(replacement.inputRoute.isActive, "Control moved to the new picture")
        XCTAssertFalse(old.inputRoute.isActive)
        XCTAssertEqual(harness.control.stops, 0)

        // The new session's clicks reach the phone.
        replacement.send(contacts: [TouchCommand(phase: .down, x: 5, y: 5)])
        replacement.send(contacts: [TouchCommand(phase: .up, x: 5, y: 5)])
        await expectEventually { !harness.control.calls.isEmpty }
    }

    func testTheViewEndingStopsControlAndQuitTerminatesTheRunnerAtOnce() async throws {
        let harness = try makeHarness()
        await turnOn(harness)
        let stop = harness.controller.viewSessionEnded(quit: true)
        XCTAssertEqual(harness.controller.phase, .off)
        XCTAssertEqual(harness.control.terminations, 1, "quit interrupts the child synchronously")
        await stop?.value
        XCTAssertEqual(harness.control.stops, 1, "and stops it politely as well")
        XCTAssertNotNil(harness.controller.takeStopTask(), "quit waits for the stop")
        XCTAssertNil(harness.controller.takeStopTask())

        // Without Control on, ending the view is a no-op.
        XCTAssertNil(harness.controller.viewSessionEnded(quit: true))
    }

    func testAnOrdinaryEndDoesNotTerminate() async throws {
        let harness = try makeHarness()
        await turnOn(harness)
        await harness.controller.viewSessionEnded(quit: false)?.value
        XCTAssertEqual(harness.control.terminations, 0)
        XCTAssertEqual(harness.control.stops, 1)
    }

    // MARK: Home, volume, rotation

    func testHomeAndVolumeGoThroughTheRunnerOnlyWhileItIsReady() async throws {
        let harness = try makeHarness()
        harness.controller.press(.home)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(harness.control.calls, [], "off: nothing")
        await turnOn(harness)
        harness.controller.press(.home)
        harness.controller.press(.volumeDown)
        await expectEventually { harness.control.calls.count == 2 }
        XCTAssertEqual(Set(harness.control.calls), [.press(.home), .press(.volumeDown)])
    }

    /// Rotate goes through `devicectl device orientation set`, with Control off and no
    /// runner: from portrait left reaches landscape left, then upside down (the
    /// frame turns half a turn, an iPhone included), then landscape right; a view that does not track the interface has its
    /// chrome turned to the pose asked for.
    func testRotateUsesDevicectlWithoutControlAndReachesUpsideDown() async throws {
        let harness = try makeHarness()
        XCTAssertFalse(harness.controller.isOn)
        XCTAssertNil(harness.controller.rotationUnavailableReason)

        await harness.controller.rotate(.left)?.value
        await harness.controller.rotate(.left)?.value
        await harness.controller.rotate(.left)?.value
        XCTAssertEqual(harness.setPoses, [.landscapeLeft, .portraitUpsideDown, .landscapeRight])
        XCTAssertEqual(harness.poses.map(\.turns), [1, 2, 3])
        XCTAssertEqual(harness.getReads, 1, "only the first turn reads the pose; later ones use the last asked")

        await harness.controller.rotate(.right)?.value
        await harness.controller.rotate(.right)?.value
        await harness.controller.rotate(.right)?.value
        XCTAssertEqual(harness.setPoses.suffix(3), [.portraitUpsideDown, .landscapeLeft, .portrait])
        XCTAssertTrue(harness.control.calls.isEmpty)
        XCTAssertEqual(harness.control.starts, 0)
        XCTAssertTrue(harness.factoryCalls.isEmpty, "no runner")
    }

    func testRotateNeedsAnEnabledReadyPhoneOnly() async throws {
        let off = try makeHarness(enabled: false)
        XCTAssertNotNil(off.controller.rotationUnavailableReason)
        XCTAssertNil(off.controller.rotate(.left))
        XCTAssertTrue(off.setPoses.isEmpty)
        let noTeam = try makeHarness()
        noTeam.team = nil
        XCTAssertNil(noTeam.controller.rotationUnavailableReason, "no Development Team needed")
        await noTeam.controller.rotate(.right)?.value
        XCTAssertEqual(noTeam.setPoses, [.landscapeRight])
    }

    private final class RotateWorld: @unchecked Sendable {
        private let lock = NSLock()
        private var _shot = CGSize(width: 1170, height: 2532)
        var shot: CGSize { get { lock.withLock { _shot } } set { lock.withLock { _shot = newValue } } }
    }

    private struct NoLease: FastInputLease {
        func start() async throws {}
        func stop() async {}
        func terminateNow() {}
    }

    /// A native session whose tracker reads `world`'s screenshot size; never started.
    private func trackingSession(_ world: RotateWorld) -> PhysicalNativeMirrorSession {
        let tracker = PhysicalInterfaceOrientationTracker(
            reads: .init(deviceOrientation: { .portrait }, screenshotSize: { world.shot }),
            sleep: { _ in }
        )
        let endpoint = NativeMirrorEndpoint(
            coreDeviceIdentifier: "00000000-0000-4000-8000-000000000001", interface: "utun4",
            hostAddress: "fd00::2", deviceAddress: "fd00::1", productType: "iPhone13,2"
        )
        return PhysicalNativeMirrorSession(
            hardwareUDID: PhysicalFixtures.udid, endpointProvider: { endpoint }, lease: NoLease(),
            makeStream: { _, _, _ in fatalError("never started") }, orientationTracker: tracker, sleep: { _ in }
        )
    }

    /// The native view's picture is the panel turned by the stage pose, so the chrome's
    /// texture turn follows that pose: upside down is a half turn, which the picture's
    /// shape alone cannot tell (it drew upright in a half-turned frame, found live on
    /// 2026-10-01).
    func testTheNativeViewTextureTurnsFollowTheStagePoseUpsideDownIncluded() async throws {
        let world = RotateWorld()
        let session = trackingSession(world)
        let frame = try AppleChromeStageTests.iPhone17ProFrame()
        let turns = AppleChromeDeviceView.textureTurns(frame: frame, session: session, devicePose: StagePoseAnimator())

        await session.noteTurn(to: .portraitUpsideDown)
        XCTAssertEqual(turns(1206, 2622), 2)
        world.shot = CGSize(width: 2532, height: 1170)
        await session.noteTurn(to: .landscapeRight)
        XCTAssertEqual(turns(2622, 1206), 3)
        world.shot = CGSize(width: 1170, height: 2532)
        await session.noteTurn(to: .portrait)
        XCTAssertEqual(turns(1206, 2622), 0)
        // A frame whose shape does not match the pose yet (in flight) keeps the shape's answer.
        await session.noteTurn(to: .landscapeLeft)
        XCTAssertEqual(turns(1206, 2622), 0)
    }

    /// With the native view the next pose comes from the tracked stage pose (the device
    /// pose), which turns at once (no 1 s poll, no screenshot wait), and a portrait-only
    /// interface changes nothing about the frame (Device Hub 27.0).
    func testRotateFromLandscapeUsesTheTrackedStagePoseAndTurnsItAtOnce() async throws {
        let world = RotateWorld()
        let session = trackingSession(world)
        world.shot = CGSize(width: 2532, height: 1170)
        await session.noteTurn(to: .landscapeLeft)
        XCTAssertEqual(session.stagePose, .landscapeLeft)
        XCTAssertTrue(session.interfaceIsLandscape)

        let harness = try makeHarness()
        harness.controller.viewSession = { _ in session }
        // Right from landscape left goes to portrait (left would skip upside down to landscape right).
        world.shot = CGSize(width: 1170, height: 2532)
        await harness.controller.rotate(.right)?.value
        XCTAssertEqual(harness.setPoses, [.portrait])
        XCTAssertEqual(harness.getReads, 0, "the tracker knew the pose")
        XCTAssertEqual(session.stagePose, .portrait, "turned without waiting for the poll")
        XCTAssertNil(harness.controller.message)
        XCTAssertEqual(harness.controller.knownChromeTurns, 0)
    }

    /// The iPhone 12 home screen never rotates: the frame still turns with the device pose
    /// and nothing says "This app stays in portrait" any more.
    func testAPortraitOnlyInterfaceStillTurnsTheFrameAndSaysNothing() async throws {
        let world = RotateWorld()
        let session = trackingSession(world)
        let harness = try makeHarness()
        harness.controller.viewSession = { _ in session }
        await harness.controller.rotate(.left)?.value
        XCTAssertEqual(harness.setPoses, [.landscapeLeft])
        XCTAssertNil(harness.controller.message)
        XCTAssertEqual(session.stagePose, .landscapeLeft)
        XCTAssertFalse(session.interfaceIsLandscape, "the interface stayed portrait: only the band decision cares")
        XCTAssertEqual(harness.controller.knownChromeTurns, 1)
        await harness.controller.rotate(.left)?.value
        XCTAssertEqual(session.stagePose, .portraitUpsideDown)
        XCTAssertEqual(harness.controller.knownChromeTurns, 2)
        XCTAssertNil(harness.controller.message)
    }

    func testARotateThatFailsSaysSoSoftly() async throws {
        let harness = try makeHarness()
        harness.controller.setDeviceOrientation = { _, _ in throw PhysicalControlError.notReady }
        await harness.controller.rotate(.left)?.value
        XCTAssertEqual(harness.controller.message, PhysicalControlError.notReady.description)
        XCTAssertFalse(harness.controller.isOn)
    }

    func testTheOrientationTheSessionReportsTurnsTheChrome() async throws {
        let harness = try makeHarness()
        await turnOn(harness)
        harness.poses.removeAll()
        let report = try XCTUnwrap(harness.reportChange)
        report(PhysicalControlSnapshot(state: .ready, orientation: .landscapeRight, revision: 50))
        await expectEventually { harness.poses.contains { $0.turns == 3 } }
        // A flat phone says nothing about the screen.
        harness.poses.removeAll()
        report(PhysicalControlSnapshot(state: .ready, orientation: .faceUp, revision: 51))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(harness.poses.count, 0)
    }

    func testTheKnownTurnsAreOnlyKnownWhileControlIsOn() async throws {
        let harness = try makeHarness()
        XCTAssertNil(harness.controller.knownChromeTurns)
        await turnOn(harness)
        try XCTUnwrap(harness.reportChange)(PhysicalControlSnapshot(state: .ready, orientation: .landscapeLeft, revision: 60))
        await expectEventually { harness.controller.knownChromeTurns == 1 }
        harness.controller.end(reason: nil)
        XCTAssertNil(harness.controller.knownChromeTurns)
    }
}

// MARK: - Preferences

@MainActor
final class PhysicalControlPreferencesTests: XCTestCase {
    func testTheTeamIDIsEmptyUntilTheUserTypesOneAndPersists() {
        let defaults = UserDefaults.scratch()
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.physicalControlTeamID, "")
        XCTAssertNil(preferences.validPhysicalControlTeamID)

        preferences.setPhysicalControlTeamID("  abcde12345 \n")
        XCTAssertEqual(preferences.physicalControlTeamID, "ABCDE12345", "trimmed and upper-cased")
        XCTAssertEqual(preferences.validPhysicalControlTeamID, "ABCDE12345")
        XCTAssertEqual(AppPreferences(defaults: defaults).physicalControlTeamID, "ABCDE12345")
    }

    func testOnlyTenLettersAndDigitsAreATeamID() {
        let preferences = AppPreferences(defaults: .scratch())
        for text in ["ABC", "ABCDE1234", "ABCDE123456", "ABCDE-2345", "ABCDE 2345", "ÄBCDE12345"] {
            preferences.setPhysicalControlTeamID(text)
            XCTAssertNil(preferences.validPhysicalControlTeamID, text)
        }
        preferences.setPhysicalControlTeamID("A1B2C3D4E5")
        XCTAssertEqual(preferences.validPhysicalControlTeamID, "A1B2C3D4E5")
        preferences.setPhysicalControlTeamID("")
        XCTAssertNil(preferences.validPhysicalControlTeamID)
    }
}

// MARK: - The workspace

/// The workspace's part: Rotate, the capabilities, and the ends of the view.
/// 
@MainActor
final class PhysicalControlWorkspaceTests: XCTestCase {
    private func beginPhysicalView(_ model: AppModel) throws -> PhysicalScreenshotSession {
        let session = PhysicalControlControllerTests_makeSession()
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

    private var recordedPoses: [SimulatorDevicePose] = []

    private func wire(_ model: AppModel, session: PhysicalScreenshotSession, control: TestControl) throws {
        let entry = try PhysicalFixtures.entry()
        let physical = model.workspace.physicalControl
        physical.inputs = { PhysicalControlController.Inputs(entry: entry, team: "ABCDE12345") }
        physical.viewSession = { _ in session }
        physical.makeControl = { _, _, _ in control }
        physical.setDeviceOrientation = { [unowned self] _, pose in self.recordedPoses.append(pose) }
        addTeardownBlock { @MainActor in _ = physical.stop(quit: false) }
    }

    func testControlIsOffAndTheViewOnlyRulesHoldWithoutIt() async throws {
        let model = AppModel.testing()
        let session = try beginPhysicalView(model)
        XCTAssertEqual(model.workspace.physicalControl.phase, .off)
        XCTAssertEqual(model.workspace.context.capabilities, [.mirror, .screenshot, .record])
        XCTAssertFalse(session.acceptsButtons)
        XCTAssertFalse(model.workspace.mirror.supportsChromeButtons)
        // Rotate turns nothing.
        await model.workspace.rotateDevice(.left)
        XCTAssertEqual(model.workspace.physicalControl.phase, .off)
    }

    func testOnTheWorkspaceGainsTheControlCapabilitiesAndRotateGoesThroughDevicectl() async throws {
        let model = AppModel.testing()
        // Fast input is on by default (and would start by itself); this is the runner route.
        model.preferences.setPhysicalFastInput(false)
        let session = try beginPhysicalView(model)
        let control = TestControl()
        try wire(model, session: session, control: control)

        model.workspace.physicalControl.setOn(true)
        await expectEventually { model.workspace.physicalControl.isReady }
        let capabilities = model.workspace.context.capabilities
        for capability: DeviceCapabilities in [.touch, .keyboard, .rotate, .hardwareButtons, .mirror, .screenshot, .record] {
            XCTAssertTrue(capabilities.contains(capability), "\(capability)")
        }
        XCTAssertTrue(model.workspace.context.isPhysicalView)
        XCTAssertNil(model.workspace.context.simulatorDevice, "still no simulator path")
        XCTAssertTrue(model.workspace.mirror.supportsChromeButtons)

        await model.workspace.rotateDevice(.left)
        await expectEventually { recordedPoses == [.landscapeLeft] }
        XCTAssertTrue(control.calls.isEmpty, "rotation does not use the runner")

        // Turning it off puts the capabilities back.
        await model.workspace.physicalControl.end(reason: nil)?.value
        XCTAssertEqual(model.workspace.context.capabilities, [.mirror, .screenshot, .record])
        XCTAssertFalse(model.workspace.mirror.supportsChromeButtons)
    }

    func testTheViewEndingEndsControlBeforeTheSessionStops() async throws {
        let model = AppModel.testing()
        let session = try beginPhysicalView(model)
        let control = TestControl()
        try wire(model, session: session, control: control)
        model.workspace.physicalControl.setOn(true)
        await expectEventually { model.workspace.physicalControl.isReady }

        model.workspace.tearDownMirror(cause: .windowClosed)
        XCTAssertEqual(model.workspace.physicalControl.phase, .off)
        XCTAssertFalse(session.inputRoute.isActive)
        await expectEventually { control.stops == 1 }
        XCTAssertEqual(control.terminations, 0)
    }

    func testQuitInterruptsTheRunnerAndItsStopIsAwaitedByTheQuitTeardown() async throws {
        let model = AppModel.testing()
        let session = try beginPhysicalView(model)
        let control = TestControl()
        try wire(model, session: session, control: control)
        model.workspace.physicalControl.setOn(true)
        await expectEventually { model.workspace.physicalControl.isReady }

        let stop = model.workspace.beginQuitTeardown()
        XCTAssertEqual(control.terminations, 1)
        XCTAssertNotNil(stop, "quit waits for the runner's stop")
        await stop?.value
        XCTAssertEqual(control.stops, 1)
    }

    func testAReplacedSessionOfTheSameDeviceKeepsControlAndItsCapabilities() async throws {
        let model = AppModel.testing()
        let first = try beginPhysicalView(model)
        let control = TestControl()
        try wire(model, session: first, control: control)
        model.workspace.physicalControl.setOn(true)
        await expectEventually { model.workspace.physicalControl.isReady }

        // The plan replaces the session (a permission granted, say).
        let second = PhysicalControlControllerTests_makeSession()
        addTeardownBlock { second.stop() }
        model.workspace.physicalControl.viewSession = { _ in second }
        let began = model.workspace.beginMirrorSession(
            second,
            device: .physicalApple(PhysicalFixtures.udid),
            port: nil,
            capabilities: PhysicalLiveViewController.capabilities
        )
        XCTAssertTrue(began)
        XCTAssertTrue(model.workspace.physicalControl.isReady, "a replaced session does not end Control")
        XCTAssertTrue(model.workspace.context.capabilities.contains(.touch), "the capabilities are kept")
        model.workspace.physicalControl.syncWithView()
        XCTAssertTrue(second.inputRoute.isActive)
        XCTAssertFalse(first.inputRoute.isActive)
        XCTAssertEqual(control.stops, 0)
    }
}

@MainActor
private func PhysicalControlControllerTests_makeSession() -> PhysicalScreenshotSession {
    let session = PhysicalScreenshotSession(hardwareUDID: PhysicalFixtures.udid, interval: .milliseconds(20)) { _ in }
    session.frames.put(Frame(data: Data(count: 117 * 253 * 4), width: 117, height: 253, seq: 1))
    return session
}

// MARK: - Source guards

final class PhysicalControlSourceGuardTests: XCTestCase {
    private func lines() throws -> [(file: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DeviceHubProApp", isDirectory: true)
        var lines: [(String, String)] = []
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
                let code = String(line)
                if code.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                lines.append((url.lastPathComponent, code))
            }
        }
        return lines
    }

    /// The app reaches the runner only through the inventory's client: the
    /// live factory is called in one place, after `client(for:)`.
    func testTheRunnerSessionIsMadeInOnePlaceThroughTheInventoryClient() throws {
        let makers = try lines().filter { $0.text.contains("PhysicalControlSession.live(") }.map(\.file)
        XCTAssertEqual(makers, ["DeviceWorkspace.swift"])
        let text = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/DeviceHubProApp/DeviceWorkspace.swift"),
            encoding: .utf8
        )
        let make = try XCTUnwrap(text.range(of: "PhysicalControlSession.live("))
        let client = try XCTUnwrap(text.range(of: "physicalInventory.client(for: entry.udid)"))
        XCTAssertLessThan(client.lowerBound, make.lowerBound, "the inventory's client (enabled, paired, connected) comes first")
    }

    /// No file of the app builds a process or names the runner's launcher.
    func testTheAppNeverLaunchesTheRunnerItself() throws {
        for line in try lines() {
            XCTAssertFalse(line.text.contains("XcodebuildRunnerLauncher"), line.file)
            XCTAssertFalse(line.text.contains("test-without-building"), line.file)
        }
    }
}
