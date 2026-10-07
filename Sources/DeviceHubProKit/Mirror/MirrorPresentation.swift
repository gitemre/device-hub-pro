import CoreGraphics
import Foundation

/// Fits the device frame into the available drawable area, preserving the device
/// aspect ratio (no stretching) and never upscaling beyond native size. The
/// result is recomputed on every call, so resizing panels or the window scales
/// the mirror smoothly and responsively.
public struct MirrorPresentation: Sendable {
    public struct Viewport: Sendable, Equatable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// Fraction of the drawable area the frame may occupy (a small margin looks
    /// better for the unframed screen; 1.0 makes the frame fill its slot exactly).
    public let margin: Double

    /// Whether the frame may be scaled up past its native pixel size. Off for
    /// the flat full-window mirror (a small stream would turn blurry), but on
    /// for the thin-bezel view: there the SwiftUI frame is already sized to the
    /// wanted on-screen size, so the texture has to fill its drawable exactly
    /// instead of sitting at 1:1 in the middle of it with black around.
    public let allowsUpscaling: Bool

    public init(margin: Double = 0.96, allowsUpscaling: Bool = false) {
        self.margin = margin
        self.allowsUpscaling = allowsUpscaling
    }

    /// The centered viewport (in drawable pixels) for the given frame size.
    public func viewport(
        frameWidth: Int,
        frameHeight: Int,
        drawableWidth: Double,
        drawableHeight: Double
    ) -> Viewport? {
        guard frameWidth > 0, frameHeight > 0, drawableWidth > 1, drawableHeight > 1 else {
            return nil
        }

        let cap = allowsUpscaling ? Double.greatestFiniteMagnitude : 1.0
        let scale = min(
            drawableWidth * margin / Double(frameWidth),
            drawableHeight * margin / Double(frameHeight),
            cap
        )
        let width = Double(frameWidth) * scale
        let height = Double(frameHeight) * scale

        return Viewport(
            x: (drawableWidth - width) / 2.0,
            y: (drawableHeight - height) / 2.0,
            width: width,
            height: height
        )
    }
}
