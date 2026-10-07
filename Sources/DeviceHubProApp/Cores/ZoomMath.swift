import CoreGraphics

/// The stage zoom's arithmetic: Device Hub's multiplicative zoom steps, the
/// fitted scale, the physical-size scale and the presentation ratio a zoom
/// change animates away.
///
/// `WindowState` keeps `stageZoom`, `zoomPresentation` and the animation
/// task, and asks this type for the numbers. `stageZoom` is a multiplier of
/// the fitted layout (nil = fit); the *absolute* scale on screen is the
/// video's points per streamed pixel (`measured`, published by the mirror
/// view), which is what the physical size and the step limits are counted
/// in.
enum ZoomMath {
    /// Device Hub's steps (TB-08, measured live against Device Hub 27.0):
    /// every Zoom In multiplies the scale by 1.25 and every Zoom Out by
    /// 0.75. They are not inverses, and there is no ladder: a step is taken
    /// from wherever the scale is.
    static let stepUp = 1.25
    static let stepDown = 0.75

    /// The scale limits, as multiples of the physical-size scale. Device Hub
    /// greys Zoom Out at 0.45 of physical (an iPhone 17's whole body then
    /// measured 105 pt wide) and Zoom In at about ten times it.
    static let minimumOfPhysical = 0.45
    static let maximumOfPhysical = 10.0

    /// The stage never draws a device larger than one point per streamed
    /// pixel (`PoseFit.scale`'s cap: the artwork is not upscaled), so that
    /// is the ceiling whatever ten times the physical scale would be.
    static let nativeCeiling = 1.0

    /// The limits as multipliers of the fitted layout while no physical
    /// scale is known (no display density read yet).
    static let fallbackRange: ClosedRange<Double> = 0.25...8.0

    /// How close two scales must be to count as the same one.
    static let tolerance = 0.005

    /// The largest scale Zoom In reaches, points per streamed pixel.
    static func maximum(physical: Double) -> Double {
        max(min(physical * maximumOfPhysical, nativeCeiling), physical)
    }

    /// Fit counts as 1.0 for a step taken from it.
    static func multiplier(_ zoom: Double?) -> Double { zoom ?? 1.0 }

    /// The zoom (a multiplier of the fitted layout) one step up or down
    /// lands on, clamped to the limits.
    ///
    /// - `measured`: the video's points per streamed pixel now, nil before
    ///   the first layout.
    /// - `physical`: the points per streamed pixel of the device at its real
    ///   size, nil while its density is unknown.
    static func step(from zoom: Double?, up: Bool, measured: Double?, physical: Double?) -> Double {
        let current = multiplier(zoom)
        let stepped = current * (up ? stepUp : stepDown)
        guard let measured, measured > 0, let physical, physical > 0 else {
            return min(max(stepped, fallbackRange.lowerBound), fallbackRange.upperBound)
        }
        let target = measured * (stepped / current)
        let clamped = min(max(target, physical * minimumOfPhysical), maximum(physical: physical))
        return current * clamped / measured
    }

    /// Whether Zoom Out has nowhere left to go.
    static func isAtMinimum(zoom: Double?, measured: Double?, physical: Double?) -> Bool {
        guard let measured, measured > 0, let physical, physical > 0 else {
            return multiplier(zoom) <= fallbackRange.lowerBound * (1 + tolerance)
        }
        return measured <= physical * minimumOfPhysical * (1 + tolerance)
    }

    /// Whether Zoom In has nowhere left to go.
    static func isAtMaximum(zoom: Double?, measured: Double?, physical: Double?) -> Bool {
        guard let measured, measured > 0, let physical, physical > 0 else {
            return multiplier(zoom) >= fallbackRange.upperBound * (1 - tolerance)
        }
        return measured >= maximum(physical: physical) * (1 - tolerance)
    }

    /// The zoom that shows the device at its real size, from the scale on
    /// screen now; nil while either scale is unknown. The layout is
    /// (nearly) proportional to the zoom, so the ratio lands close; the
    /// stage corrects the remainder once it has laid out
    /// (`correction(...)`).
    static func physicalZoom(from zoom: Double?, measured: Double?, physical: Double?) -> Double? {
        guard let measured, measured > 0, let physical, physical > 0 else { return nil }
        return multiplier(zoom) * physical / measured
    }

    /// The zoom that closes what is left of the gap to the physical size
    /// after a layout; nil when the scale is within tolerance (or unknown).
    static func correction(from zoom: Double?, measured: Double?, physical: Double?) -> Double? {
        guard let measured, measured > 0, let physical, physical > 0,
              abs(measured / physical - 1) > tolerance
        else { return nil }
        return multiplier(zoom) * physical / measured
    }

    /// Zoom-to-fit: the stage fits the device (Device Hub's "Zoom to Fit").
    static func isFit(zoom: Double?) -> Bool {
        zoom == nil
    }

