import Foundation

/// What a new window's `WindowGroup(for:)` identity carries: the device its workspace should start on, when one is known (⌘N/⌘T
/// with a selection, "Open in New Window"/"Open in New Tab" on a sidebar
/// row), else nothing — the window opens to whatever the fresh
/// `DeviceWorkspace` starts with (no selection).
///
/// `Codable` because `WindowGroup(for:)` persists and restores scene
/// identity through `NSUserActivity`/state restoration, which requires it;
/// `Hashable` because `WindowGroup(for:)` keys its windows by the value.
///
/// `openWindow(value:)` brings forward a window already presenting an equal
/// value instead of opening another, so every seed carries its own `id`:
/// two empty seeds (⌘N twice) or two for the same device are different
/// windows.
struct WorkspaceSeed: Hashable, Codable, Sendable {
    var selection: DeviceSelection?
    var id: UUID

    init(selection: DeviceSelection? = nil, id: UUID = UUID()) {
        self.selection = selection
        self.id = id
    }
}
