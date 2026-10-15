import Foundation

/// The Time-Lapse's day: 0° → 180° → 0° over `period` seconds, easing at
/// night and at noon so both ends linger a moment.
enum TimeLapseDay {
    static let period = 16.0

    static func angle(elapsed: Double) -> Double {
        90 * (1 - cos(2 * .pi * elapsed / period))
    }

    /// The inverse on the rising half (0...period / 2): when the day reaches
    /// `degrees`, so a Time-Lapse carries on from the angle the sky shows
    /// instead of jumping to night.
    static func elapsed(risingTo degrees: Double) -> Double {
        let degrees = degrees.isFinite ? min(max(degrees, 0), 180) : 0
        return period * acos(1 - degrees / 90) / (2 * .pi)
    }
}

/// One Time-Lapse as a function of time, so each frame of the sky works out
/// the angle for its own moment. Nothing steps it: a frame that comes late
/// shows the sky where it belongs then, instead of holding the last step
/// and jumping to catch up.
///
/// Times are seconds on one clock; the app uses dates as
/// `timeIntervalSinceReferenceDate`, the clock its timeline's dates give.
struct TimeLapseRun: Equatable, Sendable {
    /// When this day stood at night (0°) before rising.
    let dayStart: Double
    /// When the run stopped; nil while it plays. A stopped run holds the
    /// angle it stopped at, which the sky eases away from.
    private(set) var stoppedAt: Double?

    /// How long the sky takes to leave a stopped run: the app eases the
    /// weight out with a 0.35 s critically damped spring, which keeps 46 %
    /// of the run at 0.1 s, 13 % at 0.2 s and about 0.1 % at 0.5 s.
    static let easeOut = 0.5

    /// A run that shows `angle` at `time` on the rising half of the day, so
    /// it carries on from the sky.
    init(from angle: Double, at time: Double) {
        dayStart = time - TimeLapseDay.elapsed(risingTo: angle)
    }

    /// The run a play starts at `time`. `shown` is the angle the deck shows
    /// (the hinge's, once a stop handed the sky back to it). Within `easing`
    /// of a stop the sky still shows part of the stopped run, so the new one
    /// carries on from the angle that run holds: started from `shown`, the
    /// sky would jump by the stopped run's weight times the gap between the
    /// two (about 50° on the book 0.1 s after a stop at 20°).
    static func start(after previous: TimeLapseRun?, shown: Double, at time: Double, easing: Double = easeOut) -> TimeLapseRun {
        if let previous, let stopped = previous.stoppedAt, time - stopped < easing {
            return TimeLapseRun(from: previous.angle(at: time), at: time)
        }
        return TimeLapseRun(from: shown, at: time)
    }

    var isPlaying: Bool { stoppedAt == nil }

    /// The run's angle at `time`; after the stop, the angle it stopped at.
    func angle(at time: Double) -> Double {
        TimeLapseDay.angle(elapsed: min(time, stoppedAt ?? time) - dayStart)
    }

    mutating func stop(at time: Double) {
        if stoppedAt == nil { stoppedAt = time }
    }

    /// The sky's angle at `time` with the run weighed against `resting`,
    /// the angle the hinge or the slider gives: weight 1 while the run plays,
    /// eased to 0 after it stops, so the sky leaves the day where the run
    /// left it and settles on the hinge without a jump.
    func angle(at time: Double, weight: Double, resting: Double) -> Double {
        let weight = weight.isFinite ? min(max(weight, 0), 1) : 0
        guard weight > 0 else { return resting }
        return weight * angle(at: time) + (1 - weight) * resting
    }
}
