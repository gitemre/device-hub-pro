import Foundation

/// Whether an Android device's screen is on, as `dumpsys power` reports it
/// (`PowerManagerInternal.wakefulnessToString`: Awake, Asleep, Dreaming,
/// Dozing). Captured on an API 35 emulator:
/// `Fixtures/api35-emulator/power/dumpsys-power-wakefulness-*.txt`.
public enum AndroidWakefulness: String, Sendable, Equatable {
    case awake = "Awake"
    case asleep = "Asleep"
    /// The screen saver (Daydream): the screen is lit.
    case dreaming = "Dreaming"
    /// Ambient display on a phone that has it: the screen is off but for the
    /// always-on clock.
    case dozing = "Dozing"

    /// Whether the screen shows the device's UI: Awake or Dreaming.
    public var isScreenOn: Bool { self == .awake || self == .dreaming }

    /// The state in the `mWakefulness=` line of `dumpsys power`; nil when
    /// the text has no such line or names a state this does not know.
    public static func parse(dumpsysPower text: String) -> AndroidWakefulness? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("mWakefulness=") else { continue }
            return AndroidWakefulness(rawValue: String(trimmed.dropFirst("mWakefulness=".count)))
        }
        return nil
    }
}

extension AdbClient {
    /// KEYCODE_WAKEUP: turns the screen on, and does nothing to a screen that
    /// is on (KEYCODE_POWER would turn that one off).
    public static let wakeUpKeyCode = 224

    /// The screen's state, from the one `mWakefulness=` line of `dumpsys
    /// power` (filtered on the device: the whole dump is about 250 KB); nil
    /// when the read fails.
    public func wakefulness(serial: String) async -> AndroidWakefulness? {
        guard let text = try? await shell(serial: serial, ["dumpsys power | grep mWakefulness="]) else { return nil }
        return AndroidWakefulness.parse(dumpsysPower: text)
    }

    /// Turns the screen on with KEYCODE_WAKEUP. With `dismissKeyguard` (an
    /// emulator) the lock screen is dismissed too: a swipe lock goes away, and
    /// a PIN, pattern or password lock shows its entry screen instead, so a
    /// secure lock is never bypassed. A phone keeps its lock screen.
    public func wakeScreen(serial: String, dismissKeyguard: Bool) async throws {
        try await sendKey(serial: serial, keyCode: Self.wakeUpKeyCode)
        if dismissKeyguard {
            _ = try await shell(serial: serial, ["wm", "dismiss-keyguard"])
        }
    }
}
