import Foundation

/// A serial the problem report may ask adb about: an emulator's, as
/// `emulator-5554`. A phone's serial (`0A1B2C…`, `192.168.1.5:5555`, an mDNS
/// name) is refused, so no call can reach a phone.
struct EmulatorSerial: Equatable, Sendable {
    let rawValue: String

    init?(_ text: String) {
        let prefix = "emulator-"
        guard text.hasPrefix(prefix) else { return nil }
        let digits = text.dropFirst(prefix.count)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isWholeNumber }) else { return nil }
        rawValue = text
    }
}

/// The only adb argv shapes the problem report ever runs. Each goes through
/// `ProcessRunner.run` directly, never through the app's adb client, whose
/// recovery would restart the server.
enum ProblemReportAdbCall: Equatable, Sendable {
    /// `devices -l`.
    case devices
    /// `-s emulator-N emu avd name`: the AVD's name from the console.
    case consoleAvdName(EmulatorSerial)
    /// `-s emulator-N shell getprop ro.boot.qemu.avd_name`: the name the
    /// guest was given.
    case guestAvdName(EmulatorSerial)
    /// `-s emulator-N shell getprop sys.boot_completed`.
    case bootCompleted(EmulatorSerial)

    var arguments: [String] {
        switch self {
        case .devices:
            return ["devices", "-l"]
        case .consoleAvdName(let serial):
            return ["-s", serial.rawValue, "emu", "avd", "name"]
        case .guestAvdName(let serial):
            return ["-s", serial.rawValue, "shell", "getprop", "ro.boot.qemu.avd_name"]
        case .bootCompleted(let serial):
            return ["-s", serial.rawValue, "shell", "getprop", "sys.boot_completed"]
        }
    }
}
