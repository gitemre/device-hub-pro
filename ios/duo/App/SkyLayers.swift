import SwiftUI

/// The sky's drawing, a function per part, painted into the scene's one
/// canvas (`SkyPaint.scene`).
enum SkyPaint {
    /// Everything above the horizon, in the sky's points from its top left
    /// (the caller clips it): drawn once for the sky and once, upside down,
    /// for the lake, so the reflection always matches. For the lake
    /// (`reflected`) the twinkling and drifting parts skip what lies above
    /// `frame.reflectedFromY`, which the lake never shows, and a high sun
    /// leaves no mirrored disc.
    static func world(in context: GraphicsContext, frame: SkyFrame, moment: SkyMoment, time: Double, reflected: Bool) {
        let fromY = reflected ? frame.reflectedFromY : 0
        // The sky's colour, the warm band along the horizon, the sun and the
        // moon.
        context.fill(
            Path(CGRect(x: 0, y: 0, width: frame.width, height: frame.skyHeight)),
            with: .style(mesh(frame: frame, moment: moment))
        )
        // Screen, so the glow and the halo lighten the sky's own colour the
        // way light does instead of painting over it.
        var light = context
        light.blendMode = .screen
        light.drawLayer { layer in
            glow(in: &layer, frame: frame, moment: moment, reflected: reflected)
        }
        var discs = context
        bodies(in: &discs, frame: frame, moment: moment, reflected: reflected)
        if moment.stars > 0.004 {
            var layer = context
            stars(in: &layer, frame: frame, moment: moment, time: time, fromY: fromY)
        }
        if moment.clouds > 0.004 {
            var layer = context
            clouds(in: &layer, frame: frame, moment: moment, time: time, fromY: fromY)
        }
        // A layer of their own: the lit rims add to the ridges and the clear
        // layer round them, not to the sky beside them.
        context.drawLayer { layer in
            LandscapePaint.ridges(in: &layer, frame: frame, moment: moment)
        }
    }

    /// Zenith, upper sky and horizon rows; the glow sits under the sun's
    /// column and bows up into the sky as the light warms.
    static func mesh(frame: SkyFrame, moment: SkyMoment) -> MeshGradient {
        let palette = moment.palette
        let column = Float(min(max(frame.lightX / frame.width, 0.2), 0.8))
        let dome = Float(0.08 * moment.warmth)
        let points: [SIMD2<Float>] = [
            [0, 0], [column, 0], [1, 0],
            [0, 0.56], [column, 0.5 - dome], [1, 0.56],
            [0, 1], [column, 1], [1, 1],
        ]
        let zenith = palette.zenith.sceneColor()
        let upper = palette.upper.sceneColor()
        let horizon = palette.horizon.sceneColor()
        let colors: [Color] = [
            zenith, zenith, zenith,
            upper, palette.upper.mixed(with: palette.glow, 0.22 * moment.warmth).sceneColor(), upper,
            horizon, palette.glow.sceneColor(), horizon,
        ]
        return MeshGradient(width: 3, height: 3, points: points, colors: colors)
    }

    /// In the lake, a sun higher than about 0.35 of the sky leaves its
    /// mirror image to the glints: its disc would sit low on the water,
    /// right under the deck and the bottom bar of the tall inner window.
    static func mirroredSun(_ elevation: Double, reflected: Bool) -> Double {
        reflected ? 1 - SkyMath.smoothstep(0.35, 0.6, elevation) : 1
    }

    static func glow(in context: inout GraphicsContext, frame: SkyFrame, moment: SkyMoment, reflected: Bool) {
        let palette = moment.palette
        let skyHeight = frame.skyHeight

        // The band of warm light along the horizon, wider than tall, centred
        // under the sun's column.
        let strength = 0.14 + 0.5 * moment.warmth
        let radius = 0.8 * max(frame.width, skyHeight)
        var band = context
        band.translateBy(x: frame.lightX, y: skyHeight)
        band.scaleBy(x: 1, y: 0.5)
        band.fill(
            SkyMath.circle(.zero, radius),
            with: .radialGradient(
                SkyMath.fade([(palette.glow, strength, 0), (palette.glow, strength * 0.42, 0.38), (palette.glow, 0, 1)]),
                center: .zero, startRadius: 0, endRadius: radius
            )
        )

        // The sun's halo shows before the sun does: at blue hour its centre
        // is under the horizon and only this light reaches the sky.
        let elevation = moment.sunElevation
        let halo = SkyMath.smoothstep(-0.30, -0.06, elevation) * mirroredSun(elevation, reflected: reflected)
        guard halo > 0.004 else { return }
        let center = frame.sunCenter(elevation: elevation)
        let sunRadius = frame.sunRadius
        let outer = 7 * sunRadius
        context.fill(
            SkyMath.circle(center, outer),
            with: .radialGradient(
                SkyMath.fade([(palette.sun, 0.42 * halo, 0), (palette.sun, 0.15 * halo, 0.3), (palette.sun, 0, 1)]),
                center: center, startRadius: 0, endRadius: outer
            )
        )
        let inner = 2.3 * sunRadius
        let near = palette.sun.mixed(with: .sceneWhite, 0.45)
        context.fill(
            SkyMath.circle(center, inner),
            with: .radialGradient(
                SkyMath.fade([(near, 0.6 * halo, 0.4), (near, 0, 1)]),
                center: center, startRadius: 0, endRadius: inner
            )
        )
    }

