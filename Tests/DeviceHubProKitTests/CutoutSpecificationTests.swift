import CoreGraphics
import XCTest
@testable import DeviceHubProKit

/// The cutout-spec grammar (`CutoutSpecification`) and Android's path-data
/// parser (`AndroidPathParser`) beyond what the real capture exercises
/// (`DisplayShapeTests`).
///
/// SOURCE-DERIVED: the spec tests replay AOSP's own
/// `core/tests/coretests/src/android/view/CutoutSpecificationTest.java`
/// (`frameworks/base`, main) — its specs and the bound `Rect`s it expects,
/// which are the rounded control-point bounds of each kept cutout — since no
/// device at hand has a multi-cutout, `@dp` or `@bottom` spec. The path-data
/// tests pin Android's `PathParser` semantics (`libs/hwui/PathParser.cpp`,
/// `libs/hwui/utils/VectorDrawableUtils.cpp`) with values derived by hand in
/// each comment.
final class CutoutSpecificationTests: XCTestCase {
    /// `CutoutSpecificationTest.WITH_BIND_CUTOUT_SPECIFICATION`.
    private static let withBind = "M 0,0\nh 48\nv 48\nh -48\nz\n@left\n@center_vertical\n"
        + "M 0,0\nh 48\nv 48\nh -48\nz\n@left\n@bind_left_cutout\n@center_vertical\n"
        + "M 0,0\nh -48\nv 48\nh 48\nz\n@right\n@bind_right_cutout\n@bottom\n"
        + "M 0,0\nh -24\nv -48\nh 48\nv 48\nz\n@dp"

    /// `CutoutSpecificationTest.WITHOUT_BIND_CUTOUT_SPECIFICATION`.
    private static let withoutBind = "M 0,0\nh 48\nv 48\nh -48\nz\n@left\n@center_vertical\n"
        + "M 0,0\nh 48\nv 48\nh -48\nz\n@left\n@center_vertical\n"
        + "M 0,0\nh -48\nv 48\nh 48\nz\n@right\n@dp"

    /// The kept cutouts' edges and Android-rounded bounds (`RectF.round`
    /// over Skia's control-point `getBounds`).
    private func bounds(
        _ spec: String,
        density: CGFloat = 3.5,
        width: Int = 1080,
        height: Int = 1920
    ) throws -> [(CutoutSpecification.Edge, CGRect)] {
        let pieces = try XCTUnwrap(CutoutSpecification.pieces(spec: spec, density: density, width: width, height: height))
        return pieces.map { piece in
            let box = piece.path.boundingBox
            func round(_ value: CGFloat) -> CGFloat { (value + 0.5).rounded(.down) }
            let minX = round(box.minX), minY = round(box.minY)
            return (piece.edge, CGRect(x: minX, y: minY, width: round(box.maxX) - minX, height: round(box.maxY) - minY))
        }
    }

