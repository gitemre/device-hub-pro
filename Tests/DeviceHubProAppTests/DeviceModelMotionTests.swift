import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The 3D model's frame-by-frame motion: the arithmetic of each step, the
/// scene's stepping from the display link's clock (one pose and one draw per
/// frame however many motions move), when the link may rest, and what a
/// hinge slider drag sends.
@MainActor
final class DeviceModelMotionTests: XCTestCase {
    // MARK: - Panel textures

    /// A panel whose frames keep finding no drawable takes a new texture
    /// after `stallsBeforeNewTexture` stalls, and not again within
    /// `newTextureInterval`: after a simulator's reboot the 3D panel kept the
    /// last picture for good while every frame stalled (2026-10-15).
    func testAStarvedPanelTakesANewTextureNowAndThen() {
        let now = ContinuousClock.now
        let enough = DeviceModelScene.stallsBeforeNewTexture
        XCTAssertFalse(DeviceModelScene.takesNewTexture(stalls: enough - 1, lastNewTexture: nil, now: now))
        XCTAssertTrue(DeviceModelScene.takesNewTexture(stalls: enough, lastNewTexture: nil, now: now))
        XCTAssertFalse(DeviceModelScene.takesNewTexture(stalls: enough + 5, lastNewTexture: now - .seconds(1), now: now))
        XCTAssertTrue(DeviceModelScene.takesNewTexture(
            stalls: enough, lastNewTexture: now - DeviceModelScene.newTextureInterval, now: now
        ))
    }

    // MARK: - Lags

    func testALagCoversTheSameWayWhateverTheFrameRate() {
        for lag in [DeviceModelScene.chaseLag, DeviceModelScene.sweepLag, DeviceModelScene.centerLag, DeviceModelScene.bookLag] {
            let oneStep = DeviceModelMotion.lagged(0, towards: 100, delta: 0.5, lag: lag)
            for rate in [24.0, 60, 120, 144] {
                var shown = 0.0
                for _ in 0..<Int(0.5 * rate) { shown = DeviceModelMotion.lagged(shown, towards: 100, delta: 1 / rate, lag: lag) }
                XCTAssertEqual(shown, oneStep, accuracy: 1e-9, "lag \(lag) at \(rate) Hz")
            }
        }
    }

    func testALagIsTheMeasuredFirstOrderStep() {
        XCTAssertEqual(DeviceModelMotion.lagShare(delta: 0.06, lag: 0.06), 1 - exp(-1), accuracy: 1e-12)
        XCTAssertEqual(DeviceModelMotion.lagShare(delta: 0.19, lag: DeviceModelScene.centerLag), 1 - exp(-1), accuracy: 1e-12)
        // Device Hub's centre (57 % left 115 ms after the fold, 30 % 227 ms on):
        // the lag's remaining share after 0.115 s is exp(-0.115/0.19).
        XCTAssertEqual(1 - DeviceModelMotion.lagShare(delta: 0.115, lag: DeviceModelScene.centerLag), exp(-0.115 / 0.19), accuracy: 1e-12)
    }

    func testNoTimeMovesNothingAndNoLagArrivesAtOnce() {
        XCTAssertEqual(DeviceModelMotion.lagShare(delta: 0, lag: 0.06), 0)
        XCTAssertEqual(DeviceModelMotion.lagShare(delta: -1, lag: 0.06), 0)
        XCTAssertEqual(DeviceModelMotion.lagShare(delta: 0.016, lag: 0), 1)
        XCTAssertEqual(DeviceModelMotion.lagged(40, towards: 90, delta: 0, lag: 0.06), 40)
    }

    func testTheChaseReachesTheTargetAndStopsThere() {
        for rate in [60.0, 120] {
            var shown = 176.0
            var frames = 0
            var previous = shown
            while true {
                let step = DeviceModelMotion.chase(
                    from: shown, to: 70, delta: 1 / rate, lag: DeviceModelScene.chaseLag, settledWithin: DeviceModelScene.sweepSettled
                )
                XCTAssertLessThanOrEqual(step.angle, previous, "it only heads down")
                XCTAssertGreaterThanOrEqual(step.angle, 70, "and does not overshoot")
                shown = step.angle
                previous = step.angle
                frames += 1
                if step.settled { break }
                XCTAssertLessThan(frames, 1_000)
            }
            XCTAssertEqual(shown, 70, "the settled frame is the target itself")
            // ln(106 / 0.5) × 60 ms = 0.32 s.
            XCTAssertEqual(Double(frames) / rate, 0.32, accuracy: 2 / rate + 0.001)
        }
    }

