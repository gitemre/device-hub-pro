import CoreGraphics
import XCTest
@testable import DeviceHubProKit

/// `DeviceCompositionPlanner.vector` on real data: the displays are the API
/// 37 Pixel 9 Pro Fold emulator's `dumpsys display` capture
/// (`Fixtures/api37-emulator/adb-core/shell-dumpsys-display.txt`): the inner
/// panel 2076x2152, radius 85, the cover 1080x2424, radius 115, both at
/// `390.0 x 390.0 dpi` and `density 390`. The stopped AVD is its
/// `config.ini` (`logcat-sdk-apk/avd/Pixel_9_Pro_Fold.avd`).
///
/// Expected numbers are worked by hand from `ChromeSpec.standard`: 390 dpi
/// is 390 / 25.4 = 15.35433 px per mm, so the inner screen's 4.3 mm bezel is
/// 66.024 px and the cover's 3.3 mm one 50.669 px; the 0.166 mm rim and
/// highlight are 2.549 px and the 0.663 mm frame 10.180 px, so the glass
/// starts 15.278 px in.
final class ChromeGeometryTests: XCTestCase {
    private static let inner = CGSize(width: 2076, height: 2152)
    private static let cover = CGSize(width: 1080, height: 2424)
    private struct NotAVectorBody: Error {}

    private func shapes() throws -> [DisplayShape] {
        let shapes = DisplayShape.parse(dumpsysDisplay: try AdbCoreFixtureTests.text("shell-dumpsys-display.txt"))
        XCTAssertEqual(shapes.map(\.naturalSize), [Self.inner, Self.cover])
        return shapes
    }

    private func vectorBody(_ plan: DeviceComposition, file: StaticString = #filePath, line: UInt = #line) throws -> DeviceComposition.VectorBody {
        guard case let .vector(body) = plan.body else {
            XCTFail("not a vector body", file: file, line: line)
            throw NotAVectorBody()
        }
        return body
    }

    // MARK: - The fold's two panels

    /// The inner screen: a foldable's (the cover is a smaller built-in
    /// panel), 4.3 mm of body around the device's own 85 px corner.
    func testTheFoldInnerScreensBody() throws {
        let plan = DeviceCompositionPlanner.vector(
            screen: Self.inner,
            displays: try shapes(),
            fallbackDensityDpi: nil,
            quarterTurns: 0
        )
        let body = try vectorBody(plan)
        XCTAssertEqual(body.family, .foldableInner)
        XCTAssertEqual(body.bezel, 66.024, accuracy: 0.01)
        XCTAssertEqual(plan.layoutSize.width, 2208.047, accuracy: 0.01)
        XCTAssertEqual(plan.layoutSize.height, 2284.047, accuracy: 0.01)
        XCTAssertEqual(plan.screenRect.minX, 66.024, accuracy: 0.01)
        XCTAssertEqual(plan.screenRect.minY, 66.024, accuracy: 0.01)
        XCTAssertEqual(plan.screenRect.size, Self.inner)
        XCTAssertEqual(plan.screenCorner, ScreenCorner(radius: 85, source: .device))
        XCTAssertEqual(body.outerRadius, 151.024, accuracy: 0.01)
        XCTAssertEqual(body.bandWidths.count, 3)
        XCTAssertEqual(body.bandWidths[0], 2.549, accuracy: 0.01)
        XCTAssertEqual(body.bandWidths[1], 2.549, accuracy: 0.01)
        XCTAssertEqual(body.bandWidths[2], 10.180, accuracy: 0.01)
        XCTAssertEqual(body.bandWidths.reduce(0, +), 15.278, accuracy: 0.01)
        XCTAssertEqual(body.bandColors, ChromeSpec.standard(.foldableInner).bands.map(\.color))
        XCTAssertEqual(body.glass, ChromeSpec.standard(.foldableInner).glass)
        XCTAssertEqual(plan.cutout?.quarterTurns, 0)
        XCTAssertEqual(plan.cutout?.naturalSize, Self.inner)
    }

