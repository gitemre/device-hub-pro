import XCTest
import CoreGraphics
@testable import DeviceHubProKit

final class TextureRotationTests: XCTestCase {
    func testNormalizedWrapsNegativeAndLargeValues() {
        XCTAssertEqual(TextureRotation.normalized(0), 0)
        XCTAssertEqual(TextureRotation.normalized(4), 0)
        XCTAssertEqual(TextureRotation.normalized(-1), 3)
        XCTAssertEqual(TextureRotation.normalized(-5), 3)
        XCTAssertEqual(TextureRotation.normalized(7), 3)
    }

    func testUprightSizeTransposesOnOddTurns() {
        XCTAssertEqual(TextureRotation.uprightSize(posedWidth: 1080, posedHeight: 2400, rotation: 0).width, 1080)
        XCTAssertEqual(TextureRotation.uprightSize(posedWidth: 1080, posedHeight: 2400, rotation: 0).height, 2400)
        XCTAssertEqual(TextureRotation.uprightSize(posedWidth: 2400, posedHeight: 1080, rotation: 1).width, 1080)
        XCTAssertEqual(TextureRotation.uprightSize(posedWidth: 2400, posedHeight: 1080, rotation: 1).height, 2400)
        XCTAssertEqual(TextureRotation.uprightSize(posedWidth: 1080, posedHeight: 2400, rotation: 2).width, 1080)
    }

    /// The natural size must be invariant across poses and across the
    /// transitional inconsistency (a flipped buffer with a stale rotation),
    /// which is what keeps the video rect from transposing mid-animation.
    func testNaturalSizeIsInvariantForAPortraitDisplay() {
        let expected = (width: 1080, height: 2400)
        let pairs = [(1080, 2400, 0), (2400, 1080, 1), (1080, 2400, 2), (2400, 1080, 3),
                     (1080, 2400, 1), (2400, 1080, 0)]
        for (width, height, rotation) in pairs {
            let natural = TextureRotation.naturalSize(
                posedWidth: width,
                posedHeight: height,
                rotation: rotation,
                naturalIsPortrait: true
            )
            XCTAssertEqual(natural.width, expected.width, "\(width)x\(height) r\(rotation)")
            XCTAssertEqual(natural.height, expected.height, "\(width)x\(height) r\(rotation)")
        }
    }

    func testNaturalSizeIsInvariantForALandscapeDisplay() {
        let expected = (width: 2400, height: 1080)
        let pairs = [(2400, 1080, 0), (1080, 2400, 1), (2400, 1080, 2), (1080, 2400, 3),
                     (1080, 2400, 0), (2400, 1080, 1)]
        for (width, height, rotation) in pairs {
            let natural = TextureRotation.naturalSize(
                posedWidth: width,
                posedHeight: height,
                rotation: rotation,
                naturalIsPortrait: false
            )
            XCTAssertEqual(natural.width, expected.width, "\(width)x\(height) r\(rotation)")
            XCTAssertEqual(natural.height, expected.height, "\(width)x\(height) r\(rotation)")
        }
    }

    func testPosedPointIsTheInverseOfTouchMapping() {
        // Landscape-posed buffer (2400x1080): upright space is 1080x2400.
        let posedWidth = 2400
        let posedHeight = 1080
        for rotation in 0...3 {
            let upright = TextureRotation.uprightSize(
                posedWidth: posedWidth,
                posedHeight: posedHeight,
                rotation: rotation
            )
            for point in [(0, 0), (upright.width - 1, 0), (0, upright.height - 1),
                          (upright.width - 1, upright.height - 1), (12, 34)] {
                let posed = TextureRotation.posedPoint(
                    x: point.0,
                    y: point.1,
                    posedWidth: posedWidth,
                    posedHeight: posedHeight,
                    rotation: rotation
                )
                let back = TouchMapping.nativePoint(
                    x: posed.x,
                    y: posed.y,
                    frameWidth: posedWidth,
                    frameHeight: posedHeight,
                    rotation: rotation
                )
                XCTAssertEqual(back.x, point.0, "rotation \(rotation) point \(point)")
                XCTAssertEqual(back.y, point.1, "rotation \(rotation) point \(point)")
            }
        }
    }

    func testPosedUVMatchesPosedPointAtQuarterTurns() {
        let posedWidth = 2400
        let posedHeight = 1080
        for rotation in 0...3 {
            let upright = TextureRotation.uprightSize(
                posedWidth: posedWidth,
                posedHeight: posedHeight,
                rotation: rotation
            )
            for (u, v) in [(0.1, 0.2), (0.5, 0.5), (0.9, 0.8)] {
                let uv = TextureRotation.posedUV(u: u, v: v, rotation: rotation)
                let point = TextureRotation.posedPoint(
                    x: Int(u * Double(upright.width)),
                    y: Int(v * Double(upright.height)),
                    posedWidth: posedWidth,
                    posedHeight: posedHeight,
                    rotation: rotation
                )
                // Normalized comparison with a tight tolerance: a 180° error
                // (or a transpose) shifts a component by ~1.0, while the
                // pixel-center rounding is well under 0.002.
                XCTAssertEqual(uv.u, Double(point.x) / Double(posedWidth), accuracy: 0.002,
                               "rotation \(rotation) uv \(u),\(v)")
                XCTAssertEqual(uv.v, Double(point.y) / Double(posedHeight), accuracy: 0.002,
                               "rotation \(rotation) uv \(u),\(v)")
            }
        }
    }

    /// The direction is pinned against `TouchMapping`'s own documented pair:
    /// at rotation 1 a posed pixel (1732, 417) in a 2424×1080 buffer is the
    /// upright point (662, 1732). The shader must sample that same buffer
    /// pixel for the upright point — the check the old 1.5 px tolerance could
    /// not make.
    func testPosedUVSamplesTheCalibratedPixel() {
        let posedWidth = 2424.0
        let posedHeight = 1080.0
        let uprightWidth = 1080.0
        let uprightHeight = 2424.0

        let back = TouchMapping.nativePoint(
            x: 1732,
            y: 417,
            frameWidth: Int(posedWidth),
            frameHeight: Int(posedHeight),
            rotation: 1
        )
        XCTAssertEqual(back.x, 662)
        XCTAssertEqual(back.y, 1732)

        let uv = TextureRotation.posedUV(
            u: Double(back.x) / uprightWidth,
            v: Double(back.y) / uprightHeight,
            rotation: 1
        )
        XCTAssertEqual(uv.u, 1732.0 / posedWidth, accuracy: 0.002)
        XCTAssertEqual(uv.v, 417.0 / posedHeight, accuracy: 0.002)
    }
}
