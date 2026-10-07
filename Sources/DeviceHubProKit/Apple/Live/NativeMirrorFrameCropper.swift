import CoreImage
import CoreVideo
import Foundation

/// Cuts the screen out of a native mirror frame (the encoder pads the frame) and
/// converts it to an IOSurface-backed BGRA buffer the renderer samples in place.
/// A frame that already is BGRA and already the screen passes through.
final class NativeMirrorFrameCropper: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero

    /// The screen of `frame` inside `rect` (top-left origin, pixels), or nil when
    /// the rect does not fit the frame or no buffer could be made. `stage` is the
    /// stage-to-panel rotation (`FastInputPanelMapping`): the result is the panel
    /// picture turned the other way, so it is upright for that interface
    /// orientation (a 90 degree turn swaps the size).
    func crop(_ frame: CVPixelBuffer, to rect: CGRect, stage: FastInputPanelMapping.Rotation = .identity) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let target = rect.integral.intersection(bounds)
        guard target.width >= 1, target.height >= 1 else { return nil }
        let outputSize = stage == .clockwise90 || stage == .counterClockwise90
            ? CGSize(width: target.height, height: target.width) : target.size
        if stage == .identity, target == bounds, CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA,
           CVPixelBufferGetIOSurface(frame) != nil {
            return frame
        }
        if poolSize != outputSize || pool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: Int(outputSize.width),
                kCVPixelBufferHeightKey: Int(outputSize.height),
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            var made: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &made) == kCVReturnSuccess else { return nil }
            pool = made
            poolSize = outputSize
        }
        guard let pool else { return nil }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else { return nil }
        // Core Image's origin is bottom-left.
        let flipped = CGRect(x: target.minX, y: CGFloat(height) - target.maxY, width: target.width, height: target.height)
        var image = CIImage(cvPixelBuffer: frame).cropped(to: flipped)
            .transformed(by: CGAffineTransform(translationX: -flipped.minX, y: -flipped.minY))
        // Core Image is y-up: a positive angle turns the picture counter-clockwise.
        let w = target.width, h = target.height
        switch stage {
        case .identity: break
        case .clockwise90:  // stage = panel turned counter-clockwise
            image = image.transformed(by: CGAffineTransform(rotationAngle: .pi / 2).concatenating(CGAffineTransform(translationX: h, y: 0)))
        case .counterClockwise90:  // stage = panel turned clockwise
            image = image.transformed(by: CGAffineTransform(rotationAngle: -.pi / 2).concatenating(CGAffineTransform(translationX: 0, y: w)))
        case .turn180:
            image = image.transformed(by: CGAffineTransform(rotationAngle: .pi).concatenating(CGAffineTransform(translationX: w, y: h)))
        }
        context.render(image, to: output)
        return output
    }
}
