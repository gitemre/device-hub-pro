import XCTest
import SwiftUI
@testable import DeviceHubProApp

@MainActor
final class StagePoseAnimatorTests: XCTestCase {
    /// Synchronous runner: applies the change immediately and reports
    /// completion, so the algebra is tested without a real animation clock.
    private func immediateAnimator() -> StagePoseAnimator.AnimationRunner {
        { _, body, completion in
            body()
            completion()
        }
    }

    private func deferredAnimator() -> StagePoseAnimator.AnimationRunner {
        { _, body, _ in body() }
    }

    func testLeftRotationTargetsTheNextQuarterTurn() {
        let animator = StagePoseAnimator(reduceMotion: { false }, animate: immediateAnimator())
        animator.beginRotation(.left)
        XCTAssertEqual(animator.targetTurns, 1)
        XCTAssertEqual(animator.presentedAngle, -90, accuracy: 0.001)
        XCTAssertFalse(animator.isAnimating)
    }

    func testRightRotationGoesTheOtherWay() {
        let animator = StagePoseAnimator(reduceMotion: { false }, animate: immediateAnimator())
        animator.beginRotation(.right)
        XCTAssertEqual(animator.targetTurns, -1)
        XCTAssertEqual(animator.presentedAngle, 90, accuracy: 0.001)
    }

    func testSettleDuringTheAnimationDoesNotRebaseTheAngle() {
        let animator = StagePoseAnimator(reduceMotion: { false }, animate: deferredAnimator())
        animator.beginRotation(.left)
        XCTAssertTrue(animator.isAnimating)
        XCTAssertEqual(animator.presentedAngle, -90, accuracy: 0.001)

        animator.settle(rotation: 1)
        XCTAssertEqual(animator.settledTurns, 1)
        XCTAssertEqual(animator.targetTurns, 1, "the in-flight target must not be rebased")
        XCTAssertTrue(animator.isAnimating)
    }

    func testPhysicalRotationAnimatesToTheSettledPose() {
        let animator = StagePoseAnimator(reduceMotion: { false }, animate: immediateAnimator())
        animator.settle(rotation: 1)
        XCTAssertEqual(animator.settledTurns, 1)
        XCTAssertEqual(animator.targetTurns, 1)
        XCTAssertEqual(animator.presentedAngle, -90, accuracy: 0.001)
    }

    func testReconciliationTakesTheShortWayAround() {
        let animator = StagePoseAnimator(reduceMotion: { false }, animate: immediateAnimator())
        animator.beginRotation(.right)          // target -1 (== rotation 3)
        animator.settle(rotation: 3)            // agrees, no reconciliation
        XCTAssertEqual(animator.targetTurns, -1)

        animator.settle(rotation: 2)            // physical change to the other side
        XCTAssertEqual(animator.targetTurns, -2, "nearest congruent turn is -2, not +2")
        XCTAssertEqual(animator.presentedAngle, 180, accuracy: 0.001)
    }

    func testRepeatedRotationsAccumulate() {
        let animator = StagePoseAnimator(reduceMotion: { false }, animate: immediateAnimator())
        animator.beginRotation(.left)
        animator.settle(rotation: 1)
        animator.beginRotation(.left)
        XCTAssertEqual(animator.targetTurns, 2)
        XCTAssertEqual(animator.presentedAngle, -180, accuracy: 0.001)
    }

    /// A physical iPhone's Rotate walk (settle without a press): left, upside down, landscape
    /// right, portrait, each the shortest way, upside down included.
    func testASettleWalkThroughUpsideDownTakesEachQuarterTheShortWay() {
        let animator = StagePoseAnimator(reduceMotion: { false }, animate: immediateAnimator())
        var angles: [Double] = []
        for turns in [1, 2, 3, 0, 3, 2, 1, 0] {
            animator.settle(rotation: turns)
            angles.append(animator.presentedAngle)
        }
        XCTAssertEqual(angles, [-90, -180, -270, -360, -270, -180, -90, 0])
    }

    func testPressDuringAnAnimationIsIgnored() {
        let animator = StagePoseAnimator(reduceMotion: { false }, animate: deferredAnimator())
        animator.beginRotation(.left)
        animator.beginRotation(.left)
        XCTAssertEqual(animator.targetTurns, 1)
    }

    func testReduceMotionSnaps() {
        let animator = StagePoseAnimator(reduceMotion: { true }, animate: immediateAnimator())
        animator.beginRotation(.left)
        XCTAssertEqual(animator.presentedAngle, -90, accuracy: 0.001)
        XCTAssertFalse(animator.isAnimating)
    }