    private func rect(_ left: CGFloat, _ top: CGFloat, _ right: CGFloat, _ bottom: CGFloat) -> CGRect {
        CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    // MARK: - Spec grammar (SOURCE-DERIVED)

    /// `parse_withBindMarker_should{Left,Top,Right,Bottom}Bound`, Parser(3.5,
    /// 1080, 1920): 48 dp = 168 px squares at the top-left, left-centre,
    /// right-centre and bottom-centre.
    func testBindMarkersClaimTheirEdges() throws {
        let pieces = try bounds(Self.withBind)
        XCTAssertEqual(pieces.map { $0.0 }, [.top, .left, .right, .bottom])
        XCTAssertEqual(pieces.map { $0.1 }, [
            rect(0, 0, 168, 168),
            rect(0, 960, 168, 1128),
            rect(912, 960, 1080, 1128),
            rect(456, 1752, 624, 1920),
        ])
    }

    /// `parse_withBindMarker_tabletLikeDevice_*`, Parser(3.5, 1920, 1080).
    func testBindMarkersOnALandscapePanel() throws {
        let pieces = try bounds(Self.withBind, width: 1920, height: 1080)
        XCTAssertEqual(pieces.map { $0.0 }, [.top, .left, .right, .bottom])
        XCTAssertEqual(pieces.map { $0.1 }, [
            rect(0, 0, 168, 168),
            rect(0, 540, 168, 708),
            rect(1752, 540, 1920, 708),
            rect(876, 912, 1044, 1080),
        ])
    }

    /// `parse_withoutBindMarker_shouldHaveNo{Left,Right}Bound`: without a
    /// bind marker every cutout claims the top edge, and only the first is
    /// kept — the path holds that one square alone.
    func testUnboundCutoutsAfterTheFirstAreDropped() throws {
        let pieces = try bounds(Self.withoutBind)
        XCTAssertEqual(pieces.map { $0.0 }, [.top])
        XCTAssertEqual(pieces.map { $0.1 }, [rect(0, 0, 168, 168)])
        let path = try XCTUnwrap(CutoutSpecification.path(
            spec: Self.withoutBind, density: 3.5, physicalWidth: 1080, physicalHeight: 1920
        ))
        XCTAssertEqual(path.boundingBox, rect(0, 0, 168, 168))
    }

    /// `parse_{tall,wide,narrow}Cutout_*` and `parse_cornerCutout_*`: `@dp`
    /// scales by 3.5 around the default top-centre origin (or `@right`).
    func testDpCutoutsScaleByDensity() throws {
        let tall = try bounds("M 0,0\nL -48, 0\nL -44.3940446283, 36.0595537175\n"
            + "C -43.5582133885, 44.4178661152 -39.6, 48.0 -31.2, 48.0\nL 31.2, 48.0\n"
            + "C 39.6, 48.0 43.5582133885, 44.4178661152 44.3940446283, 36.0595537175\nL 48, 0\nZ\n@dp")
        XCTAssertEqual(tall.first?.1.height, 168)
        // Centred: 540 ± 48 dp × 3.5.
        XCTAssertEqual(tall.first?.1, rect(372, 0, 708, 168))

        let wide = try bounds("M 0,0\nL -72, 0\nL -69.9940446283, 20.0595537175\n"
            + "C -69.1582133885, 28.4178661152 -65.2, 32.0 -56.8, 32.0\nL 56.8, 32.0\n"
            + "C 65.2, 32.0 69.1582133885, 28.4178661152 69.9940446283, 20.0595537175\nL 72, 0\nZ\n@dp")
        XCTAssertEqual(wide.first?.1.width, 504)

        let narrow = try bounds("M 0,0\nL -24, 0\nL -21.9940446283, 20.0595537175\n"
            + "C -21.1582133885, 28.4178661152 -17.2, 32.0 -8.8, 32.0\nL 8.8, 32.0\n"
            + "C 17.2, 32.0 21.1582133885, 28.4178661152 21.9940446283, 20.0595537175\nL 24, 0\nZ\n@dp")
        XCTAssertEqual(narrow.first?.1.width, 168)

        let corner = try bounds("M 0,0\nL -48, 0\nC -48,48 -48,48 0,48\nZ\n@dp\n@right")
        XCTAssertEqual(corner.first?.1, rect(912, 0, 1080, 168))
    }

    /// `parse_doubleCutout_topBoundShouldHaveExpectedHeight`: `@bottom`
    /// ends the top cutout and anchors the next one at the bottom edge.
    func testBottomMarkerStartsABottomCutout() throws {
        let pieces = try bounds("M 0,0\nL -72, 0\nL -69.9940446283, 20.0595537175\n"
            + "C -69.1582133885, 28.4178661152 -65.2, 32.0 -56.8, 32.0\nL 56.8, 32.0\n"
            + "C 65.2, 32.0 69.1582133885, 28.4178661152 69.9940446283, 20.0595537175\nL 72, 0\nZ\n"
            + "@bottom\nM 0,0\nL -72, 0\nL -69.9940446283, -20.0595537175\n"
            + "C -69.1582133885, -28.4178661152 -65.2, -32.0 -56.8, -32.0\nL 56.8, -32.0\n"
            + "C 65.2, -32.0 69.1582133885, -28.4178661152 69.9940446283, -20.0595537175\nL 72, 0\nZ\n@dp")
        XCTAssertEqual(pieces.map { $0.0 }, [.top, .bottom])
        XCTAssertEqual(pieces[0].1.height, 112)
        XCTAssertEqual(pieces[1].1, rect(288, 1808, 792, 1920))
    }

    /// `parse_holeCutout_shouldMatchExpectedInset` (pixels, `@left`), and
    /// `parse_bottom{Left,Right}Spec_withBind*Marker_*` (Parser(2, 400, 200)).
    func testPixelSpecsAndBottomCorners() throws {
        XCTAssertEqual(try bounds("M 20.0,20.0\nh 136\nv 136\nh -136\nZ\n@left").first?.1, rect(20, 20, 156, 156))

        let bottomLeft = try bounds(
            "@bottomM 0,0\nv -10\nh 10\nv 10\nz\n@left\n@bind_left_cutout",
            density: 2, width: 400, height: 200
        )
        XCTAssertEqual(bottomLeft.map { $0.0 }, [.left])
        XCTAssertEqual(bottomLeft.first?.1, rect(0, 190, 10, 200))

        let bottomRight = try bounds(
            "@bottomM 0,0\nv -10\nh -10\nv 10\nz\n@right\n@bind_right_cutout",
            density: 2, width: 400, height: 200
        )
        XCTAssertEqual(bottomRight.map { $0.0 }, [.right])
        XCTAssertEqual(bottomRight.first?.1, rect(390, 190, 400, 200))
    }

    /// `parse_emptyString_pathShouldBeNull`; a spec whose path data Android
    /// rejects fails as a whole.
    func testEmptyOrInvalidSpecHasNoPath() {
        XCTAssertNil(CutoutSpecification.path(spec: "", density: 3.5, physicalWidth: 1080, physicalHeight: 1920))
        XCTAssertNil(CutoutSpecification.path(spec: "@left", density: 3.5, physicalWidth: 1080, physicalHeight: 1920))
        XCTAssertNil(CutoutSpecification.path(
            spec: "M 0,0 h 48 v 48 z @foo", density: 3.5, physicalWidth: 1080, physicalHeight: 1920
        ))
        XCTAssertNil(CutoutSpecification.pieces(spec: "M 0,0 L 1 z", density: 1, width: 100, height: 100))
    }

    /// A reduced-resolution mode scales the full-panel outline down: the
    /// 136 px square at `@right` of a 2076 px panel (x 1940…2076, y 0…136)
    /// at ratio 0.75 spans x 1455…1557 and y 0…102.
    func testPhysicalPixelRatioScalesTheOutline() throws {
        let path = try XCTUnwrap(CutoutSpecification.path(
            spec: "m 0,0 V 136 h -136 V 0 z @right",
            density: 2.4375,
            physicalWidth: 2076,
            physicalHeight: 2152,
            physicalPixelDisplaySizeRatio: 0.75
        ))
        XCTAssertEqual(path.boundingBox, rect(1455, 0, 1557, 102))
    }

    // MARK: - Path data

    /// Numbers split on ' ', ',', a '-' (not after an exponent) and a second
    /// '.'; a newline stays in the token and ends the number there.
    func testTokenizerSplitsNumbersLikeAndroid() throws {
        let commands = try XCTUnwrap(AndroidPathParser.commands(Array("M10-5 L1.5.5 l1e-2,3\nh 48\nz".utf8)))
        XCTAssertEqual(commands.map { String(UnicodeScalar($0.verb)) }, ["M", "L", "l", "h", "z"])
        XCTAssertEqual(commands[0].values, [10, -5])
        XCTAssertEqual(commands[1].values, [1.5, 0.5])
        XCTAssertEqual(commands[2].values[0], CGFloat(Float(0.01)))
        XCTAssertEqual(commands[2].values[1], 3)
        XCTAssertEqual(commands[3].values, [48])
        XCTAssertEqual(commands[4].values, [])
    }

    func testRejectedPathData() {
        XCTAssertNil(AndroidPathParser.path(""))
        XCTAssertNil(AndroidPathParser.path("   "))
        // Unknown command letter.
        XCTAssertNil(AndroidPathParser.path("M 0,0 X 5"))
        // Not a multiple of the arity.
        XCTAssertNil(AndroidPathParser.path("M 0,0 L 1"))
        XCTAssertNil(AndroidPathParser.path("M 0,0 a 1,1 0 0 0 5"))
        // A number with no digits.
        XCTAssertNil(AndroidPathParser.path("M 0,- L 5,5"))
    }

    /// Extra moveto pairs draw lines: `m 10,10 20,0 0,20 z` is a triangle
    /// (10,10) → (30,10) → (30,30). After `z` the pen is back at (10,10), so
    /// `m 20,0` starts the next subpath at (30,10): a 5 px square to 35,15.
    func testImplicitLinetoAndPenAfterClose() throws {
        let path = try XCTUnwrap(AndroidPathParser.path("m 10,10 20,0 0,20 z m 20,0 h 5 v 5 z"))
        XCTAssertEqual(path.boundingBox, rect(10, 10, 35, 30))
        XCTAssertTrue(path.contains(CGPoint(x: 29, y: 20)))
        XCTAssertFalse(path.contains(CGPoint(x: 11, y: 29)))
    }

    /// `S` mirrors the previous cubic's second control point: after
    /// `C 0,10 10,10 10,0` the first control of `S 20,-10 20,0` is (10,-10),
    /// so the second hump dips to -7.5 (a cubic with control heights -10,
    /// -10 peaks at 3/4 of them). Without the mirror it would dip only to
    /// -4.44.
    func testSmoothCubicMirrorsTheControlPoint() throws {
        let path = try XCTUnwrap(AndroidPathParser.path("M 0,0 C 0,10 10,10 10,0 S 20,-10 20,0"))
        let box = path.boundingBoxOfPath
        XCTAssertEqual(box.minY, -7.5, accuracy: 1e-9)
        XCTAssertEqual(box.maxY, 7.5, accuracy: 1e-9)
    }

    /// `T` mirrors the previous quadratic's control point: (5,10) about
    /// (10,0) is (15,-10), so the second hump dips to -5 (half the control
    /// height). Without the mirror `T` would be a straight line.
    func testSmoothQuadraticMirrorsTheControlPoint() throws {
        let path = try XCTUnwrap(AndroidPathParser.path("M 0,0 Q 5,10 10,0 T 20,0"))
        let box = path.boundingBoxOfPath
        XCTAssertEqual(box.minY, -5, accuracy: 1e-9)
        XCTAssertEqual(box.maxY, 5, accuracy: 1e-9)
    }

    /// Arcs: sweep flag 1 runs toward increasing angles, clockwise on a
    /// y-down display, so from (0,0) to (20,0) with r 10 the half circle
    /// passes over the top (y -10); flag 0 passes under it (y 10). Radii too
    /// small for the chord scale up (r 1 acts as r 10), and a zero radius is
    /// a straight line.
    func testArcSweepRadiusCorrectionAndZeroRadius() throws {
        let over = try XCTUnwrap(AndroidPathParser.path("M 0,0 A 10,10 0 0 1 20,0"))
        assertRect(over.boundingBoxOfPath, rect(0, -10, 20, 0))

        let under = try XCTUnwrap(AndroidPathParser.path("M 0,0 A 10,10 0 0 0 20,0"))
        assertRect(under.boundingBoxOfPath, rect(0, 0, 20, 10))

        let corrected = try XCTUnwrap(AndroidPathParser.path("M 0,0 A 1,1 0 0 1 20,0"))
        assertRect(corrected.boundingBoxOfPath, rect(0, -10, 20, 0))

        let line = try XCTUnwrap(AndroidPathParser.path("M 0,0 A 0,10 0 0 1 20,0"))
        assertRect(line.boundingBoxOfPath, rect(0, 0, 20, 0))

        // Large arc, r 10 on a chord of 10 (from the circle's top-left to
        // top-right 60° apart): the long way round spans the whole circle
        // but the short cap, x −5…15 around the centre (5, 8.66).
        let large = try XCTUnwrap(AndroidPathParser.path("M 0,0 A 10,10 0 1 0 10,0"))
        let box = large.boundingBoxOfPath
        XCTAssertEqual(box.minX, -5, accuracy: 1e-6)
        XCTAssertEqual(box.maxX, 15, accuracy: 1e-6)
        XCTAssertEqual(box.maxY, CGFloat(75).squareRoot() + 10, accuracy: 1e-6)
    }

    private func assertRect(
        _ actual: CGRect,
        _ expected: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1e-6, "minX", file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1e-6, "minY", file: file, line: line)
        XCTAssertEqual(actual.maxX, expected.maxX, accuracy: 1e-6, "maxX", file: file, line: line)
        XCTAssertEqual(actual.maxY, expected.maxY, accuracy: 1e-6, "maxY", file: file, line: line)
    }
}
