import SwiftUI

/// The whole picture: sky, stars, moon, sun, clouds, mountains, lake and the crease light, filling its frame.
///
/// One composition for every posture: the fold only moves the horizon and
/// the sun's column, so the same landscape re-flows around it instead of
/// each posture getting a screen of its own. The angle is the time of day
/// and is animatable, so `.animation(value: angle)` glides between the
/// hinge's 26–30 Hz steps. A playing Time-Lapse is worked out on a second
/// timeline, every frame, from its own clock; its weight eases the sky into
/// it and back out to the angle. Twinkling, drifting clouds and ripples run
/// on one timeline, which stops under Reduce Motion and in Low Power Mode.
///
/// The caller labels it for VoiceOver: it knows the hinge's own angle, which
/// the animated angle here is not during a Time-Lapse.
struct SkyScene: View, Animatable {
    /// The hinge's or the slider's angle in degrees (0...180).
    var angle: Double
    /// The Time-Lapse, playing or stopped (the sky then eases from the angle
    /// it stopped at); nil before the first.
    var timeLapse: TimeLapseRun?
    /// 1 while the Time-Lapse plays, 0 otherwise: animated, so the sky eases
    /// between the Time-Lapse and `angle` (`TimeLapseRun.angle(at:weight:resting:)`).
    var timeLapseWeight: Double
    /// From `FoldLayout.layout(...)` in the window's coordinates. The scene
    /// fills the window from its origin, so the two agree.
    var layout: SceneLayout
    /// Where the sun rises when no fold places it (the cover), in the
    /// window's points: the middle of the space the vertical bar leaves, so
    /// the sun comes up under the clock. Nil is the window's middle.
    var focusX: Double?
    /// The right edge of the space the vertical bar leaves (the window's
    /// width without a bar on that side), which the moon keeps inside.
    var clearMaxX: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    init(
        angle: Double, timeLapse: TimeLapseRun? = nil, timeLapseWeight: Double = 0,
        layout: SceneLayout, focusX: Double? = nil, clearMaxX: Double? = nil
    ) {
        self.angle = angle
        self.timeLapse = timeLapse
        self.timeLapseWeight = timeLapseWeight
        self.layout = layout
        self.focusX = focusX
        self.clearMaxX = clearMaxX
    }

    nonisolated var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(angle, timeLapseWeight) }
        set {
            angle = newValue.first
            timeLapseWeight = newValue.second
        }
    }

    /// The ambient timeline's rate at rest. Every frame cost the iPhone Duo
    /// simulator about twice the CPU at rest (app and render server), for
    /// clouds that move at most a fifth of a point a tick; while the
    /// Time-Lapse plays, the ambient motion takes its frames.
    static let ambientInterval = 1.0 / 30

    var body: some View {
        // Without a Time-Lapse in the picture, the moment is worked out once
        // per frame of the angle's animation, and the ambient ticks reuse it.
        let run = timeLapseWeight > 0 ? timeLapse : nil
        let resting = run == nil ? SkyMoment(angleDegrees: angle) : nil
        let playing = run?.isPlaying == true
        let ambientPaused = reduceMotion || lowPower
        GeometryReader { proxy in
            let frame = SkyFrame(size: proxy.size, layout: layout, focusX: focusX, clearMaxX: clearMaxX)
            // Paused while the Time-Lapse plays, whose frames then carry the
            // ambient motion too: its ticks would only rebuild the inner
            // timeline. It resumes at the current time, so nothing jumps.
            TimelineView(.animation(minimumInterval: Self.ambientInterval, paused: ambientPaused || playing)) { ambient in
                // Every frame while the Time-Lapse plays; under Reduce Motion
                // it steps 30 times a second, as the ambient motion stops.
                TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 / 30 : nil, paused: !playing)) { clock in
                    let now = clock.date.timeIntervalSinceReferenceDate
                    let moment = resting
                        ?? SkyMoment(angleDegrees: run?.angle(at: now, weight: timeLapseWeight, resting: angle) ?? angle)
                    let time = playing && !ambientPaused ? clock.date : ambient.date
                    SkyCanvas(frame: frame, moment: moment, time: time.timeIntervalSinceReferenceDate)
                }
            }
        }
        .ignoresSafeArea()
        .task {
            // Low Power Mode has no environment value: its notification
            // flips the timeline's pause while the scene is on screen.
            for await _ in NotificationCenter.default.messages(of: ProcessInfo.self, for: .powerStateDidChange) {
                lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
    }
}

