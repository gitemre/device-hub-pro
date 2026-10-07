import AppKit
import SwiftUI
import DeviceHubProKit

/// The main window's shared tab group (the multi-window switch (`DHP_MULTIWINDOW`, on unless 0)
/// only): every main window carries this identifier so `NSWindow`'s
/// automatic tabbing (enabled in `AppDelegate`) offers them as tabs of one
/// another.
enum MultiWindowTabbing {
    static let mainIdentifier = "devicehubpro.main"

    /// ⌘T / "Open in New Tab" (`openWorkspaceTab`): the window each pending
    /// seed's new window joins as a tab, keyed by the seed's `id`. The new
    /// window's binder takes its entry the moment the window exists
    /// (`WorkspaceWindowBinder`), so no polling can miss it.
    @MainActor static var pendingTabParents: [UUID: WeakWindow] = [:]

    @MainActor final class WeakWindow {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }
}

/// Hosts one main window's content: claims a `DeviceWorkspace` for it —
/// `model.workspace` for the first window a session opens
/// (`WorkspaceRegistry.claimInitialWorkspaceIfAvailable`), a fresh one
/// (`DeviceWorkspace(services:context:)`, registered) for every later one —
/// applies `seed`'s device selection when it names one, and installs the
/// window binder that names this workspace's `NSWindow` in the registry
/// (`WorkspaceRegistry.bind`) and asks before closing a window that is
/// recording.
///
/// `SceneBuilder` cannot switch which scenes exist (`DeviceHubProApp.body`), so
/// this host is always the main window's content. With
/// the multi-window switch (`DHP_MULTIWINDOW`, on unless 0) off it is the pre-step-8 single window and
/// nothing more: the one window gets `model.workspace`, and the AppKit
/// binder below — window tabbing, the registry's window map, the
/// close-confirmation delegate — is not installed at all, so the window
/// keeps SwiftUI's own delegate and closes exactly as it did before step 8.
struct MultiWindowContentHost: View {
    @Environment(AppModel.self) private var model
    let seed: WorkspaceSeed
    @State private var workspace: DeviceWorkspace?

    var body: some View {
        Group {
            if let workspace {
                ContentView()
                    .environment(workspace)
                    .background {
                        if model.launchOptions.multiWindowEnabled {
                            WorkspaceWindowBinder(workspace: workspace, seedID: seed.id)
                        }
                    }
            } else {
                // Claimed synchronously in `onAppear` below, the same frame
                // the window's content first renders; this branch is never
                // seen on screen.
                Color.clear
            }
        }
        .onAppear {
            guard workspace == nil else { return }
            guard model.launchOptions.multiWindowEnabled else {
                // One window, one workspace: the flag off never opens a
                // second main window, so this is always `model.workspace`.
                workspace = model.workspace
                return
            }
            let claimed: DeviceWorkspace
            if model.registry.claimInitialWorkspaceIfAvailable() {
                claimed = model.workspace
            } else {
                claimed = DeviceWorkspace(services: model.services)
                model.wireSharedHooks(claimed)
                model.registry.register(claimed)
            }
            if let selection = seed.selection {
                claimed.deviceSelection = selection
            }
            workspace = claimed
        }
    }
}

/// Hosts one compact-mirror window's content: resolves `id`'s workspace
/// (falling back to the focused one, defensively — a `WindowGroup(for:)`
/// scene should always be opened with the id `toggleCompactMirror` passed
/// it) and shows `CompactMirrorView` in that workspace's environment.
struct CompactWorkspaceMirrorHost: View {
    @Environment(AppModel.self) private var model
    let id: WorkspaceID?

    var body: some View {
        if let workspace = id.flatMap({ model.registry.workspace(for: $0) }) ?? model.registry.focused {
            CompactMirrorView()
                .environment(workspace)
        } else {
            Color.clear
        }
    }
}

/// Binds `workspace`'s window into the registry (`activate(_:)`'s Show
/// Window target) and installs the close-confirmation/teardown delegate.
/// AppKit configuration only — draws nothing.
private struct WorkspaceWindowBinder: NSViewRepresentable {
    let workspace: DeviceWorkspace
    /// The window's `WorkspaceSeed.id`: a pending ⌘T parent is keyed by it.
    let seedID: UUID

    func makeCoordinator() -> WorkspaceWindowDelegate {
        WorkspaceWindowDelegate(workspace: workspace)
    }

