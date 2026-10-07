import XCTest
@testable import DeviceHubProKit

/// The display rect a skin's `layout` puts the screen in, for the layouts the
/// Browse Catalog's previews were wrong for (`pixel_7a`) and two more shapes:
/// real files copied from the SDK's `skins/` (see `LogcatSdkApkFixtures`).
final class SkinDisplayRectFixtureTests: XCTestCase {
    private func display(_ skin: String) throws -> SkinDisplay {
        let url = LogcatSdkApkFixtures.url("skins/\(skin)/layout")
        return try XCTUnwrap(SkinLayout.parseFile(at: url)?.preferred)
    }

    /// 1226x2559 frame, the 1080x2400 screen at (69, 69): 77 px of artwork
    /// right of it and 90 below, a thicker chin than top bezel by design of
    /// the artwork (its transparent opening is exactly 69...1148 by
    /// 69...2468), not an offset of ours.
    func testPixel7aScreenSitsAtTheLayoutsDisplayRect() throws {
        let d = try display("pixel_7a")
        XCTAssertEqual(d.layoutSize, CGSize(width: 1226, height: 2559))
        XCTAssertEqual(d.screenRect, CGRect(x: 69, y: 69, width: 1080, height: 2400))
        XCTAssertNil(d.cornerRadius, "pixel_7a declares no corner; the artwork's opening decides")
        XCTAssertEqual(d.artworkRect(pixelSize: CGSize(width: 1226, height: 2559)), CGRect(x: 0, y: 0, width: 1226, height: 2559))
        let n = d.normalizedScreenRect
        XCTAssertEqual(n.minX, 69.0 / 1226, accuracy: 1e-9)
        XCTAssertEqual(n.maxY, 2469.0 / 2559, accuracy: 1e-9)
    }

    func testPixel9ProXlDeclaresItsOwnCorner() throws {
        let d = try display("pixel_9_pro_xl")
        XCTAssertEqual(d.screenRect, CGRect(x: 57, y: 56, width: 1344, height: 2992))
        XCTAssertEqual(d.layoutSize, CGSize(width: 1466, height: 3101))
        XCTAssertEqual(d.cornerRadius, 108)
    }

    func testRoundWatchScreenIsTheSquareInsideItsBezel() throws {
        let d = try display("wearos_xl_round")
        XCTAssertEqual(d.screenRect, CGRect(x: 25, y: 25, width: 480, height: 480))
        XCTAssertEqual(d.layoutSize, CGSize(width: 530, height: 530))
        XCTAssertEqual(d.cornerRadius, 210)
    }
}