    func testCancelRotationReturnsToTheSettledPose() {
        let animator = StagePoseAnimator(reduceMotion: { false }, animate: immediateAnimator())
        animator.beginRotation(.left)
        animator.cancelRotation()
        XCTAssertEqual(animator.targetTurns, 0)
        XCTAssertEqual(animator.presentedAngle, 0, accuracy: 0.001)
    }

    func testCancelRotationWhileDeferredDoesNotLatchIsAnimating() {
        var completions: [() -> Void] = []
        let runner: StagePoseAnimator.AnimationRunner = { _, body, done in
            body()
            completions.append(done)
        }
        let animator = StagePoseAnimator(reduceMotion: { false }, animate: runner)
        animator.beginRotation(.left)     // -90 in flight
        animator.cancelRotation()         // back to 0, in flight
        XCTAssertEqual(completions.count, 2)

        completions[0]()                  // stale completion must be ignored
        XCTAssertTrue(animator.isAnimating, "the cancel animation is still in flight")
        completions[1]()
        XCTAssertFalse(animator.isAnimating)
        XCTAssertEqual(animator.targetTurns, 0)
        XCTAssertEqual(animator.presentedAngle, 0, accuracy: 0.001)
    }

    func testNoOpCancelDoesNotLatchIsAnimating() {
        // A cancel whose target already matches the presented angle must not
        // start a no-change animation: its completion may never fire, which
        // would leave `isAnimating` latched and input disabled forever.
        var completions: [() -> Void] = []
        let runner: StagePoseAnimator.AnimationRunner = { _, body, done in
            body()
            completions.append(done)
        }
        let animator = StagePoseAnimator(reduceMotion: { false }, animate: runner)
        animator.beginRotation(.left)
        animator.cancelRotation()
        completions[0]()
        completions[1]()
        XCTAssertFalse(animator.isAnimating)

        animator.cancelRotation()
        XCTAssertFalse(animator.isAnimating)
        XCTAssertEqual(completions.count, 2, "a no-op cancel must not start an animation")
        XCTAssertEqual(animator.presentedAngle, 0, accuracy: 0.001)
    }

    func testSettlingOnTheSameRotationIsANoOp() {
        let animator = StagePoseAnimator(reduceMotion: { false }, animate: immediateAnimator())
        animator.settle(rotation: 0)
        XCTAssertEqual(animator.targetTurns, 0)
        XCTAssertEqual(animator.presentedAngle, 0, accuracy: 0.001)
    }

    /// The stage lays the device out at the rest pose's fit, so the rest
    /// angle must be the target from the first frame of every rotation — a
    /// press, a cancel, a reconcile — and never an in-between value.
    func testRestAngleIsTheTargetFromTheStartOfEveryRotation() {
        var completions: [() -> Void] = []
        let runner: StagePoseAnimator.AnimationRunner = { _, body, done in
            body()
            completions.append(done)
        }
        let animator = StagePoseAnimator(reduceMotion: { false }, animate: runner)
        func assertRestIsTarget(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(animator.restAngle, -90 * Double(animator.targetTurns), step, file: file, line: line)
        }
        assertRestIsTarget("upright")

        animator.beginRotation(.left)
        XCTAssertTrue(animator.isAnimating)
        XCTAssertEqual(animator.restAngle, -90)
        assertRestIsTarget("press, in flight")

        animator.settle(rotation: 2)          // disagrees: reconciled on landing
        assertRestIsTarget("settle in flight")
        completions[0]()
        XCTAssertEqual(animator.restAngle, -180)
        assertRestIsTarget("reconcile, in flight")

        animator.cancelRotation()
        assertRestIsTarget("cancel")
        completions.forEach { $0() }
        assertRestIsTarget("landed")

        animator.reset()
        XCTAssertEqual(animator.restAngle, 0)
    }

    func testReconcileAfterTheAnimationLands() {
        // A deferred runner keeps the animation "in flight"; the settle that
        // disagrees is remembered and reconciled by the completion, which
        // starts a second animation toward the settled pose.
        var completions: [() -> Void] = []
        let runner: StagePoseAnimator.AnimationRunner = { _, body, done in
            body()
            completions.append(done)
        }
        let animator = StagePoseAnimator(reduceMotion: { false }, animate: runner)
        animator.beginRotation(.left)     // target 1, angle -90, in flight
        animator.settle(rotation: 2)      // disagrees with the target
        XCTAssertTrue(animator.isAnimating)

        completions[0]()                  // first animation lands → reconcile starts
        XCTAssertTrue(animator.isAnimating)
        XCTAssertEqual(completions.count, 2)
        XCTAssertEqual(animator.targetTurns, 2, "reconciled to the settled pose")
        XCTAssertEqual(animator.presentedAngle, -180, accuracy: 0.001)

        completions[1]()
        XCTAssertFalse(animator.isAnimating)
    }
}