    /// The cover: a phone (443 dp wide), 3.3 mm of body around 115 px.
    func testTheFoldCoverScreensBody() throws {
        let plan = DeviceCompositionPlanner.vector(
            screen: Self.cover,
            displays: try shapes(),
            fallbackDensityDpi: nil,
            quarterTurns: 0
        )
        let body = try vectorBody(plan)
        XCTAssertEqual(body.family, .phone)
        XCTAssertEqual(body.bezel, 50.669, accuracy: 0.01)
        XCTAssertEqual(plan.layoutSize.width, 1181.339, accuracy: 0.01)
        XCTAssertEqual(plan.layoutSize.height, 2525.339, accuracy: 0.01)
        XCTAssertEqual(plan.screenCorner, ScreenCorner(radius: 115, source: .device))
        XCTAssertEqual(body.outerRadius, 165.669, accuracy: 0.01)
        XCTAssertEqual(body.bandWidths.reduce(0, +), 15.278, accuracy: 0.01)
        XCTAssertEqual(plan.cutout?.cutout, try shapes()[1].cutout)
    }

    /// The bands are concentric rounded rects, outside-in, each drawn over
    /// the one before: rim, highlight, frame, then the glass. At 0.5 pt per
    /// px on a 2x display none is clamped.
    func testPlacedBandsAreConcentricOutsideIn() throws {
        let plan = DeviceCompositionPlanner.vector(
            screen: Self.inner,
            displays: try shapes(),
            fallbackDensityDpi: nil,
            quarterTurns: 0
        )
        let placed = plan.placed(pointsPerUnit: 0.5, pixelScale: 2)
        XCTAssertEqual(placed.size.width, 1104.024, accuracy: 0.01)
        XCTAssertEqual(placed.size.height, 1142.024, accuracy: 0.01)
        XCTAssertEqual(placed.bands.count, 4)
        let insets: [CGFloat] = [0, 1.274, 2.549, 7.639]
        let spec = ChromeSpec.standard(.foldableInner)
        for (band, inset) in zip(placed.bands, insets) {
            XCTAssertEqual(band.rect.minX, inset, accuracy: 0.01)
            XCTAssertEqual(band.rect.minY, inset, accuracy: 0.01)
            XCTAssertEqual(band.rect.maxX, placed.size.width - inset, accuracy: 0.01)
            XCTAssertEqual(band.rect.maxY, placed.size.height - inset, accuracy: 0.01)
            XCTAssertEqual(band.cornerRadius, 75.512 - inset, accuracy: 0.01)
        }
        XCTAssertEqual(placed.bands.map(\.color), spec.bands.map(\.color) + [spec.glass])
        XCTAssertEqual(placed.screen.minX, 33.012, accuracy: 0.01)
        XCTAssertEqual(placed.screen.width, 1038, accuracy: 1e-9)
        XCTAssertEqual(placed.screenCornerRadius, 42.5, accuracy: 1e-9)
        XCTAssertNil(placed.artworkFrame)
        XCTAssertNil(placed.backingFrame)
        XCTAssertEqual(placed.backingRadius, 0)
        XCTAssertEqual(placed.clipRect, CGRect(origin: .zero, size: placed.size))
    }

    /// At 0.17 pt per px (the compact window) on a 2x display the 2.549 px
    /// rim and highlight would be 0.433 pt, under one pixel: each is held at
    /// 0.5 pt, so the frame starts 1.0 pt in and the glass 1.0 + 1.731 pt.
    func testThinBandsAreHeldAtOnePixel() throws {
        let plan = DeviceCompositionPlanner.vector(
            screen: Self.inner,
            displays: try shapes(),
            fallbackDensityDpi: nil,
            quarterTurns: 0
        )
        let placed = plan.placed(pointsPerUnit: 0.17, pixelScale: 2)
        let insets = placed.bands.map(\.rect.minX)
        XCTAssertEqual(insets.count, 4)
        XCTAssertEqual(insets[0], 0, accuracy: 1e-9)
        XCTAssertEqual(insets[1] - insets[0], 0.5, accuracy: 1e-9, "rim")
        XCTAssertEqual(insets[2] - insets[1], 0.5, accuracy: 1e-9, "highlight")
        XCTAssertEqual(insets[3] - insets[2], 10.180 * 0.17, accuracy: 0.01, "frame")
        // On a 1x display the same rim is held at a whole point.
        let oneX = plan.placed(pointsPerUnit: 0.17, pixelScale: 1)
        XCTAssertEqual(oneX.bands[1].rect.minX, 1, accuracy: 1e-9)
        // The plan keeps the spec's widths; only the placement holds them.
        XCTAssertEqual(try vectorBody(plan).bandWidths[0], 2.549, accuracy: 0.01)
    }

