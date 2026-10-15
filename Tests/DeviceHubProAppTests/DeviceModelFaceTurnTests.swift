import XCTest
@testable import DeviceHubProApp

/// How the 3D stage turns the device to the other face off a preset (the lit
/// panel changed): as a swing from the turn drawn, eased out, not in a snap
/// whenever the last frame was drawn.
@MainActor
final class DeviceModelFaceTurnTests: XCTestCase {
    private let t0 = ContinuousClock.now
    /// A frame about every 16.7 ms, as the settle loop draws them.
    private let frame: Duration = .microseconds(16_667)

    /// The outer face's turn at 107° and the inner book it turns to.
    private let outerTurn: Float = 1.87
    private let bookTurn: Float = -0.4

    /// A turn drawn at `outerTurn` at `t0`, then nothing (the stage settles
    /// and stops drawing).
    private func drawnEase() -> BookTurnEase {
        var ease = BookTurnEase()
        _ = ease.advance(towards: outerTurn, at: t0, reduceMotion: false)
        _ = ease.advance(towards: outerTurn, at: t0 + frame, reduceMotion: false)
        return ease
    }

    /// The lit panel changes about a second after the stage was last drawn (a
    /// 0.5 s wait and a read of two screenshots): the first frame of the
    /// swing must not cross the turn.
    func testASwingAfterALongIdleStartsFromTheTurnDrawn() {
        var ease = drawnEase()
        let now = t0 + .seconds(2)
        ease.startSwing(at: now)
        let first = ease.advance(towards: bookTurn, at: now + frame, reduceMotion: false)
        XCTAssertEqual(first, outerTurn, accuracy: abs(outerTurn - bookTurn) * 0.16, "a step of the swing, not the turn")
        XCTAssertLessThan(first, outerTurn, "it set off")
    }

    /// Without the swing's own start the idle time counts as one long step: a
    /// preset keeps its pace (the hinge moves it every frame), and a face turn
    /// that forgot `startSwing` is what this test warns of.
    func testAnIdleGapWithoutASwingStartCrossesInOneFrame() {
        var ease = drawnEase()
        let now = t0 + .seconds(2)
        let first = ease.advance(towards: bookTurn, at: now + frame, reduceMotion: false)
        XCTAssertEqual(first, bookTurn, accuracy: 0.001)
    }

    /// The swing gets nearly all the way in Device Hub's 0.55 s and is
    /// fastest at first.
    func testTheSwingTakesAboutDeviceHubsQuarterTurnTimeEasingOut() {
        var ease = drawnEase()
        let now = t0 + .seconds(1)
        ease.startSwing(at: now)
        var previous = outerTurn
        var steps: [Float] = []
        var turn = outerTurn
        for index in 1...33 {
            turn = ease.advance(towards: bookTurn, at: now + frame * index, reduceMotion: false)
            steps.append(previous - turn)
            XCTAssertLessThan(turn, previous, "monotonic")
            previous = turn
        }
        let distance = outerTurn - bookTurn
        XCTAssertGreaterThan(outerTurn - turn, distance * 0.98, "about 0.55 s")
        XCTAssertGreaterThan(steps[0], steps[10])
        XCTAssertGreaterThan(steps[10], steps[30])
        // Not there at half the time.
        var halfway = drawnEase()
        halfway.startSwing(at: now)
        var halfTurn = outerTurn
        for index in 1...16 { halfTurn = halfway.advance(towards: bookTurn, at: now + frame * index, reduceMotion: false) }
        XCTAssertLessThan(outerTurn - halfTurn, distance * 0.9)
    }

    /// A frame the main thread was late for does not jump the swing.
    func testAHitchInsideTheSwingCountsForAThirtiethOfASecond() {
        let hitch = BookTurnEase.eased(from: outerTurn, to: bookTurn, elapsed: 0.25, swinging: true)
        let step = BookTurnEase.eased(from: outerTurn, to: bookTurn, elapsed: DeviceModelScene.faceTurnStep, swinging: true)
        XCTAssertEqual(hitch, step, accuracy: 1e-6)
        XCTAssertGreaterThan(hitch, outerTurn - (outerTurn - bookTurn) * 0.3)
    }