    func makeNSView(context: Context) -> NSView {
        let view = BinderView()
        let coordinator = context.coordinator
        let workspace = workspace
        let seedID = seedID
        // The first `updateNSView` usually runs before the view is in a
        // window, and SwiftUI need not call it again, so the window is also
        // bound the moment the view joins it.
        view.onWindow = { window in
            Self.bind(window, workspace: workspace, seedID: seedID, coordinator: coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.workspace = workspace
        guard let window = nsView.window else { return }
        Self.bind(window, workspace: workspace, seedID: seedID, coordinator: context.coordinator)
    }

    private static func bind(
        _ window: NSWindow,
        workspace: DeviceWorkspace,
        seedID: UUID,
        coordinator: WorkspaceWindowDelegate
    ) {
        workspace.registry?.bind(window: window, to: workspace.id)
        if window.delegate !== coordinator {
            // A window arrives with SwiftUI's own delegate installed. We
            // take its place for `windowShouldClose`/`windowWillClose` but
            // keep it as `previous`: every other delegate message — the
            // scene bookkeeping SwiftUI does through it — is forwarded
            // unchanged (`forwardingTarget(for:)`), and both messages we do
            // implement are passed on as well.
            coordinator.previous = window.delegate
            window.delegate = coordinator
        }
        window.tabbingIdentifier = MultiWindowTabbing.mainIdentifier
        // ⌘T / Open in New Tab: join the window that asked for this tab.
        if let parent = MultiWindowTabbing.pendingTabParents.removeValue(forKey: seedID)?.window,
           parent !== window, window.tabbedWindows?.contains(parent) != true {
            parent.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        }
    }

    private final class BinderView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

/// The main window's delegate: recording confirmation on
/// close, then teardown-before-unregister (`DeviceWorkspace.closeForWindow`).
@MainActor
final class WorkspaceWindowDelegate: NSObject, NSWindowDelegate {
    var workspace: DeviceWorkspace?
    /// The delegate this one displaced (SwiftUI's own): every message this
    /// class does not implement goes there instead of being dropped.
    nonisolated(unsafe) var previous: NSWindowDelegate?

    init(workspace: DeviceWorkspace) {
        self.workspace = workspace
    }

    override nonisolated func forwardingTarget(for selector: Selector!) -> Any? {
        guard let previous, previous.responds(to: selector) else { return nil }
        return previous
    }

    override nonisolated func responds(to selector: Selector!) -> Bool {
        if super.responds(to: selector) { return true }
        return previous?.responds(to: selector) ?? false
    }

    /// Names this window's workspace as the registry's focused one:
    /// `WorkspaceRegistry.focusedID`'s write applies the
    /// soft session cap's "least recently focused" bookkeeping and moves
    /// in-app audio to this workspace (`DeviceWorkspace.applyAudioPolicy`).
    func windowDidBecomeKey(_ notification: Notification) {
        workspace?.registry?.focusedID = workspace?.id
        previous?.windowDidBecomeKey?(notification)
    }

    /// "Stop recording and save?" while this window's workspace has a live
    /// recording; any other close proceeds without asking. The save itself
    /// is `closeForWindow`'s `.windowClosed` teardown (`windowWillClose`),
    /// which finalizes exactly like the user's own Stop Mirror/Stop
    /// Recording (`.user`) — nothing here saves or discards on its own.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let previous, previous.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))),
           previous.windowShouldClose?(sender) == false {
            return false
        }
        guard let workspace, workspace.media.isRecording else { return true }
        let alert = NSAlert()
        alert.messageText = "Stop recording and save?"
        alert.informativeText = "Closing this window stops the recording in progress."
        alert.addButton(withTitle: "Stop & Save")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Tears the session down (recording finalized, the lifecycle told)
    /// before the workspace leaves the registry — never the reverse.
    func windowWillClose(_ notification: Notification) {
        workspace?.closeForWindow()
        workspace = nil
        previous?.windowWillClose?(notification)
    }
}

/// ⌘T / "Open in New Tab": opens a window for `seed` the same way ⌘N does
/// (`openWindow(value:)`) after recording `keyWindow` as the tab it joins;
/// the new window's binder adds it as a tab the moment the window exists
/// (`MultiWindowTabbing.pendingTabParents`). Without a key window it is just
/// a new window.
@MainActor
func openWorkspaceTab(seed: WorkspaceSeed, keyWindow: NSWindow?, openWindow: OpenWindowAction) {
    if let keyWindow {
        MultiWindowTabbing.pendingTabParents[seed.id] = .init(keyWindow)
    }
    openWindow(value: seed)
}
