import DeviceHubProKit
import SwiftUI

/// What resize mode (Device Hub's "Enter resize mode") offers on the stage
/// of a resizable emulator: one button per display size the emulator's
/// console lists (`resize-display`: phone, unfolded, tablet, desktop), the
/// current one selected, and a Done button that leaves the mode (Esc does
/// too). The emulator resizes to those presets only, so there are no drag
/// handles: a free-form size has nothing to apply to.
struct ResizeModeBar: View {
    @Environment(DeviceWorkspace.self) private var workspace

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "aspectratio")
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .accessibilityHidden(true)
            ForEach(workspace.hardware.resizePresets) { preset in
                presetButton(preset)
            }
            Divider().frame(height: 16)
            Button("Done") { workspace.window.exitResizeMode() }
                .keyboardShortcut(.cancelAction)
                .help("Leave resize mode")
                .accessibilityLabel("Done")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .liquidGlass(in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Resize mode")
    }

    private func presetButton(_ preset: ResizePreset) -> some View {
        let isSelected = workspace.hardware.selectedResizePreset == preset.index
        return Button {
            Task { await workspace.hardware.applyResizePreset(preset) }
        } label: {
            Text(Self.title(for: preset))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(isSelected ? Color.accentColor : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .help("Resize the display to \(preset.name)")
        .accessibilityLabel(Self.title(for: preset))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// The console's preset name, capitalised for display ("phone" →
    /// "Phone").
    static func title(for preset: ResizePreset) -> String {
        preset.name.prefix(1).uppercased() + preset.name.dropFirst()
    }
}
