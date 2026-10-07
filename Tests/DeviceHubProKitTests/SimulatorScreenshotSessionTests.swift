import Synchronization
import XCTest
@testable import DeviceHubProKit

/// `SimulatorScreenshotSession`, the view-only canvas: it captures only
/// while a view shows it, at most once per interval, publishes upright RGBA
/// frames, stops itself when the simulator is gone and drops every input.
///
/// The captures are real: `simctl-io-screenshot.home-screen-loading.png`
/// (1206×2622, iPhone 17 Pro, iOS 27.0, provenance in
/// `SimulatorLifecycleFixtureTests.testTheHomeScreenIsToldFromTheBootScreen`)
/// copied to the destination the session asks for, and the stderr of
/// `simctl io <UDID> recordVideo` on a UDID the set does not hold
/// (`simctl-io-recordVideo-invalid-device.stderr.txt`, exit 148; provenance
/// in `SimctlFixtureTests`), the failure a deleted simulator's capture gets.
final class SimulatorScreenshotSessionTests: XCTestCase {
    private let udid = "00000000-0000-4000-8000-00000000A51A"
    private static let homeScreen = SimctlFixtureTests.url("simctl-core", "simctl-io-screenshot.home-screen-loading.png")

    /// Counts captures and answers each with `answer`.
    private final class FakeCapture: Sendable {
        let count = Mutex(0)
        let answer: Mutex<@Sendable (URL) throws -> Void>

        init(_ answer: @escaping @Sendable (URL) throws -> Void = FakeCapture.copyHomeScreen) {
            self.answer = Mutex(answer)
        }

        static let copyHomeScreen: @Sendable (URL) throws -> Void = { destination in
            try FileManager.default.copyItem(at: SimulatorScreenshotSessionTests.homeScreen, to: destination)
        }

        var calls: Int { count.withLock { $0 } }

        func run(_ destination: URL) throws {
            count.withLock { $0 += 1 }
            try answer.withLock { $0 }(destination)
        }
    }

