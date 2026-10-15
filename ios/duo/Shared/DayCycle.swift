import Foundation

// The hinge angle as a time of day: night on the cover, noon flat open.
// Everything comes from the angle, never from the hinge's status, which
// reads `closed` in tent (71.1°) and on the cover up to 124° on iOS 27.1.

/// The part of the day the sky shows, named on the deck.
enum DayPhase: String, CaseIterable, Sendable {
    case night, blueHour, sunrise, goldenHour, noon

    var title: String {
        switch self {
        case .night: return "Night"
        case .blueHour: return "Blue Hour"
        case .sunrise: return "Sunrise"
        case .goldenHour: return "Golden Hour"
        case .noon: return "Noon"
        }
    }

    /// An SF Symbol (all of them in SF Symbols 5, iOS 17 and later).
    var symbolName: String {
        switch self {
        case .night: return "moon.stars.fill"
        case .blueHour: return "sun.haze.fill"
        case .sunrise: return "sunrise.fill"
        case .goldenHour: return "sun.horizon.fill"
        case .noon: return "sun.max.fill"
        }
    }
}

/// The day as a function of progress, 0 (closed) to 1 (flat open). The
/// keyframes sit on the angles apps read at Device Hub Pro's postures: tent
/// 71.1° (0.395), laptop 104.2° (0.58), half-open book 127.8° (0.71).
enum DayCycle {
    /// 0 at 0°, 1 at 180°, clamped.
    static func progress(angleDegrees: Double) -> Double {
        clamped(angleDegrees / 180)
    }

    /// night < 45°, blueHour 45..<90, sunrise 90..<116, goldenHour 116..<155,
    /// noon ≥ 155 (in progress units: /180).
    static func phase(progress: Double) -> DayPhase {
        // Each bound is computed the way `progress(angleDegrees:)` computes
        // the angle, so 116° itself lands in golden hour, not a hair short.
        if progress >= 155.0 / 180 { return .noon }
        if progress >= 116.0 / 180 { return .goldenHour }
        if progress >= 90.0 / 180 { return .sunrise }
        if progress >= 45.0 / 180 { return .blueHour }
        return .night
    }

    /// Sun centre height above the horizon as a fraction of the sky's height:
    /// −0.35 (hidden) at night, −0.12 at blue hour (just under the horizon,
    /// so only its glow shows), 0 at sunrise (touching the horizon), 0.22 at
    /// golden hour, 0.78 at noon. It keeps moving through the keyframes
    /// instead of pausing at each, so the time-lapse rises in one stroke.
    static func sunElevation(progress: Double) -> Double {
        sunCurve(clamped(progress))
    }

    /// 1 at 0, 0.5 at 0.22, 0.08 at 0.395, 0 from 0.5.
    static func starOpacity(progress: Double) -> Double {
        starCurve(clamped(progress))
    }

    /// 1 up to 0.15, 0 from 0.4.
    static func moonOpacity(progress: Double) -> Double {
        moonCurve(clamped(progress))
    }

    /// 0 up to 0.5, 0.35 at 0.71, 0.8 at 1.
    static func cloudOpacity(progress: Double) -> Double {
        cloudCurve(clamped(progress))
    }

    /// Warm light along the fold: 0 below 15° and at 180°, 1 from 100° to
    /// 135° (laptop and book), in degrees because it follows the crease's
    /// opening rather than the time of day.
    static func creaseGlow(angleDegrees: Double) -> Double {
        creaseCurve(angleDegrees.isNaN ? 0 : angleDegrees)
    }

    /// How strongly the cover's white text is lifted off the sky: the
    /// opacity of a dark veil behind it. None at night, where the text is
    /// the brightest thing on the panel; most at golden hour, when the low
    /// sun rises in the clock's column and the horizon is at its brightest.
    static func textScrim(progress: Double) -> Double {
        scrimCurve(clamped(progress))
    }

