import CoreGraphics
import XCTest
@testable import DeviceHubProKit

/// `DisplayShape` read from a real phone's `dumpsys display`: a
/// Xiaomi (`ro.product.model` 2209116AG, API 33), captured once over USB
/// (`Fixtures/physical-xiaomi/`, see its README for the trim). A single
/// built-in panel, 1080 x 2400, with four 102 px rounded corners and a
/// rectangular notch-style cutout at the top centre. Expected values are
/// spelled out from the dump's own text (and cross-checked against the
/// `boundingRect` the device prints beside the spec), never computed by the
/// parser under test.
final class PhysicalXiaomiDisplayShapeTests: XCTestCase {
    private static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/physical-xiaomi", isDirectory: true)
    private static let panelId = "local:4630946711218184577"

    private func text(_ name: String) throws -> String {
        try String(contentsOf: Self.directory.appendingPathComponent(name), encoding: .utf8)
    }

    private func shapes() throws -> [DisplayShape] {
        DisplayShape.parse(dumpsysDisplay: try text("shell-dumpsys-display.txt"))
    }

    /// The two `getprop` answers, byte-exact.
    func testTheCaptureIsTheXiaomiOnApi33() throws {
        XCTAssertEqual(try text("shell-getprop-ro.product.model.txt"), "2209116AG\n")
        XCTAssertEqual(try text("shell-getprop-ro.build.version.sdk.txt"), "33\n")
    }

    /// One display device (`Display Devices: size=1`): the built-in panel,
    /// named in the phone's locale, lit, with its density and dpi.
    func testOneBuiltInPanel() throws {
        let all = try shapes()
        XCTAssertEqual(all.count, 1)
        let panel = try XCTUnwrap(all.first)
        XCTAssertEqual(panel.uniqueId, Self.panelId)
        XCTAssertEqual(panel.name, "Yerleşik Ekran")
        XCTAssertEqual(panel.width, 1080)
        XCTAssertEqual(panel.height, 2400)
        XCTAssertEqual(panel.densityDpi, 440)
        XCTAssertEqual(try XCTUnwrap(panel.xDpi), 394.705, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(panel.yDpi), 394.307, accuracy: 1e-9)
        XCTAssertEqual(panel.type, "INTERNAL")
        XCTAssertEqual(panel.state, "ON")
        XCTAssertTrue(panel.isOn)
    }

    /// `roundedCorners RoundedCorners{[…]}`: all four corners are 102 px,
    /// centred 102 px in from each edge (1080 − 102 = 978, 2400 − 102 =
    /// 2298).
    func testFourRoundedCornersOf102Pixels() throws {
        let panel = try XCTUnwrap(shapes().first)
        XCTAssertEqual(panel.topLeft, .init(radius: 102, centerX: 102, centerY: 102))
        XCTAssertEqual(panel.topRight, .init(radius: 102, centerX: 978, centerY: 102))
        XCTAssertEqual(panel.bottomRight, .init(radius: 102, centerX: 978, centerY: 2298))
        XCTAssertEqual(panel.bottomLeft, .init(radius: 102, centerX: 102, centerY: 2298))
        XCTAssertEqual(panel.maxCornerRadius, 102)
    }

    /// The raw spec and its parser inputs: density 2.75 = 440 / 160, the
    /// full panel's size, no reduced-resolution mode.
    func testTheCutoutKeepsItsRawSpecAndInputs() throws {
        let panel = try XCTUnwrap(shapes().first)
        XCTAssertEqual(panel.cutout, DisplayShape.Cutout(
            spec: "M 0,0 H -37 V 93 H 37 V 0 H 0 Z",
            density: 2.75,
            physicalWidth: 1080,
            physicalHeight: 2400,
            physicalPixelDisplaySizeRatio: 1,
            scale: 1
        ))
    }

    /// The outline, by hand from `M 0,0 H -37 V 93 H 37 V 0 H 0 Z`: no
    /// `@left` marker, so the x origin is the panel's horizontal centre
    /// (1080 / 2 = 540); no `@bottom` (y from the top) and no `@dp`
    /// (pixels). The pen draws a 74 × 93 rectangle, x 540 ± 37 = 503…577,
    /// y 0…93, which is the `boundingRect` the device prints beside the
    /// spec (`Rect(503, 0 - 577, 93)`). A notch, not a punch hole: its
    /// corners are inside.
    func testTheCutoutIsATopCentreNotch() throws {
        let path = try XCTUnwrap(shapes().first?.cutoutPath)
        let box = path.boundingBoxOfPath
        XCTAssertEqual(box.minX, 503, accuracy: 1e-6)
        XCTAssertEqual(box.minY, 0, accuracy: 1e-6)
        XCTAssertEqual(box.maxX, 577, accuracy: 1e-6)
        XCTAssertEqual(box.maxY, 93, accuracy: 1e-6)
        XCTAssertTrue(path.contains(CGPoint(x: 540, y: 46.5)))
        XCTAssertTrue(path.contains(CGPoint(x: 504, y: 92)))
        XCTAssertFalse(path.contains(CGPoint(x: 502, y: 46.5)))
        XCTAssertFalse(path.contains(CGPoint(x: 540, y: 94)))
    }

