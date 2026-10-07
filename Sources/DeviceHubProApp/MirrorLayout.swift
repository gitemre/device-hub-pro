import CoreGraphics
import DeviceHubProKit

/// Where one streamed frame lands in a mirror view. The renderer draws with
/// it and input is mapped back through the very layout of the last draw, so
/// a click always resolves against the pixels the user is looking at.
///
/// The fit is computed in view points: `allowsUpscaling == false` caps the
/// image at one frame pixel per point (Device Hub's "Physical Size"), on
/// every backing scale. The drawable viewport is that rect in drawable
/// pixels (origin top-left, Metal's viewport space).
struct MirrorLayout: Equatable {
    /// The streamed (posed) frame size.
    let posedWidth: Int
    let posedHeight: Int
    /// The quarter turn the renderer samples the posed frame with (0 when
    /// it shows the buffer as streamed).
    let rotation: Int
    /// The view the image was fitted into, in points.
    let viewSize: CGSize
    /// The drawable behind that view, in pixels.
    let drawableSize: CGSize
    /// The image rect in view points, origin top-left.
    let imageRect: CGRect

    init?(
        posedWidth: Int,
        posedHeight: Int,
        rotation: Int,
        margin: Double,
        allowsUpscaling: Bool,
        viewSize: CGSize,
        drawableSize: CGSize
    ) {
        let rotation = TextureRotation.normalized(rotation)
        let upright = TextureRotation.uprightSize(
            posedWidth: posedWidth,
            posedHeight: posedHeight,
            rotation: rotation
        )
        guard drawableSize.width > 0, drawableSize.height > 0,
              let fit = MirrorPresentation(margin: margin, allowsUpscaling: allowsUpscaling)
                  .viewport(
                      frameWidth: upright.width,
                      frameHeight: upright.height,
                      drawableWidth: Double(viewSize.width),
                      drawableHeight: Double(viewSize.height)
                  )
        else {
            return nil
        }
        self.posedWidth = posedWidth
        self.posedHeight = posedHeight
        self.rotation = rotation
        self.viewSize = viewSize
        self.drawableSize = drawableSize
        self.imageRect = CGRect(x: fit.x, y: fit.y, width: fit.width, height: fit.height)
    }

    /// The frame's upright size (what the view shows).
    var uprightSize: (width: Int, height: Int) {
        TextureRotation.uprightSize(posedWidth: posedWidth, posedHeight: posedHeight, rotation: rotation)
    }

    /// The image rect in drawable pixels: what the renderer hands to
    /// `MTLRenderCommandEncoder.setViewport`.
    var drawableViewport: MirrorPresentation.Viewport {
        let scaleX = drawableSize.width / viewSize.width
        let scaleY = drawableSize.height / viewSize.height
        return MirrorPresentation.Viewport(
            x: imageRect.minX * scaleX,
            y: imageRect.minY * scaleY,
            width: imageRect.width * scaleX,
            height: imageRect.height * scaleY
        )
    }

    /// View points per frame pixel (the fit is uniform).
    var pointsPerFramePixel: CGFloat {
        imageRect.width / CGFloat(max(uprightSize.width, 1))
    }

    /// Maps a point in view coordinates to posed frame coordinates, or nil
    /// outside the image. `isFlipped` is the view's own flag (AppKit views
    /// measure y from the bottom unless flipped).
    func framePoint(atViewPoint point: CGPoint, isFlipped: Bool) -> (x: Int32, y: Int32)? {
        guard imageRect.width > 0, imageRect.height > 0 else { return nil }
        let fromTop = isFlipped ? point.y : viewSize.height - point.y
        let normalizedX = (point.x - imageRect.minX) / imageRect.width
        let normalizedY = (fromTop - imageRect.minY) / imageRect.height
        guard (0...1).contains(normalizedX), (0...1).contains(normalizedY) else {
            return nil
        }
        let upright = uprightSize
        let posed = TextureRotation.posedPoint(
            x: min(Int(normalizedX * CGFloat(upright.width)), upright.width - 1),
            y: min(Int(normalizedY * CGFloat(upright.height)), upright.height - 1),
            posedWidth: posedWidth,
            posedHeight: posedHeight,
            rotation: rotation
        )
        return (Int32(posed.x), Int32(posed.y))
    }
}
