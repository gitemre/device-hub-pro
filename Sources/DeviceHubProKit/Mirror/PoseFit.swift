import CoreGraphics
import Foundation

/// Fit math for the rotating device presentation.
///
/// The stage composes the device in its **native** orientation and rotates the
/// whole composition with a wrapper (see `StagePoseAnimator`). This type
/// computes how large the native composition may be at a given pose angle so
/// its rotated bounding box still fits the stage, and how that compares to the
/// fit scale already baked into the layout.
///
/// The layout carries the fit of the pose the device **rests** in, not of
/// its natural pose: the wrapper's scale is then exactly 1 at rest in every
/// pose, so the live video's drawable (sized from the view's own bounds) is
/// shown 1:1. Laid out at the natural pose's fit, a portrait phone at rest in
/// landscape was enlarged by the wrapper, about 1.5x in the default window
/// (and drawn at twice the size it was shown in the compact one).
public enum PoseFit {
    /// The axis-aligned bounding box of `size` rotated by `angle` degrees.
    ///
    /// Exact at quarter turns (the size itself or its transpose), whatever
    /// the turn count: the rest poses must fit exactly as a plain layout of
    /// the posed size would, and `cos(-450°)` is not quite 0.
    public static func rotatedBoundingBox(_ size: CGSize, angle: Double) -> CGSize {
        let quarterTurns = angle / 90
        if quarterTurns.isFinite, quarterTurns == quarterTurns.rounded() {
            return quarterTurns.truncatingRemainder(dividingBy: 2) == 0
                ? size
                : CGSize(width: size.height, height: size.width)
        }
        let radians = angle * .pi / 180
        let cosine = abs(cos(radians))
        let sine = abs(sin(radians))
        return CGSize(
            width: size.width * cosine + size.height * sine,
            height: size.width * sine + size.height * cosine
        )
    }

    /// The fit scale for a composition of `nativeSize` rotated by `angle`
    /// inside `box`, capped at `cap` (artwork is never upscaled) and floored
    /// per axis at `floor` (the thin-bezel view's degenerate-size guard).
    public static func scale(
        angle: Double,
        nativeSize: CGSize,
        box: CGSize,
        cap: CGFloat = 1,
        floor: CGFloat = 0
    ) -> CGFloat {
        let bounds = rotatedBoundingBox(nativeSize, angle: angle)
        guard bounds.width > 0, bounds.height > 0, box.width > 0, box.height > 0 else {
            return cap
        }
        let widthRatio = max(box.width / bounds.width, floor)
        let heightRatio = max(box.height / bounds.height, floor)
        return min(widthRatio, heightRatio, cap)
    }

    /// The wrapper's scale at `angle` for a composition laid out at the fit
    /// of the pose it rests in (`scale(angle: restAngle, …)`): the fit at
    /// `angle` over the fit baked into the layout.
    ///
    /// Exactly 1 at rest (both fits are the same computation). Mid-turn it
    /// is below 1 toward the diagonal, and while a rotation leaves the pose
    /// with the larger fit it starts above 1. The size on screen,
    /// `nativeSize × scale(angle:)`, never depends on the rest pose, so
    /// changing the layout with it at the start of a rotation moves nothing.
    public static func correction(
        angle: Double,
        restAngle: Double,
        nativeSize: CGSize,
        box: CGSize
    ) -> CGFloat {
        let rest = scale(angle: restAngle, nativeSize: nativeSize, box: box)
        guard rest > 0 else { return 1 }
        return scale(angle: angle, nativeSize: nativeSize, box: box) / rest
    }

    /// The offset (points, the same on both axes) that puts a composition
    /// turned by `angle` about the centre of a frame of `size` back on the
    /// pixel grid, for `pixelScale` pixels per point.
    ///
    /// A quarter turn about the centre maps the frame's pixel grid onto the
    /// grid only when width − height is an even number of pixels; otherwise
    /// every turned pixel lands half a pixel off on both axes, and a video
    /// drawn 1:1 at rest would be resampled soft. The offset is that phase,
    /// weighted by |sin(angle)|: the full half pixel at 90° and 270°, 0 at
    /// 0° and 180° (a half turn keeps the grid).
    public static func pixelGridOffset(angle: Double, size: CGSize, pixelScale: CGFloat) -> CGFloat {
        guard pixelScale > 0 else { return 0 }
        let halfDifference = (size.width - size.height) * pixelScale / 2
        let phase = halfDifference - halfDifference.rounded(.down)
        guard phase > 1e-6 else { return 0 }
        let weight = CGFloat(abs(sin(angle * .pi / 180)))
        return -phase * weight / pixelScale
    }
}
