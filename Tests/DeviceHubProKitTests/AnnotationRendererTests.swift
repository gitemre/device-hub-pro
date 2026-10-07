import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import DeviceHubProKit

final class AnnotationRendererTests: XCTestCase {
    // MARK: - Model

    func testRGBAClampsComponents() {
        let color = RGBA(red: 1.5, green: -0.25, blue: 0.5, alpha: 2)

        XCTAssertEqual(color.red, 1)
        XCTAssertEqual(color.green, 0)
        XCTAssertEqual(color.blue, 0.5)
        XCTAssertEqual(color.alpha, 1)
        XCTAssertEqual(
            RGBA(red: 0.1, green: 0.2, blue: 0.3),
            RGBA(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        )
    }

    func testAnnotationsRoundTripThroughCodable() throws {
        let annotations: [Annotation] = [
            .arrow(
                from: CGPoint(x: 1.5, y: 2.5),
                to: CGPoint(x: 30, y: 40),
                color: RGBA(red: 0.9, green: 0.1, blue: 0.2, alpha: 0.8),
                width: 4
            ),
            .rectangle(
                CGRect(x: 3, y: 4, width: 50, height: 60),
                color: RGBA(red: 0, green: 0.5, blue: 1),
                width: 2,
                filled: true
            ),
            .text("hello", at: CGPoint(x: 7, y: 8), color: RGBA(red: 0, green: 0, blue: 0), size: 18),
            .blur(CGRect(x: 10, y: 20, width: 30, height: 40)),
        ]

        let data = try JSONEncoder().encode(annotations)
        let decoded = try JSONDecoder().decode([Annotation].self, from: data)

        XCTAssertEqual(decoded, annotations)
    }

    // MARK: - Renderer

    func testEmptyAnnotationsReturnTheBaseImage() throws {
        let base = try solidPNG(width: 40, height: 30, red: 10, green: 120, blue: 200)

        let output = try AnnotationRenderer.render(base: base, annotations: [], scale: 2)

        XCTAssertEqual(output, base)
        let image = try decode(output)
        XCTAssertEqual(image.width, 40)
        XCTAssertEqual(image.height, 30)
    }

    func testInvalidBaseDataThrows() {
        XCTAssertThrowsError(
            try AnnotationRenderer.render(base: Data("not a PNG".utf8), annotations: [], scale: 1)
        ) { error in
            XCTAssertEqual(error as? AnnotationRenderError, .imageDecodeFailed)
        }
    }

    func testArrowDrawsAlongTheCorridorAtScale() throws {
        let base = try solidPNG(width: 80, height: 80, red: 255, green: 255, blue: 255)
        let black = RGBA(red: 0, green: 0, blue: 0)

        let output = try AnnotationRenderer.render(
            base: base,
            annotations: [
                .arrow(
                    from: CGPoint(x: 10, y: 20),
                    to: CGPoint(x: 30, y: 20),
                    color: black,
                    width: 4
                )
            ],
            scale: 2
        )

        let image = try decode(output)
        XCTAssertEqual(image.width, 80)
        XCTAssertEqual(image.height, 80)
        // Points scale by 2: the shaft runs along pixel row 40 from x=20 to x=60.
        XCTAssertLessThanOrEqual(image.luminance(40, 40), 40)
        XCTAssertLessThanOrEqual(image.luminance(50, 40), 40)
        // The head reaches the tip and widens around it.
        XCTAssertLessThanOrEqual(image.luminance(58, 40), 40)
        // Away from the corridor the base stays white.
        XCTAssertGreaterThanOrEqual(image.luminance(40, 10), 215)
        XCTAssertGreaterThanOrEqual(image.luminance(40, 70), 215)
        XCTAssertGreaterThanOrEqual(image.luminance(75, 75), 215)
    }

    func testRectangleBorderLeavesTheInteriorUntouched() throws {
        let base = try solidPNG(width: 40, height: 40, red: 255, green: 255, blue: 255)
        let black = RGBA(red: 0, green: 0, blue: 0)

        let output = try AnnotationRenderer.render(
            base: base,
            annotations: [
                .rectangle(
                    CGRect(x: 5, y: 5, width: 30, height: 30),
                    color: black,
                    width: 2,
                    filled: false
                )
            ],
            scale: 1
        )

        let image = try decode(output)
        XCTAssertLessThanOrEqual(image.luminance(20, 5), 40)
        XCTAssertLessThanOrEqual(image.luminance(35, 20), 40)
        XCTAssertLessThanOrEqual(image.luminance(5, 20), 40)
        XCTAssertGreaterThanOrEqual(image.luminance(20, 20), 215)
        XCTAssertGreaterThanOrEqual(image.luminance(2, 2), 215)
    }

    func testFilledRectanglePaintsTheInterior() throws {
        let base = try solidPNG(width: 60, height: 60, red: 255, green: 255, blue: 255)
        let black = RGBA(red: 0, green: 0, blue: 0)

        let output = try AnnotationRenderer.render(
            base: base,
            annotations: [
                .rectangle(
                    CGRect(x: 10, y: 10, width: 20, height: 20),
                    color: black,
                    width: 1,
                    filled: true
                )
            ],
            scale: 1
        )

        let image = try decode(output)
        XCTAssertLessThanOrEqual(image.luminance(20, 20), 40)
        XCTAssertGreaterThanOrEqual(image.luminance(9, 9), 215)
        XCTAssertGreaterThanOrEqual(image.luminance(35, 35), 215)
    }

    func testScaleMapsAnnotationPointsToPixels() throws {
        let base = try solidPNG(width: 60, height: 60, red: 255, green: 255, blue: 255)
        let black = RGBA(red: 0, green: 0, blue: 0)

        let output = try AnnotationRenderer.render(
            base: base,
            annotations: [
                .rectangle(
                    CGRect(x: 5, y: 5, width: 10, height: 10),
                    color: black,
                    width: 1,
                    filled: true
                )
            ],
            scale: 3
        )

        let image = try decode(output)
        // (5,5,10,10) points at 3 px/point covers pixels (15,15)-(45,45).
        XCTAssertEqual(image.width, 60)
        XCTAssertEqual(image.height, 60)
        XCTAssertLessThanOrEqual(image.luminance(20, 20), 40)
        XCTAssertLessThanOrEqual(image.luminance(42, 42), 40)
        XCTAssertGreaterThanOrEqual(image.luminance(12, 12), 215)
        XCTAssertGreaterThanOrEqual(image.luminance(48, 48), 215)
    }

    func testRedactionPaintsAnOpaqueFillOverTheRect() throws {
        let base = try checkerboardPNG(width: 48, height: 48, cell: 6)
        let before = try decode(base)
        XCTAssertGreaterThan(before.luminance(3, 3), 200)

        let output = try AnnotationRenderer.render(
            base: base,
            annotations: [.blur(CGRect(x: 0, y: 0, width: 12, height: 12))],
            scale: 1
        )

        let image = try decode(output)
        for y in 0..<12 {
            for x in 0..<12 {
                XCTAssertTrue(
                    image.isRedactionFill(x, y),
                    "pixel (\(x), \(y)) keeps covered content"
                )
            }
        }
        // Outside the rect the checkerboard is untouched.
        XCTAssertGreaterThan(image.luminance(15, 15), 200)
        XCTAssertLessThan(image.luminance(21, 0), 60)
        XCTAssertGreaterThan(image.luminance(12, 0), 200)
        XCTAssertGreaterThan(image.luminance(0, 12), 200)
    }

    /// The old mosaic kept each 12 px block's exact mean in a lossless PNG,
    /// which known-font text recovery reverses. Different content under the
    /// same rect must now produce byte-identical pixels there.
    func testRedactionLeaksNothingAboutTheCoveredContent() throws {
        let rect = CGRect(x: 4, y: 4, width: 30, height: 14)
        let white = try solidPNG(width: 48, height: 24, red: 255, green: 255, blue: 255)
        let text = try makePNG(width: 48, height: 24) { x, y in
            // A glyph-like pattern with a per-column ink density.
            (x * 7 + y * 3) % 11 < x % 5 ? (0, 0, 0, 255) : (255, 255, 255, 255)
        }

        let redactedWhite = try decode(
            AnnotationRenderer.render(base: white, annotations: [.blur(rect)], scale: 1)
        )
        let redactedText = try decode(
            AnnotationRenderer.render(base: text, annotations: [.blur(rect)], scale: 1)
        )

        for y in 4..<18 {
            for x in 4..<34 {
                XCTAssertTrue(
                    redactedWhite.pixel(x, y) == redactedText.pixel(x, y),
                    "pixel (\(x), \(y)) differs with the covered content"
                )
            }
        }
    }

    func testRedactionScalesWithAnnotationPointsAndCoversPartialPixels() throws {
        let base = try checkerboardPNG(width: 96, height: 96, cell: 6)

        let output = try AnnotationRenderer.render(
            base: base,
            annotations: [.blur(CGRect(x: 0.25, y: 0.25, width: 5.5, height: 5.5))],
            scale: 2
        )

        let image = try decode(output)
        // (0.25…5.75) points at 2 px per point touch pixels 0…11 (0.5…11.5).
        XCTAssertTrue(image.isRedactionFill(0, 0))
        XCTAssertTrue(image.isRedactionFill(11, 11))
        XCTAssertTrue(image.isRedactionFill(6, 3))
        XCTAssertGreaterThan(image.luminance(15, 15), 200)
        XCTAssertLessThan(image.luminance(21, 0), 60)
        XCTAssertGreaterThan(image.luminance(12, 12), 200)
    }

    /// The editor's Apply runs the background variant; it must yield the same
    /// image as the synchronous render.
    @MainActor
    func testRenderInBackgroundMatchesTheSynchronousRender() async throws {
        let base = try checkerboardPNG(width: 64, height: 64, cell: 8)
        let annotations: [Annotation] = [
            .blur(CGRect(x: 4, y: 4, width: 20, height: 10)),
            .rectangle(CGRect(x: 30, y: 30, width: 20, height: 20), color: RGBA(red: 1, green: 0, blue: 0), width: 3, filled: false),
        ]

        let background = try await AnnotationRenderer.renderInBackground(base: base, annotations: annotations, scale: 1)
        let synchronous = try AnnotationRenderer.render(base: base, annotations: annotations, scale: 1)

        XCTAssertEqual(try decode(background).bytes, try decode(synchronous).bytes)
    }

    func testTextDrawsInkInTheExpectedArea() throws {
        let base = try solidPNG(width: 80, height: 40, red: 255, green: 255, blue: 255)

        let output = try AnnotationRenderer.render(
            base: base,
            annotations: [
                .text(
                    "H",
                    at: CGPoint(x: 4, y: 4),
                    color: RGBA(red: 0, green: 0, blue: 0),
                    size: 20
                )
            ],
            scale: 1
        )

        let image = try decode(output)
        // The glyph's ink lands below and right of `at`.
        let ink = countDarkPixels(image, columns: 0..<40, rows: 0..<30)
        XCTAssertGreaterThan(ink, 5)
        // Far from the glyph the base stays white.
        let outside = countDarkPixels(image, columns: 40..<80, rows: 0..<40)
        XCTAssertEqual(outside, 0)
        let below = countDarkPixels(image, columns: 0..<80, rows: 32..<40)
        XCTAssertEqual(below, 0)
    }

    // MARK: - Fixtures

    private struct PixelImage {
        let width: Int
        let height: Int
        /// Premultiplied RGBA, row-major from the top row.
        let bytes: [UInt8]

        func pixel(_ x: Int, _ y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
            let offset = (y * width + x) * 4
            return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
        }

        func luminance(_ x: Int, _ y: Int) -> Int {
            let color = pixel(x, y)
            return (Int(color.red) + Int(color.green) + Int(color.blue)) / 3
        }

        /// Whether the pixel is exactly the renderer's opaque redaction fill.
        func isRedactionFill(_ x: Int, _ y: Int) -> Bool {
            let color = pixel(x, y)
            let fill = AnnotationRenderer.redactionColor
            return color.alpha == 255
                && Int(color.red) == Int((fill.red * 255).rounded())
                && Int(color.green) == Int((fill.green * 255).rounded())
                && Int(color.blue) == Int((fill.blue * 255).rounded())
        }
    }

    private enum FixtureError: Error {
        case creationFailed
    }

    private func solidPNG(
        width: Int,
        height: Int,
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        alpha: UInt8 = 255
    ) throws -> Data {
        try makePNG(width: width, height: height) { _, _ in (red, green, blue, alpha) }
    }

    private func checkerboardPNG(width: Int, height: Int, cell: Int) throws -> Data {
        try makePNG(width: width, height: height) { x, y in
            ((x / cell) + (y / cell)) % 2 == 0 ? (255, 255, 255, 255) : (0, 0, 0, 255)
        }
    }

    private func makePNG(
        width: Int,
        height: Int,
        pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)
    ) throws -> Data {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else {
            throw FixtureError.creationFailed
        }

        let buffer = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (red, green, blue, alpha) = pixel(x, y)
                let offset = (y * width + x) * 4
                buffer[offset] = red
                buffer[offset + 1] = green
                buffer[offset + 2] = blue
                buffer[offset + 3] = alpha
            }
        }

        guard let image = context.makeImage() else { throw FixtureError.creationFailed }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            png,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw FixtureError.creationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.creationFailed }
        return png as Data
    }

    private func countDarkPixels(_ image: PixelImage, columns: Range<Int>, rows: Range<Int>) -> Int {
        var count = 0
        for row in rows {
            for column in columns where image.luminance(column, row) < 128 {
                count += 1
            }
        }
        return count
    }

    private func decode(_ data: Data) throws -> PixelImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: image.width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ), let data = context.data else {
            throw FixtureError.creationFailed
        }

        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        )
        let buffer = data.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        return PixelImage(
            width: image.width,
            height: image.height,
            bytes: Array(UnsafeBufferPointer(start: buffer, count: image.width * image.height * 4))
        )
    }
}
