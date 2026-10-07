import Foundation

/// Which stage panel a device selection shows before the live mirror is
/// available. Device Hub had no unhealthy device to reference, so these
/// states are Android-designed (spec §6.4).
public enum CanvasStatusKind: Equatable, Sendable {
    /// No status panel: live mirror, stopped-AVD hero, physical detail or
    /// the empty view.
    case normal
    /// The emulator is starting; the canvas keeps the skin hero and adds a
    /// progress indicator with `label`.
    case booting(label: String)
    /// A physical device adb sees but cannot reach.
    case unreachable
    /// A physical device waiting for its USB-debugging prompt to be approved.
    case unauthorized
}

/// The pure state→panel mapping behind the canvas status states.
public enum CanvasStatus {
    /// The spec's booting label (§6.4).
    public static let defaultBootingLabel = "Starting…"

    /// Maps a stage selection to its panel. `booting` is the emulator's
    /// start-in-flight signal and wins over the adb state (a starting
    /// emulator often reads `offline` before it comes online). Emulators
    /// otherwise fall through to the AVD detail, which owns the stopped and
    /// externally-started cases; only physical devices get the adb-state
    /// panels.
    public static func resolve(
        device: AndroidDevice?,
        isEmulator: Bool,
        booting: Bool,
        bootingLabel: String = defaultBootingLabel
    ) -> CanvasStatusKind {
        if booting {
            return .booting(label: bootingLabel)
        }
        guard let device, !isEmulator else {
            return .normal
        }
        if device.isOnline {
            return .normal
        }
        return device.state == "unauthorized" ? .unauthorized : .unreachable
    }
}
