import Synchronization
import XCTest
@testable import DeviceHubProKit

/// `PhysicalScreenshotSession`, the wireless view of a physical iPhone:
/// repeated public `devicectl` screenshots, one at a
/// time, the next as soon as the previous finished and no sooner than the
/// floor after it started, only while a view shows it, through temporary
/// PNGs that never accumulate.
///
/// The picture a capture writes is a real PNG capture
/// (`simctl-io-screenshot.home-screen-loading.png`, 1206×2622, provenance in
/// `SimulatorLifecycleFixtureTests.testTheHomeScreenIsToldFromTheBootScreen`)
/// standing in for the PNG `devicectl device capture screenshot` writes; the
/// fake capture is the seam where `DevicectlPhysicalClient.screenshot(to:)`
/// runs in the app.
final class PhysicalScreenshotSessionTests: XCTestCase {
    /// Polls `condition` every 10 ms until it holds or `timeout` seconds pass.
    private static func wait(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    private let udid = "00000000-0000000000000000"
    private static let picture = SimctlFixtureTests.url("simctl-core", "simctl-io-screenshot.home-screen-loading.png")

    /// Counts captures, tracks how many run at once, and takes `duration`
    /// per capture.
    private final class FakeCapture: Sendable {
        private struct Counters {
            var calls = 0
            var running = 0
            var maximumRunning = 0
            var starts: [ContinuousClock.Instant] = []
            var destinations: [URL] = []
        }

        private let counters = Mutex(Counters())
        private let duration: Duration
        private let failure: (@Sendable () -> Error?)

        init(duration: Duration = .zero, failure: @escaping @Sendable () -> Error? = { nil }) {
            self.duration = duration
            self.failure = failure
        }

        var calls: Int { counters.withLock { $0.calls } }
        var maximumRunning: Int { counters.withLock { $0.maximumRunning } }
        var starts: [ContinuousClock.Instant] { counters.withLock { $0.starts } }
        /// Every file this capture was asked to write.
        var destinations: [URL] { counters.withLock { $0.destinations } }

        func run(_ destination: URL) async throws {
            counters.withLock { counters in
                counters.calls += 1
                counters.running += 1
                counters.maximumRunning = max(counters.maximumRunning, counters.running)
                counters.starts.append(ContinuousClock.now)
                counters.destinations.append(destination)
            }
            defer { counters.withLock { $0.running -= 1 } }
            if duration > .zero { try await Task.sleep(for: duration) }
            if let error = failure() { throw error }
            try FileManager.default.copyItem(at: PhysicalScreenshotSessionTests.picture, to: destination)
        }
    }

    private func makeSession(_ capture: FakeCapture, interval: Duration) -> PhysicalScreenshotSession {
        let session = PhysicalScreenshotSession(hardwareUDID: udid, interval: interval) { destination in
            try await capture.run(destination)
        }
        addTeardownBlock { session.stop() }
        return session
    }

    @discardableResult
    private func eventually(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    func testTheSessionIsViewOnlyAndNamesItsTransport() {
        XCTAssertEqual(MirrorTransport.physicalScreenshots.displayName, "devicectl screenshots (view only)")
        XCTAssertEqual(PhysicalScreenshotSession.minimumInterval, .milliseconds(500))
        let session = makeSession(FakeCapture(), interval: .milliseconds(50))
        XCTAssertEqual(session.transport, .physicalScreenshots)
        XCTAssertEqual(session.viewKind, .screenshots)
        XCTAssertFalse(session.supportsHardwareKeys)
        XCTAssertFalse(session.isRunning)
        session.send(TouchCommand(phase: .down, x: 1, y: 1))
        session.send(contacts: [])
        XCTAssertNil(session.frames.current)
    }

    /// Started but not shown (the window is hidden or the view is gone):
    /// the phone is asked for nothing.
    func testNothingIsCapturedWhileNoViewShowsIt() {
        let capture = FakeCapture()
        let session = makeSession(capture, interval: .milliseconds(20))
        session.start()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(capture.calls, 0)
        XCTAssertTrue(session.isRunning)
    }

    /// Shown: the capture becomes an upright RGBA frame; hidden again: the
    /// captures stop.
    func testAShownSessionPublishesAndAHiddenOneStops() throws {
        let capture = FakeCapture()
        let session = makeSession(capture, interval: .milliseconds(30))
        session.start()
        session.setShown(true)
        XCTAssertTrue(eventually { session.frames.current != nil })
        let frame = try XCTUnwrap(session.frames.current)
        XCTAssertEqual(frame.width, 1206)
        XCTAssertEqual(frame.height, 2622)
        XCTAssertEqual(frame.rotation, 0)
        XCTAssertNil(session.lastError)

        session.setShown(false)
        Thread.sleep(forTimeInterval: 0.15)
        let settled = capture.calls
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(capture.calls, settled, "no capture while no view shows the session")
    }

    /// The floor: instant captures still start at least the interval apart.
    func testCapturesStartNoSoonerThanTheFloorAfterThePreviousStarted() {
        let capture = FakeCapture()
        let session = makeSession(capture, interval: .milliseconds(200))
        let began = ContinuousClock.now
        session.start()
        session.setShown(true)
        // Wait for the captures rather than counting them in a fixed window:
        // a loaded machine delays them, which is not what this pins.
        XCTAssertTrue(Self.wait(until: { capture.calls >= 3 }, timeout: 5), "captures keep coming")
        session.stop()
        let elapsed = began.duration(to: .now)
        // Never faster than the floor allows in the time that really passed.
        XCTAssertLessThanOrEqual(capture.calls, Int(elapsed / .milliseconds(190)) + 1)
        // The fake stamps a start after the session's task hop, so one start
        // can land late and the next on time: the gap between two stamps may
        // be short of the floor by that hop (182 ms measured on a loaded run).
        // Their sum is not, so the floor is pinned over the whole run.
        let starts = capture.starts
        for (earlier, later) in zip(starts, starts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(earlier.duration(to: later), .milliseconds(150))
        }
        if let first = starts.first, let last = starts.last, starts.count > 1 {
            XCTAssertGreaterThanOrEqual(first.duration(to: last), .milliseconds(190) * (starts.count - 1))
        }
    }

    /// One at a time: a capture slower than the floor is never overlapped,
    /// and the next starts as soon as it finished (the pace is the capture's,
    /// not the floor's).
    func testCapturesNeverOverlapAndTheNextStartsWhenThePreviousFinished() {
        let capture = FakeCapture(duration: .milliseconds(120))
        let session = makeSession(capture, interval: .milliseconds(20))
        let began = ContinuousClock.now
        session.start()
        session.setShown(true)
        XCTAssertTrue(
            Self.wait(until: { capture.calls >= 4 }, timeout: 5),
            "the next starts as soon as the previous ends"
        )
        session.stop()
        let elapsed = began.duration(to: .now)
        XCTAssertEqual(capture.maximumRunning, 1, "captures never overlap")
        // One at a time: never more than the 120 ms captures could fit.
        XCTAssertLessThanOrEqual(capture.calls, Int(elapsed / .milliseconds(120)) + 1)
        // The pace is the capture's: consecutive starts about one capture apart,
        // not the 20 ms floor and not a long idle gap.
        let starts = capture.starts
        for (earlier, later) in zip(starts, starts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(earlier.duration(to: later), .milliseconds(115))
        }
    }

    /// The cadence the stage shows is what was measured, never a promised
    /// number.
    func testTheMeasuredCadenceFollowsTheCaptures() throws {
        let capture = FakeCapture(duration: .milliseconds(80))
        let session = makeSession(capture, interval: .milliseconds(20))
        XCTAssertNil(session.measuredInterval)
        session.start()
        session.setShown(true)
        XCTAssertTrue(eventually { capture.calls >= 4 })
        let measured = try XCTUnwrap(session.measuredInterval)
        let starts = capture.starts
        let gaps = zip(starts, starts.dropFirst()).map { $0.duration(to: $1) }
        // Measured, not promised: it is at least one capture long and no
        // longer than the slowest gap that really happened (a fixed ceiling
        // failed on a loaded machine, where every gap was longer).
        XCTAssertGreaterThan(measured, .milliseconds(60))
        XCTAssertLessThanOrEqual(measured, (gaps.max() ?? .zero) + .milliseconds(20))
        XCTAssertNotNil(PhysicalScreenshotSession.cadenceText(measured))
    }

    func testTheCadenceTextIsTheMeasuredOneToOneDecimal() {
        XCTAssertNil(PhysicalScreenshotSession.cadenceText(nil))
        XCTAssertEqual(PhysicalScreenshotSession.cadenceText(.milliseconds(1500), locale: Locale(identifier: "en_US")), "about every 1.5 s")
        XCTAssertEqual(PhysicalScreenshotSession.cadenceText(.milliseconds(1420), locale: Locale(identifier: "en_US")), "about every 1.4 s")
        XCTAssertEqual(PhysicalScreenshotSession.cadenceText(.milliseconds(500), locale: Locale(identifier: "en_US")), "about every 0.5 s")
    }

    /// A failed capture is an error in the session's words; the next
    /// capture is tried and a good one clears it.
    func testAFailedCaptureIsReportedAndTheNextOneIsTried() {
        struct Failure: Error, CustomStringConvertible { var description: String { "the phone is locked" } }
        let failing = Mutex(true)
        let capture = FakeCapture(failure: { failing.withLock { $0 } ? Failure() : nil })
        let session = makeSession(capture, interval: .milliseconds(20))
        session.start()
        session.setShown(true)
        XCTAssertTrue(eventually { session.lastError != nil })
        XCTAssertEqual(session.lastError, "Screenshot failed: the phone is locked")
        XCTAssertTrue(session.isRunning, "a failed capture does not stop the preview")
        failing.withLock { $0 = false }
        XCTAssertTrue(eventually { session.lastError == nil && session.frames.current != nil })
    }

    /// A temporary PNG lives only until its picture is read.
    func testTemporaryPicturesDoNotAccumulate() {
        let capture = FakeCapture()
        let session = makeSession(capture, interval: .milliseconds(20))
        session.start()
        session.setShown(true)
        XCTAssertTrue(eventually { capture.calls >= 3 })
        session.stop()
        // Only this mirror session's own files: a simulator view session running in
        // another test writes pictures with the same prefix meanwhile.
        XCTAssertTrue(eventually {
            capture.destinations.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
        }, "a picture of this mirror session's was left behind")
    }
}
