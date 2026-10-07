import CoreGraphics
import Foundation
import XCTest
@testable import DeviceHubProKit

/// The input router's fast path: contacts go live as
/// down, move, up in order with waiting moves coalesced, the Home and volume
/// buttons go the same way, physical Mac keys go live as keyboard reports, landscape touches go live mapped to the panel when the orientation is known,
/// and the first fast error clears the path and hands everything back to the
/// runner.
final class FastInputRouterTests: XCTestCase {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [PhysicalControlInputRouter.ActionEvent] = []
        private var _failures: [FastInputError] = []
        private var _fatal: [PhysicalControlError] = []
        var events: [PhysicalControlInputRouter.ActionEvent] { lock.withLock { _events } }
        var failures: [FastInputError] { lock.withLock { _failures } }
        var fatal: [PhysicalControlError] { lock.withLock { _fatal } }
        func add(_ event: PhysicalControlInputRouter.ActionEvent) { lock.withLock { _events.append(event) } }
        func add(_ failure: FastInputError) { lock.withLock { _failures.append(failure) } }
        func add(fatal error: PhysicalControlError) { lock.withLock { _fatal.append(error) } }
    }

    private struct Rig {
        let router: PhysicalControlInputRouter
        let control: FakeControl
        let fast: FakeFastSender
        let log: Log
    }

    private func rig(frame: CGSize = CGSize(width: 1170, height: 2532), fast: FakeFastSender = FakeFastSender(), useFast: Bool = true, pose: PhysicalControlOrientation? = nil, interfaceLandscape: (@Sendable () -> Bool)? = nil, schedule: PhysicalControlInputRouter.Scheduler? = nil, now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> Rig {
        let log = Log()
        let control = FakeControl()
        let router = PhysicalControlInputRouter(
            control: control,
            frameSize: { frame },
            schedule: schedule ?? PhysicalControlInputRouter.defaultScheduler,
            now: now,
            onFailure: { log.add(fatal: $0) },
            onSoftFailure: { _ in },
            onActionEvent: { log.add($0) },
            onFastInputFailure: { log.add($0) },
            orientation: { pose },
            interfaceLandscape: interfaceLandscape
        )
        if useFast { router.setFastInput(fast) }
        return Rig(router: router, control: control, fast: fast, log: log)
    }

    private func touch(_ phase: TouchCommand.Phase, _ x: Int32, _ y: Int32) -> TouchCommand {
        TouchCommand(phase: phase, x: x, y: y)
    }

    /// A scheduler that runs work only when the test says so.
    private final class ManualScheduler: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(id: Int, delay: TimeInterval, work: @Sendable () -> Void)] = []
        private var next = 0
        private(set) var delays: [TimeInterval] = []
        var scheduler: PhysicalControlInputRouter.Scheduler {
            { [self] delay, work in
                let id = lock.withLock { () -> Int in
                    next += 1; items.append((next, delay, work)); delays.append(delay); return next
                }
                return { [self] in lock.withLock { items.removeAll { $0.id == id } } }
            }
        }
        var pending: Int { lock.withLock { items.count } }
        /// Runs what is pending now (work scheduled by it stays pending).
        func fire() {
            let due = lock.withLock { () -> [@Sendable () -> Void] in
                let due = items.map(\.work); items.removeAll(); return due
            }
            due.forEach { $0() }
        }
    }

    // MARK: Resting finger

    func testAnEdgeContactRepeatsItsLastPointAsEdgeMovesWhileItRests() async {
        let clock = ManualScheduler()
        let rig = rig(schedule: clock.scheduler)
        rig.router.receive(touch(.down, 585, 2520))
        rig.router.receive(touch(.move, 585, 1520))   // y 0.6004
        _ = await waitUntil { rig.fast.calls.count == 2 }
        XCTAssertEqual(clock.delays.first, 0.03)
        for round in 1...3 {
            clock.fire()
            let ok = await waitUntil { rig.fast.calls.count == 2 + round }
            XCTAssertTrue(ok, "\(rig.fast.calls)")
        }
        XCTAssertEqual(rig.fast.calls.map(kind), ["edge-down", "edge-move", "edge-move", "edge-move", "edge-move"])
        XCTAssertEqual(rig.fast.calls[1], rig.fast.calls[4], "the last point is repeated unchanged")
        rig.router.receive(touch(.up, 585, 1520))
        _ = await waitUntil { rig.fast.calls.count == 6 }
        XCTAssertEqual(rig.fast.calls.last.map(kind), "edge-up")
        XCTAssertEqual(clock.pending, 0, "up stops the repeater")
        clock.fire()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(rig.fast.calls.count, 6)
    }

    func testATouchRepeatsItsLastPointAsMovesAndStopsOnUp() async {
        let clock = ManualScheduler()
        let rig = rig(schedule: clock.scheduler)
        rig.router.receive(touch(.down, 585, 1266))
        _ = await waitUntil { rig.fast.calls.count == 1 }
        clock.fire()
        _ = await waitUntil { rig.fast.calls.count == 2 }
        rig.router.receive(touch(.move, 600, 1300))
        _ = await waitUntil { rig.fast.calls.count == 3 }
        clock.fire()
        _ = await waitUntil { rig.fast.calls.count == 4 }
        XCTAssertEqual(rig.fast.calls.map(kind), ["down", "move", "move", "move"])
        XCTAssertEqual(rig.fast.calls[2], rig.fast.calls[3])
        if case .down(let first) = rig.fast.calls[0], case .move(let rest) = rig.fast.calls[1] { XCTAssertEqual(first, rest) } else { XCTFail() }
        rig.router.receive(touch(.up, 600, 1300))
        _ = await waitUntil { rig.fast.calls.count == 5 }
        XCTAssertEqual(clock.pending, 0)
    }

    func testARepeatIsSkippedWhileASendIsStillRunning() async {
        let clock = ManualScheduler()
        let gate = FastInputGate()
        let fast = FakeFastSender()
        fast.gate = { await gate.wait() }
        let rig = rig(fast: fast, schedule: clock.scheduler)
        rig.router.receive(touch(.down, 585, 1266))
        _ = await waitUntil { fast.calls.count == 1 }   // held at the gate
        rig.router.receive(touch(.move, 600, 1300))      // waits in the queue
        for _ in 0..<5 { clock.fire() }
        await gate.open()
        _ = await waitUntil { fast.calls.count == 2 }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fast.calls.map(kind), ["down", "move"], "no repeat piled up behind the slow helper")
    }

    func testStoppingAndLosingTheFastPathStopTheRepeater() async {
        let clock = ManualScheduler()
        let rig = rig(schedule: clock.scheduler)
        rig.router.receive(touch(.down, 585, 1266))
        XCTAssertEqual(clock.pending, 1)
        rig.router.setFastInput(nil)
        XCTAssertEqual(clock.pending, 0)
        let other = self.rig(schedule: clock.scheduler)
        other.router.receive(touch(.down, 585, 1266))
        other.router.stop()
        XCTAssertEqual(clock.pending, 0)
        let third = self.rig(schedule: clock.scheduler)
        third.router.receive(touch(.down, 585, 1266))
        third.router.receive(contacts: [touch(.move, 1, 1), TouchCommand(phase: .move, x: 2, y: 2, id: 1)])
        XCTAssertEqual(clock.pending, 0, "a second finger cancels the gesture")
    }

    // MARK: Bottom edge

    func testAContactStartingInTheBottomBandGoesWholeAsEdgeEvents() async {
        let rig = rig()
        rig.router.receive(touch(.down, 585, 2520))   // y 0.995
        rig.router.receive(touch(.move, 585, 2000))   // leaves the band: still edge
        rig.router.receive(touch(.up, 585, 1400))
        let done = await waitUntil { rig.fast.calls.count == 3 }
        XCTAssertTrue(done, "\(rig.fast.calls)")
        XCTAssertEqual(rig.fast.calls.map(kind), ["edge-down", "edge-move", "edge-up"])
        XCTAssertTrue(rig.control.calls.isEmpty)
    }

    func testAContactAboveTheBandStaysATouchEvenWhenItDragsIntoIt() async {
        let rig = rig()
        rig.router.receive(touch(.down, 585, 2400))   // y 0.948
        rig.router.receive(touch(.move, 585, 2525))
        rig.router.receive(touch(.up, 585, 2525))
        let done = await waitUntil { rig.fast.calls.count == 3 }
        XCTAssertTrue(done)
        XCTAssertEqual(rig.fast.calls.map(kind), ["down", "move", "up"])
    }

    func testTheBandIsInclusiveAt98Percent() async {
        let rig = rig(frame: CGSize(width: 1000, height: 1000))
        rig.router.receive(touch(.down, 500, 980))
        rig.router.receive(touch(.up, 500, 980))
        let done = await waitUntil { rig.fast.calls.count == 2 }
        XCTAssertTrue(done)
        XCTAssertEqual(rig.fast.calls.map(kind), ["edge-down", "edge-up"])
    }

    // MARK: Landscape bottom edge (buttons)

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: TimeInterval = 100
        var now: TimeInterval { lock.withLock { t } }
        func advance(_ dt: TimeInterval) { lock.withLock { t += dt } }
    }

    private let landscape = CGSize(width: 2532, height: 1170)

    func testALandscapeBottomSwipeUpIsHomeAndSendsNoTouches() async {
        let clock = Clock()
        let rig = rig(frame: landscape, pose: .landscapeLeft, now: { clock.now })
        rig.router.receive(touch(.down, 1200, 1165))
        clock.advance(0.05); rig.router.receive(touch(.move, 1200, 1100))
        clock.advance(0.05); rig.router.receive(touch(.move, 1200, 1000))
        clock.advance(0.05); rig.router.receive(touch(.up, 1200, 1000))
        let done = await waitUntil { rig.fast.calls.count == 1 }
        XCTAssertTrue(done, "\(rig.fast.calls)")
        XCTAssertEqual(rig.fast.calls.map(kind), ["button"])
        XCTAssertEqual(rig.log.events.first, .pressed(CGPoint(x: 1200.0 / 2532, y: 1165.0 / 1170)))
        XCTAssertTrue(rig.control.calls.isEmpty)
    }

    func testALandscapeBottomSwipeThatRestsOpensTheAppSwitcher() async {
        let clock = Clock()
        let rig = rig(frame: landscape, pose: .landscapeRight, now: { clock.now })
        rig.router.receive(touch(.down, 1200, 1165))
        clock.advance(0.1); rig.router.receive(touch(.move, 1200, 700))
        clock.advance(0.6)
        rig.router.receive(touch(.up, 1200, 700))
        let done = await waitUntil { rig.fast.calls.count == 1 }
        XCTAssertTrue(done, "\(rig.fast.calls)")
        XCTAssertEqual(rig.fast.calls.map(kind), ["appSwitcher"])
    }

    func testALandscapeBottomTinyMoveDoesNothing() async {
        let clock = Clock()
        let rig = rig(frame: landscape, pose: .landscapeLeft, now: { clock.now })
        rig.router.receive(touch(.down, 1200, 1165))
        clock.advance(0.1); rig.router.receive(touch(.move, 1200, 1150))
        clock.advance(0.1); rig.router.receive(touch(.up, 1200, 1150))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(rig.fast.calls.isEmpty, "\(rig.fast.calls)")
    }

    func testALandscapeBottomContactDoesNotRunTheRestRepeater() async {
        let clock = ManualScheduler()
        let rig = rig(frame: landscape, pose: .landscapeLeft, schedule: clock.scheduler)
        rig.router.receive(touch(.down, 1200, 1165))
        rig.router.receive(touch(.move, 1200, 1000))
        XCTAssertEqual(clock.pending, 0)
        XCTAssertTrue(clock.delays.isEmpty)
    }

    func testPortraitBottomEdgeIsUnchangedWithAKnownPose() async {
        let rig = rig(pose: .portrait)
        rig.router.receive(touch(.down, 585, 2520))
        rig.router.receive(touch(.up, 585, 1400))
        let done = await waitUntil { rig.fast.calls.count == 2 }
        XCTAssertTrue(done)
        XCTAssertEqual(rig.fast.calls.map(kind), ["edge-down", "edge-up"])
    }

    func testWithoutFastInputABottomContactIsNotAnEdgeEvent() async {
        let rig = rig(useFast: false)
        rig.router.receive(touch(.down, 585, 2520))
        rig.router.receive(touch(.up, 585, 1400))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(rig.fast.calls.isEmpty)
    }

    func testWhenTheHelperHasNoDigitizerTheGestureContinuesAsTouchesAndLaterOnesStartAsTouches() async {
        let fast = FakeFastSender()
        fast.failure = .commandFailed(code: 7, message: "digitizer connection unavailable")
        fast.failWhen = { if case .edge = $0 { true } else { false } }
        let rig = rig(fast: fast)
        rig.router.receive(touch(.down, 585, 2520))
        rig.router.receive(touch(.move, 585, 2000))
        rig.router.receive(touch(.up, 585, 1400))
        let done = await waitUntil { fast.calls.count == 4 }
        XCTAssertTrue(done, "\(fast.calls)")
        XCTAssertEqual(fast.calls.map(kind), ["edge-down", "down", "move", "up"])
        XCTAssertTrue(rig.log.failures.isEmpty, "err 7 is not a fast-input failure")
        XCTAssertTrue(rig.router.isFastActive)
        rig.router.receive(touch(.down, 585, 2520))
        rig.router.receive(touch(.up, 585, 2520))
        let again = await waitUntil { fast.calls.count == 6 }
        XCTAssertTrue(again)
        XCTAssertEqual(fast.calls.suffix(2).map(kind), ["down", "up"])
    }

    // MARK: Order

    func testAContactGoesLiveAsDownMoveUpInOrder() async {
        let rig = rig()
        rig.router.receive(touch(.down, 585, 1266))
        rig.router.receive(touch(.move, 600, 1300))
        rig.router.receive(touch(.up, 640, 1400))
        let done = await waitUntil { rig.fast.calls.count == 3 }
        XCTAssertTrue(done, "\(rig.fast.calls)")
        XCTAssertEqual(rig.fast.calls.map(kind), ["down", "move", "up"])
        guard case .down(let first) = rig.fast.calls[0] else { return XCTFail() }
        XCTAssertEqual(first.x, 0.5, accuracy: 0.0001, "normalized to the frame")
        XCTAssertEqual(first.y, 0.5, accuracy: 0.0001)
        XCTAssertTrue(rig.control.calls.isEmpty, "the runner is not used, no tap or swipe classification")
    }

    func testMovesThatWaitAreCoalescedButTheOrderAndTheLastPositionStay() async {
        let gate = FastInputGate()
        let fast = FakeFastSender()
        fast.gate = { await gate.wait() }
        let rig = rig(fast: fast)
        rig.router.receive(touch(.down, 100, 100))
        _ = await waitUntil { fast.calls.count == 1 }   // the down is held at the gate
        for step in 1...50 { rig.router.receive(touch(.move, 100 + Int32(step), 100 + Int32(step))) }
        rig.router.receive(touch(.up, 150, 150))
        await gate.open()
        let done = await waitUntil { fast.calls.count == 3 }
        XCTAssertTrue(done, "\(fast.calls)")
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fast.calls.map(kind), ["down", "move", "up"], "fifty waiting moves became one")
        guard case .move(let point) = fast.calls[1] else { return XCTFail() }
        XCTAssertEqual(point.x, 150.0 / 1170.0, accuracy: 0.0001, "the latest position wins")
    }

    func testTheTouchFeedbackEventsFollowTheFastPath() async {
        let gate = FastInputGate()
        let fast = FakeFastSender()
        fast.gate = { await gate.wait() }
        let rig = rig(fast: fast)
        rig.router.receive(touch(.down, 585, 1266))
        rig.router.receive(touch(.up, 585, 1266))
        _ = await waitUntil { fast.calls.count >= 1 }
        // Pressed and accepted are local; finished waits for the up's answer.
        XCTAssertEqual(rig.log.events.count, 2)
        guard case .pressed = rig.log.events[0], case .accepted(let id, _) = rig.log.events[1] else { return XCTFail("\(rig.log.events)") }
        await gate.open()
        _ = await waitUntil { rig.log.events.count == 3 }
        XCTAssertEqual(rig.log.events.last, .finished(id: id))
    }

    // MARK: Buttons and what stays with the runner

    func testEveryChromeButtonGoesThroughFastInputAsItsDownAndUpEdgesInOrder() async {
        let rig = rig()
        let all: [(SimulatorHardwareButton, Int, Int)] = [
            (.home, 0x0C, 0x40), (.side, 0x0C, 0x30), (.volumeUp, 0x0C, 0xE9),
            (.volumeDown, 0x0C, 0xEA), (.siri, 0x0C, 0xCF), (.usage(page: 0x0B, usage: 0x2D), 0x0B, 0x2D),
        ]
        var expected: [FakeFastSender.Call] = []
        for (button, page, usage) in all {
            rig.router.receive(button: button, isDown: true)
            rig.router.receive(button: button, isDown: false)
            expected += [.hid(page, usage, true), .hid(page, usage, false)]
        }
        let total = expected.count
        let done = await waitUntil { rig.fast.calls.count == total }
        XCTAssertTrue(done)
        XCTAssertEqual(rig.fast.calls, expected)
        XCTAssertTrue(rig.control.calls.isEmpty)
    }

    func testAHeldButtonAndAComboKeepTheirOrderWithTouchesAndKeys() async {
        let rig = rig()
        rig.router.receive(button: .side, isDown: true)
        rig.router.receive(button: .volumeUp, isDown: true)
        rig.router.receive(physical: key(34, down: true))
        rig.router.receive(button: .volumeUp, isDown: false)
        rig.router.receive(button: .side, isDown: false)
        let done = await waitUntil { rig.fast.calls.count == 5 }
        XCTAssertTrue(done)
        XCTAssertEqual(rig.fast.calls, [.hid(0x0C, 0x30, true), .hid(0x0C, 0xE9, true), .keys([0x0C]),
                                        .hid(0x0C, 0xE9, false), .hid(0x0C, 0x30, false)])
    }

    func testAButtonStuckDownIsReleasedAfterTheHoldLimit() async {
        let clock = ManualScheduler()
        let rig = rig(schedule: clock.scheduler)
        rig.router.receive(button: .side, isDown: true)
        _ = await waitUntil { rig.fast.calls.count == 1 }
        XCTAssertEqual(clock.delays, [10], "the stuck-button timer")
        clock.fire()
        let released = await waitUntil { rig.fast.calls.count == 2 }
        XCTAssertTrue(released)
        XCTAssertEqual(rig.fast.calls, [.hid(0x0C, 0x30, true), .hid(0x0C, 0x30, false)])
    }

    func testAnUpCancelsTheStuckTimerAndStoppingTheRouterReleasesWhatIsHeld() async {
        let clock = ManualScheduler()
        let rig = rig(schedule: clock.scheduler)
        rig.router.receive(button: .home, isDown: true)
        rig.router.receive(button: .home, isDown: false)
        XCTAssertEqual(clock.pending, 0)
        rig.router.receive(button: .volumeDown, isDown: true)
        _ = await waitUntil { rig.fast.calls.count == 3 }
        rig.router.stop()
        XCTAssertEqual(clock.pending, 0, "the timer is cancelled")
        let released = await waitUntil { rig.fast.calls.count == 4 }
        XCTAssertTrue(released)
        XCTAssertEqual(rig.fast.calls.last, .hid(0x0C, 0xEA, false))
    }

    private func key(_ code: UInt16, down: Bool, _ modifiers: UInt8 = 0) -> PhysicalKeyEvent {
        .key(code: code, isDown: down, modifiers: modifiers)
    }

    func testPhysicalKeysGoLiveAsReportsInOrder() async {
        let rig = rig()
        rig.router.receive(physical: .modifiers(0x02))                 // Shift
        rig.router.receive(physical: key(34, down: true, 0x02))        // i
        rig.router.receive(physical: key(34, down: true, 0x02))        // AppKit repeat
        rig.router.receive(physical: key(34, down: false, 0x02))
        rig.router.receive(physical: .modifiers(0))
        let done = await waitUntil { rig.fast.calls.count == 4 }
        XCTAssertTrue(done)
        XCTAssertEqual(rig.fast.calls, [.keys([0xE1]), .keys([0xE1, 0x0C]), .keys([0xE1]), .keys([])])
        XCTAssertTrue(rig.control.calls.isEmpty, "the runner is not asked")
    }

    func testTheNextKeyReportWaitsForThePreviousOne() async {
        let fast = FakeFastSender()
        let gate = FastInputGate()
        fast.gate = { await gate.wait() }
        let rig = rig(fast: fast)
        rig.router.receive(physical: key(0, down: true))
        _ = await waitUntil { fast.calls.count == 1 }
        rig.router.receive(physical: key(0, down: false))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fast.calls, [.keys([0x04])], "the release has not started: reports are never coalesced")
        await gate.open()
        let done = await waitUntil { fast.calls.count == 2 }
        XCTAssertTrue(done)
        XCTAssertEqual(fast.calls, [.keys([0x04]), .keys([])])
    }

    func testPhysicalKeysWithoutFastInputSendNothing() async {
        let rig = rig(useFast: false)
        rig.router.receive(physical: key(0, down: true))
        rig.router.receive(physical: key(0, down: false))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(rig.fast.calls.isEmpty)
        XCTAssertTrue(rig.control.calls.isEmpty)
    }

    func testTextThatStillArrivesWithFastInputOnIsTypedByTheRunner() async {
        let rig = rig()
        rig.router.receive(.text("çay"))
        rig.router.flush()
        let done = await waitUntil { !rig.control.calls.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(rig.control.calls, [.type("çay", "com.apple.mobilesafari")])
        XCTAssertTrue(rig.fast.calls.isEmpty)
        XCTAssertTrue(rig.router.isFastActive)
    }

    func testTypingWithoutFastInputStaysWithTheRunner() async {
        let rig = rig(useFast: false)
        rig.router.receive(.text("hi"))
        rig.router.flush()
        let done = await waitUntil { !rig.control.calls.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(rig.control.calls, [.type("hi", "com.apple.mobilesafari")])
        XCTAssertTrue(rig.fast.calls.isEmpty)
    }

    func testAFailedKeyReportClearsFastInputAndTextGoesToTheRunnerAfter() async {
        let fast = FakeFastSender()
        fast.failWhen = { if case .keys = $0 { true } else { false } }
        let rig = rig(fast: fast)
        rig.router.receive(physical: key(0, down: true))
        let cleared = await waitUntil { !rig.router.isFastActive }
        XCTAssertTrue(cleared)
        XCTAssertEqual(rig.log.failures.count, 1)
        rig.router.receive(physical: key(0, down: false))   // nothing goes anywhere now
        rig.router.receive(.text("hi"))
        rig.router.flush()
        let done = await waitUntil { !rig.control.calls.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(rig.control.calls, [.type("hi", "com.apple.mobilesafari")])
        XCTAssertEqual(fast.calls, [.keys([0x04])])
    }

    func testTheAppSwitcherGoesThroughFastInputElseTheRunner() async {
        let fastRig = rig()
        fastRig.router.showAppSwitcher()
        _ = await waitUntil { !fastRig.fast.calls.isEmpty }
        XCTAssertEqual(fastRig.fast.calls, [.appSwitcher])
        XCTAssertTrue(fastRig.control.calls.isEmpty)
        let plain = rig(useFast: false)
        plain.router.showAppSwitcher()
        _ = await waitUntil { !plain.control.calls.isEmpty }
        XCTAssertEqual(plain.control.calls, [.appSwitcher])
    }

    func testTheInterfaceOrientationDecidesTheMappingForLandscapeSides() async {
        // The stage is 2000x1000 (upright landscape): landscapeRight and left map differently.
        for (pose, expected) in [(PhysicalControlOrientation.landscapeLeft, CGPoint(x: 0.75, y: 0.25)),
                                 (.landscapeRight, CGPoint(x: 0.25, y: 0.75))] {
            let rig = rig(frame: CGSize(width: 2000, height: 1000), pose: pose)
            rig.router.receive(touch(.down, 500, 250))  // stage (0.25, 0.25)
            rig.router.receive(touch(.up, 500, 250))
            _ = await waitUntil { rig.fast.calls.count == 2 }
            guard case .down(let point)? = rig.fast.calls.first else { return XCTFail("\(rig.fast.calls)") }
            XCTAssertEqual(point.x, expected.x, accuracy: 0.0001, pose.rawValue)
            XCTAssertEqual(point.y, expected.y, accuracy: 0.0001, pose.rawValue)
            XCTAssertTrue(rig.control.calls.isEmpty)
        }
    }

    func testALandscapeFrameWithAnUnknownOrientationStaysWithTheRunner() async {
        let rig = rig(frame: CGSize(width: 2532, height: 1170))
        rig.router.receive(touch(.down, 1266, 585))
        rig.router.receive(touch(.up, 1266, 585))
        let done = await waitUntil { !rig.control.calls.isEmpty }
        XCTAssertTrue(done)
        guard case .tap? = rig.control.calls.first else { return XCTFail("\(rig.control.calls)") }
        XCTAssertTrue(rig.fast.calls.isEmpty)
    }

    func testALandscapeTouchGoesLiveThroughThePanelMapping() async {
        let rig = rig(frame: CGSize(width: 2000, height: 1000), pose: .landscapeLeft)
        rig.router.receive(touch(.down, 500, 250))  // stage (0.25, 0.25)
        rig.router.receive(touch(.up, 500, 250))
        let done = await waitUntil { rig.fast.calls.count == 2 }
        XCTAssertTrue(done, "\(rig.fast.calls)")
        XCTAssertTrue(rig.control.calls.isEmpty)
        let expected = FastInputPanelMapping.rotation(for: .landscapeLeft)!.apply(CGPoint(x: 0.25, y: 0.25))
        XCTAssertEqual(rig.fast.calls.map(kind), ["down", "up"])
        for call in rig.fast.calls {
            switch call {
            case .down(let p), .up(let p):
                XCTAssertEqual(p.x, expected.x, accuracy: 1e-9)
                XCTAssertEqual(p.y, expected.y, accuracy: 1e-9)
            default: XCTFail("\(call)")
            }
        }
    }

    /// Upside down (Device Hub turns the frame half a turn): a tap on the stage lands on
    /// the point the panel shows there, (1 - u, 1 - v).
    func testAnUpsideDownTouchGoesLiveThroughTheHalfTurnMapping() async {
        let rig = rig(frame: CGSize(width: 1000, height: 2000), pose: .portraitUpsideDown)
        rig.router.receive(touch(.down, 250, 500))  // stage (0.25, 0.25)
        rig.router.receive(touch(.up, 250, 500))
        let done = await waitUntil { rig.fast.calls.count == 2 }
        XCTAssertTrue(done, "\(rig.fast.calls)")
        XCTAssertEqual(rig.fast.calls.map(kind), ["down", "up"])
        for call in rig.fast.calls {
            switch call {
            case .down(let p), .up(let p):
                XCTAssertEqual(p.x, 0.75, accuracy: 1e-9)
                XCTAssertEqual(p.y, 0.75, accuracy: 1e-9)
            default: XCTFail("\(call)")
            }
        }
    }

    /// The home indicator is the panel's bottom edge: on the upside-down frame that is the
    /// stage's top band, and the stage's bottom band is an ordinary touch.
    func testTheBottomEdgeGestureFollowsTheUpsideDownFrame() async {
        let top = rig(frame: CGSize(width: 1000, height: 2000), pose: .portraitUpsideDown)
        top.router.receive(touch(.down, 500, 10))    // stage y 0.005, panel y 0.995
        top.router.receive(touch(.move, 500, 600))
        top.router.receive(touch(.up, 500, 1000))
        let done = await waitUntil { top.fast.calls.count == 3 }
        XCTAssertTrue(done, "\(top.fast.calls)")
        XCTAssertEqual(top.fast.calls.map(kind), ["edge-down", "edge-move", "edge-up"])
        guard case .edge(_, let panel)? = top.fast.calls.first else { return XCTFail("\(top.fast.calls)") }
        XCTAssertEqual(panel.y, 0.995, accuracy: 1e-9)

        let bottom = rig(frame: CGSize(width: 1000, height: 2000), pose: .portraitUpsideDown)
        bottom.router.receive(touch(.down, 500, 1995))  // stage y 0.9975: the panel's top
        bottom.router.receive(touch(.up, 500, 1995))
        let plain = await waitUntil { bottom.fast.calls.count == 2 }
        XCTAssertTrue(plain, "\(bottom.fast.calls)")
        XCTAssertEqual(bottom.fast.calls.map(kind), ["down", "up"])
    }

    // MARK: Stage pose x interface orientation (Device Hub 27.0: the frame follows the device pose)

    /// The picture is the panel turned with the frame, so a tap maps through the FRAME's
    /// pose in every pose, whatever the interface does.
    func testATapMapsThroughTheFramePoseWhateverTheInterfaceDoes() async {
        let frames: [(PhysicalControlOrientation, CGSize)] = [
            (.portrait, CGSize(width: 1000, height: 2000)),
            (.landscapeLeft, CGSize(width: 2000, height: 1000)),
            (.landscapeRight, CGSize(width: 2000, height: 1000)),
            (.portraitUpsideDown, CGSize(width: 1000, height: 2000)),
        ]
        for (pose, frame) in frames {
            for interface in [true, false] {
                let rig = rig(frame: frame, pose: pose, interfaceLandscape: { interface })
                rig.router.receive(touch(.down, Int32(frame.width / 4), Int32(frame.height / 2)))  // stage (0.25, 0.5)
                rig.router.receive(touch(.up, Int32(frame.width / 4), Int32(frame.height / 2)))
                let done = await waitUntil { rig.fast.calls.count == 2 }
                XCTAssertTrue(done, "\(pose) \(interface): \(rig.fast.calls)")
                let expected = FastInputPanelMapping.rotation(for: pose)!.apply(CGPoint(x: 0.25, y: 0.5))
                guard case .down(let p)? = rig.fast.calls.first else { return XCTFail("\(rig.fast.calls)") }
                XCTAssertEqual(p.x, expected.x, accuracy: 1e-9, "\(pose) \(interface)")
                XCTAssertEqual(p.y, expected.y, accuracy: 1e-9, "\(pose) \(interface)")
                XCTAssertTrue(rig.control.calls.isEmpty)
            }
        }
    }

    /// The device is landscape but the interface stayed portrait (the iPhone 12 home
    /// screen): the home indicator is the panel's bottom edge, a side of the landscape stage,
    /// and a swipe from there is the native edge gesture exactly as in portrait.
    func testAPortraitInterfaceInALandscapeFrameKeepsTheNativeEdgeOnTheSide() async {
        // landscapeLeft: panel = (1 - v, u), panel bottom (y >= 0.98) is stage u >= 0.98 (right side).
        let left = rig(frame: CGSize(width: 2000, height: 1000), pose: .landscapeLeft, interfaceLandscape: { false })
        left.router.receive(touch(.down, 1995, 500))
        left.router.receive(touch(.move, 1500, 500))
        left.router.receive(touch(.up, 1000, 500))
        let leftDone = await waitUntil { left.fast.calls.count == 3 }
        XCTAssertTrue(leftDone, "\(left.fast.calls)")
        XCTAssertEqual(left.fast.calls.map(kind), ["edge-down", "edge-move", "edge-up"])
        guard case .edge(_, let panel)? = left.fast.calls.first else { return XCTFail("\(left.fast.calls)") }
        XCTAssertEqual(panel.y, 0.9975, accuracy: 1e-9)
        XCTAssertTrue(left.control.calls.isEmpty)

        // The stage's bottom band is only an ordinary touch now, not the button fallback.
        let bottom = rig(frame: CGSize(width: 2000, height: 1000), pose: .landscapeLeft, interfaceLandscape: { false })
        bottom.router.receive(touch(.down, 1000, 998))
        bottom.router.receive(touch(.up, 1000, 998))
        let plain = await waitUntil { bottom.fast.calls.count == 2 }
        XCTAssertTrue(plain, "\(bottom.fast.calls)")
        XCTAssertEqual(bottom.fast.calls.map(kind), ["down", "up"])

        // landscapeRight: panel = (v, 1 - u), panel bottom is stage u <= 0.02 (left side).
        let right = rig(frame: CGSize(width: 2000, height: 1000), pose: .landscapeRight, interfaceLandscape: { false })
        right.router.receive(touch(.down, 5, 500))
        right.router.receive(touch(.up, 1000, 500))
        let rightDone = await waitUntil { right.fast.calls.count == 2 }
        XCTAssertTrue(rightDone, "\(right.fast.calls)")
        XCTAssertEqual(right.fast.calls.map(kind), ["edge-down", "edge-up"])
    }

    /// An interface that turned to landscape (an app that rotates): its bottom is the stage
    /// bottom, where the Home / App Switcher button fallback stays.
    func testALandscapeInterfaceKeepsTheButtonFallbackOnTheStageBottom() async {
        let clock = Clock()
        for pose in [PhysicalControlOrientation.landscapeLeft, .landscapeRight] {
            let rig = rig(frame: landscape, pose: pose, interfaceLandscape: { true }, now: { clock.now })
            rig.router.receive(touch(.down, 1200, 1165))
            clock.advance(0.05); rig.router.receive(touch(.move, 1200, 1100))
            clock.advance(0.05); rig.router.receive(touch(.move, 1200, 1000))
            clock.advance(0.05); rig.router.receive(touch(.up, 1200, 1000))
            let done = await waitUntil { rig.fast.calls.count == 1 }
            XCTAssertTrue(done, "\(pose): \(rig.fast.calls)")
            XCTAssertEqual(rig.fast.calls.map(kind), ["button"], pose.rawValue)
            XCTAssertTrue(rig.control.calls.isEmpty)
        }
    }

    /// Upside down never has a rotated interface on a Face ID iPhone: the band is the panel
    /// bottom (the stage's top band), whatever the tracker says about the landscape.
    func testUpsideDownWithAPortraitInterfaceUsesThePanelBottomBand() async {
        let top = rig(frame: CGSize(width: 1000, height: 2000), pose: .portraitUpsideDown, interfaceLandscape: { false })
        top.router.receive(touch(.down, 500, 10))
        top.router.receive(touch(.up, 500, 1000))
        let done = await waitUntil { top.fast.calls.count == 2 }
        XCTAssertTrue(done, "\(top.fast.calls)")
        XCTAssertEqual(top.fast.calls.map(kind), ["edge-down", "edge-up"])
    }

    func testAFrameThatContradictsTheOrientationStaysWithTheRunner() async {
        let rig = rig(frame: CGSize(width: 2532, height: 1170), pose: .portrait)
        rig.router.receive(touch(.down, 1266, 585))
        rig.router.receive(touch(.up, 1266, 585))
        let done = await waitUntil { !rig.control.calls.isEmpty }
        XCTAssertTrue(done)
        XCTAssertTrue(rig.fast.calls.isEmpty)
    }

    func testWithoutAFastPathNothingChanges() async {
        let rig = rig(useFast: false)
        XCTAssertFalse(rig.router.isFastActive)
        rig.router.receive(touch(.down, 585, 1266))
        rig.router.receive(touch(.up, 585, 1266))
        rig.router.receive(button: .home, isDown: true)
        let done = await waitUntil { rig.control.calls.count == 2 }
        XCTAssertTrue(done)
        XCTAssertEqual(rig.control.calls.last, .press(.home))
        XCTAssertTrue(rig.fast.calls.isEmpty)
    }

    // MARK: Falling back

    func testAFastErrorFallsBackToTheRunnerForTheRestOfTheSession() async {
        let fast = FakeFastSender()
        fast.failWhen = { if case .move = $0 { return true } else { return false } }
        let rig = rig(fast: fast)
        rig.router.receive(touch(.down, 585, 1266))
        rig.router.receive(touch(.move, 590, 1270))
        rig.router.receive(touch(.up, 590, 1270))
        let failed = await waitUntil { !rig.log.failures.isEmpty }
        XCTAssertTrue(failed)
        XCTAssertEqual(rig.log.failures, [.commandFailed(code: 1, message: "scripted")], "reported once")
        XCTAssertFalse(rig.router.isFastActive)
        // The touch that met the error ends for the overlay.
        let ended = await waitUntil {
            rig.log.events.contains { if case .finished = $0 { return true } else { return false } }
        }
        XCTAssertTrue(ended)

        // From now on the runner serves every input.
        rig.router.receive(touch(.down, 585, 1266))
        rig.router.receive(touch(.up, 585, 1266))
        rig.router.receive(button: .home, isDown: true)
        let served = await waitUntil { rig.control.calls.count == 2 }
        XCTAssertTrue(served, "\(rig.control.calls)")
        XCTAssertEqual(rig.control.calls.last, .press(.home))
        XCTAssertEqual(rig.log.failures.count, 1)
        XCTAssertEqual(fast.calls.map(kind), ["down", "move"], "nothing more reaches the failed path")
    }

    func testAButtonThatFailedThroughFastInputIsPressedAgainThroughTheRunner() async {
        let fast = FakeFastSender()
        fast.failWhen = { if case .button = $0 { return true } else { return false } }
        let rig = rig(fast: fast)
        rig.router.press(.home)
        let pressed = await waitUntil { rig.control.calls == [.press(.home)] }
        XCTAssertTrue(pressed, "\(rig.control.calls)")
        XCTAssertEqual(rig.log.failures.count, 1)
    }

    func testStoppingTheRouterDropsTheFastPath() async {
        let rig = rig()
        rig.router.stop()
        XCTAssertFalse(rig.router.isFastActive)
        rig.router.receive(touch(.down, 585, 1266))
        rig.router.receive(button: .home, isDown: true)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(rig.fast.calls.isEmpty)
    }

    private func kind(_ call: FakeFastSender.Call) -> String {
        switch call {
        case .down: "down"
        case .move: "move"
        case .up: "up"
        case .edge(let phase, _): "edge-\(phase.rawValue)"
        case .button: "button"
        case .hid: "hid"
        case .appSwitcher: "appSwitcher"
        case .key: "key"
        case .keys: "keys"
        }
    }
}
