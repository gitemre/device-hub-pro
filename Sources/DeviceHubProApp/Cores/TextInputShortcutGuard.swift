import AppKit

/// Keeps the Device menu's ⌘←, ⌘→, ⌘↑, ⌘↓, ⌘[ and ⌘] (Rotate, Volume, Back,
/// Recents) from stealing caret movement and text shortcuts from a text field
/// or text view that has the focus (the log search, the filters, the shell).
///
/// The main menu's key equivalents run before the focused view sees the key,
/// and SwiftUI offers no way to skip a menu shortcut. A local key monitor sees
/// the event first: when one of those combinations arrives while a text
/// editor is the first responder, it hands the key straight to that editor
/// and swallows it, so the menu never fires.
@MainActor
enum TextInputShortcutGuard {
    /// Key codes of the guarded keys: ← → ↓ ↑ [ ].
    static let guardedKeyCodes: Set<UInt16> = [123, 124, 125, 126, 33, 30]

    /// Whether a key press goes to the focused text editor instead of the
    /// menu: exactly ⌘ (no other modifier) plus a guarded key, while a text
    /// editor has the focus.
    static func defersToTextInput(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        responderIsText: Bool
    ) -> Bool {
        guard responderIsText, guardedKeyCodes.contains(keyCode) else { return false }
        let relevant = modifiers.intersection([.command, .option, .control, .shift])
        // The arrow keys carry the numeric-pad and function flags.
        return relevant == .command
    }

    private static var monitor: Any?

    /// Installs the monitor once.
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let responder = event.window?.firstResponder ?? NSApp.keyWindow?.firstResponder
            guard let text = responder as? NSText,
                  defersToTextInput(keyCode: event.keyCode, modifiers: event.modifierFlags, responderIsText: true)
            else { return event }
            text.keyDown(with: event)
            return nil
        }
    }
}
