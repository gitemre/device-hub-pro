import CoreGraphics
import XCTest
@testable import DeviceHubProKit

/// `CutoutPlacement` on the real cutouts of the API 37 Pixel 9 Pro Fold
/// emulator (`Fixtures/api37-emulator/adb-core/shell-dumpsys-display.txt`):
/// the inner panel's punch hole is a circle of r 39.5 centred at
/// (1987.5, 80) of 2076x2152, the cover's r 41.5 at (540, 86) of 1080x2424
/// (worked out from the specs in `DisplayShapeTests`).
///
/// SOURCE-DERIVED: the turned centres follow AOSP's
/// `RotationUtils.rotateBounds`
/// (`frameworks/base/core/java/android/util/RotationUtils.java`) for a
/// natural W×H panel — ROTATION_90 (x, y) → (y, W − x), ROTATION_180
/// (W − x, H − y), ROTATION_270 (H − y, x): the inner centre goes to
/// (80, 88.5) in 2152x2076, (88.5, 2072) in 2076x2152 and (2072, 1987.5) in
/// 2152x2076.
final class CutoutPlacementTests: XCTestCase {
    private func shapes() throws -> [DisplayShape] {
        DisplayShape.parse(dumpsysDisplay: try AdbCoreFixtureTests.text("shell-dumpsys-display.txt"))
    }

    private func inner(turns: Int) throws -> CutoutPlacement {
        try XCTUnwrap(CutoutPlacement(shape: try shapes()[0], quarterTurns: turns))
    }

    /// Upright, on a screen the panel's own size, the outline is the one
    /// the device reports: a 79 px box at (1948, 40.5).
    func testUprightTheOutlineIsTheDevicesOwn() throws {
        let placement = try inner(turns: 0)
        XCTAssertEqual(placement.naturalSize, CGSize(width: 2076, height: 2152))
        XCTAssertEqual(placement.rotatedSize, CGSize(width: 2076, height: 2152))
        let path = try XCTUnwrap(placement.path(in: CGRect(x: 0, y: 0, width: 2076, height: 2152)))
        assertRect(path.boundingBoxOfPath, CGRect(x: 1948, y: 40.5, width: 79, height: 79))
        XCTAssertTrue(path.contains(CGPoint(x: 1987.5, y: 80)))
    }

    /// Each turn moves the hole where Android's rotation puts it; the
    /// outline stays a 79 px circle.
    func testEachTurnMovesTheHoleWhereAndroidPutsIt() throws {
        let cases: [(turns: Int, screen: CGSize, centre: CGPoint)] = [
            (1, CGSize(width: 2152, height: 2076), CGPoint(x: 80, y: 88.5)),
            (2, CGSize(width: 2076, height: 2152), CGPoint(x: 88.5, y: 2072)),
            (3, CGSize(width: 2152, height: 2076), CGPoint(x: 2072, y: 1987.5)),
        ]
        for (turns, screen, centre) in cases {
            let placement = try inner(turns: turns)
            XCTAssertEqual(placement.rotatedSize, screen, "turns \(turns)")
            let path = try XCTUnwrap(placement.path(in: CGRect(origin: .zero, size: screen)))
            assertRect(
                path.boundingBoxOfPath,
                CGRect(x: centre.x - 39.5, y: centre.y - 39.5, width: 79, height: 79)
            )
            XCTAssertTrue(path.contains(centre), "turns \(turns)")
        }
    }

    /// Turns are taken modulo 4: −1 is ROTATION_270, 5 is ROTATION_90.
    func testTurnsWrapAround() throws {
        let screen = CGRect(x: 0, y: 0, width: 2152, height: 2076)
        let minusOne = try XCTUnwrap(inner(turns: -1).path(in: screen))
        let three = try XCTUnwrap(inner(turns: 3).path(in: screen))
        assertRect(minusOne.boundingBoxOfPath, three.boundingBoxOfPath)
        let five = try XCTUnwrap(inner(turns: 5).path(in: screen))
        let one = try XCTUnwrap(inner(turns: 1).path(in: screen))
        assertRect(five.boundingBoxOfPath, one.boundingBoxOfPath)
    }

    /// Into a half-size rect everything halves, and the rect's origin moves
    /// the outline with it: turned once, the centre (80, 88.5) lands at
    /// (100 + 40, 50 + 44.25).
    func testAHalfSizeRectHalvesTheOutline() throws {
        let path = try XCTUnwrap(inner(turns: 1).path(in: CGRect(x: 100, y: 50, width: 1076, height: 1038)))
        assertRect(path.boundingBoxOfPath, CGRect(x: 140 - 19.75, y: 94.25 - 19.75, width: 39.5, height: 39.5))
    }

