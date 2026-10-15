import Foundation

/// The book turn of the 3D device as drawn: it follows the turn the face asks
/// for (`DeviceModelScene.easedBook`) with a lag, so turning to the other face
/// is a swing, not a jump.
///
/// A swing is the device turning to the other face off a preset because the
/// lit panel changed (`startSwing`): slower (`DeviceModelScene.faceTurnLag`,
/// 99 % of the way in `DeviceModelScene.rollDuration`, fastest at first), and
/// a frame counts for at most `DeviceModelScene.faceTurnStep` seconds of lag.
/// A lit-panel change arrives after the stage was still for a second or more
/// (a 0.5 s wait and a read of the simulator's screenshots, or 0.3 s of black
/// frames), and the time since the last drawn frame would otherwise count as
/// one long step: a 140° turn across in one frame.
@MainActor
struct BookTurnEase {
    /// The turn as last drawn; nil before the first draw.
    private(set) var shown: Float?
    private var time: ContinuousClock.Instant?
    private var target: Float?
    private var swingEnd: ContinuousClock.Instant?

    /// The turn at `now` on the way to `target`, from the turn drawn before:
    /// at once with Reduce Motion on or before the first draw.
    mutating func advance(
        towards target: Float,
        at now: ContinuousClock.Instant,
        reduceMotion: Bool = MotionMetrics.reduceMotion
    ) -> Float {
        var turn = target
        if let shown, let time, !reduceMotion {
            turn = Self.eased(
                from: shown, to: target, elapsed: Self.seconds(now - time), swinging: isSwinging(at: now)
            )
        }
        shown = turn
        time = now
        self.target = target
        // A swing with nothing left to turn (the faces' turns agree, at 0°)
        // ends: the next fold is eased at the hinge's own pace.
        if abs(turn - target) <= DeviceModelScene.bookSettled { swingEnd = nil }
        return turn
    }

    /// The turn after `elapsed` seconds of lag: `DeviceModelScene.bookLag`
    /// (unclamped, as the presets have always been drawn), or while swinging
    /// `DeviceModelScene.faceTurnLag` with a step of at most
    /// `DeviceModelScene.faceTurnStep` seconds.
    static func eased(from shown: Float, to target: Float, elapsed: Double, swinging: Bool) -> Float {
        let seconds = max(elapsed, 0)
        let lag = swinging ? DeviceModelScene.faceTurnLag : DeviceModelScene.bookLag
        let step = swinging ? min(seconds, DeviceModelScene.faceTurnStep) : seconds
        return shown + (target - shown) * Float(1 - exp(-step / lag))
    }

    /// The face turned (the lit panel changed): the turn drawn so far is
    /// where the swing starts, whenever the last frame was drawn, and it eases
    /// slowly for `DeviceModelScene.rollDuration`.
    mutating func startSwing(at now: ContinuousClock.Instant) {
        time = now
        swingEnd = now + .seconds(DeviceModelScene.rollDuration)
    }

    /// A preset's sweep starts: the hinge sets the pace again.
    mutating func endSwing() { swingEnd = nil }

    /// Forgets the drawn turn: the next one is drawn at once.
    mutating func forget() {
        shown = nil
        time = nil
        target = nil
        swingEnd = nil
    }

    func isSwinging(at now: ContinuousClock.Instant) -> Bool {
        swingEnd.map { now < $0 } ?? false
    }

    /// Whether the drawn turn is where it heads.
    var isSettled: Bool {
        guard let shown, let target else { return true }
        return abs(shown - target) <= DeviceModelScene.bookSettled
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
