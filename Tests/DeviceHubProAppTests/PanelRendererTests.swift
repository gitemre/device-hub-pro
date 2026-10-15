import Foundation
import Synchronization
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The 3D stage's panel renderer calls its handler after every drawn frame.
final class PanelRendererTests: XCTestCase {
    /// Thousands of frames leave the handler's call as shallow as the first:
    /// a closure read out of a `Mutex` with `withLock { $0 }` gained two
    /// thunk frames a read and overflowed the drawing thread's stack.
    func testTheHandlerDoesNotDeepenFrameAfterFrame() {
        let renderer = PanelRenderer()
        let depths = Mutex<[Int]>([])
        renderer.setPresented { _, _ in depths.withLock { $0.append(Thread.callStackReturnAddresses.count) } }
        renderer.notifyPresented(.inner, queue: ObjectIdentifier(renderer))
        for _ in 0..<5_000 { renderer.notifyPresented(.inner, queue: ObjectIdentifier(renderer)) }
        let seen = depths.withLock { $0 }
        XCTAssertEqual(seen.count, 5_001)
        XCTAssertEqual(seen.last, seen.first)
    }

    // MARK: - The frames waiting for a panel

    /// Each panel draws its newest frame only; the draining starts once.
    func testTheNewestFrameReplacesOneStillWaiting() {
        var board = PanelJobBoard<String>()
        let first = board.submit("a", for: .inner)
        XCTAssertTrue(first.start)
        let second = board.submit("b", for: .inner)
        XCTAssertFalse(second.start, "a drain is running already")
        XCTAssertGreaterThan(second.sequence, first.sequence)
        // The other panel is independent.
        XCTAssertTrue(board.submit("c", for: .outer).start)

        let next = board.next(for: .inner)
        XCTAssertEqual(next?.0, "b")
        XCTAssertEqual(next?.1, second.sequence)
        XCTAssertNil(board.next(for: .inner), "ends the drain")
        // Idle again: the next frame starts a new one.
        XCTAssertTrue(board.submit("d", for: .inner).start)
    }

    /// A frame that found no drawable is tried once more while it is still
    /// the newest the panel was handed.
    func testAFrameThatFoundNoDrawableIsRequeuedWhileItIsTheNewest() {
        var board = PanelJobBoard<String>()
        let sent = board.submit("a", for: .inner)
        XCTAssertEqual(board.next(for: .inner)?.0, "a")
        XCTAssertNil(board.next(for: .inner))

        XCTAssertTrue(board.requeue("a", sequence: sent.sequence, for: .inner), "drain again")
        XCTAssertEqual(board.next(for: .inner)?.0, "a")
        XCTAssertNil(board.next(for: .inner))
    }

    /// A newer frame supersedes the retry, whether it is waiting or already
    /// drawn: an old picture must not replace a newer one.
    func testANewerFrameVoidsTheRetryOfAnOlderOne() {
        var board = PanelJobBoard<String>()
        let old = board.submit("old", for: .inner)
        _ = board.next(for: .inner)
        XCTAssertNil(board.next(for: .inner))

        // A newer frame waits.
        let newer = board.submit("new", for: .inner)
        XCTAssertFalse(board.requeue("old", sequence: old.sequence, for: .inner))
        XCTAssertEqual(board.next(for: .inner)?.0, "new")
        XCTAssertNil(board.next(for: .inner))
        // And once it was drawn too.
        XCTAssertFalse(board.requeue("old", sequence: old.sequence, for: .inner))
        // The newest itself is still retried.
        XCTAssertTrue(board.requeue("new", sequence: newer.sequence, for: .inner))
    }

    /// A panel that went dark drops its waiting frame and every retry.
    func testADroppedPanelForgetsItsFramesAndRetries() {
        var board = PanelJobBoard<String>()
        let sent = board.submit("a", for: .inner)
        board.drop(.inner)
        XCTAssertNil(board.next(for: .inner))
        XCTAssertFalse(board.requeue("a", sequence: sent.sequence, for: .inner))
        XCTAssertTrue(board.submit("b", for: .inner).start)
    }

    /// The retry delay is short: a static screen's one frame is not lost for
    /// long, and the scene is asked to draw meanwhile.
    func testTheSecondTryComesWithinAFewFrames() {
        XCTAssertEqual(PanelRenderer.retryDelay, .milliseconds(30))
    }
}
