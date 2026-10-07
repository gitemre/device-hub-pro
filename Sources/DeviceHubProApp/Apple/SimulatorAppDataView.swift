import AppKit
import QuickLookUI
import SwiftUI
import DeviceHubProKit

/// The sheet behind App Container ▸ Inspect Data…: Files (the containers'
/// tree with Quick Look, export and delete), Preferences (the UserDefaults
/// plist, editable while the app is not running) and Databases (a read-only
/// SQLite browser). See `SimulatorAppDataController`.
struct SimulatorAppDataView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case files = "Files"
        case preferences = "Preferences"
        case databases = "Databases"
        var id: String { rawValue }
    }

    @State var controller: SimulatorAppDataController
    @State private var tab: Tab = .files
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.app.title).font(.headline)
                    Text(controller.app.bundleIdentifier).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            Group {
                switch tab {
                case .files: AppDataFilesTab(controller: controller, tab: $tab)
                case .preferences: AppDataPreferencesTab(controller: controller)
                case .databases: AppDataDatabasesTab(controller: controller)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 900, height: 600)
        .task { await controller.start() }
        .onDisappear { controller.close() }
    }
}

// MARK: - Files

private struct AppDataFilesTab: View {
    let controller: SimulatorAppDataController
    @Binding var tab: SimulatorAppDataView.Tab
    @State private var pendingDelete: AppDataEntry?

