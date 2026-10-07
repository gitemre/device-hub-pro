import XCTest
@testable import DeviceHubProApp

/// Replay feed hardening: the persisted window is validated on load, and the
/// RGBA→BGRA staging queue is bounded so a lagging conversion can never
/// accumulate full-frame buffers.
@MainActor
final class ReplayHardeningTests: XCTestCase {
    func testValidReplayWindowAcceptsTheOfferedOptions() {
        for seconds in AppPreferences.replayWindowOptions {
            XCTAssertEqual(AppPreferences.validReplayWindow(seconds), seconds)
        }
    }

    func testValidReplayWindowFallsBackToThirtyOutsideTheOptions() {
        let invalid: [Double?] = [nil, 0, 14.9, 45, -30, 300, .nan, .infinity]
        for value in invalid {
            XCTAssertEqual(
                AppPreferences.validReplayWindow(value),
                30,
                "\(String(describing: value)) must fall back to 30"
            )
        }
    }

    func testReplayStagingAcceptsUpToTwoPendingConversions() {
        XCTAssertTrue(MediaCaptureController.replayStagingAccepts(pending: 0))
        XCTAssertTrue(MediaCaptureController.replayStagingAccepts(pending: 1))
        XCTAssertTrue(MediaCaptureController.replayStagingAccepts(pending: 2))
        XCTAssertFalse(MediaCaptureController.replayStagingAccepts(pending: 3))
        XCTAssertFalse(MediaCaptureController.replayStagingAccepts(pending: 10))
    }
}
