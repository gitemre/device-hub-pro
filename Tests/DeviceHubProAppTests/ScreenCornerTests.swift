import XCTest
import AppKit
import ImageIO
import SwiftUI
@testable import DeviceHubProKit
@testable import DeviceHubProApp

/// The screen corner (`ScreenCornerPolicy`: the device's own radius, capped
/// at the skin's opening) where the app draws a device: the live stage's
/// video clip, framed and thin-bezel, the static heroes and their cache, and
/// the framed screenshot's resolver. Device shapes are the API 37 Pixel 9
/// Pro Fold emulator's real `dumpsys display` capture (inner panel radius
/// 85, cover 115); skin numbers come from the installed SDK skins, and the
/// tests that read them skip without the SDK.
@MainActor
final class ScreenCornerTests: XCTestCase {
    private static let inner = CGSize(width: 2076, height: 2152)
    private static let cover = CGSize(width: 1080, height: 2424)

    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("DeviceHubProKitTests/Fixtures/api37-emulator/adb-core/shell-dumpsys-display.txt")

    private static func foldShapes() throws -> [DisplayShape] {
        DisplayShape.parse(dumpsysDisplay: try String(contentsOf: fixture, encoding: .utf8))
    }

    private func sdkSkin(named name: String) throws -> ResolvedSkin {
        guard let skins = SkinLocator.skinsDirectory() else {
            throw XCTSkip("no Android SDK skins directory")
        }
        let entry = try XCTUnwrap(
            SkinResolver.catalog(skinsDirectory: skins).first(where: { $0.name == name }),
            "missing skin \(name)"
        )
        return ResolvedSkin(name: entry.name, directory: entry.directory, source: .skinName, variants: entry.variants)
    }

    private func variant(_ skin: ResolvedSkin, _ id: String) throws -> (SkinVariant, SkinDisplay) {
        let variant = try XCTUnwrap(skin.variants.first(where: { $0.id == id }), "\(skin.name)/\(id)")
        return (variant, try XCTUnwrap(variant.layout?.preferred))
    }

    // MARK: - Real skins

    /// The opening radii the Kit's policy tests are written with, as the
    /// app measures them from the installed artwork, and the corner the app
    /// decides for each with the fold's real shapes (or none).
    func testTheRealSkinsCornersFollowThePolicy() throws {
        let cache = SkinThumbnailCache()
        let shapes = try Self.foldShapes()
        let fold = try sdkSkin(named: "pixel_9_pro_fold")
        let cases: [(ResolvedSkin, String, opening: CGFloat, device: DisplayShape?, want: ScreenCorner)] = [
            (try sdkSkin(named: "pixel_10_pro"), "default", 180.08, nil, ScreenCorner(radius: 99, source: .declared)),
            (fold, "default", 119.61, DisplayShape.matching(frame: Self.inner, in: shapes), ScreenCorner(radius: 85, source: .device)),
            (fold, "default", 119.61, nil, ScreenCorner(radius: 119.61, source: .opening)),
            (fold, "closed", 147.26, DisplayShape.matching(frame: Self.cover, in: shapes), ScreenCorner(radius: 115, source: .device)),
            (fold, "closed", 147.26, nil, ScreenCorner(radius: 75, source: .declared)),
            (try sdkSkin(named: "pixel_tablet"), "default", 30.37, nil, ScreenCorner(radius: 30.37, source: .opening)),
        ]
        for (skin, id, opening, device, want) in cases {
            let (variant, display) = try variant(skin, id)
            let context = "\(skin.name)/\(id) device \(device?.maxCornerRadius ?? 0)"
            XCTAssertEqual(
                try XCTUnwrap(cache.traits(for: variant, display: display).openingCornerRadius, context),
                opening,
                accuracy: 0.01,
                context
            )
            let corner = cache.screenCorner(for: variant, display: display, device: device)
            XCTAssertEqual(corner.radius, want.radius, accuracy: 0.01, context)
            XCTAssertEqual(corner.source, want.source, context)
            XCTAssertFalse(corner.isCappedAtOpening, context)
        }
    }

    /// The static preview keeps a modern mask's camera lens but leaves out
    /// its corner fill, measured here: about the opening on every skin but
    /// `pixel_8a`, which ships the Pixel 8's mask (88.8 over its own 55.7
    /// opening), the skin behind the `atd34` AVD.
    func testTheMasksCornerFillIsMeasured() throws {
        let cache = SkinThumbnailCache()
        let cases: [(String, String, mask: CGFloat, opening: CGFloat)] = [
            ("pixel_8a", "default", 88.8, 55.69),
            ("pixel_9_pro_fold", "default", 116.1, 119.61),
            ("pixel_9_pro_fold", "closed", 146.8, 147.26),
        ]
        for (name, id, mask, opening) in cases {
            let (variant, display) = try variant(sdkSkin(named: name), id)
            let image = try XCTUnwrap(SkinThumbnail.loadImage(named: display.maskImage, in: variant.directory), name)
            let fill = try XCTUnwrap(SkinRenderTraits.maskCornerRadius(mask: image, display: display), name)
            XCTAssertEqual(fill, mask, accuracy: 0.5, name)
            let traits = cache.traits(for: variant, display: display)
            XCTAssertEqual(try XCTUnwrap(traits.openingCornerRadius, name), opening, accuracy: 0.01, name)
        }
    }