    /// The fitted scale (device points per Mac point) used by the stage:
    /// 0 until the stream's pixel size and a viewport are known.
    static func fitScale(devicePixelSize: CGSize?, viewport: CGSize) -> Double {
        guard let pixels = devicePixelSize,
              viewport.width > 0,
              viewport.height > 0
        else {
            return 0
        }
        let margin = 0.96
        return min(
            viewport.width * margin / Double(pixels.width),
            viewport.height * margin / Double(pixels.height)
        )
    }

    // MARK: - Physical size

    /// The panel's dpi to count with: its `xDpi` when believable, else the
    /// logical density, else `fallback`; nil when none is known. The same
    /// rule the vector body's planner sizes with
    /// (`DeviceCompositionPlanner.density(of:fallback:)`), without its
    /// invented default: an unknown density has no physical size.
    static func devicePixelsPerInch(xDpi: Double?, densityDpi: Int?, fallback: Double?) -> Double? {
        if let xDpi, (120.0...800.0).contains(xDpi) { return xDpi }
        if let densityDpi, densityDpi > 0 { return Double(densityDpi) }
        if let fallback, fallback.isFinite, fallback > 0 { return fallback }
        return nil
    }

    /// The Mac's points per inch on `screen`: the display's EDID size over
    /// its width in points; `fallback` when the display reports none (a
    /// virtual display) or something implausible.
    static func macPointsPerInch(screenWidthMillimetres: Double, screenWidthPoints: Double, fallback: Double = 110) -> Double {
        guard screenWidthMillimetres > 50, screenWidthPoints > 0 else { return fallback }
        let ppi = screenWidthPoints / (screenWidthMillimetres / 25.4)
        return (40.0...400.0).contains(ppi) ? ppi : fallback
    }

    /// Mac points per streamed pixel that show the device at its real
    /// size: the Mac's points per inch over the panel's pixels per inch,
    /// times the panel's pixels per streamed pixel (a stream downscaled
    /// from the panel covers more of it per pixel).
    static func physicalPointsPerPixel(
        macPointsPerInch: Double,
        devicePixelsPerInch: Double,
        panelLongSide: Double?,
        streamLongSide: Double?
    ) -> Double? {
        guard macPointsPerInch > 0, devicePixelsPerInch > 0 else { return nil }
        var ratio = 1.0
        if let panelLongSide, let streamLongSide, panelLongSide > 0, streamLongSide > 0 {
            ratio = panelLongSide / streamLongSide
        }
        return macPointsPerInch / devicePixelsPerInch * ratio
    }

    /// Mac points per streamed pixel that show one device point per Mac
    /// point (Simulator.app's Point Accurate): the panel's pixels per point
    /// is `densityDpi / 160` (dp on Android, the screen scale on iOS), so a
    /// panel pixel is `160 / densityDpi` Mac points, carried to the stream's
    /// pixels by the panel-over-stream ratio. Nil while the density is
    /// unknown.
    static func pointAccuratePointsPerPixel(
        densityDpi: Double?,
        panelLongSide: Double?,
        streamLongSide: Double?
    ) -> Double? {
        guard let densityDpi, densityDpi > 0 else { return nil }
        return 160 / densityDpi * panelOverStream(panelLongSide, streamLongSide)
    }

    /// Mac points per streamed pixel that show one device pixel per Mac
    /// screen pixel (Pixel Accurate): a screen pixel is `1 / backingScale`
    /// Mac points.
    static func pixelAccuratePointsPerPixel(
        backingScaleFactor: Double,
        panelLongSide: Double?,
        streamLongSide: Double?
    ) -> Double? {
        guard backingScaleFactor > 0 else { return nil }
        return panelOverStream(panelLongSide, streamLongSide) / backingScaleFactor
    }

    /// The panel's pixels per streamed pixel (1 when either is unknown).
    private static func panelOverStream(_ panel: Double?, _ stream: Double?) -> Double {
        guard let panel, let stream, panel > 0, stream > 0 else { return 1 }
        return panel / stream
    }

    /// What a zoom change does to the presentation multiplier.
    struct Transition: Equatable, Sendable {
        /// `zoomPresentation` in the same update as the new `stageZoom`.
        let presentation: CGFloat
        /// Whether it then animates back to 1 on the next runloop turn.
        let animatesToIdentity: Bool
    }

    /// The presentation for a change from `oldZoom` to `newZoom` (nil =
    /// fit, which counts as 1). The old/new ratio is applied relative to the
    /// *current* presentation, so a second step while the first still
    /// animates continues from what is on screen. With Reduce Motion, no
    /// change or a non-positive zoom it snaps to 1 without an animation.
    static func transition(
        from oldZoom: Double?,
        to newZoom: Double?,
        currentPresentation: CGFloat,
        reduceMotion: Bool
    ) -> Transition {
        let oldValue = oldZoom ?? 1
        let newValue = newZoom ?? 1
        guard !reduceMotion, oldValue != newValue, newValue > 0 else {
            return Transition(presentation: 1, animatesToIdentity: false)
        }
        return Transition(
            presentation: CGFloat(oldValue / newValue) * currentPresentation,
            animatesToIdentity: true
        )
    }
}
