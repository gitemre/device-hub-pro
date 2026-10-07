import AppKit
import SwiftUI

/// Applies `WindowState.staysOnTop` to the main window the view is in, and
/// records that window so the menu can change it later.
struct MainWindowLevelApplier: NSViewRepresentable {
    let workspace: DeviceWorkspace

    func makeNSView(context: Context) -> NSView {
        let view = LevelView()
        view.workspace = workspace
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? LevelView)?.workspace = workspace
    }

    private final class LevelView: NSView {
        var workspace: DeviceWorkspace?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            let workspace = workspace
            MainActor.assumeIsolated {
                guard let workspace else { return }
                workspace.window.mainNSWindow = window
                WindowLevel.apply(onTop: workspace.window.staysOnTop, to: window)
            }
        }
    }
}
