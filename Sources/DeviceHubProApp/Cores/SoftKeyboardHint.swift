/// The one-time tip about the keyboard's toolbar-only state, shown when Keyboard
/// Capture is turned off while an Android emulator is on the stage. Phones
/// and iOS never get it (nothing there applies).
enum SoftKeyboardHint {
    static let text =
        "Keyboard Capture is off: type with the emulator's own keyboard. "
        + "If the keyboard shows only its toolbar, choose ≡ ▸ Show on-screen keyboard (Alt+K)."

    private static let tooltipSuffix =
        " — keyboard toolbar only? ≡ ▸ Show on-screen keyboard (Alt+K)"

    /// Whether the tip shows now: the user just turned capture OFF, the
    /// device on the stage is an emulator, and it was never shown before.
    static func shouldShow(captureEnabled: Bool, serial: String?, alreadyShown: Bool) -> Bool {
        !captureEnabled && !alreadyShown && isEmulator(serial)
    }

    /// The toolbar toggle's tooltip: the suffix only for an emulator with
    /// capture off.
    static func tooltip(base: String, captureEnabled: Bool, serial: String?) -> String {
        !captureEnabled && isEmulator(serial) ? base + tooltipSuffix : base
    }

    private static func isEmulator(_ serial: String?) -> Bool {
        serial?.hasPrefix("emulator-") == true
    }
}
