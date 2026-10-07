import XCTest
@testable import DeviceHubProKit

/// `SimulatorTouchTracker`: stage contacts to dtuhidd's one- and two-finger
/// digitizer events, by id.
final class SimulatorTouchTrackerTests: XCTestCase {
    private func contact(_ id: Int32, _ phase: TouchCommand.Phase, _ x: Double, _ y: Double, edge: SimulatorTouchEdge = .none) -> SimulatorContact {
        SimulatorContact(id: id, phase: phase, point: SimulatorTouchPoint(x: x, y: y), edge: edge)
    }

    private func point(_ x: Double, _ y: Double) -> SimulatorTouchPoint {
        SimulatorTouchPoint(x: x, y: y)
    }

    func testOneFingerDragBeganMovedEnded() {
        var tracker = SimulatorTouchTracker()
        XCTAssertEqual(tracker.accept([contact(1, .down, 0.5, 0.7)]), [.touch(x: 0.5, y: 0.7, phase: .began)])
        XCTAssertEqual(tracker.accept([contact(1, .move, 0.5, 0.5)]), [.touch(x: 0.5, y: 0.5, phase: .moved)])
        XCTAssertEqual(tracker.accept([contact(1, .up, 0.5, 0.3)]), [.touch(x: 0.5, y: 0.3, phase: .ended)])
        XCTAssertEqual(tracker.downCount, 0)
    }

    /// The edge a finger starts at rides on every event of that finger.
    func testAnEdgeContactIsTaggedOnEveryEvent() {
        var tracker = SimulatorTouchTracker()
        XCTAssertEqual(tracker.accept([contact(1, .down, 0.5, 0.995, edge: .bottom)]),
                       [.edgeTouch(x: 0.5, y: 0.995, phase: .began, edge: .bottom)])
        XCTAssertEqual(tracker.accept([contact(1, .move, 0.5, 0.8)]),
                       [.edgeTouch(x: 0.5, y: 0.8, phase: .moved, edge: .bottom)])
        XCTAssertEqual(tracker.accept([contact(1, .up, 0.5, 0.6)]),
                       [.edgeTouch(x: 0.5, y: 0.6, phase: .ended, edge: .bottom)])
        // The next finger starts clean.
        XCTAssertEqual(tracker.accept([contact(2, .down, 0.5, 0.5)]), [.touch(x: 0.5, y: 0.5, phase: .began)])
    }

    func testMovesAndUpsOfUnknownIdsAreDropped() {
        var tracker = SimulatorTouchTracker()
        XCTAssertEqual(tracker.accept([contact(7, .move, 0.1, 0.1)]), [])
        XCTAssertEqual(tracker.accept([contact(7, .up, 0.1, 0.1)]), [])
        _ = tracker.accept([contact(1, .down, 0.2, 0.2)])
        XCTAssertEqual(tracker.accept([contact(7, .move, 0.1, 0.1)]), [])
        // A repeated down of the finger that is down is a move.
        XCTAssertEqual(tracker.accept([contact(1, .down, 0.3, 0.3)]), [.touch(x: 0.3, y: 0.3, phase: .moved)])
    }

    func testATapInOneFrameBeginsAndEnds() {
        var tracker = SimulatorTouchTracker()
        XCTAssertEqual(tracker.accept([contact(1, .down, 0.4, 0.4), contact(1, .up, 0.4, 0.4)]), [
            .touch(x: 0.4, y: 0.4, phase: .began),
            .touch(x: 0.4, y: 0.4, phase: .ended),
        ])
        XCTAssertEqual(tracker.downCount, 0)
    }

    /// A pinch: both fingers in one frame, moving together, lifting together.
    func testTwoFingersInOneFrameAreOneTwoFingerTouch() {
        var tracker = SimulatorTouchTracker()
        XCTAssertEqual(tracker.accept([contact(1, .down, 0.4, 0.4), contact(2, .down, 0.6, 0.6)]), [
            .twoFingerTouch(first: point(0.4, 0.4), second: point(0.6, 0.6), phase: .began),
        ])
        XCTAssertEqual(tracker.accept([contact(1, .move, 0.3, 0.3), contact(2, .move, 0.7, 0.7)]), [
            .twoFingerTouch(first: point(0.3, 0.3), second: point(0.7, 0.7), phase: .moved),
        ])
        // One finger moving keeps the other where it was.
        XCTAssertEqual(tracker.accept([contact(2, .move, 0.8, 0.8)]), [
            .twoFingerTouch(first: point(0.3, 0.3), second: point(0.8, 0.8), phase: .moved),
        ])
        XCTAssertEqual(tracker.accept([contact(1, .up, 0.3, 0.3), contact(2, .up, 0.8, 0.8)]), [
            .twoFingerTouch(first: point(0.3, 0.3), second: point(0.8, 0.8), phase: .ended),
        ])
        XCTAssertEqual(tracker.downCount, 0)
    }

    /// A second finger joining ends the one-finger touch and begins two; the
    /// finger left after one lifts is ignored until it lifts too.
    func testASecondFingerJoiningAndTheLastFingerDraining() {
        var tracker = SimulatorTouchTracker()
        _ = tracker.accept([contact(1, .down, 0.2, 0.2)])
        XCTAssertEqual(tracker.accept([contact(2, .down, 0.8, 0.8)]), [
            .touch(x: 0.2, y: 0.2, phase: .ended),
            .twoFingerTouch(first: point(0.2, 0.2), second: point(0.8, 0.8), phase: .began),
        ])
        XCTAssertEqual(tracker.accept([contact(1, .up, 0.25, 0.25)]), [
            .twoFingerTouch(first: point(0.25, 0.25), second: point(0.8, 0.8), phase: .ended),
        ])
        XCTAssertEqual(tracker.downCount, 1)
        XCTAssertEqual(tracker.accept([contact(2, .move, 0.5, 0.5)]), [], "no stray drag after a pinch")
        XCTAssertEqual(tracker.accept([contact(3, .down, 0.1, 0.1)]), [], "nor a new finger while one drains")
        XCTAssertEqual(tracker.accept([contact(2, .up, 0.5, 0.5)]), [])
        XCTAssertEqual(tracker.downCount, 0)
        XCTAssertEqual(tracker.accept([contact(4, .down, 0.5, 0.5)]), [.touch(x: 0.5, y: 0.5, phase: .began)])
    }

    func testAThirdFingerIsDropped() {
        var tracker = SimulatorTouchTracker()
        _ = tracker.accept([contact(1, .down, 0.2, 0.2), contact(2, .down, 0.8, 0.8)])
        XCTAssertEqual(tracker.accept([contact(3, .down, 0.5, 0.5)]), [])
        XCTAssertEqual(tracker.accept([contact(3, .move, 0.5, 0.6)]), [])
        XCTAssertEqual(tracker.accept([contact(3, .up, 0.5, 0.6)]), [])
        XCTAssertEqual(tracker.downCount, 2)

        var fresh = SimulatorTouchTracker()
        XCTAssertEqual(fresh.accept([contact(1, .down, 0.1, 0.1), contact(2, .down, 0.2, 0.2), contact(3, .down, 0.3, 0.3)]), [
            .twoFingerTouch(first: point(0.1, 0.1), second: point(0.2, 0.2), phase: .began),
        ])
    }

    func testResetForgetsEverything() {
        var tracker = SimulatorTouchTracker()
        _ = tracker.accept([contact(1, .down, 0.2, 0.2)])
        tracker.reset()
        XCTAssertEqual(tracker.downCount, 0)
        XCTAssertEqual(tracker.accept([contact(1, .move, 0.3, 0.3)]), [])
    }
}
