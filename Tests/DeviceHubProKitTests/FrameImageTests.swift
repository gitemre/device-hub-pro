import CoreGraphics
import CoreVideo
import ImageIO
import XCTest
@testable import DeviceHubProKit

/// `FrameImage`: a mirror frame as an sRGB image and PNG, for the
/// simulator's screenshots from its live canvas. The pixels are read back
/// from the encoded PNG, so what the user saves is what is checked.
final class FrameImageTests: XCTestCase {
    /// A 3×2 32BGRA frame (rows padded in its IOSurface-backed buffer)
    /// becomes the same pixels, opaque, tagged sRGB.
    func testAPixelBufferFrameKeepsItsPixelsAndIsTaggedSRGB() throws {
        let bgra: [UInt8] = [
            0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255,
            10, 20, 30, 255, 40, 50, 60, 255, 70, 80, 90, 255,
        ]
        let buffer = try FramePixelBufferTests.makeBGRAPixelBuffer(width: 3, height: 2, bytes: bgra)
        XCTAssertGreaterThan(CVPixelBufferGetBytesPerRow(buffer), 12, "the buffer's rows are padded")
        let frame = Frame(pixelBuffer: buffer, seq: 1) { _ in nil }

        let image = try XCTUnwrap(FrameImage.cgImage(from: frame))
        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)

        let png = try XCTUnwrap(FrameImage.pngData(from: image))
        let decoded = try Self.decode(png)
        XCTAssertEqual(decoded.colorSpace, CGColorSpace.sRGB as String)
        XCTAssertEqual(decoded.rgba, [
            255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255,
            30, 20, 10, 255, 60, 50, 40, 255, 90, 80, 70, 255,
        ])
    }

    /// A byte frame (RGBA8888) is taken as it is.
    func testAByteFrameKeepsItsPixels() throws {
        let rgba: [UInt8] = [1, 2, 3, 255, 4, 5, 6, 255]
        let frame = Frame(data: Data(rgba), width: 2, height: 1, seq: 0)
        let png = try XCTUnwrap(FrameImage.pngData(from: frame))
        XCTAssertEqual(try Self.decode(png).rgba, rgba)
    }

    /// Short bytes, an empty frame or another pixel format give nothing.
    func testUnusableFramesGiveNoImage() throws {
        XCTAssertNil(FrameImage.cgImage(from: Frame(data: Data([1, 2, 3]), width: 1, height: 1, seq: 0)))
        XCTAssertNil(FrameImage.cgImage(from: Frame(data: Data(), width: 0, height: 0, seq: 0)))
        var yuv: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &yuv),
            kCVReturnSuccess
        )
        XCTAssertNil(FrameImage.cgImage(fromBGRA: try XCTUnwrap(yuv)))
    }

    /// The PNG's pixels drawn into straight RGBA in sRGB, and the colour
    /// space ImageIO reports for it.
    static func decode(_ png: Data) throws -> (rgba: [UInt8], colorSpace: String?) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (bytes, image.colorSpace?.name as String?)
    }
}