    private func makeSession(_ capture: FakeCapture, interval: Duration = .milliseconds(50)) -> SimulatorScreenshotSession {
        let session = SimulatorScreenshotSession(udid: udid, interval: interval) { destination in
            try capture.run(destination)
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

    func testTheTransportIsViewOnly() {
        XCTAssertEqual(MirrorTransport.simulatorScreenshots.displayName, "simctl screenshots (view only)")
        let session = makeSession(FakeCapture())
        XCTAssertEqual(session.transport, .simulatorScreenshots)
        XCTAssertFalse(session.supportsHardwareKeys)
        XCTAssertFalse(session.isRunning)
    }

    /// Started but not shown: no capture at all, however long it runs.
    func testNothingIsCapturedWhileNoViewShowsIt() {
        let capture = FakeCapture()
        let session = makeSession(capture)
        session.start()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(capture.calls, 0)
        XCTAssertNil(session.frames.current)
        XCTAssertTrue(session.isRunning)
    }

    /// Shown: the capture becomes an upright RGBA frame of the screenshot's
    /// size, opaque, with the screenshot's pixels.
    func testAShownSessionPublishesTheScreenshot() throws {
        let capture = FakeCapture()
        let session = makeSession(capture)
        session.start()
        session.setShown(true)
        XCTAssertTrue(eventually { session.frames.current != nil })
        let frame = try XCTUnwrap(session.frames.current)
        XCTAssertEqual(frame.width, 1206)
        XCTAssertEqual(frame.height, 2622)
        XCTAssertEqual(frame.rotation, 0)
        XCTAssertEqual(frame.data.count, 1206 * 2622 * 4)
        XCTAssertEqual(frame.data[3], 255, "opaque")
        XCTAssertNil(session.lastError)
    }

    /// The poll keeps to its interval: over 0.5 s at a 200 ms interval, 2–4
    /// captures (the first at once), never one per wake.
    func testCapturesKeepToTheInterval() {
        let capture = FakeCapture()
        let session = makeSession(capture, interval: .milliseconds(200))
        session.start()
        session.setShown(true)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertGreaterThanOrEqual(capture.calls, 2)
        XCTAssertLessThanOrEqual(capture.calls, 4)
    }

    /// Hidden again (the views that showed it went away): the poll stops
    /// capturing until one shows it again.
    func testHidingStopsTheCaptures() {
        let capture = FakeCapture()
        let session = makeSession(capture)
        session.start()
        session.setShown(true)
        session.setShown(true)
        XCTAssertTrue(eventually { capture.calls >= 1 })
        session.setShown(false)
        XCTAssertTrue(session.isShown, "one view still shows it")
        session.setShown(false)
        XCTAssertFalse(session.isShown)
        Thread.sleep(forTimeInterval: 0.15)
        let settled = capture.calls
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(capture.calls, settled, "no capture while hidden")
        session.setShown(true)
        XCTAssertTrue(eventually { capture.calls > settled })
    }

    /// A capture simctl refuses because the simulator is gone stops the
    /// session with the live session's shut-down message.
    func testAGoneSimulatorStopsTheSession() throws {
        let stderr = try SimctlFixtureTests.text("simctl-core", "simctl-io-recordVideo-invalid-device.stderr.txt")
        let failure = SimctlErrors.failure(
            arguments: ["io", udid, "screenshot"],
            exitCode: SimctlErrors.invalidDeviceExitStatus,
            standardError: stderr
        )
        XCTAssertEqual(failure.kind, .invalidDevice)
        let capture = FakeCapture { _ in throw failure }
        let session = makeSession(capture)
        session.start()
        session.setShown(true)
        XCTAssertTrue(eventually { !session.isRunning })
        XCTAssertEqual(session.lastError, SimulatorMirrorSession.shutDownMessage)
        let calls = capture.calls
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(capture.calls, calls, "a stopped session captures nothing more")
    }

    /// Any other failure is reported and the poll goes on; the next good
    /// capture clears it.
    func testOtherFailuresAreReportedAndRetried() {
        let failing = Mutex(true)
        let capture = FakeCapture { destination in
            if failing.withLock({ $0 }) { throw CocoaError(.fileWriteUnknown) }
            try FakeCapture.copyHomeScreen(destination)
        }
        let session = makeSession(capture)
        session.start()
        session.setShown(true)
        XCTAssertTrue(eventually { session.lastError != nil })
        XCTAssertTrue(session.isRunning)
        XCTAssertTrue(session.lastError?.hasPrefix("Simulator screenshot failed") == true)
        failing.withLock { $0 = false }
        XCTAssertTrue(eventually { session.frames.current != nil && session.lastError == nil })
    }

    /// A PNG that cannot be read is a failure, not a frame.
    func testAnUnreadableCaptureIsAFailure() {
        let capture = FakeCapture { destination in
            try Data("not a png".utf8).write(to: destination)
        }
        let session = makeSession(capture)
        session.start()
        session.setShown(true)
        XCTAssertTrue(eventually { session.lastError != nil })
        XCTAssertNil(session.frames.current)
    }

    /// Stop ends the poll, even while it waits for a viewer; a restart
    /// captures again.
    func testStopAndRestart() {
        let capture = FakeCapture()
        let session = makeSession(capture)
        session.start()
        session.stop()
        session.stop()
        XCTAssertFalse(session.isRunning)
        session.setShown(true)
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertEqual(capture.calls, 0)
        session.start()
        XCTAssertTrue(eventually { capture.calls >= 1 })
    }

    /// Resync captures at once (after a rotation), shown or not; the stats
    /// count the published frames.
    func testResyncCapturesNowAndStatsCountIt() async {
        let capture = FakeCapture()
        let session = makeSession(capture, interval: .seconds(60))
        session.start()
        await session.resync()
        XCTAssertEqual(capture.calls, 1)
        XCTAssertNotNil(session.frames.current)
        let stats = await session.stats()
        XCTAssertEqual(stats.totalFrames, 1)
        XCTAssertEqual(stats.fps, 1)
    }

    /// View only: input reaches nothing, and nothing fails for it.
    func testInputIsDropped() {
        let session = makeSession(FakeCapture())
        session.start()
        session.send(TouchCommand(phase: .down, x: 10, y: 10))
        session.send(contacts: [TouchCommand(phase: .up, x: 10, y: 10)])
        session.send(KeyboardCommand.text("a"))
        session.send(HardwareKeyEvent(key: .power, isDown: true))
        XCTAssertNil(session.lastError)
    }
}