    /// A screen shown smaller than the panel (a downscaled stream) keeps the
    /// body in proportion: at half size the bezel, radius and bands halve.
    func testAHalfSizeStreamHalvesTheBody() throws {
        let plan = DeviceCompositionPlanner.vector(
            screen: CGSize(width: 1038, height: 1076),
            displays: try shapes(),
            fallbackDensityDpi: nil,
            quarterTurns: 0
        )
        let body = try vectorBody(plan)
        XCTAssertEqual(body.family, .foldableInner)
        XCTAssertEqual(body.bezel, 33.012, accuracy: 0.01)
        XCTAssertEqual(plan.screenCorner.radius, 42.5, accuracy: 1e-9)
        XCTAssertEqual(body.outerRadius, 75.512, accuracy: 0.01)
        XCTAssertEqual(body.bandWidths[2], 5.090, accuracy: 0.01)
    }

    // MARK: - Without device data

    /// No shapes: a square screen corner (truthful to
    /// "real corners") and no cutout; the body still follows the AVD's
    /// density and hinge.
    func testNoShapesGiveASquareCornerAndNoCutout() throws {
        let plan = DeviceCompositionPlanner.vector(
            screen: Self.inner,
            displays: [],
            fallbackDensityDpi: 390,
            hingeCount: 1,
            quarterTurns: 0
        )
        XCTAssertEqual(plan.screenCorner, ScreenCorner(radius: 0, source: .none))
        XCTAssertNil(plan.cutout)
        let body = try vectorBody(plan)
        XCTAssertEqual(body.family, .foldableInner)
        XCTAssertEqual(body.bezel, 66.024, accuracy: 0.01)
        XCTAssertEqual(body.outerRadius, 66.024, accuracy: 0.01)
    }

    /// A panel that reports no rounded corners (before API 31): square,
    /// and the cutout it does report is still placed.
    func testAPanelWithoutRoundedCornersIsSquare() throws {
        var inner = try shapes()[0]
        inner.topLeft = nil
        inner.topRight = nil
        inner.bottomRight = nil
        inner.bottomLeft = nil
        let plan = DeviceCompositionPlanner.vector(
            screen: Self.inner,
            displays: [inner],
            fallbackDensityDpi: nil,
            quarterTurns: 0
        )
        XCTAssertEqual(plan.screenCorner, ScreenCorner(radius: 0, source: .none))
        XCTAssertNotNil(plan.cutout)
    }

    /// A stopped AVD's body comes from its `config.ini` alone:
    /// `hw.lcd.width`/`height` 2076x2152, `hw.lcd.density` 390 and
    /// `hw.sensor.hinge.count` 1 give the inner screen's foldable body with
    /// a square corner; with the shapes the AVD last reported, its 85 px one.
    func testTheStoppedFoldsPlanFromItsConfig() throws {
        let home = LogcatSdkApkFixtures.url("avd")
        let size = try XCTUnwrap(AvdConfig.lcdSize(avdName: "Pixel_9_Pro_Fold", avdHome: home))
        let density = try XCTUnwrap(AvdConfig.lcdDensity(avdName: "Pixel_9_Pro_Fold", avdHome: home))
        let hinges = AvdConfig.hingeCount(avdName: "Pixel_9_Pro_Fold", avdHome: home)
        XCTAssertEqual(size, Self.inner)
        XCTAssertEqual(density, 390)
        XCTAssertEqual(hinges, 1)

        let bare = DeviceCompositionPlanner.vector(
            screen: size,
            displays: [],
            fallbackDensityDpi: density,
            hingeCount: hinges,
            quarterTurns: nil
        )
        XCTAssertEqual(try vectorBody(bare).family, .foldableInner)
        XCTAssertEqual(try vectorBody(bare).bezel, 66.024, accuracy: 0.01)
        XCTAssertEqual(bare.layoutSize.width, 2208.047, accuracy: 0.01)
        XCTAssertEqual(bare.layoutSize.height, 2284.047, accuracy: 0.01)
        XCTAssertEqual(bare.screenCorner, ScreenCorner(radius: 0, source: .none))
        XCTAssertNil(bare.cutout)

        let stored = DeviceCompositionPlanner.vector(
            screen: size,
            displays: try shapes(),
            fallbackDensityDpi: density,
            hingeCount: hinges,
            quarterTurns: nil
        )
        XCTAssertEqual(try vectorBody(stored).family, .foldableInner)
        XCTAssertEqual(try vectorBody(stored).bezel, 66.024, accuracy: 0.01)
        XCTAssertEqual(stored.screenCorner, ScreenCorner(radius: 85, source: .device))
        XCTAssertEqual(try vectorBody(stored).outerRadius, 151.024, accuracy: 0.01)
        // Unknown turns, but the screen is in the panel's own orientation.
        XCTAssertEqual(stored.cutout?.quarterTurns, 0)
    }

