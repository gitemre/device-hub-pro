import CoreGraphics
import Foundation

/// One device as drawn, in layout units: where the screen sits, how its
/// corner is rounded, where the camera cutout goes and what body surrounds
/// it. Every consumer draws from this one plan (the live stage, the stopped
/// device's hero, framed screenshots), so a device cannot change shape
/// between them. Built by `DeviceCompositionPlanner`; placed at a scale with
/// `placed(pointsPerUnit:pixelScale:buttonPad:)`.
///
/// Layout units are skin artwork pixels for a skin body and device pixels of
/// the screen as shown for a vector body. Rects are top-left based.
public struct DeviceComposition: Sendable, Hashable {
    /// The fill under a skin's transparent screen opening, at `screenRect`:
    /// it shows before the first frame and in letterbox bars.
    public struct Backing: Sendable, Hashable {
        /// Layout units.
        public var cornerRadius: CGFloat
        /// sRGB components, drawn with `RGBA.srgbColor`.
        public var color: RGBA

        public init(cornerRadius: CGFloat, color: RGBA) {
            self.cornerRadius = cornerRadius
            self.color = color
        }
    }

    /// The concentric body drawn for a screen without a skin
    /// (`ChromeSpec`, converted to layout units).
    public struct VectorBody: Sendable, Hashable {
        public var family: DeviceFamily
        /// Screen edge to body edge, layout units.
        public var bezel: CGFloat
        /// The body's corner: the screen corner's radius plus `bezel`, at
        /// most half the body's short side.
        public var outerRadius: CGFloat
        /// Layout units, outside-in, as the spec gives them (before
        /// `placed` holds each at one pixel or more).
        public var bandWidths: [CGFloat]
        public var bandColors: [RGBA]
        /// The body inside the bands.
        public var glass: RGBA

        public init(
            family: DeviceFamily,
            bezel: CGFloat,
            outerRadius: CGFloat,
            bandWidths: [CGFloat],
            bandColors: [RGBA],
            glass: RGBA
        ) {
            self.family = family
            self.bezel = bezel
            self.outerRadius = outerRadius
            self.bandWidths = bandWidths
            self.bandColors = bandColors
            self.glass = glass
        }
    }

    /// A simulator's Apple chrome (`AppleChromeFrame`): its frame, built
    /// around the screen in chrome points, drawn at `unitsPerPoint` layout
    /// units per point (the display's scale, so layout units are the
    /// screen's pixels) and turned `quarterTurns` counter-clockwise.
    public struct AppleChromeBody: Sendable, Hashable {
        public var art: AppleChromeArt
        /// Native (portrait), chrome points.
        public var layout: AppleChromeLayout
        public var unitsPerPoint: CGFloat
        public var quarterTurns: Int
        /// The display's corner, chrome points: the screen's clip when the
        /// device type has no outline (`AppleChromeArt.hasMask`).
        public var cornerRadius: CGFloat
        /// The device type's sensor-bar picture (`AppleChromeFrame.sensorBar`),
        /// for a consumer that draws a placeholder screen; nil for none.
        public var sensorBar: URL?
        /// The screen has a Dynamic Island (`AppleChromeFrame.hasDynamicIsland`).
        public var hasDynamicIsland: Bool

        public init(
            art: AppleChromeArt,
            layout: AppleChromeLayout,
            unitsPerPoint: CGFloat,
            quarterTurns: Int,
            cornerRadius: CGFloat,
            sensorBar: URL? = nil,
            hasDynamicIsland: Bool = false
        ) {
            self.art = art
            self.layout = layout
            self.unitsPerPoint = unitsPerPoint
            self.quarterTurns = quarterTurns
            self.cornerRadius = cornerRadius
            self.sensorBar = sensorBar
            self.hasDynamicIsland = hasDynamicIsland
        }

