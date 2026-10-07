import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DeviceHubProKit

/// A physical iPhone's or iPad's Apps inspector, in
/// the simulator Apps tab's layout and metrics: the list card with each app's
/// name, bundle identifier and version and its real icon, the
/// `+`/`−` footer, and the filter capsule with Device Hub's scope popup (User
/// Apps, All Apps). There is no Open URL field: opening a link is a menu
/// action (`PhysicalAppsController.openURL(_:)`). A row's menu is Device
/// Hub's (`PhysicalAppMenu`). An app or a link dropped on the tab installs
/// or opens, as on the stage. A device that cannot be asked (not enabled,
/// unpaired, disconnected) shows its state hint in place of all of it.
struct PhysicalAppsInspectorView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    let entry: ApplePhysicalEntry
    @FocusState private var isListFocused: Bool
    @FocusState private var isFilterFocused: Bool

    /// The list reloads when the device changes or becomes usable, and when
    /// the scope changes.
    private struct LoadKey: Equatable {
        let udid: String
        let canUse: Bool
        let scope: PhysicalAppScope
    }

    var body: some View {
        let controller = workspace.physicalApps
        Group {
            if entry.canUseClient {
                appsPanel
            } else {
                ContentUnavailableView {
                    Label("No Apps", systemImage: "apps.iphone")
                } description: {
                    Text(ApplePhysicalInventory.unavailableText(entry: entry))
                }
            }
        }
        .task(id: LoadKey(udid: entry.udid, canUse: entry.canUseClient, scope: controller.scope)) {
            if entry.canUseClient {
                await controller.load(udid: entry.udid)
            } else {
                controller.clear()
            }
        }
        .onDrop(of: StageDropTypes.accepted(by: .apple), isTargeted: nil) { providers in
            guard entry.canUseClient else { return false }
            let udid = entry.udid
            Task { @MainActor in
                let urls = await SimulatorAppsController.urls(from: providers)
                await controller.handleDrop(urls, udid: udid)
            }
            return true
        }
        .alert(
            "Uninstall \(dhQuoted(controller.pendingUninstall?.name ?? ""))?",
            isPresented: Binding(
                get: { controller.pendingUninstall != nil },
                set: { if !$0 { controller.pendingUninstall = nil } }
            ),
            presenting: controller.pendingUninstall
        ) { request in
            Button("Cancel", role: .cancel) { controller.pendingUninstall = nil }
            Button("Uninstall", role: .destructive) {
                controller.pendingUninstall = nil
                Task {
                    await controller.uninstall(
                        bundleIdentifier: request.bundleIdentifier,
                        name: request.name,
                        udid: request.udid
                    )
                }
            }
        } message: { request in
            Text("\"\(request.name)\" (\(request.bundleIdentifier)) and its data are removed from \(entry.name).")
        }
        .sheet(item: Binding(
            get: { controller.containerTarget },
            set: { if $0 == nil { controller.closeContainerFiles() } }
        )) { target in
            PhysicalContainerFilesSheet(target: target)
                .environment(model)
                .environment(workspace)
        }
    }

    private var appsPanel: some View {
        @Bindable var controller = workspace.physicalApps
        let apps = controller.appsUDID == entry.udid ? controller.filteredApps : []
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
                                    showAll: unfiltered && controller.scope != .allApps
                                        ? { controller.scope = .allApps }
                                        : nil
                                )
                            } else {
                                ForEach(apps) { app in
                                    PhysicalAppRow(app: app, udid: entry.udid, isSelected: controller.selectedID == app.id)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            if NSApp.currentEvent?.clickCount == 2 {
                                                controller.selectedID = app.id
                                                Task { await controller.launch(app, udid: entry.udid) }
                                            } else {
                                                controller.selectedID = controller.selectedID == app.id ? nil : app.id
                                            }
                                            isListFocused = true
                                        }
                                        .contextMenu { appMenu(for: app) }
                                        .accessibilityElement(children: .combine)
                                        .accessibilityAddTraits(controller.selectedID == app.id ? [.isButton, .isSelected] : .isButton)
                                        .accessibilityAction {
                                            controller.selectedID = controller.selectedID == app.id ? nil : app.id
                                        }
                                        .accessibilityAction(named: Text("Launch")) {
                                            Task { await controller.launch(app, udid: entry.udid) }
                                        }
                                    InspectorDivider(
                                        leadingInset: ParityMetrics.inspectorAppsTextInset,
                                        trailingInset: ParityMetrics.inspectorAppsDividerTrailingInset
                                    )
                                }
                            }
                        }
                    }
                    .focusable()
                    .focused($isListFocused)
                    .focusEffectDisabled()
                    .onMoveCommand { direction in
                        moveSelection(direction, in: apps, proxy: proxy)
                    }
                    .onKeyActivation([.return]) {
                        guard let app = selectedApp(in: apps) else { return .ignored }
                        Task { await controller.launch(app, udid: entry.udid) }
                        return .handled
                    }
                    .onDeleteCommand {
                        if let app = selectedApp(in: apps), app.isRemovable {
                            controller.requestUninstall(app, udid: entry.udid)
                        }
                    }
                }

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
                            controller.requestUninstall(app, udid: entry.udid)
                        }
                    }
                )
            }
            .background(
                Color.primary.opacity(ParityMetrics.inspectorCardFillOpacity),
                in: listCardShape
            )
            .clipShape(listCardShape)
            .padding(.horizontal, ParityMetrics.inspectorCardInset)

            Divider()

            filterBar(controller: controller)
        }
        .onChange(of: controller.filter) {
            controller.selectedID = nil
        }
    }

    /// The filter capsule with Device Hub's scope popup (the simulator tab's,
    /// with the two scopes a physical device has: User Apps and All Apps).
    private func filterBar(controller: PhysicalAppsController) -> some View {
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
                .init(items: PhysicalAppScope.allCases.map { ($0.label, $0) })
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

    /// A row's menu, Device Hub's (measured on Device Hub 27.0, the phone's
    /// system and user apps): Launch; Copy Bundle ID and Copy Version; for
    /// an app that is not one of the OS's, App Container; and Uninstall for
    /// an app that can be removed. Beyond Device Hub's: Terminate, only while
    /// the app runs, and the container's item is "Show Container Files…"
    /// (a development build's data container is listed in a sheet).
    /// `PhysicalAppMenu` decides which items show.
    @ViewBuilder
    private func appMenu(for app: PhysicalApp) -> some View {
        let controller = workspace.physicalApps
        let menu = PhysicalAppMenu.make(
            app: app,
            isRunning: controller.runningBundleIdentifiers.contains(app.id),
            isBusy: controller.isBusy
        )
        Button("Launch") {
            Task { await controller.launch(app, udid: entry.udid) }
        }
        if menu.showsTerminate {
            Button("Terminate") {
                Task { await controller.terminate(app, udid: entry.udid) }
            }
        }
        Divider()
        // Device Hub's menu draws a copy glyph on this item alone.
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(app.bundleIdentifier, forType: .string)
        } label: {
            Label("Copy Bundle ID", systemImage: "doc.on.doc")
        }
        if menu.showsCopyVersion {
            Button("Copy Version") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(app.displayVersion ?? "", forType: .string)
            }
        }
        if menu.showsAppContainer {
            Divider()
            Menu("App Container") {
                Button("Show Container Files…") {
                    Task { await controller.showContainerFiles(app, udid: entry.udid) }
                }
            }
        }
        if menu.showsUninstall {
            Divider()
            Button("Uninstall", role: .destructive) {
                controller.requestUninstall(app, udid: entry.udid)
            }
            .disabled(!menu.uninstallEnabled)
        }
    }

    private func selectedApp(in apps: [PhysicalApp]) -> PhysicalApp? {
        guard let selectedID = workspace.physicalApps.selectedID else { return nil }
        return apps.first { $0.id == selectedID }
    }

    private func moveSelection(_ direction: MoveCommandDirection, in apps: [PhysicalApp], proxy: ScrollViewProxy) {
        let forward: Bool
        switch direction {
        case .down: forward = true
        case .up: forward = false
        default: return
        }
        let ids = apps.map(\.id)
        guard !ids.isEmpty else { return }
        let controller = workspace.physicalApps
        let next: String
        if let current = controller.selectedID, let index = ids.firstIndex(of: current) {
            next = ids[forward ? min(index + 1, ids.count - 1) : max(index - 1, 0)]
        } else {
            next = forward ? ids[0] : ids[ids.count - 1]
        }
        controller.selectedID = next
        proxy.scrollTo(next)
    }

    /// `+`: pick a device build (`.app` or `.ipa`) and install it.
    private func chooseAndInstall() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a build of an app for this device (.app or .ipa) to install"
        panel.allowedContentTypes = [.applicationBundle] + [UTType(filenameExtension: "ipa")].compactMap { $0 }
        if panel.runModal() == .OK, let url = panel.url {
            let udid = entry.udid
            Task { await workspace.physicalApps.install(url, udid: udid) }
        }
    }

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