    // MARK: - Landscape, in the vector plan (T2-CUTOUT, live check 6)

    /// The real Xiaomi's notch turned into the posed landscape frame a
    /// physical session's scrcpy stream arrives as: `DeviceCompositionPlanner
    /// .vector`, the plan `VectorDeviceView.composition` builds, at
    /// `quarterTurns` 1 (`ROTATION_90`, the phone's own left edge coming to
    /// the mirror's left) and 3 (`ROTATION_270`, the right edge), on a
    /// screen of the posed size (2400 x 1080, scrcpy's own multiple-of-8
    /// stream: 1080 and 2400 both already are).
    ///
    /// By hand from `M 0,0 H -37 V 93 H 37 V 0 H 0 Z` (natural bounds 503…577
    /// x, 0…93 y) through AOSP's `RotationUtils.rotateBounds` this file's
    /// header quotes: ROTATION_90 (x, y) → (y, 1080 − x) turns the natural
    /// bounds to x 0…93, y 503…577 (the screen's left edge, vertically
    /// centred); ROTATION_270 (2400 − y, x) turns them to x 2307…2400, y
    /// 503…577 (the right edge). At this screen size the natural-to-posed
    /// scale is exactly 1, so the turned bounds are the screen's own pixels.
    func testTheNotchTurnsToTheCorrectEdgeInLandscape() throws {
        let shapes = try shapes()
        let screen = CGSize(width: 2400, height: 1080)

        let left = DeviceCompositionPlanner.vector(screen: screen, displays: shapes, fallbackDensityDpi: nil, quarterTurns: 1)
        let leftBox = try XCTUnwrap(left.cutout).path(in: CGRect(origin: .zero, size: screen))
        let leftBounds = try XCTUnwrap(leftBox).boundingBoxOfPath
        XCTAssertEqual(leftBounds.minX, 0, accuracy: 1, "ROTATION_90: the left edge")
        XCTAssertEqual(leftBounds.maxX, 93, accuracy: 1)
        XCTAssertEqual(leftBounds.minY, 503, accuracy: 1)
        XCTAssertEqual(leftBounds.maxY, 577, accuracy: 1)

        let right = DeviceCompositionPlanner.vector(screen: screen, displays: shapes, fallbackDensityDpi: nil, quarterTurns: 3)
        let rightBox = try XCTUnwrap(right.cutout).path(in: CGRect(origin: .zero, size: screen))
        let rightBounds = try XCTUnwrap(rightBox).boundingBoxOfPath
        XCTAssertEqual(rightBounds.minX, 2307, accuracy: 1, "ROTATION_270: the right edge")
        XCTAssertEqual(rightBounds.maxX, 2400, accuracy: 1)
        XCTAssertEqual(rightBounds.minY, 503, accuracy: 1)
        XCTAssertEqual(rightBounds.maxY, 577, accuracy: 1)
    }

    /// The same turn, on a scrcpy-downscaled stream (sides rounded to a
    /// multiple of 8, as `DisplayShape.matching`'s own doc describes): the
    /// panel still matches within `aspectTolerance`, and the notch still
    /// lands on the correct short edge, scaled with the rest of the screen.
    func testTheNotchStillMatchesADownscaledLandscapeStream() throws {
        let shapes = try shapes()
        for screen in [CGSize(width: 1920, height: 864), CGSize(width: 2392, height: 1080)] {
            for turns in [1, 3] {
                let plan = DeviceCompositionPlanner.vector(screen: screen, displays: shapes, fallbackDensityDpi: nil, quarterTurns: turns)
                let cutout = try XCTUnwrap(plan.cutout, "screen \(screen), turns \(turns)")
                XCTAssertEqual(cutout.quarterTurns, turns)
                let box = try XCTUnwrap(cutout.path(in: CGRect(origin: .zero, size: screen))).boundingBoxOfPath
                let edgeX = turns == 1 ? box.minX : screen.width - box.maxX
                XCTAssertEqual(edgeX, 0, accuracy: 2, "screen \(screen), turns \(turns): the short edge")
            }
        }
    }
}
