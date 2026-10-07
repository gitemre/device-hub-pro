import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import DeviceHubProKit

final class DeviceFrameRendererTests: XCTestCase {
    // Fixture: the layout is 400x800 with the display at (20,20) 360x740;
    // the artwork is the same skin at 2x (800x1600), so the artwork-pixel
    // display rect is (40,40) 720x1480. The bottom margin is 80 px (not 40)
    // so a vertical flip cannot pass unnoticed, and the screenshot carries a
    // top band so a flipped composite fails the pixel probes.
    private static let artworkWidth = 800
    private static let artworkHeight = 1600
    private static let displayRect = CGRect(x: 40, y: 40, width: 720, height: 1480)

    private static let artworkRed = Pixel(red: 220, green: 30, blue: 30)
    private static let artworkBlue = Pixel(red: 20, green: 60, blue: 220)
    private static let screenshotGreen = Pixel(red: 0, green: 180, blue: 0)
    private static let screenshotMagenta = Pixel(red: 255, green: 0, blue: 255)
    private static let coverArtworkBorder = Pixel(red: 255, green: 0, blue: 128)
    private static let landscapeArtworkBorder = Pixel(red: 255, green: 140, blue: 0)

    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        super.tearDown()
    }

    // MARK: - Compositing

    func testComposeUsesTheArtworkAsTheCanvas() throws {
        let artwork = try writeArtwork()
        let screenshot = try bandedScreenshotPNG(
            width: 720,
            height: 1480,
            bandHeight: 120,
            band: Self.screenshotMagenta,
            fill: Self.screenshotGreen
        )

        let output = try DeviceFrameRenderer.compose(
            screenshot: screenshot,
            spec: DeviceFrameSpec(artwork: artwork, displayRect: Self.displayRect)
        )

        let image = try decode(output)
        XCTAssertEqual(image.width, Self.artworkWidth)
        XCTAssertEqual(image.height, Self.artworkHeight)
        // The frame margins keep the artwork's pixels.
        XCTAssertEqual(image.pixel(10, 10), Self.artworkRed)
        XCTAssertEqual(image.pixel(400, 10), Self.artworkRed)
        XCTAssertEqual(image.pixel(400, 1590), Self.artworkRed)
        XCTAssertEqual(image.pixel(790, 800), Self.artworkRed)
        // The display rect interior comes from the screenshot, top band first:
        // a vertically flipped composite would put the band at the bottom.
        XCTAssertEqual(image.pixel(400, 60), Self.screenshotMagenta)
        XCTAssertEqual(image.pixel(400, 200), Self.screenshotGreen)
        XCTAssertEqual(image.pixel(400, 1500), Self.screenshotGreen)
        // Below the top band, the display's bottom-left corner is screenshot.
        XCTAssertEqual(image.pixel(45, 300), Self.screenshotGreen)
    }

    // MARK: - Off the main actor

    /// The background variant must produce exactly what the synchronous
    /// composite produces; it only moves the work off the caller's actor.
    @MainActor
    func testComposeInBackgroundMatchesTheSynchronousComposite() async throws {
        let skin = try makeSkinFixture()
        let screenshot = try bandedScreenshotPNG(
            width: 720,
            height: 1480,
            bandHeight: 120,
            band: Self.screenshotMagenta,
            fill: Self.screenshotGreen
        )

        let background = try await DeviceFrameRenderer.composeInBackground(screenshot: screenshot, skin: skin)
        let synchronous = try DeviceFrameRenderer.compose(screenshot: screenshot, skin: skin)

        XCTAssertEqual(try decode(background).bytes, try decode(synchronous).bytes)
    }

    /// Resolving the AVD's skin (config.ini + layout reads) happens in the
    /// background task too; an AVD without a skin yields nil, not an error.
    @MainActor
    func testComposeInBackgroundResolvesTheAvdsSkin() async throws {
        let skin = try makeSkinFixture()
        try writeLayout(Self.fixtureLayout, in: skin.directory)
        let avdHome = try makeTemporaryDirectory()
        let content = avdHome.appendingPathComponent("Fixture.avd", isDirectory: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try "skin.path=\(skin.directory.path)\n".write(
            to: content.appendingPathComponent("config.ini"),
            atomically: true,
            encoding: .utf8
        )
        let screenshot = try solidPNG(width: 720, height: 1480, color: Self.screenshotGreen)

        let framed = try await DeviceFrameRenderer.composeInBackground(
            screenshot: screenshot,
            avdName: "Fixture",
            skinsDirectory: avdHome,
            avdHome: avdHome
        )
        let missing = try await DeviceFrameRenderer.composeInBackground(
            screenshot: screenshot,
            avdName: "NoSuchAvd",
            skinsDirectory: avdHome,
            avdHome: avdHome
        )

        let image = try decode(XCTUnwrap(framed))
        XCTAssertEqual(image.pixel(10, 10), Self.artworkRed)
        XCTAssertEqual(image.pixel(400, 800), Self.screenshotGreen)
        XCTAssertNil(missing)
    }

    /// Decoded artworks are cached, but an artwork replaced on disk must be
    /// decoded afresh rather than served stale.
    func testArtworkReplacedOnDiskIsNotServedFromTheCache() throws {
        let artwork = try writeArtwork()
        let spec = DeviceFrameSpec(artwork: artwork, displayRect: Self.displayRect)
        let screenshot = try solidPNG(width: 720, height: 1480, color: Self.screenshotGreen)
        XCTAssertEqual(try decode(DeviceFrameRenderer.compose(screenshot: screenshot, spec: spec)).pixel(10, 10), Self.artworkRed)

        try makePNG(width: Self.artworkWidth, height: Self.artworkHeight) { _, _ in Self.artworkBlue }
            .write(to: artwork)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: artwork.path
        )

        XCTAssertEqual(try decode(DeviceFrameRenderer.compose(screenshot: screenshot, spec: spec)).pixel(10, 10), Self.artworkBlue)
    }

    func testMismatchedScreenshotFillsAndCenterCropsTheDisplayRect() throws {
        let artwork = try writeArtwork()
        // A wide screenshot (1520x500) against the 720x1480 display: filling
        // the rect scales it up and crops the sides, so the display only ever
        // shows the screenshot's centre band — never the artwork's fill, which
        // an aspect-fit placement would leave exposed.
        let screenshot = try verticalBandsPNG(width: 1520, height: 500)

        let output = try DeviceFrameRenderer.compose(
            screenshot: screenshot,
            spec: DeviceFrameSpec(artwork: artwork, displayRect: Self.displayRect)
        )

        let image = try decode(output)
        XCTAssertEqual(image.pixel(45, 45), Self.screenshotGreen)
        XCTAssertEqual(image.pixel(755, 45), Self.screenshotGreen)
        XCTAssertEqual(image.pixel(45, 1515), Self.screenshotGreen)
        XCTAssertEqual(image.pixel(755, 1515), Self.screenshotGreen)
        XCTAssertEqual(image.pixel(400, 800), Self.screenshotGreen)
        // The frame itself is untouched.
        XCTAssertEqual(image.pixel(10, 10), Self.artworkRed)
    }

    func testCornerRadiusClipsTheScreenshotToRoundedCorners() throws {
        let artwork = try writeArtwork()
        let screenshot = try solidPNG(
            width: 720,
            height: 1480,
            color: Self.screenshotGreen
        )

        let output = try DeviceFrameRenderer.compose(
            screenshot: screenshot,
            spec: DeviceFrameSpec(
                artwork: artwork,
                displayRect: Self.displayRect,
                cornerRadius: 100
            )
        )

        let image = try decode(output)
        // The rounded corners expose the artwork's display-rect fill.
        XCTAssertEqual(image.pixel(42, 42), Self.artworkBlue)
        XCTAssertEqual(image.pixel(758, 42), Self.artworkBlue)
        XCTAssertEqual(image.pixel(42, 1518), Self.artworkBlue)
        XCTAssertEqual(image.pixel(758, 1518), Self.artworkBlue)
        // Away from the corners the screenshot is intact.
        XCTAssertEqual(image.pixel(400, 42), Self.screenshotGreen)
        XCTAssertEqual(image.pixel(42, 800), Self.screenshotGreen)
        XCTAssertEqual(image.pixel(400, 800), Self.screenshotGreen)
    }

    func testComposeClipsTheScreenshotToTheSkinsCornerRadius() throws {
        // The fixture skin declares `corner_radius 100` in layout pixels; the
        // artwork is 2x, so the clip must use 200 artwork px around each
        // display-rect corner (the same scale as the rect's x axis).
        let skin = try makeSkinFixture(layout: Self.corneredFixtureLayout)
        let screenshot = try solidPNG(width: 720, height: 1480, color: Self.screenshotGreen)

        let output = try DeviceFrameRenderer.compose(screenshot: screenshot, skin: skin)

        let image = try decode(output)
        // The corner cutouts expose the artwork's display-rect fill.
        XCTAssertEqual(image.pixel(42, 42), Self.artworkBlue)
        XCTAssertEqual(image.pixel(758, 42), Self.artworkBlue)
        XCTAssertEqual(image.pixel(42, 1518), Self.artworkBlue)
        XCTAssertEqual(image.pixel(758, 1518), Self.artworkBlue)
        // Between the corner arcs the screenshot reaches the rect's edge.
        XCTAssertEqual(image.pixel(400, 42), Self.screenshotGreen)
        XCTAssertEqual(image.pixel(42, 800), Self.screenshotGreen)
        XCTAssertEqual(image.pixel(400, 800), Self.screenshotGreen)
    }

    // MARK: - The device's screen corner

    /// The app clips a framed screenshot to the corner its live stage uses
    /// (`ScreenCornerPolicy`; here 21.25 layout units) instead of the skin's
    /// declared 100. The resolver is asked with the variant and display the
    /// capture is framed in and the capture's size, and its layout-unit
    /// radius is scaled to artwork pixels like the display rect.
    @MainActor
    func testTheResolversRadiusReplacesTheDeclaredOne() async throws {
        let skin = try makeSkinFixture(layout: Self.corneredFixtureLayout)
        try writeLayout(Self.corneredFixtureLayout, in: skin.directory)
        let avdHome = try makeTemporaryDirectory()
        let content = avdHome.appendingPathComponent("Fixture.avd", isDirectory: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try "skin.path=\(skin.directory.path)\n".write(
            to: content.appendingPathComponent("config.ini"),
            atomically: true,
            encoding: .utf8
        )
        let screenshot = try solidPNG(width: 720, height: 1480, color: Self.screenshotGreen)
        let asked = ResolverLog()

        let framed = try await DeviceFrameRenderer.composeInBackground(
            screenshot: screenshot,
            avdName: "Fixture",
            skinsDirectory: avdHome,
            avdHome: avdHome,
            screenCorner: { variant, display, frame in
                await asked.record(variant: variant.id, display: display.displaySize, frame: frame)
                return 21.25
            }
        )

        let calls = await asked.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.variant, "default")
        XCTAssertEqual(calls.first?.display, CGSize(width: 360, height: 740))
        XCTAssertEqual(calls.first?.frame, CGSize(width: 720, height: 1480))

        // 21.25 layout units → 42.5 artwork px around the display rect's
        // corner at (40, 40): 20 px in on the diagonal is inside that arc
        // (the declared 200 px arc would show the artwork there), 2 px in is
        // still outside it, so the corner is rounded, not square.
        let image = try decode(XCTUnwrap(framed))
        XCTAssertEqual(image.pixel(60, 60), Self.screenshotGreen)
        XCTAssertEqual(image.pixel(740, 1500), Self.screenshotGreen)
        XCTAssertEqual(image.pixel(42, 42), Self.artworkBlue)
        XCTAssertEqual(image.pixel(758, 1518), Self.artworkBlue)
    }

    /// A resolver without an answer keeps the skin's declared radius: the
    /// composite is the one without a resolver, byte for byte.
    @MainActor
    func testANilRadiusKeepsTheDeclaredOne() async throws {
        let skin = try makeSkinFixture(layout: Self.corneredFixtureLayout)
        let screenshot = try solidPNG(width: 720, height: 1480, color: Self.screenshotGreen)

        let resolved = try await DeviceFrameRenderer.composeInBackground(
            screenshot: screenshot,
            skin: skin,
            screenCorner: { _, _, _ in nil }
        )
        let declared = try DeviceFrameRenderer.compose(screenshot: screenshot, skin: skin)

        XCTAssertEqual(try decode(resolved).bytes, try decode(declared).bytes)
    }

    /// A foldable's cover capture asks about the cover display, the one its
    /// frame is drawn in.
    @MainActor
    func testTheResolverIsAskedAboutTheVariantTheCaptureMatches() async throws {
        let skin = try makeFoldableSkinFixture()
        let screenshot = try solidPNG(width: 200, height: 700, color: Self.screenshotGreen)
        let asked = ResolverLog()

        _ = try await DeviceFrameRenderer.composeInBackground(
            screenshot: screenshot,
            skin: skin,
            screenCorner: { variant, display, frame in
                await asked.record(variant: variant.id, display: display.displaySize, frame: frame)
                return 0
            }
        )

        let calls = await asked.calls
        XCTAssertEqual(calls.map(\.variant), ["closed"])
        XCTAssertEqual(calls.first?.display, CGSize(width: 200, height: 700))
        XCTAssertEqual(calls.first?.frame, CGSize(width: 200, height: 700))
    }

    /// A spec's radius past half the display rect is clamped, not handed to
    /// CoreGraphics, which traps on it.
    func testARadiusPastHalfTheRectIsClamped() throws {
        let artwork = try writeArtwork()
        let screenshot = try solidPNG(width: 720, height: 1480, color: Self.screenshotGreen)

        let output = try DeviceFrameRenderer.compose(
            screenshot: screenshot,
            spec: DeviceFrameSpec(artwork: artwork, displayRect: Self.displayRect, cornerRadius: 5_000)
        )

        let image = try decode(output)
        XCTAssertEqual(image.pixel(400, 800), Self.screenshotGreen)
        XCTAssertEqual(image.pixel(42, 42), Self.artworkBlue)
    }

    // MARK: - Skin resolution

    func testSpecResolvesThePreferredVariantScaledToArtworkPixels() throws {
        let skin = try makeSkinFixture()

        let spec = try XCTUnwrap(DeviceFrameRenderer.spec(for: skin))

        XCTAssertEqual(spec.artwork, skin.preferredVariant?.directory.appendingPathComponent("back.png"))
        XCTAssertEqual(spec.displayRect, Self.displayRect)
        XCTAssertNil(spec.cornerRadius)
    }

    func testSpecScalesTheSkinsCornerRadiusToArtworkPixels() throws {
        let skin = try makeSkinFixture(layout: Self.corneredFixtureLayout)

        let spec = try XCTUnwrap(DeviceFrameRenderer.spec(for: skin))

        // corner_radius 100 in layout pixels; the artwork is 2x → 200.
        XCTAssertEqual(spec.cornerRadius, 200)
    }

    func testComposeWithASkinMatchesTheResolvedSpec() throws {
        let skin = try makeSkinFixture()
        let screenshot = try bandedScreenshotPNG(
            width: 720,
            height: 1480,
            bandHeight: 120,
            band: Self.screenshotMagenta,
            fill: Self.screenshotGreen
        )

        let output = try DeviceFrameRenderer.compose(screenshot: screenshot, skin: skin)

        let image = try decode(output)
        XCTAssertEqual(image.width, Self.artworkWidth)
        XCTAssertEqual(image.height, Self.artworkHeight)
        XCTAssertEqual(image.pixel(400, 60), Self.screenshotMagenta)
        XCTAssertEqual(image.pixel(400, 1500), Self.screenshotGreen)
        XCTAssertEqual(image.pixel(10, 10), Self.artworkRed)
    }

    func testComposeWithAFoldableSkinPicksTheVariantMatchingTheScreenshot() throws {
        let skin = try makeFoldableSkinFixture()
        // A cover-sized screenshot (200x700) against the open (720x1480) and
        // cover (200x700) displays: the cover artwork must win.
        let screenshot = try solidPNG(width: 200, height: 700, color: Self.screenshotGreen)

        let output = try DeviceFrameRenderer.compose(screenshot: screenshot, skin: skin)

        let image = try decode(output)
        XCTAssertEqual(image.width, 400)
        XCTAssertEqual(image.height, 800)
        XCTAssertEqual(image.pixel(5, 5), Self.coverArtworkBorder)
        XCTAssertEqual(image.pixel(200, 400), Self.screenshotGreen)
        // `spec(for:)` keeps resolving the skin's preferred (open) variant.
        XCTAssertEqual(DeviceFrameRenderer.spec(for: skin)?.displayRect, Self.displayRect)
    }

    func testComposeUsesTheDisplayMatchingTheCaptureOrientation() throws {
        let skin = try makeDualOrientationSkinFixture()

        // A landscape capture must land in the landscape artwork's rect...
        let landscapeOutput = try DeviceFrameRenderer.compose(
            screenshot: try solidPNG(width: 740, height: 360, color: Self.screenshotGreen),
            skin: skin
        )
        let landscape = try decode(landscapeOutput)
        XCTAssertEqual(landscape.width, 1600)
        XCTAssertEqual(landscape.height, 800)
        XCTAssertEqual(landscape.pixel(5, 5), Self.landscapeArtworkBorder)
        XCTAssertEqual(landscape.pixel(800, 400), Self.screenshotGreen)

        // ...and a portrait capture in the portrait artwork's rect.
        let portraitOutput = try DeviceFrameRenderer.compose(
            screenshot: try solidPNG(width: 360, height: 740, color: Self.screenshotGreen),
            skin: skin
        )
        let portrait = try decode(portraitOutput)
        XCTAssertEqual(portrait.width, 800)
        XCTAssertEqual(portrait.height, 1600)
        XCTAssertEqual(portrait.pixel(5, 5), Self.artworkRed)
        XCTAssertEqual(portrait.pixel(400, 800), Self.screenshotGreen)
    }

    func testComposeThrowsWhenTheSkinHasNoDisplayForTheCaptureOrientation() throws {
        // A portrait-only modern phone skin has no correctly-oriented artwork
        // for a landscape capture, so the app keeps the raw shot.
        let skin = try makeSkinFixture()
        let screenshot = try solidPNG(width: 740, height: 360, color: Self.screenshotGreen)

        XCTAssertThrowsError(try DeviceFrameRenderer.compose(screenshot: screenshot, skin: skin)) { error in
            XCTAssertEqual(error as? DeviceFrameError, .artworkMissing)
        }
    }

    /// A skin with no display in the capture's pose is framed in its other
    /// display with the artwork turned by the capture's display rotation,
    /// the capture drawn as posed (its top band on top). The fixture's
    /// portrait display (40, 40) 720x1480 in the 800x1600 artwork, with an
    /// 80 px bottom margin: turned counter-clockwise (ROTATION_90) the
    /// canvas is 1600x800 and the display (40, 40) 1480x720, the wide
    /// margin on the right; clockwise (ROTATION_270) on the left. Without a
    /// turn, or with one that keeps the pose, it still throws. The capture
    /// is generated input.
    func testALandscapeCaptureIsFramedInTheTurnedPortraitArtwork() throws {
        let skin = try makeSkinFixture()
        let screenshot = try bandedScreenshotPNG(
            width: 1480,
            height: 720,
            bandHeight: 60,
            band: Self.screenshotMagenta,
            fill: Self.screenshotGreen
        )
        for (turns, displayMinX) in [(1, 40), (3, 80), (-1, 80), (5, 40)] {
            let context = "turns \(turns)"
            let image = try decode(DeviceFrameRenderer.compose(screenshot: screenshot, skin: skin, quarterTurns: turns))
            XCTAssertEqual(image.width, 1600, context)
            XCTAssertEqual(image.height, 800, context)
            // The display's edges: the artwork just outside, the capture
            // just inside.
            XCTAssertEqual(image.pixel(displayMinX - 2, 400), Self.artworkRed, "\(context): left of the display")
            XCTAssertEqual(image.pixel(displayMinX + 2, 400), Self.screenshotGreen, "\(context): the display's left edge")
            XCTAssertEqual(image.pixel(displayMinX + 1478, 400), Self.screenshotGreen, "\(context): its right edge")
            XCTAssertEqual(image.pixel(displayMinX + 1482, 400), Self.artworkRed, "\(context): right of it")
            XCTAssertEqual(image.pixel(800, 38), Self.artworkRed, "\(context): above it")
            XCTAssertEqual(image.pixel(800, 762), Self.artworkRed, "\(context): below it")
            // Posed as captured: the band along the top.
            XCTAssertEqual(image.pixel(800, 70), Self.screenshotMagenta, "\(context): the band on top")
            XCTAssertEqual(image.pixel(800, 740), Self.screenshotGreen, context)
        }
        for turns: Int? in [nil, 0, 2] {
            XCTAssertThrowsError(
                try DeviceFrameRenderer.compose(screenshot: screenshot, skin: skin, quarterTurns: turns),
                "turns \(String(describing: turns))"
            ) { error in
                XCTAssertEqual(error as? DeviceFrameError, .artworkMissing)
            }
        }
        // A capture in the display's own pose ignores the turn.
        let portrait = try decode(DeviceFrameRenderer.compose(
            screenshot: try solidPNG(width: 720, height: 1480, color: Self.screenshotGreen),
            skin: skin,
            quarterTurns: 1
        ))
        XCTAssertEqual(portrait.width, 800)
        XCTAssertEqual(portrait.height, 1600)
    }

    /// Tier 2 live check 4, bug 2: the open `pixel_9_pro_fold` at
    /// ROTATION_90 (a 2152x2076 capture) was saved raw. Framed now in the
    /// real skin's artwork turned counter-clockwise, as the stage shows it:
    /// 2274x2204, the frame pixel for pixel the portrait composite's
    /// turned (transparent outside the body, the side buttons along the
    /// top), and the inner panel's hole (1987.5, 80), r 39.5, turned with
    /// the capture to (80, 88.5) of the display at (62, 66). Reads the
    /// installed SDK skin and skips without it; the captures are generated
    /// input (solid images of the panel's two poses), the shapes the fold's
    /// real `dumpsys display`.
    @MainActor
    func testTheOpenFoldInLandscapeIsFramedInItsTurnedSkin() async throws {
        guard let skins = SkinLocator.skinsDirectory() else {
            throw XCTSkip("no Android SDK skins directory")
        }
        guard let entry = SkinResolver.catalog(skinsDirectory: skins).first(where: { $0.name == "pixel_9_pro_fold" }) else {
            throw XCTSkip("pixel_9_pro_fold is not installed")
        }
        let skin = ResolvedSkin(name: entry.name, directory: entry.directory, source: .skinName, variants: entry.variants)
        let inner = try foldShapes()[0]
        let landscape = try solidPNG(width: 2152, height: 2076, color: Self.screenshotGreen)
        let upright = try solidPNG(width: 2076, height: 2152, color: Self.screenshotGreen)

        // Without the rotation there is still nothing to frame it in.
        XCTAssertThrowsError(try DeviceFrameRenderer.compose(screenshot: landscape, skin: skin)) { error in
            XCTAssertEqual(error as? DeviceFrameError, .artworkMissing)
        }
        let turnedHole = try XCTUnwrap(CutoutPlacement(shape: inner, quarterTurns: 1))
        let turnedData = try await DeviceFrameRenderer.composeInBackground(
            screenshot: landscape,
            skin: skin,
            quarterTurns: 1,
            screenShape: { _, _, _ in (radius: nil, cutout: turnedHole) }
        )
        let portraitData = try await DeviceFrameRenderer.composeInBackground(
            screenshot: upright,
            skin: skin,
            screenShape: { _, _, _ in (radius: nil, cutout: nil) }
        )
        let image = try decode(turnedData)
        let portrait = try decode(portraitData)
        XCTAssertEqual(portrait.width, 2204)
        XCTAssertEqual(portrait.height, 2274)
        XCTAssertEqual(image.width, 2274)
        XCTAssertEqual(image.height, 2204)

        // The frame is the portrait one turned: portrait pixel (x, y) lands
        // on (y, 2203 - x), on a grid over the whole canvas outside the
        // screen (inside it the two captures differ only by the hole).
        let display = CGRect(x: 62, y: 62, width: 2076, height: 2152)
        var transparent = 0
        var compared = 0
        for x in stride(from: 0, to: 2204, by: 7) {
            for y in stride(from: 0, to: 2274, by: 7) where !display.insetBy(dx: -2, dy: -2).contains(CGPoint(x: x, y: y)) {
                let want = portrait.pixel(x, y)
                XCTAssertEqual(image.pixel(y, 2203 - x), want, "portrait (\(x), \(y))")
                if want.alpha == 0 { transparent += 1 }
                compared += 1
            }
        }
        XCTAssertGreaterThan(compared, 10_000)
        XCTAssertGreaterThan(transparent, 100, "transparent outside the body")
        XCTAssertEqual(image.pixel(0, 0).alpha, 0)
        // The side buttons: the portrait's right edge, now the top.
        var buttonRows = 0
        for x in stride(from: 0, to: 2274, by: 1) where image.pixel(x, 2).alpha == 255 { buttonRows += 1 }
        var rightColumn = 0
        for y in stride(from: 0, to: 2274, by: 1) where portrait.pixel(2201, y).alpha == 255 { rightColumn += 1 }
        XCTAssertGreaterThan(rightColumn, 0, "the portrait artwork's buttons reach its right edge")
        XCTAssertEqual(buttonRows, rightColumn, "the buttons along the top")

        // The capture, and the hole turned with it.
        XCTAssertEqual(image.pixel(1137, 1102), Self.screenshotGreen, "the screen's centre")
        XCTAssertEqual(image.pixel(62 + 80, 66 + 88), Pixel(red: 0, green: 0, blue: 0), "the turned hole")
        XCTAssertEqual(image.pixel(62 + 80, 66 + 88 + 60), Self.screenshotGreen, "below it")
    }

    func testComposeMatchesAFoldOpenDisplayByCapturePoseAcrossSections() throws {
        // `pixel_9_pro_fold`/`pixel_10_pro_fold` name their sole section
        // `landscape` while the open display is portrait-shaped (2076x2152).
        // A portrait capture must still composite into that display; a
        // landscape capture has no matching pose and, without the capture's
        // rotation to turn the artwork by, falls back.
        let skin = try makeFoldOpenSkinFixture()

        let portraitOutput = try DeviceFrameRenderer.compose(
            screenshot: try solidPNG(width: 360, height: 740, color: Self.screenshotGreen),
            skin: skin
        )
        let portrait = try decode(portraitOutput)
        XCTAssertEqual(portrait.width, 800)
        XCTAssertEqual(portrait.height, 1600)
        XCTAssertEqual(portrait.pixel(5, 5), Self.artworkRed)
        XCTAssertEqual(portrait.pixel(400, 800), Self.screenshotGreen)

        XCTAssertThrowsError(
            try DeviceFrameRenderer.compose(
                screenshot: try solidPNG(width: 740, height: 360, color: Self.screenshotGreen),
                skin: skin
            )
        ) { error in
            XCTAssertEqual(error as? DeviceFrameError, .artworkMissing)
        }
    }

    func testComposeThrowsForALegacyLandscapeSectionWithoutRotatedGeometry() throws {
        // Legacy landscape sections carry `rotation` metadata the layout
        // parser drops, leaving a portrait-shaped display inside a landscape
        // layout; compositing it would misplace the screen, so it falls back.
        let directory = try makeTemporaryDirectory()
        try artworkPNG().write(to: directory.appendingPathComponent("back.png"))
        let layout = SkinLayoutFile(
            portrait: SkinDisplay(
                displaySize: CGSize(width: 360, height: 740),
                origin: CGPoint(x: 20, y: 20),
                layoutSize: CGSize(width: 400, height: 800),
                backgroundImage: "back.png",
                maskImage: nil,
                orientation: .portrait
            ),
            landscape: SkinDisplay(
                displaySize: CGSize(width: 360, height: 740),
                origin: CGPoint(x: 200, y: 700),
                layoutSize: CGSize(width: 800, height: 400),
                backgroundImage: "back.png",
                maskImage: nil,
                orientation: .landscape
            )
        )
        let skin = ResolvedSkin(
            name: "Legacy",
            directory: directory,
            source: .skinPath,
            variants: [
                SkinVariant(id: "default", directory: directory, layout: layout)
            ]
        )
        let screenshot = try solidPNG(width: 740, height: 360, color: Self.screenshotGreen)

        XCTAssertThrowsError(try DeviceFrameRenderer.compose(screenshot: screenshot, skin: skin)) { error in
            XCTAssertEqual(error as? DeviceFrameError, .artworkMissing)
        }
    }

    func testComposeThrowsWhenTheSkinHasNoArtwork() throws {
        let directory = try makeTemporaryDirectory()
        let skin = ResolvedSkin(
            name: "No artwork",
            directory: directory,
            source: .skinName,
            variants: []
        )
        let screenshot = try solidPNG(width: 100, height: 200, color: Self.screenshotGreen)

        XCTAssertThrowsError(try DeviceFrameRenderer.compose(screenshot: screenshot, skin: skin)) { error in
            XCTAssertEqual(error as? DeviceFrameError, .artworkMissing)
        }
    }

    // MARK: - Real SDK skins

    /// `pixel_10_pro_fold/closed` ships a 1236x2495 frame for a 1236x2554
    /// layout. Stretched to the layout, its transparent opening ended ~57 px
    /// below the display rect and the framed shot showed a see-through
    /// strip there; drawn at its natural size (the emulator's rule) the
    /// opening sits on the display rect. Reads the installed SDK skin and
    /// skips without it.
    func testFoldCoverArtworkOpeningSitsOnTheDisplayRect() throws {
        guard let skins = SkinLocator.skinsDirectory() else {
            throw XCTSkip("no Android SDK skins directory")
        }
        let catalog = SkinResolver.catalog(skinsDirectory: skins)
        guard let fold = catalog.first(where: { $0.name == "pixel_10_pro_fold" }) else {
            throw XCTSkip("pixel_10_pro_fold is not installed")
        }
        let closed = try XCTUnwrap(fold.variants.first(where: { $0.id == "closed" }))
        let display = try XCTUnwrap(closed.layout?.preferred)
        let spec = try XCTUnwrap(DeviceFrameRenderer.spec(for: closed, display: display))
        XCTAssertEqual(spec.displayRect, CGRect(x: 84, y: 66, width: 1080, height: 2364))
        XCTAssertEqual(spec.cornerRadius, 75)

        // The opening's straight edges, walked out from the display's centre
        // along lines clear of the painted camera (top centre).
        let artwork = try decode(Data(contentsOf: spec.artwork))
        XCTAssertEqual(artwork.width, 1236)
        XCTAssertEqual(artwork.height, 2495)
        let rect = spec.displayRect
        let centre = (x: Int(rect.midX), y: Int(rect.midY))
        func opaque(_ x: Int, _ y: Int) -> Bool { artwork.pixel(x, y).alpha >= 128 }
        for fraction in [0.3, 0.7] {
            let row = Int(rect.minY + rect.height * fraction)
            let column = Int(rect.minX + rect.width * fraction)
            var left = centre.x
            while left > 0, !opaque(left - 1, row) { left -= 1 }
            var right = centre.x
            while right < artwork.width, !opaque(right, row) { right += 1 }
            var top = centre.y
            while top > 0, !opaque(column, top - 1) { top -= 1 }
            var bottom = centre.y
            while bottom < artwork.height, !opaque(column, bottom) { bottom += 1 }
            XCTAssertEqual(CGFloat(left), rect.minX, accuracy: 2, "left edge at \(fraction)")
            XCTAssertEqual(CGFloat(right), rect.maxX, accuracy: 2, "right edge at \(fraction)")
            XCTAssertEqual(CGFloat(top), rect.minY, accuracy: 2, "top edge at \(fraction)")
            XCTAssertEqual(CGFloat(bottom), rect.maxY, accuracy: 2, "bottom edge at \(fraction)")
        }

        // Composited: the screenshot runs to the display rect's bottom and
        // the bezel follows at once, with no see-through strip between.
        let screenshot = try solidPNG(width: 1080, height: 2364, color: Self.screenshotGreen)
        let image = try decode(DeviceFrameRenderer.compose(screenshot: screenshot, spec: spec))
        XCTAssertEqual(image.width, 1236)
        XCTAssertEqual(image.height, 2495)
        let column = Int(rect.minX + rect.width * 0.3)
        XCTAssertEqual(image.pixel(column, Int(rect.maxY) - 3), Self.screenshotGreen)
        for y in Int(rect.maxY) + 3..<Int(rect.maxY) + 60 {
            XCTAssertEqual(image.pixel(column, y).alpha, 255, "see-through bezel at y=\(y)")
            XCTAssertNotEqual(image.pixel(column, y), Self.screenshotGreen, "screenshot past the display at y=\(y)")
        }
    }

    // MARK: - The camera cutout

    /// The fold's real `dumpsys display` capture (API 37 Pixel 9 Pro Fold
    /// emulator): the inner panel 2076x2152, radius 85, a punch hole centred
    /// at (1987.5, 80), r 39.5; the cover 1080x2424, radius 115, the hole at
    /// (540, 86), r 41.5.
    private func foldShapes() throws -> [DisplayShape] {
        let shapes = DisplayShape.parse(dumpsysDisplay: try AdbCoreFixtureTests.text("shell-dumpsys-display.txt"))
        XCTAssertEqual(shapes.map(\.naturalSize), [CGSize(width: 2076, height: 2152), CGSize(width: 1080, height: 2424)])
        return shapes
    }

    /// A skin spec fills the device's cutout black over the shot, inside the
    /// display's clip. The artwork is generated input (not device output):
    /// its display rect is the fold cover's panel at half size, so the
    /// cover's hole lands at (30 + 270, 30 + 43), r 20.75.
    func testASkinSpecDrawsTheFoldCoversHole() throws {
        let directory = try makeTemporaryDirectory()
        let artwork = directory.appendingPathComponent("back.png")
        let display = CGRect(x: 30, y: 30, width: 540, height: 1212)
        try makePNG(width: 600, height: 1300) { x, y in
            display.contains(CGPoint(x: x, y: y)) ? Self.artworkBlue : Self.artworkRed
        }.write(to: artwork)
        let cover = try XCTUnwrap(CutoutPlacement(shape: try foldShapes()[1], quarterTurns: 0))
        let screenshot = try solidPNG(width: 1080, height: 2424, color: Self.screenshotGreen)

        let image = try decode(DeviceFrameRenderer.compose(
            screenshot: screenshot,
            spec: DeviceFrameSpec(artwork: artwork, displayRect: display, cornerRadius: 57.5, cutout: cover)
        ))

        XCTAssertEqual(image.pixel(300, 73), Pixel(red: 0, green: 0, blue: 0), "the hole's centre")
        XCTAssertEqual(image.pixel(300 - 18, 73), Pixel(red: 0, green: 0, blue: 0), "inside its 20.75 radius")
        XCTAssertEqual(image.pixel(300 - 24, 73), Self.screenshotGreen, "past it: the shot")
        XCTAssertEqual(image.pixel(300, 600), Self.screenshotGreen)
        XCTAssertEqual(image.pixel(10, 10), Self.artworkRed, "the frame is untouched")
        // Without a cutout nothing is drawn there.
        let plain = try decode(DeviceFrameRenderer.compose(
            screenshot: screenshot,
            spec: DeviceFrameSpec(artwork: artwork, displayRect: display, cornerRadius: 57.5)
        ))
        XCTAssertEqual(plain.pixel(300, 73), Self.screenshotGreen)
    }

    /// A shape resolver's cutout reaches the composite with its radius: the
    /// fixture skin's 720x1480 display fits the cover's panel at 0.6106
    /// (its long side), so the hole is centred at (369.7, 92.5), r 25.3.
    @MainActor
    func testTheShapeResolversCutoutIsDrawnWithItsRadius() async throws {
        let skin = try makeSkinFixture(layout: Self.corneredFixtureLayout)
        try writeLayout(Self.corneredFixtureLayout, in: skin.directory)
        let avdHome = try makeTemporaryDirectory()
        let content = avdHome.appendingPathComponent("Fixture.avd", isDirectory: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try "skin.path=\(skin.directory.path)\n".write(
            to: content.appendingPathComponent("config.ini"),
            atomically: true,
            encoding: .utf8
        )
        let cover = try XCTUnwrap(CutoutPlacement(shape: try foldShapes()[1], quarterTurns: 0))
        let screenshot = try solidPNG(width: 720, height: 1480, color: Self.screenshotGreen)
        let asked = ResolverLog()

        let framed = try await DeviceFrameRenderer.composeInBackground(
            screenshot: screenshot,
            avdName: "Fixture",
            skinsDirectory: avdHome,
            avdHome: avdHome,
            screenShape: { variant, display, frame in
                await asked.record(variant: variant.id, display: display.displaySize, frame: frame)
                return (radius: 21.25, cutout: cover)
            }
        )

        let calls = await asked.calls
        XCTAssertEqual(calls.map(\.frame), [CGSize(width: 720, height: 1480)])
        let image = try decode(XCTUnwrap(framed))
        XCTAssertEqual(image.pixel(370, 93), Pixel(red: 0, green: 0, blue: 0), "the hole")
        XCTAssertEqual(image.pixel(370 - 30, 93), Self.screenshotGreen)
        // The resolver's 21.25 corner (42.5 artwork px), not the declared 200.
        XCTAssertEqual(image.pixel(60, 60), Self.screenshotGreen)
        XCTAssertEqual(image.pixel(42, 42), Self.artworkBlue)
    }

    // MARK: - Vector bodies

    /// A capture framed in the vector body its device reports (the fold's
    /// inner panel; the capture is generated input, a solid 2076x2152
    /// image): the canvas is ceil(2208.047 x 2284.047), the hole is black at
    /// (66.024 + 1987.5, 66.024 + 80), the shot fills the screen and the
    /// canvas is transparent outside the body's 151.024 px corner.
    func testAVectorCompositeFramesTheCaptureInItsBody() throws {
        let plan = DeviceCompositionPlanner.vector(
            screen: CGSize(width: 2076, height: 2152),
            displays: try foldShapes(),
            fallbackDensityDpi: nil,
            quarterTurns: 0
        )
        let screenshot = try solidPNG(width: 2076, height: 2152, color: Self.screenshotGreen)

        let image = try decode(DeviceFrameRenderer.compose(screenshot: screenshot, composition: plan))

        XCTAssertEqual(image.width, 2209)
        XCTAssertEqual(image.height, 2285)
        XCTAssertEqual(image.pixel(2053, 146), Pixel(red: 0, green: 0, blue: 0), "the hole's centre")
        XCTAssertEqual(image.pixel(2053 - 45, 146), Self.screenshotGreen, "beside the hole")
        XCTAssertEqual(image.pixel(1104, 1142), Self.screenshotGreen, "the screen")
        XCTAssertEqual(image.pixel(0, 0).alpha, 0, "outside the body")
        XCTAssertEqual(image.pixel(2208, 0).alpha, 0)
        XCTAssertEqual(image.pixel(0, 2284).alpha, 0)
        XCTAssertEqual(image.pixel(40, 1142), Pixel(red: 1, green: 1, blue: 1), "the glass")
        XCTAssertEqual(image.pixel(66 + 5, 66 + 5), Pixel(red: 1, green: 1, blue: 1), "the screen's corner wedge")
    }

    /// A landscape capture of the inner panel shown a quarter turn round
    /// (`Surface.ROTATION_90`): the hole moves to (80, 88.5) of the turned
    /// 2152x2076 screen, after the same 66.024 px bezel.
    func testARotatedCapturePutsTheHoleWhereTheTurnTakesIt() throws {
        let plan = DeviceCompositionPlanner.vector(
            screen: CGSize(width: 2152, height: 2076),
            displays: try foldShapes(),
            fallbackDensityDpi: nil,
            quarterTurns: 1
        )
        let screenshot = try solidPNG(width: 2152, height: 2076, color: Self.screenshotGreen)

        let image = try decode(DeviceFrameRenderer.compose(screenshot: screenshot, composition: plan))

        XCTAssertEqual(image.width, 2285)
        XCTAssertEqual(image.height, 2209)
        let centre = (x: Int(66.024 + 80), y: Int(66.024 + 88.5))
        XCTAssertEqual(image.pixel(centre.x, centre.y), Pixel(red: 0, green: 0, blue: 0), "the hole's centre")
        XCTAssertEqual(image.pixel(centre.x, centre.y + 45), Self.screenshotGreen, "below the hole")
        // Where the upright hole would have been, the shot.
        XCTAssertEqual(image.pixel(2053, 146), Self.screenshotGreen)
    }

    /// The plan's screen rect is fractional (the cover's bezel is 50.669
    /// px), but the capture is drawn from a whole pixel, so a capture of the
    /// screen's own size comes through pixel for pixel: a one-pixel
    /// checkerboard (generated input) keeps every black and white pixel,
    /// where a fractional draw would blend them into greys.
    func testAVectorCompositeCopiesTheCapturePixelForPixel() throws {
        let plan = DeviceCompositionPlanner.vector(
            screen: CGSize(width: 1080, height: 2424),
            displays: try foldShapes(),
            fallbackDensityDpi: nil,
            quarterTurns: 0
        )
        XCTAssertEqual(plan.screenRect.minX, 50.669, accuracy: 0.01)
        let black = Pixel(red: 0, green: 0, blue: 0)
        let white = Pixel(red: 255, green: 255, blue: 255)
        let screenshot = try makePNG(width: 1080, height: 2424) { x, y in (x + y) % 2 == 0 ? black : white }

        let image = try decode(DeviceFrameRenderer.compose(screenshot: screenshot, composition: plan))

        for y in 1_000..<1_008 {
            for x in 200..<208 {
                XCTAssertEqual(image.pixel(51 + x, 51 + y), (x + y) % 2 == 0 ? black : white, "(\(x), \(y))")
            }
        }
    }

    /// A skin plan carries no artwork, and a capture that does not decode
    /// frames nothing; either throws, and the caller keeps the raw shot.
    func testAVectorCompositeThrowsForASkinPlanOrAnUndecodableShot() throws {
        let display = SkinDisplay(
            displaySize: CGSize(width: 360, height: 740),
            origin: CGPoint(x: 20, y: 20),
            layoutSize: CGSize(width: 400, height: 800),
            backgroundImage: "back.png",
            maskImage: nil,
            orientation: .portrait
        )
        let skin = DeviceCompositionPlanner.skin(
            display: display,
            artworkPixelSize: CGSize(width: 400, height: 800),
            corner: ScreenCorner(radius: 0, source: .none),
            backing: nil,
            drawsLegacyMask: false,
            hasOverlay: false
        )
        let screenshot = try solidPNG(width: 360, height: 740, color: Self.screenshotGreen)
        XCTAssertThrowsError(try DeviceFrameRenderer.compose(screenshot: screenshot, composition: skin)) { error in
            XCTAssertEqual(error as? DeviceFrameError, .artworkMissing)
        }
        let vector = DeviceCompositionPlanner.vector(
            screen: CGSize(width: 360, height: 740),
            displays: [],
            fallbackDensityDpi: nil,
            quarterTurns: nil
        )
        XCTAssertThrowsError(try DeviceFrameRenderer.compose(screenshot: Data("not a PNG".utf8), composition: vector)) { error in
            XCTAssertEqual(error as? DeviceFrameError, .imageDecodeFailed)
        }
        XCTAssertNil(DeviceFrameRenderer.pixelSize(ofScreenshot: Data("not a PNG".utf8)))
        XCTAssertEqual(DeviceFrameRenderer.pixelSize(ofScreenshot: screenshot), CGSize(width: 360, height: 740))
    }

    /// The background variant produces exactly the synchronous composite.
    @MainActor
    func testAVectorCompositeInBackgroundMatchesTheSynchronousOne() async throws {
        let plan = DeviceCompositionPlanner.vector(
            screen: CGSize(width: 1080, height: 2424),
            displays: try foldShapes(),
            fallbackDensityDpi: nil,
            quarterTurns: 0
        )
        let screenshot = try solidPNG(width: 1080, height: 2424, color: Self.screenshotGreen)
        let background = try await DeviceFrameRenderer.composeInBackground(screenshot: screenshot, composition: plan)
        let synchronous = try DeviceFrameRenderer.compose(screenshot: screenshot, composition: plan)
        XCTAssertEqual(try decode(background).bytes, try decode(synchronous).bytes)
    }

    // MARK: - Errors

    func testComposeThrowsOnAnUndecodableScreenshot() throws {
        let artwork = try writeArtwork()
        let spec = DeviceFrameSpec(artwork: artwork, displayRect: Self.displayRect)

        XCTAssertThrowsError(
            try DeviceFrameRenderer.compose(screenshot: Data("not a PNG".utf8), spec: spec)
        ) { error in
            XCTAssertEqual(error as? DeviceFrameError, .imageDecodeFailed)
        }
    }

    func testComposeThrowsOnUndecodableArtwork() throws {
        let directory = try makeTemporaryDirectory()
        let artwork = directory.appendingPathComponent("back.png")
        try Data("not an image".utf8).write(to: artwork)
        let screenshot = try solidPNG(width: 720, height: 1480, color: Self.screenshotGreen)

        XCTAssertThrowsError(
            try DeviceFrameRenderer.compose(
                screenshot: screenshot,
                spec: DeviceFrameSpec(artwork: artwork, displayRect: Self.displayRect)
            )
        ) { error in
            XCTAssertEqual(error as? DeviceFrameError, .artworkDecodeFailed)
        }
    }

    // MARK: - Fixtures

    private struct Pixel: Equatable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8

        init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }
    }

    private struct PixelImage {
        let width: Int
        let height: Int
        /// Premultiplied RGBA, row-major from the top row.
        let bytes: [UInt8]

        func pixel(_ x: Int, _ y: Int) -> Pixel {
            let offset = (y * width + x) * 4
            return Pixel(
                red: bytes[offset],
                green: bytes[offset + 1],
                blue: bytes[offset + 2],
                alpha: bytes[offset + 3]
            )
        }
    }

    private enum FixtureError: Error {
        case creationFailed
    }

    private static let coverDisplayRect = CGRect(x: 10, y: 10, width: 200, height: 700)
    private static let landscapeDisplayRect = CGRect(x: 40, y: 40, width: 1480, height: 720)

    /// The fixture layout, at half the artwork's pixel size.
    private static let fixtureLayout = """
    parts {
        device {
            display {
                width 360
                height 740
            }
        }
        back {
            background {
                image back.png
            }
        }
    }
    layouts {
        portrait {
            width 400
            height 800
            part1 {
                name back
                x 0
                y 0
            }
            part2 {
                name device
                x 20
                y 20
            }
        }
    }
    """

    /// The fixture layout with a display corner radius (100 layout px → 200
    /// artwork px at the artwork's 2x scale).
    private static let corneredFixtureLayout = """
    parts {
        device {
            display {
                width 360
                height 740
                corner_radius 100
            }
        }
        back {
            background {
                image back.png
            }
        }
    }
    layouts {
        portrait {
            width 400
            height 800
            part1 {
                name back
                x 0
                y 0
            }
            part2 {
                name device
                x 20
                y 20
            }
        }
    }
    """

    /// Foldable open state: the artwork is the 2x fixture (800x1600).
    private static let openVariantLayout = """
    parts {
        device {
            display {
                width 360
                height 740
            }
        }
        back {
            background {
                image back.png
            }
        }
    }
    layouts {
        landscape {
            width 400
            height 800
            part1 {
                name back
                x 0
                y 0
            }
            part2 {
                name device
                x 20
                y 20
            }
        }
    }
    """

    /// Foldable cover state: artwork and layout share the 400x800 size.
    private static let coverVariantLayout = """
    parts {
        device {
            display {
                width 200
                height 700
            }
        }
        back {
            background {
                image back.png
            }
        }
    }
    layouts {
        portrait {
            width 400
            height 800
            part1 {
                name back
                x 0
                y 0
            }
            part2 {
                name device
                x 10
                y 10
            }
        }
    }
    """

    private func makeSkinFixture(
        layout: String = DeviceFrameRendererTests.fixtureLayout
    ) throws -> ResolvedSkin {
        let directory = try makeTemporaryDirectory()
        try artworkPNG().write(to: directory.appendingPathComponent("back.png"))
        let variant = SkinVariant(
            id: "default",
            directory: directory,
            layout: SkinLayout.parse(layout)
        )
        return ResolvedSkin(
            name: "Fixture",
            directory: directory,
            source: .skinPath,
            variants: [variant]
        )
    }

    private func makeFoldableSkinFixture() throws -> ResolvedSkin {
        let root = try makeTemporaryDirectory()
        let openDirectory = root.appendingPathComponent("default", isDirectory: true)
        let coverDirectory = root.appendingPathComponent("closed", isDirectory: true)
        try FileManager.default.createDirectory(at: openDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: coverDirectory, withIntermediateDirectories: true)
        try artworkPNG().write(to: openDirectory.appendingPathComponent("back.png"))
        try coverArtworkPNG().write(to: coverDirectory.appendingPathComponent("back.png"))
        return ResolvedSkin(
            name: "Foldable",
            directory: root,
            source: .skinName,
            variants: [
                SkinVariant(
                    id: "default",
                    directory: openDirectory,
                    layout: SkinLayout.parse(Self.openVariantLayout)
                ),
                SkinVariant(
                    id: "closed",
                    directory: coverDirectory,
                    layout: SkinLayout.parse(Self.coverVariantLayout)
                ),
            ]
        )
    }

    /// A skin with both orientations: portrait 800x1600 artwork and landscape
    /// 1600x800 artwork, built from `SkinDisplay` values directly (the layout
    /// file format shares one device display across sections).
    private func makeDualOrientationSkinFixture() throws -> ResolvedSkin {
        let directory = try makeTemporaryDirectory()
        try artworkPNG().write(to: directory.appendingPathComponent("back_portrait.png"))
        try landscapeArtworkPNG().write(to: directory.appendingPathComponent("back_landscape.png"))
        let layout = SkinLayoutFile(
            portrait: SkinDisplay(
                displaySize: CGSize(width: 360, height: 740),
                origin: CGPoint(x: 20, y: 20),
                layoutSize: CGSize(width: 400, height: 800),
                backgroundImage: "back_portrait.png",
                maskImage: nil,
                orientation: .portrait
            ),
            landscape: SkinDisplay(
                displaySize: CGSize(width: 740, height: 360),
                origin: CGPoint(x: 20, y: 20),
                layoutSize: CGSize(width: 800, height: 400),
                backgroundImage: "back_landscape.png",
                maskImage: nil,
                orientation: .landscape
            )
        )
        return ResolvedSkin(
            name: "Dual",
            directory: directory,
            source: .skinPath,
            variants: [
                SkinVariant(id: "default", directory: directory, layout: layout)
            ]
        )
    }

    /// A fold-open skin whose sole section is named `landscape` while its
    /// display is portrait-shaped (the SDK's `pixel_*_pro_fold` default).
    private func makeFoldOpenSkinFixture() throws -> ResolvedSkin {
        let directory = try makeTemporaryDirectory()
        try artworkPNG().write(to: directory.appendingPathComponent("back.png"))
        let display = SkinDisplay(
            displaySize: CGSize(width: 360, height: 740),
            origin: CGPoint(x: 20, y: 20),
            layoutSize: CGSize(width: 400, height: 800),
            backgroundImage: "back.png",
            maskImage: nil,
            orientation: .landscape
        )
        return ResolvedSkin(
            name: "Fold open",
            directory: directory,
            source: .skinPath,
            variants: [
                SkinVariant(
                    id: "default",
                    directory: directory,
                    layout: SkinLayoutFile(portrait: nil, landscape: display)
                )
            ]
        )
    }

    /// Writes `layout` as the skin directory's `layout` file, so
    /// `SkinResolver` recognizes the directory on disk.
    private func writeLayout(_ layout: String, in directory: URL) throws {
        try layout.write(to: directory.appendingPathComponent("layout"), atomically: true, encoding: .utf8)
    }

    private func writeArtwork() throws -> URL {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("back.png")
        try artworkPNG().write(to: url)
        return url
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceFrameRendererTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func artworkPNG() throws -> Data {
        try makePNG(width: Self.artworkWidth, height: Self.artworkHeight) { x, y in
            let inside = x >= Int(Self.displayRect.minX)
                && x < Int(Self.displayRect.maxX)
                && y >= Int(Self.displayRect.minY)
                && y < Int(Self.displayRect.maxY)
            return inside ? Self.artworkBlue : Self.artworkRed
        }
    }

    private func coverArtworkPNG() throws -> Data {
        try makePNG(width: 400, height: 800) { x, y in
            let inside = x >= Int(Self.coverDisplayRect.minX)
                && x < Int(Self.coverDisplayRect.maxX)
                && y >= Int(Self.coverDisplayRect.minY)
                && y < Int(Self.coverDisplayRect.maxY)
            return inside ? Self.artworkBlue : Self.coverArtworkBorder
        }
    }

    private func landscapeArtworkPNG() throws -> Data {
        try makePNG(width: 1600, height: 800) { x, y in
            let inside = x >= Int(Self.landscapeDisplayRect.minX)
                && x < Int(Self.landscapeDisplayRect.maxX)
                && y >= Int(Self.landscapeDisplayRect.minY)
                && y < Int(Self.landscapeDisplayRect.maxY)
            return inside ? Self.artworkBlue : Self.landscapeArtworkBorder
        }
    }

    private func solidPNG(width: Int, height: Int, color: Pixel) throws -> Data {
        try makePNG(width: width, height: height) { _, _ in color }
    }

    private func bandedScreenshotPNG(
        width: Int,
        height: Int,
        bandHeight: Int,
        band: Pixel,
        fill: Pixel
    ) throws -> Data {
        try makePNG(width: width, height: height) { _, y in
            y < bandHeight ? band : fill
        }
    }

    /// Three vertical bands (red / green / blue): the centre-crop of a wide
    /// screenshot must only ever show the green middle band.
    private func verticalBandsPNG(width: Int, height: Int) throws -> Data {
        try makePNG(width: width, height: height) { x, _ in
            if x < width / 3 { return Pixel(red: 255, green: 0, blue: 0) }
            if x < 2 * width / 3 { return Self.screenshotGreen }
            return Pixel(red: 0, green: 0, blue: 255)
        }
    }

    private func makePNG(
        width: Int,
        height: Int,
        pixel: (Int, Int) -> Pixel
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
                let color = pixel(x, y)
                let offset = (y * width + x) * 4
                buffer[offset] = color.red
                buffer[offset + 1] = color.green
                buffer[offset + 2] = color.blue
                buffer[offset + 3] = color.alpha
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

/// What a `ScreenCornerResolver` was asked, in order.
private actor ResolverLog {
    struct Call {
        let variant: String
        let display: CGSize
        let frame: CGSize
    }

    private(set) var calls: [Call] = []

    func record(variant: String, display: CGSize, frame: CGSize) {
        calls.append(Call(variant: variant, display: display, frame: frame))
    }
}
