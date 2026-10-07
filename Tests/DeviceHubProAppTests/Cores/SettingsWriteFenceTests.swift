import XCTest
@testable import DeviceHubProApp

/// Which Controls polls may apply their settings rows around writes.
final class SettingsWriteFenceTests: XCTestCase {
    func testAPollWithNoWriteAppliesItsRows() {
        let fence = SettingsWriteFence()
        XCTAssertTrue(fence.isIdle)
        let ticket = fence.pollTicket
        XCTAssertTrue(fence.admits(pollStartedAt: ticket))
    }

    func testAPollOverlappingAFinishedWriteDropsItsRows() {
        var fence = SettingsWriteFence()
        let ticket = fence.pollTicket
        // The write starts and finishes while the poll's reads run.
        fence.beginWrite()
        fence.endWrite()
        XCTAssertTrue(fence.isIdle)
        XCTAssertFalse(fence.admits(pollStartedAt: ticket), "the reads may predate the write's value")
        // The next poll starts after the write and applies.
        XCTAssertTrue(fence.admits(pollStartedAt: fence.pollTicket))
    }

    func testAPollDuringAWriteNeitherReadsNorApplies() {
        var fence = SettingsWriteFence()
        fence.beginWrite()
        XCTAssertFalse(fence.isIdle, "the poll skips the settings reads")
        XCTAssertFalse(fence.admits(pollStartedAt: fence.pollTicket), "nor applies while the write runs")
    }

    func testAWriteStartingBeforeTheApplyBlocksIt() {
        var fence = SettingsWriteFence()
        let ticket = fence.pollTicket
        fence.beginWrite()
        XCTAssertFalse(fence.admits(pollStartedAt: ticket))
    }

    func testOverlappingWritesHoldTheFenceUntilTheLastEnds() {
        var fence = SettingsWriteFence()
        fence.beginWrite()
        fence.beginWrite()
        XCTAssertEqual(fence.depth, 2)
        XCTAssertEqual(fence.writesStarted, 2)
        fence.endWrite()
        XCTAssertFalse(fence.isIdle, "the first to finish must not release the second")
        fence.endWrite()
        XCTAssertTrue(fence.isIdle)
        XCTAssertEqual(fence.writesStarted, 2, "an end starts nothing")
    }

    func testTheStartCountWrapsInsteadOfTrapping() {
        var fence = SettingsWriteFence(writesStarted: .max)
        let ticket = fence.pollTicket
        fence.beginWrite()
        fence.endWrite()
        XCTAssertEqual(fence.writesStarted, 0)
        XCTAssertFalse(fence.admits(pollStartedAt: ticket))
    }
}
