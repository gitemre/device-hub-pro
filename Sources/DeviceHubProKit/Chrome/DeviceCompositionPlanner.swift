import CoreGraphics

/// Builds a `DeviceComposition`: around an SDK skin's artwork, or as a
/// vector body sized from what the device reports about its own screen.
public enum DeviceCompositionPlanner {
    /// The skin as the live stage lays it out today: the layout box, the
    /// display rect (`SkinDisplay.screenRect`) and the artwork at its natural
    /// size (`SkinDisplay.artworkRect(pixelSize:)`), so placed at a scale it
    /// equals `SkinHeroLayout.native(display:scale:)`. The corner comes from
    /// `ScreenCornerPolicy`; nothing here decides it. `buttons` are
    /// `SkinButtonScanner`'s, in artwork pixels; the plan holds them in
    /// layout units.
    public static func skin(
        display: SkinDisplay,
        artworkPixelSize: CGSize,
        corner: ScreenCorner,
        backing: DeviceComposition.Backing?,
        drawsLegacyMask: Bool,
        hasOverlay: Bool,
        buttons: [SkinHardwareButton] = [],
        cutout: CutoutPlacement? = nil
    ) -> DeviceComposition {
        DeviceComposition(
            layoutSize: display.layoutSize,
            screenRect: display.screenRect,
            screenCorner: corner,
            cutout: cutout,
            body: .skin(
                artworkRect: display.artworkRect(pixelSize: artworkPixelSize),
                backing: backing,
                drawsLegacyMask: drawsLegacyMask,
                hasOverlay: hasOverlay
            ),
            buttons: buttons.map { button in
                var placed = button
                placed.rect = layoutRect(artworkPixels: button.rect, display: display, artworkPixelSize: artworkPixelSize)
                return placed
            }
        )
    }

    /// A rect of the artwork's own pixels (a side button found in the image)
    /// in layout units: where `SkinDisplay.artworkRect(pixelSize:)` puts
    /// those pixels.
    static func layoutRect(
        artworkPixels rect: CGRect,
        display: SkinDisplay,
        artworkPixelSize: CGSize
    ) -> CGRect {
        let artwork = display.artworkRect(pixelSize: artworkPixelSize)
        let scale = display.artworkScale(pixelSize: artworkPixelSize)
        return CGRect(
            x: artwork.minX + rect.minX / scale,
            y: artwork.minY + rect.minY / scale,
            width: rect.width / scale,
            height: rect.height / scale
        )
    }

    /// A simulator in its Apple chrome (`AppleChromeFrame`), turned
    /// `quarterTurns` counter-clockwise (the device's orientation, 1 for
    /// landscape left). Layout units are the screen's pixels (chrome points
    /// times the display's scale), as a vector body's are, so a screenshot
    /// of the display fills the screen rect one pixel per unit.
    ///
    /// The screen's corner is the display's radius (`ScreenCorner.device`):
    /// what a consumer without the outline clips to; the chrome's own
    /// drawing clips to the device type's framebuffer mask.
    public static func appleChrome(_ frame: AppleChromeFrame, quarterTurns: Int = 0) -> DeviceComposition {
        let body = DeviceComposition.AppleChromeBody(
            art: frame.art,
            layout: frame.layout,
            unitsPerPoint: frame.scale,
            quarterTurns: ((quarterTurns % 4) + 4) % 4,
            cornerRadius: frame.cornerRadius,
            sensorBar: frame.sensorBar,
            hasDynamicIsland: frame.hasDynamicIsland
        )
        let native = CGSize(
            width: frame.layout.canvasSize.width * frame.scale,
            height: frame.layout.canvasSize.height * frame.scale
        )
        let turned = body.quarterTurns % 2 == 1 ? CGSize(width: native.height, height: native.width) : native
        return DeviceComposition(
            layoutSize: turned,
            screenRect: frame.layout.screen.applying(body.pointsToUnits),
            screenCorner: ScreenCorner(radius: frame.cornerRadius * frame.scale, source: .device),
            cutout: nil,
            body: .appleChrome(body)
        )
    }

