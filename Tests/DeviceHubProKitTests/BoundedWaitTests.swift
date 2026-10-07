import XCTest
@testable import DeviceHubProKit

final class BoundedWaitTests: XCTestCase {
    /// A body that never returns (and ignores cancellation, like a gRPC call
    /// parked in a server worker) does not hold the caller past the timeout.
    func testAStuckBodyTimesOutWithoutBeingAwaited() async {
        let started = ContinuousClock.now
        let value: Int? = await BoundedWait.run(.milliseconds(100)) {
            await withCheckedContinuation { (_: CheckedContinuation<Int, Never>) in }
        }
        XCTAssertNil(value)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
    }

    func testAnAnswerInTimeIsReturned() async {
        let value = await BoundedWait.run(.seconds(5)) { 42 }
        XCTAssertEqual(value, 42)
    }
}