    // MARK: - Density

    /// An `xDpi` outside 120…800 is a placeholder, not the panel's: the
    /// logical density stands in. The real inner panel with its `xDpi`
    /// edited (generated input, not device output) keeps the 390 dpi body.
    func testAnImplausibleXDpiFallsBackToTheDensity() throws {
        for xDpi in [0, 72, 1200.0] {
            var shapes = try shapes()
            shapes[0].xDpi = xDpi
            let plan = DeviceCompositionPlanner.vector(
                screen: Self.inner,
                displays: shapes,
                fallbackDensityDpi: 160,
                quarterTurns: 0
            )
            XCTAssertEqual(try vectorBody(plan).bezel, 66.024, accuracy: 0.01, "xDpi \(xDpi)")
        }
        XCTAssertEqual(DeviceCompositionPlanner.density(of: try shapes()[0], fallback: 160), 390)
    }

    /// Then the fallback (`wm density`, `hw.lcd.density`), then 420.
    func testTheDensityFallsBackInOrder() throws {
        var inner = try shapes()[0]
        inner.xDpi = nil
        XCTAssertEqual(DeviceCompositionPlanner.density(of: inner, fallback: 160), 390)
        inner.densityDpi = nil
        XCTAssertEqual(DeviceCompositionPlanner.density(of: inner, fallback: 160), 160)
        XCTAssertEqual(DeviceCompositionPlanner.density(of: inner, fallback: nil), 420)
        XCTAssertEqual(DeviceCompositionPlanner.density(of: nil, fallback: 0), 420)
        XCTAssertEqual(DeviceCompositionPlanner.density(of: nil, fallback: .nan), 420)
    }

    // MARK: - Family

    /// The inner panel is a foldable's only beside the smaller cover (or
    /// with a hinge); alone it is 2076 / 2.4375 = 852 dp wide, a tablet,
    /// with a 9.5 mm (145.9 px) bezel under the 9% bound (186.8 px).
    func testTheInnerPanelAloneReadsAsATablet() throws {
        let alone = DeviceCompositionPlanner.vector(
            screen: Self.inner,
            displays: [try shapes()[0]],
            fallbackDensityDpi: nil,
            quarterTurns: 0
        )
        XCTAssertEqual(try vectorBody(alone).family, .tablet)
        XCTAssertEqual(try vectorBody(alone).bezel, 145.866, accuracy: 0.01)

        let hinged = DeviceCompositionPlanner.vector(
            screen: Self.inner,
            displays: [try shapes()[0]],
            fallbackDensityDpi: nil,
            hingeCount: 1,
            quarterTurns: 0
        )
        XCTAssertEqual(try vectorBody(hinged).family, .foldableInner)
    }

    /// A hinge only makes a nearly square screen the inner one: the cover's
    /// 2.24 aspect stays a phone.
    func testAHingeDoesNotMakeTheCoverAFoldablesInnerScreen() throws {
        let plan = DeviceCompositionPlanner.vector(
            screen: Self.cover,
            displays: [],
            fallbackDensityDpi: 390,
            hingeCount: 1,
            quarterTurns: 0
        )
        XCTAssertEqual(try vectorBody(plan).family, .phone)
        XCTAssertEqual(try vectorBody(plan).bezel, 50.669, accuracy: 0.01)
    }

    /// A 2560x1600 screen at 320 dpi (generated input, not device output)
    /// is 800 dp wide: a tablet, 9.5 mm = 119.685 px of body.
    func testASixHundredDpScreenIsATablet() throws {
        let plan = DeviceCompositionPlanner.vector(
            screen: CGSize(width: 2560, height: 1600),
            displays: [],
            fallbackDensityDpi: 320,
            quarterTurns: nil
        )
        XCTAssertEqual(try vectorBody(plan).family, .tablet)
        XCTAssertEqual(try vectorBody(plan).bezel, 119.685, accuracy: 0.01)
    }

