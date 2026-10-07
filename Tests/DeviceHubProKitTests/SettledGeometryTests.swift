import XCTest
@testable import DeviceHubProKit

final class SettledGeometryTests: XCTestCase {
    func testAcceptsFirstFrameImmediately() {
        var geometry = SettledGeometry()
        XCTAssertTrue(geometry.observe(width: 1080, height: 2424, rotation: 0))
        XCTAssertEqual(geometry.size, CGSize(width: 1080, height: 2424))
        XCTAssertEqual(geometry.rotation, 0)
    }

    func testIgnoresSingleTransitionalFrame() {
        var geometry = SettledGeometry()
        XCTAssertTrue(geometry.observe(width: 1080, height: 2424, rotation: 0))

        // Rotation metadata lags the buffer for a beat: landscape pixels
        // still tagged with rotation 0.
        XCTAssertFalse(geometry.observe(width: 2424, height: 1080, rotation: 0))
        XCTAssertEqual(geometry.size, CGSize(width: 1080, height: 2424))
        XCTAssertEqual(geometry.rotation, 0)
    }

    func testAcceptsGeometryRepeatedTwice() {
        var geometry = SettledGeometry()
        XCTAssertTrue(geometry.observe(width: 1080, height: 2424, rotation: 0))

        XCTAssertFalse(geometry.observe(width: 2424, height: 1080, rotation: 1))
        XCTAssertTrue(geometry.observe(width: 2424, height: 1080, rotation: 1))
        XCTAssertEqual(geometry.size, CGSize(width: 2424, height: 1080))
        XCTAssertEqual(geometry.rotation, 1)
    }

    func testReturningToSettledClearsPendingFlap() {
        var geometry = SettledGeometry()
        XCTAssertTrue(geometry.observe(width: 1080, height: 2424, rotation: 0))

        // A B A: the lone B never commits and leaves no residue.
        XCTAssertFalse(geometry.observe(width: 2424, height: 1080, rotation: 1))
        XCTAssertFalse(geometry.observe(width: 1080, height: 2424, rotation: 0))
        XCTAssertFalse(geometry.observe(width: 2424, height: 1080, rotation: 1))
        XCTAssertEqual(geometry.size, CGSize(width: 1080, height: 2424))
        XCTAssertEqual(geometry.rotation, 0)
    }

    func testAcceptsLandscapeAtRotationZero() {
        // An opened foldable is landscape-native: landscape pixels at
        // rotation 0 are settled, not transitional.
        var geometry = SettledGeometry()
        XCTAssertTrue(geometry.observe(width: 2208, height: 2092, rotation: 0))
        XCTAssertEqual(geometry.size, CGSize(width: 2208, height: 2092))
        XCTAssertEqual(geometry.rotation, 0)
    }

    func testFoldOpenRecoversFromStaleCoverSize() {
        var geometry = SettledGeometry()
        XCTAssertTrue(geometry.observe(width: 1080, height: 2092, rotation: 0))

        // Unfolding: the new landscape geometry commits once it repeats,
        // instead of starving behind a parity rule.
        XCTAssertFalse(geometry.observe(width: 2208, height: 2092, rotation: 0))
        XCTAssertTrue(geometry.observe(width: 2208, height: 2092, rotation: 0))
        XCTAssertEqual(geometry.size, CGSize(width: 2208, height: 2092))
        XCTAssertEqual(geometry.rotation, 0)
    }

    func testRepeatedObservationsDoNotChurn() {
        var geometry = SettledGeometry()
        XCTAssertTrue(geometry.observe(width: 1080, height: 2424, rotation: 0))
        for _ in 0..<10 {
            XCTAssertFalse(geometry.observe(width: 1080, height: 2424, rotation: 0))
        }
    }
}