    func testTheChaseDoesNotMoveOnAFrameWithNoTimeBehindIt() {
        let step = DeviceModelMotion.chase(from: 120, to: 60, delta: 0, lag: DeviceModelScene.chaseLag, settledWithin: DeviceModelScene.sweepSettled)
        XCTAssertEqual(step, DeviceModelMotion.Chase(angle: 120, settled: false))
    }

    func testTheSweepIsFollowedWithTheLagAndWithReduceMotionAtOnce() {
        XCTAssertEqual(
            DeviceModelMotion.followed(180, towards: 100, delta: 0.15, lag: DeviceModelScene.sweepLag, reduceMotion: false),
            180 - 80 * (1 - exp(-1)), accuracy: 1e-9
        )
        XCTAssertEqual(DeviceModelMotion.followed(180, towards: 100, delta: 0.001, lag: DeviceModelScene.sweepLag, reduceMotion: true), 100)
    }

    // MARK: - Timed motions

    func testProgressAndEasing() {
        XCTAssertEqual(DeviceModelMotion.progress(elapsed: 0, duration: 0.55), 0)
        XCTAssertEqual(DeviceModelMotion.progress(elapsed: 0.275, duration: 0.55), 0.5, accuracy: 1e-6)
        XCTAssertEqual(DeviceModelMotion.progress(elapsed: 5, duration: 0.55), 1)
        XCTAssertEqual(DeviceModelMotion.progress(elapsed: -1, duration: 0.55), 0)
        XCTAssertEqual(DeviceModelMotion.progress(elapsed: 0, duration: 0), 1, "no duration (Reduce Motion) is done at once")
        XCTAssertEqual(DeviceModelMotion.eased(0, easingOut: false), 0)
        XCTAssertEqual(DeviceModelMotion.eased(1, easingOut: false), 1)
        XCTAssertEqual(DeviceModelMotion.eased(0.5, easingOut: false), 0.5, accuracy: 1e-6)
        XCTAssertEqual(DeviceModelMotion.eased(0.25, easingOut: false), 0.15625, accuracy: 1e-6)
        XCTAssertEqual(DeviceModelMotion.eased(0, easingOut: true), 0)
        XCTAssertEqual(DeviceModelMotion.eased(1, easingOut: true), 1)
        XCTAssertEqual(DeviceModelMotion.eased(0.5, easingOut: true), 0.875, accuracy: 1e-6, "cubic out: fastest at the start")
    }

    // MARK: - The scene's steps

    /// A scene with no model: its motions and clock run all the same.
    private func makeScene() -> DeviceModelScene {
        let scene = DeviceModelScene()
        scene.reduceMotion = { false }
        return scene
    }

    func testATimedMotionIsStepAtTheFramesItsTimeFallsOn() {
        let scene = makeScene()
        var seen: [Float] = []
        var finished = 0
        _ = scene.animate(over: 1, { seen.append($0) }, done: { finished += 1 })
        XCTAssertTrue(scene.isAnimating)
        scene.step(at: 100)
        scene.step(at: 100.5)
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(seen[0], 0)
        XCTAssertEqual(seen[1], 0.5, accuracy: 1e-6)
        XCTAssertEqual(finished, 0)
        scene.step(at: 101.2)
        XCTAssertEqual(seen.last, 1, "the last frame is the end whenever it lands")
        XCTAssertEqual(finished, 1)
        XCTAssertFalse(scene.isAnimating)
        scene.step(at: 102)
        XCTAssertEqual(seen.count, 3, "a finished motion is not stepped again")
        XCTAssertEqual(finished, 1)
    }

