import SwiftUI

/// Simulator.app's Features ▸ Face ID shortcuts for a matching and a
/// non-matching face, on the Device ▸ Face ID menu's "Authorized with" and
/// "Unauthorized with" items (`devicectl device simulate biometrics`, the
/// mechanism the Controls panel already uses).
///
/// Simulator.app binds ⌥⌘M and ⌥⌘N, but ⌥⌘M is the compact mirror's here, so
/// both carry ⇧ as well; the difference is in the README's shortcut table.
/// Only the menu of the biometric the device type really has gets them (the
/// other two menus are disabled, and one shortcut is never bound twice).
enum BiometricShortcuts {
    static let match = KeyboardShortcut("m", modifiers: [.command, .option, .shift])
    static let nonMatch = KeyboardShortcut("n", modifiers: [.command, .option, .shift])

    /// The shortcut for the menu titled `title` ("Face ID", "Touch ID",
    /// "Optic ID") on a device whose biometric is `deviceType` (nil reads as
    /// Face ID, as the menus do); nil when that menu is not the device's.
    static func shortcut(menu title: String, deviceType: String?, matching: Bool) -> KeyboardShortcut? {
        guard (deviceType ?? "Face ID") == title else { return nil }
        return matching ? match : nonMatch
    }
}
