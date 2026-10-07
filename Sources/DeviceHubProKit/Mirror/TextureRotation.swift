import CoreGraphics
import Foundation

/// Maps between a streamed frame's posed coordinates and the display's upright
/// (logical) coordinates for a quarter-turn device rotation.
///
/// `TouchMapping` converts a posed point to upright for input; this type is its
/// inverse plus the size helpers the renderer needs to present a posed buffer
/// upright (the rotation animation composes the device natively and uprights
/// the buffer inside it).
public enum TextureRotation {
    /// Normalized quarter turn (0...3).
    public static func normalized(_ rotation: Int) -> Int {
        ((rotation % 4) + 4) % 4
    }

    /// The upright (logical) size of a posed frame: odd quarter turns
    /// transpose width and height.
    public static func uprightSize(
        posedWidth: Int,
        posedHeight: Int,
        rotation: Int
    ) -> (width: Int, height: Int) {
        normalized(rotation) % 2 == 1
            ? (width: posedHeight, height: posedWidth)
            : (width: posedWidth, height: posedHeight)
    }

    /// The size of a posed frame in the display's **natural** orientation,
    /// which is invariant across poses.
    ///
    /// `uprightSize` alone is only invariant for a *consistent* (size,
    /// rotation) pair; a transitional frame (the buffer already flipped while
    /// the rotation metadata still lags, or vice versa) would transpose it for
    /// a frame. Orienting the result to the display's natural pose makes the
    /// video rect stable through a rotation transition, so the composition
    /// never flips mid-animation.
    public static func naturalSize(
        posedWidth: Int,
        posedHeight: Int,
        rotation: Int,
        naturalIsPortrait: Bool
    ) -> (width: Int, height: Int) {
        let upright = uprightSize(
            posedWidth: posedWidth,
            posedHeight: posedHeight,
            rotation: rotation
        )
        let uprightIsPortrait = upright.height >= upright.width
        if uprightIsPortrait == naturalIsPortrait {
            return upright
        }
        return (width: upright.height, height: upright.width)
    }

    /// Converts an upright point into the posed frame's coordinates (the
    /// inverse of `TouchMapping.nativePoint`).
    public static func posedPoint(
        x: Int,
        y: Int,
        posedWidth: Int,
        posedHeight: Int,
        rotation: Int
    ) -> (x: Int, y: Int) {
        switch normalized(rotation) {
        case 1:
            return (x: y, y: posedHeight - 1 - x)
        case 2:
            return (x: posedWidth - 1 - x, y: posedHeight - 1 - y)
        case 3:
            return (x: posedWidth - 1 - y, y: x)
        default:
            return (x: x, y: y)
        }
    }

    /// The UV transform the fragment shader applies to sample a posed texture
    /// for an upright drawable: `(u, v)` in the upright image maps to the
    /// returned texture coordinate.
    public static func posedUV(u: Double, v: Double, rotation: Int) -> (u: Double, v: Double) {
        switch normalized(rotation) {
        case 1:
            return (u: v, v: 1 - u)
        case 2:
            return (u: 1 - u, v: 1 - v)
        case 3:
            return (u: 1 - v, v: u)
        default:
            return (u: u, v: v)
        }
    }
}
