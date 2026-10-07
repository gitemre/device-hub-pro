import Foundation
@testable import DeviceHubProKit

/// Which attached devices a live integration test may drive. Emulators are
/// always fair game; a physical phone is somebody's own device, so a test
/// touches it only when `DHP_SCRCPY_SERIAL` names it. Without that
/// opt-in, a phone plugged in for charging (or for their own work)
/// must never be mirrored, typed into, or have its clipboard replaced by a
/// plain `swift test`.
enum LiveTestDevices {
    /// The explicitly pinned serial, if any.
    static var pinnedSerial: String? {
        guard let pinned = ProcessInfo.processInfo.environment["DHP_SCRCPY_SERIAL"],
              !pinned.isEmpty
        else { return nil }
        return pinned
    }

    /// The online devices a test may use: the pinned one alone when a serial
    /// is pinned, otherwise every online emulator and no physical device.
    static func allowed(_ devices: [AndroidDevice]) -> [AndroidDevice] {
        let online = devices.filter(\.isOnline)
        if let pinned = pinnedSerial {
            return online.filter { $0.serial == pinned }
        }
        return online.filter(\.isEmulator)
    }
}
