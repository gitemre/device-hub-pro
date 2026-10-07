import Foundation

/// Why a Xiaomi phone can show the mirror yet ignore every click.
///
/// MIUI and HyperOS keep a second switch behind "USB debugging": the
/// developer option "USB debugging (Security settings)" (system property
/// `persist.security.adbinput`). While it is `0` the OS refuses the input
/// events the scrcpy server injects: the server prints a `SecurityException`
/// naming `INJECT_EVENTS` on its console and the screen keeps streaming. The
/// switch can turn itself off again; turning it on takes effect at once, no
/// restart of the mirror.
///
/// Both signals are pure functions here: the property values read with
/// `adb -s <serial> shell getprop`, and one line of the server's console.
public enum XiaomiInputBlock {
    /// Property naming the MIUI version (empty off MIUI).
    public static let miuiVersionProperty = "ro.miui.ui.version.name"
    /// Property naming the HyperOS version (empty off HyperOS).
    public static let hyperOSVersionProperty = "ro.mi.os.version.name"
    /// The Security-settings switch: `1` lets the Mac inject input.
    public static let adbInputProperty = "persist.security.adbinput"

    /// The stage line shown while input is blocked.
    public static let bannerText =
        "This Xiaomi phone blocks input from the Mac. Turn on Developer options \u{203A} USB debugging (Security settings) on the phone."

    /// One `adb shell` script that prints the three values, one per line, so
    /// a single adb round trip answers.
    public static let probeScript =
        "getprop \(miuiVersionProperty); getprop \(hyperOSVersionProperty); getprop \(adbInputProperty)"

    /// Whether input is blocked: a MIUI or HyperOS device whose Security
    /// switch reads `0`. An unreadable switch (empty) is not a block, and
    /// neither is any other maker's phone.
    public static func isBlocked(miuiVersion: String?, hyperOSVersion: String?, adbInput: String?) -> Bool {
        guard isXiaomi(miuiVersion: miuiVersion, hyperOSVersion: hyperOSVersion) else { return false }
        return adbInput?.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
    }

    public static func isXiaomi(miuiVersion: String?, hyperOSVersion: String?) -> Bool {
        [miuiVersion, hyperOSVersion].contains { value in
            !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    /// The decision from the output of ``probeScript``: three lines
    /// (MIUI version, HyperOS version, switch), blank when a property is
    /// unset. Nil when the output has fewer than three lines, and for a
    /// Xiaomi phone whose switch reads empty: that is unknown (the property
    /// could not be read), not "input is allowed", so the caller keeps what
    /// it knew.
    public static func isBlocked(probeOutput: String) -> Bool? {
        let lines = probeOutput.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.count >= 3 else { return nil }
        if isXiaomi(miuiVersion: lines[0], hyperOSVersion: lines[1]), lines[2].isEmpty { return nil }
        return isBlocked(miuiVersion: lines[0], hyperOSVersion: lines[1], adbInput: lines[2])
    }

    /// Whether one line of the scrcpy server's console is the refusal of an
    /// injected input event.
    public static func isInjectionDenied(logLine: String) -> Bool {
        logLine.contains("SecurityException") && logLine.contains("INJECT_EVENTS")
    }
}
