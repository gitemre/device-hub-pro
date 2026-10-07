import Foundation
import XCTest
@testable import DeviceHubProKit

/// The stage's touch dots: the pure model's transitions, the router's action
/// events, and the transport's warm-connection settings.
final class TouchFeedbackTests: XCTestCase {
    typealias Event = PhysicalControlInputRouter.ActionEvent
    private let point = CGPoint(x: 0.5, y: 0.25)

    // MARK: Model

    func testPressAcceptFinishFadeRemove() {
        var model = TouchFeedbackModel()
        model.apply(.pressed(point), now: 10)
        XCTAssertEqual(model.dots.map(\.phase), [.pressing])
        model.apply(.accepted(id: 7, point: point), now: 10.1)
        XCTAssertEqual(model.dots.map(\.phase), [.inFlight])
        XCTAssertEqual(model.dots.first?.id, 7)
        XCTAssertNil(model.settleDelay(now: 10.2), "waits on the runner")
        model.apply(.finished(id: 7), now: 11)
        XCTAssertEqual(model.dots.map(\.phase), [.fading])
        let mid = model.opacity(of: model.dots[0], now: 11.15)
        XCTAssertGreaterThan(mid, 0)
        XCTAssertLessThan(mid, 0.4)
        XCTAssertEqual(model.settleDelay(now: 11)!, TouchFeedbackModel.fadeDuration, accuracy: 0.001)
        XCTAssertTrue(model.visibleDots(now: 11.4).isEmpty)
        model.prune(now: 11.4)
        XCTAssertTrue(model.isEmpty)
    }

    func testDragMovesThePressingDotAndCancelRemovesIt() {
        var model = TouchFeedbackModel()
        model.apply(.pressed(point), now: 0)
        model.apply(.moved(CGPoint(x: 0.6, y: 0.7)), now: 0.1)
        XCTAssertEqual(model.dots.count, 1)
        XCTAssertEqual(model.dots[0].point, CGPoint(x: 0.6, y: 0.7))
        model.apply(.cancelled, now: 0.2)
        XCTAssertTrue(model.isEmpty)
    }

    func testADroppedTapShowsBrieflyAsDropped() {
        var model = TouchFeedbackModel()
        model.apply(.pressed(point), now: 0)
        model.apply(.dropped(point: point), now: 1)
        XCTAssertEqual(model.dots.map(\.phase), [.dropped])
        XCTAssertFalse(model.visibleDots(now: 1.1).isEmpty)
        XCTAssertTrue(model.visibleDots(now: 1 + TouchFeedbackModel.droppedDuration).isEmpty)
    }

    func testAFinishOfAnUnknownActionChangesNothing() {
        var model = TouchFeedbackModel()
        model.apply(.accepted(id: 1, point: point), now: 0)
        model.apply(.finished(id: 2), now: 0.1)
        XCTAssertEqual(model.dots.map(\.phase), [.inFlight])
    }

    func testReduceMotionRemovesAtOnceInsteadOfFading() {
        var model = TouchFeedbackModel()
        model.reduceMotion = true
        model.apply(.accepted(id: 1, point: point), now: 0)
        model.apply(.finished(id: 1), now: 1)
        XCTAssertTrue(model.isEmpty)
        model.apply(.dropped(point: point), now: 2)
        XCTAssertEqual(model.opacity(of: model.dots[0], now: 2.2), 0.8, "no fade: shown, then hidden")
        XCTAssertTrue(model.visibleDots(now: 2.4).isEmpty)
    }

    // MARK: Router events

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [Event] = []
        var all: [Event] { lock.withLock { _all } }
        func add(_ event: Event) { lock.withLock { _all.append(event) } }
    }

    private func router(_ control: FakeControl, _ events: Events) -> PhysicalControlInputRouter {
        PhysicalControlInputRouter(
            control: control,
            frameSize: { CGSize(width: 1000, height: 2000) },
            onFailure: { _ in },
            onSoftFailure: { _ in },
            onActionEvent: { events.add($0) }
        )
    }

    func testAClickEmitsPressedAcceptedThenFinished() async {
        let control = FakeControl()
        let events = Events()
        let router = router(control, events)
        router.receive(TouchCommand(phase: .down, x: 500, y: 1000))
        router.receive(TouchCommand(phase: .move, x: 502, y: 1000))
        router.receive(TouchCommand(phase: .up, x: 502, y: 1000))
        _ = await waitUntil { events.all.count == 4 }
        XCTAssertEqual(events.all, [
            .pressed(CGPoint(x: 0.5, y: 0.5)),
            .moved(CGPoint(x: 0.502, y: 0.5)),
            .accepted(id: 1, point: CGPoint(x: 0.502, y: 0.5)),
            .finished(id: 1),
        ])
    }

    func testAThirdClickIsDroppedAndDoesNotFinish() async {
        let control = FakeControl()
        control.gate = { try? await Task.sleep(for: .milliseconds(300)) }
        let events = Events()
        let router = router(control, events)
        for x in [100, 200, 300] as [Int32] {
            router.receive(TouchCommand(phase: .down, x: x, y: 100))
            router.receive(TouchCommand(phase: .up, x: x, y: 100))
        }
        XCTAssertTrue(events.all.contains(.dropped(point: CGPoint(x: 0.3, y: 0.05))))
        _ = await waitUntil { events.all.filter { if case .finished = $0 { return true } else { return false } }.count == 2 }
        let finished = events.all.compactMap { event -> UInt64? in if case .finished(let id) = event { id } else { nil } }
        XCTAssertEqual(finished, [1, 2])
    }

    func testASecondFingerCancelsTheGesture() {
        let events = Events()
        let router = router(FakeControl(), events)
        router.receive(contacts: [TouchCommand(phase: .down, x: 10, y: 10)])
        router.receive(contacts: [TouchCommand(phase: .move, x: 10, y: 10), TouchCommand(phase: .down, x: 20, y: 20, id: 1)])
        XCTAssertEqual(events.all.last, .cancelled)
    }

    // MARK: Transport

    func testTheTransportKeepsOneWarmConnection() throws {
        let configuration = URLSessionConfiguration.ephemeral
        let endpoint = try PhysicalControlEndpoint(tunnelAddress: "fd12:3456:789a::1", token: try PhysicalControlToken.generate())
        _ = PhysicalControlURLSessionTransport(endpoint: endpoint, configuration: configuration)
        XCTAssertEqual(configuration.httpMaximumConnectionsPerHost, 1)
        XCTAssertFalse(configuration.httpShouldUsePipelining)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 300)
    }
}
