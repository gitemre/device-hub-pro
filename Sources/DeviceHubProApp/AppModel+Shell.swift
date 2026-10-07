import Foundation
import DeviceHubProKit

/// The window shell's model helpers: inspector routing for the toolbar's
/// inspector capsule. Kept beside `AppModel` so the views stay thin.
extension WindowState.InspectorTab {
    /// Info and Apps share Device Hub's Info/Apps inspector (the segmented
    /// control switches between them); Controls and Diagnostics are panels
    /// of their own.
    var isDeviceInfoSurface: Bool {
        self == .info || self == .apps
    }
}

/// The three buttons of the toolbar's inspector capsule (TB-04).
enum InspectorToolbarButton: CaseIterable {
    case controls
    case diagnostics
    case deviceInfo
}

/// Everything `PixelCatalogModel.refresh(from:)` builds the Pixel list from.
/// The refresh is keyed on this value, so it re-runs whenever the skin
/// catalog lands, an AVD is added, removed, renamed or re-skinned, or the
/// device profiles load — and only then.
struct PixelCatalogInputs: Hashable {
    let skins: [SkinCatalogEntry]
    let avds: [String]
    /// Each AVD's resolved skin, in `avds` order via the cards.
    let avdSkins: [String?]
    let avdDevices: [AvdDevice]
}

extension AppModel {
    /// The AVD that Return on a sidebar row starts: a stopped AVD, selected
    /// directly or through its Pixel row. nil for anything running, booting
    /// or not installed (a running device is already live on the stage), and
    /// while the app is busy, like the Start buttons: `startAndMirror` marks
    /// the app busy before its first await but only marks the AVD as
    /// starting after one, so a second Return during a boot would launch the
    /// same AVD twice, or boot another one concurrently.
    func sidebarStartTarget(for selection: DeviceSelection?) -> String? {
        SelectionRouting.sidebarStartTarget(for: selection, isBusy: isBusy, in: liveRoutingSnapshot)
    }

    /// The simulator that Return on its sidebar row starts, as its Start
    /// button would: a selected simulator that is stopped and available,
    /// with no operation in flight (the lifecycle's own busy gate: a second
    /// Return during its boot starts nothing). nil for anything else.
    func sidebarSimulatorStartTarget(for selection: DeviceSelection?) -> String? {
        guard case .simulator(let udid) = selection,
              let entry = simulators.entry(udid: udid),
              entry.isAvailable,
              simulatorLifecycle.operations[udid] == nil,
              simulatorLifecycle.runState(for: entry) == .stopped
        else { return nil }
        return udid
    }
}
