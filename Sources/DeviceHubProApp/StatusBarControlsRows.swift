import SwiftUI
import DeviceHubProKit

/// The Clean status bar row (SystemUI demo mode), in Device Hub's row
/// language: one switch that turns the store-screenshot look on (demo mode
/// with the Screenshot preset) or ends demo mode. The switch shows SystemUI's
/// own answer where Android reports it (`StatusBarDemoController`).
struct StatusBarRowView: View {
    @Environment(DeviceWorkspace.self) private var workspace
    let row: ControlsRow

    private var statusBar: StatusBarDemoController { workspace.conditions.statusBar }

    var body: some View {
        switch row {
        case .cleanStatusBar: cleanStatusBarRow
        default: EmptyView()
        }
    }

    private var cleanStatusBarRow: some View {
        let demoMode = statusBar.demoModeRow
        return VStack(spacing: 0) {
            DHToggleRow(
                title: "Clean status bar",
                glyph: "rectangle.topthird.inset.filled",
                help: dhHelp(StatusBarRowText.demoModeOff, StatusBarRowText.cleanStatusBarHelp),
                value: demoMode.value
            ) { await statusBar.setDemoMode($0) }
            .disabled(statusBar.isWriting)
            // Off, what the switch does is the help; any other state (on by
            // someone else, stuck, unreadable, a phone) stays visible.
            if demoMode.caption != StatusBarRowText.demoModeOff {
                DHCaptionRow(demoMode.caption)
            }
        }
    }
}