    private static let sunCurve = MonotoneCurve([
        (0, -0.35), (0.22, -0.35), (0.395, -0.12), (0.58, 0), (0.71, 0.22), (1, 0.78),
    ])
    private static let starCurve = MonotoneCurve([(0, 1), (0.22, 0.5), (0.395, 0.08), (0.5, 0), (1, 0)])
    private static let moonCurve = MonotoneCurve([(0, 1), (0.15, 1), (0.4, 0), (1, 0)])
    private static let cloudCurve = MonotoneCurve([(0, 0), (0.5, 0), (0.71, 0.35), (1, 0.8)])
    private static let creaseCurve = MonotoneCurve([(0, 0), (15, 0), (100, 1), (135, 1), (180, 0)])
    private static let scrimCurve = MonotoneCurve([(0, 0), (0.22, 0), (0.395, 0.16), (0.58, 0.32), (0.71, 0.4), (1, 0.3)])

    private static func clamped(_ progress: Double) -> Double {
        progress.isNaN ? 0 : min(max(progress, 0), 1)
    }
}

extension DayCycle {
    /// A smooth curve through keyframes that never overshoots them (monotone
    /// cubic Hermite, Fritsch–Carlson slopes): a flat stretch stays flat, a fade
    /// never leaves 0...1, and the value keeps moving through a keyframe between
    /// two rising stretches. Outside the keyframes it holds the end values.
    private struct MonotoneCurve: Sendable {
        private let xs: [Double]
        private let ys: [Double]
        private let slopes: [Double]

        init(_ points: [(x: Double, y: Double)]) {
            let xs = points.map(\.x)
            let ys = points.map(\.y)
            self.xs = xs
            self.ys = ys
            let count = points.count
            guard count > 1 else {
                slopes = Array(repeating: 0, count: count)
                return
            }
            let widths = (0..<(count - 1)).map { xs[$0 + 1] - xs[$0] }
            let secants = (0..<(count - 1)).map { (ys[$0 + 1] - ys[$0]) / widths[$0] }
            var slopes = Array(repeating: 0.0, count: count)
            for k in 1..<(count - 1) where secants[k - 1] * secants[k] > 0 {
                // The weighted harmonic mean of the two secants (the form for
                // uneven spacing), which keeps the cubic inside the keyframes.
                let w1 = 2 * widths[k] + widths[k - 1]
                let w2 = widths[k] + 2 * widths[k - 1]
                slopes[k] = (w1 + w2) / (w1 / secants[k - 1] + w2 / secants[k])
            }
            slopes[0] = Self.endSlope(widths[0], widths.count > 1 ? widths[1] : widths[0],
                                      secants[0], secants.count > 1 ? secants[1] : secants[0])
            slopes[count - 1] = Self.endSlope(widths[count - 2], count > 2 ? widths[count - 3] : widths[count - 2],
                                              secants[count - 2], count > 2 ? secants[count - 3] : secants[count - 2])
            self.slopes = slopes
        }

        /// The one-sided three-point slope, limited so the end piece cannot
        /// overshoot either.
        private static func endSlope(_ h0: Double, _ h1: Double, _ d0: Double, _ d1: Double) -> Double {
            let slope = ((2 * h0 + h1) * d0 - h0 * d1) / (h0 + h1)
            if slope * d0 <= 0 { return 0 }
            if d0 * d1 <= 0, abs(slope) > abs(3 * d0) { return 3 * d0 }
            return slope
        }

        func callAsFunction(_ x: Double) -> Double {
            guard let first = xs.first, let last = xs.last else { return 0 }
            if x <= first { return ys[0] }
            if x >= last { return ys[ys.count - 1] }
            var k = 0
            while x > xs[k + 1] { k += 1 }
            let h = xs[k + 1] - xs[k]
            let t = (x - xs[k]) / h
            let t2 = t * t
            let t3 = t2 * t
            return (2 * t3 - 3 * t2 + 1) * ys[k]
                + (t3 - 2 * t2 + t) * h * slopes[k]
                + (-2 * t3 + 3 * t2) * ys[k + 1]
                + (t3 - t2) * h * slopes[k + 1]
        }
    }
}
