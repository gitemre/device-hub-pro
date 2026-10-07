import CoreGraphics
import XCTest
@testable import DeviceHubProKit

final class FastInputPanelMappingTests: XCTestCase {
    private func check(_ rotation: FastInputPanelMapping.Rotation, _ input: (Double, Double), _ expected: (Double, Double), line: UInt = #line) {
        let p = rotation.apply(CGPoint(x: input.0, y: input.1))
        XCTAssertEqual(p.x, expected.0, accuracy: 1e-12, line: line)
        XCTAssertEqual(p.y, expected.1, accuracy: 1e-12, line: line)
    }

    func testTheFourRotationsExactly() {
        check(.identity, (0.2, 0.7), (0.2, 0.7))
        check(.clockwise90, (0.2, 0.7), (0.3, 0.2))
        check(.counterClockwise90, (0.2, 0.7), (0.7, 0.8))
        check(.turn180, (0.2, 0.7), (0.8, 0.3))
    }

    func testTheOrientationTable() {
        XCTAssertEqual(FastInputPanelMapping.rotation(for: .portrait), .identity)
        XCTAssertEqual(FastInputPanelMapping.rotation(for: .landscapeLeft), .clockwise90)
        XCTAssertEqual(FastInputPanelMapping.rotation(for: .landscapeRight), .counterClockwise90)
        XCTAssertEqual(FastInputPanelMapping.rotation(for: .portraitUpsideDown), .turn180)
        XCTAssertNil(FastInputPanelMapping.rotation(for: .faceUp))
        XCTAssertNil(FastInputPanelMapping.rotation(for: .unknown))
    }

    func testUpsideDownMapsThroughAHalfTurnOnAPortraitFrame() {
        let portrait = CGSize(width: 400, height: 800), landscape = CGSize(width: 800, height: 400)
        let p = FastInputPanelMapping.panelPoint(CGPoint(x: 0.2, y: 0.7), frame: portrait, orientation: .portraitUpsideDown)
        XCTAssertEqual(p?.x ?? -1, 0.8, accuracy: 1e-9)
        XCTAssertEqual(p?.y ?? -1, 0.3, accuracy: 1e-9)
        XCTAssertNil(FastInputPanelMapping.panelPoint(.zero, frame: landscape, orientation: .portraitUpsideDown))
        // A corner goes to the opposite corner, and the map is its own inverse.
        let corner = FastInputPanelMapping.panelPoint(.zero, frame: portrait, orientation: .portraitUpsideDown)
        XCTAssertEqual(corner, CGPoint(x: 1, y: 1))
        let back = FastInputPanelMapping.Rotation.turn180.apply(FastInputPanelMapping.Rotation.turn180.apply(CGPoint(x: 0.2, y: 0.7)))
        XCTAssertEqual(back.x, 0.2, accuracy: 1e-9)
        XCTAssertEqual(back.y, 0.7, accuracy: 1e-9)
    }

    func testAFrameMustAgreeWithTheOrientation() {
        let landscape = CGSize(width: 800, height: 400), portrait = CGSize(width: 400, height: 800)
        XCTAssertNotNil(FastInputPanelMapping.panelPoint(.zero, frame: landscape, orientation: .landscapeLeft))
        XCTAssertNil(FastInputPanelMapping.panelPoint(.zero, frame: portrait, orientation: .landscapeLeft))
        XCTAssertNil(FastInputPanelMapping.panelPoint(.zero, frame: landscape, orientation: .portrait))
        XCTAssertNil(FastInputPanelMapping.panelPoint(.zero, frame: portrait, orientation: .unknown))
    }
}
