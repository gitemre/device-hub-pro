import SwiftUI
import DeviceHubProKit

/// Reconciles the workspace's physical view (`PhysicalLiveViewController`)
/// whenever something it depends on changes: the selection, the listed
/// device (its state, transport), the window's visibility, "Show physical
/// Apple devices", the two switches, what a device reported unsupported, and
/// the session itself (a stop from outside restarts nothing the plan does not
/// ask for). Applied once, high in each workspace's own view tree
/// (`ContentView`), beside the window-visibility tracking it reads.
struct PhysicalLiveViewDriver: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace

    private struct Key: Equatable {
        var selection: DeviceSelection?
        var entry: ApplePhysicalEntry?
        var listed: [ApplePhysicalDevice]
        var isWindowVisible: Bool
        /// A recording keeps the capture alive while hidden
        /// (`DeviceWorkspace`'s inputs), so its end must reconcile too.
        var isRecording: Bool
        var showsPhysicalDevices: Bool
        var liveViewOn: Bool
        var autoRefreshOn: Bool
        var screenshotSupported: Bool
        var session: ObjectIdentifier?
    }

    private var key: Key {
        let inventory = model.physicalInventory
        var entry: ApplePhysicalEntry?
        if case .physicalApple(let udid)? = workspace.deviceSelection {
            entry = inventory.entry(udid: udid)
        }
        return Key(
            selection: workspace.deviceSelection,
            entry: entry,
            listed: inventory.entries.map(\.device),
            isWindowVisible: workspace.window.isStageVisible,
            isRecording: workspace.media.isRecording,
            showsPhysicalDevices: inventory.isShowing,
            liveViewOn: model.preferences.physicalLiveViewEnabled,
            autoRefreshOn: model.preferences.physicalAutoRefreshEnabled,
            screenshotSupported: entry.map { model.physicalDevices.isSupported(.screenshot, udid: $0.udid) } ?? true,
            session: workspace.mirror.session.map { ObjectIdentifier($0) }
        )
    }

    func body(content: Content) -> some View {
        content.task(id: key) {
            workspace.physicalLive.reconcile()
        }
    }
}

extension View {
    /// See `PhysicalLiveViewDriver`.
    func drivingPhysicalLiveView() -> some View {
        modifier(PhysicalLiveViewDriver())
    }
}
