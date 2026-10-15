import DeviceHubProKit
import Foundation

/// The window a foldable's 3D model is shown in. A scene's entity tree can
/// sit in one renderer only, and the main window stays alive (hidden) while
/// the compact window shows the same device, so each window has a scene of
/// its own.
enum DeviceModelSurface: Hashable, Sendable {
    case main
    case compact
}

/// One `DeviceModelStageView` instance's hold on a scene. The instance keeps
/// the scene it first asked for for its whole life, and a view that is
/// rebuilt (a new finish, the stage swapping its layout) makes a new lease,
/// so the old view's disappearance cannot stop what the new view started and
/// a stale view cannot take the registry's scene back.
@MainActor
final class DeviceModelLease {
    fileprivate(set) var key: DeviceModelScenes.Key?
    fileprivate(set) var scene: DeviceModelScene?
}

/// Holds the 3D scenes of a workspace's foldable beyond the lifetime of the
/// SwiftUI views that show them.
///
/// Loading a model reads the USDZ file and the lighting environments and
/// compiles the renderer's shaders, which takes hundreds of milliseconds to
/// seconds, and the device was absent from the stage for that long every
/// time its view was made anew (the stage swapping between its layouts, the
/// session restarting on the other panel, the compact window opening). A
/// rebuilt view takes the loaded scene from here and only makes a new
/// renderer for it.
///
/// One scene per window (`DeviceModelSurface`) and per finish: the key
/// changes with the model's file and colour, and a scene no view shows is
/// dropped after `retention` (the compact window's too: closed and opened
/// again within that time, it shows the model at once).
@MainActor
final class DeviceModelScenes {
    struct Key: Hashable {
        var surface: DeviceModelSurface
        var model: AppleDeviceModel
        var color: String
    }

    private final class Entry {
        let key: Key
        let scene: DeviceModelScene
        /// The lease of the view showing the scene now.
        var owner: ObjectIdentifier?
        var eviction: Task<Void, Never>?

        init(key: Key, scene: DeviceModelScene) {
            self.key = key
            self.scene = scene
        }
    }

    private var entries: [DeviceModelSurface: Entry] = [:]

    /// How long a scene no view shows is kept (a view made anew in between
    /// takes it back): long enough for a session to restart on the other
    /// panel, a window to switch, or the compact window to be closed and
    /// opened again with the model still loaded, short enough to free the
    /// panels' textures once the device is gone from the stage.
    static let defaultRetention: Duration = .seconds(20)

    private let retention: Duration

    init(retention: Duration = DeviceModelScenes.defaultRetention) {
        self.retention = retention
    }

    /// The scene `lease` shows: the one it was lent before, else the surface's
    /// scene for `key` (made now when there is none, replacing the scene of
    /// another model or finish).
    func lend(_ key: Key, to lease: DeviceModelLease) -> DeviceModelScene {
        if let scene = lease.scene { return scene }
        let scene: DeviceModelScene
        if let entry = entries[key.surface], entry.key == key {
            scene = entry.scene
        } else {
            if let old = entries[key.surface] {
                old.eviction?.cancel()
                old.scene.stopFeeding()
            }
            let readied = prepared.removeValue(forKey: key)
            prepared = prepared.filter { $0.key.surface != key.surface }
            let entry = Entry(key: key, scene: readied ?? DeviceModelScene())
            entries[key.surface] = entry
            scene = entry.scene
        }
        lease.key = key
        lease.scene = scene
        return scene
    }

    /// Scenes loaded ahead of the view that will show them (`prepare`).
    private var prepared: [Key: DeviceModelScene] = [:]

    /// Loads the scene for `key` while the surface's view still shows the
    /// scene it has, so the next view (a new finish, View ▸ Device Color)
    /// takes it loaded: made anew and loaded then, the device was absent from
    /// the stage for about half a second (2026-10-14). Returns once loaded.
    func prepare(_ key: Key) async {
        if let entry = entries[key.surface], entry.key == key { return }
        let scene = prepared[key] ?? DeviceModelScene()
        prepared[key] = scene
        _ = await scene.load(key.model, color: key.color)
    }

    /// Whether the surface holds `scene`.
    func holds(_ scene: DeviceModelScene, on surface: DeviceModelSurface) -> Bool {
        entries[surface]?.scene === scene
    }

    /// `lease`'s view shows its scene from now on. A scene waiting to be
    /// dropped is kept (and put back when it was dropped meanwhile).
    func claim(_ lease: DeviceModelLease) {
        guard let key = lease.key, let scene = lease.scene else { return }
        if entries[key.surface] == nil { entries[key.surface] = Entry(key: key, scene: scene) }
        guard let entry = entries[key.surface], entry.scene === scene else { return }
        entry.eviction?.cancel()
        entry.eviction = nil
        entry.owner = ObjectIdentifier(lease)
    }

    /// `lease`'s view no longer shows its scene. True when the caller should
    /// stop what it fed to the scene: it was the scene's owner, or the
    /// scene has been replaced. False when another view has taken the scene
    /// over meanwhile (a view made anew appears before or after the old one
    /// disappears), which carries on. A scene left without a view is dropped
    /// after `retention`.
    func release(_ lease: DeviceModelLease) -> Bool {
        guard let key = lease.key, let entry = entries[key.surface], entry.scene === lease.scene else { return true }
        guard entry.owner == ObjectIdentifier(lease) else { return false }
        entry.owner = nil
        entry.eviction?.cancel()
        let surface = key.surface
        let retention = retention
        entry.eviction = Task { @MainActor [weak self, weak entry] in
            try? await Task.sleep(for: retention)
            guard !Task.isCancelled, let self, let entry, entry.owner == nil, self.entries[surface] === entry else { return }
            self.entries[surface] = nil
        }
        return true
    }

    /// Whether any window's view is showing a scene now.
    var isShowing: Bool { entries.values.contains { $0.owner != nil } }

    /// The hinge slider's live angle, to every scene a view shows (the main
    /// window's stays alive behind the compact window).
    func foldLive(toOpening degrees: Double) {
        for entry in entries.values where entry.owner != nil {
            entry.scene.dragFold(toOpening: degrees)
        }
    }

    /// The hinge slider was let go (`DeviceModelScene.hingeDragEnded`).
    func hingeDragEnded() {
        for entry in entries.values where entry.owner != nil {
            entry.scene.hingeDragEnded()
        }
    }

    /// The simulator's lit panel was read after the slider moved the hinge:
    /// every scene faces it again (`DeviceModelScene.litPanelSettled`).
    func litPanelSettled() {
        for entry in entries.values {
            entry.scene.litPanelSettled()
        }
    }
}
