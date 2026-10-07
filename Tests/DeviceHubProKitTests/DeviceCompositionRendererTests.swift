import CoreGraphics
import XCTest
@testable import DeviceHubProKit

/// `DeviceCompositionRenderer` drawing the vector body the fold's real
/// `dumpsys display` capture plans for its inner screen (2076x2152, radius
/// 85, the punch hole centred at (1987.5, 80); `ChromeGeometryTests` has
/// the numbers: bezel 66.024, outer radius 151.024, bands 2.549 / 2.549 /
/// 10.180 px, glass from 15.278 px in). The screen content is generated
/// input, not device output: solid fills drawn by the test.
final class DeviceCompositionRendererTests: XCTestCase {
    private static let green = Pixel(red: 0, green: 200, blue: 0, alpha: 255)

    private func innerPlan() throws -> DeviceComposition {
        let shapes = DisplayShape.parse(dumpsysDisplay: try AdbCoreFixtureTests.text("shell-dumpsys-display.txt"))
        return DeviceCompositionPlanner.vector(
            screen: CGSize(width: 2076, height: 2152),
            displays: shapes,
            fallbackDensityDpi: nil,
            quarterTurns: 0
        )
    }

    private func render(_ plan: DeviceComposition, pixelsPerUnit: CGFloat) throws -> PixelImage {
        let image = try XCTUnwrap(DeviceCompositionRenderer.render(plan, pixelsPerUnit: pixelsPerUnit) { context, rect in
            context.setFillColor(CGColor(srgbRed: 0, green: 200.0 / 255, blue: 0, alpha: 1))
            context.fill(rect)
        })
        return try PixelImage(image)
    }

    /// The canvas is ceil(layout × ppu): 2208.047 x 2284.047 at 1 px per
    /// unit is 2209 x 2285, and 1104.02 x 1142.02 at 0.5 is 1105 x 1143.
    func testTheCanvasIsTheLayoutRoundedUp() throws {
        let plan = try innerPlan()
        let full = try XCTUnwrap(DeviceCompositionRenderer.render(plan, pixelsPerUnit: 1) { _, _ in })
        XCTAssertEqual(full.width, 2209)
        XCTAssertEqual(full.height, 2285)
        XCTAssertEqual(full.colorSpace?.name, CGColorSpace.sRGB)
        let half = try XCTUnwrap(DeviceCompositionRenderer.render(plan, pixelsPerUnit: 0.5) { _, _ in })
        XCTAssertEqual(half.width, 1105)
        XCTAssertEqual(half.height, 1143)
    }

    /// Along the left edge at mid-height each band shows its own colour at
    /// its midpoint (±2 levels): the rim (1.27 px in) black at 0.148
    /// (premultiplied, alpha 38), the highlight (3.8) #7E7E7E, the frame
    /// (10.2) #2C2C2C, the glass (40) #010101; the screen is the drawn
    /// green.
    func testEachBandShowsItsColourAtItsMidpoint() throws {
        let image = try render(try innerPlan(), pixelsPerUnit: 1)
        let row = 1142
        assertPixel(image.pixel(1, row), Pixel(red: 0, green: 0, blue: 0, alpha: 38), "rim")
        assertPixel(image.pixel(3, row), Pixel(red: 126, green: 126, blue: 126, alpha: 255), "highlight")
        assertPixel(image.pixel(10, row), Pixel(red: 44, green: 44, blue: 44, alpha: 255), "frame")
        assertPixel(image.pixel(40, row), Pixel(red: 1, green: 1, blue: 1, alpha: 255), "glass")
        assertPixel(image.pixel(1104, row), Self.green, "screen")
    }

    /// Outside the outer arc (radius 151.024 about (151.024, 151.024)) the
    /// canvas stays transparent; just inside it the rim begins.
    func testOutsideTheOuterArcIsTransparent() throws {
        let image = try render(try innerPlan(), pixelsPerUnit: 1)
        XCTAssertEqual(image.pixel(0, 0).alpha, 0)
        XCTAssertEqual(image.pixel(2208, 2284).alpha, 0)
        // 3 px outside the arc on the top-left diagonal: 151.024 − 154.024/√2.
        let outside = Int((151.024 - 154.024 / 2.0.squareRoot()).rounded(.down))
        XCTAssertEqual(image.pixel(outside, outside).alpha, 0)
        // 8 px inside it: the highlight or frame, opaque.
        let inside = Int((151.024 - 143.024 / 2.0.squareRoot()).rounded(.down))
        XCTAssertEqual(image.pixel(inside, inside).alpha, 255)
    }

    /// The screen is clipped to the device's corner: the wedge outside the
    /// 85 px arc shows the glass, not the screen.
    func testTheScreenIsClippedToItsCorner() throws {
        let image = try render(try innerPlan(), pixelsPerUnit: 1)
        assertPixel(image.pixel(66 + 5, 66 + 5), Pixel(red: 1, green: 1, blue: 1, alpha: 255), "corner wedge")
        assertPixel(image.pixel(66 + 85, 66 + 5), Self.green, "top edge past the arc")
    }

    /// The cutout is filled black over the screen: its centre is
    /// (66.024 + 1987.5, 66.024 + 80).
    func testTheCutoutCentreIsBlack() throws {
        let image = try render(try innerPlan(), pixelsPerUnit: 1)
        assertPixel(image.pixel(2053, 146), Pixel(red: 0, green: 0, blue: 0, alpha: 255), "cutout", accuracy: 0)
        // 45 px left of the centre (r 39.5): the screen again.
        assertPixel(image.pixel(2053 - 45, 146), Self.green, "beside the cutout")
    }

