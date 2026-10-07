import SwiftUI
import DeviceHubProKit

/// The one Links row, shared by every device kind: a URL field with the
/// saved-links bookmark menu, the recent-links menu and an Open button, in
/// Device Hub's row language (DHControlRow, DHField). The link is always sent
/// the way a browser click sends it (ACTION_VIEW with BROWSABLE on Android,
/// the system's own resolution on every platform): no handler is chosen.
struct OpenURLRowContent: View {
    @Binding var draft: String
    let recents: [String]
    let clearRecents: () -> Void
    let canOpen: Bool
    let help: String
    let open: () -> Void

    /// One line at every other row's height: the link glyph, the field (its
    /// prompt names the row, so there is no "URL" title taking its width),
    /// one menu with the saved and the recent links, and Open.
    var body: some View {
        DHControlRow(glyph: "link", help: help, alignment: .leading) {
            HStack(spacing: 6) {
                DHField(
                    text: $draft,
                    prompt: "URL or deep link",
                    accessibilityLabel: "Link to open"
                )
                .frame(maxWidth: .infinity)
                .onSubmit {
                    guard canOpen else { return }
                    open()
                }
                SavedLinksControl(draft: $draft, recents: recents, clearRecents: clearRecents)
                Button("Open", action: open)
                    .buttonStyle(.dhPanel)
                    .disabled(!canOpen)
            }
            .padding(.leading, ParityMetrics.controlsLabelGap)
        }
    }
}

/// The Android Links row: the shared URL row over `DeviceLinksController`,
/// with the caption naming what Android did with the link — the activity it
/// started, a reused screen, the chooser, no handler — never what Device Hub Pro
/// sent.
struct LinksRowView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    let row: ControlsRow

    private var links: DeviceLinksController { workspace.links }

    /// The Info read's API level (as the Text Size row uses), else the one
    /// the preview read.
    private var apiLevel: Int? {
        links.apiLevel(
            deviceInfo: workspace.context.serial
                .flatMap { model.inventory.deviceInfos[$0] }
                .flatMap { Int($0.apiLevel) }
        )
    }

    var body: some View {
        switch row {
        case .linkURL: urlRow
        default: EmptyView()
        }
    }

    private var urlRow: some View {
        @Bindable var links = links
        let api = apiLevel
        let validation = links.validation(apiLevel: api)
        let request = links.request(apiLevel: api)
        let canOpen = request != nil && !links.isOpening
        let urlCaption = LinksRowText.urlCaption(
            validation: validation,
            preview: links.preview(for: request),
            previewError: links.previewError(for: request),
            apiLevel: api
        )
        let openCaption = links.openCaption(apiLevel: api)
        return VStack(spacing: 0) {
            OpenURLRowContent(
                draft: $links.draft,
                recents: links.recents.links,
                clearRecents: { links.clearRecents() },
                canOpen: canOpen,
                help: dhHelp(LinksRowText.emptyCaption, LinksRowText.urlHelp),
                open: { Task { await links.open(apiLevel: api) } }
            )
            // Why the draft cannot be sent, or which app opens it; with no
            // draft the row's help says what it does.
            if urlCaption != LinksRowText.emptyCaption {
                DHCaptionRow(urlCaption)
            }
            // What the last Open reported; the idle text is the help.
            if openCaption != LinksRowText.openIdleCaption {
                DHCaptionRow(openCaption)
            }
        }
        .task(id: links.previewKey(apiLevel: api)) {
            // Debounces typing; also runs when the row appears and after an
            // Open or an install.
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            await links.refreshPreview(apiLevel: api)
        }
    }
}
