import CoreGraphics

/// A display's camera cutout placed on the screen as shown: the device's
/// own outline (`DisplayShape.Cutout`, display pixels in the panel's natural
/// orientation), turned by the display's rotation and scaled into the
/// screen's rect.
///
/// The host draws the cutout itself: a framed screenshot carries none, and
/// the live stream only shows one where the guest paints it. An emulator's
/// frame is shown upright (`quarterTurns` 0 on the natural panel); a phone's
/// scrcpy frame arrives already posed, so its outline is turned by the
/// display rotation `dumpsys display` reports.
public struct CutoutPlacement: Sendable, Hashable {
    public var cutout: DisplayShape.Cutout
    /// The panel's natural size in pixels (`DisplayShape.naturalSize`), the
    /// space `cutout`'s outline is in.
    public var naturalSize: CGSize
    /// `Surface.ROTATION_0` … `ROTATION_270` of the screen as shown: 0 to 3,
    /// taken modulo 4.
    public var quarterTurns: Int

    public init(cutout: DisplayShape.Cutout, naturalSize: CGSize, quarterTurns: Int) {
        self.cutout = cutout
        self.naturalSize = naturalSize
        self.quarterTurns = quarterTurns
    }

    /// `shape`'s cutout at `quarterTurns`; nil when the display has none.
    public init?(shape: DisplayShape, quarterTurns: Int) {
        guard let cutout = shape.cutout else { return nil }
        self.init(cutout: cutout, naturalSize: shape.naturalSize, quarterTurns: quarterTurns)
    }

    /// The size the turned panel shows at: `naturalSize`, transposed for an
    /// odd turn.
    public var rotatedSize: CGSize {
        turns % 2 == 1
            ? CGSize(width: naturalSize.height, height: naturalSize.width)
            : naturalSize
    }

    /// The outline mapped into `screen` (points or pixels, top-left based):
    /// turned by `quarterTurns`, then scaled like
    /// `DisplayShape.scale(toFit:)` (the smaller of the short- and long-side
    /// ratios) and moved to `screen`'s origin. Nil when the spec does not
    /// parse or either size is empty.
    ///
    /// SOURCE-DERIVED: the turn maps a point of a natural W×H panel the way
    /// AOSP's `RotationUtils.rotateBounds`
    /// (`frameworks/base/core/java/android/util/RotationUtils.java`) maps a
    /// rect's corners: ROTATION_90 (x, y) → (y, W − x), ROTATION_180
    /// (W − x, H − y), ROTATION_270 (H − y, x).
    public func path(in screen: CGRect) -> CGPath? {
        let width = naturalSize.width
        let height = naturalSize.height
        let short = min(width, height)
        let long = max(width, height)
        guard short > 0, screen.width > 0, screen.height > 0,
              let outline = cutout.path
        else { return nil }

        let rotation: CGAffineTransform
        switch turns {
        case 1: rotation = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        case 2: rotation = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        case 3: rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        default: rotation = .identity
        }
        let scale = min(
            min(screen.width, screen.height) / short,
            max(screen.width, screen.height) / long
        )
        var transform = rotation
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: screen.minX, y: screen.minY))
        return outline.copy(using: &transform)
    }

    private var turns: Int {
        ((quarterTurns % 4) + 4) % 4
    }
}