    func testTheSameMotionOnAFasterDisplayGetsMoreFramesToTheSameProgress() {
        for rate in [60.0, 120] {
            let scene = makeScene()
            var latest: Float = -1
            var count = 0
            _ = scene.animate(over: 0.55, easingOut: true, { latest = $0; count += 1 })
            var time = 50.0
            while scene.isAnimating {
                scene.step(at: time)
                time += 1 / rate
            }
            XCTAssertEqual(latest, 1)
            XCTAssertEqual(Double(count), 0.55 * rate, accuracy: 2, "\(rate) Hz")
        }
    }

    func testReduceMotionTakesAMotionToItsEndOnTheNextFrame() {
        let scene = makeScene()
        scene.reduceMotion = { true }
        var seen: [Float] = []
        var finished = 0
        _ = scene.animate(over: 0.55, { seen.append($0) }, done: { finished += 1 })
        scene.step(at: 10)
        XCTAssertEqual(seen, [1])
        XCTAssertEqual(finished, 1)
        XCTAssertFalse(scene.isAnimating)
    }

    func testACancelledMotionIsNotSteppedAndLetsTheLinkRest() {
        let scene = makeScene()
        var steps = 0
        var finished = 0
        let motion = scene.animate(over: 1, { _ in steps += 1 }, done: { finished += 1 })
        scene.step(at: 1)
        XCTAssertEqual(steps, 1)
        motion.cancel()
        scene.step(at: 1.5)
        XCTAssertEqual(steps, 1)
        XCTAssertEqual(finished, 0, "a cancelled motion does not finish")
        XCTAssertFalse(scene.isAnimating)
    }

    func testAMotionBegunInAStepFirstMovesOnTheNextFrame() {
        let scene = makeScene()
        var inner: [Float] = []
        var begun = false
        _ = scene.animate(over: 1, { _ in
            guard !begun else { return }
            begun = true
            _ = scene.animate(over: 1, { inner.append($0) })
        })
        scene.step(at: 1)
        XCTAssertTrue(inner.isEmpty)
        XCTAssertTrue(scene.isAnimating)
        scene.step(at: 1.5)
        XCTAssertEqual(inner, [0], "it begins at progress 0 on the first frame it sees")
    }

    func testAnyNumberOfMotionsPoseTheDeviceOncePerFrame() {
        let scene = makeScene()
        for _ in 0..<3 {
            _ = scene.animate(over: 1, { _ in scene.zoom(by: 1) })
        }
        XCTAssertEqual(scene.layoutPasses, 0, "asking poses nothing")
        scene.step(at: 1)
        XCTAssertEqual(scene.layoutPasses, 1)
        scene.step(at: 1.5)
        XCTAssertEqual(scene.layoutPasses, 2)
        scene.step(at: 2)
        XCTAssertEqual(scene.layoutPasses, 3)
        scene.step(at: 2.5)
        XCTAssertEqual(scene.layoutPasses, 3, "nothing moves, nothing is posed")
        XCTAssertFalse(scene.isAnimating)
    }

    func testTheDeviceIsPosedOnlyWhenAskedFor() {
        let scene = makeScene()
        scene.step(at: 1)
        scene.step(at: 2)
        XCTAssertEqual(scene.layoutPasses, 0)
        scene.fit(in: CGSize(width: 400, height: 300))
        scene.zoom(by: 1.2)
        scene.fit(in: CGSize(width: 500, height: 300))
        XCTAssertTrue(scene.isAnimating, "a pose is waiting")
        scene.step(at: 3)
        XCTAssertEqual(scene.layoutPasses, 1)
        XCTAssertFalse(scene.isAnimating)
    }

    func testAnyChangeAsksTheCanvasForAFrame() {
        let scene = makeScene()
        var asked = 0
        scene.onNeedsRender = { asked += 1 }
        scene.zoom(by: 1.1)
        XCTAssertGreaterThan(asked, 0)
        let before = asked
        _ = scene.animate(over: 1, { _ in })
        XCTAssertGreaterThan(asked, before, "a motion wakes a resting link")
    }

    func testTheFirstFrameAfterTheLinkRestedHasNoTimeBehindIt() {
        let scene = makeScene()
        XCTAssertEqual(scene.step(at: 10), FrameClock(time: 10, delta: 0))
        XCTAssertEqual(scene.step(at: 10.25).delta, 0.25, accuracy: 1e-12)
        scene.framesPaused()
        XCTAssertEqual(scene.step(at: 500), FrameClock(time: 500, delta: 0))
        XCTAssertEqual(scene.step(at: 500.01).delta, 0.01, accuracy: 1e-12)
        // A time that went back counts as none.
        XCTAssertEqual(scene.step(at: 400).delta, 0)
    }

