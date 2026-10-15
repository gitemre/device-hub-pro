import Foundation

/// The colours of one moment of the day, back to front.
struct SkyPalette: Equatable, Sendable {
    /// Sky top → horizon; `glow` is the warm band at the horizon, under the sun.
    var zenith, upper, horizon, glow: RGB
    /// Mountain layers: the far range, lighter as haze would make it, and the near one.
    var ridgeFar, ridgeNear: RGB
    /// The lake's base tint (the reflection is drawn over it).
    var water: RGB
    /// The sun's disc.
    var sun: RGB
}

extension DayCycle {
    /// Smoothstep-interpolated between keyframes: each posture's own colours
    /// hold for a moment around its angle, and the change between two eases
    /// in and out instead of turning a corner at the keyframe.
    static func palette(progress: Double) -> SkyPalette {
        let keyframes = SkyKeyframe.all
        let progress = progress.isNaN ? 0 : min(max(progress, 0), 1)
        guard let after = keyframes.firstIndex(where: { $0.progress > progress }) else {
            return keyframes[keyframes.count - 1].palette
        }
        let from = keyframes[after - 1]
        let to = keyframes[after]
        let t = (progress - from.progress) / (to.progress - from.progress)
        return SkyKeyframe.blend(from.palette, to.palette, t * t * (3 - 2 * t))
    }
}

extension DayCycle {
    /// One keyframe of the day. The sky colours are chosen; the ridges and the
    /// lake are derived from them, so they always sit in the same light.
    private struct SkyKeyframe: Sendable {
        let progress: Double
        let palette: SkyPalette

        /// The near ridge's colour at noon, a cool blue-grey that reads as
        /// rock in daylight rather than sky.
        private static let daylightRock = RGB(hex: 0x3E5872)

        private static let nightSun = RGB(hex: 0xFFE9B0)
        private static let blueHourSun = RGB(hex: 0xFF9E6E)

        static let all: [SkyKeyframe] = [
            SkyKeyframe(0, zenith: 0x070B24, upper: 0x121A45, horizon: 0x2B2A68, glow: 0x3A2F72, sun: nightSun),
            // Pre-dawn has no sun colour of its own (the sun is far below the
            // horizon): the straight line between night's and blue hour's.
            SkyKeyframe(0.22, zenith: 0x0E1640, upper: 0x23306A, horizon: 0x4B4A8E, glow: 0x6C568F,
                        sun: nightSun.mixed(with: blueHourSun, 0.22 / 0.395)),
            SkyKeyframe(0.395, zenith: 0x1C2F6B, upper: 0x3D5AA0, horizon: 0x8D8FC4, glow: 0xE7A7B2, sun: blueHourSun),
            SkyKeyframe(0.58, zenith: 0x2E4F9C, upper: 0x6A86C6, horizon: 0xF4A582, glow: 0xFFC27A, sun: RGB(hex: 0xFFB347)),
            SkyKeyframe(0.71, zenith: 0x3C6FBF, upper: 0x8DB5E6, horizon: 0xFFD59A, glow: 0xFFE3A8, sun: RGB(hex: 0xFFD166)),
            SkyKeyframe(1, zenith: 0x1F6FD8, upper: 0x4E9BEB, horizon: 0xA9D6FF, glow: 0xE8F4FF, sun: RGB(hex: 0xFFFBEA)),
        ]

        private init(_ progress: Double, zenith: UInt32, upper: UInt32, horizon: UInt32, glow: UInt32, sun: RGB) {
            let zenith = RGB(hex: zenith)
            let upper = RGB(hex: upper)
            let horizon = RGB(hex: horizon)
            // Noon's zenith is a deeper blue than golden hour's, which would
            // darken the far ridge and the lake from golden hour to noon; a lift
            // that only wakes toward noon keeps both brightening all day.
            let lift = progress * progress * progress
            self.progress = progress
            palette = SkyPalette(
                zenith: zenith,
                upper: upper,
                horizon: horizon,
                glow: RGB(hex: glow),
                ridgeFar: Self.scale(upper.mixed(with: zenith, 0.35), 0.62 + 0.28 * lift),
                ridgeNear: Self.scale(zenith.mixed(with: Self.daylightRock, progress), 0.45 + 0.55 * progress),
                water: Self.scale(horizon.mixed(with: zenith, 0.5), 0.8 + 0.1 * lift),
                sun: sun
            )
        }

        static func blend(_ a: SkyPalette, _ b: SkyPalette, _ t: Double) -> SkyPalette {
            SkyPalette(
                zenith: a.zenith.mixed(with: b.zenith, t),
                upper: a.upper.mixed(with: b.upper, t),
                horizon: a.horizon.mixed(with: b.horizon, t),
                glow: a.glow.mixed(with: b.glow, t),
                ridgeFar: a.ridgeFar.mixed(with: b.ridgeFar, t),
                ridgeNear: a.ridgeNear.mixed(with: b.ridgeNear, t),
                water: a.water.mixed(with: b.water, t),
                sun: a.sun.mixed(with: b.sun, t)
            )
        }

        private static func scale(_ colour: RGB, _ factor: Double) -> RGB {
            RGB(r: colour.r * factor, g: colour.g * factor, b: colour.b * factor)
        }
    }
}
