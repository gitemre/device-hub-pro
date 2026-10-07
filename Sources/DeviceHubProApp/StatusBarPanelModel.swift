import Foundation
import DeviceHubProKit

/// The plain rows at the bottom of the Android Controls panel, after the
/// groups (no disclosure): the Link URL row, then Clean status bar (SystemUI
/// demo mode) where the device takes it.
func controlsTrailingRows(_ available: ControlsGroupAvailability, family: ControlsFamily = .androidHandheld) -> [ControlsRow] {
    var rows: [ControlsRow] = []
    if available.links { rows.append(.linkURL) }
    if available.statusBar { rows.append(.cleanStatusBar) }
    return rows.filter { $0.availability(on: family).isVisible }
}

// MARK: - What Device Hub Pro sent

/// The demo values Device Hub Pro last sent, for the rows Android does not report
/// (the clock and the icons everywhere, the battery before API 33). Cleared
/// when a reading shows demo mode off, and when the device is left.
struct StatusBarDemoSent: Equatable {
    /// The last preset applied; any value-row write clears it.
    var preset: StatusBarPreset?
    var clock: DemoClockTime?
    var batteryLevel: Int?
    var batteryState: BatteryDemoState?
    var wifi: WifiDemoIcon?
    var mobile: MobileDemoIcon?
    /// SystemUI shows notification icons until a command hides them.
    var notificationIconsVisible: Bool?

    /// What entering demo mode with `commands` leaves.
    static func entered(_ commands: [DemoCommand]) -> StatusBarDemoSent {
        var sent = StatusBarDemoSent(notificationIconsVisible: true)
        sent.record(commands)
        return sent
    }

    /// Folds `commands` in, in order.
    mutating func record(_ commands: [DemoCommand]) {
        for command in commands {
            switch command {
            case .enter, .exit:
                break
            case .clock(let time):
                clock = time
            case .battery(let level, let plugged, let powerSave):
                batteryLevel = level
                batteryState = BatteryDemoState.from(
                    plugged: plugged ?? batteryState?.plugged ?? false,
                    powerSave: powerSave ?? batteryState?.powerSave ?? false
                )
            case .wifi(let icon):
                wifi = icon
            case .mobile(let icon):
                mobile = icon
            case .notifications(let visible):
                notificationIconsVisible = visible
            }
        }
    }
}

// MARK: - Popup options

/// The Demo mode switch and its caption.
struct StatusBarDemoModeRowModel: Equatable {
    /// nil (the switch disabled) until the first probe, and while a SystemUI
    /// that reported before does not answer.
    let value: Bool?
    let caption: String
}

/// - Parameters:
///   - hasRecord: Device Hub Pro turned demo mode on here (its restore record).
///   - hasReportedController: SystemUI reported `DemoModeController` earlier
///     this mirror session, so a probe without it means SystemUI did not answer.
///   - isPhysical: a phone, whose maker's status bar may ignore demo mode.
func demoModeRowModel(
    snapshot: StatusBarDemoSnapshot?,
    hasRecord: Bool,
    hasReportedController: Bool,
    isPhysical: Bool
) -> StatusBarDemoModeRowModel {
    let suffix = isPhysical ? StatusBarRowText.phoneSuffix : ""
    guard let snapshot else {
        // The last read failed (the group hides after three).
        return StatusBarDemoModeRowModel(value: nil, caption: StatusBarRowText.readFailed + suffix)
    }
    let value: Bool?
    let caption: String
    if snapshot.controller == nil {
        if hasReportedController {
            value = nil
            caption = StatusBarRowText.noAnswer
        } else {
            value = snapshot.isInDemoMode
            caption = (snapshot.apiLevel ?? 0) < StatusBarDemo.controllerMinimumAPI
                ? StatusBarRowText.unreportedLegacy
                : StatusBarRowText.unreportedSystemUI
        }
    } else {
        value = snapshot.isInDemoMode
        if snapshot.isStuck {
            caption = StatusBarRowText.stuck
        } else if snapshot.isInDemoMode {
            caption = hasRecord ? StatusBarRowText.onByDeviceHubPro : StatusBarRowText.onNotByDeviceHubPro
        } else {
            caption = StatusBarRowText.demoModeOff
        }
    }
    return StatusBarDemoModeRowModel(value: value, caption: caption + suffix)
}

// MARK: - Row text

enum StatusBarRowText {
    // Demo mode
    static let demoModeOff =
        "Freezes the status bar for screenshots: a fixed clock, battery and signal, and no system icons. Apps still see the real time, battery and network. Turning it on applies the Screenshot look."
    static let onByDeviceHubPro =
        "Demo mode is on. Turning it off, disconnecting, Stop or quitting puts back the device's own status bar."
    static let onNotByDeviceHubPro =
        "Demo mode was already on (Developer options ▸ System UI demo mode, or another tool). Turning it off ends it; Device Hub Pro leaves it on when it disconnects."
    static let stuck =
        "Demo mode is on but the device ignores changes to it. Turning it off allows them for a moment to end it."
    static let unreportedLegacy =
        "Android 11 and older do not report demo mode: the switch shows what Device Hub Pro set. Check the stage."
    static let unreportedSystemUI =
        "This device does not report demo mode: the switch shows what Device Hub Pro set. Check the stage."
    static let noAnswer = "The status bar did not answer (it may be restarting)."
    static let readFailed = "The device did not answer the last read."
    static let phoneSuffix = " Some phone makers' status bars ignore demo mode; check the stage."
    static let cleanStatusBarHelp =
        "Shows the store-screenshot status bar, like Developer options ▸ System UI demo mode: 9:41, full Wi-Fi and signal, battery 100% not charging, notification icons hidden where Android supports it (no mobile icon on Android 14 and newer). Android 12 and newer read demo mode back."

    // Status line
    static func enteredMessage(_ preset: StatusBarPreset) -> String {
        "Status bar demo mode on (\(preset.label) preset)"
    }

    static let exitedMessage = "Status bar demo mode off"
    static let staleBatteryMessage = "The battery icon keeps the demo level until the battery next changes."

    /// A failed exit; a record Device Hub Pro keeps is put back at disconnect.
    static func exitFailedMessage(_ error: any Error, keepsRecord: Bool) -> String {
        "\(error)" + (keepsRecord ? " Device Hub Pro tries again when it disconnects." : "")
    }
}
