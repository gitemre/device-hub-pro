import AppKit
import XCTest
import DeviceHubProKit
@testable import DeviceHubProApp

/// Gallery previews (MR-11): rendered off the main thread from downsampled
/// artwork, kept within a pixel budget, and misses retried.
@MainActor
final class SkinPreviewCacheTests: XCTestCase {
    func testAPreviewRendersOffTheMainThreadAndIsThenServedFromTheCache() async throws {
        let calls = RenderLog()
        let cache = SkinThumbnailCache(render: { _, height, scale, _ in
            calls.record(onMain: Thread.isMainThread)
            return Self.solidImage(width: Int(height * scale / 2), height: Int(height * scale))
        })
        let variant = Self.variant(named: "a")

        XCTAssertNil(cache.image(for: variant), "a view body must never wait for a decode")
        let maybeRendered = await cache.renderedImage(for: variant)
        let rendered = try XCTUnwrap(maybeRendered)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.onMain, [false], "previews render off the main thread")

        XCTAssertTrue(cache.image(for: variant) === rendered)
        XCTAssertEqual(rendered.size.height, SkinThumbnail.height, accuracy: 0.5)
        XCTAssertEqual(calls.count, 1, "a cached preview is not rendered again")
    }

    func testPreviewsStayWithinTheirPixelBudget() async throws {
        // Each preview is 10×20 px = 800 bytes; room for three.
        let cache = SkinThumbnailCache(costLimit: 2_400, render: { _, _, _, _ in
            Self.solidImage(width: 10, height: 20)
        })
        let variants = (0..<5).map { Self.variant(named: "skin-\($0)") }
        for variant in variants {
            _ = await cache.renderedImage(for: variant, height: 20)
        }

        XCTAssertLessThanOrEqual(cache.previewBytes, 2_400)
        XCTAssertNil(cache.image(for: variants[0], height: 20), "the least recently used preview is dropped")
        XCTAssertNotNil(cache.image(for: variants[4], height: 20))
    }

    func testASkinWithoutArtworkIsTriedAgainLater() async throws {
        let calls = RenderLog()
        let clock = TestClock()
        let artworkInstalled = Flag()
        let cache = SkinThumbnailCache(missRetryInterval: 30, now: { clock.now }, render: { _, _, _, _ in
            calls.record(onMain: false)
            return artworkInstalled.value ? Self.solidImage(width: 4, height: 8) : nil
        })
        let variant = Self.variant(named: "late")

        let missing = await cache.renderedImage(for: variant)
        XCTAssertNil(missing)
        artworkInstalled.value = true
        XCTAssertNil(cache.image(for: variant))
        XCTAssertEqual(calls.count, 1, "a fresh miss is not retried on every view refresh")

        clock.now = clock.now.addingTimeInterval(31)
        let found = await cache.renderedImage(for: variant)
        XCTAssertNotNil(found, "a skin installed later appears without a relaunch")
        XCTAssertEqual(calls.count, 2)
    }

    /// The real renderer, end to end, on a synthetic skin whose artwork is
    /// far larger than the preview: it decodes each layer at the drawn size.
    func testTheRendererDrawsFromArtworkDecodedAtThePreviewSize() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicehubpro-skin-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let artwork = try SkinRenderTraitsTests.syntheticArtwork(layout: .rgba8, scale: 8)
        try Self.writePNG(artwork, to: directory.appendingPathComponent("back.png"))
        let display = SkinDisplay(
            displaySize: CGSize(width: 1280, height: 2880),
            origin: CGPoint(x: 160, y: 160),
            layoutSize: CGSize(width: 1600, height: 3200),
            backgroundImage: "back.png",
            maskImage: nil,
            orientation: .portrait,
            cornerRadius: 200
        )
        let variant = SkinVariant(
            id: "default",
            directory: directory,
            layout: SkinLayoutFile(portrait: display, landscape: nil)
        )

        let decoded = try XCTUnwrap(SkinThumbnail.decode(named: "back.png", in: directory, maxPixelSize: 460))
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 460, "never a full-size decode")

        let preview = try XCTUnwrap(SkinThumbnail.render(variant: variant, height: 230, scale: 2))
        XCTAssertEqual(preview.height, 460)
        XCTAssertEqual(preview.width, 230)
    }

    // MARK: - Vector bodies

    /// The fold's inner screen as a stopped skinless AVD plans it from its
    /// `config.ini` (2076x2152, 390 dpi, one hinge), with or without the
    /// shapes it last reported (the API 37 emulator's real `dumpsys
    /// display`: radius 85, a punch hole at (1987.5, 80)).
    private static func innerPlan(withShapes: Bool) throws -> DeviceComposition {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("DeviceHubProKitTests/Fixtures/api37-emulator/adb-core/shell-dumpsys-display.txt")
        let shapes = withShapes ? DisplayShape.parse(dumpsysDisplay: try String(contentsOf: fixture, encoding: .utf8)) : []
        return DeviceCompositionPlanner.vector(
            screen: CGSize(width: 2076, height: 2152),
            displays: shapes,
            fallbackDensityDpi: 390,
            hingeCount: 1,
            quarterTurns: 0
        )
    }

    /// A vector body renders off the main thread, once per plan and height:
    /// the same plan is served from the cache, another plan (the device's
    /// corner learned) or height renders apart.
    func testAVectorBodyRendersOffTheMainThreadOncePerPlanAndHeight() async throws {
        let calls = RenderLog()
        let cache = SkinThumbnailCache(renderVector: { plan, height, scale in
            calls.record(onMain: Thread.isMainThread)
            let aspect = plan.layoutSize.width / plan.layoutSize.height
            return Self.solidImage(width: Int(height * scale * aspect), height: Int(height * scale))
        })
        let square = try Self.innerPlan(withShapes: false)
        let rounded = try Self.innerPlan(withShapes: true)

        XCTAssertNil(cache.vectorImage(for: square, height: 400), "a view body must never wait for a render")
        let rendered = await cache.renderedVectorImage(for: square, height: 400)
        let first = try XCTUnwrap(rendered)
        XCTAssertEqual(calls.onMain, [false], "vector bodies render off the main thread")
        XCTAssertEqual(first.size.height, 400, accuracy: 0.5)
        XCTAssertEqual(first.size.width, 400 * 2208.047 / 2284.047, accuracy: 1)

        XCTAssertTrue(cache.vectorImage(for: square, height: 400) === first)
        XCTAssertTrue(cache.vectorImage(for: try Self.innerPlan(withShapes: false), height: 400) === first, "an equal plan shares it")
        XCTAssertEqual(calls.count, 1)

        let other = await cache.renderedVectorImage(for: rounded, height: 400)
        let smaller = await cache.renderedVectorImage(for: square, height: 230)
        XCTAssertEqual(calls.count, 3)
        XCTAssertFalse(other === first)
        XCTAssertEqual(try XCTUnwrap(smaller).size.height, 230, accuracy: 0.5)
        XCTAssertEqual(
            SkinThumbnailCache.vectorKey(for: square, height: 400),
            SkinThumbnailCache.vectorKey(for: try Self.innerPlan(withShapes: false), height: 400)
        )
        XCTAssertNotEqual(
            SkinThumbnailCache.vectorKey(for: square, height: 400),
            SkinThumbnailCache.vectorKey(for: rounded, height: 400)
        )
    }

    /// Vector bodies share the gallery previews' pixel budget: the least
    /// recently used image goes first, whichever kind it is.
    func testVectorBodiesStayWithinThePreviewBudget() async throws {
        // Each image is 10x20 px = 800 bytes; room for three.
        let cache = SkinThumbnailCache(
            costLimit: 2_400,
            render: { _, _, _, _ in Self.solidImage(width: 10, height: 20) },
            renderVector: { _, _, _ in Self.solidImage(width: 10, height: 20) }
        )
        let skin = Self.variant(named: "skin")
        _ = await cache.renderedImage(for: skin, height: 20)
        for height in [20, 21, 22] {
            _ = await cache.renderedVectorImage(for: try Self.innerPlan(withShapes: false), height: CGFloat(height))
        }

        XCTAssertLessThanOrEqual(cache.previewBytes, 2_400)
        XCTAssertNil(cache.image(for: skin, height: 20), "the oldest, a skin preview, is dropped")
        XCTAssertNotNil(cache.vectorImage(for: try Self.innerPlan(withShapes: false), height: 22))
    }

    /// The real vector renderer: the body at the requested height, the
    /// placeholder screen inside it, the camera hole black over it, and a
    /// transparent canvas past the body's corner. 400 pt at 2x is 0.3502
    /// px per unit: the hole's centre (66.024 + 1987.5, 66.024 + 80) is at
    /// (719.2, 51.1), r 13.8, and the screen's middle at (386.7, 400.0).
    func testTheVectorRendererDrawsThePlaceholderInTheBody() throws {
        let image = try XCTUnwrap(SkinThumbnail.renderVector(try Self.innerPlan(withShapes: true), height: 400, scale: 2))
        XCTAssertEqual(image.height, 800)
        XCTAssertEqual(image.width, Int((2208.047 * 800 / 2284.047).rounded(.up)))
        let pixels = try Self.rgba(image)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let offset = (y * image.width + x) * 4
            return Array(pixels[offset..<offset + 4])
        }
        XCTAssertEqual(pixel(719, 51), [0, 0, 0, 255], "the hole")
        XCTAssertEqual(pixel(0, 0)[3], 0, "past the body's corner")
        let screen = pixel(386, 400)
        XCTAssertEqual(screen[3], 255)
        // DH's stopped device shows a plain light-blue wallpaper, not a
        // dark one: blue-dominant, and lighter than
        // the old dark-navy placeholder (sum was < 300; the new gradient
        // reads ~414–490 depending on position).
        XCTAssertGreaterThan(Int(screen[2]), Int(screen[0]), "blue-dominant: \(screen)")
        let sum = Int(screen[0]) + Int(screen[1]) + Int(screen[2])
        XCTAssertTrue((380...520).contains(sum), "the placeholder's light-blue wallpaper: \(screen)")
        XCTAssertEqual(pixel(10, 400), [1, 1, 1, 255], "the glass")
    }

    /// The image's premultiplied sRGB RGBA bytes, top row first.
    private static func rgba(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: buffer.baseAddress,
                      width: image.width,
                      height: image.height,
                      bitsPerComponent: 8,
                      bytesPerRow: image.width * 4,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(drawn)
        return bytes
    }

    // MARK: - The opening's edge

    /// The preview fills the artwork's opening from under the artwork, as
    /// the live stage does (`FramedBodyLayers`): a backing outset 2 pixels
    /// past the screen, drawn before the artwork, and the placeholder screen
    /// over it. Drawn only above the artwork, the placeholder's
    /// anti-aliased edge and the artwork's shared the pixel an edge falls
    /// in at a fractional scale and each let the other's uncovered share
    /// through, a see-through line along the opening's straight edges.
    ///
    /// The synthetic skin (the traits tests' artwork at 8x: a 1280x2880
    /// opening at (160, 160) of a 1600x3200 layout; generated input) drawn
    /// 410 pt tall at 1x puts every straight edge half a pixel in (20.5,
    /// 184.5, 389.5), the worst case, and 405 and 415 pt a quarter either
    /// way. Every pixel within one of an edge, over its middle 60%, must be
    /// opaque; before the backing was drawn the weakest read alpha 191–199
    /// of 255.
    func testThePreviewHasNoSeamAtTheOpeningsStraightEdges() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicehubpro-skin-seam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.writePNG(
            try SkinRenderTraitsTests.syntheticArtwork(layout: .rgba8, scale: 8),
            to: directory.appendingPathComponent("back.png")
        )
        let display = SkinDisplay(
            displaySize: CGSize(width: 1280, height: 2880),
            origin: CGPoint(x: 160, y: 160),
            layoutSize: CGSize(width: 1600, height: 3200),
            backgroundImage: "back.png",
            maskImage: nil,
            orientation: .portrait,
            cornerRadius: 200
        )
        let variant = SkinVariant(id: "default", directory: directory, layout: SkinLayoutFile(portrait: display, landscape: nil))

        for height: CGFloat in [410, 405, 415] {
            let preview = try XCTUnwrap(SkinThumbnail.render(variant: variant, height: height, scale: 1))
            try Self.assertOpaqueEdges(of: preview, screen: display.screenRect, pointsPerUnit: height / 3200, scale: 1, "\(height) pt")
        }
    }

    /// The same on real SDK skins with a transparent opening, at the
    /// stopped hero's 400 pt on a 1x and a 2x display (skipped without the
    /// SDK). Before the backing, the weakest edge pixel read alpha 197–226.
    func testRealSkinPreviewsHaveNoSeamAtTheirOpenings() throws {
        guard let skins = SkinLocator.skinsDirectory() else {
            throw XCTSkip("no Android SDK skins directory")
        }
        let catalog = SkinResolver.catalog(skinsDirectory: skins)
        var checked = 0
        for (name, id) in [("pixel_9_pro_fold", "closed"), ("pixel_9_pro_fold", "default"), ("pixel_10_pro", "default")] {
            guard let variant = catalog.first(where: { $0.name == name })?.variants.first(where: { $0.id == id }),
                  let display = variant.layout?.preferred
            else { continue }
            for scale: CGFloat in [1, 2] {
                let preview = try XCTUnwrap(SkinThumbnail.render(variant: variant, height: 400, scale: scale), name)
                try Self.assertOpaqueEdges(
                    of: preview,
                    screen: display.screenRect,
                    pointsPerUnit: 400 / display.layoutSize.height,
                    scale: scale,
                    "\(name)/\(id) at \(scale)x"
                )
            }
            checked += 1
        }
        if checked == 0 { throw XCTSkip("none of the checked skins is installed") }
    }

    /// Every pixel within one of the screen's straight edges (`screen` in
    /// layout units), over the middle 60% of each edge, is opaque.
    private static func assertOpaqueEdges(
        of image: CGImage,
        screen: CGRect,
        pointsPerUnit: CGFloat,
        scale: CGFloat,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let alpha = try alphaPlane(image)
        let pixels = pointsPerUnit * scale
        let rect = CGRect(x: screen.minX * pixels, y: screen.minY * pixels, width: screen.width * pixels, height: screen.height * pixels)
        let rows = Int((rect.minY + rect.height * 0.2).rounded(.up))..<Int((rect.minY + rect.height * 0.8).rounded(.down))
        let columns = Int((rect.minX + rect.width * 0.2).rounded(.up))..<Int((rect.minX + rect.width * 0.8).rounded(.down))
        var weakest = (alpha: UInt8(255), x: 0, y: 0)
        func check(_ x: Int, _ y: Int) {
            let value = alpha[y * image.width + x]
            if value < weakest.alpha { weakest = (value, x, y) }
        }
        for edge in [rect.minX, rect.maxX] {
            let column = Int(edge.rounded(.down))
            for y in rows { for x in column - 1...column + 1 { check(x, y) } }
        }
        for edge in [rect.minY, rect.maxY] {
            let row = Int(edge.rounded(.down))
            for x in columns { for y in row - 1...row + 1 { check(x, y) } }
        }
        XCTAssertEqual(weakest.alpha, 255, "\(context): see-through at pixel (\(weakest.x), \(weakest.y))", file: file, line: line)
    }

    /// The image's alpha channel, top row first.
    private static func alphaPlane(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(drawn)
        return bytes
    }

    func testRealSkinsRenderWhenTheSDKIsInstalled() throws {
        guard let skins = SkinLocator.skinsDirectory() else {
            throw XCTSkip("no Android SDK skins directory")
        }
        let catalog = SkinResolver.catalog(skinsDirectory: skins)
        for name in ["pixel_10_pro", "pixel_tablet", "wearos_xl_round"] {
            guard let variant = catalog.first(where: { $0.name == name })?.preferredVariant else { continue }
            XCTAssertNotNil(SkinThumbnail.render(variant: variant, height: 230, scale: 2), name)
        }
    }

    // MARK: - Fixtures

    private static func variant(named name: String) -> SkinVariant {
        SkinVariant(
            id: "default",
            directory: URL(fileURLWithPath: "/nonexistent/\(name)"),
            layout: nil
        )
    }

    nonisolated static func solidImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: max(width, 1),
            height: max(height, 1),
            bitsPerComponent: 8,
            bytesPerRow: max(width, 1) * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func writePNG(_ image: NSImage, to url: URL) throws {
        var rect = CGRect(origin: .zero, size: image.size)
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}

private final class RenderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [Bool] = []

    func record(onMain: Bool) {
        lock.lock()
        calls.append(onMain)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls.count
    }

    var onMain: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}

@MainActor
private final class TestClock {
    var now = Date(timeIntervalSince1970: 1_000_000)
}
