import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Failures the annotation renderer can report.
public enum AnnotationRenderError: Error, Equatable, CustomStringConvertible {
    case imageDecodeFailed
    case contextCreationFailed
    case encodingFailed

    public var description: String {
        switch self {
        case .imageDecodeFailed:
            return "The screenshot could not be decoded as an image."
        case .contextCreationFailed:
            return "The annotation canvas could not be created."
        case .encodingFailed:
            return "The annotated image could not be encoded as PNG."
        }
    }
}

/// Composites annotations onto a screenshot in image-pixel space.
///
/// The base image's decoded pixel size defines the output size; `scale` is the
/// number of image pixels per editor point, so an annotation point `(x, y)`
/// lands on pixel `(x * scale, y * scale)`. Annotation coordinates use the
/// editor's convention: origin top-left, y down. Annotations are composited in
/// array order, so a `.blur` redacts everything drawn before it. With no
/// annotations the base data is returned unchanged (after validating that it
/// decodes); `scale` must be positive.
public enum AnnotationRenderer {
    /// The opaque fill a `.blur` redaction paints over its rect (the editor's
    /// preview must draw the same). It is deliberately independent of the
    /// covered pixels: a mosaic of block means — even one mean — survives the
    /// lossless PNG exactly, and pixelated text in a known font at a known
    /// size (Roboto on a phone screenshot) can be recovered from it.
    public static let redactionColor = RGBA(red: 0, green: 0, blue: 0)

    /// ``render(base:annotations:scale:)`` on a background task: decoding a
    /// full-resolution screenshot, compositing and PNG-encoding it must not
    /// stall a `@MainActor` caller (the editor's Apply).
    public static func renderInBackground(
        base: Data,
        annotations: [Annotation],
        scale: CGFloat
    ) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try render(base: base, annotations: annotations, scale: scale)
        }.value
    }

    public static func render(base: Data, annotations: [Annotation], scale: CGFloat) throws -> Data {
        guard let source = CGImageSourceCreateWithData(base as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AnnotationRenderError.imageDecodeFailed
        }
        guard !annotations.isEmpty else { return base }
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw AnnotationRenderError.contextCreationFailed
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

        // Flip into editor space: origin top-left, y down, one unit per point.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)

        for annotation in annotations {
            switch annotation {
            case .arrow(let from, let to, let color, let width):
                drawArrow(in: context, from: from, to: to, color: color, width: width)
            case .rectangle(let rect, let color, let width, let filled):
                drawRectangle(in: context, rect: rect, color: color, width: width, filled: filled)
            case .blur(let rect):
                redact(in: context, rect: rect, scale: scale)
            case .text(let string, let at, let color, let size):
                drawText(in: context, string: string, at: at, color: color, size: size)
            }
        }

        guard let annotated = context.makeImage() else {
            throw AnnotationRenderError.contextCreationFailed
        }
        return try pngData(from: annotated)
    }

    private static func drawArrow(
        in context: CGContext,
        from: CGPoint,
        to: CGPoint,
        color: RGBA,
        width: CGFloat
    ) {
        let headLength = max(width * 3, 8)
        let spread = CGFloat.pi / 7

        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        context.move(to: from)
        context.addLine(to: to)
        context.strokePath()

        let angle = atan2(to.y - from.y, to.x - from.x)
        for side in [angle + .pi - spread, angle + .pi + spread] {
            context.move(to: to)
            context.addLine(
                to: CGPoint(
                    x: to.x + cos(side) * headLength,
                    y: to.y + sin(side) * headLength
                )
            )
        }
        context.strokePath()
        context.restoreGState()
    }

    private static func drawRectangle(
        in context: CGContext,
        rect: CGRect,
        color: RGBA,
        width: CGFloat,
        filled: Bool
    ) {
        context.saveGState()
        if filled {
            context.setFillColor(color.cgColor)
            context.fill(rect)
        } else {
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width)
            context.stroke(rect)
        }
        context.restoreGState()
    }

    /// Paints ``redactionColor`` over every pixel the rect touches (rounded
    /// outward, so no partially covered edge pixel keeps its content). The
    /// fill is written straight into the bitmap, without antialiasing, so
    /// nothing of the covered content can blend into the output.
    private static func redact(in context: CGContext, rect: CGRect, scale: CGFloat) {
        let pixelRect = CGRect(
            x: rect.minX * scale,
            y: rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
        guard let data = context.data else { return }
        let bytesPerRow = context.bytesPerRow
        let buffer = data.bindMemory(
            to: UInt8.self,
            capacity: bytesPerRow * context.height
        )

        let minX = max(0, min(context.width, Int(pixelRect.minX.rounded(.down))))
        let minY = max(0, min(context.height, Int(pixelRect.minY.rounded(.down))))
        let maxX = max(0, min(context.width, Int(pixelRect.maxX.rounded(.up))))
        let maxY = max(0, min(context.height, Int(pixelRect.maxY.rounded(.up))))
        guard minX < maxX, minY < maxY else { return }

        // The context is premultiplied RGBA (`premultipliedLast`); bitmap
        // row 0 is the image's top row, the editor's y = 0.
        let color = redactionColor
        let alpha = UInt8((color.alpha * 255).rounded())
        let pixel: [UInt8] = [
            UInt8((color.red * color.alpha * 255).rounded()),
            UInt8((color.green * color.alpha * 255).rounded()),
            UInt8((color.blue * color.alpha * 255).rounded()),
            alpha,
        ]
        for y in minY..<maxY {
            let row = buffer + y * bytesPerRow
            for x in minX..<maxX {
                let offset = x * 4
                row[offset] = pixel[0]
                row[offset + 1] = pixel[1]
                row[offset + 2] = pixel[2]
                row[offset + 3] = pixel[3]
            }
        }
    }

    /// Draws one line of text with its top-left corner at `at`. CoreText works
    /// in a y-up space, so the glyphs get a local flip inside the renderer's
    /// y-down editor space.
    private static func drawText(
        in context: CGContext,
        string: String,
        at: CGPoint,
        color: RGBA,
        size: CGFloat
    ) {
        guard let font = CTFontCreateUIFontForLanguage(.system, size, nil) else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: string, attributes: attributes)
        )
        var ascent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, nil, nil)

        context.saveGState()
        context.translateBy(x: at.x, y: at.y + ascent)
        context.scaleBy(x: 1, y: -1)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func pngData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw AnnotationRenderError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AnnotationRenderError.encodingFailed
        }
        return data as Data
    }
}
