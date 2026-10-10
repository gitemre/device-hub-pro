import XCTest
@testable import DeviceHubProKit

/// `KeyShortcut`: a Mac ⌘ shortcut as the simulator's HID keyboard presses it
/// (Capture Keyboard Shortcuts), and the few the Mac keeps.
final class KeyShortcutTests: XCTestCase {
    /// ⌘H (kVK_ANSI_H, 4) is the H position (usage 0x0B) with Left Command
    /// held around it.
    func testCommandHIsTheHKeyWithCommandHeld() throws {
        let stroke = try XCTUnwrap(KeyShortcut(keyCode: 4).simulatorStroke)
        XCTAssertEqual(stroke, SimulatorKeyStroke(usage: 0x0B, modifiers: [SimulatorKeyboard.leftCommand]))
        XCTAssertEqual(stroke.events, [
            .key(usage: 0xE3, isDown: true),
            .key(usage: 0x0B, isDown: true),
            .key(usage: 0x0B, isDown: false),
            .key(usage: 0xE3, isDown: false),
        ])
    }

    /// The other modifiers are held too, inside Command: ⌃⌥⇧⌘A.
    func testTheOtherModifiersAreHeldToo() throws {
        let stroke = try XCTUnwrap(KeyShortcut(keyCode: 0, shift: true, option: true, control: true).simulatorStroke)
        XCTAssertEqual(stroke.usage, 0x04)
        XCTAssertEqual(stroke.modifiers, [0xE3, 0xE0, 0xE2, 0xE1])
    }

    /// Quit, Close, Minimize, Settings, the next window and Keyboard
    /// Capture's ⌘K stay the Mac's; ⌘H, ⌘C, ⌘Space go to the device.
    func testTheMacKeepsAFewShortcuts() {
        for code: UInt16 in [12, 13, 46, 43, 50, 40] {
            XCTAssertTrue(KeyShortcut(keyCode: code).staysOnTheMac, "key code \(code)")
        }
        for code: UInt16 in [4, 8, 49, 3] {
            XCTAssertFalse(KeyShortcut(keyCode: code).staysOnTheMac, "key code \(code)")
        }
    }

    /// A key the HID table does not know makes no press.
    func testAnUnknownKeyMakesNoStroke() {
        XCTAssertNil(KeyShortcut(keyCode: 0x7F).simulatorStroke)
    }
}
