import AppKit
import XCTest
@testable import DeviceHubProApp

@MainActor
final class TextInputShortcutGuardTests: XCTestCase {
    func testCommandArrowsAndBracketsGoToATextEditor() {
        for code: UInt16 in [123, 124, 125, 126, 33, 30] {
            XCTAssertTrue(TextInputShortcutGuard.defersToTextInput(keyCode: code, modifiers: [.command], responderIsText: true))
            XCTAssertFalse(TextInputShortcutGuard.defersToTextInput(keyCode: code, modifiers: [.command], responderIsText: false))
        }
    }

    func testOtherKeysAndModifierMixesStayWithTheMenu() {
        // ⌘S, ⌥⌘← and ⇧⌘← are not guarded.
        XCTAssertFalse(TextInputShortcutGuard.defersToTextInput(keyCode: 1, modifiers: [.command], responderIsText: true))
        XCTAssertFalse(TextInputShortcutGuard.defersToTextInput(keyCode: 123, modifiers: [.command, .option], responderIsText: true))
        XCTAssertFalse(TextInputShortcutGuard.defersToTextInput(keyCode: 123, modifiers: [.command, .shift], responderIsText: true))
        XCTAssertFalse(TextInputShortcutGuard.defersToTextInput(keyCode: 123, modifiers: [], responderIsText: true))
    }
}
