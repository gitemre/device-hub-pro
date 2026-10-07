import Foundation
import DeviceHubProKit

/// The Network conditions rows and the App conditions group: which rows show, and
/// the text their rows derive from the readings. Pure, so the gating and
/// the wording are unit-tested without a device.
/// The network conditions rows that follow the switches in the one Network
/// group (emulators only). Speed and latency run `tc` in the guest, which
/// needs root: they show only on a debuggable build, never on a Play Store
/// image or a phone (nothing runs `adb root` to find out).
func networkConditionRows(_ available: ControlsGroupAvailability) -> [ControlsRow] {
    guard available.networkConditions else { return [] }
    var rows: [ControlsRow] = []
    if available.shaping { rows += [.networkSpeed, .connectionLatency] }
    rows += [.meteredMobileData, .resetConditions]
    return rows
}

func conditionsGroups(_ available: ControlsGroupAvailability) -> [ControlsGroup] {
    var groups: [ControlsGroup] = []
    if available.appConditions {
        var rows: [ControlsRow] = [.targetApp]
        if available.lowMemory { rows.append(.lowMemory) }
        rows.append(.killProcess)
        groups.append(ControlsGroup(id: .appConditions, rows: rows))
    }
    return groups
}

// MARK: - Popup options

/// One Target app entry.
struct TargetAppOption: Identifiable, Hashable {
    let package: String
    let isForeground: Bool

    var id: String { package }
    var title: String { isForeground ? "\(package) (foreground)" : package }
}

// MARK: - Row text

enum ConditionsRowText {
    static let speedFootnote =
        "Limits the data path's throughput in both directions with tc inside the device. Needs root: Device Hub Pro runs adb root when you pick a speed (restarting adbd) and unroots on Reset conditions."

    static let latencyFootnote =
        "Adds round-trip latency to all traffic of the data path with tc netem, half in each direction. Needs root, like Speed."

    static let meterFootnote =
        "Off marks mobile data temporarily not metered (TEMPORARILY_NOT_METERED); isActiveNetworkMetered() still says metered."

    static let meterUnavailable = "Readable only while mobile data is connected."

    static let resetFootnote =
        "Speed and latency off, metered, and Wi-Fi and mobile data as they were before Use Mobile Data. Disconnecting or quitting puts back what Device Hub Pro changed."

    static let killFootnote =
        "Ends the app's process only while it is in the background (cached), the way Android reclaims memory. Reopen it from Recents to test state restoration."

    static let lowMemoryFootnote =
        "Asks the app to free memory the way Android does when the device runs low: RUNNING_CRITICAL while it is in the foreground, COMPLETE once it is in the background. Android only accepts a level above the one the app last received."

    /// The caption under Speed: the network the shaping acts on.
    static func speedPathCaption(_ path: DataPath?) -> String {
        switch path {
        case .wifi?: return "Shaping traffic over Wi-Fi"
        case .mobileData?: return "Shaping traffic over mobile data"
        case .noNetwork?: return "No network to shape"
        case .other(let name)?: return "Shaping traffic over \(name)"
        case nil: return "The network that carries the traffic is unknown"
        }
    }

    /// The Connection latency popup's value while no preset matches.
    static func latencyPlaceholder(_ latency: ConnectionLatency?) -> String {
        guard let latency else { return "Unknown" }
        return "Custom · \(latency.rangeLabel)"
    }

    /// The Speed popup's value while no preset matches.
    static func speedPlaceholder(_ reading: ShapingReading?) -> String {
        reading == nil ? "Unknown" : "Custom"
    }

    /// The target's process line under Target app.
    static func processLine(_ snapshot: AppConditionsSnapshot?, apiLevel: Int?) -> String? {
        guard let snapshot else { return nil }
        guard let pid = snapshot.mainPid else {
            if let exit = snapshot.lastExit {
                return "Not running · last exit: \(exit.summary)" + (exit.timestamp.map { " at \($0)" } ?? "")
            }
            return "Not running"
        }
        var parts = ["pid \(pid)"]
        if let process = snapshot.runningProcess {
            if let state = process.procState {
                parts.append(AppProcessState.procStateName(state, apiLevel: apiLevel) ?? "state \(state)")
            }
            if process.isFrozen == true { parts.append("frozen") }
            if let level = process.trimMemoryLevel { parts.append("trim level \(level)") }
        }
        return parts.joined(separator: " · ")
    }
}
