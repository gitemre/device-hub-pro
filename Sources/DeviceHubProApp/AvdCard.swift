import Foundation
import DeviceHubProKit

/// Which device the center stage shows: an installed AVD by name, a running
/// device by adb serial (physical devices and foreign emulators), a Pixel
/// device from the SDK catalog, addressed by skin name, an Apple simulator
/// by UDID, or a physical Apple device by hardware UDID.
enum DeviceSelection: Hashable, Codable {
    case avd(String)
    case device(String)
    /// A Pixel catalog device. Routes to the matching AVD when one exists,
    /// else to the provisioning screen.
    case pixel(String)
    /// A simulator of the listed set (`SimulatorInventory`), by UDID: stable
    /// across boot and shutdown, and never an adb serial.
    case simulator(String)
    /// A physical iPhone or iPad the user opted in to see
    /// (`ApplePhysicalInventory`), by upper-cased hardware UDID. Manage-only:
    /// it is never an adb serial, an AVD or a simulator, and no path that
    /// reads an adb serial or a simulator UDID accepts it.
    case physicalApple(String)

    /// Whether this is a physical Apple device.
    var isPhysicalApple: Bool {
        if case .physicalApple = self { return true }
        return false
    }

    /// The hardware UDID of a physical Apple selection.
    var physicalAppleUDID: String? {
        if case .physicalApple(let udid) = self { return udid }
        return nil
    }

    /// The reference and kind of an Apple selection (a simulator or a
    /// physical device); nil for anything else, so an adb path that asks
    /// `DeviceRef.adbSerial` of it never gets a serial.
    var appleDeviceRef: (ref: DeviceRef, kind: DeviceKind)? {
        switch self {
        case .simulator(let udid): (.apple(udid), .simulator)
        case .physicalApple(let udid): (.physicalApple(udid), .physical)
        case .avd, .device, .pixel: nil
        }
    }
}

/// One installed AVD as shown in the device gallery: its skin artwork,
/// target and live running state.
struct AvdCard: Hashable, Identifiable, Sendable {
    let name: String
    let displayName: String
    /// Raw target from `<avd>.ini` (`android-35`, …), if known.
    let target: String?
    let skin: ResolvedSkin?
    let isRunning: Bool
    /// adb serial when the AVD is running and visible to adb.
    let serial: String?
    /// Whether the AVD's `config.ini` turns its hardware keyboard on
    /// (`AvdConfig.hardwareKeyboard`; true when it cannot be read, so an
    /// unreadable config offers nothing). Without it the emulator's keys go
    /// nowhere and the mirror presses and types through adb; the stopped
    /// page offers to turn it on.
    var hasHardwareKeyboard = true

    /// The device class of the AVD's system image (`AvdConfig.formFactor`),
    /// for a glyph when the AVD has no skin to say it.
    var formFactor: SystemImage.FormFactor = .handheld

    var id: String { name }

    var targetLabel: String? {
        guard let target else { return nil }
        if target.hasPrefix("android-") {
            return "API " + target.dropFirst("android-".count)
        }
        return target
    }

    /// The OS as the sidebar names it, "Android 16"; the API label when the
    /// level's release is not known. A stopped emulator's title read "API 36"
    /// beside a sidebar row that said "Android 16".
    var osTitle: String? {
        guard let level = apiLevel else { return targetLabel }
        return SystemImage.androidRelease(forAPILevel: level).map { "Android \($0)" } ?? targetLabel
    }

    /// "Android 16 (API 36)", the Info inspector's OS value for a running device.
    var osDetailTitle: String? {
        guard let level = apiLevel, let release = SystemImage.androidRelease(forAPILevel: level) else { return targetLabel }
        return "Android \(release) (API \(level))"
    }

    private var apiLevel: String? {
        guard let target, target.hasPrefix("android-") else { return nil }
        return String(target.dropFirst("android-".count))
    }

    var isFoldable: Bool {
        skin?.isFoldable ?? false
    }

    /// The `ps`-based running pass of the gallery refresh (spec §6.4): flips
    /// only `isRunning` from the parsed emulator names, nothing else.
    func withRunningState(runningAVDNames: Set<String>) -> AvdCard {
        AvdCard(
            name: name,
            displayName: displayName,
            target: target,
            skin: skin,
            isRunning: runningAVDNames.contains(name),
            serial: serial,
            hasHardwareKeyboard: hasHardwareKeyboard,
            formFactor: formFactor
        )
    }
}
