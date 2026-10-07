import Foundation
import XCTest
@testable import DeviceHubProKit

/// The chrome's buttons of a physical iPhone while Control is off: a fast session starts on
/// the first press, the edges wait for it in order, stale ones are dropped, a stuck button is
/// released, and stopping ends the session.
final class PhysicalChromeButtonsTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 100
        var now: TimeInterval { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }

    private final class Manual: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(id: Int, delay: TimeInterval, work: @Sendable () -> Void)] = []
        private var next = 0
        var scheduler: PhysicalControlInputRouter.Scheduler {
            { [self] delay, work in
                let id = lock.withLock { () -> Int in next += 1; items.append((next, delay, work)); return next }
                return { [self] in lock.withLock { items.removeAll { $0.id == id } } }
            }
        }
        func delays() -> [TimeInterval] { lock.withLock { items.map(\.delay) } }
        func fire(delay: TimeInterval) {
            let due = lock.withLock { () -> [@Sendable () -> Void] in
                let due = items.filter { $0.delay == delay }.map(\.work)
                items.removeAll { $0.delay == delay }
                return due
            }
            due.forEach { $0() }
        }
    }

    private final class Starts: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        let sender = FakeFastSender()
        var count: Int { lock.withLock { _count } }
        func bump() { lock.withLock { _count += 1 } }
    }

    func testThePressesWaitForTheSessionThatStartsOnTheFirstOneAndGoInOrder() async throws {
        let starts = Starts()
        let gate = FastInputGate()
        let buttons = PhysicalChromeButtons(start: {
            starts.bump()
            await gate.wait()
            return starts.sender
        })
        buttons.receive(button: .volumeUp, isDown: true)
        buttons.receive(button: .volumeUp, isDown: false)
        buttons.receive(button: .side, isDown: true)
        buttons.receive(button: .side, isDown: false)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(starts.count, 1, "one session, started by the first press")
        XCTAssertTrue(starts.sender.calls.isEmpty)
        await gate.open()
        let done = await waitUntil { starts.sender.calls.count == 4 }
        XCTAssertTrue(done)
        XCTAssertEqual(starts.sender.calls, [.hid(0x0C, 0xE9, true), .hid(0x0C, 0xE9, false),
                                             .hid(0x0C, 0x30, true), .hid(0x0C, 0x30, false)])
        buttons.receive(button: .home, isDown: true)
        _ = await waitUntil { starts.sender.calls.count == 5 }
        XCTAssertEqual(starts.count, 1, "the running session is reused")
        await buttons.stop().value
        XCTAssertEqual(starts.sender.stops, 1)
    }

    func testAPairOlderThanTwoSecondsIsDroppedWhenTheSessionIsReady() async throws {
        let clock = Clock()
        let starts = Starts()
        let gate = FastInputGate()
        let buttons = PhysicalChromeButtons(start: {
            starts.bump()
            await gate.wait()
            return starts.sender
        }, now: { clock.now })
        buttons.receive(button: .volumeUp, isDown: true)
        buttons.receive(button: .volumeUp, isDown: false)
        clock.advance(2.5)
        buttons.receive(button: .volumeDown, isDown: true)
        buttons.receive(button: .volumeDown, isDown: false)
        await gate.open()
        let done = await waitUntil { starts.sender.calls.count == 2 }
        XCTAssertTrue(done)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(starts.sender.calls, [.hid(0x0C, 0xEA, true), .hid(0x0C, 0xEA, false)])
        await buttons.stop().value
    }

    func testAButtonWithNoUpIsReleasedAfterTenSecondsAndAnUpCancelsTheTimer() async throws {
        let manual = Manual()
        let starts = Starts()
        let buttons = PhysicalChromeButtons(start: { starts.bump(); return starts.sender }, schedule: manual.scheduler)
        buttons.receive(button: .side, isDown: true)
        XCTAssertEqual(manual.delays(), [10])
        buttons.receive(button: .side, isDown: false)
        XCTAssertEqual(manual.delays(), [], "the up cancelled the timer")
        buttons.receive(button: .siri, isDown: true)
        _ = await waitUntil { starts.sender.calls.count == 3 }
        manual.fire(delay: 10)
        let released = await waitUntil { starts.sender.calls.count == 4 }
        XCTAssertTrue(released)
        XCTAssertEqual(starts.sender.calls.last, .hid(0x0C, 0xCF, false))
        await buttons.stop().value
    }

    func testAClickIsADownAndAnUp() async throws {
        let manual = Manual()
        let starts = Starts()
        let buttons = PhysicalChromeButtons(start: { starts.bump(); return starts.sender }, schedule: manual.scheduler)
        buttons.tap(button: .home)
        _ = await waitUntil { starts.sender.calls.count == 1 }
        manual.fire(delay: 0.08)
        let done = await waitUntil { starts.sender.calls.count == 2 }
        XCTAssertTrue(done)
        XCTAssertEqual(starts.sender.calls, [.hid(0x0C, 0x40, true), .hid(0x0C, 0x40, false)])
        await buttons.stop().value
    }

    func testAFailedStartIsReportedAndTheNextPressTriesAgain() async throws {
        let failures = Starts()
        let reported = Starts()
        let buttons = PhysicalChromeButtons(start: {
            failures.bump()
            if failures.count == 1 { throw FastInputError.tunnelNotConnected }
            return failures.sender
        }, onFailure: { _ in reported.bump() })
        buttons.receive(button: .home, isDown: true)
        let first = await waitUntil { reported.count == 1 }
        XCTAssertTrue(first)
        buttons.receive(button: .volumeUp, isDown: true)
        let second = await waitUntil { failures.sender.calls.count == 1 }
        XCTAssertTrue(second)
        XCTAssertEqual(failures.sender.calls, [.hid(0x0C, 0xE9, true)])
        await buttons.stop().value
    }
}
