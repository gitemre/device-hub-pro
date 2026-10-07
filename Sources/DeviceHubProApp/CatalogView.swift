import SwiftUI
import DeviceHubProKit

/// Browse Catalog: every device the app can create, Android (the SDK's
/// skins) and Apple (every simulator device type simctl knows), as a grid of
/// equally sized cards with a platform switch, a form-factor filter and a
/// search field, and a detail pane for the selected device.
///
/// Opened from the sidebar `+` menu and the Device menu. A card's Create
/// opens the matching sheet with the device preselected
/// (`SimulatorCreateSheet` for Apple, `AvdCreateSheet` for Android); an
/// Android device that already has an AVD offers Start instead.
struct CatalogView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var platform: CatalogPlatform
    @State private var group: CatalogGroup?
    @State private var searchText = ""
    @State private var onlyCreatable = true
    @State private var selectedID: String?
    @State private var createTarget: CatalogItem?
    @State private var didChoosePlatform: Bool
    @FocusState private var isSearchFocused: Bool

    /// - Parameters:
    ///   - platform: the half to open on; nil opens Android, or Apple when
    ///     the SDK has no skins and Xcode has device types.
    ///   - group: the form factor or family to filter to.
    init(platform: CatalogPlatform? = nil, group: CatalogGroup? = nil) {
        _platform = State(initialValue: platform ?? group?.platform ?? .android)
        _group = State(initialValue: group)
        _didChoosePlatform = State(initialValue: platform != nil || group != nil)
    }

    /// The sheet's measured layout.
    static let minSize = CGSize(width: 960, height: 640)
    static let detailWidth: CGFloat = 300
    static let cardMinWidth: CGFloat = 188
    static let cardMaxWidth: CGFloat = 236
    static let previewHeight: CGFloat = 168

    private var allItems: [CatalogItem] {
        DeviceCatalog.items(
            skins: model.catalog.skinCatalog,
            deviceTypes: model.simulators.deviceTypes,
            runtimes: model.simulators.runtimes
        )
    }

    var body: some View {
        let items = allItems
        let visible = DeviceCatalog.filter(
            items,
            platform: platform,
            group: group,
            search: searchText,
            onlyCreatable: platform == .apple && onlyCreatable
        )
        VStack(spacing: 0) {
            header(items: items)
            Divider()
            HStack(spacing: 0) {
                gridPane(visible, allItems: items)
                Divider()
                CatalogDetailPane(item: items.first(where: { $0.id == selectedID })) { item in
                    createTarget = item
                }
                .frame(width: Self.detailWidth)
            }
        }
        .frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
        .task {
            // Best effort: the simulator catalogs load with the provider.
            await model.simulators.refresh()
            chooseInitialPlatform()
        }
        .onChange(of: platform) {
            group = nil
            selectedID = nil
        }
        .sheet(item: $createTarget) { target in
            createSheet(for: target)
        }
    }

    // MARK: - Header

    private func header(items: [CatalogItem]) -> some View {
        VStack(spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Browse Catalog")
                        .font(.title2.bold())
                    Text(platform == .android
                        ? "Device skins of the Android SDK"
                        : "Device types of the installed Xcode")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Platform", selection: $platform) {
                    ForEach(CatalogPlatform.allCases) { platform in
                        Text(platform.label).tag(platform)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                Spacer()
                searchField
                // The sheet had no way out but a window close.
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 8) {
                groupChips(items: items)
                Spacer(minLength: 8)
                if platform == .apple {
                    Toggle("Installed runtimes only", isOn: $onlyCreatable)
                        .toggleStyle(.checkbox)
                        .font(.callout)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var searchField: some View {
        HStack(spacing: ParityMetrics.sidebarSearchIconSpacing + 2) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 13, weight: .medium))
            TextField("Search devices", text: $searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
        }
        .padding(.horizontal, 8)
        .frame(width: 200, height: ParityMetrics.sidebarSearchHeight)
        .textFieldHitArea(
            RoundedRectangle(cornerRadius: 8, style: .continuous),
            focus: $isSearchFocused
        )
        // Plain glass like the sidebar search: a text field does not morph
        // under the pointer.
        .liquidGlass(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func groupChips(items: [CatalogItem]) -> some View {
        let groups = DeviceCatalog.groups(in: items, platform: platform)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                CatalogChip(title: "All", isSelected: group == nil) { group = nil }
                ForEach(groups) { candidate in
                    CatalogChip(
                        title: candidate.label,
                        symbol: candidate.symbol,
                        isSelected: group == candidate
                    ) {
                        group = group == candidate ? nil : candidate
                    }
                }
            }
        }
    }

    // MARK: - Grid

    private func gridPane(_ visible: [CatalogItem], allItems: [CatalogItem]) -> some View {
        ScrollView {
            if visible.isEmpty {
                emptyState(hasAny: allItems.contains { $0.platform == platform })
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            } else {
                LazyVGrid(
                    columns: [GridItem(
                        .adaptive(minimum: Self.cardMinWidth, maximum: Self.cardMaxWidth * 1.4),
                        spacing: 14,
                        alignment: .top
                    )],
                    alignment: .leading,
                    spacing: 14,
                    pinnedViews: [.sectionHeaders]
                ) {
                    ForEach(DeviceCatalog.sections(visible), id: \.group) { section in
                        Section {
                            ForEach(section.items) { item in
                                CatalogCard(
                                    item: item,
                                    isSelected: item.id == selectedID,
                                    select: { selectedID = item.id },
                                    create: { createTarget = item }
                                )
                            }
                        } header: {
                            if group == nil {
                                CatalogSectionHeader(group: section.group, count: section.items.count)
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private func emptyState(hasAny: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: hasAny ? "magnifyingglass" : platform == .android ? "smartphone" : "applelogo")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(hasAny ? "No devices match" : platform == .android ? "No Android skins found" : "No simulator device types found")
                .font(.headline)
            Text(hasAny
                ? "Try another search or filter."
                : platform == .android
                    ? "The device skins come with Google's Android tools, which are not set up on this Mac yet."
                    : "Install Xcode and its platforms to browse simulator devices here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !hasAny, platform == .android {
                Button("Set Up Android Tools\u{2026}") {
                    dismiss()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        workspace.window.isAndroidSetupPresented = true
                    }
                }
                .glassProminentButton()
                .padding(.top, 6)
            }
        }
    }

    // MARK: - Create

    @ViewBuilder
    private func createSheet(for item: CatalogItem) -> some View {
        switch item.source {
        case .skin(let entry):
            AvdCreateSheet(
                formFactor: entry.category,
                preferredSkin: entry.name,
                onCreated: { dismiss() }
            )
            .environment(model)
        case .simulator(let type, let family):
            SimulatorCreateSheet(
                family: family,
                preferredModel: type.identifier,
                onCreated: { dismiss() }
            )
            .environment(model)
        }
    }

    /// Android first, unless the SDK has no skins and Xcode has device types.
    private func chooseInitialPlatform() {
        guard !didChoosePlatform else { return }
        didChoosePlatform = true
        if model.catalog.skinCatalog.isEmpty, !model.simulators.deviceTypes.isEmpty {
            platform = .apple
        }
    }
}

// MARK: - Pieces

private struct CatalogChip: View {
    let title: String
    var symbol: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11))
                }
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                Capsule().fill(isSelected ? Color.accentColor : Color.primary.opacity(0.07))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct CatalogSectionHeader: View {
    let group: CatalogGroup
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: group.symbol)
                .font(.system(size: 12))
            Text(group.label)
                .font(.system(size: ParityMetrics.sidebarHeaderFontSize + 2, weight: .semibold))
            Text("\(count)")
                .font(.system(size: ParityMetrics.sidebarHeaderFontSize))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
        // Opaque, so cards scrolling under the pinned header do not show.
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// The information a card and the detail pane show about one item's screen,
/// read where it is known: an Android skin's layout, an Apple device type's
/// display once its profile was read.
@MainActor
struct CatalogFacts {
    let item: CatalogItem
    let model: AppModel
    var variantID = "default"

    var skinVariant: SkinVariant? {
        guard let skin = item.skin else { return nil }
        return skin.variants.first(where: { $0.id == variantID }) ?? skin.preferredVariant
    }

    /// The screen's pixel size, nil until known.
    var screenPixels: CGSize? {
        switch item.source {
        case .skin:
            return skinVariant?.layout?.preferred?.displaySize
        case .simulator(let type, _):
            if let chrome = model.simulators.chromeFrame(forDeviceType: type) {
                return chrome.screenPixels
            }
            return model.simulators.displayShape(forDeviceType: type).map {
                CGSize(width: $0.width, height: $0.height)
            }
        }
    }

    /// "1080 × 2400 px", nil until known.
    var resolution: String? { screenPixels.flatMap(CatalogScreenText.resolution) }

    /// "@3x" for an Apple device whose chrome was read.
    var scale: String? {
        guard case .simulator(let type, _) = item.source,
              let chrome = model.simulators.chromeFrame(forDeviceType: type)
        else { return nil }
        return CatalogScreenText.scale(chrome.scale)
    }

    /// The AVD installed for this Android skin, if any.
    var installedAvd: AvdCard? {
        guard let skin = item.skin else { return nil }
        return model.catalog.avdCards.first(where: { $0.skin?.name == skin.name })
    }

    /// The simulators of this device type already created.
    var simulatorCount: Int {
        guard let type = item.deviceType else { return 0 }
        return model.simulators.simulators.filter { $0.deviceTypeIdentifier == type.identifier }.count
    }
}

// MARK: - Cards

private struct CatalogCard: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    let item: CatalogItem
    let isSelected: Bool
    let select: () -> Void
    let create: () -> Void

    var body: some View {
        let facts = CatalogFacts(item: item, model: model)
        VStack(spacing: 0) {
            CatalogPreview(item: item, height: CatalogView.previewHeight)
                .padding(.top, 12)
                .padding(.horizontal, 10)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle(facts))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                action(facts)
                    .padding(.top, 5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(maxWidth: .infinity)
        // Fill, not glass: the card hosts glass buttons, and glass on glass
        // is prohibited (audit 2026-09-18).
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: select)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .task(id: item.id) {
            if let type = item.deviceType {
                await model.simulators.loadDisplayShape(forDeviceType: type)
            }
        }
    }

    private func subtitle(_ facts: CatalogFacts) -> String {
        var parts = [item.group.label]
        if let resolution = facts.resolution { parts.append(resolution) }
        return parts.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder
    private func action(_ facts: CatalogFacts) -> some View {
        if let avd = facts.installedAvd {
            // A running emulator is shown, not started again (the action
            // attaches to it and selects it either way).
            Button(avd.isRunning ? "Show" : "Start") {
                Task { await model.startAndMirror(avd: avd.name, workspace: workspace) }
            }
            .glassButton()
            .controlSize(.small)
            .disabled(model.isBusy)
        } else {
            Button("Create\u{2026}", action: create)
                .glassButton()
                .controlSize(.small)
                .disabled(!item.isCreatable)
                .help(item.isCreatable ? "" : "No installed runtime runs this device")
        }
    }
}

// MARK: - Preview

/// A device's picture: the skin artwork or the Apple chrome (DeviceKit,
/// read at runtime from the user's Xcode), else the system's device icon,
/// else the vector body around its display; a neutral tile of the
/// device's own proportions while the picture renders or when it has none.
/// The shared cache (`SkinThumbnailCache`) renders off the main thread and
/// updates this view when the image lands.
///
/// The box is the same for every device, so the grid stays regular; the
/// picture keeps its aspect inside it, a watch at a fraction of a phone's
/// height (`CatalogGroup.previewFill`) and a wide TV or car screen limited
/// by the box's width.
struct CatalogPreview: View {
    @Environment(AppModel.self) private var model
    let item: CatalogItem
    let height: CGFloat
    var variantID = "default"

    var body: some View {
        let fill = item.group.previewFill
        ZStack {
            if let image = image() {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: height * fill)
            } else {
                CatalogPlaceholder(group: item.group)
                    .frame(maxWidth: .infinity, maxHeight: height * fill)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .accessibilityHidden(true)
    }

    @MainActor
    private func image() -> NSImage? {
        let cache = SkinThumbnailCache.shared
        switch item.source {
        case .skin(let entry):
            let variant = entry.variants.first(where: { $0.id == variantID }) ?? entry.preferredVariant
            return variant.flatMap { cache.image(for: $0, height: height) }
        case .simulator(let type, _):
            let simulators = model.simulators
            if let chrome = simulators.chromeFrame(forDeviceType: type) {
                return cache.vectorImage(for: DeviceCompositionPlanner.appleChrome(chrome), height: height)
            }
            guard simulators.hasReadDisplayShape(forDeviceType: type) else { return nil }
            if let icon = SystemDeviceIcon.image(forModelIdentifier: type.modelIdentifier) {
                return icon
            }
            guard let plan = SimulatorHero.plan(simulators.displayShape(forDeviceType: type)) else { return nil }
            return cache.vectorImage(for: plan, height: height)
        }
    }
}

/// A neutral tile in the device's own outline, for while its picture
/// renders and for a skin with no artwork: round for a watch, a phone's
/// tall rectangle for a phone, a wide one for a TV or a car.
private struct CatalogPlaceholder: View {
    let group: CatalogGroup

    var body: some View {
        shape
            .fill(Color.primary.opacity(0.08))
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                Image(systemName: group.symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
            }
    }

    private var shape: AnyShape {
        switch group {
        case .wear: AnyShape(Circle())
        case .appleWatch: AnyShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        default: AnyShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    /// Width over height.
    private var aspect: CGFloat {
        switch group {
        case .androidPhones, .androidOther, .iPhone: 9 / 19
        case .androidFoldables: 0.85
        case .androidTablets: 1.4
        case .iPad: 0.75
        case .wear: 1
        case .appleWatch: 0.82
        case .tv, .appleTV: 16 / 9
        case .automotive: 2
        case .xr, .appleVision: 1.5
        }
    }
}

// MARK: - Detail pane

/// The selected device: a large picture, its facts in Device Hub's card of
/// rows, and the create action.
private struct CatalogDetailPane: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    let item: CatalogItem?
    let create: (CatalogItem) -> Void
    @State private var variantID = "default"

    var body: some View {
        Group {
            if let item {
                content(item)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "rectangle.and.hand.point.up.left")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text("Select a device")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func content(_ item: CatalogItem) -> some View {
        let facts = CatalogFacts(item: item, model: model, variantID: variantID)
        return ScrollView {
            VStack(spacing: 14) {
                CatalogPreview(item: item, height: 250, variantID: variantID)
                    .padding(.top, 8)

                VStack(spacing: 2) {
                    Text(item.name)
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                    Text(item.platform.label + " \u{00B7} " + item.group.label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let skin = item.skin, skin.variants.count > 1 {
                    Picker("Screen", selection: $variantID) {
                        ForEach(skin.variants, id: \.id) { variant in
                            Text(variant.id == "default" ? "Open" : variant.id.capitalized).tag(variant.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                DHSheetCard {
                    ForEach(rows(item, facts), id: \.0) { row in
                        DHSheetRow(title: row.0) {
                            Text(row.1)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                    }
                }

                actions(item, facts)
            }
            .padding(16)
        }
        .task(id: item.id) {
            variantID = "default"
            if let type = item.deviceType {
                await model.simulators.loadDisplayShape(forDeviceType: type)
            }
        }
    }

    private func rows(_ item: CatalogItem, _ facts: CatalogFacts) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let resolution = facts.resolution {
            rows.append(("Screen", resolution + (facts.scale.map { " \($0)" } ?? "")))
        }
        switch item.source {
        case .skin(let entry):
            rows.append(("Skin", entry.name))
            if let profile = AvdmanagerClient.device(
                forSkinName: entry.name,
                devices: model.catalog.avdDevices
            ) {
                rows.append(("Profile", profile.id))
            }
            rows.append(("Installed", facts.installedAvd?.displayName ?? "None"))
        case .simulator(let type, _):
            if let identifier = type.modelIdentifier { rows.append(("Model", identifier)) }
            rows.append(("Runtimes", item.runtimeNames.isEmpty
                ? "None installed"
                : item.runtimeNames.prefix(3).joined(separator: ", ")
                    + (item.runtimeNames.count > 3 ? " +\(item.runtimeNames.count - 3)" : "")))
            rows.append(("Simulators", facts.simulatorCount == 0 ? "None" : "\(facts.simulatorCount)"))
        }
        return rows
    }

    @ViewBuilder
    private func actions(_ item: CatalogItem, _ facts: CatalogFacts) -> some View {
        VStack(spacing: 8) {
            if let avd = facts.installedAvd {
                Button {
                    Task { await model.startAndMirror(avd: avd.name, workspace: workspace) }
                } label: {
                    Text("Start \(avd.displayName)").frame(maxWidth: .infinity)
                }
                .glassProminentButton()
                .controlSize(.large)
                .disabled(model.isBusy)
            }
            Button {
                create(item)
            } label: {
                Text("Create\u{2026}").frame(maxWidth: .infinity)
            }
            .modifier(CatalogCreateButtonStyle(prominent: facts.installedAvd == nil))
            .controlSize(.large)
            .disabled(!item.isCreatable)

            if !item.isCreatable, SimulatorCreateSheet.addPlatformsURL != nil {
                Text("No installed runtime runs this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Add Platforms in Xcode\u{2026}") { SimulatorCreateSheet.openAddPlatforms() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }
}

private struct CatalogCreateButtonStyle: ViewModifier {
    let prominent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if prominent {
            content.glassProminentButton()
        } else {
            content.glassButton()
        }
    }
}