        /// Maps native chrome points to the composition's layout units
        /// (turned): scaled by `unitsPerPoint`, then turned.
        public var pointsToUnits: CGAffineTransform {
            let native = CGSize(
                width: layout.canvasSize.width * unitsPerPoint,
                height: layout.canvasSize.height * unitsPerPoint
            )
            return CGAffineTransform(scaleX: unitsPerPoint, y: unitsPerPoint)
                .concatenating(AppleChromeLayout.turn(canvas: native, quarterTurns: quarterTurns))
        }
    }

    public enum Body: Sendable, Hashable {
        /// SDK skin artwork at `artworkRect` (layout units; it can overhang
        /// the layout box, which clips it), a backing under its opening
        /// (nil for legacy skins without one), whether the legacy foreground
        /// mask is drawn over the screen and whether an `onion` overlay is.
        case skin(artworkRect: CGRect, backing: Backing?, drawsLegacyMask: Bool, hasOverlay: Bool)
        case vector(VectorBody)
        /// Apple's device chrome, read at runtime from the user's Xcode.
        case appleChrome(AppleChromeBody)
    }

    /// The whole device (`PosePresentation.nativeSize`).
    public var layoutSize: CGSize
    public var screenRect: CGRect
    public var screenCorner: ScreenCorner
    /// Drawn by the host; nil when the stream carries its own or the
    /// display's rotation is not known.
    public var cutout: CutoutPlacement?
    public var body: Body
    /// The side buttons painted into a skin's artwork, their `rect`s in
    /// layout units (`baseline` and `depth` stay artwork pixels); empty for
    /// a vector body.
    public var buttons: [SkinHardwareButton]

    public init(
        layoutSize: CGSize,
        screenRect: CGRect,
        screenCorner: ScreenCorner,
        cutout: CutoutPlacement?,
        body: Body,
        buttons: [SkinHardwareButton] = []
    ) {
        self.layoutSize = layoutSize
        self.screenRect = screenRect
        self.screenCorner = screenCorner
        self.cutout = cutout
        self.body = body
        self.buttons = buttons
    }

    /// The plan at `pointsPerUnit` (points, or pixels for a bitmap, per
    /// layout unit) on a display of `pixelScale` pixels per point.
    ///
    /// - `buttonPad` widens the canvas by that many points on both sides,
    ///   so the layout box stays centred, and extends the clip on the right
    ///   only, where the side buttons slide out.
    /// - The backing is outset by 2 pixels past the screen on every side, so
    ///   the artwork's anti-aliased opening edge lies over it instead of over
    ///   the stage.
    /// - Each vector band is held at one pixel or more, so the thin rim and
    ///   highlight do not fade out at small sizes.
    public func placed(pointsPerUnit: CGFloat, pixelScale: CGFloat, buttonPad: CGFloat = 0) -> PlacedComposition {
        let scale = pointsPerUnit
        let pixel = pixelScale > 0 ? 1 / pixelScale : 0
        let origin = CGPoint(x: buttonPad, y: 0)
        func place(_ rect: CGRect) -> CGRect {
            CGRect(
                x: origin.x + rect.minX * scale,
                y: origin.y + rect.minY * scale,
                width: rect.width * scale,
                height: rect.height * scale
            )
        }
        let box = CGRect(origin: origin, size: CGSize(width: layoutSize.width * scale, height: layoutSize.height * scale))
        let screen = place(screenRect)

        var artworkFrame: CGRect?
        var backingFrame: CGRect?
        var backingRadius: CGFloat = 0
        var backingColor: RGBA?
        var bands: [PlacedBand] = []
        switch body {
        case let .skin(artworkRect, backing, _, _):
            artworkFrame = place(artworkRect)
            if let backing {
                let outset = 2 * pixel
                backingFrame = screen.insetBy(dx: -outset, dy: -outset)
                backingRadius = backing.cornerRadius * scale + outset
                backingColor = backing.color
            }
        case .appleChrome:
            artworkFrame = box
        case let .vector(vector):
            // Filled rounded rects, each drawn over the one before: a band
            // shows as the ring between its rect and the next one's.
            let outer = vector.outerRadius * scale
            let maxInset = min(box.width, box.height) / 2
            var inset: CGFloat = 0
            for (index, color) in (vector.bandColors + [vector.glass]).enumerated() {
                let clamped = min(inset, maxInset)
                bands.append(PlacedBand(
                    rect: box.insetBy(dx: clamped, dy: clamped),
                    cornerRadius: max(outer - clamped, 0),
                    color: color
                ))
                if index < vector.bandWidths.count {
                    inset += max(vector.bandWidths[index] * scale, pixel)
                }
            }
        }

        return PlacedComposition(
            size: CGSize(width: box.width + 2 * buttonPad, height: box.height),
            layoutOrigin: origin,
            screen: screen,
            screenCornerRadius: screenCorner.radius * scale,
            artworkFrame: artworkFrame,
            backingFrame: backingFrame,
            backingRadius: backingRadius,
            backingColor: backingColor,
            bands: bands,
            clipRect: CGRect(x: origin.x, y: origin.y, width: box.width + buttonPad, height: box.height),
            cutout: cutout
        )
    }
}

