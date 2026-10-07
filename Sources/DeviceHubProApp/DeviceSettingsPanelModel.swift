import Foundation
import DeviceHubProKit

/// The Controls inspector's collapsible domain groups, in display order
/// (the order `controlsGroups(_:)` lists them in).
enum ControlsGroupID: String, CaseIterable, Identifiable, Hashable, Sendable {
    case network
    case appConditions
    case power
    case location
    case languageAndTime
    case displayAndSound
    case accessibility
    case debugAndInput
    /// The emulator's Fingerprint touch (the Device menu's Simulate ▸ Fingerprint Touch has the same action).
    case biometrics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .network: return "Network"
        case .power: return "Power & battery"
        case .location: return "Location"
        case .languageAndTime: return "Language & time"
        case .displayAndSound: return "Display & sound"
        case .accessibility: return "Accessibility"
        case .debugAndInput: return "Debug"
        case .appConditions: return "App conditions"
        case .biometrics: return "Biometrics"
        }
    }

    /// The daily groups open; the UI/a11y/QA-pass groups collapsed.
    var defaultExpanded: Bool {
        switch self {
        case .displayAndSound, .accessibility, .debugAndInput, .biometrics: return false
        case .appConditions: return false
        default: return true
        }
    }
}

/// One row inside a group. The view maps each row to its content; this model
/// only orders and gates them. Rows whose presence depends on a live reading
/// (battery, sensor values, hinge angle, outer display) stay listed and are
/// filtered by the view.
enum ControlsRow: Hashable, CaseIterable {
    case wifi
    case bluetooth
    case airplaneMode
    case mobileData
    case dataSaver
    // Network conditions (ConditionsPanelModel.swift), after the switches in the Network group.
    case networkSpeed
    case connectionLatency
    case meteredMobileData
    case resetConditions
    case battery
    case charging
    case batterySaver
    case location
    case appearance
    case textSize
    case reduceMotion
    case showBorders
    case sound
    case talkBack
    case colorFilter
    case increaseContrast
    case showTaps
    case backgroundANRs
    // Biometrics (the emulator's console)
    case fingerprint
    // Language & time
    case deviceLanguage
    case forceRTL
    case dateTime
    case timeZone
    case timeFormat24
    // App conditions (ConditionsPanelModel.swift).
    case targetApp
    case lowMemory
    case killProcess
    // Links (LinksPanelModel.swift)
    case linkURL
    // Clean status bar (StatusBarPanelModel.swift), a plain row at the bottom of the panel
    case cleanStatusBar
    // iOS only (Apple/AppleControlsRows.swift; `ControlsRow.platforms`)
    case liquidGlass
    case reduceTransparency
    case audioOutput
    case audioInput
    // iOS only, in the simulator panel's and the physical panel's groups
    // (Apple/AppleGroupControlsRows.swift): Device Hub Pro's addition below DH's cards.
    case biometricsEnrolled
    case biometricsMatch
    case permissions
    case permissionsAccess
    case pushNotification
    case launchApp
    case terminateApp
    case memoryWarning
    // Data group (simulator) and the panel's last row
    case addRootCertificate
    case resetKeychain
    case resetDefaults
}

/// One flag per probe or gate, mirroring `AppModel`'s `shows*` properties.
struct ControlsGroupAvailability: Equatable {
    // The Network group's four base rows: listed while the device answered the read
    // (a device that does not report one, such as a Wi-Fi-only tablet's mobile data,
    // gets no row instead of a dead switch). True by default for callers with no reading.
    var wifi = true
    var bluetooth = true
    var airplaneMode = true
    var mobileData = true
    var canUseEmulatorControls = false
    var appearance = false
    var textSize = false
    var reduceMotion = false
    var increaseContrast = false
    var showBorders = false
    var talkBack = false
    // Color Filter and Color inversion (`ColorFilterController.shows*Row`).
    var colorFilter = false
    var sound = false
    var forceRTL = false
    var showTaps = false
    var backgroundANRs = false
    /// Fingerprint touch: an emulator with a console port.
    var fingerprint = false
    var dataSaver = false
    // Language & time (`LanguageTimeController.shows*Row`)
    var deviceLanguage = false
    var dateTime = false
    var timeZone = false
    var timeFormat24 = false
    // Network conditions and App conditions (ConditionsPanelModel.swift).
    var networkConditions = false
    /// Speed and Connection latency: a debuggable emulator build (`DeviceConditionsController.showsShaping`).
    var shaping = false
    var appConditions = false
    /// Simulate low memory (`am send-trim-memory`, API 23+).
    var lowMemory = false
    // Link URL (a plain row at the bottom of the panel).
    var links = false
    // Clean status bar (`StatusBarDemoController.showsGroup`)
    var statusBar = false
}

