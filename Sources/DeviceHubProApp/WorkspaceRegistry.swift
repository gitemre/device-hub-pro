import AppKit
import Foundation
import DeviceHubProKit

/// Names one `DeviceWorkspace` (one window) for the app's lifetime.
struct WorkspaceID: Hashable, Codable, Sendable {
    let rawValue: UUID

    init() {
        rawValue = UUID()
    }
}

/// The app's workspaces: which exist, which is focused, and which
/// owns a device. A device has one session at a time, in the workspace that
/// claimed it; the app-wide actions that concern a device (Stop Emulator,
/// Power On, an emulator exiting, the lifecycle's teardown and resume, a
/// simulator listing, a batch write, quit) reach the workspace that owns it
/// (`owner(of:)`), or every workspace.
///
/// Today it has exactly one member, `AppModel.workspace`.
@MainActor
final class WorkspaceRegistry {
    private var members: [WorkspaceID: DeviceWorkspace] = [:]
    /// The members in the order they registered.
    private var order: [WorkspaceID] = []
    /// Which workspace holds each device's session.
    private var claims: [DeviceRef: WorkspaceID] = [:]
    /// The workspace of the key window; nil falls back to the first member.
    /// Recorded into `focusOrder` on every real change, and
    /// applied to every workspace's in-app audio (`applyAudioPolicy`: only
    /// the focused workspace's mirror plays).
    /// Called after a workspace joins (`AppModel` starts its log watch).
    var onRegister: ((DeviceWorkspace) -> Void)?
    /// Called after the focused window changed (`AppModel` re-targets the
    /// soft keyboard).
    var onFocusChange: (() -> Void)?

    var focusedID: WorkspaceID? {
        didSet {
            guard focusedID != oldValue else { return }
            defer { onFocusChange?() }
            if let focusedID {
                focusOrder.removeAll { $0 == focusedID }
                focusOrder.append(focusedID)
            }
            for workspace in workspaces { workspace.applyAudioPolicy() }
        }
    }
    /// The order workspaces became focused, oldest first:
    /// the soft session cap's "least recently focused"
    /// (`leastRecentlyFocused(excluding:)`) reads it.
    private var focusOrder: [WorkspaceID] = []
    /// Each workspace's own `NSWindow`, bound by
    /// `bind(window:to:)` once its `WindowGroup(for:)` scene's content is in
    /// a window; used by `activate(_:)` (Show Window) and cleared when the
    /// workspace unregisters or the window itself is replaced.
    private var windows: [WorkspaceID: NSWindow] = [:]
    /// Brings a workspace's own window forward (the "Shown in another
    /// window" placeholder's Show Window). Falls back to just activating the
    /// app when no window is bound yet (single-window mode, or before the
    /// scene's binder ran), which is the same thing as long as there is only
    /// the one window.
    var activate: (WorkspaceID) -> Void = { _ in
        NSApp.activate(ignoringOtherApps: true)
    }
    /// Whether a scene has already claimed `AppModel.workspace` for its
    /// window: the first `WindowGroup(for: WorkspaceSeed.self)`
    /// scene instance reuses it; every later one gets its own via
    /// `DeviceWorkspace(services:context:)`.
    private var hasClaimedInitialWorkspace = false

    init() {
        activate = { [weak self] id in
            NSApp.activate(ignoringOtherApps: true)
            self?.windows[id]?.makeKeyAndOrderFront(nil)
        }
    }

    /// Names `window` as `id`'s own, so `activate(_:)` can bring it forward.
    /// Re-binding (a scene rebuilding its content) simply replaces the
    /// previous window reference.
    func bind(window: NSWindow, to id: WorkspaceID) {
        windows[id] = window
    }

    /// Forgets `id`'s window (its scene tore down its binder without the
    /// workspace unregistering first — defensive; `unregister` already
    /// clears this for the normal close path).
    func unbind(_ id: WorkspaceID) {
        windows[id] = nil
    }

    /// The window bound to `id`, if any — for callers and tests that need
    /// to know whether one exists without triggering `activate(_:)`'s
    /// side effects (bringing the app and the window forward).
    func boundWindow(for id: WorkspaceID) -> NSWindow? {
        windows[id]
    }

    /// Returns `true` once, for the first caller only: the Scene body's hook
    /// for "the first window reuses `model.workspace`".
    func claimInitialWorkspaceIfAvailable() -> Bool {
        guard !hasClaimedInitialWorkspace else { return false }
        hasClaimedInitialWorkspace = true
        return true
    }

