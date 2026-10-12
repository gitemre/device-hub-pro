import AppKit
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The error alert's "Show Details" disclosure: closed it adds one line to
/// the alert, open it grows the alert by the details box. With
/// `DHP_RENDER_DIR` set the two states are written as PNGs.
@MainActor
final class ErrorDetailsAlertTests: XCTestCase {
    private func snapshot(_ alert: NSAlert, name: String) throws -> CGFloat {
        alert.layout()
        let window = alert.window
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        if let dir = ProcessInfo.processInfo.environment["DHP_RENDER_DIR"], !dir.isEmpty {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        return window.frame.height
    }

    func testDisclosureGrowsTheAlert() throws {
        let alert = ErrorDetailsAlert.make(
            message: "This Mac can\u{2019}t run Android emulators here: hardware virtualization isn\u{2019}t available (for example inside a virtual machine).",
            details: "INFO    | \u{2026}HVF error: HV_UNSUPPORTED\nqemu-system-aarch64: failed to initialize HVF: Invalid argument\nWARNING | QEMU main loop exits abnormally with code 1"
        )
        let accessory = try XCTUnwrap(alert.accessoryView as? ErrorDetailsAlert.DisclosureAccessory)
        XCTAssertFalse(accessory.isOpen)
        XCTAssertTrue(accessory.scroll.isHidden)
        let closed = try snapshot(alert, name: "error-details-closed")

        accessory.toggle.performClick(nil)
        XCTAssertTrue(accessory.isOpen)
        XCTAssertFalse(accessory.scroll.isHidden)
        let open = try snapshot(alert, name: "error-details-open")
        XCTAssertGreaterThan(open, closed + 80)
    }

    // MARK: - Report…

    /// The alert offers Report… after OK only when the window can show the
    /// Report a Problem sheet.
    func testTheReportButtonFollowsOkOnlyWhenOffered() {
        let offered = ErrorDetailsAlert.make(message: "m", details: "d", offersReport: true)
        XCTAssertEqual(offered.buttons.map(\.title), ["OK", ErrorDetailsAlert.reportButtonTitle])
        XCTAssertEqual(ErrorDetailsAlert.reportButtonTitle, "Report\u{2026}")

        let plain = ErrorDetailsAlert.make(message: "m", details: "d")
        XCTAssertEqual(plain.buttons.map(\.title), ["OK"])
    }

    /// Report… clears the error and hands over the raw message (the alert
    /// shows its plain wording) with the details by line.
    func testReportHandsTheRawErrorOnAndClearsIt() async {
        let status = StatusCenter()
        let raw = "adb -s emulator-5554 shell input tap 1 2 failed (1): cmd: Failure calling service input"
        status.errorMessage = raw
        status.errorDetails = "line one\nline two"
        var received: [ProblemReport.Subject] = []

        ErrorDetailsAlertHost.handle(
            response: .alertSecondButtonReturn,
            center: status,
            message: raw,
            details: "line one\nline two",
            onReport: { received.append($0) }
        )

        XCTAssertNil(status.errorMessage)
        XCTAssertEqual(received.count, 0, "the sheet appears after the alert's sheet ended, one turn later")
        await waitUntil("Report\u{2026} never reached the sheet") { !received.isEmpty }
        XCTAssertEqual(received.first?.message, raw)
        XCTAssertEqual(received.first?.details, ["line one", "line two"])
    }

    /// OK clears the error and reports nothing.
    func testOkClearsTheErrorWithoutReporting() async throws {
        let status = StatusCenter()
        status.errorMessage = "m"
        var reported = false

        ErrorDetailsAlertHost.handle(
            response: .alertFirstButtonReturn,
            center: status,
            message: "m",
            details: "d",
            onReport: { _ in reported = true }
        )

        XCTAssertNil(status.errorMessage)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(reported)
    }

    /// Without a way to show the sheet a second button cannot report, and the
    /// error is still cleared.
    func testWithoutAHandlerTheErrorIsJustCleared() {
        let status = StatusCenter()
        status.errorMessage = "m"

        ErrorDetailsAlertHost.handle(
            response: .alertSecondButtonReturn,
            center: status,
            message: "m",
            details: "d",
            onReport: nil
        )

        XCTAssertNil(status.errorMessage)
    }
}
