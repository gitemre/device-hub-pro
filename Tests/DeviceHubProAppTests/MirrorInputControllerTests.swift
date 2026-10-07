import AppKit
import XCTest
import DeviceHubProKit
@testable import DeviceHubProApp

/// The mirror's trackpad/mouse mapping: scroll strokes (MR-02/MR-03) and
/// their touch slop, lifting every contact before a session switch, real
/// wheel events and Back for physical devices, and keyboard routing.
@MainActor
final class MirrorInputControllerTests: XCTestCase {
    private let frame = CGSize(width: 1080, height: 2400)
    private var sent: [TouchCommand] = []
    private var scheduler = ManualScheduler()

    override func setUp() async throws {
        sent = []
        scheduler = ManualScheduler()
    }

    /// View points map 1:1 to frame pixels here, so the numbers read as
    /// frame coordinates (y from the top).
    private func makeController(
        pointsPerPixel: CGFloat = 1,
        frame: CGSize? = nil,
        reportedPixelsPerDp: CGFloat? = nil,
        pointer: FakePointerInput? = nil
    ) -> MirrorInputController {
        let controller = MirrorInputController()
        let frame = frame ?? self.frame
        controller.logicalPoint = { point in
            guard point.x >= 0, point.y >= 0, point.x < frame.width, point.y < frame.height else { return nil }
            return (Int32(point.x), Int32(point.y))
        }
        controller.frameSize = { frame }
        controller.pointsPerFramePixel = { pointsPerPixel }
        controller.reportedPixelsPerDp = { _ in reportedPixelsPerDp }
        controller.sendContacts = { [weak self] contacts in self?.sent.append(contentsOf: contacts) }
        controller.pointerInput = { pointer }
        let scheduler = self.scheduler
        controller.schedule = { delay, work in scheduler.add(delay: delay, work: work) }
        return controller
    }

    private var phases: [TouchCommand.Phase] { sent.map(\.phase) }

    // MARK: - MR-02: resting fingers never tap