    /// The density assumed when nothing reports one: a common modern phone's
    /// (`DisplayMetrics.DENSITY_420`).
    public static let defaultDensityDpi: Double = 420

    /// The physical dpi range a panel's `xDpi` is believed in; outside it
    /// (a placeholder value) the logical density stands in.
    static let plausibleDpi: ClosedRange<Double> = 120...800

    /// The bezel's bounds as fractions of the screen's short side, so an
    /// odd density can neither erase the body nor swallow the screen.
    static let bezelFraction: ClosedRange<CGFloat> = 0.025...0.09

    /// A vector body for a screen of `screen` pixels.
    ///
    /// - Parameters:
    ///   - screen: the pixels shown, upright (an emulator's stream in its
    ///     natural orientation) or posed (a phone's scrcpy stream, a
    ///     screenshot); layout units are these pixels.
    ///   - displays: every display the device reported
    ///     (`DisplayShape.parse(dumpsysDisplay:)`, or the stored list); may
    ///     be empty.
    ///   - fallbackDensityDpi: `wm density`, or an AVD's `hw.lcd.density`.
    ///   - hingeCount: the AVD's `hw.sensor.hinge.count`.
    ///   - quarterTurns: the display rotation (`Surface.ROTATION_*`) the
    ///     screen is shown at; nil when not known.
    ///
    /// Rules:
    /// - the panel is `DisplayShape.matching(frame: screen, in: displays)`,
    ///   shown at `k` = its `scale(toFit: screen)` (1 without one);
    /// - the dpi is the panel's `xDpi` when plausible (120…800), else its
    ///   `densityDpi`, else `fallbackDensityDpi`, else 420; pixels per mm are
    ///   dpi / 25.4 × k;
    /// - the family is `.foldableInner` when another built-in panel is
    ///   smaller than this built-in one, or when the AVD has a hinge and the
    ///   screen is nearly square (long / short < 1.4); else `.tablet` from a
    ///   600 dp smallest width, Android's own `sw600dp` line: the panel's
    ///   short side in dp at its logical density (`densityDpi`, else
    ///   `fallbackDensityDpi`, else the dpi above), so the body agrees with
    ///   the UI the device picks even where a phone's measured `xDpi`
    ///   differs; else `.phone`;
    /// - the bezel is `ChromeSpec.standard(family).bezelMM`, held to
    ///   2.5–9% of the screen's short side;
    /// - the screen corner is the device's own radius (`ScreenCorner.device`),
    ///   or square (`.none`) when it reports none;
    /// - the body's corner is the screen's plus the bezel, so the two are
    ///   concentric;
    /// - the cutout is placed at `quarterTurns`, or upright when they are
    ///   unknown and the screen is in the panel's natural orientation; it is
    ///   left out otherwise, and whenever the turn contradicts the screen's
    ///   orientation (a rotation read that lags a turn).
    ///
    /// The inner screen of the API 37 Pixel 9 Pro Fold emulator
    /// (2076×2152, 390 dpi, radius 85) gives a foldableInner body 66.024 px
    /// wide, 2208.047 × 2284.047 overall, outer radius 151.024.
    public static func vector(
        screen: CGSize,
        displays: [DisplayShape],
        fallbackDensityDpi: Double?,
        hingeCount: Int = 0,
        quarterTurns: Int?
    ) -> DeviceComposition {
        let width = max(screen.width, 0)
        let height = max(screen.height, 0)
        let short = min(width, height)
        let long = max(width, height)
        let shape = DisplayShape.matching(frame: screen, in: displays)
        let fit = shape?.scale(toFit: screen) ?? 1
        let k = fit > 0 ? fit : 1

        let dpi = Self.density(of: shape, fallback: fallbackDensityDpi)
        let pixelsPerMM = CGFloat(dpi / 25.4) * k
        let family = Self.family(
            of: shape,
            in: displays,
            screenShort: short,
            screenLong: long,
            k: k,
            logicalDpi: Self.logicalDensity(of: shape, fallback: fallbackDensityDpi, physical: dpi),
            hingeCount: hingeCount
        )
        let spec = ChromeSpec.standard(family)

        let bezel = min(
            max(CGFloat(spec.bezelMM) * pixelsPerMM, bezelFraction.lowerBound * short),
            bezelFraction.upperBound * short
        )
        let halfShort = short / 2
        let corner: ScreenCorner
        if let shape, shape.maxCornerRadius > 0 {
            corner = ScreenCorner(radius: min(shape.clipCornerRadius(scaledTo: screen), halfShort), source: .device)
        } else {
            corner = ScreenCorner(radius: 0, source: .none)
        }
        let layout = CGSize(width: width + 2 * bezel, height: height + 2 * bezel)

        return DeviceComposition(
            layoutSize: layout,
            screenRect: CGRect(x: bezel, y: bezel, width: width, height: height),
            screenCorner: corner,
            cutout: shape.flatMap { Self.cutout(of: $0, screen: screen, quarterTurns: quarterTurns) },
            body: .vector(DeviceComposition.VectorBody(
                family: family,
                bezel: bezel,
                outerRadius: min(corner.radius + bezel, min(layout.width, layout.height) / 2),
                bandWidths: spec.bands.map { CGFloat($0.widthMM) * pixelsPerMM },
                bandColors: spec.bands.map(\.color),
                glass: spec.glass
            ))
        )
    }

