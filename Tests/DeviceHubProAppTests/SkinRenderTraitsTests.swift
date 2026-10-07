import XCTest
import AppKit
import DeviceHubProKit
@testable import DeviceHubProApp

/// Guards `SkinRenderTraits` against the real SDK skins when they are
/// installed; skipped on machines without the SDK.
@MainActor
final class SkinRenderTraitsTests: XCTestCase {
    private func skin(named name: String) throws -> SkinCatalogEntry {
        guard let skins = SkinLocator.skinsDirectory() else {
            throw XCTSkip("no Android SDK skins directory")
        }
        let catalog = SkinResolver.catalog(skinsDirectory: skins)
        return try XCTUnwrap(catalog.first(where: { $0.name == name }), "missing skin \(name)")
    }

    private func traits(for entry: SkinCatalogEntry) throws -> (SkinRenderTraits, SkinDisplay) {
        let variant = try XCTUnwrap(entry.preferredVariant)
        let display = try XCTUnwrap(variant.layout?.preferred)
        let artwork = SkinThumbnail.loadImage(named: display.backgroundImage, in: variant.directory)
        let mask = SkinThumbnail.loadImage(named: display.maskImage, in: variant.directory)
        let traits = SkinRenderTraits.measure(artwork: artwork, mask: mask, display: display)
        return (traits, display)
    }

    /// pixel_10_pro's artwork paints the screen transparently; its opening is
    /// wider than the declared physical corner (99 layout units), which is why
    /// the compositors clip at the physical corner and fill the ring.
    func testPixel10ProTraits() throws {
        let (traits, display) = try traits(for: skin(named: "pixel_10_pro"))
        XCTAssertTrue(traits.hasTransparentOpening)
        XCTAssertFalse(traits.isCircularDisplay)
        let opening = try XCTUnwrap(traits.openingCornerRadius)
        XCTAssertGreaterThan(opening, 150)
        XCTAssertLessThan(opening, 210)
        let physical = try XCTUnwrap(display.cornerRadius)
        XCTAssertGreaterThan(opening, physical)
        let bezel = try XCTUnwrap(traits.bezelColor)
        XCTAssertLessThan(try XCTUnwrap(brightness(of: bezel)), 0.15, "dark bezel")
    }

    /// The regression this guards: a hard-coded black ring would be visibly
    /// wrong on the tablet's light bezel (#E5E5E5 measured).
    func testPixelTabletBezelColorIsLight() throws {
        let (traits, _) = try traits(for: skin(named: "pixel_tablet"))
        XCTAssertTrue(traits.hasTransparentOpening)
        XCTAssertNotNil(traits.openingCornerRadius)
        let bezel = try XCTUnwrap(traits.bezelColor)
        XCTAssertGreaterThan(try XCTUnwrap(brightness(of: bezel)), 0.7, "light bezel")
    }

    /// The backing under the live video is the glass right at the opening's
    /// straight edges, dark on the phones and light on the tablet's bezel:
    /// (0, 0, 0) on the Pixel 10 Pro, (3, 3, 3) on the fold cover and
    /// (230, 230, 230) on the tablet, measured.
    func testGlassColorIsTheArtworksColorAtTheOpeningsEdge() throws {
        let pixel10Pro = try XCTUnwrap(skin(named: "pixel_10_pro").preferredVariant)
        let foldCover = try XCTUnwrap(skin(named: "pixel_9_pro_fold").variants.first(where: { $0.id == "closed" }))
        let tablet = try XCTUnwrap(skin(named: "pixel_tablet").preferredVariant)
        XCTAssertLessThan(try glassLuminance(of: pixel10Pro), 0.15, "pixel_10_pro")
        XCTAssertLessThanOrEqual(try glassLuminance(of: foldCover), 0.15, "pixel_9_pro_fold/closed")
        XCTAssertGreaterThan(try glassLuminance(of: tablet), 0.7, "pixel_tablet")
    }

    private func glassLuminance(of variant: SkinVariant) throws -> CGFloat {
        let display = try XCTUnwrap(variant.layout?.preferred)
        let traits = SkinRenderTraits.measure(
            artwork: SkinThumbnail.loadImage(named: display.backgroundImage, in: variant.directory),
            mask: SkinThumbnail.loadImage(named: display.maskImage, in: variant.directory),
            display: display
        )
        return try luminance(of: XCTUnwrap(traits.glassColor))
    }