    /// A framed screenshot asks the same question as the live stage: the
    /// fold's cover capture gets the cover's 115, the inner capture 85.
    func testTheScreenshotResolverAnswersTheLiveStagesCorner() async throws {
        let fold = try sdkSkin(named: "pixel_9_pro_fold")
        let cache = SkinThumbnailCache()
        let resolver = CaptureController.screenCornerResolver(shapes: try Self.foldShapes(), cache: cache)
        let (closed, closedDisplay) = try variant(fold, "closed")
        let (open, openDisplay) = try variant(fold, "default")

        let coverRadius = await resolver(closed, closedDisplay, Self.cover)
        let innerRadius = await resolver(open, openDisplay, Self.inner)
        let noShapes = await CaptureController.screenCornerResolver(shapes: [], cache: cache)(closed, closedDisplay, Self.cover)

        XCTAssertEqual(try XCTUnwrap(coverRadius), 115, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(innerRadius), 85, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(noShapes), 75, accuracy: 1e-9, "the declared radius without device data")
    }

    /// A variant the live stage never measured (the fold's cover with Show
    /// Device Frame off) is measured off the main thread, once, from the
    /// same artwork: the live stage then reads the kept traits. One the live
    /// stage measured is not measured again.
    func testTheScreenshotResolverMeasuresAMissOffTheMainThreadOnce() async throws {
        let fold = try sdkSkin(named: "pixel_9_pro_fold")
        let log = MeasureLog()
        let cache = SkinThumbnailCache(measureTraits: { variant, display in
            log.record(variant.id, onMainThread: pthread_main_np() != 0)
            return SkinThumbnailCache.measuredTraits(for: variant, display: display)
        })
        let resolver = CaptureController.screenCornerResolver(shapes: try Self.foldShapes(), cache: cache)
        let (closed, closedDisplay) = try variant(fold, "closed")
        let (open, openDisplay) = try variant(fold, "default")

        let first = await resolver(closed, closedDisplay, Self.cover)
        let again = await resolver(closed, closedDisplay, Self.cover)
        _ = cache.traits(for: open, display: openDisplay)
        let inner = await resolver(open, openDisplay, Self.inner)

        XCTAssertEqual(log.entries, [MeasureLog.Entry(variant: "closed", onMainThread: false)])
        XCTAssertEqual(try XCTUnwrap(first), 115, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(again), 115, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(inner), 85, accuracy: 1e-9)
        XCTAssertEqual(
            try XCTUnwrap(cache.traits(for: closed, display: closedDisplay).openingCornerRadius),
            147.26,
            accuracy: 0.01,
            "the live stage reads what the screenshot measured"
        )
    }

    /// The whole framed-screenshot path: the capture of the fold's cover is
    /// composited into the cover's artwork and clipped at the mirrored
    /// device's 115 (the shapes `displayShapesProvider` hands over), not the
    /// skin's declared 75. Probed on the display's top-left diagonal, where
    /// the 75 arc is 22.0 artwork px in, the 115 arc 33.7 and the artwork's
    /// opening 43.1: at 28 px the shot shows under 75 and the bezel under
    /// 115; at 38 px the shot shows under both.
    func testAFramedScreenshotIsClippedToTheMirroredDevicesCorner() async throws {
        let fold = try sdkSkin(named: "pixel_9_pro_fold")
        let (closed, closedDisplay) = try variant(fold, "closed")
        let display = try XCTUnwrap(DeviceFrameRenderer.spec(for: closed, display: closedDisplay)).displayRect
        let shapes = try Self.foldShapes()

        let withShapes = try await framedShot(of: fold, shapes: shapes)
        XCTAssertFalse(try Self.isRed(withShapes, x: display.minX + 28, y: display.minY + 28), "outside the device's 115")
        XCTAssertTrue(try Self.isRed(withShapes, x: display.minX + 38, y: display.minY + 38), "inside it")

        let withoutShapes = try await framedShot(of: fold, shapes: [])
        XCTAssertTrue(try Self.isRed(withoutShapes, x: display.minX + 28, y: display.minY + 28), "inside the declared 75")
    }