    /// The tablet line is Android's own `sw600dp`: the smallest width in dp
    /// at the panel's logical density (`density`), not at its measured
    /// `xDpi`, which only sizes the body in millimetres. The real panels,
    /// each alone and with `density` edited (generated input, not device
    /// output) so the two straddle 600 dp:
    /// - the cover at 280 is 1080 / 1.75 = 617 dp, a tablet (though 443 dp
    ///   at its 390 xDpi): 9.5 mm is 145.9 px at 390, held at 9% of 1080;
    /// - the inner panel at 560 is 2076 / 3.5 = 593 dp, a phone (though
    ///   852 dp at 390);
    /// - the cover at 420 is a phone whose 3.3 mm is 50.669 px at its
    ///   390 xDpi, not 54.567 at 420.
    func testTheTabletLineCountsDpAtTheLogicalDensity() throws {
        let fixture = try shapes()
        func plan(_ index: Int, density: Int) -> DeviceComposition {
            var panel = fixture[index]
            panel.densityDpi = density
            return DeviceCompositionPlanner.vector(
                screen: panel.naturalSize,
                displays: [panel],
                fallbackDensityDpi: nil,
                quarterTurns: 0
            )
        }
        let wideCover = try vectorBody(plan(1, density: 280))
        XCTAssertEqual(wideCover.family, .tablet)
        XCTAssertEqual(wideCover.bezel, 97.2, accuracy: 1e-9)

        XCTAssertEqual(try vectorBody(plan(0, density: 560)).family, .phone)

        let cover = try vectorBody(plan(1, density: 420))
        XCTAssertEqual(cover.family, .phone)
        XCTAssertEqual(cover.bezel, 50.669, accuracy: 0.01)
    }

    /// Without a logical density the fallback (`wm density`,
    /// `hw.lcd.density`) counts the dp, then the measured dpi: the inner
    /// panel alone with its `density` removed (generated input) is 593 dp
    /// at a fallback of 560, a phone, and 852 dp at its 390 xDpi, a tablet.
    func testTheLogicalDensityFallsBackInOrder() throws {
        var inner = try shapes()[0]
        inner.densityDpi = nil
        func family(fallback: Double?) throws -> DeviceFamily {
            try vectorBody(DeviceCompositionPlanner.vector(
                screen: Self.inner,
                displays: [inner],
                fallbackDensityDpi: fallback,
                quarterTurns: 0
            )).family
        }
        XCTAssertEqual(try family(fallback: 560), .phone)
        XCTAssertEqual(try family(fallback: nil), .tablet)

        let reported = try shapes()[0]
        XCTAssertEqual(DeviceCompositionPlanner.logicalDensity(of: reported, fallback: 560, physical: 100), 390)
        XCTAssertEqual(DeviceCompositionPlanner.logicalDensity(of: inner, fallback: 560, physical: 100), 560)
        XCTAssertEqual(DeviceCompositionPlanner.logicalDensity(of: inner, fallback: .nan, physical: 100), 100)
        XCTAssertEqual(DeviceCompositionPlanner.logicalDensity(of: nil, fallback: 0, physical: 100), 100)
    }

    // MARK: - Bezel bounds

    /// The bezel stays within 2.5–9% of the screen's short side (generated
    /// inputs, not device output): 3.3 mm at 800 dpi on a 400 px wide screen
    /// would be 103.9 px, held at 36; 9.5 mm at 120 dpi on a 2000 px wide
    /// one would be 44.9 px, held at 50.
    func testTheBezelIsHeldWithinItsBounds() throws {
        let dense = DeviceCompositionPlanner.vector(
            screen: CGSize(width: 400, height: 800),
            displays: [],
            fallbackDensityDpi: 800,
            quarterTurns: nil
        )
        XCTAssertEqual(try vectorBody(dense).family, .phone)
        XCTAssertEqual(try vectorBody(dense).bezel, 36, accuracy: 1e-9)
        XCTAssertEqual(dense.layoutSize, CGSize(width: 472, height: 872))

        let sparse = DeviceCompositionPlanner.vector(
            screen: CGSize(width: 2000, height: 3000),
            displays: [],
            fallbackDensityDpi: 120,
            quarterTurns: nil
        )
        XCTAssertEqual(try vectorBody(sparse).family, .tablet)
        XCTAssertEqual(try vectorBody(sparse).bezel, 50, accuracy: 1e-9)
    }

    /// An empty screen plans an empty device instead of trapping.
    func testAnEmptyScreenPlansNothing() throws {
        let plan = DeviceCompositionPlanner.vector(
            screen: .zero,
            displays: try shapes(),
            fallbackDensityDpi: nil,
            quarterTurns: 0
        )
        XCTAssertEqual(plan.layoutSize, .zero)
        XCTAssertEqual(plan.screenCorner, ScreenCorner(radius: 0, source: .none))
        XCTAssertNil(plan.cutout)
        let placed = plan.placed(pointsPerUnit: 1, pixelScale: 2)
        XCTAssertEqual(placed.size, .zero)
        XCTAssertTrue(placed.bands.allSatisfy { $0.cornerRadius == 0 })
    }
}
