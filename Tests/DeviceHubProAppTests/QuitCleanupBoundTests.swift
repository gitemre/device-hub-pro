import XCTest
@testable import DeviceHubProApp

/// The quit's overall bound must cover the conditions' put-back (the meter
/// alone can take about 7 s), or the quit abandons it half done.
@MainActor
final class QuitCleanupBoundTests: XCTestCase {
    func testTheQuitBoundCoversTheConditionsPutBack() {
        XCTAssertGreaterThanOrEqual(AppModel.quitCleanupLimit, DeviceConditionsController.cleanupWaitLimit)
    }
}