    /// The model hands framed screenshots the displays the live stage draws
    /// with (`MirrorController.liveDisplayShapes`): the session's read, else
    /// the AVD's stored shapes.
    func testTheModelHandsFramedScreenshotsTheLiveStagesShapes() async throws {
        let shapes = try Self.foldShapes()
        let model = AppModel.testing()
        XCTAssertEqual(model.capture.displayShapesProvider(), [])
        await model.mirror.mirrorViewState.loadDisplayShapes { shapes }
        XCTAssertEqual(model.capture.displayShapesProvider(), shapes)

        // A made-up AVD name: the context reads the named AVD's config.ini.
        let stored = AppModel.testing()
        stored.context.avdName = "ScreenCornerTests_Stored"
        stored.mirror.displayShapes.record(shapes, forAvd: "ScreenCornerTests_Stored")
        XCTAssertEqual(stored.capture.displayShapesProvider(), shapes)
        XCTAssertEqual(stored.capture.displayShapesProvider(), stored.mirror.liveDisplayShapes)
    }

    /// Takes a framed screenshot through `CaptureController` of an AVD whose
    /// `skin.path` is `skin`, in a temporary AVD home, with a stub adb whose
    /// `screencap` is a solid red 1080x2424 capture (the cover's size).
    private func framedShot(of skin: ResolvedSkin, shapes: [DisplayShape]) async throws -> CGImage {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicehubpro-framed-shot-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let avdDirectory = root.appendingPathComponent("avd/ScreenCornerFold.avd", isDirectory: true)
        try FileManager.default.createDirectory(at: avdDirectory, withIntermediateDirectories: true)
        try Data("skin.path=\(skin.directory.path)\n".utf8).write(to: avdDirectory.appendingPathComponent("config.ini"))

        let shot = root.appendingPathComponent("cover.png")
        let red = try XCTUnwrap(CGContext(
            data: nil,
            width: Int(Self.cover.width),
            height: Int(Self.cover.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        red.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        red.fill(CGRect(origin: .zero, size: Self.cover))
        try Self.writePNG(NSImage(cgImage: try XCTUnwrap(red.makeImage()), size: .zero), to: shot)

        let adb = try makeStubAdb(arms: """
          "-s emulator-5554 exec-out screencap -p")
            cat '\(shot.path)' ;;
        """)
        let preferences = AppPreferences(defaults: .scratch())
        preferences.setIncludeDeviceFrameInScreenshots(true)
        let context = ActiveDeviceContext(avdHome: root.appendingPathComponent("avd", isDirectory: true))
        context.serial = "emulator-5554"
        context.avdName = "ScreenCornerFold"
        let status = StatusCenter()
        let capture = CaptureController(
            adbClient: adb.client,
            status: status,
            preferences: preferences,
            context: context,
            pasteboard: TestPasteboard(),
            picker: TestPicker()
        )
        capture.displayShapesProvider = { shapes }

        await capture.annotateScreenshot()

        XCTAssertNil(status.statusMessage, "framed without a fallback")
        let png = try XCTUnwrap(capture.annotationEditRequest?.png)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// Whether the composite's pixel at (`x`, `y`) — top-left based artwork
    /// pixels — is the red capture.
    private static func isRed(_ image: CGImage, x: CGFloat, y: CGFloat) throws -> Bool {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let (px, py) = (Int(x), Int(y))
        context.draw(image, in: CGRect(x: -px, y: py - image.height + 1, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return bytes[0] > 200 && bytes[1] < 40 && bytes[2] < 40 && bytes[3] > 200
    }

    // MARK: - Heroes

    /// A stopped AVD's hero takes the stored panel matching the variant it
    /// shows: the inner screen's 85 for the open fold, the cover's 115 for
    /// the closed one (the fold skin's own display sizes).
    func testTheHeroPicksThePanelItsVariantShows() throws {
        let shapes = try Self.foldShapes()
        let open = Self.variant(displaySize: Self.inner)
        let closed = Self.variant(displaySize: Self.cover)
        XCTAssertEqual(SkinHero.deviceCornerRadius(for: open, shapes: shapes), 85)
        XCTAssertEqual(SkinHero.deviceCornerRadius(for: closed, shapes: shapes), 115)
        XCTAssertNil(SkinHero.deviceCornerRadius(for: open, shapes: []))
        XCTAssertNil(
            SkinHero.deviceCornerRadius(for: Self.variant(displaySize: CGSize(width: 2560, height: 1600)), shapes: shapes),
            "a tablet display fits neither fold panel"
        )
    }

    /// Previews of one skin with different device corners are rendered and
    /// cached apart; the same corner is served from the cache.
    func testThePreviewCacheKeyIncludesTheDeviceCorner() async throws {
        let log = CornerLog()
        let cache = SkinThumbnailCache(render: { _, height, scale, corner in
            log.record(corner)
            return SkinPreviewCacheTests.solidImage(width: Int(height * scale / 2), height: Int(height * scale))
        })
        let variant = Self.variant(displaySize: Self.inner)

        let skin = await cache.renderedImage(for: variant)
        let device = await cache.renderedImage(for: variant, deviceCornerRadius: 85)
        let again = await cache.renderedImage(for: variant, deviceCornerRadius: 85)
        let other = await cache.renderedImage(for: variant, deviceCornerRadius: 115)

        XCTAssertEqual(log.corners, [nil, 85, 115])
        XCTAssertTrue(device === again)
        XCTAssertFalse(skin === device)
        XCTAssertFalse(device === other)
        XCTAssertNotEqual(
            SkinThumbnailCache.previewKey(for: variant, height: 400, deviceCornerRadius: nil),
            SkinThumbnailCache.previewKey(for: variant, height: 400, deviceCornerRadius: 0)
        )
    }

    // MARK: - The static preview

    /// The preview draws the placeholder screen over the artwork, clipped
    /// to the policy's corner, as the live video is. The synthetic skin (the
    /// traits tests' artwork at 8x: a 1280x2880 opening of radius 320 at
    /// (160, 160) in a 1600x3200 layout) declares 200; rendered 400 pt tall
    /// that is 25 pt, the opening 40 pt, a device's 100 12.5 pt.
    func testThePreviewClipsTheScreenToThePolicysCorner() throws {
        let skin = try Self.syntheticSkin(declared: 200)
        // Top-left of the screen at (20, 20) pt; probes on its diagonal.
        func probe(_ inset: Int, _ image: CGImage) throws -> Probe {
            try Probe(image, x: 20 + inset, y: 20 + inset)
        }
        let declared = try XCTUnwrap(SkinThumbnail.render(variant: skin.variant, height: 400, scale: 1))
        XCTAssertEqual(try probe(9, declared), .placeholder, "inside the declared 25 pt corner")
        XCTAssertEqual(try probe(5, declared), .artwork, "outside it")

        let device = try XCTUnwrap(SkinThumbnail.render(variant: skin.variant, height: 400, scale: 1, deviceCornerRadius: 100))
        XCTAssertEqual(try probe(5, device), .placeholder, "inside the device's 12.5 pt corner")
        XCTAssertEqual(try probe(1, device), .artwork, "still rounded")

        let undeclared = try Self.syntheticSkin(declared: nil)
        let opening = try XCTUnwrap(SkinThumbnail.render(variant: undeclared.variant, height: 400, scale: 1))
        XCTAssertEqual(try probe(7, opening), .artwork, "the opening's 40 pt corner without a declared one")
        XCTAssertEqual(try probe(14, opening), .placeholder)
    }

    /// A modern mask's corner fill (drawn here out to the opening, as the
    /// SDK masks are) would round the screen off at the opening again; the
    /// preview keeps only what lies inside it, like the lens.
    func testThePreviewKeepsTheMasksLensButNotItsCorners() throws {
        let skin = try Self.syntheticSkin(declared: 200, maskWithLens: true)
        let image = try XCTUnwrap(SkinThumbnail.render(variant: skin.variant, height: 400, scale: 1, deviceCornerRadius: 100))
        XCTAssertEqual(try Probe(image, x: 25, y: 25), .placeholder, "the mask's corner fill is left out")
        // The lens: a 20-unit dot at the display's top centre, (100, 40) pt.
        XCTAssertEqual(try Probe(image, x: 100, y: 40), .mask)
    }

    // MARK: - The thin bezel (Apple devices)

    /// An Apple device's thin bezel (`DeviceChrome.thinBezel`): the video is
    /// clipped to the device's radius at the screen's size and the bezel is
    /// concentric.
    func testTheThinBezelIsConcentricWithTheDevicesCorner() throws {
        let inner = try XCTUnwrap(DisplayShape.matching(frame: Self.inner, in: Self.foldShapes()))
        // The inner panel laid out 1038 pt wide: half size.
        let corners = ThinBezelCorners(device: inner, screen: CGSize(width: 1038, height: 1076), bezel: 8, growth: 1)
        XCTAssertEqual(corners.screen, 42.5, accuracy: 1e-9)
        XCTAssertEqual(corners.outer, 50.5, accuracy: 1e-9)

        let grown = ThinBezelCorners(device: inner, screen: CGSize(width: 1038, height: 1076), bezel: 12, growth: 1.5)
        XCTAssertEqual(grown.outer - grown.screen, 12, accuracy: 1e-9, "the band keeps its width round the corner")
    }

    /// Without device data the outer corner stays 16 pt (grown with the
    /// layout) and the video's is 16 pt less the bezel.
    func testTheThinBezelFallsBackToItsOldOuterCorner() {
        let plain = ThinBezelCorners(device: nil, screen: CGSize(width: 400, height: 800), bezel: 8, growth: 1)
        XCTAssertEqual(plain.screen, 8)
        XCTAssertEqual(plain.outer, 16)
        let grown = ThinBezelCorners(device: nil, screen: CGSize(width: 400, height: 800), bezel: 12, growth: 1.5)
        XCTAssertEqual(grown.screen, 12)
        XCTAssertEqual(grown.outer, 24)
    }

    // MARK: - The live stage, hosted

    /// The live framed fold clips its video to the device's corner at the
    /// hero's scale (85 of 2076 on the inner screen, 115 of 1080 on the
    /// cover), the AVD's stored shapes before the session's read, and the
    /// skin's fallback without either.
    func testTheFramedStageClipsTheVideoToTheDevicesCorner() async throws {
        let fold = try sdkSkin(named: "pixel_9_pro_fold")
        let shapes = try Self.foldShapes()

        // The session's own read.
        for (natural, radius) in [(Self.inner, 85.0), (Self.cover, 115.0)] {
            let hosted = try host(chrome: .skin(fold), natural: natural)
            defer { hosted.window.close() }
            await hosted.model.mirror.mirrorViewState.loadDisplayShapes { shapes }
            try await assertVideoCorner(hosted, radius / natural.width, "read, \(natural)")
        }

        // The AVD's stored shapes, before any read. (A made-up AVD name: the
        // context reads the named AVD's config.ini.)
        let stored = try host(chrome: .skin(fold), natural: Self.cover)
        defer { stored.window.close() }
        stored.model.context.avdName = "ScreenCornerTests_Fold"
        stored.model.mirror.displayShapes.record(shapes, forAvd: "ScreenCornerTests_Fold")
        try await assertVideoCorner(stored, 115 / Self.cover.width, "stored")

        // Nothing known: the cover's declared 75, the inner screen's opening.
        let (open, openDisplay) = try variant(fold, "default")
        let opening = try XCTUnwrap(SkinThumbnailCache.shared.traits(for: open, display: openDisplay).openingCornerRadius)
        for (natural, radius) in [(Self.cover, 75.0), (Self.inner, opening)] {
            let hosted = try host(chrome: .skin(fold), natural: natural)
            defer { hosted.window.close() }
            try await assertVideoCorner(hosted, radius / natural.width, "fallback, \(natural)")
        }
    }

    /// An Apple device's thin bezel clips its video to the device's radius
    /// at its laid-out size.
    func testTheThinBezelClipsTheVideoToTheDevicesCorner() async throws {
        let shapes = try Self.foldShapes()
        let hosted = try host(chrome: .thinBezel, natural: Self.inner)
        defer { hosted.window.close() }
        await hosted.model.mirror.mirrorViewState.loadDisplayShapes { shapes }
        try await assertVideoCorner(hosted, 85 / Self.inner.width, "thin bezel")
    }

    // MARK: - The vector body, hosted

    /// The backing scales the vector body's hosted checks run at.
    private static let scales: [CGFloat] = [1, 2]

    /// Skinless AVDs and phones: the vector body clips the video to the
    /// device's own radius at its laid-out size, 85 of the inner panel's
    /// 2076 px, from the session's read or, before it, the AVD's stored
    /// shapes (the cover's 115 of 1080).
    func testTheVectorBodyClipsTheVideoToTheDevicesCorner() async throws {
        let shapes = try Self.foldShapes()
        for scale in Self.scales {
            let hosted = try host(chrome: .vector, natural: Self.inner, scale: scale)
            defer { hosted.window.close() }
            await hosted.model.mirror.mirrorViewState.loadDisplayShapes { shapes }
            try await assertVideoCorner(hosted, 85 / Self.inner.width, "vector body at \(scale)x, read")

            let stored = try host(chrome: .vector, natural: Self.cover, scale: scale)
            defer { stored.window.close() }
            stored.model.context.avdName = "ScreenCornerTests_Skinless"
            stored.model.mirror.displayShapes.record(shapes, forAvd: "ScreenCornerTests_Skinless")
            try await assertVideoCorner(stored, 115 / Self.cover.width, "vector body at \(scale)x, stored")
        }
    }

    /// A device that reports no corner gets a square screen:
    /// no clip at all, not a made-up radius.
    func testTheVectorBodysScreenIsSquareWithoutDeviceShapes() async throws {
        for scale in Self.scales {
            let hosted = try host(chrome: .vector, natural: Self.inner, scale: scale)
            defer { hosted.window.close() }
            let view = try await settledVideo(hosted, "\(scale)x")
            XCTAssertEqual(view.layer?.cornerRadius, 0, "\(scale)x")
            XCTAssertEqual(view.layer?.masksToBounds, false, "\(scale)x")
        }
    }

    /// The body is concentric with the screen: its outer corner is the
    /// screen's 85 plus the 66.024 px foldableInner bezel, 151.024 layout
    /// units, drawn at the scale the stage lays the body out at, which is
    /// the scale the hosted video shows the 2076 px panel at.
    ///
    /// Measured on what the hosted stage drew (`cacheDisplay`, one pixel per
    /// backing pixel): the body's outer edge is its rim, black at 0.148 over
    /// the white the snapshot is drawn on, so a pixel's rim coverage is its
    /// darkening over 0.148. The left and top edges are found on the rows
    /// and columns through the body's middle, and the corner arc on each row
    /// and column across it, each as the uncovered length of its pixel strip
    /// (exact for a straight edge, second-order for the arc); each arc point
    /// gives the radius of the circle tangent to both edges through it
    /// (`(a − r)² + (b − r)² = r²`). Their mean is the drawn radius, to
    /// within a backing pixel of 151.024 × the video's scale, and no point
    /// strays a pixel from that circle.
    func testTheVectorBodysOuterCornerIsConcentricWithTheScreens() async throws {
        let shapes = try Self.foldShapes()
        for scale in Self.scales {
            let context = "\(scale)x"
            let hosted = try host(chrome: .vector, natural: Self.inner, scale: scale)
            defer { hosted.window.close() }
            await hosted.model.mirror.mirrorViewState.loadDisplayShapes { shapes }
            let view = try await settledVideo(hosted, context)
            let shown = view.bounds.width / Self.inner.width

            // The plan the view draws, laid out as the view lays it out:
            // fitted into the stage less 8 pt a side, at rest. These are the
            // numbers the drawing is held to.
            let plan = VectorDeviceView.composition(workspace: hosted.model.workspace, session: hosted.session, screen: Self.inner)
            guard case .vector(let body) = plan.body else { return XCTFail("\(context): a vector plan") }
            XCTAssertEqual(body.family, .foldableInner, context)
            XCTAssertEqual(body.outerRadius, 151.024, accuracy: 0.01, context)
            let laidOut = PoseFit.scale(
                angle: 0,
                nativeSize: plan.layoutSize,
                box: CGSize(width: hosted.stage.width - 16, height: hosted.stage.height - 16)
            )
            // SwiftUI rounds the laid-out video to the pixel grid: within a
            // backing pixel of the 2076 px width.
            let slack = 1 / hosted.window.backingScaleFactor / Self.inner.width
            XCTAssertEqual(laidOut, shown, accuracy: slack, "\(context): the video shows the plan's scale")
            XCTAssertEqual(view.layer?.cornerRadius ?? 0, 85 * laidOut, accuracy: 1e-6, "\(context): the video's clip")

            let drawn = try drawnOuterCorner(hosted, video: view, bezel: body.bezel * laidOut, context)
            let expected = 151.024 * laidOut * scale
            XCTAssertEqual(drawn.radius, expected, accuracy: 1, "\(context): the drawn outer corner, pixels")
            XCTAssertLessThan(drawn.worstMiss, 1, "\(context): the drawn corner is that circle's arc")
            XCTAssertGreaterThan(drawn.points, Int(expected / 2), "\(context): arc points measured")
        }
    }

    /// The top-left outer corner of the vector body the hosted stage drew
    /// (see `testTheVectorBodysOuterCornerIsConcentricWithTheScreens`):
    /// the mean radius, in backing pixels, of the circles tangent to the
    /// body's left and top edges through each measured point of its arc;
    /// the farthest any point lies from the circle of that radius; and how
    /// many points were measured. `bezel` (points) only places the search.
    private func drawnOuterCorner(
        _ hosted: Hosted,
        video: MirrorMetalView,
        bezel: CGFloat,
        _ context: String
    ) throws -> (radius: CGFloat, worstMiss: CGFloat, points: Int) {
        let host = hosted.host
        XCTAssertTrue(host.isFlipped, "\(context): top-left based, as the bitmap's rows")
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds), context)
        host.cacheDisplay(in: host.bounds, to: rep)
        let pixelScale = CGFloat(rep.pixelsWide) / host.bounds.width
        XCTAssertEqual(pixelScale, hosted.window.backingScaleFactor, "\(context): one pixel per backing pixel")

        let paper = try XCTUnwrap(rep.colorAt(x: 0, y: 0), context)
        XCTAssertEqual(paper.brightnessComponent, 1, accuracy: 1e-3, "\(context): drawn on white")
        XCTAssertEqual(paper.alphaComponent, 1, accuracy: 1e-3, "\(context): drawn on white")
        let rim = try XCTUnwrap(ChromeSpec.standard(.foldableInner).bands.first).color.alpha
        func coverage(_ x: Int, _ y: Int) -> CGFloat {
            guard let color = rep.colorAt(x: x, y: y) else { return 0 }
            return min(max((1 - color.brightnessComponent) / rim, 0), 1)
        }
        /// The uncovered length of a strip of pixels from `start`, `count`
        /// long: where the body's edge crosses it, from `start`.
        func uncovered(from start: Int, count: Int, _ pixel: (Int) -> CGFloat) -> CGFloat {
            (0..<count).reduce(0) { $0 + (1 - pixel(start + $1)) }
        }

        let frame = video.convert(video.bounds, to: host)
        let margin = 4
        let bezelPixels = Int((bezel * pixelScale).rounded(.up))
        let searchLeft = Int(frame.minX * pixelScale) - bezelPixels - margin
        let searchTop = Int(frame.minY * pixelScale) - bezelPixels - margin
        let span = bezelPixels + 2 * margin
        let midRow = Int(frame.midY * pixelScale)
        let midColumn = Int(frame.midX * pixelScale)
        let left = CGFloat(searchLeft) + uncovered(from: searchLeft, count: span) { coverage($0, midRow) }
        let top = CGFloat(searchTop) + uncovered(from: searchTop, count: span) { coverage(midColumn, $0) }

        // Rows through the steep half of the arc, columns through the
        // shallow half: each strip crosses the edge at 45° or steeper.
        let guess = 151.024 * video.bounds.width / Self.inner.width * pixelScale
        let steep = Int((guess * (1 - 1 / 2.squareRoot())).rounded(.up))
        let reach = Int(guess.rounded(.up)) + 2 * margin
        var arc: [(a: CGFloat, b: CGFloat)] = []
        for step in (steep + 1)..<Int(guess.rounded(.down)) {
            let row = Int(top) + step
            let x = CGFloat(searchLeft) + uncovered(from: searchLeft, count: reach) { coverage($0, row) }
            arc.append((a: x - left, b: CGFloat(row) + 0.5 - top))
            let column = Int(left) + step
            let y = CGFloat(searchTop) + uncovered(from: searchTop, count: reach) { coverage(column, $0) }
            arc.append((a: CGFloat(column) + 0.5 - left, b: y - top))
        }
        guard !arc.isEmpty else {
            XCTFail("\(context): no arc measured")
            return (0, .infinity, 0)
        }
        // (a − r)² + (b − r)² = r², the root larger than a and b.
        let radii = arc.map { $0.a + $0.b + (2 * max($0.a * $0.b, 0)).squareRoot() }
        let radius = radii.reduce(0, +) / CGFloat(radii.count)
        let worstMiss = arc.map { abs(hypot($0.a - radius, $0.b - radius) - radius) }.max() ?? .infinity
        return (radius, worstMiss, arc.count)
    }

    /// The hosted video once SwiftUI has applied the latest change.
    private func settledVideo(_ hosted: Hosted, _ context: String) async throws -> MirrorMetalView {
        // Best effort: the sleep fails only on cancellation. SwiftUI applies
        // the observed change on its next update.
        try? await Task.sleep(for: .milliseconds(50))
        hosted.host.layoutSubtreeIfNeeded()
        let view = try XCTUnwrap(mirrorView(in: hosted.host), context)
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.bounds.width, 10, context)
        return view
    }

    private struct Hosted {
        let stage: CGSize
        let window: NSWindow
        let host: NSView
        let model: AppModel
        let session: FakeMirrorSession
    }

    /// The stage content (`MirrorStageContent`, framed in `chrome`) in an
    /// offscreen 1300x866 window, at `scale` (`ScaledTestWindow`; nil: the
    /// display's), with one upright frame of `natural` streamed.
    private func host(chrome: DeviceChrome, natural: CGSize, scale: CGFloat? = nil) throws -> Hosted {
        let model = AppModel.testing()
        model.workspace.window.showDeviceFrame = true
        let session = FakeMirrorSession()
        let stage = CGSize(width: 1300, height: 866)
        let content = MirrorStageContent(session: session, chrome: chrome, available: stage)
            .environment(model).environment(model.workspace)
            .transaction { $0.animation = nil }
        let host = NSHostingView(rootView: content)
        let window = ScaledTestWindow.hosting(host, size: stage, scale: scale)
        session.frames.put(Frame(
            data: Data(count: Int(natural.width * natural.height) * 4),
            width: Int(natural.width),
            height: Int(natural.height),
            seq: 0,
            rotation: 0
        ))
        model.workspace.mirror.mirrorViewState.devicePixelSize = natural
        model.workspace.mirror.stagePose.settle(rotation: 0)
        return Hosted(stage: stage, window: window, host: host, model: model, session: session)
    }

    /// The video's layer clip over its laid-out width is `fraction`, to
    /// within the point SwiftUI's pixel rounding can take off the laid-out
    /// width (0.15% of these ~700 pt videos; the radii told apart differ by
    /// 30% and more).
    private func assertVideoCorner(
        _ hosted: Hosted,
        _ fraction: CGFloat,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        // Best effort: the sleep fails only on cancellation. SwiftUI applies
        // the observed change on its next update.
        try? await Task.sleep(for: .milliseconds(50))
        hosted.host.layoutSubtreeIfNeeded()
        let view = try XCTUnwrap(mirrorView(in: hosted.host), context, file: file, line: line)
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.bounds.width, 10, context, file: file, line: line)
        let radius = try XCTUnwrap(view.layer?.cornerRadius, context, file: file, line: line)
        XCTAssertEqual(radius, fraction * view.bounds.width, accuracy: fraction, context, file: file, line: line)
        XCTAssertEqual(view.layer?.masksToBounds, true, context, file: file, line: line)
    }

    private func mirrorView(in view: NSView) -> MirrorMetalView? {
        if let mirror = view as? MirrorMetalView { return mirror }
        for subview in view.subviews {
            if let mirror = mirrorView(in: subview) { return mirror }
        }
        return nil
    }

    // MARK: - Fixtures

    private static func variant(displaySize: CGSize) -> SkinVariant {
        let display = SkinDisplay(
            displaySize: displaySize,
            origin: .zero,
            layoutSize: displaySize,
            backgroundImage: nil,
            maskImage: nil,
            orientation: .portrait
        )
        return SkinVariant(
            id: "default",
            directory: URL(fileURLWithPath: "/nonexistent/\(Int(displaySize.width))x\(Int(displaySize.height))"),
            layout: SkinLayoutFile(portrait: display, landscape: nil)
        )
    }

    private struct SyntheticSkin {
        let variant: SkinVariant
        let directory: URL
    }

    /// The traits tests' artwork at 8x (1600x3200, opening radius 320 at
    /// (160, 160), 1280x2880) as a skin, declaring `declared`; with
    /// `maskWithLens`, a display-sized mask that fills the corners out to
    /// the opening and paints a lens dot at the top centre.
    private static func syntheticSkin(declared: CGFloat?, maskWithLens: Bool = false) throws -> SyntheticSkin {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicehubpro-screen-corner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writePNG(try SkinRenderTraitsTests.syntheticArtwork(layout: .rgba8, scale: 8), to: directory.appendingPathComponent("back.png"))
        if maskWithLens {
            try writePNG(try maskImage(), to: directory.appendingPathComponent("mask.png"))
        }
        let display = SkinDisplay(
            displaySize: CGSize(width: 1280, height: 2880),
            origin: CGPoint(x: 160, y: 160),
            layoutSize: CGSize(width: 1600, height: 3200),
            backgroundImage: "back.png",
            maskImage: maskWithLens ? "mask.png" : nil,
            orientation: .portrait,
            cornerRadius: declared
        )
        return SyntheticSkin(
            variant: SkinVariant(id: "default", directory: directory, layout: SkinLayoutFile(portrait: display, landscape: nil)),
            directory: directory
        )
    }

    /// 1280x2880, red outside the opening's 320 radius arcs and in a
    /// 160-wide dot centred at (640, 160); clear elsewhere.
    private static func maskImage() throws -> NSImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 1280,
            height: 2880,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1280, height: 2880))
        context.setBlendMode(.clear)
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 1280, height: 2880), cornerWidth: 320, cornerHeight: 320, transform: nil))
        context.fillPath()
        context.setBlendMode(.normal)
        // y up: the top centre is at 2880 − 160.
        context.fillEllipse(in: CGRect(x: 560, y: 2880 - 240, width: 160, height: 160))
        return NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: .zero)
    }

    private static func writePNG(_ image: NSImage, to url: URL) throws {
        var rect = CGRect(origin: .zero, size: image.size)
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}