    /// The frame with its side buttons cleared (`LiveButtonArt.background`,
    /// drawn while a button is out of its place) has the artwork's own
    /// screen traits, on every installed skin variant whose buttons the
    /// stage splits: the buttons lie past the body's right edge, away from
    /// the opening, the ring and the straight edges the traits are measured
    /// at, so a stage that measured the split frame would lay out the same.
    func testTheFrameWithoutItsButtonsHasTheArtworksTraits() throws {
        guard let skins = SkinLocator.skinsDirectory() else {
            throw XCTSkip("no Android SDK skins directory")
        }
        var checked: [String] = []
        for entry in SkinResolver.catalog(skinsDirectory: skins) {
            for variant in entry.variants {
                guard let display = variant.layout?.preferred,
                      let file = display.backgroundImage,
                      let art = LiveButtonArt.make(artworkURL: variant.directory.appendingPathComponent(file))
                else {
                    continue
                }
                let name = "\(entry.name)/\(variant.id)"
                let artwork = try XCTUnwrap(SkinThumbnail.loadImage(named: file, in: variant.directory), name)
                let mask = SkinThumbnail.loadImage(named: display.maskImage, in: variant.directory)
                let original = SkinRenderTraits.measure(artwork: artwork, mask: mask, display: display)
                let split = SkinRenderTraits.measure(artwork: art.background, mask: mask, display: display)
                XCTAssertEqual(split.isCircularDisplay, original.isCircularDisplay, name)
                XCTAssertEqual(split.hasTransparentOpening, original.hasTransparentOpening, name)
                XCTAssertEqual(split.openingCornerRadius, original.openingCornerRadius, name)
                XCTAssertEqual(components(split.bezelColor), components(original.bezelColor), name)
                XCTAssertEqual(components(split.glassColor), components(original.glassColor), name)
                checked.append(name)
            }
        }
        // Every Pixel phone skin and both screens of most folds
        // (`SkinButtonsTests`' snapshot lists 36).
        XCTAssertGreaterThanOrEqual(checked.count, 30, "\(checked)")
    }

    private func components(_ color: NSColor?) -> [CGFloat]? {
        guard let color = color?.usingColorSpace(.sRGB) else { return nil }
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
    }

    func testWearMaskIsCircular() throws {
        let (traits, _) = try traits(for: skin(named: "wearos_xl_round"))
        XCTAssertTrue(traits.isCircularDisplay)
    }

    // MARK: - Round displays

    private static let roundWearSkins: Set<String> = [
        "wearos_large_round",
        "wearos_small_round",
        "wearos_xl_round",
    ]

    func testRoundWearSkinsAreCircular() throws {
        for name in Self.roundWearSkins.sorted() {
            let (traits, _) = try traits(for: skin(named: name))
            XCTAssertTrue(traits.isCircularDisplay, name)
        }
    }

    /// The regression this guards: `pixel_9`'s full-size mask (the live
    /// stage's input; an opaque line runs round its edge) passed the old
    /// 8×8-average check, and the live Pixel 9 screen was clipped to a pill.
    ///
    /// `wearos_square` and `wearos_rect` ship no mask, so they only check
    /// that a maskless skin is not round; the square negatives the geometric
    /// check has to reject are in the synthetic-mask tests below.
    func testSquareWearAndPhoneSkinsAreNotCircular() throws {
        for name in ["wearos_square", "wearos_rect", "pixel_9"] {
            let (traits, _) = try traits(for: skin(named: name))
            XCTAssertFalse(traits.isCircularDisplay, name)
        }
        let variant = try XCTUnwrap(skin(named: "pixel_9").preferredVariant)
        let display = try XCTUnwrap(variant.layout?.preferred)
        let mask = try XCTUnwrap(SkinThumbnail.loadImage(named: display.maskImage, in: variant.directory))
        XCTAssertEqual(mask.artworkPixelSize, CGSize(width: 1080, height: 2424))
        XCTAssertFalse(SkinRenderTraits.isCircularDisplay(mask: mask))
    }

