import Foundation

/// Rotation of a physical Android phone through adb, as Android Studio's
/// device mirroring does it: auto-rotate is switched off and the user
/// rotation is pinned to the pose Rotate chose. The two settings the phone
/// had are read once, before the first change, and put back when the mirror
/// of that phone ends (`restore`).
///
/// The pose is in the stage's count of counter-clockwise quarter turns, which
/// is also Android's `Surface.ROTATION_*` (1 is the device turned left).
public enum AndroidPhoneRotation {
    /// `accelerometer_rotation` and `user_rotation` as the phone had them;
    /// nil for a setting the phone has not set (`settings get` prints
    /// `null`).
    public struct Saved: Sendable, Equatable, Codable {
        public var accelerometer: String?
        public var user: String?

        public init(accelerometer: String?, user: String?) {
            self.accelerometer = accelerometer
            self.user = user
        }
    }

    /// The value `settings get` printed, or nil for `null` / empty output.
    static func settingValue(_ output: String) -> String? {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "null" ? nil : value
    }

    /// Reads the two settings; nil when neither could be read at all (the
    /// phone does not answer), so nothing is changed that could not be put
    /// back.
    public static func read(adb: AdbClient, serial: String) async -> Saved? {
        let accelerometer = try? await adb.shell(
            serial: serial, ["settings", "get", "system", "accelerometer_rotation"])
        let user = try? await adb.shell(
            serial: serial, ["settings", "get", "system", "user_rotation"])
        guard accelerometer != nil || user != nil else { return nil }
        return Saved(
            accelerometer: accelerometer.flatMap(settingValue),
            user: user.flatMap(settingValue)
        )
    }

    /// Switches auto-rotate off and pins the user rotation to `turns`
    /// (0...3, any integer is normalized). `cmd window user-rotation lock`
    /// does both in one native call (Android 12+; measured on a
    /// Xiaomi, Android 13: 89 ms, where the two `settings put` calls start a
    /// Java process each, about 180 ms apiece); a phone without it gets the
    /// two settings.
    public static func lock(adb: AdbClient, serial: String, turns: Int) async throws {
        let rotation = ((turns % 4) + 4) % 4
        if let output = try? await adb.shell(
            serial: serial, ["cmd", "window", "user-rotation", "lock", String(rotation)]),
           !output.localizedCaseInsensitiveContains("unknown"),
           !output.localizedCaseInsensitiveContains("error"),
           !output.localizedCaseInsensitiveContains("exception")
        {
            return
        }
        _ = try await adb.shell(
            serial: serial, ["settings", "put", "system", "accelerometer_rotation", "0"])
        _ = try await adb.shell(
            serial: serial, ["settings", "put", "system", "user_rotation", String(rotation)])
    }

    /// Puts the remembered values back: the user rotation first, then
    /// auto-rotate, so a phone whose auto-rotate was on turns to the sensor
    /// with its old user rotation already in place. A setting the phone had
    /// not set is deleted. True when every write was accepted.
    @discardableResult
    public static func restore(adb: AdbClient, serial: String, saved: Saved) async -> Bool {
        var ok = true
        for (name, value) in [("user_rotation", saved.user), ("accelerometer_rotation", saved.accelerometer)] {
            let arguments = value.map { ["settings", "put", "system", name, $0] }
                ?? ["settings", "delete", "system", name]
            if (try? await adb.shell(serial: serial, arguments)) == nil { ok = false }
        }
        return ok
    }
}
