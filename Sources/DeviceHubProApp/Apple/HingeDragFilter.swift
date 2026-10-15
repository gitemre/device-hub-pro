import DeviceHubProKit

/// What each event of a hinge slider drag does: the 3D model is told the
/// slider's own angle every time it changes, the simulator only when the
/// whole degree it takes (`SimulatorFold.sentAngle`) changes. The slider's
/// events come at the mouse's rate (60–120 a second) and move a fraction of
/// a degree each; sending each of them made the model follow a staircase of
/// whole degrees (a step of about 2° per pointer pixel on the 84 pt slider)
/// and the simulator take repeats.
struct HingeDragFilter {
    /// What one event does.
    struct Move: Equatable {
        /// The slider's angle (0...180, not rounded) for the model.
        var live: Double
        /// The whole degree for the simulator, nil when it is the one last sent.
        var send: Double?
    }

    private var lastLive: Double?
    private var lastSent: (udid: String, angle: Double)?

    /// What an event for `udid` at `degrees` does; nil when it is not a
    /// number, or the same angle again.
    mutating func next(udid: String, degrees: Double) -> Move? {
        guard degrees.isFinite else { return nil }
        let live = min(max(degrees, 0), 180)
        if live == lastLive, lastSent?.udid == udid { return nil }
        lastLive = live
        let angle = SimulatorFold.sentAngle(live)
        if let lastSent, lastSent.udid == udid, lastSent.angle == angle {
            return Move(live: live, send: nil)
        }
        lastSent = (udid, angle)
        return Move(live: live, send: angle)
    }

    /// A new drag, or the hinge moved some other way: the next event sends.
    mutating func reset() {
        lastLive = nil
        lastSent = nil
    }
}