    /// The top 1080×1080 of `pixel_9`'s mask: square, so it passes the
    /// aspect gate that stops every whole phone mask, and it holds the edge
    /// line and both top corners that fooled the old check. The diagonal
    /// tests have to reject it on their own.
    func testASquareWindowOfThePixel9MaskIsNotCircular() throws {
        let variant = try XCTUnwrap(skin(named: "pixel_9").preferredVariant)
        let display = try XCTUnwrap(variant.layout?.preferred)
        let mask = try XCTUnwrap(SkinThumbnail.loadImage(named: display.maskImage, in: variant.directory))
        var rect = CGRect(origin: .zero, size: mask.size)
        let full = try XCTUnwrap(mask.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let window = try XCTUnwrap(full.cropping(to: CGRect(x: 0, y: 0, width: 1080, height: 1080)))
        XCTAssertFalse(SkinRenderTraits.isCircularDisplay(mask: NSImage(cgImage: window, size: .zero)))
    }

    /// Every branch of the geometric check, on square masks: no installed
    /// skin ships a square mask that is not round (the square Wear skins
    /// have none, and every phone, tablet and TV mask fails the aspect gate),
    /// so without these the diagonal tests only ever ran on masks that pass.
    /// The shapes are geometry inputs, not device output; each is drawn at a
    /// live size and at the gallery's decode size.
    func testSquareMasksAreRoundOnlyWhenTheInscribedCircleIsTheDisplay() throws {
        let cases: [(String, Bool, (CGContext, CGFloat) -> Void)] = [
            // Accepted: the round Wear masks' two shapes.
            ("opaque outside the inscribed circle", true, { context, side in
                Self.fillOutside(context, side: side, CGPath(ellipseIn: Self.inset(side, 0), transform: nil))
            }),
            ("a ring just outside the inscribed circle", true, { context, side in
                // `wearos_xl_round`: opaque at 0.52–0.55 of the side, clear
                // inside and at the corners.
                let ring = CGMutablePath()
                ring.addEllipse(in: Self.inset(side, 0.5 - 0.55))
                ring.addEllipse(in: Self.inset(side, 0.5 - 0.51))
                context.addPath(ring)
                context.fillPath(using: .evenOdd)
            }),
            // Rejected by the opaque band past the circle.
            ("a phone-style edge line with filled corners", false, { context, side in
                // `pixel_9`'s shape: an opaque line round the edge, and the
                // corners outside a 0.1-side screen radius.
                let line = side / 80
                let screen = Self.inset(side, line / side)
                Self.fillOutside(context, side: side, CGPath(
                    roundedRect: screen,
                    cornerWidth: side * 0.1,
                    cornerHeight: side * 0.1,
                    transform: nil
                ))
            }),
            ("a rounded square, corner radius half the half side", false, { context, side in
                Self.fillOutside(context, side: side, Self.roundedSquare(side, radius: 0.5 * side / 2))
            }),
            ("a rounded square, corner radius 0.65 of the half side", false, { context, side in
                Self.fillOutside(context, side: side, Self.roundedSquare(side, radius: 0.65 * side / 2))
            }),
            ("inverted: opaque over the display", false, { context, side in
                context.addPath(CGPath(ellipseIn: Self.inset(side, 0), transform: nil))
                context.fillPath()
            }),
            // Rejected by the clear run from the centre.
            ("a circle inset from the edge", false, { context, side in
                // Clipping at the inscribed circle would show the bezel.
                Self.fillOutside(context, side: side, CGPath(ellipseIn: Self.inset(side, 0.1), transform: nil))
            }),
        ]
        for side in [400, 120] {
            for (name, expected, draw) in cases {
                let mask = try Self.syntheticMask(side: side, draw)
                XCTAssertEqual(SkinRenderTraits.isCircularDisplay(mask: mask), expected, "\(name) at \(side) px")
            }
        }
    }

    /// A clear `side`-pixel square mask with `draw` filling its opaque parts.
    private static func syntheticMask(side: Int, _ draw: (CGContext, CGFloat) -> Void) throws -> NSImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        draw(context, CGFloat(side))
        return NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: .zero)
    }

    /// The square inset by `fraction` of its side on every edge.
    private static func inset(_ side: CGFloat, _ fraction: CGFloat) -> CGRect {
        CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: side * fraction, dy: side * fraction)
    }

    private static func roundedSquare(_ side: CGFloat, radius: CGFloat) -> CGPath {
        CGPath(roundedRect: inset(side, 0), cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// Fills the whole square except `display`.
    private static func fillOutside(_ context: CGContext, side: CGFloat, _ display: CGPath) {
        context.addRect(inset(side, 0))
        context.addPath(display)
        context.fillPath(using: .evenOdd)
    }

    /// Every installed variant and orientation that has a mask, at full size
    /// (the live stage) and decoded small (the gallery): exactly the round
    /// Wear skins are circular. The other masks are phones, tablets and TVs,
    /// which the aspect gate rejects before any diagonal is read.
    func testOnlyTheRoundWearSkinsAreCircular() throws {
        guard let skins = SkinLocator.skinsDirectory() else {
            throw XCTSkip("no Android SDK skins directory")
        }
        let catalog = SkinResolver.catalog(skinsDirectory: skins)
        var circular: Set<String> = []
        var masks = 0
        for entry in catalog {
            let expected = Self.roundWearSkins.contains(entry.name)
            for variant in entry.variants {
                let displays = [variant.layout?.portrait, variant.layout?.landscape].compactMap { $0 }
                for display in displays {
                    guard let name = display.maskImage,
                          let full = SkinThumbnail.loadImage(named: name, in: variant.directory)
                    else {
                        continue
                    }
                    masks += 1
                    let label = "\(entry.name)/\(variant.id)/\(display.orientation.rawValue)"
                    let isCircular = SkinRenderTraits.isCircularDisplay(mask: full)
                    XCTAssertEqual(isCircular, expected, label)
                    if isCircular { circular.insert(entry.name) }
                    let small = try XCTUnwrap(
                        SkinThumbnail.decode(named: name, in: variant.directory, maxPixelSize: 120),
                        label
                    )
                    XCTAssertEqual(
                        SkinRenderTraits.isCircularDisplay(mask: NSImage(cgImage: small, size: .zero)),
                        expected,
                        "\(label) at 120 px"
                    )
                }
            }
        }
        XCTAssertGreaterThan(masks, 0)
        XCTAssertEqual(circular, Self.roundWearSkins.intersection(catalog.map(\.name)))
    }

    // MARK: - Artwork placement

    /// `pixel_10_pro_fold/closed` ships a 1236x2495 frame for a 1236x2554
    /// layout. Stretched to the layout, the frame's transparent opening
    /// ended ~56 layout units below the display rect, and the preview showed
    /// the canvas through the strip under the screen; drawn at its natural
    /// size, the bezel follows the screen at once.
    func testFoldCoverPreviewKeepsTheBezelUnderTheScreen() throws {
        let fold = try skin(named: "pixel_10_pro_fold")
        let closed = try XCTUnwrap(fold.variants.first(where: { $0.id == "closed" }))
        let display = try XCTUnwrap(closed.layout?.preferred)
        XCTAssertEqual(
            SkinThumbnail.pixelSize(named: try XCTUnwrap(display.backgroundImage), in: closed.directory),
            CGSize(width: 1236, height: 2495)
        )
        // Half a point per layout unit at 2x: one preview pixel per unit.
        let preview = try XCTUnwrap(SkinThumbnail.render(
            variant: closed,
            height: display.layoutSize.height / 2,
            scale: 2
        ))
        let pixels = try Self.alphaChannel(of: preview)
        XCTAssertEqual(pixels.width, 1236)
        XCTAssertEqual(pixels.height, 2554)
        let screenBottom = Int(display.screenRect.maxY)
        for fraction in [0.3, 0.7] {
            let x = Int(display.screenRect.minX + display.screenRect.width * fraction)
            XCTAssertEqual(pixels.alpha(x, screenBottom - 3), 255, "screen at x=\(x)")
            for y in screenBottom + 2..<screenBottom + 58 {
                XCTAssertEqual(pixels.alpha(x, y), 255, "see-through bezel at (\(x), \(y))")
            }
            // Past the artwork's own bottom edge the layout box is empty.
            XCTAssertEqual(pixels.alpha(x, 2540), 0, "below the artwork at x=\(x)")
        }
    }

    /// The traits measure the frame where it is drawn, at its natural size.
    /// `pixel_10_pro_fold/closed`'s opening radius reads 129.3 layout units
    /// there; measured on the frame stretched to its 1236x2554 layout, it
    /// read 132.2 and the sample row sat 1.5 px off. The live stage's cache
    /// measures the full image; a smaller decode passes the file's natural
    /// size and reads the same opening, including at 0.9 of the artwork,
    /// where a decode taken for full size would be placed one pixel per unit
    /// (91 instead of 129).
    func testFoldCoverOpeningIsMeasuredAtTheArtworksNaturalSize() throws {
        let fold = try skin(named: "pixel_10_pro_fold")
        let closed = try XCTUnwrap(fold.variants.first(where: { $0.id == "closed" }))
        let display = try XCTUnwrap(closed.layout?.preferred)
        let name = try XCTUnwrap(display.backgroundImage)
        let natural = try XCTUnwrap(SkinThumbnail.pixelSize(named: name, in: closed.directory))

        let full = try XCTUnwrap(SkinThumbnail.loadImage(named: name, in: closed.directory))
        let measured = try XCTUnwrap(
            SkinRenderTraits.measure(artwork: full, mask: nil, display: display).openingCornerRadius
        )
        XCTAssertEqual(measured, 129.3, accuracy: 1)

        let live = SkinThumbnailCache().traits(for: closed, display: display)
        XCTAssertEqual(try XCTUnwrap(live.openingCornerRadius), measured, accuracy: 0.01)

        for maxPixelSize: CGFloat in [2250, 1250] {
            let decoded = try XCTUnwrap(
                SkinThumbnail.decode(named: name, in: closed.directory, maxPixelSize: maxPixelSize)
            )
            let traits = SkinRenderTraits.measure(
                artwork: NSImage(cgImage: decoded, size: .zero),
                mask: nil,
                display: display,
                artworkPixelSize: natural
            )
            XCTAssertEqual(
                try XCTUnwrap(traits.openingCornerRadius, "decoded at \(maxPixelSize) px"),
                measured,
                accuracy: 1.5,
                "decoded at \(maxPixelSize) px"
            )
        }
    }

    /// A PNG's resolution metadata can make an NSImage's point size half its
    /// pixels; the artwork is placed by its pixels.
    func testArtworkPixelSizeIgnoresTheImagesPointSize() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 200,
            pixelsHigh: 400,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        rep.size = NSSize(width: 100, height: 200)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        XCTAssertEqual(image.size, CGSize(width: 100, height: 200))
        XCTAssertEqual(image.artworkPixelSize, CGSize(width: 200, height: 400))
    }

    private struct AlphaChannel {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        /// Alpha at a pixel, row 0 at the top.
        func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[y * width + x] }
    }

    private static func alphaChannel(of image: CGImage) throws -> AlphaChannel {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(drawn)
        return AlphaChannel(width: image.width, height: image.height, bytes: bytes)
    }

    private func brightness(of color: NSColor) throws -> CGFloat? {
        try XCTUnwrap(color.usingColorSpace(.sRGB)).brightnessComponent
    }

    /// Rec. 709 luma of the sRGB-encoded components, 0...1.
    private func luminance(of color: NSColor) throws -> CGFloat {
        let srgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
        return 0.2126 * srgb.redComponent + 0.7152 * srgb.greenComponent + 0.0722 * srgb.blueComponent
    }

    // MARK: - Pixel formats (MR-10)

    /// The same artwork measures the same in every pixel layout ImageIO can
    /// hand back. The old reader assumed alpha at byte 0 for
    /// premultipliedFirst (it is byte 3 in little-endian BGRA) and read single
    /// bytes of 16-bit channels, so those decodes found no opening radius or
    /// a garbage one; it also kept a pointer into a copied CFData that was
    /// released when its initializer returned.
    func testTraitsAreTheSameForEveryPixelLayout() throws {
        let display = SkinDisplay(
            displaySize: CGSize(width: 160, height: 360),
            origin: CGPoint(x: 20, y: 20),
            layoutSize: CGSize(width: 200, height: 400),
            backgroundImage: "bg.png",
            maskImage: nil,
            orientation: .portrait
        )
        let layouts: [(String, ArtworkLayout)] = [
            ("RGBA8 big-endian", .rgba8),
            ("BGRA8 little-endian", .bgra8Little),
            ("RGBA16", .rgba16),
        ]
        for (name, layout) in layouts {
            let artwork = try Self.syntheticArtwork(layout: layout)
            let traits = SkinRenderTraits.measure(artwork: artwork, mask: nil, display: display)

            XCTAssertTrue(traits.hasTransparentOpening, name)
            let radius = try XCTUnwrap(traits.openingCornerRadius, name)
            XCTAssertEqual(radius, 40, accuracy: 3, name)
            let bezel = try XCTUnwrap(traits.bezelColor?.usingColorSpace(.sRGB), name)
            XCTAssertEqual(bezel.redComponent * 255, 40, accuracy: 3, name)
            XCTAssertEqual(bezel.greenComponent * 255, 90, accuracy: 3, name)
            XCTAssertEqual(bezel.blueComponent * 255, 160, accuracy: 3, name)
            let glass = try XCTUnwrap(traits.glassColor?.usingColorSpace(.sRGB), name)
            XCTAssertEqual(glass.redComponent * 255, 40, accuracy: 3, name)
            XCTAssertEqual(glass.greenComponent * 255, 90, accuracy: 3, name)
            XCTAssertEqual(glass.blueComponent * 255, 160, accuracy: 3, name)
        }
    }

    /// The glass is the artwork's color right at the opening's straight
    /// edges, not the average of the band around the corners: on a frame
    /// whose 2-unit dark ring lines the opening inside a lighter bezel
    /// (generated input, not device output), the glass reads the ring, full
    /// size and decoded at half size, while the corner rays, which start 2
    /// units out, read the bezel beyond it. The real skins differ the same
    /// way where the glass darkens toward the opening: the fold cover's
    /// glass is (3, 3, 3), its corner average (15, 15, 15).
    func testGlassColorReadsTheRingAtTheOpeningNotTheBezelBeyondIt() throws {
        let display = SkinDisplay(
            displaySize: CGSize(width: 160, height: 360),
            origin: CGPoint(x: 20, y: 20),
            layoutSize: CGSize(width: 200, height: 400),
            backgroundImage: "bg.png",
            maskImage: nil,
            orientation: .portrait
        )
        for scale: CGFloat in [1, 0.5] {
            let artwork = try Self.syntheticArtwork(layout: .rgba8, scale: scale, ring: (
                width: 2,
                color: CGColor(srgbRed: 10 / 255, green: 12 / 255, blue: 14 / 255, alpha: 1)
            ))
            let traits = SkinRenderTraits.measure(
                artwork: artwork,
                mask: nil,
                display: display,
                artworkPixelSize: CGSize(width: 200, height: 400)
            )
            let glass = try XCTUnwrap(traits.glassColor?.usingColorSpace(.sRGB), "at \(scale)")
            XCTAssertEqual(glass.redComponent * 255, 10, accuracy: 3, "at \(scale)")
            XCTAssertEqual(glass.greenComponent * 255, 12, accuracy: 3, "at \(scale)")
            XCTAssertEqual(glass.blueComponent * 255, 14, accuracy: 3, "at \(scale)")
            let bezel = try XCTUnwrap(traits.bezelColor, "at \(scale)")
            XCTAssertGreaterThan(try luminance(of: bezel), try luminance(of: glass) + 0.1, "at \(scale)")
        }
    }

    /// A half-size decode (the gallery measures downsampled artwork) reports
    /// the radius in layout units, like the full-size artwork.
    func testADownsampledArtworkReportsTheRadiusInLayoutUnits() throws {
        let display = SkinDisplay(
            displaySize: CGSize(width: 160, height: 360),
            origin: CGPoint(x: 20, y: 20),
            layoutSize: CGSize(width: 200, height: 400),
            backgroundImage: "bg.png",
            maskImage: nil,
            orientation: .portrait
        )
        let artwork = try Self.syntheticArtwork(layout: .rgba8, scale: 0.5)
        let traits = SkinRenderTraits.measure(artwork: artwork, mask: nil, display: display)
        XCTAssertEqual(try XCTUnwrap(traits.openingCornerRadius), 40, accuracy: 4)
    }

    enum ArtworkLayout {
        case rgba8
        case bgra8Little
        case rgba16
    }

    /// A 200×400 (layout units) phone frame: an opaque bezel colored
    /// (40, 90, 160) with a transparent display opening at (20, 20, 160×360)
    /// whose corners have a 40-unit radius.
    static func syntheticArtwork(
        layout: ArtworkLayout,
        scale: CGFloat = 1,
        ring: (width: CGFloat, color: CGColor)? = nil
    ) throws -> NSImage {
        let width = Int(200 * scale)
        let height = Int(400 * scale)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let bitsPerComponent: Int
        let bitmapInfo: UInt32
        switch layout {
        case .rgba8:
            bitsPerComponent = 8
            bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        case .bgra8Little:
            bitsPerComponent = 8
            bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        case .rgba16:
            bitsPerComponent = 16
            bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        }
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: bitmapInfo
        ))
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(srgbRed: 40 / 255, green: 90 / 255, blue: 160 / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 400))
        if let ring {
            // Concentric with the opening, `ring.width` units wide.
            context.setFillColor(ring.color)
            context.addPath(CGPath(
                roundedRect: CGRect(x: 20, y: 20, width: 160, height: 360)
                    .insetBy(dx: -ring.width, dy: -ring.width),
                cornerWidth: 40 + ring.width,
                cornerHeight: 40 + ring.width,
                transform: nil
            ))
            context.fillPath()
        }
        context.setBlendMode(.clear)
        context.addPath(CGPath(
            roundedRect: CGRect(x: 20, y: 20, width: 160, height: 360),
            cornerWidth: 40,
            cornerHeight: 40,
            transform: nil
        ))
        context.fillPath()
        let image = try XCTUnwrap(context.makeImage())
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }

    // MARK: - Round watches on the live stage

    /// The live stage draws the artwork the previews do: a round watch's opaque
    /// #202020 tile is cleared outside the ring's circle (`SkinThumbnail.roundClipped`),
    /// so the corners are see-through and the centre keeps the artwork.
    func testStageClipsTheRoundWearTilesToTheirRing() throws {
        for name in Self.roundWearSkins.sorted() {
            let entry = try skin(named: name)
            let variant = try XCTUnwrap(entry.preferredVariant)
            let display = try XCTUnwrap(variant.layout?.preferred)
            let raw = try XCTUnwrap(SkinThumbnail.loadImage(named: display.backgroundImage, in: variant.directory))
            let (traits, _) = try traits(for: entry)
            XCTAssertTrue(traits.isCircularDisplay, name)
            // `wearos_xl_round` ships transparent corners: no clip needed.
            guard let clipped = SkinThumbnail.roundClipped(raw) else {
                XCTAssertEqual(name, "wearos_xl_round", "\(name) kept its opaque corners")
                continue
            }
            XCTAssertEqual(clipped.artworkPixelSize, raw.artworkPixelSize, name)
            XCTAssertEqual(clipped.size, raw.size, name)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(clipped.tiffRepresentation)))
            let rawBitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(raw.tiffRepresentation)))
            let w = bitmap.pixelsWide, h = bitmap.pixelsHigh
            for (x, y) in [(1, 1), (w - 2, 1), (1, h - 2), (w - 2, h - 2)] {
                XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent, 0, accuracy: 0.01, "\(name) corner \(x),\(y)")
            }
            XCTAssertEqual(rawBitmap.colorAt(x: 1, y: 1)?.alphaComponent ?? 0, 1, accuracy: 0.01, "\(name) raw corner is opaque")
            let mid = try XCTUnwrap(bitmap.colorAt(x: w / 2, y: h / 2))
            let rawMid = try XCTUnwrap(rawBitmap.colorAt(x: w / 2, y: h / 2))
            XCTAssertEqual(mid.alphaComponent, rawMid.alphaComponent, accuracy: 0.02, name)
        }
    }

    func testStageLeavesOtherArtworkAsItIs() throws {
        let entry = try skin(named: "pixel_9")
        let variant = try XCTUnwrap(entry.preferredVariant)
        let display = try XCTUnwrap(variant.layout?.preferred)
        let raw = try XCTUnwrap(SkinThumbnail.loadImage(named: display.backgroundImage, in: variant.directory))
        let (traits, _) = try traits(for: entry)
        XCTAssertFalse(traits.isCircularDisplay)
        XCTAssertTrue(SkinThumbnailCache.shared.stageBackground(raw, traits: traits, variant: variant, display: display) === raw)
    }
}