    func testAFrameTimeLandsOnTheContinuousClockWhereTheMediaTimeDoes() {
        func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        let now = DeviceModelScene.instant(atMediaTime: CACurrentMediaTime())
        XCTAssertEqual(seconds(now.duration(to: .now)), 0, accuracy: 0.05)
        let later = DeviceModelScene.instant(atMediaTime: CACurrentMediaTime() + 2)
        XCTAssertEqual(seconds(ContinuousClock.now.duration(to: later)), 2, accuracy: 0.05)
        let earlier = DeviceModelScene.instant(atMediaTime: CACurrentMediaTime() - 1)
        XCTAssertEqual(seconds(ContinuousClock.now.duration(to: earlier)), -1, accuracy: 0.05)
    }

    // MARK: - The display link

    func testTheStageDrawsWhenItAsksAndTheRendererHasRoom() {
        XCTAssertTrue(RenderCadence.shouldRender(needsRender: true, canRender: true, inFlight: 0))
        XCTAssertTrue(RenderCadence.shouldRender(needsRender: true, canRender: true, inFlight: RenderCadence.maxFramesInFlight - 1))
        XCTAssertFalse(RenderCadence.shouldRender(needsRender: true, canRender: true, inFlight: RenderCadence.maxFramesInFlight))
        XCTAssertFalse(RenderCadence.shouldRender(needsRender: false, canRender: true, inFlight: 0))
        XCTAssertFalse(RenderCadence.shouldRender(needsRender: true, canRender: false, inFlight: 0))
        XCTAssertGreaterThanOrEqual(RenderCadence.maxFramesInFlight, 1)
    }

    func testTheLinkRestsOnlyWhenNothingMovesAndNothingCanBeDrawn() {
        // Idle: nothing to draw, nothing moving.
        XCTAssertTrue(RenderCadence.shouldPause(needsRender: false, canRender: true, animating: false))
        // A frame is wanted and can be drawn (maybe later, the renderer busy).
        XCTAssertFalse(RenderCadence.shouldPause(needsRender: true, canRender: true, animating: false))
        // A motion under way keeps it going whatever else.
        XCTAssertFalse(RenderCadence.shouldPause(needsRender: false, canRender: true, animating: true))
        XCTAssertFalse(RenderCadence.shouldPause(needsRender: false, canRender: false, animating: true))
        // A frame is wanted but the renderer is not loaded or the view has no
        // size: it rests, and wakes when either arrives (`needsRender` set).
        XCTAssertTrue(RenderCadence.shouldPause(needsRender: true, canRender: false, animating: false))
        XCTAssertTrue(RenderCadence.shouldPause(needsRender: false, canRender: false, animating: false))
    }

    /// A scene that rests wakes the link on a new motion, and rests again
    /// once it is done: the decision the canvas makes each tick.
    func testTheLinkRestsAfterAFoldAndWakesForTheNextOne() {
        let scene = makeScene()
        var needsRender = false
        scene.onNeedsRender = { needsRender = true }
        func tick(_ time: Double) -> Bool {
            scene.step(at: time)
            let draws = RenderCadence.shouldRender(needsRender: needsRender, canRender: true, inFlight: 0)
            if draws { needsRender = false }
            let rests = RenderCadence.shouldPause(needsRender: needsRender, canRender: true, animating: scene.isAnimating)
            if rests { scene.framesPaused() }
            return rests
        }
        XCTAssertTrue(tick(1), "nothing to do: it rests")
        _ = scene.animate(over: 0.1, { _ in })
        XCTAssertTrue(needsRender, "the motion woke it")
        XCTAssertFalse(tick(2))
        XCTAssertFalse(tick(2.05))
        XCTAssertTrue(tick(2.2), "the motion is done and the link rests")
        XCTAssertTrue(tick(3))
        // The next motion begins with no time behind it.
        _ = scene.animate(over: 0.1, { _ in })
        XCTAssertEqual(scene.step(at: 40).delta, 0)
    }