/// The scene at one tick of the ambient timeline, in one canvas that the
/// GPU renders off the main thread (`SkyPaint.scene`).
///
/// One layer: as many layers (each canvas, the mesh, the blend modes), every
/// frame waited on the GPU once per layer, and in a Time-Lapse the inner
/// panel dropped about 16 frames a second on the iPhone Duo simulator, the
/// cover 4. Rendered on the main thread, as a `.drawingGroup()` is, the one
/// layer still kept it waiting for the GPU every frame: 1.7 ms of the 4.8 ms
/// a Time-Lapse frame took at rest, and far longer while the simulator and
/// Device Hub Pro draw a fold, when a preset's sweep on the inner panel
/// dropped to 32–51 frames a second (the frames' main-thread time was mostly
/// that wait, `RB::RenderFrame` in a sample). Rendered asynchronously, a
/// Time-Lapse frame takes 3.1 ms, as with no sky at all. The picture is the
/// drawing group's to within 5 levels in 255 (Closed, Laptop, Partially Open
/// and Open, under 0.003 % of the pixels off by more than 2).
struct SkyCanvas: View {
    let frame: SkyFrame
    let moment: SkyMoment
    let time: Double

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, _ in
            SkyPaint.scene(in: context, frame: frame, moment: moment, time: time)
        }
        .frame(width: frame.width, height: frame.height)
    }
}

extension SkyPaint {
    /// The sky above the horizon, its reflection below, the fold's light over
    /// both, in the window's points. A part that blends with what lies under
    /// it as a whole (the glow, the ridges and their lit rims, the ripples)
    /// is drawn in a layer of its own, as it was when each was a view; the
    /// rest paints straight onto the scene, which composites the same. The
    /// fold's light already is one layer (it fades along the fold), which
    /// adds to the scene as the view did, so it needs no second round it.
    static func scene(in context: GraphicsContext, frame: SkyFrame, moment: SkyMoment, time: Double) {
        var sky = context
        sky.clip(to: Path(CGRect(x: 0, y: 0, width: frame.width, height: frame.skyHeight)))
        world(in: sky, frame: frame, moment: moment, time: time, reflected: false)

        var lake = context
        lake.translateBy(x: 0, y: frame.horizonY)
        lake.clip(to: Path(CGRect(x: 0, y: 0, width: frame.width, height: frame.lakeHeight)))
        LandscapePaint.lake(in: lake, frame: frame, moment: moment, time: time)

        if moment.crease > 0.004, frame.fold != .none {
            var crease = context
            crease.blendMode = .plusLighter
            LandscapePaint.crease(in: &crease, frame: frame, moment: moment)
        }
    }
}

/// Everything the angle decides, worked out once per frame of its animation
/// and handed to every part of the drawing, so the timeline's ticks reuse it.
struct SkyMoment: Equatable, Sendable {
    /// The angle the moment is made from, clamped to 0...180. Everything
    /// else follows from it, so `==` compares it alone: SwiftUI compares the
    /// moment on every tick, and one number is cheapest.
    let angle: Double
    let progress: Double
    let palette: SkyPalette
    let sunElevation: Double
    let stars: Double
    let moon: Double
    let clouds: Double
    /// The fold's light, from the angle itself (`DayCycle.creaseGlow`).
    let crease: Double
    /// How warm the low light is: it rises through blue hour, holds over
    /// sunrise and golden hour and mostly fades by noon. It tints the
    /// horizon, the clouds' lit sides and the ridges' rims.
    let warmth: Double
    /// The clouds' two soft passes, the shaded underside a little lower and
    /// then the lit tops: two passes read as volume without a blur.
    let cloudPasses: [CloudPass]
    /// The sun's and the sky's light on the water, for the ripples.
    let sunStreak: Gradient
    let rippleStreak: Gradient

    struct CloudPass: Sendable {
        /// How far below the puff's centre the pass sits, in its radii.
        let drop: Double
        let gradient: Gradient
    }

    init(angleDegrees: Double) {
        let angle = angleDegrees.isFinite ? min(max(angleDegrees, 0), 180) : 0
        let progress = DayCycle.progress(angleDegrees: angle)
        let palette = DayCycle.palette(progress: progress)
        let warmth = SkyMath.smoothstep(0.25, 0.52, progress) * (1 - 0.85 * SkyMath.smoothstep(0.74, 0.98, progress))
        self.angle = angle
        self.progress = progress
        self.palette = palette
        self.warmth = warmth
        sunElevation = DayCycle.sunElevation(progress: progress)
        stars = DayCycle.starOpacity(progress: progress)
        moon = DayCycle.moonOpacity(progress: progress)
        clouds = DayCycle.cloudOpacity(progress: progress)
        crease = DayCycle.creaseGlow(angleDegrees: angle)

        let lit = RGB.sceneWhite.mixed(with: palette.glow, 0.6 * warmth)
        let shade = palette.upper.mixed(with: palette.horizon, 0.5).mixed(with: .sceneWhite, 0.18)
        cloudPasses = [(shade, 0.4, 0.24), (lit, 0.8, -0.04)].map { colour, peak, drop in
            CloudPass(drop: drop, gradient: SkyMath.fade([
                (colour, peak, 0), (colour, peak * 0.92, 0.5), (colour, peak * 0.5, 0.78), (colour, 0, 1),
            ]))
        }
        sunStreak = SkyMath.streak(palette.sun.mixed(with: .sceneWhite, 0.35))
        rippleStreak = SkyMath.streak(palette.horizon.mixed(with: .sceneWhite, 0.55))
    }

