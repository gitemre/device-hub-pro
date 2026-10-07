import XCTest
@testable import DeviceHubProApp

/// Device ▸ Shake on an emulator: the accelerometer sequence.
final class ShakeMotionTests: XCTestCase {
    func testShakeJoltsAlternateAndEndOnTheRestingReading() {
        let rest: [Float] = [0.5, 9.7, 0.8]
        let samples = ShakeMotion.samples(rest: rest)
        XCTAssertEqual(samples.count, ShakeMotion.jolts + 1)
        XCTAssertEqual(samples.last, rest)
        XCTAssertEqual(samples[0][0], 0.5 + ShakeMotion.amplitude)
        XCTAssertEqual(samples[1][0], 0.5 - ShakeMotion.amplitude)
        for sample in samples.dropLast() {
            XCTAssertEqual(sample[1], 9.7)
            XCTAssertEqual(sample[2], 0.8)
            XCTAssertGreaterThan(abs(sample[0] - 0.5), 25, "above a shake threshold of about 2.5 g")
        }
    }

    func testShakeFallsBackToUprightGravity() {
        XCTAssertEqual(ShakeMotion.samples(rest: nil).last, ShakeMotion.defaultRest)
        XCTAssertEqual(ShakeMotion.samples(rest: [1, 2]).last, ShakeMotion.defaultRest, "a short reading is not trusted")
    }
}
