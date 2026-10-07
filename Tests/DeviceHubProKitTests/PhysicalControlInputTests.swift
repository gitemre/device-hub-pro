import Foundation
import XCTest
@testable import DeviceHubProKit

/// How the stage's mouse, keys and Apple-chrome buttons become the runner's
/// few actions: a click is one tap, a drag one swipe
/// on mouse-up, typed keys are buffered into one type call for the app that
/// owns the keyboard, buttons press on their down edge, and with no router
/// (Control off) every input is dropped.
final class PhysicalControlInputTests: XCTestCase {
    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var _fatal: [PhysicalControlError] = []
        private var _soft: [PhysicalControlError] = []
        var fatal: [PhysicalControlError] { lock.withLock { _fatal } }
        var soft: [PhysicalControlError] { lock.withLock { _soft } }
        func addFatal(_ error: PhysicalControlError) { lock.withLock { _fatal.append(error) } }
        func addSoft(_ error: PhysicalControlError) { lock.withLock { _soft.append(error) } }
    }

    /// A scheduler the test fires by hand.
    private final class ManualScheduler: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [(id: Int, delay: TimeInterval, work: @Sendable () -> Void)] = []
        private var counter = 0
        private var _cancelled = 0
        var cancelledCount: Int { lock.withLock { _cancelled } }
        var pendingCount: Int { lock.withLock { pending.count } }
        var delays: [TimeInterval] { lock.withLock { pending.map(\.delay) } }

        var scheduler: PhysicalControlInputRouter.Scheduler {
            { [self] delay, work in
                let id = lock.withLock { () -> Int in
                    counter += 1
                    pending.append((counter, delay, work))
                    return counter
                }
                return { [self] in
                    lock.withLock {
                        if let index = pending.firstIndex(where: { $0.id == id }) {
                            pending.remove(at: index)
                            _cancelled += 1
                        }
                    }
                }
            }
        }

        func fire() {
            let work = lock.withLock { () -> (@Sendable () -> Void)? in
                pending.isEmpty ? nil : pending.removeFirst().work
            }
            work?()
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: TimeInterval = 100
        var now: TimeInterval { lock.withLock { _now } }
        func advance(_ seconds: TimeInterval) { lock.withLock { _now += seconds } }
    }

    private struct Rig {
        let router: PhysicalControlInputRouter
        let control: FakeControl
        let reports: Reports
        let scheduler: ManualScheduler
        let clock: Clock
    }

    private func rig(frame: CGSize? = CGSize(width: 1170, height: 2532), control: FakeControl = FakeControl()) -> Rig {
        let reports = Reports()
        let scheduler = ManualScheduler()
        let clock = Clock()
        let router = PhysicalControlInputRouter(
            control: control,
            frameSize: { frame },
            schedule: scheduler.scheduler,
            now: { clock.now },
            onFailure: { reports.addFatal($0) },
            onSoftFailure: { reports.addSoft($0) }
        )
        return Rig(router: router, control: control, reports: reports, scheduler: scheduler, clock: clock)
    }

    private func down(_ x: Int32, _ y: Int32, id: Int32 = 0) -> TouchCommand { TouchCommand(phase: .down, x: x, y: y, id: id) }
    private func move(_ x: Int32, _ y: Int32, id: Int32 = 0) -> TouchCommand { TouchCommand(phase: .move, x: x, y: y, id: id) }
    private func up(_ x: Int32, _ y: Int32, id: Int32 = 0) -> TouchCommand { TouchCommand(phase: .up, x: x, y: y, id: id) }

    // MARK: Click

    func testAClickIsOneTapAtThePointWhereItWentDown() async throws {
        let rig = rig()
        rig.router.receive(contacts: [down(585, 1266)])
        rig.clock.advance(0.08)
        rig.router.receive(contacts: [up(587, 1268)])
        let sent = await waitUntil { !rig.control.calls.isEmpty }
        XCTAssertTrue(sent)
        guard case .tap(let point)? = rig.control.calls.first else { return XCTFail("\(rig.control.calls)") }
        XCTAssertEqual(point.x, 195, accuracy: 0.01)
        XCTAssertEqual(point.y, 422, accuracy: 0.01)
        XCTAssertEqual(rig.control.calls.count, 1)
    }

    func testAClickMapsToThePortraitPointSpace() async throws {
        let rig = rig(frame: CGSize(width: 1170, height: 2532))
        rig.router.receive(down(0, 0))
        rig.router.receive(up(0, 0))
        _ = await waitUntil { rig.control.calls.count == 1 }
        XCTAssertEqual(rig.control.calls, [.tap(.zero)])
    }

    /// A phone on its side gives a landscape frame; the same picture point is
    /// the same interface point whichever landscape it is (the direction only
    /// turns the chrome).
    func testAClickInALandscapeFrameMapsToTheSwappedInterface() async throws {
        let rig = rig(frame: CGSize(width: 2532, height: 1170))
        rig.router.receive(down(1266, 585))
        rig.router.receive(up(1266, 585))
        _ = await waitUntil { rig.control.calls.count == 1 }
        guard case .tap(let point)? = rig.control.calls.first else { return XCTFail("\(rig.control.calls)") }
        XCTAssertEqual(point.x, 422, accuracy: 0.01)
        XCTAssertEqual(point.y, 195, accuracy: 0.01)
    }

    func testEveryDragOrientationOfTheFrameIsMappedThroughTheFramesShape() async throws {
        for (frame, expected) in [
            (CGSize(width: 1170, height: 2532), CGPoint(x: 97.5, y: 211)),
            (CGSize(width: 2532, height: 1170), CGPoint(x: 211, y: 97.5)),
        ] {
            let rig = rig(frame: frame)
            rig.router.receive(down(Int32(frame.width / 4), Int32(frame.height / 4)))
            rig.router.receive(up(Int32(frame.width / 4), Int32(frame.height / 4)))
            _ = await waitUntil { rig.control.calls.count == 1 }
            guard case .tap(let point)? = rig.control.calls.first else { return XCTFail("\(frame)") }
            XCTAssertEqual(point.x, expected.x, accuracy: 0.6)
            XCTAssertEqual(point.y, expected.y, accuracy: 0.6)
        }
    }

    // MARK: Drag

    func testADragIsOneSwipeOnMouseUpWithItsStartEndAndDuration() async throws {
        let rig = rig()
        rig.router.receive(down(585, 2000))
        // Moves are not sent: no live tracking.
        for y in stride(from: 1900, to: 600, by: -100) {
            rig.router.receive(move(585, Int32(y)))
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(rig.control.calls, [], "nothing goes to the phone until the mouse comes up")
        rig.clock.advance(0.5)
        rig.router.receive(up(585, 500))
        _ = await waitUntil { rig.control.calls.count == 1 }
        guard case .swipe(let from, let to, let duration)? = rig.control.calls.first else { return XCTFail("\(rig.control.calls)") }
        XCTAssertEqual(from.x, 195, accuracy: 0.01)
        XCTAssertEqual(from.y, 2000 * 844 / 2532, accuracy: 0.05)
        XCTAssertEqual(to.y, 500 * 844 / 2532, accuracy: 0.05)
        XCTAssertEqual(duration, 0.5, accuracy: 0.001)
        XCTAssertEqual(rig.control.calls.count, 1, "one swipe, however long the drag")
    }

    func testASwipesDurationIsKeptInARange() async throws {
        let rig = rig()
        rig.router.receive(down(100, 100))
        rig.clock.advance(0.001)
        rig.router.receive(up(100, 1500))
        rig.router.receive(down(100, 100))
        rig.clock.advance(30)
        rig.router.receive(up(100, 1500))
        _ = await waitUntil { rig.control.calls.count == 2 }
        let durations = rig.control.calls.compactMap { call -> TimeInterval? in
            if case .swipe(_, _, let duration) = call { return duration }
            return nil
        }.sorted()
        XCTAssertEqual(durations, [0.12, 1.5], "a flick is not instantaneous and a long press-drag is not endless")
    }

    func testAPointerThatBarelyMovedIsAClickNotADrag() async throws {
        let rig = rig()
        rig.router.receive(down(500, 500))
        rig.router.receive(up(510, 505)) // 10 px of 1170: a few points
        _ = await waitUntil { rig.control.calls.count == 1 }
        if case .tap? = rig.control.calls.first {} else { XCTFail("\(rig.control.calls)") }
    }

    func testOnlyTheFirstFingerCounts() async throws {
        let rig = rig()
        // A pinch or an Option-drag: two contacts. Nothing is sent, and the
        // gesture in progress is dropped.
        rig.router.receive(contacts: [down(100, 100)])
        rig.router.receive(contacts: [down(100, 100, id: 1), down(200, 200, id: 2)])
        rig.router.receive(contacts: [move(100, 100, id: 1), move(300, 300, id: 2)])
        rig.router.receive(contacts: [up(300, 300, id: 1), up(300, 300, id: 2)])
        rig.router.receive(contacts: [up(100, 100)])
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(rig.control.calls, [])
    }

    func testAnUpWithoutADownAndAnEmptyFrameSendNothing() async throws {
        let rig = rig()
        rig.router.receive(up(10, 10))
        let empty = self.rig(frame: nil)
        empty.router.receive(down(10, 10))
        empty.router.receive(up(10, 10))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(rig.control.calls, [])
        XCTAssertEqual(empty.control.calls, [])
    }

    /// One action runs and at most one waits; a further click is dropped with
    /// a soft note, never queued for later.
    func testAtMostOneTouchWaitsAndTheRestAreDroppedAsBusy() async throws {
        let control = FakeControl()
        let gate = TypeGate()
        control.gate = { await gate.wait() }
        let rig = rig(control: control)
        func click(at x: Int32) {
            rig.router.receive(down(x, 100))
            rig.router.receive(up(x, 100))
        }
        click(at: 100)
        _ = await waitUntil { control.calls.count == 1 }
        click(at: 200)
        click(at: 300) // a third: dropped
        _ = await waitUntil { !rig.reports.soft.isEmpty }
        XCTAssertEqual(rig.reports.soft, [.busy])
        XCTAssertEqual(control.calls.count, 1, "the second waits for the first")
        await gate.open()
        _ = await waitUntil { control.calls.count == 2 }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(control.calls.count, 2, "the dropped click never runs later")
        let xs = control.calls.compactMap { call -> CGFloat? in
            if case .tap(let point) = call { return point.x } else { return nil }
        }
        XCTAssertEqual(xs.count, 2)
        XCTAssertLessThan(xs[0], xs[1], "in the order they were made")
        XCTAssertEqual(rig.reports.fatal, [])
    }

    /// Actions keep the order they were made in, whatever their kind.
    func testButtonsAndTypingKeepTheirOrderWithTaps() async throws {
        let rig = rig()
        rig.router.receive(button: .volumeUp, isDown: true)
        rig.router.receive(button: .volumeDown, isDown: true)
        rig.router.receive(button: .home, isDown: true)
        _ = await waitUntil { rig.control.calls.count == 3 }
        XCTAssertEqual(rig.control.calls, [.press(.volumeUp), .press(.volumeDown), .press(.home)])
    }

    // MARK: Failures

    func testABusyPhoneIsASoftNoteAndAnyOtherFailureIsFatal() async throws {
        let rig = rig()
        rig.control.failure = .busy
        rig.router.receive(down(10, 10))
        rig.router.receive(up(10, 10))
        _ = await waitUntil { !rig.reports.soft.isEmpty }
        XCTAssertEqual(rig.reports.soft, [.busy])
        XCTAssertEqual(rig.reports.fatal, [])

        rig.control.failure = .transportFailed("reset")
        rig.router.receive(down(10, 10))
        rig.router.receive(up(10, 10))
        _ = await waitUntil { !rig.reports.fatal.isEmpty }
        XCTAssertEqual(rig.reports.fatal, [.transportFailed("reset")])
    }

    // MARK: Keys

    func testTypedKeysAreBufferedAndSentOnceTheKeysStop() async throws {
        let rig = rig()
        rig.router.receive(.text("h"))
        rig.router.receive(.text("i"))
        rig.router.receive(.text("!"))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(rig.control.calls, [], "nothing is sent per key")
        XCTAssertEqual(rig.scheduler.pendingCount, 1, "one idle timer, restarted by each key")
        XCTAssertEqual(rig.scheduler.delays, [0.25])
        XCTAssertEqual(rig.scheduler.cancelledCount, 2)

        rig.scheduler.fire()
        _ = await waitUntil { !rig.control.calls.isEmpty }
        XCTAssertEqual(rig.control.calls, [.type("hi!", "com.apple.mobilesafari")], "one type call to the app that owns the keyboard")
    }

    func testAFullBufferIsSentAtOnce() async throws {
        let rig = rig()
        rig.router.receive(.text(String(repeating: "a", count: 40)))
        _ = await waitUntil { !rig.control.calls.isEmpty }
        XCTAssertEqual(rig.control.calls, [.type(String(repeating: "a", count: 40), "com.apple.mobilesafari")])
    }

    func testKeysTypedWhileASendIsInFlightGoInTheNextSendInOrder() async throws {
        let control = FakeControl()
        let gate = TypeGate()
        control.gate = { await gate.wait() }
        let rig = rig(control: control)
        rig.router.receive(.text("ab"))
        rig.scheduler.fire()
        _ = await waitUntil { control.calls.count == 1 }
        // "cd" arrives while "ab" is in flight.
        rig.router.receive(.text("cd"))
        rig.scheduler.fire()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(control.calls, [.type("ab", "com.apple.mobilesafari")], "one send at a time")
        await gate.open()
        _ = await waitUntil { control.calls.count == 2 }
        XCTAssertEqual(control.calls, [.type("ab", "com.apple.mobilesafari"), .type("cd", "com.apple.mobilesafari")])
    }

    func testDeleteReturnAndTabAreTypedAsTheirControlCharactersAndOtherKeysAreLeftAlone() async throws {
        let rig = rig()
        rig.router.receive(.text("a"))
        rig.router.receive(.specialKey(51)) // delete
        rig.router.receive(.specialKey(36)) // return
        rig.router.receive(.specialKey(48)) // tab
        rig.router.receive(.specialKey(123)) // left arrow: no public equivalent
        rig.router.receive(.specialKey(53)) // escape
        rig.scheduler.fire()
        _ = await waitUntil { !rig.control.calls.isEmpty }
        XCTAssertEqual(rig.control.calls, [.type("a\u{8}\n\t", "com.apple.mobilesafari")])
    }

    func testNoAppInTheForegroundSaysTapATextFieldFirstAndTypesNothing() async throws {
        let control = FakeControl()
        control.foreground = nil
        let rig = rig(control: control)
        rig.router.receive(.text("hello"))
        rig.scheduler.fire()
        _ = await waitUntil { !rig.reports.soft.isEmpty }
        XCTAssertEqual(rig.reports.soft, [.noForegroundApp])
        XCTAssertEqual(rig.reports.soft.first?.description, "Tap a text field first")
        XCTAssertEqual(control.calls, [], "nothing was typed")
        XCTAssertEqual(rig.reports.fatal, [])
    }

    func testAKeyboardThatIsNotShowingIsASoftNote() async throws {
        let rig = rig()
        rig.control.failure = .keyboardNotShowing
        rig.router.receive(.text("x"))
        rig.scheduler.fire()
        _ = await waitUntil { !rig.reports.soft.isEmpty }
        XCTAssertEqual(rig.reports.soft, [.keyboardNotShowing])
    }

    // MARK: Buttons

    func testTheChromeButtonsPressOnTheirDownEdgeAndOnlyHomeAndVolumeExist() async throws {
        let rig = rig()
        rig.router.receive(button: .home, isDown: true)
        rig.router.receive(button: .home, isDown: false)
        rig.router.receive(button: .volumeUp, isDown: true)
        rig.router.receive(button: .volumeDown, isDown: true)
        // No public lock, Siri or Action button.
        rig.router.receive(button: .side, isDown: true)
        rig.router.receive(button: .siri, isDown: true)
        rig.router.receive(button: .usage(page: 0x0B, usage: 0x2D), isDown: true)
        _ = await waitUntil { rig.control.calls.count >= 3 }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(rig.control.calls, [.press(.home), .press(.volumeUp), .press(.volumeDown)])
    }

    // MARK: Ending

    func testAStoppedRouterSendsNothingAndDropsWhatItHeld() async throws {
        let rig = rig()
        rig.router.receive(.text("held"))
        rig.router.receive(down(10, 10))
        rig.router.stop()
        XCTAssertEqual(rig.scheduler.pendingCount, 0, "the idle timer is cancelled")
        rig.router.receive(up(10, 10))
        rig.router.receive(.text("more"))
        rig.router.receive(button: .home, isDown: true)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(rig.control.calls.filter { if case .press = $0 { return false } else { return true } }, [])
    }

    // MARK: The route

    func testWithoutARouterTheSessionsDropEveryInput() async throws {
        let session = PhysicalScreenshotSession(hardwareUDID: "U", interval: .milliseconds(10)) { _ in }
        XCTAssertFalse(session.inputRoute.isActive)
        XCTAssertFalse(session.acceptsButtons, "the chrome offers no buttons while Control is off")
        session.frames.put(Frame(data: Data(count: 4 * 4 * 4), width: 4, height: 4, seq: 1))
        let control = FakeControl()
        // No router: nothing can reach the fake, and nothing crashes.
        session.send(contacts: [down(1, 1)])
        session.send(contacts: [up(1, 1)])
        session.send(.text("x"))
        session.send(button: .home, isDown: true)
        XCTAssertEqual(control.calls, [])
    }

    func testASetRouterGetsTheSessionsInputAndAClearedOneDropsIt() async throws {
        let session = PhysicalScreenshotSession(hardwareUDID: "U", interval: .milliseconds(10)) { _ in }
        session.frames.put(Frame(data: Data(count: 4 * 4 * 4), width: 4, height: 4, seq: 1))
        let control = FakeControl()
        let router = PhysicalControlInputRouter(
            control: control,
            frameSize: { [frames = session.frames] in
                frames.currentSize.map { CGSize(width: $0.width, height: $0.height) }
            },
            onFailure: { _ in },
            onSoftFailure: { _ in }
        )
        session.inputRoute.set(router)
        XCTAssertTrue(session.inputRoute.isActive)
        XCTAssertTrue(session.acceptsButtons)

        session.send(contacts: [down(2, 4)])
        session.send(contacts: [up(2, 4)])
        session.send(button: .volumeDown, isDown: true)
        _ = await waitUntil { control.calls.count == 2 }
        XCTAssertTrue(control.calls.contains(.press(.volumeDown)))
        XCTAssertTrue(control.calls.contains { if case .tap = $0 { return true } else { return false } })

        session.inputRoute.set(nil)
        XCTAssertFalse(session.inputRoute.isActive)
        session.send(contacts: [down(2, 4)])
        session.send(contacts: [up(2, 4)])
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(control.calls.count, 2, "cleared: view only again")
    }

    func testReplacingARouterStopsTheOldOne() async throws {
        let route = PhysicalInputRoute()
        let first = rig()
        let second = rig()
        route.set(first.router)
        route.set(second.router)
        first.router.receive(down(10, 10))
        first.router.receive(up(10, 10))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(first.control.calls, [], "the replaced router was stopped")
        route.set(second.router)
        second.router.receive(down(10, 10))
        second.router.receive(up(10, 10))
        _ = await waitUntil { second.control.calls.count == 1 }
        XCTAssertEqual(second.control.calls.count, 1, "setting the same router again does not stop it")
    }
}

private actor TypeGate {
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