/// What a preview pixel shows: the synthetic artwork's blue (40, 90, 160),
/// the placeholder screen's light-blue gradient (2026-09-28: DH's
/// plain wallpaper, sampled r 61–87 / g 145–170 / b 208–233), or the
/// synthetic mask's red.
private enum Probe: Equatable {
    case artwork
    case placeholder
    case mask
    case other(Int, Int, Int)

    /// The pixel at (`x`, `y`) points from the top-left of a 1x image.
    init(_ image: CGImage, x: Int, y: Int) throws {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let (r, g, b) = (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
        if abs(r - 40) <= 6, abs(g - 90) <= 6, abs(b - 160) <= 6 {
            self = .artwork
        } else if r > 200, g < 40, b < 40 {
            self = .mask
        } else if (40...110).contains(r), (120...190).contains(g), (190...245).contains(b) {
            self = .placeholder
        } else {
            self = .other(r, g, b)
        }
    }
}

/// The off-main measurements a cache ran: which variant, on which thread.
private final class MeasureLog: @unchecked Sendable {
    struct Entry: Equatable {
        let variant: String
        let onMainThread: Bool
    }

    private let lock = NSLock()
    private var recorded: [Entry] = []

    func record(_ variant: String, onMainThread: Bool) {
        lock.withLock { recorded.append(Entry(variant: variant, onMainThread: onMainThread)) }
    }

    var entries: [Entry] {
        lock.withLock { recorded }
    }
}

private final class CornerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CGFloat?] = []

    func record(_ corner: CGFloat?) {
        lock.withLock { recorded.append(corner) }
    }

    var corners: [CGFloat?] {
        lock.withLock { recorded }
    }
}
