import SwiftUI
import DeviceHubProKit

// The Accessibility group's Color Filter row
// (`ControlsView.rowView` passes each its title). They read and write through
// `controlsPanel.colorFilters` (`ColorFilterController`); what they show comes
// from `ColorFilterRowModels`.

// MARK: - Color Filter

struct ColorFilterRow: View {
    @Environment(DeviceWorkspace.self) private var workspace
    let title: String

    private var colorFilters: ColorFilterController { workspace.controlsPanel.colorFilters }

    private static let help = "Android's Color correction (Settings ▸ Accessibility ▸ Color correction). Writes secure accessibility_display_daltonizer (0 grayscale, 11 protanomaly, 12 deuteranomaly, 13 tritanomaly), then accessibility_display_daltonizer_enabled; None turns only the switch off. Read back from SurfaceFlinger's color matrix on Android 13 and newer, from the settings before."

    var body: some View {
        let readings = colorFilters.readings
        let popup = colorFilterPopupModel(for: readings)
        return VStack(spacing: 0) {
            DHPopupRow(
                title: title,
                glyph: "camera.filters",
                help: popup.help.map { "\(Self.help) \($0)" } ?? Self.help,
                options: ColorFilterOption.allCases,
                selection: popup.selection,
                placeholder: popup.placeholder,
                titleFor: { $0.title },
                valueTitleFor: { $0.shortTitle },
                onSelect: { option in Task { await colorFilters.setColorFilter(option) } }
            )
            .disabled(readings?.setting == nil || colorFilters.isWriting)
            DHCaptionRow(colorFilterCaption(
                readings: readings,
                check: colorFilters.check,
                isEmulator: colorFilters.isEmulator,
                apiLevel: colorFilters.support?.apiLevel
            ))
        }
    }
}
