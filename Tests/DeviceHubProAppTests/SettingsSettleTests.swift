import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

@MainActor
final class SettingsSettleTests: XCTestCase {
    func testSettlesOnTheFirstRead() async {
        var reads = 0
        var value = false

        let settled = await settleSetting(
            attempts: 5,
            delay: .zero,
            attempt: {
                reads += 1
                value = true
            },
            settled: { value }
        )

        XCTAssertTrue(settled)
        XCTAssertEqual(reads, 1)
    }

    /// The device left while the loop read: the next read is not made.
    func testStopsWhenTheDeviceIsNoLongerCurrent() async {
        var reads = 0
        var present = true

        let settled = await settleSetting(
            attempts: 5,
            delay: .zero,
            isCurrent: { present },
            attempt: {
                reads += 1
                present = false
            },
            settled: { false }
        )

        XCTAssertFalse(settled)
        XCTAssertEqual(reads, 1)
    }

    /// Each read's adb calls carry the short bound while the loop runs.
    func testAttemptsRunUnderTheShortCallTimeout() async {
        var seen: Duration?
        _ = await settleSetting(
            attempts: 1,
            delay: .zero,
            attemptTimeout: .seconds(5),
            attempt: { seen = AdbCallTimeout.override },
            settled: { true }
        )
        XCTAssertEqual(seen, .seconds(5))
        XCTAssertNil(AdbCallTimeout.override)
    }

    func testRetriesUntilTheValueArrives() async {
        var reads = 0
        var value = false

        let settled = await settleSetting(
            attempts: 5,
            delay: .zero,
            attempt: {
                reads += 1
                if reads == 3 { value = true }
            },
            settled: { value }
        )

        XCTAssertTrue(settled)
        XCTAssertEqual(reads, 3)
    }

    func testGivesUpAfterTheBudget() async {
        var reads = 0

        let settled = await settleSetting(
            attempts: 3,
            delay: .zero,
            attempt: { reads += 1 },
            settled: { false }
        )

        XCTAssertFalse(settled)
        XCTAssertEqual(reads, 3)
    }

    func testVolumeKeyEventsStepTowardTheTarget() {
        XCTAssertEqual(volumeKeyEvents(from: 5, to: 8), ["24", "24", "24"])
        XCTAssertEqual(volumeKeyEvents(from: 8, to: 5), ["25", "25", "25"])
    }

    func testVolumeKeyEventsAreEmptyWhenAlreadyThere() {
        XCTAssertEqual(volumeKeyEvents(from: 7, to: 7), [])
    }

    func testVolumeKeyEventsRespectTheLimit() {
        XCTAssertEqual(volumeKeyEvents(from: 0, to: 15, limit: 4), ["24", "24", "24", "24"])
        XCTAssertEqual(volumeKeyEvents(from: 15, to: 0, limit: 0), [])
    }

    func testZeroAttemptsReportsTheCurrentStateWithoutReading() async {
        var reads = 0

        let settled = await settleSetting(
            attempts: 0,
            delay: .zero,
            attempt: { reads += 1 },
            settled: { true }
        )

        XCTAssertTrue(settled)
        XCTAssertEqual(reads, 0)
    }
}
