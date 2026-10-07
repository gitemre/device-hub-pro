import XCTest
@testable import DeviceHubProApp

/// The status line's ownership rules and the busy count, on `StatusCenter`
/// alone: a line is cleared only by the writer that still shows it, and
/// overlapping operations keep the app busy until the last one ends.
@MainActor
final class StatusCenterTests: XCTestCase {
    /// A flash stays up for its 1.8 s and then clears itself, but only while
    /// its own text is still shown: a line written after it survives.
    func testAFlashClearsAfterItsDelayOnlyWhileStillShown() async throws {
        let flashed = StatusCenter()
        let overwritten = StatusCenter()

        flashed.flash("Replay saved")
        overwritten.flash("Launched com.example")
        overwritten.showProgress("Installing app.apk…")
        try await Task.sleep(for: .seconds(1.4))
        XCTAssertEqual(flashed.statusMessage, "Replay saved", "a flash stays up for its delay")

        await waitUntil(timeout: 2, "the flash never cleared") { flashed.statusMessage == nil }
        // Both flashes were due at the same moment; give the other one's
        // clear a beat to run.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(overwritten.statusMessage, "Installing app.apk…", "a flash never clears a newer line")
    }

    /// Two overlapping operations keep the app busy until both have ended,
    /// and an unbalanced end cannot drive the count below zero.
    func testOverlappingBusyOperationsStayBusyUntilBothEnd() {
        let status = StatusCenter()
        XCTAssertFalse(status.isBusy)

        status.beginBusy()
        status.beginBusy()
        status.endBusy()
        XCTAssertTrue(status.isBusy, "the second operation still runs")
        status.endBusy()
        XCTAssertFalse(status.isBusy)

        status.endBusy()
        status.beginBusy()
        XCTAssertTrue(status.isBusy, "an extra end is clamped, not banked against the next begin")
        status.endBusy()
        XCTAssertFalse(status.isBusy)
    }

    /// `clear(ifShowing:)` clears only the line it names: an operation that
    /// ends must not wipe the line another one is using.
    func testClearIfShowingNeverWipesAnotherOperationsLine() {
        let status = StatusCenter()
        status.showProgress("Stopping Pixel_9…")

        status.clear(ifShowing: "Installing app.apk…")
        XCTAssertEqual(status.statusMessage, "Stopping Pixel_9…")
        status.clear(ifShowing: nil)
        XCTAssertEqual(status.statusMessage, "Stopping Pixel_9…", "an operation that showed nothing clears nothing")

        status.clear(ifShowing: "Stopping Pixel_9…")
        XCTAssertNil(status.statusMessage)
    }

    /// The elapsed line appends the seconds once the operation outlasts a
    /// second and clears only a line that still starts with its own text.
    func testTheElapsedTickerAppendsSecondsAndClearsOnlyItsOwnLine() async throws {
        let status = StatusCenter()

        await status.withElapsedStatus("Stopping Pixel_9…") {
            XCTAssertEqual(status.statusMessage, "Stopping Pixel_9…")
            XCTAssertEqual(status.statusKind, .progress)
            await waitUntil(timeout: 3, "the ticker never appended the seconds") {
                status.statusMessage == "Stopping Pixel_9… 1 s"
            }
            XCTAssertEqual(status.statusKind, .progress, "a tick is still progress")
        }
        XCTAssertNil(status.statusMessage, "a ticked line is still its own")

        await status.withElapsedStatus("Stopping Pixel_8…") {
            status.showProgress("Installing app.apk…")
            try? await Task.sleep(for: .milliseconds(1300))
            XCTAssertEqual(status.statusMessage, "Installing app.apk…", "the ticker leaves another line alone")
        }
        XCTAssertEqual(status.statusMessage, "Installing app.apk…", "another operation's line is not cleared")
    }

    // MARK: - Kind

    /// The kind is what the writer states, never read from the text: an
    /// outcome that quotes an APK named with an ellipsis shows no spinner,
    /// and a progress line without an ellipsis still shows one.
    func testTheKindIsTheWritersNotTheTexts() {
        let status = StatusCenter()

        status.showOutcome("Nightly…build.apk installed")
        XCTAssertEqual(status.statusKind, .outcome, "an outcome whose text has an ellipsis")
        status.showProgress("Installing app.apk")
        XCTAssertEqual(status.statusKind, .progress, "a progress line without one")
        status.flash("Device frame unavailable — continuing without it: no skin in …/pixel_9")
        XCTAssertEqual(status.statusKind, .outcome, "a flash is an outcome")
        status.showProgress("Stopping Pixel_9…")
        XCTAssertEqual(status.statusKind, .progress, "the next line brings its own kind")
    }

    /// Clearing takes the line away, whoever wrote it.
    func testClearRemovesAnyLine() {
        let status = StatusCenter()
        status.showProgress("Stopping Pixel_9…")
        status.clear()
        XCTAssertNil(status.statusMessage)
    }
}