    /// Every workspace, in registration order.
    var workspaces: [DeviceWorkspace] { order.compactMap { members[$0] } }

    /// The key window's workspace, else the first one.
    var focused: DeviceWorkspace? {
        focusedID.flatMap { members[$0] } ?? workspaces.first
    }

    /// The workspace named `id`, if it is still a member (:
    /// the per-workspace compact mirror window resolves its `WorkspaceID`
    /// scene value through this).
    func workspace(for id: WorkspaceID) -> DeviceWorkspace? {
        members[id]
    }

    func register(_ workspace: DeviceWorkspace) {
        guard members[workspace.id] == nil else { return }
        members[workspace.id] = workspace
        order.append(workspace.id)
        workspace.registry = self
        // Joins the hot-plug pump: its own coordinator now
        // decides its own reconnect episode, alongside every other member's.
        workspace.services.inventory.registerLifecycle(workspace.lifecycle, workspace: workspace.id)
        onRegister?(workspace)
    }

    /// Removes `workspace` with its claims (its window closed). Tears its
    /// session down first (a defensive `.replaced`, distinct from the
    /// window-close path's own `.windowClosed` teardown, which already ran
    /// by the time it calls this) so a caller that forgets to stop the
    /// session first never leaves one dangling with no workspace to answer
    /// for it, or its device claimed forever.
    func unregister(_ workspace: DeviceWorkspace) {
        guard members[workspace.id] != nil else { return }
        if workspace.mirror.session != nil {
            workspace.tearDownMirror(cause: .replaced)
        }
        members.removeValue(forKey: workspace.id)
        order.removeAll { $0 == workspace.id }
        claims = claims.filter { $0.value != workspace.id }
        windows[workspace.id] = nil
        focusOrder.removeAll { $0 == workspace.id }
        if focusedID == workspace.id { focusedID = nil }
        workspace.services.inventory.unregisterLifecycle(workspace: workspace.id)
        if workspace.registry === self { workspace.registry = nil }
    }

    // MARK: - Claims

    /// Claims `device` for `workspace`'s session: true when it is free or
    /// already the workspace's, false (nothing changes) when another
    /// workspace holds it.
    @discardableResult
    func claim(_ device: DeviceRef, for workspace: DeviceWorkspace) -> Bool {
        if let holder = claims[device], holder != workspace.id, members[holder] != nil {
            return false
        }
        claims[device] = workspace.id
        return true
    }

    /// Gives `device` up, when `workspace` holds it.
    func release(_ device: DeviceRef, for workspace: DeviceWorkspace) {
        if claims[device] == workspace.id { claims[device] = nil }
    }

    /// The workspace whose session shows `device`: the one that claimed
    /// it, else the one whose context names it.
    func owner(of device: DeviceRef) -> DeviceWorkspace? {
        if let holder = claims[device], let workspace = members[holder] { return workspace }
        return workspaces.first { $0.context.device == device }
    }

    /// The workspace mirroring `avd`'s VM: the owning workspace of its serial when
    /// the AVD card knows it, else the one whose session names the AVD.
    func owner(ofAvd avd: String, serial: String?) -> DeviceWorkspace? {
        if let serial, let owner = owner(of: .android(serial)) { return owner }
        return workspaces.first { $0.context.avdName == avd }
    }

    // MARK: - Soft session cap

    /// Live sessions across every workspace: each whose mirror has an
    /// active session. `DeviceWorkspace.beginMirrorSession` warns, without
    /// blocking, once starting one would make this more than 4.
    var liveSessionCount: Int { workspaces.count { $0.mirror.session != nil } }

    /// The workspace with a live session that was focused longest ago,
    /// excluding `excluding` — the soft session cap's suggested workspace
    /// to stop. A workspace with a live session that never became key
    /// (never focused; only possible for one every session start claims a
    /// device but a window can go straight from launch to a second mirror
    /// before ever gaining focus) sorts first, since it has waited longer
    /// than anything `focusOrder` has seen. Nil when no other workspace has
    /// a session to offer.
    func leastRecentlyFocused(excluding: WorkspaceID) -> DeviceWorkspace? {
        let live = workspaces.filter { $0.id != excluding && $0.mirror.session != nil }
        guard !live.isEmpty else { return nil }
        if let neverFocused = live.first(where: { !focusOrder.contains($0.id) }) {
            return neverFocused
        }
        return live.min {
            (focusOrder.firstIndex(of: $0.id) ?? Int.max) < (focusOrder.firstIndex(of: $1.id) ?? Int.max)
        }
    }
}
