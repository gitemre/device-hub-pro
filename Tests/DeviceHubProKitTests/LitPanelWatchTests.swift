import CoreVideo
import XCTest
@testable import DeviceHubProKit

/// The pieces that find a black panel quickly and read the lit one reliably:
/// the frame sampler, the watchdog's thresholds and the check queue.
final class LitPanelWatchTests: XCTestCase {
    // MARK: - Frame darkness

    private func buffer(width: Int, height: Int, format: OSType = kCVPixelFormatType_32BGRA) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, format, attributes, &made), kCVReturnSuccess)
        let buffer = try XCTUnwrap(made)
        if format == kCVPixelFormatType_32BGRA {
            fill(buffer, blue: 0, green: 0, red: 0)
        }
        return buffer
    }

    private func fill(_ buffer: CVPixelBuffer, blue: UInt8, green: UInt8, red: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            for x in 0..<CVPixelBufferGetWidth(buffer) {
                let pixel = base + y * stride + x * 4
                pixel[0] = blue
                pixel[1] = green
                pixel[2] = red
                pixel[3] = 255
            }
        }
    }

    private func set(_ buffer: CVPixelBuffer, x: Int, y: Int, value: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let pixel = base + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        pixel[0] = value
        pixel[1] = value
        pixel[2] = value
    }

    func testABlackFrameIsDarkAndALitOneIsNot() throws {
        let frame = try buffer(width: 640, height: 480)
        XCTAssertEqual(FrameDarkness.isDark(frame), true)
        fill(frame, blue: 200, green: 200, red: 200)
        XCTAssertEqual(FrameDarkness.isDark(frame), false)
    }

    /// The unlit panel is pure black; a dark wallpaper keeps a few levels.
    func testTheThresholdSeparatesBlackFromADarkWallpaper() throws {
        let frame = try buffer(width: 640, height: 480)
        fill(frame, blue: 9, green: 9, red: 9)
        XCTAssertEqual(FrameDarkness.isDark(frame), true)
        fill(frame, blue: 0, green: 0, red: 10)
        XCTAssertEqual(FrameDarkness.isDark(frame), false, "the brightest channel counts")
    }

    func testAnySampledPixelWithContentMakesTheFrameLit() throws {
        let frame = try buffer(width: 1752, height: 2784)
        // The grid's first pixel: (width / 64, height / 96).
        set(frame, x: 1752 / 64, y: 2784 / 96, value: 255)
        XCTAssertEqual(FrameDarkness.isDark(frame), false)
    }

    func testATinyFrameIsSampledWhole() throws {
        let frame = try buffer(width: 3, height: 2)
        XCTAssertEqual(FrameDarkness.isDark(frame), true)
        set(frame, x: 2, y: 1, value: 80)
        XCTAssertEqual(FrameDarkness.isDark(frame), false)
    }

    func testAFrameItCannotReadHasNoAnswer() throws {
        let other = try buffer(width: 16, height: 16, format: kCVPixelFormatType_32ARGB)
        XCTAssertNil(FrameDarkness.isDark(other))
    }

    // MARK: - The watchdog

    private let t0 = ContinuousClock.now

    func testAPanelThatStaysBlackIsAskedAfterThreeHundredMilliseconds() {
        var watch = DarkPanelWatchdog()
        XCTAssertNil(watch.due)
        watch.observe(dark: true, at: t0)
        XCTAssertEqual(watch.due, t0 + .milliseconds(300))
        XCTAssertFalse(watch.take(at: t0 + .milliseconds(299)))
        XCTAssertTrue(watch.take(at: t0 + .milliseconds(300)))
    }

    /// More black frames inside the spell do not push the time back.
    func testALongerSpellKeepsItsFirstBlackFrame() {
        var watch = DarkPanelWatchdog()
        watch.observe(dark: true, at: t0)
        watch.observe(dark: true, at: t0 + .milliseconds(200))
        XCTAssertEqual(watch.due, t0 + .milliseconds(300))
    }

    func testALitFrameEndsTheSpell() {
        var watch = DarkPanelWatchdog()
        watch.observe(dark: true, at: t0)
        watch.observe(dark: false, at: t0 + .milliseconds(200))
        XCTAssertNil(watch.due)
        XCTAssertFalse(watch.isDark)
        XCTAssertFalse(watch.take(at: t0 + .seconds(5)))
        // Black again: a new spell, counted from its own first frame.
        watch.observe(dark: true, at: t0 + .seconds(6))
        XCTAssertEqual(watch.due, t0 + .seconds(6) + .milliseconds(300))
    }

    func testASpellAsksTwiceAndNoMoreForABlackPanel() {
        var watch = DarkPanelWatchdog()
        watch.observe(dark: true, at: t0)
        XCTAssertTrue(watch.take(at: t0 + .milliseconds(300)))
        // The second ask waits `retryGap` after the first.
        XCTAssertEqual(watch.due, t0 + .milliseconds(300) + .milliseconds(1500))
        XCTAssertFalse(watch.take(at: t0 + .milliseconds(1799)))
        XCTAssertTrue(watch.take(at: t0 + .milliseconds(1800)))
        XCTAssertNil(watch.due, "a panel black for good is read twice, not for ever")
        XCTAssertFalse(watch.take(at: t0 + .seconds(60)))
    }

    /// A hinge that moves again may light the other panel: the spell asks
    /// again, but not closer than a second to the last ask.
    func testAMovingHingeEarnsNewChecksOneSecondApart() {
        var watch = DarkPanelWatchdog()
        watch.observe(dark: true, at: t0)
        XCTAssertTrue(watch.take(at: t0 + .milliseconds(300)))
        XCTAssertTrue(watch.take(at: t0 + .milliseconds(1800)))
        XCTAssertNil(watch.due)
        watch.hingeMoved()
        XCTAssertEqual(watch.due, t0 + .milliseconds(1800) + .seconds(1))
        XCTAssertTrue(watch.take(at: t0 + .milliseconds(2800)))
    }

    /// A screen that flickers between black and lit (a video, a black app)
    /// is read twice at most, not twice per flicker.
    func testAFlickeringScreenIsNotReadAgainAtEveryBlackSpell() {
        var watch = DarkPanelWatchdog()
        var asks = 0
        var now = t0
        for _ in 0..<20 {
            watch.observe(dark: true, at: now)
            now += .milliseconds(400)
            if watch.take(at: now) { asks += 1 }
            now += .milliseconds(1600)
            if watch.take(at: now) { asks += 1 }
            watch.observe(dark: false, at: now)
            now += .milliseconds(100)
        }
        XCTAssertEqual(asks, DarkPanelWatchdog.maximumChecks)
        // Until the hinge moves.
        watch.hingeMoved()
        watch.observe(dark: true, at: now)
        XCTAssertNotNil(watch.due)
    }

    func testAFreshPanelForgetsTheSpell() {
        var watch = DarkPanelWatchdog()
        watch.observe(dark: true, at: t0)
        XCTAssertTrue(watch.take(at: t0 + .milliseconds(300)))
        XCTAssertTrue(watch.take(at: t0 + .milliseconds(1800)))
        watch.reset()
        XCTAssertNil(watch.due)
        XCTAssertFalse(watch.isDark)
        watch.observe(dark: true, at: t0 + .seconds(1))
        XCTAssertEqual(watch.due, t0 + .seconds(1) + .milliseconds(300), "a fresh panel asks again, at once")
    }

    // MARK: - The check queue

    private let udid = "00000000-0000-0000-0000-000000000001"

    func testARequestWhileAReadRunsReadsAgainWhenItEnds() {
        var queue = LitPanelCheckQueue()
        XCTAssertTrue(queue.request(udid))
        XCTAssertFalse(queue.request(udid), "one read at a time")
        XCTAssertFalse(queue.request(udid), "however many ask meanwhile")
        XCTAssertEqual(queue.finish(udid, conclusive: true), .rerun)
        // The rerun is a read under way: a request now waits for it.
        XCTAssertFalse(queue.request(udid))
        XCTAssertEqual(queue.finish(udid, conclusive: true), .rerun)
        XCTAssertEqual(queue.finish(udid, conclusive: true), .done)
        XCTAssertTrue(queue.request(udid), "idle again")
    }

    func testAnInconclusiveReadIsRetriedAfterHalfASecondASecondAndTwo() {
        var queue = LitPanelCheckQueue()
        XCTAssertTrue(queue.request(udid))
        XCTAssertEqual(queue.finish(udid, conclusive: false), .retry(after: .milliseconds(500)))
        XCTAssertTrue(queue.retryDue(udid))
        XCTAssertEqual(queue.finish(udid, conclusive: false), .retry(after: .seconds(1)))
        XCTAssertTrue(queue.retryDue(udid))
        XCTAssertEqual(queue.finish(udid, conclusive: false), .retry(after: .seconds(2)))
        XCTAssertTrue(queue.retryDue(udid))
        XCTAssertEqual(queue.finish(udid, conclusive: false), .done, "three retries, then it stops")
    }

    func testAConclusiveReadEndsTheRetries() {
        var queue = LitPanelCheckQueue()
        XCTAssertTrue(queue.request(udid))
        XCTAssertEqual(queue.finish(udid, conclusive: false), .retry(after: .milliseconds(500)))
        XCTAssertTrue(queue.retryDue(udid))
        XCTAssertEqual(queue.finish(udid, conclusive: true), .done)
        // The next inconclusive read starts the delays over.
        XCTAssertTrue(queue.request(udid))
        XCTAssertEqual(queue.finish(udid, conclusive: false), .retry(after: .milliseconds(500)))
    }

    func testANewRequestStartsTheRetriesOver() {
        var queue = LitPanelCheckQueue()
        XCTAssertTrue(queue.request(udid))
        XCTAssertEqual(queue.finish(udid, conclusive: false), .retry(after: .milliseconds(500)))
        XCTAssertTrue(queue.retryDue(udid))
        XCTAssertEqual(queue.finish(udid, conclusive: false), .retry(after: .seconds(1)))
        // A newer fold asks while the retry waits: it reads at once, and its
        // own retries begin with the short wait.
        XCTAssertTrue(queue.request(udid))
        XCTAssertEqual(queue.finish(udid, conclusive: false), .retry(after: .milliseconds(500)))
    }

    /// A retry whose wait ended after a newer read began leaves that read to
    /// do the work.
    func testARetryDoesNotReadOverANewerRead() {
        var queue = LitPanelCheckQueue()
        XCTAssertTrue(queue.request(udid))
        XCTAssertEqual(queue.finish(udid, conclusive: false), .retry(after: .milliseconds(500)))
        XCTAssertTrue(queue.request(udid))
        XCTAssertFalse(queue.retryDue(udid))
    }

    /// The watchdog asks again itself: its read is taken once, however it
    /// ends, so a panel black for good is not read four times a time.
    func testAReadThatDoesNotRetryEndsWhateverItSays() {
        var queue = LitPanelCheckQueue()
        XCTAssertTrue(queue.request(udid, retriesWhenInconclusive: false))
        XCTAssertEqual(queue.finish(udid, conclusive: false), .done)
        // The next request that retries is not held to it.
        XCTAssertTrue(queue.request(udid))
        XCTAssertEqual(queue.finish(udid, conclusive: false), .retry(after: .milliseconds(500)))
    }

    /// A request that retries, made while a read that does not is under way,
    /// makes the read that follows it retry.
    func testARequestThatRetriesWinsOverOneThatDoesNot() {
        var queue = LitPanelCheckQueue()
        XCTAssertTrue(queue.request(udid, retriesWhenInconclusive: false))
        XCTAssertFalse(queue.request(udid))
        XCTAssertEqual(queue.finish(udid, conclusive: false), .rerun)
        XCTAssertEqual(queue.finish(udid, conclusive: false), .retry(after: .milliseconds(500)))
    }

    func testEachSimulatorHasItsOwnReads() {
        var queue = LitPanelCheckQueue()
        XCTAssertTrue(queue.request(udid))
        XCTAssertTrue(queue.request("00000000-0000-0000-0000-000000000002"))
        XCTAssertEqual(queue.finish(udid, conclusive: true), .done)
    }

    func testASimulatorThatWentAwayIsForgotten() {
        var queue = LitPanelCheckQueue()
        XCTAssertTrue(queue.request(udid))
        XCTAssertFalse(queue.request(udid))
        queue.forget(udid)
        XCTAssertTrue(queue.request(udid))
        XCTAssertEqual(queue.finish(udid, conclusive: true), .done)
    }

    // MARK: - What a read means

    private func record(_ angle: Double, _ panel: SimulatorFoldPanel) -> SimulatorFoldRecord {
        SimulatorFoldRecord(angle: angle, panel: panel)
    }

    func testAReadThatFindsAnotherPanelLitMovesTheSession() {
        let outcome = LitPanelRead.outcome(asked: record(107, .inner), now: record(107, .inner), lit: .outer)
        XCTAssertEqual(outcome, LitPanelRead.Outcome(switchTo: .outer, conclusive: true))
    }

    func testAReadThatFindsTheRecordedPanelLitLeavesItBe() {
        let outcome = LitPanelRead.outcome(asked: record(107, .inner), now: record(107, .inner), lit: .inner)
        XCTAssertEqual(outcome, LitPanelRead.Outcome(switchTo: nil, conclusive: true))
    }

    /// Both panels dark, both lit or a screenshot missing: tried again.
    func testAReadThatCannotTellIsNotConclusive() {
        let outcome = LitPanelRead.outcome(asked: record(107, .inner), now: record(107, .inner), lit: nil)
        XCTAssertEqual(outcome, LitPanelRead.Outcome(switchTo: nil, conclusive: false))
    }

    /// A hinge that moved while the screenshots were read is newer than they
    /// are: neither the panel nor a retry, the move's own check reads it.
    func testAHingeThatMovedMeanwhileMakesTheReadStale() {
        for lit in [SimulatorFoldPanel?.none, .some(.outer), .some(.inner)] {
            XCTAssertEqual(
                LitPanelRead.outcome(asked: record(107, .inner), now: record(150, .inner), lit: lit),
                LitPanelRead.Outcome(switchTo: nil, conclusive: true), "angle moved, lit \(String(describing: lit))"
            )
            XCTAssertEqual(
                LitPanelRead.outcome(asked: record(107, .inner), now: record(107, .outer), lit: lit),
                LitPanelRead.Outcome(switchTo: nil, conclusive: true), "panel moved, lit \(String(describing: lit))"
            )
        }
    }

    /// The canvas's loop, scripted: a read made while the guest is still
    /// lighting a panel finds both dark and is tried again; a check asked
    /// meanwhile reads straight after; the read that tells moves the session.
    func testTheChecksReadAgainUntilThePanelIsFound() {
        var queue = LitPanelCheckQueue()
        var book = SimulatorFoldBook()
        book.note(udid: udid, angle: 107, panel: .inner)
        let asked = book.record(of: udid)

        XCTAssertTrue(queue.request(udid))
        // Both panels dark: not conclusive, retried after half a second.
        var outcome = LitPanelRead.outcome(asked: asked, now: book.record(of: udid), lit: nil)
        XCTAssertEqual(queue.finish(udid, conclusive: outcome.conclusive), .retry(after: .milliseconds(500)))
        XCTAssertTrue(queue.retryDue(udid))
        // A drag ends while that read runs: it waits, and reads when it ends.
        XCTAssertFalse(queue.request(udid))
        outcome = LitPanelRead.outcome(asked: asked, now: book.record(of: udid), lit: nil)
        XCTAssertEqual(queue.finish(udid, conclusive: outcome.conclusive), .rerun)
        // The rerun finds the outer panel lit while the inner one is booked.
        outcome = LitPanelRead.outcome(asked: asked, now: book.record(of: udid), lit: .outer)
        XCTAssertEqual(outcome.switchTo, .outer)
        XCTAssertTrue(book.note(udid: udid, angle: 107, panel: .outer))
        XCTAssertEqual(queue.finish(udid, conclusive: outcome.conclusive), .done)
        XCTAssertEqual(book.record(of: udid).panel, .outer)
    }

    // MARK: - Steps

    func testOnlyHingeStepsMoveTheHinge() {
        XCTAssertTrue(SimulatorFoldStep.hinge(130).movesHinge)
        XCTAssertTrue(SimulatorFoldStep.sweep(from: 0, to: 130).movesHinge)
        XCTAssertFalse(SimulatorFoldStep.pose(.portrait).movesHinge)
        XCTAssertFalse(SimulatorFoldStep.pause(0.5).movesHinge)
    }
}