    var body: some View {
        @Bindable var controller = controller
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                Divider()
                if let problem = controller.problem {
                    Text(problem).foregroundStyle(.secondary).padding(20)
                    Spacer()
                } else {
                    table
                }
            }
            .frame(minWidth: 460)
            Divider()
            preview
                .frame(width: 330)
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let entry = pendingDelete { Task { await controller.delete(entry) } }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("It is removed from the simulator's container and cannot be undone. A running app may not expect it to be gone.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if controller.roots.count > 1 {
                Picker("Container", selection: Binding(
                    get: { controller.root },
                    set: { new in if let new { Task { await controller.select(root: new) } } }
                )) {
                    ForEach(controller.roots) { Text($0.title).tag(Optional($0)) }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }
            Button {
                Task { await controller.goUp() }
            } label: { Image(systemName: "chevron.up") }
                .disabled(!controller.canGoUp)
                .help("Enclosing folder")
            Text(pathText)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Task { await controller.reload() }
            } label: { Image(systemName: "arrow.clockwise") }
                .help("Reload")
            Button {
                if let directory = controller.directory { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
            } label: { Image(systemName: "folder") }
                .help("Show in Finder")
        }
        .padding(8)
    }

    private var pathText: String {
        let parts = controller.breadcrumb.map(\.lastPathComponent)
        guard parts.count > 1 else { return "/" }
        return "/" + parts.dropFirst().joined(separator: "/")
    }

    private var table: some View {
        @Bindable var controller = controller
        return Table(controller.entries, selection: $controller.selection) {
            TableColumn("Name") { entry in
                Label(entry.name, systemImage: entry.isDirectory ? "folder" : (entry.isSymbolicLink ? "link" : "doc"))
                    .lineLimit(1)
            }
            TableColumn("Size") { entry in
                Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                    .foregroundStyle(.secondary)
            }
            .width(70)
            TableColumn("Modified") { entry in
                Text(entry.modified?.formatted(date: .abbreviated, time: .shortened) ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(120)
        }
        .contextMenu(forSelectionType: AppDataEntry.ID.self) { ids in
            if let entry = controller.entries.first(where: { ids.contains($0.id) }) {
                Button("Export…") { exportItem(entry) }
                Button("Delete…", role: .destructive) { pendingDelete = entry }
            }
        } primaryAction: { ids in
            if let entry = controller.entries.first(where: { ids.contains($0.id) }) {
                Task { await controller.open(entry) }
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let entry = controller.selectedEntry {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name).font(.headline).lineLimit(2)
                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Export…") { exportItem(entry) }
                        Button("Delete…", role: .destructive) { pendingDelete = entry }
                    }
                    if !entry.isDirectory, AppDataBrowser.isPropertyList(entry.url),
                       entry.url == controller.preferencesURL {
                        Button("Edit as Preferences") { tab = .preferences }
                    }
                    if !entry.isDirectory, AppDataBrowser.isSQLiteDatabase(entry.url) {
                        Button("Browse Database") {
                            Task {
                                await controller.openDatabase(entry.url)
                                tab = .databases
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                Divider()
                if entry.isDirectory || entry.isSymbolicLink {
                    Text(entry.isDirectory ? "Folder" : "Symbolic link")
                        .foregroundStyle(.secondary)
                        .frame(maxHeight: .infinity)
                } else {
                    QuickLookPreview(url: entry.url)
                        .id(entry.url)
                }
            }
        } else {
            Text("Select a file to preview it.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func exportItem(_ entry: AppDataEntry) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose where to copy “\(entry.name)”."
        panel.prompt = "Export"
        if panel.runModal() == .OK, let folder = panel.url {
            Task { await controller.export(entry, to: folder) }
        }
    }
}

/// Quick Look's preview of a file, in the sheet.
private struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

// MARK: - Preferences

private struct AppDataPreferencesTab: View {
    let controller: SimulatorAppDataController
    @State private var selectedKey: String?
    @State private var editKind: PreferenceKind = .string
    @State private var editText = ""
    @State private var newKey = ""
    @State private var newKind: PreferenceKind = .string
    @State private var newText = ""
    @State private var askToTerminate = false

    private static let editableKinds = PreferenceKind.allCases.filter(\.isEditable)

    var body: some View {
        VStack(spacing: 0) {
            if let problem = controller.preferencesProblem, controller.preferences == nil {
                Text(problem).foregroundStyle(.secondary).padding(20)
                Spacer()
            } else {
                Table(controller.preferenceEntries, selection: $selectedKey) {
                    TableColumn("Key") { Text($0.key).lineLimit(1) }
                    TableColumn("Type") { Text($0.kind.rawValue).foregroundStyle(.secondary) }.width(80)
                    TableColumn("Value") { Text($0.text).lineLimit(1).truncationMode(.tail) }
                }
                .onChange(of: selectedKey) { _, key in
                    guard let key, let entry = controller.preferenceEntries.first(where: { $0.key == key }) else { return }
                    editKind = entry.kind.isEditable ? entry.kind : .string
                    editText = entry.text
                }
                Divider()
                editor
            }
            Divider()
            footer
        }
        .confirmationDialog(
            "\(controller.app.title) is running.",
            isPresented: $askToTerminate,
            titleVisibility: .visible
        ) {
            Button("Terminate and Save", role: .destructive) {
                Task { _ = await controller.savePreferences(terminatingIfRunning: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app keeps its own copy of these values and would overwrite the edit. Terminate it, then write the file.")
        }
    }

    @ViewBuilder
    private var editor: some View {
        let entry = controller.preferenceEntries.first { $0.key == selectedKey }
        VStack(alignment: .leading, spacing: 8) {
            if let entry {
                HStack {
                    Text(entry.key).font(.callout.weight(.medium)).lineLimit(1)
                    if entry.kind.isEditable {
                        Picker("", selection: $editKind) {
                            ForEach(Self.editableKinds) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        TextField("Value", text: $editText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { _ = controller.setPreference(key: entry.key, kind: editKind, text: editText) }
                        Button("Set") { _ = controller.setPreference(key: entry.key, kind: editKind, text: editText) }
                    } else {
                        Text("A \(entry.kind.rawValue) can be deleted here, not edited.").foregroundStyle(.secondary)
                        Spacer()
                    }
                    Button("Delete Key", role: .destructive) {
                        controller.removePreference(key: entry.key)
                        selectedKey = nil
                    }
                }
            }
            HStack {
                Text("Add").foregroundStyle(.secondary)
                TextField("Key", text: $newKey).textFieldStyle(.roundedBorder).frame(width: 220)
                Picker("", selection: $newKind) {
                    ForEach(Self.editableKinds) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
                TextField("Value", text: $newText).textFieldStyle(.roundedBorder)
                Button("Add") {
                    if controller.setPreference(key: newKey, kind: newKind, text: newText) {
                        newKey = ""
                        newText = ""
                    }
                }
                .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(10)
    }

    private var footer: some View {
        HStack {
            Text(controller.preferencesDirty
                ? "Edited. Nothing is written until you save; the app is stopped first if it runs."
                : "Changes are written only while the app is not running.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Revert") { Task { await controller.discardPreferenceChanges() } }
                .disabled(!controller.preferencesDirty)
            Button("Save") {
                Task {
                    if await controller.savePreferences(terminatingIfRunning: false) == .appRunning {
                        askToTerminate = true
                    }
                }
            }
            .glassProminentButton()
            .disabled(!controller.preferencesDirty)
        }
        .padding(10)
    }
}

// MARK: - Databases

private struct AppDataDatabasesTab: View {
    let controller: SimulatorAppDataController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Database", selection: Binding(
                    get: { controller.openDatabase },
                    set: { new in if let new { Task { await controller.openDatabase(new) } } }
                )) {
                    if controller.openDatabase == nil { Text("Choose a database").tag(URL?.none) }
                    ForEach(controller.databases, id: \.self) { url in
                        Text(relativeName(url)).tag(Optional(url))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 420)
                Button {
                    Task { await controller.refreshDatabase() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(controller.openDatabase == nil)
                    .help("Take a new copy")
                Spacer()
                Text("Read-only, on a copy: a running app is not disturbed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            Divider()
            if controller.databases.isEmpty {
                Text("No SQLite databases in \(controller.app.title)'s data container.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let problem = controller.databaseProblem, controller.rows == nil {
                Text(problem).foregroundStyle(.secondary).padding(20)
                Spacer()
            } else {
                HStack(spacing: 0) {
                    List(controller.tables, selection: Binding(
                        get: { controller.selectedTable },
                        set: { new in if let new { Task { await controller.showTable(new) } } }
                    )) { table in
                        Label(table.name, systemImage: table.isView ? "eye" : "tablecells").lineLimit(1)
                            .tag(table.name)
                    }
                    .frame(width: 200)
                    Divider()
                    rowsView
                }
            }
        }
    }

    private func relativeName(_ url: URL) -> String {
        guard let root = controller.roots.first?.url else { return url.lastPathComponent }
        let prefix = root.resolvingSymlinksInPath().path + "/"
        let path = url.resolvingSymlinksInPath().path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    @ViewBuilder
    private var rowsView: some View {
        if let rows = controller.rows {
            VStack(spacing: 0) {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(rows.rows.indices, id: \.self) { index in
                                cells(rows.rows[index], bold: false)
                                    .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.04))
                            }
                        } header: {
                            cells(rows.columns, bold: true)
                                .background(.bar)
                        }
                    }
                }
                Divider()
                Text(rows.isTruncated
                    ? "First \(rows.rows.count) of \(rows.totalRows) rows"
                    : "\(rows.totalRows) \(rows.totalRows == 1 ? "row" : "rows")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
        } else {
            Text("Choose a table.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func cells(_ values: [String], bold: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(values.indices, id: \.self) { column in
                Text(values[column])
                    .font(.system(.caption, design: .monospaced).weight(bold ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 160, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .textSelection(.enabled)
            }
        }
    }
}
