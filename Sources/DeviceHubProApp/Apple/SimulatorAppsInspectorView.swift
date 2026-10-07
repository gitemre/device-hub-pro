import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DeviceHubProKit

/// A simulator's Apps inspector (Device Hub's S28/S29), in the Android Apps
/// tab's layout and metrics (IN-03): the list card with each app's icon,
/// name, bundle identifier and version, the `+`/`−` footer, and the filter
/// capsule with Device Hub's scope popup. A row's menu launches, terminates
/// and uninstalls (confirmed) the app and shows its data container in the
/// Finder. The list follows the simulator's installed apps
/// (`SimulatorAppsController`); a simulator that is off has none to list.
struct SimulatorAppsInspectorView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(SimulatorActionDialogs.self) private var dialogs
    let udid: String
    @State private var selectedID: String?
    @State private var launchOptionsApp: SimulatorApp?
    /// The app whose data the inspector sheet shows.
    @State private var inspectedApp: SimulatorApp?
    @FocusState private var isListFocused: Bool
    @FocusState private var isFilterFocused: Bool

    /// The list reloads when the simulator changes or starts.
    private struct LoadKey: Equatable {
        let udid: String
        let isBooted: Bool
        /// A just-booted simulator is listed only once it answers.
        let isReady: Bool
    }

    var body: some View {
        let entry = model.simulators.entry(udid: udid)
        let isBooted = entry?.state == .booted
        let isReady = isBooted && model.simulatorLifecycle.isReady(udid)
        Group {
            if isBooted {
                appsPanel
            } else {
                DHAppsEmptyState(caption: "Start the simulator to add or customize apps.")
            }
        }
        .task(id: LoadKey(udid: udid, isBooted: isBooted, isReady: isReady)) {
            selectedID = nil
            if isReady {
                await workspace.simulatorApps.load(udid: udid)
            } else {
                workspace.simulatorApps.clear()
            }
        }
        .onDisappear {
            workspace.simulatorApps.clear()
        }
        .sheet(item: $launchOptionsApp) { app in
            LaunchOptionsSheet(app: app, udid: udid)
                .environment(model)
                .environment(workspace)
        }
        .sheet(item: $inspectedApp) { app in
            if let inspector = workspace.simulatorApps.makeDataInspector(for: app, udid: udid) {
                SimulatorAppDataView(controller: inspector)
            }
        }
    }

    private var appsPanel: some View {
        @Bindable var controller = workspace.simulatorApps
        let apps = controller.appsUDID == udid ? controller.filteredApps : []
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if controller.isLoading && controller.apps.isEmpty {
                                ProgressView()
                                    .padding(.vertical, 20)
                            } else if let problem = controller.loadProblem, controller.apps.isEmpty {
                                Text(problem)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(20)
                            } else if apps.isEmpty {
                                let unfiltered = controller.filter.trimmingCharacters(in: .whitespaces).isEmpty
                                AppsEmptyState(
                                    message: unfiltered ? controller.scope.emptyLabel : "No Results",
                                    showAll: unfiltered && controller.scope != .all
                                        ? { controller.scope = .all }
                                        : nil
                                )
                            } else {
                                ForEach(apps) { app in
                                    SimulatorAppRow(app: app, isSelected: selectedID == app.id)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            if NSApp.currentEvent?.clickCount == 2 {
                                                selectedID = app.id
                                                Task { await controller.launch(app, udid: udid) }
                                            } else {
                                                selectedID = selectedID == app.id ? nil : app.id
                                            }
                                            isListFocused = true
                                        }
                                        .selectsOnSecondaryClick { selectedID = app.id; isListFocused = true }
                                        .contextMenu { appMenu(for: app) }
                                        .accessibilityElement(children: .combine)
                                        .accessibilityAddTraits(selectedID == app.id ? [.isButton, .isSelected] : .isButton)
                                        .accessibilityAction {
                                            selectedID = selectedID == app.id ? nil : app.id
                                        }
                                        .accessibilityAction(named: Text("Launch")) {
                                            Task { await controller.launch(app, udid: udid) }
                                        }
                                    InspectorDivider(
                                        leadingInset: ParityMetrics.inspectorAppsTextInset,
                                        trailingInset: ParityMetrics.inspectorAppsDividerTrailingInset
                                    )
                                }
                            }
                        }
                        // The rows keep the card's width; the scroll view
                        // itself runs on to the column's edge, where
                        // Device Hub's overlay scroller sits (outside the
                        // card, measured 2026-09-29).
                        .padding(.trailing, ParityMetrics.inspectorCardInset)
                    }
                    .padding(.trailing, -ParityMetrics.inspectorCardInset)
                    // The card's rounded top corners still clip the rows; the
                    // mask spans the whole scroll view, so the scroller past
                    // the card's right edge is not cut off.
                    .mask(alignment: .leading) {
                        UnevenRoundedRectangle(
                            topLeadingRadius: ParityMetrics.inspectorCardRadius,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0,
                            topTrailingRadius: 0,
                            style: .continuous
                        )
                    }
                    .focusable()
                    .focused($isListFocused)
                    .focusEffectDisabled()
                    .onMoveCommand { direction in
                        moveSelection(direction, in: apps, proxy: proxy)
                    }
                    .onKeyActivation([.return]) {
                        guard let app = selectedApp(in: apps) else { return .ignored }
                        Task { await controller.launch(app, udid: udid) }
                        return .handled
                    }
                    .onDeleteCommand {
                        if let app = selectedApp(in: apps), app.isRemovable {
                            dialogs.requestUninstall(app, udid: udid)
                        }
                    }
                }

                // Device Hub's +/− footer: install an app, uninstall the
                // selected one (confirmed).
                InspectorDivider(leadingInset: 0, trailingInset: 0)
                InspectorActionFooter(
                    isAddingEnabled: true,
                    isRemovingEnabled: selectedApp(in: apps)?.isRemovable == true,
                    isBusy: controller.isBusy,
                    isInstalling: controller.activity.map { if case .installing = $0 { true } else { false } } ?? false,
                    addLabel: "Install App",
                    removeLabel: "Uninstall App",
                    add: chooseAndInstall,
                    remove: {
                        if let app = selectedApp(in: apps) {
                            dialogs.requestUninstall(app, udid: udid)
                        }
                    }
                )
            }
            .background(
                Color.primary.opacity(ParityMetrics.inspectorCardFillOpacity),
                in: listCardShape
            )
            .padding(.horizontal, ParityMetrics.inspectorCardInset)

            Divider()

            filterBar(controller: controller)
        }
        .onChange(of: controller.filter) {
            selectedID = nil
        }
        .onChange(of: apps.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) {
                self.selectedID = nil
            }
        }
    }

    /// The filter capsule with the scope popup (the Android tab's, with
    /// Device Hub's four scopes).
    private func filterBar(controller: SimulatorAppsController) -> some View {
        @Bindable var controller = controller
        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
                TextField("Filter", text: $controller.filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: ParityMetrics.inspectorAppsFilterFontSize))
                    .focused($isFilterFocused)
                    .padding(.leading, 6)
            }
            .frame(maxHeight: .infinity)
            .textFieldHitArea(Rectangle(), focus: $isFilterFocused)
            .layoutPriority(1)
            Spacer(minLength: 6)

            Rectangle()
                .fill(Color.primary.opacity(ParityMetrics.inspectorAppsScopeDividerOpacity))
                .frame(
                    width: ParityMetrics.inspectorDividerHeight,
                    height: ParityMetrics.inspectorAppsSeparatorHeight
                )
            AppsScopePopup(
                title: controller.scope.label,
                sections: [
                // Device Hub's popup: All Apps, a separator, then the three
                // filters.
                .init(items: [(SimulatorAppScope.all.label, .all)]),
                .init(items: SimulatorAppScope.allCases.filter { $0 != .all }.map { ($0.label, $0) }),
            ],
                selection: $controller.scope
            )
        }
        .frame(height: ParityMetrics.inspectorAppsFilterHeight)
        .background(Color.primary.opacity(ParityMetrics.inspectorAppsFilterFillOpacity), in: Capsule())
        .padding(.horizontal, ParityMetrics.inspectorCardInset)
        .padding(.top, ParityMetrics.inspectorAppsFilterTopSpacing)
        .padding(.bottom, ParityMetrics.inspectorAppsFilterBottomSpacing)
    }

    /// A row's menu, Device Hub's (measured on Device Hub 27.0): Launch; Copy
    /// Bundle ID and Copy Version; App Container ▸ Show in Finder, Replace…,
    /// Download…; and Uninstall for an app that can be removed. (Terminate
    /// is not in Device Hub's menu.)
    @ViewBuilder
    private func appMenu(for app: SimulatorApp) -> some View {
        let controller = workspace.simulatorApps
        Button("Launch") {
            Task { await controller.launch(app, udid: udid) }
        }
        Button("Launch with Options…") { launchOptionsApp = app }
        Divider()
        // Device Hub's menu draws a copy glyph on this item alone.
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(app.bundleIdentifier, forType: .string)
        } label: {
            Label("Copy Bundle ID", systemImage: "doc.on.doc")
                .labelStyle(.titleAndIcon)
        }
        // An app that reports no version has nothing to copy: no item.
        if (app.shortVersion ?? app.version) != nil {
            Button("Copy Version") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(app.shortVersion ?? app.version ?? "", forType: .string)
            }
        }
        // An app with no data container (a system app, one never opened) has none to show.
        if app.dataContainer != nil {
        Divider()
        Menu("App Container") {
            Button("Show in Finder") {
                Task { await controller.showDataContainer(app, udid: udid) }
            }
            Button("Replace…") { chooseContainerReplacement(for: app) }
            Button("Download…") { chooseContainerDestination(for: app) }
            Divider()
            // Device Hub Pro's own: browse, preview, edit UserDefaults, read SQLite.
            Button("Inspect Data…") { inspectedApp = app }
            Button("Save App State…") { chooseStateDestination(for: app) }
                .disabled(controller.isBusy)
            Button("Restore App State…") { chooseStateToRestore(for: app) }
                .disabled(controller.isBusy)
        }
        }
        if app.isRemovable {
            Divider()
            Button("Uninstall", role: .destructive) {
                dialogs.requestUninstall(app, udid: udid)
            }
            .disabled(controller.isBusy)
        }
    }

    /// App Container ▸ Save App State…: a zip of the data container, the app
    /// stopped first.
    private func chooseStateDestination(for app: SimulatorApp) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = AppDataStateArchive.suggestedName(bundleIdentifier: app.bundleIdentifier)
        panel.message = "Save the data of “\(app.title)” as a zip. The app is stopped first."
        panel.prompt = "Save"
        if panel.runModal() == .OK, let archive = panel.url {
            Task { await workspace.simulatorApps.saveAppState(app, udid: udid, to: archive) }
        }
    }

    /// App Container ▸ Restore App State…: a zip made by Save App State…,
    /// confirmed first because it replaces the app's data.
    private func chooseStateToRestore(for app: SimulatorApp) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip]
        panel.message = "Choose an app state zip to restore into “\(app.title)”."
        panel.prompt = "Restore"
        guard panel.runModal() == .OK, let archive = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "Restore the state of “\(app.title)”?"
        alert.informativeText = "Everything in the app's data container is removed and replaced with the contents of “\(archive.lastPathComponent)”. The app is stopped first."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await workspace.simulatorApps.restoreAppState(app, udid: udid, from: archive) }
    }

    /// App Container ▸ Download…: Device Hub's folder chooser.
    private func chooseContainerDestination(for app: SimulatorApp) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a location to save the app data container."
        panel.prompt = "Download"
        if panel.runModal() == .OK, let folder = panel.url {
            Task { await workspace.simulatorApps.downloadContainer(app, udid: udid, to: folder) }
        }
    }

    /// App Container ▸ Replace…: a folder or an `.xcappdata` bundle whose
    /// contents become the app's data. Asked to confirm first: it removes the
    /// data the app has now.
    private func chooseContainerReplacement(for app: SimulatorApp) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose a folder or .xcappdata bundle to replace the app data container."
        panel.prompt = "Replace"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "Replace the data of “\(app.title)”?"
        alert.informativeText = "Everything in the app's data container is removed and replaced with the contents of “\(source.lastPathComponent)”. The app is stopped first."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await workspace.simulatorApps.replaceContainer(app, udid: udid, with: source) }
    }

    private func selectedApp(in apps: [SimulatorApp]) -> SimulatorApp? {
        guard let selectedID else { return nil }
        return apps.first { $0.id == selectedID }
    }

    private func moveSelection(_ direction: MoveCommandDirection, in apps: [SimulatorApp], proxy: ScrollViewProxy) {
        let forward: Bool
        switch direction {
        case .down: forward = true
        case .up: forward = false
        default: return
        }
        let ids = apps.map(\.id)
        guard !ids.isEmpty else { return }
        let next: String
        if let current = selectedID, let index = ids.firstIndex(of: current) {
            next = ids[forward ? min(index + 1, ids.count - 1) : max(index - 1, 0)]
        } else {
            next = forward ? ids[0] : ids[ids.count - 1]
        }
        selectedID = next
        proxy.scrollTo(next)
    }

    /// `+`: pick a simulator build (`.app`, `.ipa` or `.zip`) and install it.
    private func chooseAndInstall() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a simulator build of an app (.app, .ipa or .zip) to install"
        panel.allowedContentTypes = [.applicationBundle, .zip] + [UTType(filenameExtension: "ipa")].compactMap { $0 }
        if panel.runModal() == .OK, let url = panel.url {
            Task { await workspace.simulatorApps.install(url, udid: udid) }
        }
    }

    /// The list card: rounded top corners, square bottom against the panel
    /// divider (the Android tab's).
    private var listCardShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: ParityMetrics.inspectorCardRadius,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: ParityMetrics.inspectorCardRadius,
            style: .continuous
        )
    }
}