/// One app, in the simulator row's metrics: the app's real icon (fetched
/// lazily through `devicectl device info appIcon` and cached, the generic
/// glyph until it loads or when it cannot), the name and the bundle
/// identifier, the version trailing.
private struct PhysicalAppRow: View {
    @Environment(DeviceWorkspace.self) private var workspace
    let app: PhysicalApp
    let udid: String
    var isSelected = false

    var body: some View {
        HStack(spacing: 0) {
            iconTile
                .padding(.leading, ParityMetrics.inspectorAppsTileInset)

            VStack(alignment: .leading, spacing: 1) {
                Text(app.title)
                    .font(.system(size: ParityMetrics.inspectorAppsNameFontSize, weight: .semibold))
                    .lineLimit(1)
                Text(app.bundleIdentifier)
                    .font(.system(size: ParityMetrics.inspectorAppsPackageFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.leading, ParityMetrics.inspectorAppsTileTextSpacing)

            Spacer(minLength: 6)

            Text(app.displayVersion ?? "")
                .font(.system(size: ParityMetrics.inspectorAppsVersionFontSize))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.trailing, ParityMetrics.inspectorAppsDividerTrailingInset)
        }
        .frame(height: ParityMetrics.inspectorAppsRowHeight)
        .background(isSelected ? Color.primary.opacity(ParityMetrics.inspectorAppsSelectionOpacity) : .clear)
        // Asked while the row shows (a lazy list only builds visible rows),
        // dropped when it scrolls away before its turn.
        .onAppear { workspace.physicalApps.icons.request(app, udid: udid) }
        .onDisappear { workspace.physicalApps.icons.cancel(app, udid: udid) }
    }

    private var iconTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ParityMetrics.inspectorAppsTileRadius, style: .continuous)
                .fill(Color.primary.opacity(0.06))
            if let icon = workspace.physicalApps.icons.image(for: app, udid: udid) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                AppStoreGlyph()
            }
        }
        .frame(width: ParityMetrics.inspectorAppsTileSize, height: ParityMetrics.inspectorAppsTileSize)
        .clipShape(RoundedRectangle(cornerRadius: ParityMetrics.inspectorAppsTileRadius, style: .continuous))
    }
}

