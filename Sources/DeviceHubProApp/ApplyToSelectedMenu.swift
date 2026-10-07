import SwiftUI
import DeviceHubProKit

/// The Selected Devices items: Apply to
/// Selected's actions, Screenshot All Selected and, while a batch runs, its
/// Cancel. In the Device menu, and first in a multi-selected row's context
/// menu. They act on two selected rows or more, one batch at a time.
struct ApplyToSelectedMenuItems: View {
    let model: AppModel?
    /// The window whose multi-selection the items act on.
    let workspace: DeviceWorkspace?
    /// The menu bar's items carry the shortcut; the context menu's repeat
    /// none.
    let showsShortcuts: Bool

    private var enabled: Bool { model?.canActOnSelected(in: workspace) == true }

    var body: some View {
        Menu("Apply to Selected") {
            ApplyProfileMenu(model: model, workspace: workspace)

            Divider()

            Button("Dark Appearance") { run(.appearance(dark: true)) }
            Button("Light Appearance") { run(.appearance(dark: false)) }

            Menu("Text Size") {
                ForEach(BatchTextSize.allCases) { size in
                    Button(size.label) { run(.textSize(size)) }
                }
            }

            Menu("Language") {
                ForEach(BatchLocales.common) { locale in
                    Button(Self.languageTitle(locale)) { run(.language(locale)) }
                }
            }

            // The Location row's saved places (Controls ▸ Location ▸
            // Custom Location…): an emulator or a simulator takes them, a
            // phone reports its own.
            Menu("Location") {
                ForEach(workspace?.location.locationPresets ?? []) { place in
                    Button(place.name) {
                        run(.location(BatchPlace(name: place.name, latitude: place.latitude, longitude: place.longitude)))
                    }
                }
            }
            .disabled(workspace?.location.locationPresets.isEmpty != false)

            Divider()

            Button("Clean Status Bar") { run(.statusBar(clean: true)) }
            Button("Clear Status Bar") { run(.statusBar(clean: false)) }

            Divider()

            Button("Open URL…") {
                Task { await model?.openURLOnSelected(in: workspace) }
            }
            Button("Install Build…") {
                Task { await model?.installBuildOnSelected(in: workspace) }
            }
        }
        .disabled(!enabled)

        screenshotAll

        if let running = model?.multiDevice.runningAction {
            Button("Cancel \(running.title)") {
                model?.multiDevice.cancel()
            }
        }
    }

    @ViewBuilder
    private var screenshotAll: some View {
        let button = Button("Screenshot All Selected") {
            Task { await model?.screenshotAllSelected(in: workspace) }
        }
        .disabled(!enabled)
        if showsShortcuts {
            button.keyboardShortcut("s", modifiers: [.command, .shift, .option])
        } else {
            button
        }
    }

    private func run(_ action: BatchAction) {
        Task { await model?.applyToSelected(action, in: workspace) }
    }

    /// "Turkish (Türkiye)": the language and region in English, as the
    /// menus are.
    /// In its own language ("Deutsch (Deutschland)"), as each device's
    /// Device ▸ Language menu and the Language row name it.
    static func languageTitle(_ locale: DeviceLocale) -> String {
        DeviceLocaleNames.nativeName(locale)
    }
}
