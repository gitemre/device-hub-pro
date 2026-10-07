import XCTest
@testable import DeviceHubProKit

final class TouchMappingTests: XCTestCase {
    // Inner display: streamed frame 2152x2076 in landscape (rotation 1/3).
    // Cover display: streamed frame 2424x1080 in landscape.

    func testPortraitIsIdentity() {
        let point = TouchMapping.nativePoint(
            x: 650, y: 710,
            frameWidth: 2076, frameHeight: 2152,
            rotation: 0
        )
        XCTAssertEqual(point.x, 650)
        XCTAssertEqual(point.y, 710)
    }

    func testLandscapeMapping() {
        let point = TouchMapping.nativePoint(
            x: 930, y: 1585,
            frameWidth: 2152, frameHeight: 2076,
            rotation: 1
        )
        XCTAssertEqual(point.x, 490)
        XCTAssertEqual(point.y, 930)
    }

    /// Calibrated on the emulator: with the folded cover rotated to landscape
    /// (frame 2424x1080, rotation 1), this is the Photos icon on screen; its
    /// touch point is the upright one Android reports for the same icon.
    func testCoverLandscapeMappingMatchesEmulator() {
        let point = TouchMapping.nativePoint(
            x: 1732, y: 417,
            frameWidth: 2424, frameHeight: 1080,
            rotation: 1
        )
        XCTAssertEqual(point.x, 662)
        XCTAssertEqual(point.y, 1732)
    }

    func testReverseLandscapeMapping() {
        let point = TouchMapping.nativePoint(
            x: 650, y: 710,
            frameWidth: 2152, frameHeight: 2076,
            rotation: 3
        )
        XCTAssertEqual(point.x, 710)
        XCTAssertEqual(point.y, 1501)
    }

    func testReversePortraitMapping() {
        let point = TouchMapping.nativePoint(
            x: 650, y: 710,
            frameWidth: 2076, frameHeight: 2152,
            rotation: 2
        )
        XCTAssertEqual(point.x, 1425)
        XCTAssertEqual(point.y, 1441)
    }

    func testCornersClampToPanel() {
        let topLeft = TouchMapping.nativePoint(
            x: 0, y: 0,
            frameWidth: 2152, frameHeight: 2076,
            rotation: 3
        )
        XCTAssertEqual(topLeft.x, 0)
        XCTAssertEqual(topLeft.y, 2151)

        let bottomRight = TouchMapping.nativePoint(
            x: 2151, y: 2075,
            frameWidth: 2152, frameHeight: 2076,
            rotation: 3
        )
        XCTAssertEqual(bottomRight.x, 2075)
        XCTAssertEqual(bottomRight.y, 0)
    }
}
