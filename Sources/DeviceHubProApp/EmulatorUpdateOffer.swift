import DeviceHubProKit

/// Settings ▸ Emulator's "Update the emulator" row: offered only while the
/// installed emulator streams its screen the slow way (older than 37.2.3)
/// and sdkmanager offers a newer one.
struct EmulatorUpdateOffer: Equatable {
    static let package = "emulator"

    let installed: String
    let available: String
    /// Updating replaces the emulator binaries, so a running emulator blocks it.
    let blockedByRunningEmulator: Bool

    static let blockedCaption = "Shut down running emulators first"

    var title: String { "Update the emulator to \(available)" }

    var caption: String {
        "The emulator \(installed) streams its screen the slow way: Device Hub Pro uses more memory and CPU. \(available) streams it directly."
    }

    /// nil (no row at all) when either version is unknown, the installed one
    /// already streams directly, or the available one is not newer.
    static func make(installed: String?, available: String?, emulatorRunning: Bool) -> EmulatorUpdateOffer? {
        guard let installed, let available,
              !EmulatorVersion.supportsMMAP(installed),
              EmulatorVersion.isOlder(installed, than: available)
        else { return nil }
        return EmulatorUpdateOffer(
            installed: installed,
            available: available,
            blockedByRunningEmulator: emulatorRunning
        )
    }
}
