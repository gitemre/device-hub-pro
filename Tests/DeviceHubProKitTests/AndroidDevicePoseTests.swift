import XCTest
@testable import DeviceHubProKit

final class AndroidDevicePoseTests: XCTestCase {
    func testTheModelRotationNamesTheStagePoseInQuarterTurns() {
        let cases: [(Float, Int)] = [
            (0, 0), (90, 1), (180, 2), (270, 3), (360, 0), (450, 1),
            (-90, 3), (-180, 2), (-270, 1), (-360, 0), (89.6, 1), (-0.4, 0), (181.2, 2),
        ]
        for (degrees, turns) in cases {
            XCTAssertEqual(AndroidDevicePose.turns(forRotationDegrees: degrees), turns, "\(degrees)")
        }
    }

    func testANonFiniteReadingIsPortrait() {
        XCTAssertEqual(AndroidDevicePose.turns(forRotationDegrees: .nan), 0)
        XCTAssertEqual(AndroidDevicePose.turns(forRotationDegrees: .infinity), 0)
    }
}