    func testRestingTwoFingersSendNothing() {
        let controller = makeController()
        let cursor = CGPoint(x: 540, y: 1200)

        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: 0, phase: .mayBegin))
        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: 0, phase: .cancelled))
        scheduler.runAll()

        XCTAssertTrue(sent.isEmpty, "a touch without movement must not reach the device: \(phases)")
    }

    func testZeroDeltaEventsDoNotStartAStroke() {
        let controller = makeController()
        let cursor = CGPoint(x: 540, y: 1200)

        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: 0, phase: .began))
        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: 0, phase: .changed))
        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: 0, phase: .ended))
        scheduler.runAll()

        XCTAssertTrue(sent.isEmpty)
    }

    // MARK: - MR-03: one stroke, still lift, clear of the gesture zones

    func testAScrollIsOneStrokeThatLiftsOnlyOnceStill() throws {
        let controller = makeController()
        let cursor = CGPoint(x: 540, y: 1200)

        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: -40, phase: .began))
        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: -10, phase: .changed))
        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: 0, phase: .ended))

        XCTAssertEqual(phases, [.down, .move, .move], "no lift while momentum may still follow")
        XCTAssertEqual(sent.first?.y, 1200)
        XCTAssertEqual(sent.last?.y, 1150)
        XCTAssertEqual(scheduler.pendingDelays, [MirrorInputController.stillBeforeLift])

        scheduler.runAll()
        XCTAssertEqual(phases, [.down, .move, .move, .up])
        XCTAssertEqual(sent.last?.y, 1150, "the finger lifts where it rested")
    }

    func testMomentumContinuesTheSameStroke() {
        let controller = makeController()
        let cursor = CGPoint(x: 540, y: 1200)

        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: -40, phase: .began))
        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: 0, phase: .ended))
        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: -30, momentumPhase: .began))
        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: -10, momentumPhase: .changed))
        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: 0, momentumPhase: .ended))
        scheduler.runAll()

        XCTAssertEqual(phases.filter { $0 == .down }.count, 1, "momentum must not start a new stroke: \(phases)")
        XCTAssertEqual(phases.filter { $0 == .up }.count, 1)
        XCTAssertEqual(phases.last, .up)
        XCTAssertEqual(sent.last?.y, 1200 - 80)
    }

    func testAMomentumStartWithoutADeltaKeepsTheFingerDown() {
        let controller = makeController()
        let cursor = CGPoint(x: 540, y: 1200)
        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: -40, phase: .began))
        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: 0, phase: .ended))
        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: 0, momentumPhase: .began))
        XCTAssertTrue(scheduler.pendingDelays.isEmpty, "the lift scheduled at .ended must not fire mid-momentum")
        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: -10, momentumPhase: .changed))
        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: 0, momentumPhase: .ended))
        scheduler.runAll()
        XCTAssertEqual(phases, [.down, .move, .move, .up])
    }

    func testTouchingTheTrackpadDuringMomentumLiftsTheFinger() {
        let controller = makeController()
        let cursor = CGPoint(x: 540, y: 1200)
        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: -40, momentumPhase: .changed))
        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: 0, phase: .mayBegin))
        scheduler.runAll()
        XCTAssertEqual(phases, [.down, .move, .up])
    }

    func testTheFingerNeverTouchesDownInASystemGestureZone() throws {
        let density = MirrorInputController.estimatedPixelsPerDp(frame: frame)
        let insets = MirrorInputController.gestureInsetsDp

        for cursor in [
            CGPoint(x: 540, y: 2399),  // over the gesture bar (Home)
            CGPoint(x: 0, y: 1200),    // left edge (Back)
            CGPoint(x: 1079, y: 1200), // right edge (Back)
            CGPoint(x: 540, y: 0),     // status bar (shade)
        ] {
            sent = []
            let controller = makeController()
            controller.scroll(.init(location: cursor, deltaX: 3, deltaY: -40, phase: .began))
            let down = try XCTUnwrap(sent.first { $0.phase == .down })
            XCTAssertGreaterThanOrEqual(CGFloat(down.x), insets.left * density - 1, "\(cursor)")
            XCTAssertLessThanOrEqual(CGFloat(down.x), frame.width - 1 - insets.right * density + 1, "\(cursor)")
            XCTAssertGreaterThanOrEqual(CGFloat(down.y), insets.top * density - 1, "\(cursor)")
            XCTAssertLessThanOrEqual(CGFloat(down.y), frame.height - 1 - insets.bottom * density + 1, "\(cursor)")
        }
    }

    // MARK: - Touch slop: short scrolls never reach the device as a tap

    /// A 1080x2400 stream shown in an 800 pt stage.
    private let stagePointsPerPixel: CGFloat = 0.32

    func testAScrollUnderTheSlopSendsNoTouch() {
        let controller = makeController(pointsPerPixel: stagePointsPerPixel)
        let cursor = CGPoint(x: 540, y: 1200)

        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: -1, phase: .began))
        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: -2, phase: .changed))
        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: 0, phase: .ended))
        scheduler.runAll()

        XCTAssertTrue(sent.isEmpty, "a 3 pt scroll must not tap what is under the cursor: \(phases)")
    }

    func testRestingAfterANudgeUnderTheSlopSendsNothing() {
        let controller = makeController(pointsPerPixel: stagePointsPerPixel)
        let cursor = CGPoint(x: 540, y: 1200)

        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: -3, phase: .began))
        // The fingers rest on the trackpad: no events, nothing scheduled.
        XCTAssertTrue(scheduler.pendingDelays.isEmpty)
        scheduler.runAll()
        XCTAssertTrue(sent.isEmpty, "no finger may rest on the device into a long press: \(phases)")

        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: 0, phase: .cancelled))
        scheduler.runAll()
        XCTAssertTrue(sent.isEmpty)
    }

    func testAScrollPastTheSlopGoesDownAndCrossesItInOneMove() throws {
        let controller = makeController(pointsPerPixel: stagePointsPerPixel)
        let cursor = CGPoint(x: 540, y: 1200)
        let density = MirrorInputController.estimatedPixelsPerDp(frame: frame)
        let slop = MirrorInputController.touchSlopPixels(pixelsPerDp: density)

        var scrolled: CGFloat = 0
        while sent.isEmpty, scrolled < 100 {
            controller.scroll(.init(location: cursor, deltaX: 0, deltaY: -2, phase: scrolled == 0 ? .began : .changed))
            scrolled += 2
        }

        XCTAssertEqual(phases, [.down, .move])
        let down = try XCTUnwrap(sent.first)
        let move = try XCTUnwrap(sent.last)
        XCTAssertEqual(down.y, 1200)
        XCTAssertGreaterThan(CGFloat(down.y - move.y), slop.height - 1)
        XCTAssertGreaterThanOrEqual(CGFloat(down.y - move.y), 8 * density, "past Android's 8 dp touch slop")
        XCTAssertEqual(
            Double(down.y - move.y), Double(scrolled / stagePointsPerPixel), accuracy: 1,
            "the move carries the whole distance scrolled so far"
        )

        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: -2, phase: .changed))
        XCTAssertEqual(phases, [.down, .move, .move], "past the slop the finger follows every event")
    }

    func testAHorizontalScrollWaitsForThePagingSlop() throws {
        let controller = makeController()
        let cursor = CGPoint(x: 540, y: 1200)
        let density = MirrorInputController.estimatedPixelsPerDp(frame: frame)

        // 12 dp: past the touch slop but not the launcher's 16 dp paging
        // slop, so no pager would take it and the icon under it would open.
        controller.scroll(.init(location: cursor, deltaX: 12 * density, deltaY: 0, phase: .began))
        XCTAssertTrue(sent.isEmpty, "\(phases)")

        controller.scroll(.init(location: cursor, deltaX: 8 * density, deltaY: 0, phase: .changed))
        XCTAssertEqual(phases, [.down, .move])
        let down = try XCTUnwrap(sent.first)
        let move = try XCTUnwrap(sent.last)
        XCTAssertGreaterThanOrEqual(CGFloat(move.x - down.x), 16 * density)
    }

    func testTheRestAfterAnEdgeLiftWaitsForTheSlopToo() {
        let controller = makeController()
        let cursor = CGPoint(x: 540, y: 1200)

        // The finger reaches the top edge exactly, then 5 px past it.
        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: -1200, phase: .began))
        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: -5, phase: .changed))
        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: 0, phase: .ended))
        scheduler.runAll()

        XCTAssertEqual(phases, [.down, .move, .move, .up], "5 px at the anchor would tap it: \(phases)")
        XCTAssertEqual(sent.last?.y, 0)
    }

    func testALongScrollReAnchorsInsteadOfPinningAtTheEdge() {
        let controller = makeController()
        let cursor = CGPoint(x: 540, y: 1200)

        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: -200, phase: .began))
        for _ in 0..<30 {
            controller.scroll(.init(location: cursor, deltaX: 0, deltaY: -200, phase: .changed))
        }
        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: 0, phase: .ended))
        scheduler.runAll()

        for command in sent {
            XCTAssertTrue((0..<1080).contains(command.x) && (0..<2400).contains(command.y), "\(command)")
        }
        let downs = sent.filter { $0.phase == .down }
        XCTAssertGreaterThan(downs.count, 1, "a 6200 px scroll must put the finger down again")
        XCTAssertTrue(downs.allSatisfy { $0.y == 1200 }, "every stroke restarts at the anchor")

        // Every stroke's travel adds up to the whole scroll.
        var travelled = 0
        var start: Int32 = 0
        for command in sent {
            switch command.phase {
            case .down: start = command.y
            case .up: travelled += Int(start - command.y)
            case .move: break
            }
        }
        XCTAssertEqual(travelled, 31 * 200)
    }

    func testTrackpadDistanceFollowsTheFingerAtTheViewScale() {
        // The image is shown at half a point per frame pixel: 10 pt of finger
        // travel is 20 frame pixels of content.
        let controller = makeController(pointsPerPixel: 0.5)
        controller.scroll(.init(location: CGPoint(x: 540, y: 1200), deltaX: 0, deltaY: 20, phase: .began))
        XCTAssertEqual(sent.last?.y, 1240)
    }

    func testAMouseWheelScrollsAWheelUnitPerLineAndLiftsWhenIdle() {
        let controller = makeController()
        controller.scroll(.init(
            location: CGPoint(x: 540, y: 1200), deltaX: 0, deltaY: -1, hasPreciseDeltas: false
        ))
        let unit = MirrorInputController.wheelUnitPixels(
            pixelsPerDp: MirrorInputController.estimatedPixelsPerDp(frame: frame)
        )
        XCTAssertEqual(phases, [.down, .move])
        XCTAssertEqual(Double(sent.last!.y), Double(1200 - unit), accuracy: 1)
        XCTAssertEqual(scheduler.pendingDelays, [MirrorInputController.wheelIdleLift])
        scheduler.runAll()
        XCTAssertEqual(phases.last, .up)
    }

    func testScrollingDuringAMouseDragIsIgnored() {
        let controller = makeController()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1080, height: 2400))
        controller.mouseDown(mouseEvent(.leftMouseDown, at: CGPoint(x: 100, y: 100)), in: view)
        let beforeScroll = sent.count

        controller.scroll(.init(location: CGPoint(x: 540, y: 1200), deltaX: 0, deltaY: -20, phase: .began))
        XCTAssertEqual(sent.count, beforeScroll, "a second finger with id 0 must not go down")
    }

    func testAClickLiftsAPendingScrollFingerFirst() {
        let controller = makeController()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1080, height: 2400))
        controller.scroll(.init(location: CGPoint(x: 540, y: 1200), deltaX: 0, deltaY: -40, phase: .began))
        controller.mouseDown(mouseEvent(.leftMouseDown, at: CGPoint(x: 100, y: 100)), in: view)
        XCTAssertEqual(phases, [.down, .move, .up, .down])
        XCTAssertTrue(scheduler.pendingDelays.isEmpty)
    }

    // MARK: - Lifting everything before a session switch

    func testLiftAllLiftsTheScrollFingerAndCancelsItsPendingLift() {
        let controller = makeController()
        let cursor = CGPoint(x: 540, y: 1200)
        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: -40, phase: .began))
        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: 0, phase: .ended))

        controller.liftAll()
        XCTAssertEqual(phases, [.down, .move, .up])
        XCTAssertTrue(scheduler.pendingDelays.isEmpty, "the pending lift would reach the next session")

        var next: [TouchCommand] = []
        controller.sendContacts = { next.append(contentsOf: $0) }
        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: -10, momentumPhase: .changed))
        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: 0, momentumPhase: .ended))
        scheduler.runAll()
        XCTAssertTrue(next.isEmpty, "the rest of the old gesture stays under the slop: \(next.map(\.phase))")
    }

    func testLiftAllLiftsAMouseDragAndIgnoresItsRest() {
        let controller = makeController()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1080, height: 2400))
        controller.mouseDown(mouseEvent(.leftMouseDown, at: CGPoint(x: 100, y: 100)), in: view)
        controller.mouseDragged(mouseEvent(.leftMouseDragged, at: CGPoint(x: 120, y: 100)), in: view)

        controller.liftAll()
        XCTAssertEqual(phases, [.down, .move, .up])
        XCTAssertEqual(sent.last?.x, 120, "lifted where it was")

        controller.mouseDragged(mouseEvent(.leftMouseDragged, at: CGPoint(x: 140, y: 100)), in: view)
        controller.mouseUp(mouseEvent(.leftMouseUp, at: CGPoint(x: 140, y: 100)), in: view)
        XCTAssertEqual(phases, [.down, .move, .up])
    }

    func testLiftAllLiftsBothFingersOfAnOptionPinch() {
        let controller = makeController()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1080, height: 2400))
        controller.mouseDown(mouseEvent(.leftMouseDown, at: CGPoint(x: 500, y: 500), modifiers: .option), in: view)

        controller.liftAll()
        XCTAssertEqual(sent.filter { $0.phase == .up }.map(\.id).sorted(), [1, 2])

        controller.mouseUp(mouseEvent(.leftMouseUp, at: CGPoint(x: 500, y: 500)), in: view)
        XCTAssertEqual(sent.count, 4, "nothing after the lift")
    }

    func testLiftAllWithNothingDownSendsNothing() {
        let controller = makeController()
        controller.scroll(.init(location: CGPoint(x: 540, y: 1200), deltaX: 0, deltaY: -3, phase: .began))
        controller.liftAll()
        XCTAssertTrue(sent.isEmpty)
    }

    // MARK: - The device's reported density

    /// A Pixel Tablet: 2560x1600 at 320 dpi is 2 px per dp, where the
    /// phone-sized estimate (a 411 dp short side) says 3.9.
    private let tablet = CGSize(width: 2560, height: 1600)

    func testATabletWheelScrollFollowsTheFingersAtItsReportedDensity() {
        let pointer = FakePointerInput(acceptsScroll: true)
        let controller = makeController(frame: tablet, reportedPixelsPerDp: 2, pointer: pointer)

        // 128 px is one 64 dp wheel unit at 2 px per dp.
        controller.scroll(.init(location: CGPoint(x: 1280, y: 800), deltaX: 0, deltaY: -128, phase: .changed))
        XCTAssertEqual(pointer.scrolls.map(\.vertical), [-1], "the content must move as far as the fingers")
    }

    func testATabletTouchScrollUsesItsReportedSlopAndGestureZones() throws {
        let controller = makeController(frame: tablet, reportedPixelsPerDp: 2)

        // 25 px is past the 10 dp slop at 2 px per dp (20 px), not at 3.9.
        controller.scroll(.init(location: CGPoint(x: 1280, y: 1599), deltaX: 0, deltaY: -25, phase: .began))
        XCTAssertEqual(phases, [.down, .move])
        let down = try XCTUnwrap(sent.first)
        XCTAssertEqual(down.y, 1599 - 48 * 2, "clear of the 48 dp gesture bar, and no further")
    }

    func testTheEstimateStandsInWhileTheDensityIsUnknown() {
        let pointer = FakePointerInput(acceptsScroll: true)
        let controller = makeController(frame: tablet, reportedPixelsPerDp: nil, pointer: pointer)
        let estimate = MirrorInputController.estimatedPixelsPerDp(frame: tablet)

        controller.scroll(.init(location: CGPoint(x: 1280, y: 800), deltaX: 0, deltaY: -128, phase: .changed))
        let vertical = Double(pointer.scrolls.first?.vertical ?? 0)
        XCTAssertEqual(vertical, Double(-128 / MirrorInputController.wheelUnitPixels(pixelsPerDp: estimate)), accuracy: 0.0001)
    }

    // MARK: - Physical devices: real wheel events and Back

    func testAPhysicalSessionGetsWheelEventsInsteadOfTouches() throws {
        let pointer = FakePointerInput(acceptsScroll: true)
        let controller = makeController(pointer: pointer)
        let cursor = CGPoint(x: 300, y: 900)

        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: 0, phase: .mayBegin))
        XCTAssertTrue(pointer.scrolls.isEmpty, "resting fingers scroll nothing")

        // Fingers moving up (content up, negative delta) scroll down.
        controller.scroll(.init(location: cursor, deltaX: 0, deltaY: -20, phase: .changed))
        let scroll = try XCTUnwrap(pointer.scrolls.first)
        XCTAssertEqual(scroll.x, 300)
        XCTAssertEqual(scroll.y, 900)
        XCTAssertLessThan(scroll.vertical, 0)
        XCTAssertEqual(scroll.horizontal, 0)
        let unit = MirrorInputController.wheelUnitPixels(
            pixelsPerDp: MirrorInputController.estimatedPixelsPerDp(frame: frame)
        )
        XCTAssertEqual(Double(scroll.vertical), Double(-20 / unit), accuracy: 0.0001)

        // Content moving right reveals the left: Android scrolls left.
        controller.scroll(.init(location: cursor, deltaX: 15, deltaY: 0, momentumPhase: .changed))
        XCTAssertLessThan(try XCTUnwrap(pointer.scrolls.last).horizontal, 0)

        XCTAssertTrue(sent.isEmpty, "no touches for a session that takes wheel events")
    }

    func testAFastWheelIsSplitIntoSingleSteps() {
        let pointer = FakePointerInput(acceptsScroll: true)
        let controller = makeController(pointer: pointer)
        controller.scroll(.init(
            location: CGPoint(x: 300, y: 900), deltaX: 0, deltaY: 3.5, hasPreciseDeltas: false
        ))
        XCTAssertEqual(pointer.scrolls.map(\.vertical), [1, 1, 1, 0.5])
    }

    func testWithoutTheControlSocketScrollingFallsBackToTouches() {
        let pointer = FakePointerInput(acceptsScroll: false)
        let controller = makeController(pointer: pointer)
        controller.scroll(.init(location: CGPoint(x: 540, y: 1200), deltaX: 0, deltaY: -40, phase: .began))
        XCTAssertTrue(pointer.scrolls.isEmpty)
        XCTAssertEqual(phases, [.down, .move])
    }

    func testARightClickIsBackOnlyWhereTheSessionTakesIt() {
        let pointer = FakePointerInput(acceptsScroll: false)
        XCTAssertTrue(makeController(pointer: pointer).secondaryClick())
        XCTAssertEqual(pointer.backs, 1)

        XCTAssertFalse(makeController().secondaryClick(), "an emulator session has no Back binding")
        XCTAssertTrue(sent.isEmpty)
    }

    // MARK: - Keyboard

    func testControlCombinationsAreNotTypedAsText() {
        XCTAssertNil(MirrorKeyRouting.command(keyCode: 18, characters: "1", modifiers: .control))
        XCTAssertNil(MirrorKeyRouting.command(keyCode: 0, characters: "\u{01}", modifiers: .control))
        XCTAssertNil(MirrorKeyRouting.command(keyCode: 44, characters: "/", modifiers: [.control, .shift]))
    }

    func testSpecialKeysStillReachTheDeviceWithControl() {
        guard case .specialKey(51)? = MirrorKeyRouting.command(keyCode: 51, characters: "\u{7F}", modifiers: .control) else {
            return XCTFail("delete must stay a special key")
        }
    }

    func testCommandShortcutsStayOnTheMac() {
        XCTAssertNil(MirrorKeyRouting.command(keyCode: 8, characters: "c", modifiers: .command))
        XCTAssertNil(MirrorKeyRouting.command(keyCode: 51, characters: "\u{7F}", modifiers: .command))
    }

    func testPlainAndOptionTextIsTyped() {
        guard case .text("a")? = MirrorKeyRouting.command(keyCode: 0, characters: "a", modifiers: []) else {
            return XCTFail("plain text must be typed")
        }
        guard case .text("ç")? = MirrorKeyRouting.command(keyCode: 8, characters: "ç", modifiers: .option) else {
            return XCTFail("Option characters are text")
        }
    }

    // MARK: - Helpers

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at point: CGPoint,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }
}

