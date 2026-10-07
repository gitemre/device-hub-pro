import XCTest
@testable import DeviceHubProApp

/// The Logcat view's placeholder mapping (spec §9.3c), including the
/// deliberate-stop state that used to fall through to "No device" because
/// `stopLogcat` clears the serial.
final class LogcatStateTests: XCTestCase {
    private func resolve(
        serial: String? = "emulator-5554",
        wasStopped: Bool = false,
        stopReason: String? = nil,
        isPaused: Bool = false,
        hasStoredEntries: Bool = false,
        hasVisibleEntries: Bool = false
    ) -> LogcatPlaceholder? {
        LogcatPlaceholder.resolve(
            serial: serial,
            wasStopped: wasStopped,
            stopReason: stopReason,
            isPaused: isPaused,
            hasStoredEntries: hasStoredEntries,
            hasVisibleEntries: hasVisibleEntries
        )
    }

    func testNoSerialWithoutADeliberateStopIsNoDevice() {
        XCTAssertEqual(resolve(serial: nil), .noDevice)
    }

    func testDeliberateStopOutranksTheClearedSerial() {
        XCTAssertEqual(resolve(serial: nil, wasStopped: true), .stopped)
    }

    func testVisibleEntriesShowTheList() {
        XCTAssertNil(resolve(hasStoredEntries: true, hasVisibleEntries: true))
    }

    func testDisconnectedStateKeepsItsReason() {
        XCTAssertEqual(
            resolve(serial: "emulator-5554", stopReason: "logcat exited with status 15"),
            .disconnected(reason: "logcat exited with status 15")
        )
    }

    func testStopReasonWinsOverPausedAndFilteredEntries() {
        XCTAssertEqual(
            resolve(stopReason: "adb died", isPaused: true, hasStoredEntries: true),
            .disconnected(reason: "adb died")
        )
    }

    func testPausedWithNothingVisibleIsPaused() {
        XCTAssertEqual(resolve(isPaused: true), .paused)
    }

    /// Paused with entries the filter hides: the panel must not claim that
    /// nothing was captured ("No entries captured yet.").
    func testPausedEntriesHiddenByTheFilterAreNoMatches() {
        XCTAssertEqual(resolve(isPaused: true, hasStoredEntries: true), .noMatches)
    }

    func testStoredEntriesHiddenByTheFilterAreNoMatches() {
        XCTAssertEqual(resolve(hasStoredEntries: true), .noMatches)
    }

    func testNothingAtAllIsNoOutput() {
        XCTAssertEqual(resolve(), .noOutput)
    }

    func testPlaceholderCopyNamesTheStates() {
        XCTAssertEqual(LogcatPlaceholder.noDevice.title, "No device")
        XCTAssertEqual(LogcatPlaceholder.stopped.title, "Log stream stopped")
        XCTAssertEqual(LogcatPlaceholder.noOutput.title, "No log output")
        XCTAssertNotNil(LogcatPlaceholder.stopped.message)
        XCTAssertTrue(LogcatPlaceholder.stopped.systemImage.contains("stop"))
    }

    func testStoppedAndDisconnectedOfferRetryAndLeadWithAPlainSentence() {
        XCTAssertTrue(LogcatPlaceholder.stopped.offersRetry)
        XCTAssertTrue(LogcatPlaceholder.disconnected(reason: "adb died").offersRetry)
        XCTAssertFalse(LogcatPlaceholder.noDevice.offersRetry)
        let message = LogcatPlaceholder.disconnected(reason: "adb died").message ?? ""
        XCTAssertTrue(message.hasPrefix("The device stopped sending its log."))
        XCTAssertTrue(message.hasSuffix("adb died"))
    }
}