    func testTheRendererAdvancesByTheRealTimeBetweenFrames() {
        XCTAssertEqual(RenderCadence.frameDelta(previous: nil, current: 5), 1.0 / 60)
        XCTAssertEqual(RenderCadence.frameDelta(previous: 5, current: 5 + 1.0 / 120), 1.0 / 120, accuracy: 1e-12)
        XCTAssertEqual(RenderCadence.frameDelta(previous: 5, current: 5 + 1.0 / 60), 1.0 / 60, accuracy: 1e-12)
        XCTAssertEqual(RenderCadence.frameDelta(previous: 5, current: 5), 1.0 / 240, "never zero")
        XCTAssertEqual(RenderCadence.frameDelta(previous: 5, current: 4), 1.0 / 240)
        XCTAssertEqual(RenderCadence.frameDelta(previous: 5, current: 65), 0.1, "after the link rested")
    }

    func testFramesInFlightAreCountedFromAnyThread() {
        let frames = FramesInFlight()
        XCTAssertEqual(frames.count, 0)
        frames.begin()
        frames.begin()
        XCTAssertEqual(frames.count, 2)
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            frames.begin()
            frames.end()
        }
        XCTAssertEqual(frames.count, 2)
        frames.end()
        frames.end()
        frames.end()
        XCTAssertEqual(frames.count, 0, "never below none")
    }

    // MARK: - The hinge slider's events

    func testTheModelFollowsEveryEventAndTheSimulatorEachWholeDegree() {
        var filter = HingeDragFilter()
        let udid = "A"
        XCTAssertEqual(filter.next(udid: udid, degrees: 10.2), .init(live: 10.2, send: 10))
        XCTAssertEqual(filter.next(udid: udid, degrees: 10.4), .init(live: 10.4, send: nil))
        XCTAssertEqual(filter.next(udid: udid, degrees: 10.49), .init(live: 10.49, send: nil))
        XCTAssertEqual(filter.next(udid: udid, degrees: 10.6), .init(live: 10.6, send: 11))
        XCTAssertNil(filter.next(udid: udid, degrees: 10.6), "the same angle again is nothing")
        XCTAssertEqual(filter.next(udid: udid, degrees: 10.2), .init(live: 10.2, send: 10), "back across a degree sends it again")
        XCTAssertNil(filter.next(udid: udid, degrees: .nan))
        XCTAssertNil(filter.next(udid: udid, degrees: .infinity))
        XCTAssertEqual(filter.next(udid: udid, degrees: 500), .init(live: 180, send: 180))
        XCTAssertNil(filter.next(udid: udid, degrees: 181), "clamped to the same angle")
        XCTAssertEqual(filter.next(udid: udid, degrees: -4), .init(live: 0, send: 0))
    }

    func testAnEventForAnotherSimulatorAndANewDragSend() {
        var filter = HingeDragFilter()
        XCTAssertEqual(filter.next(udid: "A", degrees: 90.1)?.send, 90)
        XCTAssertEqual(filter.next(udid: "B", degrees: 90.1)?.send, 90, "another simulator")
        XCTAssertNil(filter.next(udid: "B", degrees: 90.1))
        filter.reset()
        XCTAssertEqual(filter.next(udid: "B", degrees: 90.1)?.send, 90, "a drag starts from wherever the hinge is")
    }

    /// 120 events a second, 0.3° each, across 60°: every one reaches the
    /// model, the simulator gets one per whole degree.
    func testADragAtTheMouseRateSendsEachDegreeOnce() {
        var filter = HingeDragFilter()
        var lives: [Double] = []
        var sends: [Double] = []
        for event in 0...200 {
            if let move = filter.next(udid: "A", degrees: Double(event) * 0.3) {
                lives.append(move.live)
                if let send = move.send { sends.append(send) }
            }
        }
        XCTAssertEqual(lives.count, 201)
        XCTAssertEqual(sends, (0...60).map(Double.init))
        XCTAssertEqual(lives, lives.sorted())
        XCTAssertEqual(Set(lives).count, lives.count, "the model gets angles between the whole degrees")
    }
}