    static func bodies(in context: inout GraphicsContext, frame: SkyFrame, moment: SkyMoment, reflected: Bool) {
        let palette = moment.palette

        // A crisp disc, lighter at its heart, cut by the horizon (the frame
        // clips it; the lake shows the rest as its reflection).
        let center = frame.sunCenter(elevation: moment.sunElevation)
        let radius = frame.sunRadius
        let sunOpacity = mirroredSun(moment.sunElevation, reflected: reflected)
        if center.y - radius < frame.skyHeight, sunOpacity > 0.004 {
            var sun = context
            sun.opacity = sunOpacity
            sun.fill(
                SkyMath.circle(center, radius),
                with: .radialGradient(
                    SkyMath.fade([
                        (palette.sun.mixed(with: .sceneWhite, 0.5), 1, 0),
                        (palette.sun.mixed(with: .sceneWhite, 0.36), 1, 0.6),
                        (palette.sun.mixed(with: .sceneWhite, 0.1), 1, 1),
                    ]),
                    center: center, startRadius: 0, endRadius: radius
                )
            )
        }

        guard moment.moon > 0.004 else { return }
        var moon = context
        moon.opacity = moment.moon
        let moonCenter = frame.moonCenter(progress: moment.progress)
        let moonRadius = frame.moonRadius
        let moonlight = SkyField.moonlight
        moon.fill(
            SkyMath.circle(moonCenter, 5 * moonRadius),
            with: .radialGradient(
                SkyMath.fade([(moonlight, 0.2, 0), (moonlight, 0.06, 0.4), (moonlight, 0, 1)]),
                center: moonCenter, startRadius: 0, endRadius: 5 * moonRadius
            )
        )
        // Earthshine on the dark side, and the crescent lit from below the
        // horizon toward the sun's column.
        let disc = SkyMath.circle(moonCenter, moonRadius)
        moon.fill(disc, with: .color(red: 0.5, green: 0.55, blue: 0.72, opacity: 0.3))
        let shadow = SkyMath.circle(
            CGPoint(x: moonCenter.x + 0.42 * moonRadius, y: moonCenter.y - 0.36 * moonRadius), 0.98 * moonRadius
        )
        moon.fill(
            disc.subtracting(shadow),
            with: .linearGradient(
                Gradient(colors: [Color(.sRGB, red: 1, green: 0.98, blue: 0.92), Color(.sRGB, red: 0.9, green: 0.9, blue: 0.88)]),
                startPoint: CGPoint(x: moonCenter.x - moonRadius, y: moonCenter.y + moonRadius),
                endPoint: CGPoint(x: moonCenter.x + moonRadius, y: moonCenter.y - moonRadius)
            )
        )
    }

    /// About 140 fixed stars that twinkle on the timeline and fade toward
    /// the horizon, where the sky is brighter; those above `fromY` are left
    /// out (the reflection's hidden part).
    static func stars(in context: inout GraphicsContext, frame: SkyFrame, moment: SkyMoment, time: Double, fromY: Double) {
        let width = frame.width
        let height = frame.skyHeight
        // No stars over the moon's disc and its brightest halo.
        let moonCenter = frame.moonCenter(progress: moment.progress)
        let keepOut = moment.moon > 0.004 ? pow(2.6 * frame.moonRadius, 2) : 0
        for star in SkyField.stars {
            let x = star.x * width
            let y = star.y * height
            if y + 4.5 * star.radius < fromY { continue }
            if keepOut > 0, pow(x - moonCenter.x, 2) + pow(y - moonCenter.y, 2) < keepOut { continue }
            let twinkle = 0.68 + 0.32 * sin(time * star.speed + star.phase)
            let alpha = moment.stars * star.brightness * star.horizonFade * twinkle
            guard alpha > 0.01 else { continue }
            let center = CGPoint(x: x, y: y)
            let tint = SkyField.starTints[star.tint]
            context.fill(
                SkyMath.circle(center, star.radius),
                with: .color(.sRGB, red: tint.r, green: tint.g, blue: tint.b, opacity: alpha)
            )
            if star.radius > 1.1 {
                let glow = 4.5 * star.radius
                var halo = context
                halo.opacity = alpha
                halo.fill(
                    SkyMath.circle(center, glow),
                    with: .radialGradient(SkyField.starGlows[star.tint], center: center, startRadius: 0, endRadius: glow)
                )
            }
        }
    }

