import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders an adaptive icon the way a launcher shows it, from the rasters an
/// APK carries: the background layer (a color or a raster) under the
/// foreground raster, both stretched over the 108 dp layer canvas, then
/// cropped to the 72 dp viewport at its centre (the outer 18 dp on each side
/// is reserved for launcher effects and never shown). The output is an
/// unmasked square PNG: the caller clips it to its own launcher shape, as
/// the Apps list's rounded tile does. Vector layers cannot be drawn here, so
/// the caller passes `.none` for a background it could not rasterize.
enum AdaptiveIconRenderer {
    enum Background: Equatable {
        /// `0xAARRGGBB`.
        case color(UInt32)
        case raster(Data)
        case none
    }

    /// The share of the layer canvas a launcher shows: 72 dp of 108 dp.
    static let viewportFraction: CGFloat = 72.0 / 108.0

    /// The composited icon, or nil when the foreground does not decode (a
    /// background raster that does not decode is left out).
    static func render(foreground: Data, background: Background) -> Data? {
        guard let foregroundImage = decode(foreground) else { return nil }
        // Layers are square; a non-square raster is stretched onto the
        // square canvas exactly as the launcher draws it into its bounds.
        let layerSide = CGFloat(max(foregroundImage.width, foregroundImage.height))
        let side = max(1, Int((layerSide * viewportFraction).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: side,
                  height: side,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return nil
        }
        context.interpolationQuality = .high

        // The layer canvas, centred on the viewport and overflowing it on
        // every side by the reserved margin.
        let inset = (CGFloat(side) - layerSide) / 2
        let layerRect = CGRect(x: inset, y: inset, width: layerSide, height: layerSide)

        switch background {
        case .color(let argb):
            context.setFillColor(CGColor(
                srgbRed: CGFloat((argb >> 16) & 0xFF) / 255,
                green: CGFloat((argb >> 8) & 0xFF) / 255,
                blue: CGFloat(argb & 0xFF) / 255,
                alpha: CGFloat((argb >> 24) & 0xFF) / 255
            ))
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        case .raster(let data):
            if let image = decode(data) {
                context.draw(image, in: layerRect)
            }
        case .none:
            break
        }
        context.draw(foregroundImage, in: layerRect)

        guard let icon = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, icon, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
