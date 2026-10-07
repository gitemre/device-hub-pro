import Foundation
import DeviceHubProKit

/// Words for the user where a tool's own failure text would reach a banner or
/// an alert. The controllers keep the full command line in their messages
/// (tests and logs read it); the two places that show a message to the user
/// (the status banner and the error alert) pass it through here, so no
/// `adb ... failed (1): ...`, `simctl ... failed (...)` or `devicectl ...`
/// command line is ever shown.
enum UserFacingText {
    /// The sentence for a command that needs adb on a Mac without it.
    static let androidToolsMissing = "The Android tools aren\u{2019}t installed."

    /// Whether an error alert about `message` should offer "Set Up Android
    /// Tools\u{2026}" (the missing-tools sentences).
    static func offersAndroidSetup(_ message: String?) -> Bool {
        guard let message else { return false }
        return message == androidToolsMissing || message == EmulatorError.emulatorNotFound.description
    }

    /// `adb -s emulator-5554 shell ... failed (1): cmd: ...` and its
    /// `simctl` / `devicectl` cousins.
    nonisolated(unsafe) private static let toolFailure = try! Regex(
        #"^(adb|simctl|devicectl)\b[^\n]*? failed \(([^)]*)\):?[ ]?(.*)$"#
    ).dotMatchesNewlines()

    static func plain(_ text: String) -> String {
        guard let match = text.firstMatch(of: toolFailure) else { return text }
        let tool = String(match.output[1].substring ?? "")
        let detail = String(match.output[3].substring ?? "")
            .split(whereSeparator: \.isNewline).first
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        // A server that would not start is not the device's error.
        if tool == "adb", AdbServerStartFailure.matches(detail) {
            return "Couldn\u{2019}t start adb. Try again."
        }
        let subject = tool == "adb" ? "The device" : "The simulator"
        return detail.isEmpty ? "\(subject) returned an error." : "\(subject) returned an error: \(detail)"
    }
}
