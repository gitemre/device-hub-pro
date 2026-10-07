import AppKit
import XCTest
@testable import DeviceHubProApp

/// Window ▸ Stay on Top: the window level and what is remembered.
final class StayOnTopTests: XCTestCase {
    @MainActor
    func testStayOnTopSetsTheFloatingLevel() {
        XCTAssertEqual(WindowLevel.level(onTop: true), .floating)
        XCTAssertEqual(WindowLevel.level(onTop: false), .normal)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        WindowLevel.apply(onTop: true, to: window)
        XCTAssertEqual(window.level, .floating)
        WindowLevel.apply(onTop: false, to: window)
        XCTAssertEqual(window.level, .normal)
        WindowLevel.apply(onTop: true, to: nil)
    }

    @MainActor
    func testStayOnTopIsRememberedPerWindowKind() throws {
        let suite = "ScaleModesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.stayOnTopMain)
        XCTAssertFalse(preferences.stayOnTopCompact)
        preferences.setStayOnTop(true, compact: true)
        let again = AppPreferences(defaults: defaults)
        XCTAssertTrue(again.stayOnTopCompact)
        XCTAssertFalse(again.stayOnTopMain)
    }
}