    /// A preset's book turn keeps today's lag and counts the whole time since
    /// the frame before.
    func testTheBookTurnOfAPresetIsUnchanged() {
        let seconds = 0.0167
        let expected = outerTurn + (bookTurn - outerTurn) * Float(1 - exp(-seconds / DeviceModelScene.bookLag))
        XCTAssertEqual(
            BookTurnEase.eased(from: outerTurn, to: bookTurn, elapsed: seconds, swinging: false), expected, accuracy: 1e-6
        )
        XCTAssertEqual(BookTurnEase.eased(from: outerTurn, to: bookTurn, elapsed: 5, swinging: false), bookTurn, accuracy: 1e-4)
        XCTAssertEqual(BookTurnEase.eased(from: outerTurn, to: bookTurn, elapsed: -1, swinging: false), outerTurn, "never back in time")
    }

    /// The swing is slower than the preset's book turn, which crossed a half
    /// turn in 0.2 s.
    func testTheSwingIsSlowerThanThePresetsBookTurn() {
        let swing = BookTurnEase.eased(from: 0, to: 1, elapsed: DeviceModelScene.faceTurnStep, swinging: true)
        let preset = BookTurnEase.eased(from: 0, to: 1, elapsed: DeviceModelScene.faceTurnStep, swinging: false)
        XCTAssertLessThan(swing, preset)
    }

    /// A preset's sweep starting ends the swing, as does the swing's own
    /// 0.55 s.
    func testASweepOrTheEndOfTheWindowReturnsThePaceToTheHinge() {
        var ease = drawnEase()
        let now = t0 + .seconds(1)
        ease.startSwing(at: now)
        XCTAssertTrue(ease.isSwinging(at: now + .milliseconds(500)))
        XCTAssertFalse(ease.isSwinging(at: now + .seconds(DeviceModelScene.rollDuration) + .milliseconds(1)))
        ease.endSwing()
        XCTAssertFalse(ease.isSwinging(at: now + .milliseconds(100)))
    }

    func testReduceMotionTurnsAtOnce() {
        var ease = drawnEase()
        let now = t0 + .seconds(1)
        ease.startSwing(at: now)
        XCTAssertEqual(ease.advance(towards: bookTurn, at: now + frame, reduceMotion: true), bookTurn)
    }

    func testAForgottenTurnIsDrawnAtOnce() {
        var ease = drawnEase()
        let now = t0 + .seconds(1)
        XCTAssertTrue(ease.isSettled, "settled where it heads")
        ease.forget()
        XCTAssertNil(ease.shown)
        XCTAssertEqual(ease.advance(towards: bookTurn, at: now, reduceMotion: false), bookTurn)
    }

    func testTheEaseIsSettledOnlyOnceItIsWhereItHeads() {
        var ease = drawnEase()
        let now = t0 + .seconds(1)
        XCTAssertTrue(ease.isSettled)
        ease.startSwing(at: now)
        _ = ease.advance(towards: bookTurn, at: now + frame, reduceMotion: false)
        XCTAssertFalse(ease.isSettled)
        _ = ease.advance(towards: bookTurn, at: now + .seconds(60), reduceMotion: true)
        XCTAssertTrue(ease.isSettled)
    }

    /// The watchdog looks at a lit panel often, and less often once a look
    /// costs more than a millisecond of the main thread.
    func testTheWatchdogLooksLessOftenWhenALookIsExpensive() {
        XCTAssertEqual(DeviceModelScene.darkSampleGap(afterCost: .microseconds(200)), DeviceModelScene.darkSampleInterval)
        XCTAssertEqual(DeviceModelScene.darkSampleGap(afterCost: .milliseconds(1)), DeviceModelScene.darkSampleInterval)
        XCTAssertEqual(DeviceModelScene.darkSampleGap(afterCost: .milliseconds(4)), DeviceModelScene.slowSampleInterval)
        XCTAssertGreaterThan(DeviceModelScene.slowSampleInterval, DeviceModelScene.darkSampleInterval)
    }
}