/// One app, in the Android row's metrics (IN-03): the icon tile (the app's
/// own icon read from its bundle, else the generic glyph), the name and the
/// bundle identifier, the version trailing.
struct SimulatorAppRow: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    let app: SimulatorApp
    var isSelected = false

    var body: some View {
        HStack(spacing: 0) {
            iconTile
                .padding(.leading, ParityMetrics.inspectorAppsTileInset)

            VStack(alignment: .leading, spacing: 1) {
                Text(app.title)
                    .font(.system(size: ParityMetrics.inspectorAppsNameFontSize))
                    .lineLimit(1)
                // DH cuts a simulator app's bundle identifier at its head
                // ("…pple.NanoUniverse.AegirProxyApp", `dh-IN-03.png`).
                Text(app.bundleIdentifier)
                    .font(.system(size: ParityMetrics.inspectorAppsPackageFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.leading, ParityMetrics.inspectorAppsTileTextSpacing)

            Spacer(minLength: 6)

            Text(app.shortVersion ?? app.version ?? "")
                .font(.system(size: ParityMetrics.inspectorAppsVersionFontSize))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.trailing, ParityMetrics.inspectorAppsDividerTrailingInset)
        }
        .frame(height: ParityMetrics.inspectorAppsRowHeight)
        .appRowFocusRing(isSelected)
        .task(id: app.path) {
            await workspace.simulatorApps.loadIcon(for: app)
        }
    }

    private var iconTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ParityMetrics.inspectorAppsTileRadius, style: .continuous)
                .fill(workspace.simulatorApps.usesTemplateTile(app) ? Color.white : Color.primary.opacity(0.06))
            if let icon = workspace.simulatorApps.icon(for: app) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else if workspace.simulatorApps.usesTemplateTile(app) {
                // Device Hub's tile for an app that cannot be launched or
                // shows nothing: the icon template's grid on white.
                IconTemplateGrid()
            } else {
                // Device Hub's tile for an app without an icon: the App
                // Store "A".
                AppStoreGlyph()
            }
        }
        .frame(width: ParityMetrics.inspectorAppsTileSize, height: ParityMetrics.inspectorAppsTileSize)
        .clipShape(RoundedRectangle(cornerRadius: ParityMetrics.inspectorAppsTileRadius, style: .continuous))
    }
}