    // MARK: - Rules

    static func density(of shape: DisplayShape?, fallback: Double?) -> Double {
        if let xDpi = shape?.xDpi, plausibleDpi.contains(xDpi) {
            return xDpi
        }
        if let logical = shape?.densityDpi, logical > 0 {
            return Double(logical)
        }
        if let fallback, fallback.isFinite, fallback > 0 {
            return fallback
        }
        return defaultDensityDpi
    }

    /// The density Android lays the panel out at, which dp are counted in:
    /// its logical `densityDpi`, else `fallback`, else `physical` (the
    /// `density(of:fallback:)` the body is measured with).
    static func logicalDensity(of shape: DisplayShape?, fallback: Double?, physical: Double) -> Double {
        if let logical = shape?.densityDpi, logical > 0 {
            return Double(logical)
        }
        if let fallback, fallback.isFinite, fallback > 0 {
            return fallback
        }
        return physical
    }

    static func family(
        of shape: DisplayShape?,
        in displays: [DisplayShape],
        screenShort: CGFloat,
        screenLong: CGFloat,
        k: CGFloat,
        logicalDpi: Double,
        hingeCount: Int
    ) -> DeviceFamily {
        if let shape, shape.isBuiltIn {
            let area = shape.width * shape.height
            if displays.contains(where: { $0.isBuiltIn && $0 != shape && $0.width * $0.height < area }) {
                return .foldableInner
            }
        }
        if hingeCount > 0, screenShort > 0, screenLong / screenShort < 1.4 {
            return .foldableInner
        }
        let smallestWidthDp = Double(screenShort / k) / (logicalDpi / 160)
        return smallestWidthDp >= 600 ? .tablet : .phone
    }

    /// `shape`'s cutout on a screen of `screen` pixels, or nil when the turn
    /// is unknown or does not fit the screen's orientation.
    static func cutout(of shape: DisplayShape, screen: CGSize, quarterTurns: Int?) -> CutoutPlacement? {
        let natural = shape.naturalSize
        let turns: Int
        if let quarterTurns {
            turns = quarterTurns
        } else if sameOrientation(screen, natural) {
            turns = 0
        } else {
            return nil
        }
        guard let placement = CutoutPlacement(shape: shape, quarterTurns: turns),
              sameOrientation(screen, placement.rotatedSize)
        else { return nil }
        return placement
    }

    /// Both portrait or both landscape; a square matches either.
    private static func sameOrientation(_ a: CGSize, _ b: CGSize) -> Bool {
        a.width == a.height || b.width == b.height || (a.width > a.height) == (b.width > b.height)
    }
}