struct ControlsGroup: Equatable, Identifiable {
    let id: ControlsGroupID
    let rows: [ControlsRow]
}

/// The panel's groups in display order. The Network group's base rows are
/// listed only for the readings the device gave; the settings groups appear
/// only while at least one of their rows is available.
/// Rows the device's family cannot work (`ControlsRow.availability(on:)`: a
/// TV's Battery, a watch's Status bar) are left out, and so are the groups
/// that leave empty; before the family is read it is handheld, the class the
/// rows were built for.
func controlsGroups(
    _ available: ControlsGroupAvailability,
    family: ControlsFamily = .androidHandheld
) -> [ControlsGroup] {
    allControlsGroups(available).compactMap { group in
        let rows = family.visible(group.rows)
        return rows.isEmpty ? nil : ControlsGroup(id: group.id, rows: rows)
    }
}

private func allControlsGroups(_ available: ControlsGroupAvailability) -> [ControlsGroup] {
    var groups: [ControlsGroup] = []

    var network: [ControlsRow] = []
    if available.wifi { network.append(.wifi) }
    if available.bluetooth { network.append(.bluetooth) }
    if available.airplaneMode { network.append(.airplaneMode) }
    if available.mobileData { network.append(.mobileData) }
    if available.dataSaver { network.append(.dataSaver) }
    network += networkConditionRows(available)
    groups.append(ControlsGroup(id: .network, rows: network))
    groups += conditionsGroups(available)

    groups.append(ControlsGroup(id: .power, rows: [.battery, .charging, .batterySaver]))

    if available.canUseEmulatorControls {
        groups.append(ControlsGroup(id: .location, rows: [.location]))
    }

    var languageAndTime: [ControlsRow] = []
    if available.deviceLanguage { languageAndTime.append(.deviceLanguage) }
    if available.forceRTL { languageAndTime.append(.forceRTL) }
    if available.dateTime { languageAndTime.append(.dateTime) }
    if available.timeZone { languageAndTime.append(.timeZone) }
    if available.timeFormat24 { languageAndTime.append(.timeFormat24) }
    if !languageAndTime.isEmpty {
        groups.append(ControlsGroup(id: .languageAndTime, rows: languageAndTime))
    }

    var display: [ControlsRow] = []
    if available.appearance { display.append(.appearance) }
    if available.textSize { display.append(.textSize) }
    if available.reduceMotion { display.append(.reduceMotion) }
    if available.showBorders { display.append(.showBorders) }
    if available.sound { display.append(.sound) }
    if !display.isEmpty {
        groups.append(ControlsGroup(id: .displayAndSound, rows: display))
    }

    var accessibility: [ControlsRow] = []
    if available.talkBack { accessibility.append(.talkBack) }
    if available.colorFilter { accessibility.append(.colorFilter) }
    if available.increaseContrast { accessibility.append(.increaseContrast) }
    if !accessibility.isEmpty {
        groups.append(ControlsGroup(id: .accessibility, rows: accessibility))
    }

    var debug: [ControlsRow] = []
    if available.showTaps { debug.append(.showTaps) }
    if available.backgroundANRs { debug.append(.backgroundANRs) }
    if !debug.isEmpty {
        groups.append(ControlsGroup(id: .debugAndInput, rows: debug))
    }

    if available.fingerprint {
        groups.append(ControlsGroup(id: .biometrics, rows: [.fingerprint]))
    }

    return groups
}

/// What the Controls panel shows. The controls act on the mirrored device
/// (`AppModel.activeDeviceSerial`), so without one there is nothing to read
/// or write: the panel says so instead of spinning over inert switches.
enum ControlsPanelContent: Equatable {
    case noDevice
    /// A device is mirrored but its first read has not landed yet.
    case loading
    case ready
}

func controlsPanelContent(activeSerial: String?, controlsLoaded: Bool) -> ControlsPanelContent {
    guard activeSerial != nil else { return .noDevice }
    return controlsLoaded ? .ready : .loading
}

/// The Controls panel's poll: battery level, toggles and the recovery state
/// stay live (an emulator whose battery hits 0 % shuts down by itself). The
/// refresh overlaps its reads, so a 2 s beat is cheap.
enum ControlsPoll {
    static let interval: Duration = .seconds(2)