/// Runs scheduled work by hand.
@MainActor
private final class ManualScheduler {
    private struct Item {
        let id: Int
        let delay: TimeInterval
        let work: @MainActor () -> Void
    }

    private var items: [Item] = []
    private var nextID = 0

    var pendingDelays: [TimeInterval] { items.map(\.delay) }

    func add(delay: TimeInterval, work: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        nextID += 1
        let id = nextID
        items.append(Item(id: id, delay: delay, work: work))
        return { [weak self] in self?.items.removeAll { $0.id == id } }
    }

    func runAll() {
        while !items.isEmpty {
            let item = items.removeFirst()
            item.work()
        }
    }
}

private final class FakePointerInput: MirrorPointerInput {
    struct Scroll {
        let x: Int32
        let y: Int32
        let horizontal: Float
        let vertical: Float
    }

    let acceptsScroll: Bool
    private(set) var scrolls: [Scroll] = []
    private(set) var backs = 0

    init(acceptsScroll: Bool) {
        self.acceptsScroll = acceptsScroll
    }

    func sendScroll(x: Int32, y: Int32, horizontal: Float, vertical: Float) {
        scrolls.append(Scroll(x: x, y: y, horizontal: horizontal, vertical: vertical))
    }

    func sendBackOrScreenOn() {
        backs += 1
    }
}
