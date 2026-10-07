import Foundation

/// The touch dots the stage draws while Control is on (the iOS "Show
/// Touches" idea): a pure model of which dots exist and in what state, fed
/// by `PhysicalControlInputRouter.ActionEvent`s. The view is a thin renderer
/// of `visibleDots(now:)`; nothing here waits for the runner.
///
/// - `pressing`: the pointer is down (a full dot that follows a drag).
/// - `inFlight`: the release is queued or running (a faint ring).
/// - `dropped`: the release was refused as busy (a dashed grey dot, brief).
/// - `fading`: the runner answered; the ring fades out.
public struct TouchFeedbackModel: Sendable, Equatable {
    public struct Dot: Sendable, Equatable {
        public enum Phase: Sendable, Equatable { case pressing, inFlight, dropped, fading }
        /// The touch action's id; 0 for the pressing dot.
        public var id: UInt64
        /// Normalized (0...1) in the stage's frame.
        public var point: CGPoint
        public var phase: Phase
        /// When a `dropped` or `fading` dot began to go away.
        public var goneFrom: TimeInterval?
    }

    public static let fadeDuration: TimeInterval = 0.3
    public static let droppedDuration: TimeInterval = 0.35

    public private(set) var dots: [Dot] = []
    /// No fade animation: dots just appear and disappear.
    public var reduceMotion = false

    public init() {}

    public var isEmpty: Bool { dots.isEmpty }

    public mutating func apply(_ event: PhysicalControlInputRouter.ActionEvent, now: TimeInterval) {
        switch event {
        case .pressed(let point):
            dots.removeAll { $0.phase == .pressing }
            dots.append(Dot(id: 0, point: point, phase: .pressing, goneFrom: nil))
        case .moved(let point):
            if let index = dots.firstIndex(where: { $0.phase == .pressing }) { dots[index].point = point }
        case .cancelled:
            dots.removeAll { $0.phase == .pressing }
        case .accepted(let id, let point):
            dots.removeAll { $0.phase == .pressing }
            dots.append(Dot(id: id, point: point, phase: .inFlight, goneFrom: nil))
        case .dropped(let point):
            dots.removeAll { $0.phase == .pressing }
            dots.append(Dot(id: 0, point: point, phase: .dropped, goneFrom: now))
        case .finished(let id):
            guard let index = dots.firstIndex(where: { $0.id == id && $0.phase == .inFlight }) else { return }
            if reduceMotion {
                dots.remove(at: index)
            } else {
                dots[index].phase = .fading
                dots[index].goneFrom = now
            }
        }
    }

    /// Removes the dots that are gone by `now`.
    public mutating func prune(now: TimeInterval) {
        let live = dots.filter { opacity(of: $0, now: now) > 0 }
        dots = live
    }

    public func visibleDots(now: TimeInterval) -> [Dot] {
        dots.filter { opacity(of: $0, now: now) > 0 }
    }

    /// The dot's opacity at `now`: 1 pressing, faint in flight, a linear
    /// fade for a fading or dropped one (a plain hide with Reduce Motion).
    public func opacity(of dot: Dot, now: TimeInterval) -> Double {
        switch dot.phase {
        case .pressing: return 1
        case .inFlight: return 0.4
        case .fading:
            guard let from = dot.goneFrom else { return 0 }
            let progress = (now - from) / Self.fadeDuration
            return progress >= 1 ? 0 : 0.4 * (1 - max(progress, 0))
        case .dropped:
            guard let from = dot.goneFrom else { return 0 }
            let elapsed = now - from
            if elapsed >= Self.droppedDuration { return 0 }
            return reduceMotion ? 0.8 : 0.8 * (1 - max(elapsed, 0) / Self.droppedDuration)
        }
    }

    /// Seconds after which every current dot is gone, for the pruning timer;
    /// nil while one waits on the runner or the pointer.
    public func settleDelay(now: TimeInterval) -> TimeInterval? {
        var latest: TimeInterval = 0
        for dot in dots {
            switch dot.phase {
            case .pressing, .inFlight: return nil
            case .fading: latest = max(latest, (dot.goneFrom ?? now) + Self.fadeDuration - now)
            case .dropped: latest = max(latest, (dot.goneFrom ?? now) + Self.droppedDuration - now)
            }
        }
        return max(latest, 0)
    }
}
