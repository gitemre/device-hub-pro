import CoreGraphics
import ImageIO
import XCTest
@testable import DeviceHubProKit

/// `DeviceCompositionPlanner.skin` and `DeviceComposition.placed`. The skin
/// plan must place every installed SDK skin exactly where the live stage
/// lays it out today (`SkinHeroLayout.native`, `SkinDisplay.artworkRect`),
/// so moving the stage onto the plan cannot move Tier 1's verified
/// geometry. That sweep reads the installed SDK and skips without it; the
/// other tests use the skin layouts copied from the SDK
/// (`LogcatSdkApkFixtures`, `skins/`) and the fold's real `dumpsys display`
/// capture. Artwork pixel sizes outside the sweep are typed in, not read
/// from an image: generated input, apart from `wearos_rect`'s 434x508
/// (`SkinAvdRealFilesTests.testArtworkPartPlacementIsKept`).
final class DeviceCompositionTests: XCTestCase {
    private static let scales: [CGFloat] = [0.17, 0.283, 0.5, 1.0]

    private func layout(_ path: String) throws -> SkinDisplay {
        let file = try XCTUnwrap(SkinLayout.parseFile(at: LogcatSdkApkFixtures.url("skins").appendingPathComponent(path)))
        return try XCTUnwrap(file.preferred)
    }

    private func shapes() throws -> [DisplayShape] {
        DisplayShape.parse(dumpsysDisplay: try AdbCoreFixtureTests.text("shell-dumpsys-display.txt"))
    }

    // MARK: - Skin equivalence

