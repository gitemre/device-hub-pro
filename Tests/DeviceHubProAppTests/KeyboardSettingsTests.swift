import AppKit
import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// Settings ▸ Keyboard: Capture keyboard shortcuts and Secure keyboard entry.
@MainActor
final class KeyboardSettingsTests: XCTestCase {
    /// A key pressed with Command makes a shortcut carrying the other
    /// modifiers; without Command there is none (typing stays text).
    func testOnlyACommandKeyMakesAShortcut() {
        XCTAssertNil(MirrorKeyRouting.shortcut(keyCode: 4, modifiers: []))
        XCTAssertNil(MirrorKeyRouting.shortcut(keyCode: 4, modifiers: [.control, .option]))
        XCTAssertEqual(MirrorKeyRouting.shortcut(keyCode: 4, modifiers: [.command]), KeyShortcut(keyCode: 4))
        XCTAssertEqual(
            MirrorKeyRouting.shortcut(keyCode: 0, modifiers: [.command, .shift, .option]),
            KeyShortcut(keyCode: 0, shift: true, option: true)
        )
        // Text routing still leaves every ⌘ key to the Mac.
        XCTAssertNil(MirrorKeyRouting.command(keyCode: 4, characters: "h", modifiers: [.command]))
    }

    /// Secure input is turned on with the first view that holds it and off
    /// with the last, once each: macOS counts the calls.
    func testSecureInputIsCountedOncePerView() {
        var enabled = 0
        var disabled = 0
        let entry = SecureKeyboardEntry(enable: { enabled += 1 }, disable: { disabled += 1 })
        let first = NSView()
        let second = NSView()
        entry.set(true, for: first)
        entry.set(true, for: first)
        entry.set(true, for: second)
        XCTAssertEqual(enabled, 1)
        XCTAssertTrue(entry.isOn)
        entry.set(false, for: first)
        XCTAssertEqual(disabled, 0, "the second view still holds it")
        entry.set(false, for: second)
        entry.set(false, for: second)
        XCTAssertEqual(disabled, 1)
        XCTAssertFalse(entry.isOn)
    }

    /// Both settings are off on a fresh install and remembered.
    func testBothSettingsAreRemembered() {
        let defaults = UserDefaults.scratch()
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.captureKeyboardShortcuts)
        XCTAssertFalse(preferences.secureKeyboardEntry)
        preferences.setCaptureKeyboardShortcuts(true)
        preferences.setSecureKeyboardEntry(true)
        let again = AppPreferences(defaults: defaults)
        XCTAssertTrue(again.captureKeyboardShortcuts)
        XCTAssertTrue(again.secureKeyboardEntry)
    }
}