    /// `drawScreen` gets CoreGraphics' y-up space and the screen rect in it,
    /// so an image drawn into the rect lands upright: a generated image red
    /// on top and blue below shows red at the top of the screen.
    func testTheScreenIsDrawnUpright() throws {
        let plan = try innerPlan()
        var received: CGRect?
        let halves = try twoToneImage()
        let cgImage = try XCTUnwrap(DeviceCompositionRenderer.render(plan, pixelsPerUnit: 1) { context, rect in
            received = rect
            context.draw(halves, in: rect)
        })
        let rect = try XCTUnwrap(received)
        XCTAssertEqual(rect.minX, 66.024, accuracy: 0.01)
        XCTAssertEqual(rect.minY, 2285 - 66.024 - 2152, accuracy: 0.01)
        XCTAssertEqual(rect.size, CGSize(width: 2076, height: 2152))

        let image = try PixelImage(cgImage)
        assertPixel(image.pixel(1104, 400), Pixel(red: 255, green: 0, blue: 0, alpha: 255), "top half")
        assertPixel(image.pixel(1104, 1900), Pixel(red: 0, green: 0, blue: 255, alpha: 255), "bottom half")
    }

    /// Thin bands are held at one pixel: at 0.1 px per unit the 0.25 px rim
    /// still covers the first column at mid-height.
    func testThinBandsStayVisibleAtSmallSizes() throws {
        let image = try render(try innerPlan(), pixelsPerUnit: 0.1)
        XCTAssertEqual(image.width, 221)
        assertPixel(image.pixel(0, image.height / 2), Pixel(red: 0, green: 0, blue: 0, alpha: 38), "rim")
        assertPixel(image.pixel(1, image.height / 2), Pixel(red: 126, green: 126, blue: 126, alpha: 255), "highlight")
    }

    /// Skin plans are drawn from their artwork, not here; nor is anything
    /// drawn at no size.
    func testOnlyVectorPlansAtAPositiveScaleRender() throws {
        let display = try XCTUnwrap(SkinLayout.parseFile(
            at: LogcatSdkApkFixtures.url("skins/pixel_9_pro/layout")
        )?.preferred)
        let skin = DeviceCompositionPlanner.skin(
            display: display,
            artworkPixelSize: display.layoutSize,
            corner: ScreenCorner(radius: 109, source: .declared),
            backing: nil,
            drawsLegacyMask: false,
            hasOverlay: false
        )
        XCTAssertNil(DeviceCompositionRenderer.render(skin, pixelsPerUnit: 1) { _, _ in })
        XCTAssertNil(DeviceCompositionRenderer.render(try innerPlan(), pixelsPerUnit: 0) { _, _ in })
        XCTAssertNil(DeviceCompositionRenderer.render(try innerPlan(), pixelsPerUnit: .infinity) { _, _ in })
        let empty = DeviceCompositionPlanner.vector(screen: .zero, displays: [], fallbackDensityDpi: nil, quarterTurns: nil)
        XCTAssertNil(DeviceCompositionRenderer.render(empty, pixelsPerUnit: 1) { _, _ in })
    }

    /// The chrome's colours are sRGB and are drawn as such: each standard
    /// colour fills a 1x1 sRGB bitmap with its exact 8-bit level (a Generic
    /// RGB fill of the same components lands the highlight at 145, not 126).
    func testChromeColoursFillTheirOwnSRGBLevels() throws {
        let spec = ChromeSpec.standard(.phone)
        let expected: [(RGBA, Pixel)] = [
            (spec.bands[0].color, Pixel(red: 0, green: 0, blue: 0, alpha: 38)),
            (spec.bands[1].color, Pixel(red: 126, green: 126, blue: 126, alpha: 255)),
            (spec.bands[2].color, Pixel(red: 44, green: 44, blue: 44, alpha: 255)),
            (spec.glass, Pixel(red: 1, green: 1, blue: 1, alpha: 255)),
        ]
        for (color, pixel) in expected {
            XCTAssertEqual(color.srgbColor.colorSpace?.name, CGColorSpace.sRGB)
            let context = try XCTUnwrap(CGContext(
                data: nil,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(color.srgbColor)
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            let image = try PixelImage(try XCTUnwrap(context.makeImage()))
            assertPixel(image.pixel(0, 0), pixel, "\(color)", accuracy: 0)
        }
    }

    // MARK: - Helpers

    private struct Pixel: Equatable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8
    }

    /// Premultiplied RGBA bytes, row-major from the top row.
    private struct PixelImage {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init(_ image: CGImage) throws {
            width = image.width
            height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: image.width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            guard drawn else { throw CocoaError(.featureUnsupported) }
            self.bytes = bytes
        }

        func pixel(_ x: Int, _ y: Int) -> Pixel {
            let offset = (y * width + x) * 4
            return Pixel(red: bytes[offset], green: bytes[offset + 1], blue: bytes[offset + 2], alpha: bytes[offset + 3])
        }
    }

    /// 2076x2152, red above the middle, blue below (generated input).
    private func twoToneImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 2076,
            height: 2152,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // y-up: the upper half is y 1076…2152.
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2076, height: 1076))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 1076, width: 2076, height: 1076))
        return try XCTUnwrap(context.makeImage())
    }

    private func assertPixel(
        _ actual: Pixel,
        _ expected: Pixel,
        _ message: String,
        accuracy: Int = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let channels = [
            (actual.red, expected.red), (actual.green, expected.green),
            (actual.blue, expected.blue), (actual.alpha, expected.alpha),
        ]
        for (got, want) in channels where abs(Int(got) - Int(want)) > accuracy {
            XCTFail("\(message): \(actual) is not \(expected) ±\(accuracy)", file: file, line: line)
            return
        }
    }
}
