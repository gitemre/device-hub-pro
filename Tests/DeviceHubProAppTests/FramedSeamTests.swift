import XCTest
import SwiftUI
import DeviceHubProKit
@testable import DeviceHubProApp

/// The seam between a modern skin's frame artwork and the backing that fills
/// its transparent opening, rendered with the real SDK skins when they are
/// installed (skipped on machines without the SDK).
///
/// The artwork's opening ends in a hard alpha step on the display rect
/// (`pixel_9_pro_fold/closed/back.webp`: x 93/94 and y 69/70). With the
/// backing drawn above the artwork, at the display rect, both anti-aliased
/// edges shared the one pixel the step falls in at a fractional scale, and
/// each let the other's uncovered share through (c(1 − c) of the stage for
/// a pixel the artwork covers c; its minifying filter spreads the edge
/// further): a light line along the opening's straight edges on a light
/// stage. Scanned here in that order, the brightest seam pixel read 93 of
/// 255 levels on the fold cover, 74 on the inner screen and 30 on the
/// Pixel 10 Pro (origins 0 and 0.5 pt; 32, 15 and 1 at 0.25 and 0.75),
/// against the glass's own 32, 15 and 2 with the backing under the artwork.
@MainActor
final class FramedSeamTests: XCTestCase {
    /// The fold cover's scale on the main stage: 0.624 backing pixels per
    /// layout unit at 2x.
    private static let pointsPerUnit: CGFloat = 0.312
    private static let pixelScale: CGFloat = 2
    /// Luminance, in 8-bit sRGB levels, no seam pixel may exceed. The
    /// artwork's glass along these edges is 0–32 and the backing is dark.
    private static let limit = 40.0

    func testFoldCoverOpeningShowsNoSeam() throws {
        try assertNoSeam(skin: "pixel_9_pro_fold", variant: "closed")
    }

    func testFoldInnerOpeningShowsNoSeam() throws {
        try assertNoSeam(skin: "pixel_9_pro_fold", variant: "default")
    }

    func testPixel10ProOpeningShowsNoSeam() throws {
        try assertNoSeam(skin: "pixel_10_pro", variant: nil)
    }

    /// Renders the body layers over opaque white with the composition's
    /// origin at a quarter-point grid (so the opening's edges fall at
    /// several fractions of a pixel), then scans the pixels around the
    /// opening's straight left and top edges over the middle 60% of each.
    private func assertNoSeam(
        skin name: String,
        variant id: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let entry = try skin(named: name)
        let variant = try XCTUnwrap(
            id.map { id in entry.variants.first(where: { $0.id == id }) } ?? entry.preferredVariant,
            "missing variant \(id ?? "preferred") of \(name)"
        )
        let display = try XCTUnwrap(variant.layout?.preferred)
        let cache = SkinThumbnailCache()
        let background = try XCTUnwrap(cache.artwork(for: variant, display: display).background)
        let traits = cache.traits(for: variant, display: display)
        XCTAssertTrue(traits.hasTransparentOpening, "\(name) is a modern skin", file: file, line: line)
        let hero = SkinHeroLayout.native(display: display, scale: Self.pointsPerUnit)
        let corner = cache.screenCorner(for: variant, display: display, device: nil)
        let layers = FramedBodyLayers(
            background: background,
            display: display,
            hero: hero,
            traits: traits,
            videoRadius: corner.radius * hero.scale
        )

        for origin: CGFloat in [0, 0.25, 0.5, 0.75] {
            let context = "\(name)/\(variant.id) at origin \(origin) pt"
            let pixels = try render(layers, frame: hero.frame.size, origin: origin)
            let screen = hero.screen.offsetBy(dx: origin, dy: origin)
            // The pixel an edge falls in, and one each side of it: the
            // artwork's filtered edge can spread over two.
            let left = Int((screen.minX * Self.pixelScale).rounded(.down))
            let top = Int((screen.minY * Self.pixelScale).rounded(.down))
            let rows = Int(((screen.minY + screen.height * 0.2) * Self.pixelScale).rounded(.up))
                ..< Int(((screen.minY + screen.height * 0.8) * Self.pixelScale).rounded(.down))
            let columns = Int(((screen.minX + screen.width * 0.2) * Self.pixelScale).rounded(.up))
                ..< Int(((screen.minX + screen.width * 0.8) * Self.pixelScale).rounded(.down))

            var brightest = (luminance: 0.0, x: 0, y: 0)
            for y in rows {
                for x in left - 1...left + 1 {
                    let value = pixels.luminance(x, y)
                    if value > brightest.luminance { brightest = (value, x, y) }
                }
            }
            for x in columns {
                for y in top - 1...top + 1 {
                    let value = pixels.luminance(x, y)
                    if value > brightest.luminance { brightest = (value, x, y) }
                }
            }
            XCTAssertLessThanOrEqual(
                brightest.luminance,
                Self.limit,
                "\(context): the stage shows through at pixel (\(brightest.x), \(brightest.y))",
                file: file,
                line: line
            )
        }
    }

    /// `layers` framed and clipped to the layout box as the stage does, at
    /// `origin` points from the top-left of an opaque white canvas with a
    /// margin past the box, which is checked to be white so a render that
    /// drew everything dark cannot pass.
    private func render(_ layers: FramedBodyLayers, frame: CGSize, origin: CGFloat) throws -> Pixels {
        let content = ZStack(alignment: .topLeading) {
            Color.white
            layers
                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                .clipped()
                .padding(.leading, origin)
                .padding(.top, origin)
        }
        .frame(width: (frame.width + 2).rounded(.up), height: (frame.height + 2).rounded(.up), alignment: .topLeading)
        let renderer = ImageRenderer(content: content)
        renderer.scale = Self.pixelScale
        let pixels = try Pixels(image: XCTUnwrap(renderer.cgImage, "rendered"))
        XCTAssertEqual(pixels.luminance(pixels.width - 1, pixels.height - 1), 255, accuracy: 0.5, "the white canvas")
        return pixels
    }

    private func skin(named name: String) throws -> SkinCatalogEntry {
        guard let skins = SkinLocator.skinsDirectory() else {
            throw XCTSkip("no Android SDK skins directory")
        }
        let catalog = SkinResolver.catalog(skinsDirectory: skins)
        return try XCTUnwrap(catalog.first(where: { $0.name == name }), "missing skin \(name)")
    }

    /// A rendered image redrawn as 8-bit sRGB RGBA; opaque, so the bytes
    /// are the straight color.
    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init(image: CGImage) throws {
            let width = image.width
            let height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(
                    data: raw.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                ) else {
                    return false
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            XCTAssertTrue(drawn)
            self.width = width
            self.height = height
            self.bytes = bytes
        }

        /// Rec. 709 luma of the sRGB-encoded levels, row 0 at the top.
        func luminance(_ x: Int, _ y: Int) -> Double {
            let offset = (y * width + x) * 4
            return 0.2126 * Double(bytes[offset])
                + 0.7152 * Double(bytes[offset + 1])
                + 0.0722 * Double(bytes[offset + 2])
        }
    }
}