    /// Calls `refresh` every `interval` until the calling task is cancelled.
    /// A cancellation during the wait ends the loop at once: a refresh run
    /// inside a cancelled task has every adb read terminated at launch and
    /// would write that empty result over the panel.
    static func run(
        every interval: Duration = interval,
        isolation: isolated (any Actor)? = #isolation,
        _ refresh: () async -> Void
    ) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            // The sleep can finish just before a cancellation while the task
            // still waits for its actor; it then returns normally, so check
            // again rather than refresh inside a cancelled task.
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }
}

/// How a developer toggle's row tells the user when its change lands
/// (`DeviceSettingsState.effect(for:)`). Unsupported toggles never get here:
/// their rows are hidden (`AppModel.showsToggle`).
struct ToggleRowStatus: Equatable {
    /// A caption under the row; nil when the switch tells the whole story.
    let caption: String?
    /// Spoken after the switch's on/off value.
    let accessibilityStatus: String?

    static let plain = ToggleRowStatus(caption: nil, accessibilityStatus: nil)
}

func toggleRowStatus(for effect: ToggleEffect?) -> ToggleRowStatus {
    guard let effect, case .afterRestart = effect.support else { return .plain }
    if effect.isPending {
        // The switch shows the stored request; the device still runs with
        // the previous setting until it restarts.
        let note = effect.note ?? "The change applies after the device restarts."
        return ToggleRowStatus(
            caption: "Restart pending: \(note)",
            accessibilityStatus: "restart pending"
        )
    }
    return ToggleRowStatus(
        caption: "Applies after the device restarts.",
        accessibilityStatus: "applies after the device restarts"
    )
}

/// The Battery saver row. Android refuses battery saver while a charger is
/// connected (and turns it off when one is plugged in), so the switch is
/// disabled then and says why (in its help: the Charging row above is the
/// one control for the charger).
struct BatterySaverRowModel: Equatable {
    let value: Bool?
    let isEnabled: Bool
    let caption: String?
    let offersChargingOff: Bool
}

/// - Parameters:
///   - saverEnabled: the effective battery saver reading.
///   - effect: the battery saver effect, for its note.
///   - devicePowered: the battery service's charger flag (any device).
///   - emulatorCharging: the emulator's gRPC charger state, nil on a
///     physical device. It wins over `devicePowered`: it is what the
///     Charging row shows and changes, and it updates at once.
func batterySaverRowModel(
    saverEnabled: Bool?,
    effect: ToggleEffect?,
    devicePowered: Bool?,
    emulatorCharging: Bool?
) -> BatterySaverRowModel {
    guard (emulatorCharging ?? devicePowered) == true else {
        return BatterySaverRowModel(
            value: saverEnabled,
            isEnabled: saverEnabled != nil,
            caption: nil,
            offersChargingOff: false
        )
    }
    return BatterySaverRowModel(
        value: saverEnabled == nil ? nil : false,
        isEnabled: false,
        caption: effect?.note ?? "Battery saver can't turn on while the device is charging.",
        offersChargingOff: emulatorCharging == true
    )
}

/// What the Appearance row's value popup shows for a reading.
struct AppearancePopupModel: Equatable {
    /// Always the three modes, so an unrepresentable device state can be left
    /// from the popup (the `AppearanceProbe` rule).
    let selectableModes: [AppearanceMode]
    /// "Custom" for an answered-but-unmapped token, "Unknown" for an
    /// unreadable one, nil while a mode is selected.
    let placeholderTitle: String?
    let selection: AppearanceMode?
    let help: String
}

func appearancePopupModel(for reading: AppearanceReading?) -> AppearancePopupModel {
    switch reading {
    case .mode(let mode):
        return AppearancePopupModel(
            selectableModes: AppearanceMode.allCases,
            placeholderTitle: nil,
            selection: mode,
            help: ""
        )
    case .unmapped(let raw):
        return AppearancePopupModel(
            selectableModes: AppearanceMode.allCases,
            placeholderTitle: "Custom",
            selection: nil,
            help: "The device is set to \(raw). Choose Light, Dark or System to change it."
        )
    case .unreadable, nil:
        return AppearancePopupModel(
            selectableModes: AppearanceMode.allCases,
            placeholderTitle: "Unknown",
            selection: nil,
            help: ""
        )
    }
}
