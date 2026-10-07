import CoreGraphics

/// The radius a framed device's screen is clipped to, in the skin's layout
/// units, and where it came from.
public struct ScreenCorner: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        /// A round display (Wear): the inscribed circle.
        case roundDisplay
        /// The device's own `RoundedCorners` (`dumpsys display`).
        case device
        /// The skin layout's `corner_radius`.
        case declared
        /// The skin artwork's transparent opening, as measured.
        case opening
        /// Nothing to go on: square corners.
        case none
    }

    public var radius: CGFloat
    public var source: Source
    /// The source's radius was wider than the artwork's opening and was
    /// lowered to it.
    public var isCappedAtOpening: Bool

    public init(radius: CGFloat, source: Source, isCappedAtOpening: Bool = false) {
        self.radius = radius
        self.source = source
        self.isCappedAtOpening = isCappedAtOpening
    }
}

/// Decides the screen corner of a framed device: the live stage's video
/// clip, the static heroes and the framed screenshots all ask this one
/// function, so a device's corner does not change shape between them.
///
/// The rule: the device's own corner radius,
/// capped at the artwork's transparent opening; without device data the
/// skin's declared `corner_radius`, capped the same way; without that the
/// opening itself. Real numbers, in layout units (1 = one artwork pixel):
///
/// | Skin | Device | Declared | Opening | Clip |
/// |---|---|---|---|---|
/// | `pixel_10_pro` | not captured | 99 | ≈180 | 99, declared |
/// | `pixel_9_pro_fold` inner (`default`) | 85 | none | ≈120 | 85, device |
/// | `pixel_9_pro_fold` cover (`closed`) | 115 | 75 | ≈147 | 115, device |
/// | `pixel_tablet` | not captured | none | ≈30 | 30, opening |
///
/// Why the device's radius: it is the corner the device rounds its own
/// screen to — the shade clock stays whole inside it on both fold screens
/// (checked on real stream frames), where a clip at the artwork's opening
/// cut the Pixel 10 Pro's first digit (P2-FRAME) — and it is the only value
/// every device has: 16 installed skin variants with a transparent opening
/// declare none (the fold's inner screen and `pixel_tablet` among them),
/// and the one the fold cover declares (75) is further from its artwork
/// than the device's 115.
///
/// Why the cap: the video is drawn above the artwork, so a radius wider
/// than the opening would leave a ring between the video and the frame. At
/// or under the opening the video covers the whole opening and the frame's
/// black band narrows at the corner by (opening − clip)(1 − 1/√2): 10 px at
/// the fold inner's 85, 24 px at the Pixel 10 Pro's 99.
///
/// Legacy skins (no transparent opening) paint the screen corners with
/// their foreground mask, so they keep the declared radius (0 when none)
/// unless the device reports one; the mask still draws over the video.
public enum ScreenCornerPolicy {
    /// - Parameters:
    ///   - shape: the display the device reports for the screen shown — the
    ///     one matching the streamed frame (`DisplayShape.matching(frame:in:)`)
    ///     or, before a read, a stored one; nil without device data.
    ///   - displaySize: the skin display's size in layout units. The device's
    ///     resolution can differ from it; its radius is scaled to it
    ///     (`DisplayShape.scale(toFit:)`).
    ///   - declaredRadius: the layout's `corner_radius`, layout units.
    ///   - openingRadius: the artwork's measured opening radius, layout units
    ///     (`SkinRenderTraits.openingCornerRadius`).
    ///   - hasTransparentOpening: the artwork paints the screen transparently
    ///     (modern skins); only then does the opening cap anything.
    ///   - isRoundDisplay: a round (Wear) display, clipped to its inscribed
    ///     circle whatever else is known.
    public static func corner(
        device shape: DisplayShape?,
        displaySize: CGSize,
        declaredRadius: CGFloat?,
        openingRadius: CGFloat?,
        hasTransparentOpening: Bool,
        isRoundDisplay: Bool = false
    ) -> ScreenCorner {
        corner(
            deviceRadius: deviceRadius(of: shape, displaySize: displaySize),
            displaySize: displaySize,
            declaredRadius: declaredRadius,
            openingRadius: openingRadius,
            hasTransparentOpening: hasTransparentOpening,
            isRoundDisplay: isRoundDisplay
        )
    }

    /// `corner(device:…)` with the device's radius already in layout units
    /// (`deviceRadius(of:displaySize:)`), for callers that key a cache on it.
    public static func corner(
        deviceRadius: CGFloat?,
        displaySize: CGSize,
        declaredRadius: CGFloat?,
        openingRadius: CGFloat?,
        hasTransparentOpening: Bool,
        isRoundDisplay: Bool = false
    ) -> ScreenCorner {
        // A rounded rect cannot take a radius past half its short side
        // (CoreGraphics traps on one), and a wider one is the same shape.
        let halfShort = max(min(displaySize.width, displaySize.height), 0) / 2
        if isRoundDisplay {
            return ScreenCorner(radius: halfShort, source: .roundDisplay)
        }
        let cap = hasTransparentOpening ? positive(openingRadius) : nil

        func capped(_ radius: CGFloat, _ source: ScreenCorner.Source) -> ScreenCorner {
            let limit = min(cap ?? .greatestFiniteMagnitude, halfShort)
            return ScreenCorner(
                radius: min(radius, limit),
                source: source,
                isCappedAtOpening: cap.map { radius > $0 } ?? false
            )
        }

        if let device = positive(deviceRadius) {
            return capped(device, .device)
        }
        if let declared = positive(declaredRadius) {
            return capped(declared, .declared)
        }
        if let cap {
            return ScreenCorner(radius: min(cap, halfShort), source: .opening)
        }
        return ScreenCorner(radius: 0, source: .none)
    }

    /// The device's clip radius (`DisplayShape.maxCornerRadius`) in the
    /// skin display's layout units; nil without a shape or when it reports
    /// no rounded corners (before API 31).
    public static func deviceRadius(of shape: DisplayShape?, displaySize: CGSize) -> CGFloat? {
        guard let shape, shape.maxCornerRadius > 0 else { return nil }
        return positive(shape.clipCornerRadius(scaledTo: displaySize))
    }

    private static func positive(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}
