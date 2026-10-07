import Foundation

/// What to tell the user when the emulator process exits while an AVD starts:
/// a plain sentence for the cause the log names, and the log's last lines
/// (without the INFO chatter) for a "Show Details" disclosure.
///
/// The causes are matched on the emulator's own wording; see the tests for
/// which lines are captures and which are SOURCE-DERIVED.
public struct EmulatorStartFailure: Sendable, Equatable {
    /// The sentence the alert shows.
    public let message: String
    /// The log's last lines worth reading, nil when there are none.
    public let details: String?

    public init(message: String, details: String?) {
        self.message = message
        self.details = details
    }

    /// How many lines the disclosure keeps.
    public static let detailLines = 10
    /// A longer line is cut to its end (the emulator's one-line kernel
    /// command line runs to thousands of characters and ends in the error).
    static let maxLineLength = 240

    /// The failure for `when` ("during startup") with the emulator log's
    /// tail (`EmulatorManager.logTail`, any number of lines).
    public static func exited(_ when: String, logTail: String) -> EmulatorStartFailure {
        let known = knownCause(in: logTail)
        return EmulatorStartFailure(
            message: known ?? "The emulator exited \(when).",
            details: detail(from: logTail)
        )
    }

    /// The plain-words cause when the log names a known one.
    public static func knownCause(in log: String) -> String? {
        let lowered = log.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { lowered.contains($0) } }

        if has("hv_unsupported", "failed to initialize hvf", "hvf error", "whpx", "/dev/kvm", "kvm is required",
               "requires hardware acceleration", "hardware acceleration is not available") {
            return "This Mac can\u{2019}t run Android emulators here: hardware virtualization isn\u{2019}t available (for example inside a virtual machine)."
        }
        if has("not enough space to create userdata", "no space left on device", "not enough disk space",
               "enospc") {
            return "There isn\u{2019}t enough free disk space to start this emulator. Free some space and try again."
        }
        if has("running multiple emulators with the same avd", "is already running", "multiinstance.lock",
               "hardware-qemu.ini.lock", "avd is already in use") {
            return "This emulator is already running, or its lock file is left over from one that was not shut down cleanly. Stop it, or delete the .lock files in its AVD folder, and try again."
        }
        if has("cannot find avd system path", "broken avd system path", "missing a kernel file", "no system image",
               "cannot find system image", "could not find system image", "system image is missing",
               "image.sysdir.1") {
            return "The system image this emulator needs is missing. Download it again from the OS Version menu of the New Emulator sheet, or recreate the emulator."
        }
        if has("vulkan", "vkcreateinstance", "gpu emulation", "could not initialize emulated framebuffer",
               "failed to initialize egl", "eglinitialize") {
            return "The emulator could not start its graphics. Try again; if it keeps failing, update the emulator package and macOS."
        }
        return nil
    }

    /// The last `detailLines` lines worth reading: INFO lines are dropped
    /// unless they carry an error word, and long lines keep their end.
    public static func detail(from log: String) -> String? {
        let keepWords = ["error", "fail", "fatal", "panic", "warning", "cannot", "can't", "unsupported"]
        let kept = log.split(separator: "\n", omittingEmptySubsequences: true).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("INFO") else { return true }
            let lowered = trimmed.lowercased()
            return keepWords.contains { lowered.contains($0) }
        }
        let lines = kept.suffix(detailLines).map { line -> String in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.count > maxLineLength else { return text }
            return "\u{2026}" + text.suffix(maxLineLength)
        }
        let joined = lines.joined(separator: "\n")
        return joined.isEmpty || joined.hasPrefix("(no emulator log") ? nil : joined
    }
}