/// The icon template's grid Device Hub draws on a white tile for an app that
/// cannot be launched (measured on DH 27.0, 2x: verticals and horizontals at
/// 11, 33, 50, 68 and 89 % of the tile, the two diagonals, circles of 39, 27
/// and 17 % radius, a dot at the centre and at 31 and 68 %, all in light
/// gray hairlines).
struct IconTemplateGrid: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            var lines = Path()
            for fraction in [0.11, 0.33, 0.5, 0.68, 0.89] {
                lines.move(to: CGPoint(x: fraction * w, y: 0))
                lines.addLine(to: CGPoint(x: fraction * w, y: h))
                lines.move(to: CGPoint(x: 0, y: fraction * h))
                lines.addLine(to: CGPoint(x: w, y: fraction * h))
            }
            lines.move(to: .zero)
            lines.addLine(to: CGPoint(x: w, y: h))
            lines.move(to: CGPoint(x: w, y: 0))
            lines.addLine(to: CGPoint(x: 0, y: h))
            for radius in [0.39, 0.27, 0.17] {
                lines.addEllipse(in: CGRect(
                    x: (0.5 - radius) * w, y: (0.5 - radius) * h,
                    width: 2 * radius * w, height: 2 * radius * h
                ))
            }
            let line = Color(white: 0.8)
            context.stroke(lines, with: .color(line), lineWidth: 0.5)
            for (x, y) in [(0.5, 0.5), (0.31, 0.31), (0.68, 0.31), (0.31, 0.68), (0.68, 0.68)] {
                context.fill(
                    Path(ellipseIn: CGRect(x: x * w - 0.8, y: y * h - 0.8, width: 1.6, height: 1.6)),
                    with: .color(line)
                )
            }
        }
        .accessibilityHidden(true)
    }
}