    /// Every installed skin variant with a layout and a readable background,
    /// in each orientation it declares, at the compact window's 0.17, the
    /// Pixel 10 Pro's stage fit 0.283, 0.5 and 1: the placed frame, screen
    /// and artwork equal `SkinHeroLayout.native` and `artworkRect` × s
    /// within 1e-9.
    func testTheSkinPlanPlacesEveryInstalledSkinLikeTheStage() throws {
        guard let skins = SkinLocator.skinsDirectory() else {
            throw XCTSkip("no Android SDK skins directory")
        }
        let catalog = SkinResolver.catalog(skinsDirectory: skins)
        var checked = 0
        for entry in catalog {
            for variant in entry.variants {
                guard let file = variant.layout else { continue }
                for display in [file.portrait, file.landscape].compactMap({ $0 }) {
                    guard let background = display.backgroundImage,
                          let artwork = pixelSize(of: variant.directory.appendingPathComponent(background))
                    else { continue }
                    let plan = DeviceCompositionPlanner.skin(
                        display: display,
                        artworkPixelSize: artwork,
                        corner: ScreenCorner(radius: display.cornerRadius ?? 0, source: .declared),
                        backing: nil,
                        drawsLegacyMask: false,
                        hasOverlay: display.overlayImage != nil
                    )
                    let name = "\(entry.name)/\(variant.id) \(display.orientation)"
                    XCTAssertEqual(plan.layoutSize, display.layoutSize, name)
                    for scale in Self.scales {
                        let placed = plan.placed(pointsPerUnit: scale, pixelScale: 2)
                        let hero = SkinHeroLayout.native(display: display, scale: scale)
                        let frame = CGRect(origin: placed.layoutOrigin, size: placed.size)
                        assertRect(frame, hero.frame, accuracy: 1e-9, "\(name) frame at \(scale)")
                        assertRect(placed.screen, hero.screen, accuracy: 1e-9, "\(name) screen at \(scale)")
                        let rect = display.artworkRect(pixelSize: artwork)
                        assertRect(
                            try XCTUnwrap(placed.artworkFrame, name),
                            CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale),
                            accuracy: 1e-9,
                            "\(name) artwork at \(scale)"
                        )
                        XCTAssertEqual(placed.screenCornerRadius, (display.cornerRadius ?? 0) * scale, accuracy: 1e-9, name)
                        XCTAssertEqual(placed.clipRect, frame, name)
                        XCTAssertEqual(placed.bands, [], name)
                    }
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 50, "expected the full SDK skin set")
    }

    // MARK: - Placing a skin plan

    /// The fold cover (`pixel_9_pro_fold/closed`, 1236x2554 layout, display
    /// 1080x2424 at (94, 70)) with a backing: at 0.312 pt per unit on a 2x
    /// display the backing is the screen outset by 1 pt, its radius the
    /// backing's scaled plus 1 pt.
    func testTheBackingIsOutsetByTwoPixels() throws {
        let display = try layout("pixel_9_pro_fold/closed/layout")
        let glass = RGBA(red: 0.02, green: 0.02, blue: 0.02)
        let plan = DeviceCompositionPlanner.skin(
            display: display,
            artworkPixelSize: CGSize(width: 1236, height: 2554),
            corner: ScreenCorner(radius: 115, source: .device),
            backing: DeviceComposition.Backing(cornerRadius: 147.26, color: glass),
            drawsLegacyMask: false,
            hasOverlay: false
        )
        let placed = plan.placed(pointsPerUnit: 0.312, pixelScale: 2)
        assertRect(placed.screen, CGRect(x: 94 * 0.312, y: 70 * 0.312, width: 1080 * 0.312, height: 2424 * 0.312), accuracy: 1e-9)
        assertRect(try XCTUnwrap(placed.backingFrame), placed.screen.insetBy(dx: -1, dy: -1), accuracy: 1e-9)
        XCTAssertEqual(placed.backingRadius, 147.26 * 0.312 + 1, accuracy: 1e-9)
        XCTAssertEqual(placed.backingColor, glass)
        XCTAssertEqual(placed.screenCornerRadius, 115 * 0.312, accuracy: 1e-9)

        // On a 1x display the outset is a whole point.
        let oneX = plan.placed(pointsPerUnit: 0.312, pixelScale: 1)
        assertRect(try XCTUnwrap(oneX.backingFrame), oneX.screen.insetBy(dx: -2, dy: -2), accuracy: 1e-9)

        // Legacy skins have none.
        let legacy = DeviceCompositionPlanner.skin(
            display: try layout("nexus_one/layout"),
            artworkPixelSize: CGSize(width: 732, height: 1178),
            corner: ScreenCorner(radius: 0, source: .none),
            backing: nil,
            drawsLegacyMask: true,
            hasOverlay: true
        ).placed(pointsPerUnit: 0.5, pixelScale: 2)
        XCTAssertNil(legacy.backingFrame)
        XCTAssertNil(legacy.backingColor)
        XCTAssertEqual(legacy.backingRadius, 0)
    }

    /// The button pad widens the canvas on both sides, so the layout box
    /// stays centred, and extends the clip on the right only.
    func testTheButtonPadCentresTheLayoutAndClipsRightOnly() throws {
        let display = try layout("pixel_9_pro/layout")
        let plan = DeviceCompositionPlanner.skin(
            display: display,
            artworkPixelSize: display.layoutSize,
            corner: ScreenCorner(radius: 109, source: .declared),
            backing: nil,
            drawsLegacyMask: false,
            hasOverlay: false
        )
        let plain = plan.placed(pointsPerUnit: 0.25, pixelScale: 2)
        let padded = plan.placed(pointsPerUnit: 0.25, pixelScale: 2, buttonPad: 7)
        XCTAssertEqual(padded.size.width, plain.size.width + 14, accuracy: 1e-9)
        XCTAssertEqual(padded.size.height, plain.size.height)
        XCTAssertEqual(padded.layoutOrigin, CGPoint(x: 7, y: 0))
        assertRect(padded.screen, plain.screen.offsetBy(dx: 7, dy: 0), accuracy: 1e-9)
        assertRect(try XCTUnwrap(padded.artworkFrame), try XCTUnwrap(plain.artworkFrame).offsetBy(dx: 7, dy: 0), accuracy: 1e-9)
        assertRect(padded.clipRect, CGRect(x: 7, y: 0, width: plain.size.width + 7, height: plain.size.height), accuracy: 1e-9)
    }

    /// Artwork exported at another scale or placed off the layout origin:
    /// a rect of its pixels (a side button) lands where `artworkRect` puts
    /// them. On `pixel_9_pro` (1408x2974 layout) artwork a few pixels off
    /// the layout maps 1:1 and a 2x re-export halves (both sizes generated
    /// input); `wearos_rect` places its 434x508 artwork at (16, 16).
    func testArtworkPixelsMapIntoLayoutUnits() throws {
        let pro = try layout("pixel_9_pro/layout")
        let button = CGRect(x: 1399, y: 830, width: 10, height: 233)
        XCTAssertEqual(
            DeviceCompositionPlanner.layoutRect(artworkPixels: button, display: pro, artworkPixelSize: CGSize(width: 1410, height: 2968)),
            button
        )
        XCTAssertEqual(
            DeviceCompositionPlanner.layoutRect(artworkPixels: button, display: pro, artworkPixelSize: CGSize(width: 2816, height: 5948)),
            CGRect(x: 699.5, y: 415, width: 5, height: 116.5)
        )
        let wear = try layout("wearos_rect/layout")
        XCTAssertEqual(
            DeviceCompositionPlanner.layoutRect(artworkPixels: CGRect(x: 0, y: 0, width: 10, height: 10), display: wear, artworkPixelSize: CGSize(width: 434, height: 508)),
            CGRect(x: 16, y: 16, width: 10, height: 10)
        )
    }

    /// The plan carries a skin's side buttons in layout units: on
    /// `pixel_9_pro` (1408x2974 layout) artwork a few pixels off the layout
    /// keeps them 1:1 and a 2x re-export halves them, `baseline` and `depth`
    /// untouched; a vector body has none. The button rows are the
    /// `pixel_10_pro` scan's power bulge, the sizes generated input.
    func testTheSkinPlanCarriesItsButtonsInLayoutUnits() throws {
        let display = try layout("pixel_9_pro/layout")
        let power = SkinHardwareButton(
            key: .power,
            group: 0,
            rect: CGRect(x: 1400, y: 830, width: 10, height: 233),
            baseline: 1399,
            depth: 10
        )
        func plan(_ artwork: CGSize) -> DeviceComposition {
            DeviceCompositionPlanner.skin(
                display: display,
                artworkPixelSize: artwork,
                corner: ScreenCorner(radius: 109, source: .declared),
                backing: nil,
                drawsLegacyMask: false,
                hasOverlay: false,
                buttons: [power]
            )
        }
        XCTAssertEqual(plan(CGSize(width: 1410, height: 2968)).buttons, [power])

        let halved = try XCTUnwrap(plan(CGSize(width: 2816, height: 5948)).buttons.first)
        XCTAssertEqual(halved.rect, CGRect(x: 700, y: 415, width: 5, height: 116.5))
        XCTAssertEqual(halved.key, .power)
        XCTAssertEqual(halved.baseline, 1399)
        XCTAssertEqual(halved.depth, 10)

        XCTAssertNotEqual(plan(display.layoutSize), DeviceCompositionPlanner.skin(
            display: display,
            artworkPixelSize: display.layoutSize,
            corner: ScreenCorner(radius: 109, source: .declared),
            backing: nil,
            drawsLegacyMask: false,
            hasOverlay: false
        ))
        let vector = DeviceCompositionPlanner.vector(
            screen: CGSize(width: 1080, height: 2424),
            displays: try shapes(),
            fallbackDensityDpi: nil,
            quarterTurns: 0
        )
        XCTAssertEqual(vector.buttons, [])
    }

    // MARK: - The video and its cutout

    /// The stream is aspect-fit and centred in the screen: the cover's
    /// 1080x2416 scrcpy frame leaves 8 px of 2424 at 1:1, 4 above and 4
    /// below; an empty stream takes the whole screen.
    func testTheVideoIsAspectFitAndCentred() throws {
        let plan = DeviceCompositionPlanner.vector(
            screen: CGSize(width: 1080, height: 2424),
            displays: try shapes(),
            fallbackDensityDpi: nil,
            quarterTurns: 0
        )
        let placed = plan.placed(pointsPerUnit: 1, pixelScale: 1)
        let video = placed.videoRect(stream: CGSize(width: 1080, height: 2416))
        assertRect(video, CGRect(x: placed.screen.minX, y: placed.screen.minY + 4, width: 1080, height: 2416), accuracy: 1e-9)
        XCTAssertEqual(placed.videoRect(stream: .zero), placed.screen)

        let half = plan.placed(pointsPerUnit: 0.5, pixelScale: 2)
        let halfVideo = half.videoRect(stream: CGSize(width: 1080, height: 2424))
        assertRect(halfVideo, half.screen, accuracy: 1e-9)
    }

    /// The cutout comes back in the video view's own coordinates: at half
    /// size the cover's hole (centre (540, 86), r 41.5) is at (270, 43),
    /// r 20.75, whatever the view's position in the body.
    func testTheCutoutIsInTheVideoViewsOwnCoordinates() throws {
        let plan = DeviceCompositionPlanner.vector(
            screen: CGSize(width: 1080, height: 2424),
            displays: try shapes(),
            fallbackDensityDpi: nil,
            quarterTurns: 0
        )
        let placed = plan.placed(pointsPerUnit: 0.5, pixelScale: 2, buttonPad: 7)
        let video = placed.videoRect(stream: CGSize(width: 1080, height: 2424))
        let box = try XCTUnwrap(placed.cutoutPath(inVideoRect: video)).boundingBoxOfPath
        assertRect(box, CGRect(x: 270 - 20.75, y: 43 - 20.75, width: 41.5, height: 41.5), accuracy: 1e-9)

        let square = DeviceCompositionPlanner.vector(
            screen: CGSize(width: 1080, height: 2424),
            displays: [],
            fallbackDensityDpi: 390,
            quarterTurns: 0
        ).placed(pointsPerUnit: 0.5, pixelScale: 2)
        XCTAssertNil(square.cutoutPath(inVideoRect: video))
    }

    /// The plan is a value: equal inputs give equal, equally hashed plans
    /// (hero caches key on it), and any change tells them apart.
    func testPlansCompareAndHashByValue() throws {
        let shapes = try shapes()
        func plan(_ turns: Int?) -> DeviceComposition {
            DeviceCompositionPlanner.vector(
                screen: CGSize(width: 2076, height: 2152),
                displays: shapes,
                fallbackDensityDpi: nil,
                quarterTurns: turns
            )
        }
        XCTAssertEqual(plan(0), plan(0))
        XCTAssertEqual(plan(0).hashValue, plan(0).hashValue)
        XCTAssertEqual(plan(nil), plan(0))
        XCTAssertNotEqual(plan(0), plan(2))
        XCTAssertEqual(Set([plan(0), plan(0), plan(2)]).count, 2)
    }

    // MARK: - Helpers

    /// The image's pixel size from its header, without a decode.
    private func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
        else { return nil }
        return CGSize(width: width, height: height)
    }

    private func assertRect(
        _ actual: CGRect,
        _ expected: CGRect,
        accuracy: CGFloat,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, "minX \(message)", file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, "minY \(message)", file: file, line: line)
        XCTAssertEqual(actual.maxX, expected.maxX, accuracy: accuracy, "maxX \(message)", file: file, line: line)
        XCTAssertEqual(actual.maxY, expected.maxY, accuracy: accuracy, "maxY \(message)", file: file, line: line)
    }
}
