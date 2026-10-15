import Foundation

/// What each hinge reading means for the sky, kept apart from SwiftUI so the
/// Mac tests can run it: DayModel hands it `onHingeChange`'s angles and the
/// Time-Lapse's start and stop, and carries out the step it returns.
struct HingeFollower: Equatable, Sendable {
    /// Whether the device has a hinge, as far as the app knows yet.
    enum Availability: Equatable, Sendable {
        /// No reading yet. On the iOS 27.1 iPhone Duo simulator the first
        /// came 0.35–2.6 s after launch over nine launches.
        case waiting
        case present
        /// A reading without a hinge, or none within the model's grace.
        case absent
    }

    /// What the model does about one event.
    enum Step: Equatable, Sendable {
        /// Nothing the sky shows changes: a hand resting on the device
        /// during a Time-Lapse, the first reading of a Time-Lapse started
        /// before it, or "no hinge" again.
        case none
        /// Show the hinge's angle. `jump` for a reading that arrives rather
        /// than moves (the first after launch, or after the hinge went
        /// away), so the scene is simply right when it appears.
        case show(degrees: Double, jump: Bool)
        /// The hinge moved past `timeLapseTolerance` during a Time-Lapse.
        case stopTimeLapse
        /// The device has no hinge: the slider takes over.
        case noHinge
    }

    /// A move larger than this stops the Time-Lapse; smaller ones are a hand
    /// resting on the device.
    static let timeLapseTolerance = 2.0

    private(set) var availability = Availability.waiting
    private(set) var isTimeLapsing = false
    /// Where the hinge rested when the Time-Lapse started; nil when it
    /// started before the first reading, which then sets it.
    private(set) var timeLapseAnchor: Double?

    /// Before the first reading the sky shows the likeliest posture for the
    /// window instead of night everywhere: the narrow cover is a closed
    /// phone (0°), the wide inner window most often the half-open book
    /// (127.8°). The first reading then jumps to the real angle.
    static func likelyAngle(regularWidth: Bool) -> Double {
        regularWidth ? 127.8 : 0
    }

    /// One `onHingeChange` call, as the old and new angles in degrees (nil
    /// without a hinge). SwiftUI repeats values at rest; the model drops the
    /// writes that change nothing.
    mutating func reading(old: Double?, new: Double?) -> Step {
        guard let degrees = new else {
            guard availability != .absent else { return .none }
            availability = .absent
            return .noHinge
        }
        guard degrees.isFinite else { return .none }
        // `old` is nil on SwiftUI's first call; a reading after the grace
        // or after "no hinge" arrives too, whatever `old` says.
        let arrives = old == nil || availability != .present
        availability = .present
        guard isTimeLapsing else { return .show(degrees: degrees, jump: arrives) }
        guard let anchor = timeLapseAnchor else {
            timeLapseAnchor = degrees
            return .none
        }
        return abs(degrees - anchor) > Self.timeLapseTolerance ? .stopTimeLapse : .none
    }

    /// No reading came within the grace: the device has no hinge.
    mutating func graceEnded() -> Step {
        guard availability == .waiting else { return .none }
        availability = .absent
        return .noHinge
    }

    /// `hinge`: the angle the hinge rests at, nil before the first reading.
    mutating func timeLapseStarted(hinge: Double?) {
        isTimeLapsing = true
        timeLapseAnchor = hinge
    }

    mutating func timeLapseStopped() {
        isTimeLapsing = false
        timeLapseAnchor = nil
    }
}
