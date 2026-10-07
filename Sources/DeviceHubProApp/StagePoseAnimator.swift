import Observation
import SwiftUI
import DeviceHubProKit

/// Owns the stage's **presentation pose**: the absolute rotation angle applied
/// as a wrapper around the native composition, plus the settled stream
/// rotation that drives the renderer's texture uprighting.
///
/// The stage composes the device in its native orientation (no transposed
/// layout), so the pose is one continuous angle:
///
/// * a rotate press starts an optimistic animation toward the next quarter
///   turn immediately (the emulator follows underneath);
/// * when the stream settles, only the texture uprighting changes — the
///   wrapper angle is already on its way, so nothing rebases and the rotation
///   never stutters;
/// * a rotation that arrives without a press (a physical device) or one that
///   disagrees with the target (the emulator rotated the other way) is
///   reconciled by animating to the settled pose.
///
/// Reduce Motion snaps instead of animating (the `runPostureAnimation`
/// precedent). The animator is UI-free except for the injected animation
/// runner, so the algebra is unit-tested with a synchronous runner.
@MainActor
@Observable
final class StagePoseAnimator {
    /// Applies an animation to a state change and runs `completion` when it
    /// finishes. Injectable for tests.
    typealias AnimationRunner = (Animation, @escaping () -> Void, @escaping () -> Void) -> Void

    /// Absolute wrapper angle in degrees (`-90 * targetTurns`). Grows with
    /// repeated rotations on purpose: keeping the value continuous makes the
    /// wrapper animate the short way around.
    private(set) var presentedAngle: Double = 0

    /// The angle the wrapper comes to rest at, known from the first frame of
    /// a rotation: `presentedAngle` is only ever assigned its target (the
    /// animation interpolates what is drawn, not the stored value), so this
    /// is always `-90 * targetTurns`. The stage lays the device out at this
    /// pose's fit (see `PosePresentation`).
    ///
    /// It reads `presentedAngle` rather than `targetTurns`, so reading it
    /// adds no dependency to the views that turn the device: they update
    /// once, in the animated change.
    var restAngle: Double { presentedAngle }

    /// The stream's settled quarter turn (0...3), used to upright the texture.
    private(set) var settledTurns = 0

    /// The pose the wrapper is animating toward (unbounded turn counter).
    private(set) var targetTurns = 0

    /// True from a press until the wrapper animation finishes; the mirror
    /// disables input while it is set (taps would be mapped against a pose the
    /// view is no longer in).
    private(set) var isAnimating = false

    @ObservationIgnored private let reduceMotion: () -> Bool
    @ObservationIgnored private let animate: AnimationRunner
    @ObservationIgnored private var animationGeneration = 0
    @ObservationIgnored private var needsReconcile = false

    init(
        reduceMotion: @escaping () -> Bool = { MotionMetrics.reduceMotion },
        animate: @escaping AnimationRunner = { animation, body, completion in
            withAnimation(animation, body, completion: completion)
        }
    ) {
        self.reduceMotion = reduceMotion
        self.animate = animate
    }

    /// Starts an optimistic quarter-turn rotation. A press while a rotation is
    /// still in flight is ignored (the emulator is serializing it anyway).
    func beginRotation(_ direction: RotationDirection) {
        guard !isAnimating else { return }
        targetTurns += direction == .left ? 1 : -1
        start(to: targetTurns)
    }

    /// The stream settled on `rotation` (0...3).
    func settle(rotation: Int) {
        let normalized = TextureRotation.normalized(rotation)
        let changed = normalized != settledTurns
        settledTurns = normalized
        guard changed else { return }

        if TextureRotation.normalized(targetTurns) == normalized {
            needsReconcile = false
            return
        }
        if isAnimating {
            // The wrapper is mid-flight; reconcile when it lands.
            needsReconcile = true
            return
        }
        reconcile()
    }

    /// The rotate command failed: animate back to the settled pose.
    func cancelRotation() {
        targetTurns = nearestTurns(congruentTo: settledTurns, from: targetTurns)
        start(to: targetTurns)
    }

    /// Drops any in-flight animation and returns to the upright pose; used
    /// when a new mirror session replaces the old one.
    func reset() {
        animationGeneration += 1
        presentedAngle = 0
        settledTurns = 0
        targetTurns = 0
        isAnimating = false
        needsReconcile = false
    }

    /// Rests at `turns` at once, with no animation: a session that starts
    /// on a device already turned (a simulator in its Apple chrome,
    /// `SimulatorCanvasController.devicePose`).
    func snap(toTurns turns: Int) {
        animationGeneration += 1
        targetTurns = turns
        settledTurns = TextureRotation.normalized(turns)
        presentedAngle = -90.0 * Double(turns)
        isAnimating = false
        needsReconcile = false
    }

    private func reconcile() {
        targetTurns = nearestTurns(congruentTo: settledTurns, from: targetTurns)
        start(to: targetTurns)
    }

    private func start(to turns: Int) {
        let angle = -90.0 * Double(turns)
        // Already at the target: nothing to animate. If a rotation toward
        // this same angle is in flight, its own completion clears
        // `isAnimating`; starting a no-change animation here would bump the
        // generation and latch `isAnimating` true forever.
        if presentedAngle == angle { return }
        animationGeneration += 1
        let generation = animationGeneration
        if reduceMotion() {
            presentedAngle = angle
            isAnimating = false
            return
        }
        isAnimating = true
        animate(MotionMetrics.hero, { self.presentedAngle = angle }) { [weak self] in
            guard let self, self.animationGeneration == generation else { return }
            self.isAnimating = false
            if self.needsReconcile {
                self.needsReconcile = false
                self.reconcile()
            }
        }
    }

    /// The congruent quarter turn (normalized + 4k) closest to `reference`,
    /// so reconciliation never spins the long way around.
    private func nearestTurns(congruentTo normalized: Int, from reference: Int) -> Int {
        var candidate = normalized
        while candidate - reference > 2 { candidate -= 4 }
        while reference - candidate > 2 { candidate += 4 }
        return candidate
    }
}
