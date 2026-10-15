import SwiftUI

/// The landscape's drawing, a function per part, painted into the scene's
/// one canvas (`SkyPaint.scene`).
enum LandscapePaint {
    /// Below the horizon, in the lake's points from the horizon (the caller
    /// clips it): the sky turned upside down, darkened by the water the
    /// nearer it comes, with ripples catching the light.
    static func lake(in context: GraphicsContext, frame: SkyFrame, moment: SkyMoment, time: Double) {
        let palette = moment.palette
        let water = Path(CGRect(x: 0, y: 0, width: frame.width, height: frame.lakeHeight))
        context.fill(water, with: .color(palette.water.sceneColor()))
        var mirrored = context
        mirrored.translateBy(x: 0, y: frame.skyHeight)
        mirrored.scaleBy(x: 1, y: -1)
        SkyPaint.world(in: mirrored, frame: frame, moment: moment, time: time, reflected: true)
        // Water reflects less than the sky gives it: a tint over all of it,
        // then more of the water's own colour toward the near shore.
        var tint = context
        tint.blendMode = .multiply
        tint.fill(water, with: .color(palette.water.mixed(with: .sceneWhite, 0.5).sceneColor()))
        context.fill(
            water,
            with: .linearGradient(
                SkyMath.fade([(palette.water, 0.1, 0), (palette.water, 0.4, 0.45), (palette.water, 0.62, 1)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: frame.lakeHeight)
            )
        )
        // The ripples' light adds to the water's as one layer, so where two
        // highlights cross they do not add up twice.
        var light = context
        light.blendMode = .plusLighter
        light.drawLayer { layer in
            ripples(in: &layer, frame: frame, moment: moment, time: time)
        }
    }

    /// Two ranges standing on the horizon, the far one paler with mist at
    /// its foot, both parting where the sun rises so it comes up between
    /// them.
    static func ridges(in context: inout GraphicsContext, frame: SkyFrame, moment: SkyMoment) {
        let palette = moment.palette
        let height = frame.skyHeight
        let width = frame.width

        let far = ridge(
            LandscapeField.farRidge, frame: frame, base: 0.05, amplitude: 0.2,
            valleyDepth: 0.85, valleyWidth: 1.4 * frame.valleyWidth, valleyPower: 1
        )
        context.fill(
            far.fill,
            with: .linearGradient(
                Gradient(colors: [palette.ridgeFar.sceneColor(), palette.ridgeFar.mixed(with: palette.horizon, 0.45).sceneColor()]),
                startPoint: CGPoint(x: 0, y: height - far.peak), endPoint: CGPoint(x: 0, y: height)
            )
        )
        rim(far.crest, in: context, frame: frame, colour: palette.glow, opacity: 0.85 * moment.warmth)

        // Mist between the ranges, thickest in the morning.
        let mistHeight = 0.2 * height
        let mist = 0.22 + 0.3 * moment.warmth
        context.fill(
            Path(CGRect(x: 0, y: height - mistHeight, width: width, height: mistHeight)),
            with: .linearGradient(
                SkyMath.fade([(palette.horizon, 0, 0), (palette.horizon, mist, 1)]),
                startPoint: CGPoint(x: 0, y: height - mistHeight), endPoint: CGPoint(x: 0, y: height)
            )
        )

        let near = ridge(
            LandscapeField.nearRidge, frame: frame, base: 0.02, amplitude: 0.1,
            valleyDepth: 0.94, valleyWidth: frame.valleyWidth, valleyPower: 2
        )
        context.fill(
            near.fill,
            with: .linearGradient(
                Gradient(colors: [palette.ridgeNear.sceneColor(), palette.ridgeNear.mixed(with: palette.water, 0.25).sceneColor()]),
                startPoint: CGPoint(x: 0, y: height - near.peak), endPoint: CGPoint(x: 0, y: height)
            )
        )
        rim(near.crest, in: context, frame: frame, colour: palette.glow, opacity: 0.35 * moment.warmth)
    }

    /// One range's outline from the shared heights: the same mountains at
    /// any width, spread over at least 760 pt about the sun's column so a
    /// narrow cover shows them as large as the wide inner panel does.
    private static func ridge(
        _ heights: [Double], frame: SkyFrame, base: Double, amplitude: Double,
        valleyDepth: Double, valleyWidth: Double, valleyPower: Double
    ) -> (fill: Path, crest: Path, peak: Double) {
        let skyHeight = frame.skyHeight
        let span = max(frame.width, 760) + 2 * abs(frame.lightX - frame.width / 2)
        let left = frame.lightX - span / 2
        let step = span / Double(max(heights.count - 1, 1))
        var crest = Path()
        var peak = 0.0
        var first: Double?
        var last = 0.0
        for (index, value) in heights.enumerated() {
            let x = left + Double(index) * step
            guard x >= -step, x <= frame.width + step else { continue }
            // The gap: exp(−d²) slopes the far range down into it like
            // distant hills; exp(−d⁴) gives the near one a flat floor and
            // steep sides, so it keeps its crests up to the gap.
            let distance = (x - frame.lightX) / valleyWidth
            let rise = skyHeight * (base + amplitude * value)
                * (1 - valleyDepth * exp(-pow(distance * distance, valleyPower)))
            peak = max(peak, rise)
            let point = CGPoint(x: x, y: skyHeight - rise)
            if first == nil {
                crest.move(to: point)
                first = x
            } else {
                crest.addLine(to: point)
            }
            last = x
        }
        var fill = crest
        fill.addLine(to: CGPoint(x: last, y: skyHeight + 2))
        fill.addLine(to: CGPoint(x: first ?? 0, y: skyHeight + 2))
        fill.closeSubpath()
        return (fill, crest, peak)
    }

    /// Low sun catching the crests nearest it.
    private static func rim(_ crest: Path, in context: GraphicsContext, frame: SkyFrame, colour: RGB, opacity: Double) {
        guard opacity > 0.01 else { return }
        var rim = context
        rim.blendMode = .plusLighter
        rim.stroke(
            crest,
            with: .linearGradient(
                SkyMath.fade([(colour, 0, 0), (colour, opacity, 0.5), (colour, 0, 1)]),
                startPoint: CGPoint(x: frame.lightX - 0.5 * frame.width, y: 0),
                endPoint: CGPoint(x: frame.lightX + 0.5 * frame.width, y: 0)
            ),
            lineWidth: 1.5
        )
    }

    /// Thin highlights that shimmer on the timeline: a few across the lake, a
    /// path of glints under the sun (and the moon at night), and the line
    /// where the water meets the shore.
    static func ripples(in context: inout GraphicsContext, frame: SkyFrame, moment: SkyMoment, time: Double) {
        let palette = moment.palette
        let width = frame.width

        // The waterline.
        let shore = palette.horizon.mixed(with: .sceneWhite, 0.6)
        context.fill(
            Path(CGRect(x: 0, y: 0, width: width, height: 1.2)),
            with: .linearGradient(
                SkyMath.fade([(shore, 0, 0), (shore, 0.2 + 0.25 * moment.warmth, 0.5), (shore, 0, 1)]),
                startPoint: CGPoint(x: frame.lightX - 0.5 * width, y: 0),
                endPoint: CGPoint(x: frame.lightX + 0.5 * width, y: 0)
            )
        )

        // Faint ripples across the whole lake, catching the sky.
        let ripple = moment.rippleStreak
        let rippleStrength = 0.1 + 0.12 * palette.horizon.luminance
        for line in LandscapeField.ripples {
            let shimmer = 0.5 + 0.5 * sin(time * line.speed + line.phase)
            highlight(
                in: context, gradient: ripple, opacity: rippleStrength * (0.25 + 0.75 * shimmer * shimmer),
                centerX: (0.5 + line.offset) * width + sin(time * 0.3 + line.phase) * line.sway,
                y: line.depth * frame.lakeHeight,
                length: line.length * width * (0.5 + line.depth), thickness: 0.6 + 1.4 * line.depth
            )
        }

        // The low sun's mirror image: under the water's tint the reflected
        // disc reads as a dull ochre coin, so give it back some of its light,
        // drawn out downwards as rippled water draws a reflection. A high
        // sun leaves no mirrored disc (`SkyPaint.mirroredSun`).
        let elevation = moment.sunElevation
        let reflection = SkyMath.smoothstep(-0.07, 0.02, elevation)
        let mirrorGlow = reflection * (1 - SkyMath.smoothstep(0.3, 0.6, elevation))
        if mirrorGlow > 0.01 {
            let radius = 1.7 * frame.sunRadius
            let light = palette.sun.mixed(with: .sceneWhite, 0.3)
            var glow = context
            glow.translateBy(x: frame.lightX, y: elevation * frame.skyHeight)
            glow.scaleBy(x: 1, y: 1.3)
            glow.fill(
                SkyMath.circle(.zero, radius),
                with: .radialGradient(
                    SkyMath.fade([(light, 0.32 * mirrorGlow, 0), (light, 0.18 * mirrorGlow, 0.5), (light, 0, 1)]),
                    center: .zero, startRadius: 0, endRadius: radius
                )
            )
        }

        // The light's path on the water: the low sun's is longest and
        // brightest, starting at the shore; a high sun's lies farther out but
        // stops short of the lake's foot, where the deck and the bottom bar
        // sit, and is fainter.
        let sunGlints = reflection * (1 - 0.6 * SkyMath.smoothstep(0.3, 0.78, elevation))
        if sunGlints > 0.01 {
            glints(
                in: context, frame: frame, time: time, x: frame.lightX,
                gradient: moment.sunStreak, strength: 0.9 * sunGlints,
                nearest: 0.04 + 0.4 * min(max(elevation, 0) / 0.78, 1)
            )
        }
        if moment.moon > 0.01 {
            glints(
                in: context, frame: frame, time: time, x: frame.moonCenter(progress: moment.progress).x,
                gradient: LandscapeField.moonStreak, strength: 0.45 * moment.moon, nearest: 0.6
            )
        }
    }

    /// `nearest` is where along the lake (0 at the shore, 1 at the bottom)
    /// the path is brightest.
    private static func glints(
        in context: GraphicsContext, frame: SkyFrame, time: Double, x: Double,
        gradient: Gradient, strength: Double, nearest: Double
    ) {
        let width = frame.width
        for glint in LandscapeField.glints {
            let spread = (0.02 + 0.14 * glint.depth) * width
            let shimmer = 0.5 + 0.5 * sin(time * glint.speed + glint.phase)
            let falloff = exp(-pow((glint.depth - nearest) / 0.55, 2))
            highlight(
                in: context, gradient: gradient, opacity: strength * falloff * (0.2 + 0.8 * shimmer * shimmer),
                centerX: x + 2 * glint.offset * spread + sin(time * 0.45 + glint.phase) * glint.sway,
                y: glint.depth * frame.lakeHeight,
                length: (0.012 + 0.05 * glint.depth) * width * (0.6 + glint.length * 4),
                thickness: 0.8 + 1.6 * glint.depth
            )
        }
    }

    /// A thin capsule of light, fading out at both ends.
    private static func highlight(
        in context: GraphicsContext, gradient: Gradient, opacity: Double,
        centerX: Double, y: Double, length: Double, thickness: Double
    ) {
        guard opacity > 0.006, length > 1 else { return }
        var context = context
        context.opacity *= opacity
        let rect = CGRect(x: centerX - length / 2, y: y - thickness / 2, width: length, height: thickness)
        context.fill(
            Path(roundedRect: rect, cornerRadius: thickness / 2),
            with: .linearGradient(gradient, startPoint: CGPoint(x: rect.minX, y: y), endPoint: CGPoint(x: rect.maxX, y: y))
        )
    }

    /// Warm light along the fold, as if the sun shone through it: a feathered
    /// band down the book's spine, or along the laptop's crease, which is the
    /// horizon there.
    static func crease(in context: inout GraphicsContext, frame: SkyFrame, moment: SkyMoment) {
        let palette = moment.palette
        let light = palette.glow.mixed(with: palette.sun, 0.45).mixed(with: .sceneWhite, 0.1)
        context.opacity = 0.45 * moment.crease
        switch frame.fold {
        case .none:
            return
        case .spine(let x, let halfWidth):
            // Light pooling where the sun meets the horizon, gone a quarter
            // of the page above and below it: a beam the page's full height
            // would read as a seam beside the real crease, and the zenith
            // stays clean.
            let horizon = frame.horizonY / frame.height
            band(
                in: &context, colour: light, frame: frame, vertical: true, center: x, halfWidth: max(halfWidth, 8),
                along: [(0, 0), (horizon - 0.25, 0.12), (horizon, 1), (horizon + 0.25, 0.12), (1, 0.05)]
            )
        case .crease(let y, let halfHeight):
            // Along the horizon, strongest under the sun.
            band(
                in: &context, colour: light, frame: frame, vertical: false, center: y, halfWidth: max(halfHeight, 8),
                along: [(0, 0.35), (frame.lightX / frame.width, 1), (1, 0.35)]
            )
        }
    }

    /// A feathered core three margins either side of the fold, with a faint
    /// bloom three times wider, kept along its length as much as `along`
    /// says (opacity at a fraction of the length, in order).
    private static func band(
        in context: inout GraphicsContext, colour: RGB, frame: SkyFrame, vertical: Bool,
        center: Double, halfWidth: Double, along: [(location: Double, opacity: Double)]
    ) {
        let length = vertical ? frame.height : frame.width
        func rect(_ half: Double) -> Path {
            Path(vertical
                ? CGRect(x: center - half, y: 0, width: 2 * half, height: length)
                : CGRect(x: 0, y: center - half, width: length, height: 2 * half))
        }
        func across(_ offset: Double) -> CGPoint {
            vertical ? CGPoint(x: center + offset, y: 0) : CGPoint(x: 0, y: center + offset)
        }
        let bloom = 9 * halfWidth
        let core = 3 * halfWidth
        context.drawLayer { layer in
            layer.fill(
                rect(bloom),
                with: .linearGradient(
                    SkyMath.fade([(colour, 0, 0), (colour, 0.12, 0.5), (colour, 0, 1)]),
                    startPoint: across(-bloom), endPoint: across(bloom)
                )
            )
            layer.fill(
                rect(core),
                with: .linearGradient(
                    SkyMath.fade([
                        (colour, 0, 0), (colour, 0.14, 0.3), (colour, 0.5, 0.5), (colour, 0.14, 0.7), (colour, 0, 1),
                    ]),
                    startPoint: across(-core), endPoint: across(core)
                )
            )
            // Keep what is drawn only as much as the fade along the fold lets.
            layer.blendMode = .destinationIn
            layer.fill(
                rect(bloom),
                with: .linearGradient(
                    SkyMath.fade(along.map { (.sceneWhite, $0.opacity, min(max($0.location, 0), 1)) }),
                    startPoint: .zero, endPoint: vertical ? CGPoint(x: 0, y: length) : CGPoint(x: length, y: 0)
                )
            )
        }
    }
}

/// The fixed mountains and ripples, chosen once from a seed.
enum LandscapeField {
    struct Highlight: Sendable {
        /// 0 at the shore, 1 at the bottom of the lake; denser near the
        /// shore, as perspective packs distant ripples.
        var depth: Double
        /// Horizontal, −0.5...0.5.
        var offset: Double
        /// A fraction of the width.
        var length: Double
        /// Points of slow side-to-side drift.
        var sway: Double
        /// Shimmer, in radians per second.
        var speed: Double
        var phase: Double
    }

