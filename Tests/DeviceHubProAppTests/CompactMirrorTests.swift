import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// The compact window's pure decisions: the toolbar button's title /
/// enablement and the close-when-the-mirror-stops predicate. Everything else
/// about the window is AppKit/SwiftUI wiring verified by build + behavior.
final class CompactMirrorTests: XCTestCase {
    func testMenuUnavailableWithoutALiveMirror() {
        let state = compactMirrorMenuState(isLive: false, isCompactOpen: false)

        XCTAssertEqual(state, .unavailable)
        XCTAssertEqual(state.title, "Switch to compact window")
        XCTAssertFalse(state.isEnabled)
    }

    func testMenuOffersOpenWhileLiveAndClosed() {
        let state = compactMirrorMenuState(isLive: true, isCompactOpen: false)

        XCTAssertEqual(state, .open)
        XCTAssertEqual(state.title, "Switch to compact window")
        XCTAssertTrue(state.isEnabled)
    }

    func testMenuOffersCloseWhileLiveAndOpen() {
        let state = compactMirrorMenuState(isLive: true, isCompactOpen: true)

        XCTAssertEqual(state, .close)
        XCTAssertEqual(state.title, "Show in Main Window")
        XCTAssertTrue(state.isEnabled)
    }

    func testMenuIgnoresStaleOpenFlagAfterTheMirrorStops() {
        let state = compactMirrorMenuState(isLive: false, isCompactOpen: true)

        XCTAssertEqual(state, .unavailable)
        XCTAssertFalse(state.isEnabled)
    }

    func testTheWindowClosesOnlyWhenTheActiveDeviceEnds() {
        XCTAssertTrue(compactMirrorShouldClose(activeDevice: nil))
        XCTAssertFalse(compactMirrorShouldClose(activeDevice: .android("emulator-5554")))
        // An Apple device has no adb serial, and still keeps the window open.
        XCTAssertFalse(compactMirrorShouldClose(activeDevice: .apple("00000000-0000-0000-0000-000000000000")))
    }

    /// The fatal-error teardown: polling stops the mirror once a physical
    /// session reports an error *and* has stopped itself. A live session's
    /// input errors land in `lastError` too, and must not take it down.
    func testAFatalSessionErrorStopsTheMirror() {
        XCTAssertTrue(
            shouldStopMirror(after: "The mirror stream ended unexpectedly", isRunning: false)
        )
    }

    func testAnInputErrorDoesNotStopTheMirror() {
        XCTAssertFalse(shouldStopMirror(after: "input: adb exited 1", isRunning: true))
    }

    func testNoErrorDoesNotStopTheMirror() {
        XCTAssertFalse(shouldStopMirror(after: nil, isRunning: true))
        XCTAssertFalse(shouldStopMirror(after: nil, isRunning: false))
    }

    /// The stats-poll resume guard: a result that resumes after its task was
    /// cancelled or its session replaced must be discarded, so a stale
    /// physical session's leftover error cannot reach `shouldStopMirror` and
    /// tear down the freshly started mirror.
    func testACancelledOrSupersededStatsPollResultIsDiscarded() {
        XCTAssertTrue(shouldApplyStatsResult(isCancelled: false, isCurrentSession: true))
        XCTAssertFalse(shouldApplyStatsResult(isCancelled: true, isCurrentSession: true))
        XCTAssertFalse(shouldApplyStatsResult(isCancelled: false, isCurrentSession: false))
        XCTAssertFalse(shouldApplyStatsResult(isCancelled: true, isCurrentSession: false))
    }
}
