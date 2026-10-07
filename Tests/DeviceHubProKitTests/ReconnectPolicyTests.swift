import XCTest
@testable import DeviceHubProKit

final class ReconnectPolicyTests: XCTestCase {
    func testScheduleCapsAttempts() {
        let policy = ReconnectPolicy()
        XCTAssertEqual(policy.delay(attempt: 1), .milliseconds(500))
        XCTAssertEqual(policy.delay(attempt: 2), .seconds(1))
        XCTAssertEqual(policy.delay(attempt: 5), .seconds(10))
        XCTAssertNil(policy.delay(attempt: 6))
        XCTAssertNil(policy.delay(attempt: 0))
    }

    func testCustomScheduleRepeatsLastDelay() {
        let policy = ReconnectPolicy(delays: [.milliseconds(10), .milliseconds(20)], maxAttempts: 3)
        XCTAssertEqual(policy.delay(attempt: 3), .milliseconds(20))
        XCTAssertNil(policy.delay(attempt: 4))
    }
}