    /// 257 samples: about one per 3–4 pt on the widest window.
    static let farRidge = Ridge.heights(seed: 9, count: 257, roughness: 0.55)
    static let nearRidge = Ridge.heights(seed: 0x0EA2_1D6E_5EED_0042, count: 257, roughness: 0.6)

    static let ripples: [Highlight] = highlights(count: 18, seed: 0x21BB_1E55_0000_0001, length: 0.05...0.14)
    static let glints: [Highlight] = highlights(count: 22, seed: 0x611A_7700_0000_0002, length: 0.05...0.25)
    static let moonStreak = SkyMath.streak(SkyField.moonlight)

    private static func highlights(count: Int, seed: UInt64, length: ClosedRange<Double>) -> [Highlight] {
        var random = SplitMix64(seed: seed)
        return (0..<count).map { index in
            // Spread evenly in depth, then jittered, so no two bunch up.
            let slot = (Double(index) + random.between(0.15, 0.85)) / Double(count)
            return Highlight(
                depth: pow(slot, 1.6),
                offset: random.between(-0.5, 0.5),
                length: random.between(length.lowerBound, length.upperBound),
                sway: random.between(2, 7),
                speed: random.between(0.7, 1.7),
                phase: random.between(0, 2 * .pi)
            )
        }
    }
}