    /// A few soft clouds drifting slowly across, lit warm at golden hour and
    /// white at noon; those wholly above `fromY` are left out (the
    /// reflection's hidden part).
    static func clouds(in context: inout GraphicsContext, frame: SkyFrame, moment: SkyMoment, time: Double, fromY: Double) {
        context.opacity = moment.clouds
        for cloud in SkyField.clouds {
            let cloudWidth = cloud.width * frame.unit
            let centerY = cloud.altitude * frame.skyHeight
            // Its lowest puff reaches about 0.36 of its width below the
            // centre, squashed.
            if centerY + 0.6 * cloudWidth * cloud.squash < fromY { continue }
            // Each cloud wraps round once it has fully left the frame, so it
            // never pops in or out.
            let margin = 0.8 * cloudWidth
            let span = frame.width + 2 * margin
            var x = (cloud.start * span + time * cloud.speed).truncatingRemainder(dividingBy: span)
            if x < 0 { x += span }
            let centerX = x - margin
            for pass in moment.cloudPasses {
                for puff in cloud.puffs {
                    let radius = puff.radius * cloudWidth
                    var layer = context
                    layer.translateBy(
                        x: centerX + puff.dx * cloudWidth,
                        y: centerY + (puff.dy * cloudWidth + pass.drop * radius) * cloud.squash
                    )
                    layer.scaleBy(x: 1, y: cloud.squash)
                    layer.fill(
                        SkyMath.circle(.zero, radius),
                        with: .radialGradient(pass.gradient, center: .zero, startRadius: 0, endRadius: radius)
                    )
                }
            }
        }
    }
}

/// The fixed stars and clouds, chosen once from a seed.
enum SkyField {
    struct Star: Sendable {
        /// Fractions of the sky's width and height.
        var x: Double
        var y: Double
        /// In points.
        var radius: Double
        var brightness: Double
        /// 1 high up, fading to a tenth just above the horizon.
        var horizonFade: Double
        /// Twinkling, in radians per second.
        var speed: Double
        var phase: Double
        /// An index into `starTints`.
        var tint: Int
    }

    struct Puff: Sendable {
        /// Offsets and radius in the cloud's widths.
        var dx: Double
        var dy: Double
        var radius: Double
    }

    struct Cloud: Sendable {
        /// Where it is along its drift at time 0, as a fraction of the drift.
        var start: Double
        /// Its centre, as a fraction of the sky's height from the top.
        var altitude: Double
        /// As a fraction of the frame's shorter side.
        var width: Double
        /// How flat its puffs are: lower clouds, farther away, are flatter.
        var squash: Double
        /// Points per second; lower clouds drift slower, as distant ones look.
        var speed: Double
        var puffs: [Puff]
    }

    /// White, and a few warm and cool stars among them.
    static let starTints = [RGB.sceneWhite, RGB(r: 1, g: 0.93, b: 0.82), RGB(r: 0.84, g: 0.9, b: 1)]
    /// The bright stars' halos, one per tint.
    static let starGlows = starTints.map { SkyMath.fade([($0, 0.35, 0), ($0, 0, 1)]) }
    static let moonlight = RGB(r: 0.86, g: 0.9, b: 1)

    static let stars: [Star] = {
        var random = SplitMix64(seed: 0x0DA7_B4EA_C057_A125)
        return (0..<140).map { _ in
            let x = random.unit()
            let y = pow(random.unit(), 1.25) * 0.9
            let size = random.unit()
            let tint = random.unit()
            return Star(
                x: x, y: y,
                radius: 0.45 + 1.05 * size * size * size,
                brightness: random.between(0.35, 1),
                horizonFade: 1 - 0.9 * SkyMath.smoothstep(0.45, 0.9, y),
                speed: random.between(0.5, 1.9),
                phase: random.between(0, 2 * .pi),
                tint: tint < 0.2 ? 1 : tint > 0.75 ? 2 : 0
            )
        }
    }()

    static let clouds: [Cloud] = {
        var random = SplitMix64(seed: 0xC10D_5EED_2026_1015)
        let shapes: [(altitude: Double, width: Double, squash: Double, speed: Double)] = [
            (0.13, 0.5, 0.56, 6.5),
            (0.27, 0.38, 0.5, 5.2),
            (0.4, 0.56, 0.42, 4.2),
            (0.53, 0.42, 0.36, 3.3),
            (0.66, 0.66, 0.28, 2.6),
        ]
        return shapes.enumerated().map { index, shape in
            // A bank of puffs, biggest in the middle and riding higher there,
            // so the tops billow and the base stays nearly flat.
            let count = 9
            let puffs = (0..<count).map { puff -> Puff in
                let along = (Double(puff) + random.between(-0.3, 0.3)) / Double(count - 1) - 0.5
                let middle = max(1 - 2 * abs(along), 0)
                let radius = 0.07 + 0.13 * middle + random.between(0, 0.06)
                return Puff(dx: 0.86 * along, dy: -0.5 * radius * middle + random.between(-0.03, 0.03), radius: radius)
            }
            return Cloud(
                start: (Double(index) * 0.37 + random.between(0, 0.15)).truncatingRemainder(dividingBy: 1),
                altitude: shape.altitude, width: shape.width, squash: shape.squash, speed: shape.speed,
                puffs: puffs
            )
        }
    }()
}