    static func == (a: SkyMoment, b: SkyMoment) -> Bool {
        a.angle == b.angle
    }
}

/// Where the scene's parts sit in a frame of a given size, in its points.
struct SkyFrame: Equatable, Sendable {
    /// The fold as the scene draws it: the book's spine, the laptop's
    /// crease (which is also the horizon) or none.
    enum Fold: Equatable, Sendable {
        case none
        case spine(x: Double, halfWidth: Double)
        case crease(y: Double, halfHeight: Double)
    }

    let width: Double
    let height: Double
    /// Whole points, so the sky and its reflection meet on a pixel edge.
    let horizonY: Double
    /// The sun's column: the spine in a book, else `focusX` or the middle.
    let lightX: Double
    /// The right edge of the space the vertical bar leaves clear.
    let clearMaxX: Double
    let fold: Fold

    init(size: CGSize, layout: SceneLayout, focusX: Double? = nil, clearMaxX: Double? = nil) {
        let width = max(Double(size.width), 1)
        let height = max(Double(size.height), 1)
        self.clearMaxX = clearMaxX.flatMap { $0.isFinite ? min(max($0, 0.5 * width), width) : nil } ?? width
        // Clamped, so a layout worked out for another size (a pass during a
        // fold) still leaves room for both sky and lake.
        func horizon(_ y: Double) -> Double {
            (y.isFinite ? min(max(y, 0.3 * height), 0.85 * height) : 0.64 * height).rounded()
        }
        self.width = width
        self.height = height
        switch layout {
        case .single(let horizonY):
            self.horizonY = horizon(horizonY)
            lightX = focusX.flatMap { $0.isFinite ? min(max($0, 0.25 * width), 0.75 * width) : nil } ?? width / 2
            fold = .none
        case .book(let spineX, let halfWidth, let horizonY):
            self.horizonY = horizon(horizonY)
            let spine = spineX.isFinite ? min(max(spineX, 0.25 * width), 0.75 * width) : width / 2
            lightX = spine
            fold = .spine(x: spine, halfWidth: halfWidth.isFinite ? max(halfWidth, 0) : 0)
        case .lidAndBase(let creaseY, let halfHeight):
            let crease = horizon(creaseY)
            horizonY = crease
            lightX = width / 2
            fold = .crease(y: crease, halfHeight: halfHeight.isFinite ? max(halfHeight, 0) : 0)
        }
    }

    var skyHeight: Double { horizonY }
    var lakeHeight: Double { height - horizonY }
    /// Where the lake's mirror image of the sky starts showing, in the sky's
    /// points: the lake is shallower than the sky everywhere but the laptop,
    /// so the reflection skips stars and clouds higher than this.
    var reflectedFromY: Double { max(skyHeight - lakeHeight, 0) }
    /// The frame's shorter side, which sizes the sun, the moon and the clouds
    /// alike on the cover and inside.
    var unit: Double { min(width, height) }
    var sunRadius: Double { 0.07 * unit }
    var moonRadius: Double { 0.03 * unit }

    func sunCenter(elevation: Double) -> CGPoint {
        CGPoint(x: lightX, y: horizonY - elevation * skyHeight)
    }

    /// High on the trailing side (the trailing page in a book), sinking a
    /// little as it fades toward blue hour. Placed between the sun's column
    /// and the space the vertical bar leaves, so its halo (five radii) stays
    /// clear of the bar: on the 466 pt portrait cover the disc ends 72 pt
    /// before it.
    func moonCenter(progress: Double) -> CGPoint {
        let x = lightX + 0.55 * max(clearMaxX - lightX, 0)
        return CGPoint(x: x, y: skyHeight * (0.2 + 0.08 * min(max(progress / 0.4, 0), 1)))
    }

    /// Half the floor of the gap between the mountains where the sun rises,
    /// so the ridges never hide it at sunrise.
    var valleyWidth: Double { 1.3 * sunRadius }
}

enum SkyMath {
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    static func circle(_ center: CGPoint, _ radius: Double) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
    }

    /// A gradient that fades `colour` out to its own transparent self, so
    /// the edge does not pass through grey as a fade to `.clear` can.
    static func fade(_ stops: [(colour: RGB, opacity: Double, location: Double)]) -> Gradient {
        Gradient(stops: stops.map { Gradient.Stop(color: $0.colour.sceneColor($0.opacity), location: $0.location) })
    }

    /// Clear at both ends, `colour` in the middle: one per colour, each
    /// highlight drawn with it setting its own opacity.
    static func streak(_ colour: RGB) -> Gradient {
        fade([(colour, 0, 0), (colour, 1, 0.5), (colour, 0, 1)])
    }
}

/// The stars, clouds and ripples are chosen once from a seed: the same sky on
/// every launch and every device.
extension SplitMix64 {
    mutating func between(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * unit()
    }
}

extension RGB {
    static let sceneWhite = RGB(r: 1, g: 1, b: 1)

    /// This colour for SwiftUI, in sRGB as the palette is written.
    func sceneColor(_ opacity: Double = 1) -> Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}
