import XCTest
@testable import DeviceHubProApp

/// Frame dedupe, backpressure and ring rebuilds of the mirror's frame feed.
final class FeedAdmissionTests: XCTestCase {
    // MARK: - Dedupe

    func testARepeatedGenerationIsSkipped() {
        var feed = FeedAdmission()
        XCTAssertTrue(feed.isNew(width: 64, height: 128, generation: 7))
        XCTAssertTrue(feed.stage(generation: 7, hasConsumer: true))
        XCTAssertFalse(feed.isNew(width: 64, height: 128, generation: 7), "the same frame is fed once")
        XCTAssertTrue(feed.isNew(width: 64, height: 128, generation: 8))
    }

    func testAFrameWithoutPixelsIsSkipped() {
        let feed = FeedAdmission()
        XCTAssertFalse(feed.isNew(width: 0, height: 128, generation: 1))
        XCTAssertFalse(feed.isNew(width: 64, height: 0, generation: 1))
        XCTAssertFalse(feed.isNew(width: -1, height: 128, generation: 1))
    }

    // MARK: - Backpressure

    func testFramesAreDroppedWhileMoreThanTwoConversionsArePending() {
        var feed = FeedAdmission()
        XCTAssertTrue(feed.stage(generation: 1, hasConsumer: true))
        XCTAssertTrue(feed.stage(generation: 2, hasConsumer: true))
        XCTAssertTrue(feed.stage(generation: 3, hasConsumer: true), "pending 2 still admits one more")
        XCTAssertEqual(feed.pending, 3)

        XCTAssertFalse(feed.stage(generation: 4, hasConsumer: true), "pending 3 drops the frame")
        XCTAssertEqual(feed.pending, 3)
        XCTAssertEqual(feed.lastGeneration, 3)
        XCTAssertTrue(feed.isNew(width: 64, height: 128, generation: 4), "a dropped frame is offered again")

        feed.conversionFinished()
        XCTAssertTrue(feed.stage(generation: 4, hasConsumer: true))
    }

    func testTheStagingLimitMatchesTheModel() {
        XCTAssertTrue(FeedAdmission.stagingAccepts(pending: 0))
        XCTAssertTrue(FeedAdmission.stagingAccepts(pending: 2))
        XCTAssertFalse(FeedAdmission.stagingAccepts(pending: 3))
    }

    @MainActor
    func testTheStagingRuleIsTheModelsRule() {
        for pending in -1...5 {
            XCTAssertEqual(
                FeedAdmission.stagingAccepts(pending: pending),
                MediaCaptureController.replayStagingAccepts(pending: pending),
                "\(pending)"
            )
        }
    }

    func testAFrameNobodyConsumesIsNeitherStagedNorRecorded() {
        var feed = FeedAdmission()
        XCTAssertFalse(feed.stage(generation: 1, hasConsumer: false))
        XCTAssertEqual(feed.pending, 0)
        XCTAssertNil(feed.lastGeneration)
        XCTAssertTrue(feed.isNew(width: 64, height: 128, generation: 1))
    }

    func testPendingNeverGoesBelowZero() {
        var feed = FeedAdmission()
        feed.conversionFinished()
        XCTAssertEqual(feed.pending, 0)
    }

    func testPendingIsNeverReset() {
        var feed = FeedAdmission()
        XCTAssertTrue(feed.stage(generation: 1, hasConsumer: true))
        XCTAssertTrue(feed.stage(generation: 2, hasConsumer: true))
        XCTAssertTrue(feed.stage(generation: 3, hasConsumer: true))

        // The ring is dropped and a recording restarts the feed while the
        // previous run's conversions are still queued.
        feed.resetRing()
        feed.offerCurrentFrameAgain()
        XCTAssertEqual(feed.pending, 3, "the queued conversions still count")
        XCTAssertFalse(feed.stage(generation: 3, hasConsumer: true), "no transient over-admission")

        feed.conversionFinished()
        XCTAssertTrue(feed.stage(generation: 3, hasConsumer: true))
    }

    // MARK: - Re-offering

    func testARingResetOrARecordingStartOffersTheCurrentFrameAgain() {
        var feed = FeedAdmission()
        XCTAssertTrue(feed.stage(generation: 5, hasConsumer: true))
        feed.offerCurrentFrameAgain()
        XCTAssertTrue(feed.isNew(width: 64, height: 128, generation: 5))

        XCTAssertTrue(feed.stage(generation: 5, hasConsumer: true))
        feed.resetRing()
        XCTAssertTrue(feed.isNew(width: 64, height: 128, generation: 5))
    }

    // MARK: - Ring

    func testTheRingIsBuiltForTheFirstFrameAndRebuiltOnASizeChange() {
        var feed = FeedAdmission()
        XCTAssertTrue(feed.ringNeedsRebuild(replayEnabled: true, hasRing: false, width: 1080, height: 2400))
        XCTAssertEqual(feed.ringSize, FeedAdmission.PixelSize(width: 1080, height: 2400))
        XCTAssertFalse(feed.ringNeedsRebuild(replayEnabled: true, hasRing: true, width: 1080, height: 2400))
        // Rotated.
        XCTAssertTrue(feed.ringNeedsRebuild(replayEnabled: true, hasRing: true, width: 2400, height: 1080))
        XCTAssertEqual(feed.ringSize, FeedAdmission.PixelSize(width: 2400, height: 1080))
    }

    func testAMissingRingIsRebuiltEvenAtTheSameSize() {
        var feed = FeedAdmission()
        XCTAssertTrue(feed.ringNeedsRebuild(replayEnabled: true, hasRing: false, width: 64, height: 128))
        XCTAssertTrue(feed.ringNeedsRebuild(replayEnabled: true, hasRing: false, width: 64, height: 128))
    }

    func testWithReplayOffNoRingIsBuilt() {
        var feed = FeedAdmission()
        XCTAssertFalse(feed.ringNeedsRebuild(replayEnabled: false, hasRing: false, width: 64, height: 128))
        XCTAssertNil(feed.ringSize)
    }

    func testARingResetForgetsTheRingSize() {
        var feed = FeedAdmission()
        XCTAssertTrue(feed.ringNeedsRebuild(replayEnabled: true, hasRing: false, width: 64, height: 128))
        feed.resetRing()
        XCTAssertNil(feed.ringSize)
        XCTAssertTrue(feed.ringNeedsRebuild(replayEnabled: true, hasRing: false, width: 64, height: 128))
    }
}
