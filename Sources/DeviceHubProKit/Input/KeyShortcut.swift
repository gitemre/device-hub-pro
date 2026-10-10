/// A Mac key pressed with Command, sent to the device as the same key with the
/// same modifiers: Capture Keyboard Shortcuts, as Xcode 27.1's Device Hub
/// offers it. On an iOS simulator ⌘H goes home and an app's own shortcuts
/// (⌘C, ⌘F, ⌘N, …) reach the app.
public struct KeyShortcut: Sendable, Equatable {
    /// The Mac virtual key code (kVK_*): the key's position.
    public var keyCode: UInt16
    public var shift: Bool
    public var option: Bool
    public var control: Bool

    public init(keyCode: UInt16, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.keyCode = keyCode
        self.shift = shift
        self.option = option
        self.control = control
    }

    /// The shortcuts that stay the Mac's while shortcuts are captured: Quit
    /// (⌘Q), Close (⌘W), Minimize (⌘M), Settings (⌘,), the next window (⌘`)
    /// and Keyboard Capture's own ⌘K, so capture can always be turned off.
    public static let macKeyCodes: Set<UInt16> = [12, 13, 46, 43, 50, 40]

    public var staysOnTheMac: Bool { Self.macKeyCodes.contains(keyCode) }

    /// The simulator's HID press: the key's usage with Command, and the other
    /// modifiers held, around it. Nil for a key the HID table does not know.
    public var simulatorStroke: SimulatorKeyStroke? {
        guard let usage = MacKeyUsage.usage(forKeyCode: keyCode) else { return nil }
        var modifiers = [SimulatorKeyboard.leftCommand]
        if control { modifiers.append(SimulatorKeyboard.leftControl) }
        if option { modifiers.append(SimulatorKeyboard.leftOption) }
        if shift { modifiers.append(SimulatorKeyboard.leftShift) }
        return SimulatorKeyStroke(usage: UInt32(usage), modifiers: modifiers)
    }
}