    /// A stream whose sides were rounded (scrcpy's multiples of 8: the
    /// cover as 1080x2416) is placed at the smaller side ratio, like
    /// `DisplayShape.scale(toFit:)`: 2416 / 2424.
    func testARoundedStreamUsesTheSmallerSideRatio() throws {
        let cover = try XCTUnwrap(CutoutPlacement(shape: try shapes()[1], quarterTurns: 3))
        XCTAssertEqual(cover.rotatedSize, CGSize(width: 2424, height: 1080))
        let path = try XCTUnwrap(cover.path(in: CGRect(x: 0, y: 0, width: 2416, height: 1080)))
        let k = 2416.0 / 2424
        // ROTATION_270 puts the cover's (540, 86) at (2424 − 86, 540).
        let box = path.boundingBoxOfPath
        XCTAssertEqual(Double(box.midX), (2424 - 86) * k, accuracy: 1e-6)
        XCTAssertEqual(Double(box.midY), 540 * k, accuracy: 1e-6)
        XCTAssertEqual(Double(box.width), 83 * k, accuracy: 1e-6)
    }

    /// No outline for an empty screen, an empty panel, or a spec Android
    /// would reject; a display without a cutout has no placement.
    func testNothingToPlace() throws {
        let placement = try inner(turns: 0)
        XCTAssertNil(placement.path(in: .zero))
        var empty = placement
        empty.naturalSize = .zero
        XCTAssertNil(empty.path(in: CGRect(x: 0, y: 0, width: 2076, height: 2152)))
        var garbled = placement
        garbled.cutout.spec = "m 2027,80 x 39.5 z @left"
        XCTAssertNil(garbled.path(in: CGRect(x: 0, y: 0, width: 2076, height: 2152)))

        var plain = try shapes()[0]
        plain.cutout = nil
        XCTAssertNil(CutoutPlacement(shape: plain, quarterTurns: 0))
    }

    // MARK: - In the vector plan

    /// Unknown turns: placed upright only when the screen is in the panel's
    /// natural orientation (the inner panel is portrait); a landscape frame
    /// of it could be either ROTATION_90 or ROTATION_270, so no hole is
    /// drawn until the rotation is read.
    func testUnknownTurnsPlaceTheHoleOnlyInTheNaturalOrientation() throws {
        let shapes = try shapes()
        let portrait = DeviceCompositionPlanner.vector(
            screen: CGSize(width: 2076, height: 2152),
            displays: shapes,
            fallbackDensityDpi: nil,
            quarterTurns: nil
        )
        XCTAssertEqual(portrait.cutout?.quarterTurns, 0)

        let landscape = DeviceCompositionPlanner.vector(
            screen: CGSize(width: 2152, height: 2076),
            displays: shapes,
            fallbackDensityDpi: nil,
            quarterTurns: nil
        )
        XCTAssertNil(landscape.cutout)
        // The rest of the plan does not wait for the rotation.
        XCTAssertEqual(landscape.screenCorner, ScreenCorner(radius: 85, source: .device))
    }

    /// A known turn places the hole in the posed screen, inside the body:
    /// ROTATION_90 of the inner panel shown landscape puts its centre at
    /// (bezel + 80, bezel + 88.5), bezel 66.024.
    func testAKnownTurnPlacesTheHoleInThePosedScreen() throws {
        let plan = DeviceCompositionPlanner.vector(
            screen: CGSize(width: 2152, height: 2076),
            displays: try shapes(),
            fallbackDensityDpi: nil,
            quarterTurns: 1
        )
        let cutout = try XCTUnwrap(plan.cutout)
        XCTAssertEqual(cutout.quarterTurns, 1)
        let box = try XCTUnwrap(cutout.path(in: plan.screenRect)).boundingBoxOfPath
        XCTAssertEqual(box.midX, 66.024 + 80, accuracy: 0.01)
        XCTAssertEqual(box.midY, 66.024 + 88.5, accuracy: 0.01)
    }

    /// A turn that contradicts the screen (a rotation read that lags the
    /// turn: ROTATION_90 on a portrait frame) draws no hole rather than one
    /// on the wrong edge.
    func testATurnThatContradictsTheScreenPlacesNoHole() throws {
        for turns in [1, 3] {
            let plan = DeviceCompositionPlanner.vector(
                screen: CGSize(width: 2076, height: 2152),
                displays: try shapes(),
                fallbackDensityDpi: nil,
                quarterTurns: turns
            )
            XCTAssertNil(plan.cutout, "turns \(turns)")
        }
        let upsideDown = DeviceCompositionPlanner.vector(
            screen: CGSize(width: 2076, height: 2152),
            displays: try shapes(),
            fallbackDensityDpi: nil,
            quarterTurns: 2
        )
        XCTAssertEqual(upsideDown.cutout?.quarterTurns, 2)
    }

    // MARK: - Helpers

    private func assertRect(
        _ actual: CGRect,
        _ expected: CGRect,
        accuracy: CGFloat = 1e-6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, "minX", file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, "minY", file: file, line: line)
        XCTAssertEqual(actual.maxX, expected.maxX, accuracy: accuracy, "maxX", file: file, line: line)
        XCTAssertEqual(actual.maxY, expected.maxY, accuracy: accuracy, "maxY", file: file, line: line)
    }
}
