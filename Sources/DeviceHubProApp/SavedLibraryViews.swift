import AppKit
import SwiftUI
import DeviceHubProKit

/// A plain-text editor for JSON, arguments and similar: an `NSTextView` with
/// every text substitution off, so `"` stays a straight quote and `--` stays
/// two hyphens (SwiftUI's `TextEditor` keeps smart quotes and dashes on).
struct PlainCodeEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 11
    /// When true Tab / Shift-Tab move focus to the next / previous control
    /// instead of inserting a tab character.
    var tabMovesFocus = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        Self.configure(view, fontSize: fontSize)
        view.delegate = context.coordinator
        view.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }

    /// Every automatic substitution off.
    @MainActor
    static func configure(_ view: NSTextView, fontSize: CGFloat) {
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.smartInsertDeleteEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.textContainerInset = NSSize(width: 2, height: 4)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainCodeEditor

        init(_ parent: PlainCodeEditor) { self.parent = parent }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard parent.tabMovesFocus else { return false }
            switch selector {
            case #selector(NSResponder.insertTab(_:)):
                textView.window?.selectNextKeyView(nil)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(nil)
                return true
            default:
                return false
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}

/// The rounded well the editors sit in.
struct CodeEditorWell: ViewModifier {
    var height: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: DHSheetMetrics.cardRadius, style: .continuous)
                    .fill(Color(nsColor: .quaternarySystemFill))
            )
            .frame(height: height)
    }
}

// MARK: - Saved links

/// The saved-links menu beside the URL field of the Open URL sheets (the
/// simulator's and Android's): choose a link to fill the field, save the
/// field as a named link, or manage the list.
struct SavedLinksControl: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: String
    /// Recently opened links, listed under the saved ones when given (the
    /// Controls URL row keeps one menu for both).
    var recents: [String] = []
    var clearRecents: (() -> Void)?
    @State private var isManaging = false
    @State private var isNaming = false
    @State private var name = ""

    var body: some View {
        let libraries = model.libraries
        Menu {
            let sections = SavedLink.sections(libraries.links.items)
            ForEach(sections.indices, id: \.self) { index in
                let section = sections[index]
                Section(section.group ?? (sections.count > 1 ? "Other" : "Saved links")) {
                    ForEach(section.links) { link in
                        Button(link.name) { draft = link.url }
                            .help(link.url)
                    }
                }
            }
            if let clearRecents, !recents.isEmpty {
                Section("Recent") {
                    ForEach(recents, id: \.self) { link in
                        Button(LinksRowText.recentTitle(link)) { draft = link }
                    }
                    Button("Clear Recents") { clearRecents() }
                }
            }
            if !libraries.links.items.isEmpty || (clearRecents != nil && !recents.isEmpty) { Divider() }
            Button("Save Current as…") {
                name = ""
                isNaming = true
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Manage Saved Links…") { isManaging = true }
        } label: {
            Label("Saved links", systemImage: "bookmark")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Saved links")
        .accessibilityLabel("Saved links")
        .sheet(isPresented: $isManaging) { SavedLinksManageSheet().environment(model) }
        .alert("Save Link", isPresented: $isNaming) {
            TextField("Name", text: $name)
            Button("Save") {
                let url = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                libraries.saveLink(name: name, url: url, group: SavedLink.suggestedGroup(for: url))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The link is kept under this name and grouped by its scheme.")
        }
    }
}

/// Add, edit, duplicate and delete the saved links.
struct SavedLinksManageSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let libraries = model.libraries
        DHSheet(
            title: "Saved Links",
            width: 560,
            cancelTitle: "Done",
            actions: [
                DHSheetAction(title: "Add") {
                    libraries.saveLink(name: "New link", url: "myapp://", group: "myapp")
                },
            ]
        ) {
            if libraries.links.items.isEmpty {
                Text("No saved links yet. Add one here, or type a link in the URL row and choose Save Current as… from its bookmark menu.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(libraries.links.items) { link in
                            SavedLinkRow(link: link)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
    }
}

private struct SavedLinkRow: View {
    @Environment(AppModel.self) private var model
    let link: SavedLink
    @State private var name = ""
    @State private var url = ""
    @State private var group = ""

    var body: some View {
        let libraries = model.libraries
        HStack(spacing: 6) {
            TextField("Name", text: $name).frame(width: 110)
            TextField("URL", text: $url)
            TextField("App (scheme or bundle id)", text: $group).frame(width: 130)
            Button { libraries.duplicateLink(id: link.id) } label: { Image(systemName: "plus.square.on.square") }
                .help("Duplicate")
            Button { libraries.deleteLink(id: link.id) } label: { Image(systemName: "trash") }
                .help("Delete")
        }
        .buttonStyle(.borderless)
        .textFieldStyle(.roundedBorder)
        .onAppear { load() }
        .onChange(of: name) { _, _ in commit() }
        .onChange(of: url) { _, _ in commit() }
        .onChange(of: group) { _, _ in commit() }
    }

    private func load() {
        name = link.name
        url = link.url
        group = link.group ?? ""
    }

    private func commit() {
        var updated = link
        updated.name = name
        updated.url = url
        let trimmed = group.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.group = trimmed.isEmpty ? nil : trimmed
        model.libraries.updateLink(updated)
    }
}