/// An app's data container, listed (`device info files`): the tree as
/// devicectl lists it, and "Save to…" on each file (`device copy from` into a
/// place the user chooses). Folders are shown, not copied. Nothing on the
/// device changes.
private struct PhysicalContainerFilesSheet: View {
    @Environment(DeviceWorkspace.self) private var workspace
    let target: PhysicalAppsController.ContainerTarget

    var body: some View {
        let controller = workspace.physicalApps
        VStack(alignment: .leading, spacing: 12) {
            Text("Container Files of \"\(target.name)\"")
                .font(.headline)
            Text(target.bundleIdentifier)
                .font(.caption)
                .foregroundStyle(.secondary)

            Group {
                if controller.isLoadingContainer {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let problem = controller.containerProblem {
                    Text(problem)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(20)
                } else if controller.containerFiles.isEmpty {
                    Text("This container has no files.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(controller.containerFiles) { file in
                                PhysicalContainerFileRow(file: file)
                                Divider()
                            }
                        }
                    }
                }
            }
            .frame(width: 520, height: 320)
            .background(Color.primary.opacity(ParityMetrics.inspectorCardFillOpacity), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                Button("Done") { controller.closeContainerFiles() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

private struct PhysicalContainerFileRow: View {
    @Environment(DeviceWorkspace.self) private var workspace
    let file: PhysicalContainerFile

    var body: some View {
        let controller = workspace.physicalApps
        HStack(spacing: 8) {
            Image(systemName: file.isDirectory ? "folder" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(file.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if !file.isDirectory, let size = file.size {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if !file.isDirectory {
                Menu("Save to…") {
                    Button("Save to…") {
                        Task { await controller.saveContainerFile(file) }
                    }
                    Button("Save and Show in Finder") {
                        Task { await controller.saveContainerFile(file, revealAfter: true) }
                    }
                } primaryAction: {
                    Task { await controller.saveContainerFile(file) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.leading, 10 + CGFloat(file.depth) * 16)
        .padding(.trailing, 10)
        .frame(height: 28)
        .help(file.relativePath)
    }
}

/// Which items a physical app's context menu shows and enables (Device Hub's
/// menu, measured on Device Hub 27.0 with the test iPhone's system and user
/// apps, `r2-phone-dh-app-ctx-*`): Launch and Copy Bundle ID always; Copy
/// Version only for an app that reports one; App Container only for an app
/// whose data container is readable (a development build's); Uninstall for a
/// removable app; and, beyond Device Hub's, Terminate while the app runs. Device
/// Hub dims the first two; this menu lists only what works.
struct PhysicalAppMenu: Equatable {
    var showsTerminate: Bool
    var showsCopyVersion: Bool
    var showsAppContainer: Bool
    var showsUninstall: Bool
    var uninstallEnabled: Bool

    static func make(app: PhysicalApp, isRunning: Bool, isBusy: Bool) -> PhysicalAppMenu {
        PhysicalAppMenu(
            showsTerminate: isRunning,
            showsCopyVersion: app.displayVersion != nil,
            showsAppContainer: app.containerAccessible,
            showsUninstall: app.isRemovable,
            uninstallEnabled: !isBusy
        )
    }
}