/// One filled rounded rect of a placed vector body.
public struct PlacedBand: Sendable, Hashable {
    public var rect: CGRect
    public var cornerRadius: CGFloat
    public var color: RGBA

    public init(rect: CGRect, cornerRadius: CGFloat, color: RGBA) {
        self.rect = rect
        self.cornerRadius = cornerRadius
        self.color = color
    }
}

/// A `DeviceComposition` at one scale, in points (or pixels) of a canvas of
/// `size`, top-left based. Rects are unsnapped: the live stage's geometry
/// stays what Tier 1 verified.
public struct PlacedComposition: Sendable, Hashable {
    /// The layout at scale, plus `buttonPad` on both sides.
    public var size: CGSize
    /// Where the layout box starts: (`buttonPad`, 0).
    public var layoutOrigin: CGPoint
    public var screen: CGRect
    public var screenCornerRadius: CGFloat
    /// Skin bodies: the artwork; Apple chrome: the whole canvas.
    public var artworkFrame: CGRect?
    /// Skin bodies with a backing: `screen` outset by 2 pixels on every side.
    public var backingFrame: CGRect?
    /// The backing's corner, outset with it; 0 without one.
    public var backingRadius: CGFloat
    public var backingColor: RGBA?
    /// Vector bodies only: outside-in, each at least one pixel wide; the
    /// last is the glass.
    public var bands: [PlacedBand]
    /// The layout box, extended by `buttonPad` on the right only.
    public var clipRect: CGRect
    public var cutout: CutoutPlacement?

    /// Where a stream of `stream` pixels is drawn: aspect-fit and centred in
    /// `screen` (a stream whose sides were rounded, or a foldable's frame of
    /// the other panel while the plan catches up, is letterboxed, never
    /// stretched). `screen` itself for an empty size.
    public func videoRect(stream: CGSize) -> CGRect {
        guard stream.width > 0, stream.height > 0, screen.width > 0, screen.height > 0 else {
            return screen
        }
        let scale = min(screen.width / stream.width, screen.height / stream.height)
        let fit = CGSize(width: stream.width * scale, height: stream.height * scale)
        return CGRect(
            x: screen.minX + (screen.width - fit.width) / 2,
            y: screen.minY + (screen.height - fit.height) / 2,
            width: fit.width,
            height: fit.height
        )
    }

    /// The cutout in the video view's own coordinates (origin at its
    /// top-left corner), for a video drawn at `inVideoRect`; nil without one.
    public func cutoutPath(inVideoRect: CGRect) -> CGPath? {
        cutout?.path(in: CGRect(origin: .zero, size: inVideoRect.size))
    }
}
