import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A mirror frame as an image: a screenshot taken from the frame the stage
/// shows instead of asking the device for one ("Capture": the
/// simulator's live canvas).
///
/// The image is the frame's pixels as stored: a simulator's frames are
/// published display-oriented with `Frame.rotation` 0, so they are the
/// screen as its interface shows it. It is opaque and tagged sRGB by
/// default: the simulator's screen reports DCI-P3, but `simctl io
/// screenshot` tags its PNGs sRGB over the same bytes, so a frame tagged
/// that way reads like simctl's own capture.
public enum FrameImage {
    /// The colour space the images are tagged with unless told otherwise.
    public static var sRGB: CGColorSpace {
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// The frame as an opaque image in `colorSpace`, its pixels copied (the
    /// frame's buffer may be reused once the call returns). A pixel-buffer
    /// frame must be 32BGRA (the simulator's and scrcpy's frames are); a
    /// byte frame is RGBA8888, `width * 4` per row. Nil for another pixel
    /// format, an empty frame or short bytes.
    public static func cgImage(from frame: Frame, colorSpace: CGColorSpace = sRGB) -> CGImage? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        if let buffer = frame.pixelBuffer {
            return cgImage(fromBGRA: buffer, colorSpace: colorSpace)
        }
        let data = frame.data
        let rowBytes = frame.width * 4
        guard data.count >= rowBytes * frame.height else { return nil }
        return makeImage(
            data: data.prefix(rowBytes * frame.height),
            width: frame.width,
            height: frame.height,
            // R, G, B, then an unused byte.
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            colorSpace: colorSpace
        )
    }

    /// A 32BGRA pixel buffer's pixels as an opaque image, its rows copied
    /// without their padding.
    public static func cgImage(fromBGRA buffer: CVPixelBuffer, colorSpace: CGColorSpace = sRGB) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let sourceRowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let rowBytes = width * 4
        guard width > 0, height > 0, sourceRowBytes >= rowBytes,
              let base = CVPixelBufferGetBaseAddress(buffer)
        else { return nil }
        var data = Data(count: rowBytes * height)
        data.withUnsafeMutableBytes { destination in
            guard let target = destination.baseAddress else { return }
            if sourceRowBytes == rowBytes {
                target.copyMemory(from: base, byteCount: rowBytes * height)
            } else {
                for row in 0..<height {
                    (target + row * rowBytes).copyMemory(from: base + row * sourceRowBytes, byteCount: rowBytes)
                }
            }
        }
        return makeImage(
            data: data,
            width: width,
            height: height,
            // B, G, R, then an unused byte: a little-endian 32-bit xRGB.
            bitmapInfo: CGBitmapInfo(
                rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
            ),
            colorSpace: colorSpace
        )
    }

    /// `image` encoded as PNG, its colour space embedded; nil when ImageIO
    /// cannot encode it.
    public static func pngData(from image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// The frame as PNG bytes (`cgImage(from:)`, then `pngData(from:)`).
    public static func pngData(from frame: Frame, colorSpace: CGColorSpace = sRGB) -> Data? {
        cgImage(from: frame, colorSpace: colorSpace).flatMap(pngData(from:))
    }

    private static func makeImage(
        data: Data,
        width: Int,
        height: Int,
        bitmapInfo: CGBitmapInfo,
        colorSpace: CGColorSpace
    ) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
