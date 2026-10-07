import AppKit
import XCTest
@testable import DeviceHubProApp

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
}
