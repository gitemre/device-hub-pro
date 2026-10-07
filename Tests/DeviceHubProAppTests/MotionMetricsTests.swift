import XCTest
@testable import DeviceHubProApp

/// Pins the motion tokens to their measured Device Hub values. Changing a
/// token without re-measuring DH (and updating the parity audit) fails
/// here on purpose.
final class MotionMetricsTests: XCTestCase {
    func testRotationTokenMatchesTheMeasuredDeviceHubValue() {
        // MOTION-01: DH rotates the device in ~250 ms.
        XCTAssertEqual(MotionMetrics.heroDuration, 0.25, accuracy: 0.001)
    }

    func testZoomTokenMatchesTheMeasuredDeviceHubValue() {
        // MOTION-02: DH animates zoom over ~283 ms.
        XCTAssertEqual(MotionMetrics.zoomDuration, 0.28, accuracy: 0.001)
    }

    func testMicroTokensStayMicro() {
        XCTAssertEqual(MotionMetrics.selectionDuration, 0.12, accuracy: 0.001)
        XCTAssertLessThan(MotionMetrics.standardDuration, MotionMetrics.zoomDuration)
        XCTAssertEqual(MotionMetrics.bannerDuration, 0.2, accuracy: 0.001)
    }

    func testFoldTokens() {
        XCTAssertEqual(MotionMetrics.foldDuration, 0.5, accuracy: 1e-9)
        XCTAssertEqual(MotionMetrics.foldStepInterval, 0.016, accuracy: 1e-9)
    }

    /// The frame buttons' tokens (HW-01; MOTION-08 is provisional until
    /// Device Hub's rollover is measured): hover out in 0.15 s, back after
    /// 0.10 s over 0.20 s, a press in 0.12 s, darkened 8 % as DH's held
    /// platter is (`PointerFeedback.pressedFill`, 7.8 %).
    func testChromeButtonTokens() {
        XCTAssertEqual(MotionMetrics.chromeHoverOnDuration, 0.15, accuracy: 1e-9)
        XCTAssertEqual(MotionMetrics.chromeHoverOffDelay, 0.10, accuracy: 1e-9)
        XCTAssertEqual(MotionMetrics.chromeHoverOffDuration, 0.20, accuracy: 1e-9)
        XCTAssertEqual(MotionMetrics.chromePressDuration, 0.12, accuracy: 1e-9)
        XCTAssertEqual(MotionMetrics.chromePressDuration, MotionMetrics.selectionDuration, accuracy: 1e-9)
        XCTAssertEqual(MotionMetrics.chromePressTint, 0.92, accuracy: 1e-9)
        // The hand-back from the split frame to the whole artwork at rest
        // is as long as the ease back.
        XCTAssertEqual(MotionMetrics.chromeRestFadeDuration, 0.20, accuracy: 1e-9)
        XCTAssertEqual(MotionMetrics.chromeRestFadeDuration, MotionMetrics.chromeHoverOffDuration, accuracy: 1e-9)
    }

    /// Hover travel is round(1.4 × depth) artwork pixels, held to 8–16 px
    /// and to 6 pt on screen: the Pixel 10 Pro's 10 px buttons roll out
    /// 14 px, ≈4.0 pt at its 0.283 pt/px stage fit; the open 9 Pro Fold's
    /// 4 px ones 8 px (5.6 rounds to 6, below the floor); a 12 px button
    /// stops at 16 px; a large fit stops at 6 pt.
    func testChromeHoverTravel() {
        XCTAssertEqual(MotionMetrics.chromeHoverTravel(depth: 10, pointsPerPixel: 0.283, reduceMotion: false), 14)
        XCTAssertEqual(14 * 0.283, 4.0, accuracy: 0.05)
        XCTAssertEqual(MotionMetrics.chromeHoverTravel(depth: 4, pointsPerPixel: 0.3, reduceMotion: false), 8)
        XCTAssertEqual(MotionMetrics.chromeHoverTravel(depth: 5, pointsPerPixel: 0.3, reduceMotion: false), 8)
        XCTAssertEqual(MotionMetrics.chromeHoverTravel(depth: 7, pointsPerPixel: 0.3, reduceMotion: false), 10)
        XCTAssertEqual(MotionMetrics.chromeHoverTravel(depth: 12, pointsPerPixel: 0.3, reduceMotion: false), 16)
        XCTAssertEqual(MotionMetrics.chromeHoverTravel(depth: 10, pointsPerPixel: 1, reduceMotion: false), 6, "6 pt at 1 pt/px")
        XCTAssertEqual(MotionMetrics.chromeHoverTravel(depth: 10, pointsPerPixel: 0.5, reduceMotion: false), 12, "6 pt at 0.5 pt/px")
    }

    /// A held button sinks round(0.6 × depth) pixels into the body.
    func testChromePressTravel() {
        XCTAssertEqual(MotionMetrics.chromePressTravel(depth: 10, reduceMotion: false), -6)
        XCTAssertEqual(MotionMetrics.chromePressTravel(depth: 4, reduceMotion: false), -2)
        XCTAssertEqual(MotionMetrics.chromePressTravel(depth: 7, reduceMotion: false), -4)
    }

    /// Reduce Motion: no button ever moves; the press shows as the tint.
    func testChromeButtonsDoNotMoveUnderReduceMotion() {
        for depth in [0, 4, 7, 10, 12] {
            XCTAssertEqual(MotionMetrics.chromeHoverTravel(depth: depth, pointsPerPixel: 0.283, reduceMotion: true), 0)
            XCTAssertEqual(MotionMetrics.chromePressTravel(depth: depth, reduceMotion: true), 0)
        }
    }

    func testRunSkipsTheAnimationUnderReduceMotion() {
        var values: [Int] = []
        MotionMetrics.run(.easeOut(duration: 0.1), reduceMotion: true) {
            values.append(1)
        }
        MotionMetrics.run(.easeOut(duration: 0.1), reduceMotion: false) {
            values.append(2)
        }
        XCTAssertEqual(values, [1, 2])
    }
}
