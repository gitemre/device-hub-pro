import DeviceHubProKit
import Foundation
import Synchronization

/// When one frame of the 3D stage is due on screen, and how long after the
/// one before (`DeviceModelScene.step`).
struct FrameClock: Equatable {
    /// The frame's presentation time, in `CACurrentMediaTime`'s seconds (the
    /// display link's `targetTimestamp`).
    var time: Double
    /// Seconds since the scene was last stepped; zero for the first frame
    /// after the display link rested, so a motion that begins then does not
    /// start with a jump of the time the screen sat still.
    var delta: Double
}

/// A motion of the 3D model that moves on the display link's frames
/// (`DeviceModelScene.step`) instead of on a timer of its own: every motion
/// takes its step from the same clock, and the scene poses the device and
/// draws once for all of them.
@MainActor
final class FrameAnimation {
    /// Takes the frame; false once the motion has finished.
    typealias Step = @MainActor (FrameClock) -> Bool

    /// Let go once the motion ends: the closures capture what they move (a
    /// hardware key holds its own motion), which would otherwise keep both
    /// alive after the scene was dropped.
    private var advance: Step?
    /// Finished, or cancelled: it is not stepped again.
    var isFinished: Bool { advance == nil }

    init(_ advance: @escaping Step) {
        self.advance = advance
    }

    /// Stops the motion where it is (its `done` is not called).
    func cancel() {
        advance = nil
    }

    func run(_ frame: FrameClock) {
        guard let advance else { return }
        if !advance(frame) { self.advance = nil }
    }
}

/// The arithmetic of the 3D model's motion, one frame at a time. Every
/// motion is a function of the time it was given, never of how many frames
/// there were (a first-order lag covers the same share of its way in 1/60 s
/// once as in two steps of 1/120 s), so the constants measured against
/// Device Hub (`DeviceModelScene.chaseLag`, `sweepLag`, `centerLag`,
/// `bookLag`) mean the same at any display rate.
enum DeviceModelMotion {
    /// The share of its way to the target that a first-order lag of `lag`
    /// seconds covers in `delta` seconds; none for no time, all of it for a
    /// lag that is not positive.
    static func lagShare(delta: Double, lag: Double) -> Double {
        guard delta > 0 else { return 0 }
        guard lag > 0 else { return 1 }
        return 1 - exp(-delta / lag)
    }

    /// `shown` after `delta` seconds of heading for `target` with a lag of
    /// `lag` seconds.
    static func lagged(_ shown: Double, towards target: Double, delta: Double, lag: Double) -> Double {
        shown + (target - shown) * lagShare(delta: delta, lag: lag)
    }

    /// One frame of the hinge chasing the slider.
    struct Chase: Equatable {
        /// The angle to draw.
        var angle: Double
        /// It has reached the target (and `angle` is the target itself).
        var settled: Bool
    }

    /// The drawn hinge `shown` after `delta` seconds of heading for `target`
    /// with a lag of `lag` seconds (`DeviceModelScene.chaseLag`): it counts as
    /// there, and is the target itself, within `settledWithin` degrees.
    static func chase(from shown: Double, to target: Double, delta: Double, lag: Double, settledWithin: Double) -> Chase {
        var drawn = lagged(shown, towards: target, delta: delta, lag: lag)
        let settled = abs(drawn - target) < settledWithin
        if settled { drawn = target }
        return Chase(angle: drawn, settled: settled)
    }

    /// The hinge drawn after the simulator's: `drawn` after `delta` seconds
    /// of heading for the angle the simulator's sweep has reached, with a lag
    /// of `lag` seconds (`DeviceModelScene.sweepLag`); with Reduce Motion on,
    /// at the sweep's angle itself.
    static func followed(_ drawn: Double, towards angle: Double, delta: Double, lag: Double, reduceMotion: Bool) -> Double {
        reduceMotion ? angle : lagged(drawn, towards: angle, delta: delta, lag: lag)
    }

    /// How far a timed motion of `duration` seconds got after `elapsed`
    /// seconds (0...1); finished at once when it has no duration (Reduce
    /// Motion).
    static func progress(elapsed: Double, duration: Double) -> Float {
        guard duration > 0 else { return 1 }
        return Float(min(max(elapsed / duration, 0), 1))
    }

    /// `progress` eased: out (cubic), as the simulator's hinge sweeps
    /// (`SimulatorFold.sweepAngles`) and Device Hub turns the device, else in
    /// and out (smoothstep).
    static func eased(_ progress: Float, easingOut: Bool) -> Float {
        easingOut ? 1 - pow(1 - progress, 3) : progress * progress * (3 - 2 * progress)
    }
}

/// When the 3D stage's display link draws, and when it may rest. The link
/// runs while something moves or waits to be drawn and rests otherwise: an
/// idle stage woke the main thread at the display's rate (60–120 Hz) for
/// nothing.
enum RenderCadence {
    /// How many frames may be with the renderer at once: one is drawn by the
    /// GPU while the next is encoded, so a frame costs the longer of the two
    /// instead of their sum. With one at a time a tick that found the last
    /// frame unfinished drew nothing (and the old guard cleared only after a
    /// further hop to the main queue). Three drawables back the layer, one of
    /// them on screen. Not measured live: set to 1 to go back to a frame at
    /// a time if RealityKit proves not to take two.
    static let maxFramesInFlight = 2

    /// Whether a tick draws a frame: the scene changed, the renderer and the
    /// view are ready, and the renderer has room for another frame.
    static func shouldRender(needsRender: Bool, canRender: Bool, inFlight: Int) -> Bool {
        needsRender && canRender && inFlight < maxFramesInFlight
    }

    /// Whether the link rests after a tick: nothing moves and nothing can be
    /// drawn that is wanted. A frame that is wanted but has to wait for the
    /// renderer keeps the link going; the link wakes when the scene asks for
    /// a frame (`needsRender`), the renderer comes, or the view is resized.
    static func shouldPause(needsRender: Bool, canRender: Bool, animating: Bool) -> Bool {
        !animating && !(needsRender && canRender)
    }

    /// The seconds the renderer's update advances by for a frame due at
    /// `current` after one due at `previous`: the real time between them, at
    /// least 1/240 s and at most 1/10 s (the link rests between motions), a
    /// 60th of a second for the first.
    static func frameDelta(previous: Double?, current: Double) -> Double {
        guard let previous else { return 1.0 / 60 }
        return min(max(current - previous, 1.0 / 240), 1.0 / 10)
    }
}

/// How many frames the renderer holds: asked of it and not yet finished by
/// the GPU. Frames finish on a thread of the renderer's, hence the lock.
final class FramesInFlight: Sendable {
    private let held = Mutex(0)

    var count: Int { held.withLock { $0 } }

    func begin() {
        held.withLock { $0 += 1 }
    }

    func end() {
        held.withLock { $0 = max($0 - 1, 0) }
    }
}
