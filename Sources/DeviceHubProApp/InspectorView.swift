import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DeviceHubProKit

// The device inspector (the window's trailing column): the Info/Apps
// selector, Device Info, Apps with its install popover and footer,
// Diagnostics, and the card primitives they share. Controls lives in
// ControlsView.swift.

/// Device Hub's Info/Apps selector (IN-01). Until 2026-09-28 this was drawn
/// by hand — a flat 24 pt track, a 20 pt selected pill, gray labels, a 1 pt
/// bottom hairline — because the system segmented control rendered a
/// floating Liquid Glass capsule instead of DH's then-flat look (audit
/// 2026-09-18). Re-measured against Device Hub 27.0 (`dh-IN-01-live-
/// 2026-09-28.png`): DH's own Info/Apps/Profiles control is now that same
/// floating glass capsule — full inspector width, full-height rounded ends,
/// a plain gray selected pill (24 pt track, ~2 pt vertical pill inset,
/// unchanged), black labels (not the old gray #828282–#989898), no bottom
/// hairline (nothing attaches it to the content below).
///
/// A plain SwiftUI `Picker(.segmented)` (tried the same day) draws the same
/// material but not DH's *width*: an `NSSegmentedControl`-backed picker
/// sizes itself to its segments' content (`.fit` distribution) and does not
/// stretch for a `.frame(maxWidth: .infinity)` around it — that only
/// enlarges the invisible layout box, centered, with the same small control
/// inside. DH's track always spans the full padded column regardless of
/// segment count (confirmed live on its two-segment Apps tab equivalent, not
/// just the three-segment Info tab), so a centered, content-sized track was
/// a real deviation, not an acceptable side effect of having fewer segments.
/// `GlassSegmentedControl` wraps `NSSegmentedControl` directly instead:
/// `segmentDistribution = .fillEqually` makes the two segments split
/// whatever width AppKit gives the control, and a plain `NSViewRepresentable`
/// (unlike the built-in `Picker` bridging) does hand it the full width a
/// `.frame(maxWidth: .infinity)` proposes. `segmentStyle` stays `.automatic`,
/// which is what draws System's Liquid Glass material on macOS 26+ — this
/// is the same rendering DH's own control gets, not a re-creation of it.
private struct InspectorSegmentedControl: View {
    @Binding var selection: WindowState.InspectorTab

    private static let tabs: [(tab: WindowState.InspectorTab, title: String)] = [
        (.info, "Info"),
        (.apps, "Apps"),
    ]

    /// In a window that is not key DH's control drops its glass and shows a
    /// flat track (#e3e3e4 over the panel's #ebebec, the selected segment
    /// #cfcfd0, gray labels, no border); AppKit's keeps a hairline border
    /// there, so the flat track is drawn here.
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        Group {
            if activeState == .inactive {
                inactiveTrack
            } else {
                GlassSegmentedControl(selection: $selection, segments: Self.tabs)
            }
        }
            .frame(maxWidth: .infinity)
            .accessibilityRepresentation {
                Picker("Inspector", selection: $selection) {
                    ForEach(Self.tabs, id: \.tab) { Text($0.title).tag($0.tab) }
                }
                .pickerStyle(.segmented)
            }
    }
}

extension InspectorSegmentedControl {
    fileprivate var inactiveTrack: some View {
        HStack(spacing: 0) {
            ForEach(Self.tabs, id: \.tab) { entry in
                Button { selection = entry.tab } label: {
                    Text(entry.title)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor).opacity(1.6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            if selection == entry.tab {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.primary.opacity(0.11))
                                    .padding(2)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.055)))
    }
}

/// `NSSegmentedControl` bridge for `InspectorSegmentedControl` (IN-01):
/// `segmentDistribution = .fillEqually` so the segments split the full width
/// AppKit gives the control, which a plain `Picker(.segmented)` never
/// receives (see above). `segmentStyle` is left `.automatic` — the system's
/// own Liquid Glass rendering, matching Device Hub's control exactly because
/// it is the same control, not a copy of its look.
private struct GlassSegmentedControl: NSViewRepresentable {
    @Binding var selection: WindowState.InspectorTab
    let segments: [(tab: WindowState.InspectorTab, title: String)]

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: segments.map(\.title),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.segmentChanged(_:))
        )
        control.segmentDistribution = .fillEqually
        control.segmentStyle = .automatic
        control.selectedSegment = segments.firstIndex { $0.tab == selection } ?? 0
        return control
    }

    func updateNSView(_ nsView: NSSegmentedControl, context: Context) {
        context.coordinator.segments = segments
        if let index = segments.firstIndex(where: { $0.tab == selection }), nsView.selectedSegment != index {
            nsView.selectedSegment = index
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, segments: segments)
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<WindowState.InspectorTab>
        var segments: [(tab: WindowState.InspectorTab, title: String)]

        init(selection: Binding<WindowState.InspectorTab>, segments: [(tab: WindowState.InspectorTab, title: String)]) {
            self.selection = selection
            self.segments = segments
        }

        @objc func segmentChanged(_ sender: NSSegmentedControl) {
            guard segments.indices.contains(sender.selectedSegment) else { return }
            selection.wrappedValue = segments[sender.selectedSegment].tab
        }
    }
}

struct InspectorView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace

    var body: some View {
        @Bindable var window = workspace.window

        if workspace.deviceSelection == nil {
            // DH's inspector has nothing to show without a device.
            NoSelectionView()
        } else {
        VStack(spacing: 0) {
            // Device Hub hides the Info/Apps selector while its
            // device-settings panel or its Reports panel is open
            // (`dh-CT-panel.png`, `inspector-dh-reports-2026-09-28.png`: the panel
            // fills the column with no tab row); the toolbar's sliders / doc /
            // info buttons still switch surfaces.
            if workspace.window.inspectorTab != .controls && workspace.window.inspectorTab != .diagnostics {
                InspectorSegmentedControl(selection: $window.inspectorTab)
                    .padding(.horizontal, ParityMetrics.inspectorSegmentedSideInset)
                    .padding(.top, ParityMetrics.inspectorSegmentedTopSpacing)
                    .padding(.bottom, ParityMetrics.inspectorSegmentedBottomSpacing)
            }

            Group {
                switch workspace.window.inspectorTab {
                case .info:
                    DeviceInspectorView()
                case .apps:
                    if case .simulator(let udid)? = workspace.deviceSelection {
                        SimulatorAppsInspectorView(udid: udid)
                    } else if case .physicalApple(let udid)? = workspace.deviceSelection {
                        if let entry = model.physicalInventory.entry(udid: udid) {
                            PhysicalAppsInspectorView(entry: entry)
                        } else {
                            DeviceNoLongerListedState()
                        }
                    } else {
                        AppsInspectorView()
                    }
                case .diagnostics:
                    DiagnosticsInspectorView()
                case .controls:
                    ControlsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // A device with no Controls panel (an Apple Watch or Vision simulator) never shows
        // an empty Settings panel: the inspector falls to Info.
        .onChange(of: workspace.deviceFamily, initial: true) { leaveControlsIfNoPanel() }
        .onChange(of: workspace.window.inspectorTab) { leaveControlsIfNoPanel() }
        }
    }

    private func leaveControlsIfNoPanel() {
        guard workspace.deviceFamily?.hasControlsPanel == false, workspace.window.inspectorTab == .controls else { return }
        workspace.window.inspectorTab = .info
    }
}

private struct DeviceInspectorView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    /// The shown Android device's screen ("1080 × 2400"), read with `wm size`.
    @State private var androidDisplay: String?
    /// Device Hub's Edit Visibility checklist replaces the cards.
    @State private var isEditingVisibility = false

    var body: some View {
        VStack(spacing: 0) {
            infoScroll
            if isEditingVisibility {
                InfoVisibilityDoneButton { isEditingVisibility = false }
            }
        }
        .onChange(of: workspace.deviceSelection) { isEditingVisibility = false }
    }

    private var infoScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ParityMetrics.inspectorCardSpacing) {
                if case .simulator(let udid)? = workspace.deviceSelection,
                   let entry = model.simulators.entry(udid: udid) {
                    SimulatorInfoCards(entry: entry, isEditingVisibility: $isEditingVisibility)
                } else if case .physicalApple(let udid)? = workspace.deviceSelection,
                          let entry = model.physicalInventory.entry(udid: udid) {
                    PhysicalInfoCards(entry: entry, isEditingVisibility: $isEditingVisibility)
                } else if let snapshot = infoSnapshot {
                    // Device Hub's cards for an Android device: Name and OS;
                    // Model, Manufacturer and Serial (its Product Type and
                    // UDID); Display and ABI.
                    // A stopped AVD has no model, serial, display or ABI yet:
                    // a row with nothing to say is left out (it showed "—").
                    let groups: [[(String, String?)]] = [
                        [("Name", snapshot.name), ("OS", snapshot.os)],
                        [("Model", snapshot.model), ("Manufacturer", snapshot.manufacturer), ("Serial", snapshot.serial)],
                        [("Display", androidDisplay), ("ABI", snapshot.abi)],
                    ]
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        let rows = group.compactMap { row in row.1.flatMap { $0 == "—" ? nil : $0 }.map { (row.0, $0) } }
                        if !rows.isEmpty {
                            InspectorCard {
                                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                                    if index > 0 { InspectorDivider() }
                                    InspectorCardRow(label: row.0, value: row.1)
                                }
                            }
                        }
                    }
                } else {
                    InspectorCard {
                        Text("Select a device in the sidebar.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            }
            // DH insets the cards horizontally only: the segmented header's
            // bottom spacing is the gap above the first card.
            .padding(.horizontal, ParityMetrics.inspectorCardInset)
            .padding(.bottom, ParityMetrics.inspectorCardInset)
        }
        .task(id: workspace.inspectorSerial) {
            androidDisplay = nil
            if let serial = workspace.inspectorSerial,
               let device = model.inventory.devices.first(where: { $0.serial == serial })
            {
                await model.inventory.loadInfo(for: device)
                if let adb = model.adbClient,
                   let metrics = await MirrorController.readDisplayMetrics(adb: adb, serial: serial)
                {
                    androidDisplay = "\(metrics.width) × \(metrics.height)"
                }
            }
        }
    }

    /// "Android 16 (API 36)": the version and the level in one value, Device
    /// Hub's OS row.
    static func androidOS(_ info: DeviceInfo) -> String {
        info.apiLevel == "?" ? "Android \(info.androidVersion)" : "Android \(info.androidVersion) (API \(info.apiLevel))"
    }

    private var infoSnapshot: InspectorInfoSnapshot? {
        switch workspace.deviceSelection {
        case .avd(let name):
            guard let card = model.catalog.avdCards.first(where: { $0.name == name }) else {
                return nil
            }
            let info = card.serial.flatMap { model.inventory.deviceInfos[$0] }
            let os: String = if let info {
                Self.androidOS(info)
            } else if let target = card.osDetailTitle {
                target
            } else {
                "—"
            }
            return InspectorInfoSnapshot(
                name: card.displayName,
                os: os,
                model: info?.model ?? card.skin?.name ?? "—",
                manufacturer: info?.manufacturer,
                serial: card.serial ?? "—",
                abi: info?.abi
            )
        case .device(let serial):
            let device = model.inventory.devices.first(where: { $0.serial == serial })
            let info = model.inventory.deviceInfos[serial]
            let os: String = if let info {
                Self.androidOS(info)
            } else {
                device?.isEmulator == true ? "Emulator" : "Physical"
            }
            return InspectorInfoSnapshot(
                name: device?.displayName ?? serial,
                os: os,
                model: info?.model ?? "—",
                manufacturer: info?.manufacturer,
                serial: serial,
                abi: info?.abi
            )
        case .pixel(let skinName):
            let entry = model.catalog.skinCatalog.first(where: { $0.name == skinName })
            let card = model.catalog.avdCards.first(where: { $0.skin?.name == skinName })
            let info = card?.serial.flatMap { model.inventory.deviceInfos[$0] }
            let os: String = if let info {
                Self.androidOS(info)
            } else if let target = card?.osDetailTitle {
                target
            } else {
                "—"
            }
            return InspectorInfoSnapshot(
                name: entry?.displayName ?? skinName,
                os: os,
                model: info?.model ?? entry?.name ?? "—",
                manufacturer: info?.manufacturer,
                serial: card?.serial ?? "—",
                abi: info?.abi
            )
        case .simulator, .physicalApple:
            // `SimulatorInfoCards` and `PhysicalInfoCards` show a listed
            // simulator or physical device; one that is gone shows nothing.
            return nil
        case nil:
            return nil
        }
    }
}

/// A physical iPhone's or iPad's Info, Device Hub's (;
/// `PhysicalInfoLayout`): Name and OS; Capacity, ECID, Model, Product Type,
/// Serial Number and UDID; Display; and the "Edit Visibility" capsule, which
/// swaps the cards for a checklist of every property (Device Hub Pro's own state
/// rows, ticked off by default, are in it). Before the user enables the
/// device only the list's own values show. Once it is enabled (and paired
/// and connected) the four reads refresh on selection and every 10 s while
/// the card is on screen in a visible window.
private struct PhysicalInfoCards: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    let entry: ApplePhysicalEntry
    @Binding var isEditingVisibility: Bool

    /// How often the reads repeat while the card shows.
    static let refreshInterval: Duration = .seconds(10)

    private struct RefreshKey: Equatable {
        let udid: String
        let canRead: Bool
        let isVisible: Bool
    }

    var body: some View {
        let devices = model.physicalDevices
        let info = devices.infos[entry.udid]
        if isEditingVisibility {
            PhysicalInfoVisibilityChecklist(entry: entry, info: info, model: model)
        } else {
            let cards = PhysicalInfoLayout.cards(
                entry: entry,
                info: info,
                visible: model.preferences.physicalInfoVisible
            )
            ForEach(cards.indices, id: \.self) { index in
                InspectorCard {
                    ForEach(cards[index].indices, id: \.self) { row in
                        if row > 0 { InspectorDivider() }
                        infoRow(cards[index][row])
                    }
                }
            }

            if !entry.isEnabled {
                InspectorCard {
                    HStack {
                        Text("Not enabled")
                            .font(.system(size: ParityMetrics.inspectorRowFontSize))
                        Spacer(minLength: 8)
                        Button("Use This Device…") {
                            model.physicalInventory.requestEnable(entry)
                        }
                        .buttonStyle(.link)
                        .font(.system(size: ParityMetrics.inspectorRowFontSize))
                    }
                    .padding(.horizontal, ParityMetrics.inspectorRowTextInset)
                    .frame(height: ParityMetrics.inspectorRowHeight)
                }
            } else if let error = devices.infoErrors[entry.udid] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            if let hint = entry.hint, entry.isEnabled {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            Button("Edit Visibility") { isEditingVisibility = true }
                .buttonStyle(InfoVisibilityCapsuleStyle())
                .frame(maxWidth: .infinity)
                .padding(.top, ParityMetrics.infoEditVisibilityTopGap)
        }
        Color.clear
            .frame(height: 0)
            .task(id: RefreshKey(
                udid: entry.udid,
                canRead: entry.canUseClient,
                isVisible: workspace.window.isWindowVisible
            )) {
                guard entry.canUseClient, workspace.window.isWindowVisible else { return }
                while !Task.isCancelled {
                    await devices.refreshInfo(udid: entry.udid)
                    // Ends early, with the loop, when the task is cancelled.
                    try? await Task.sleep(for: Self.refreshInterval)
                }
            }
    }

    /// The identifiers Device Hub cuts in the middle to the width the row
    /// has: selectable, with the full value in the tooltip.
    @ViewBuilder
    private func infoRow(_ row: PhysicalInfoLayout.Row) -> some View {
        let view = InspectorCardRow(label: row.label, value: row.value)
        switch row.property {
        case .udid, .ecid, .serialNumber:
            view
                .textSelection(.enabled)
                .help(row.value)
        default:
            view
        }
    }
}

/// The physical Info's Edit Visibility checklist: the simulator's layout
/// (`InfoVisibilityChecklist`) over `PhysicalInfoProperty`, keeping its
/// own preference (`physicalInfoVisible`).
private struct PhysicalInfoVisibilityChecklist: View {
    let entry: ApplePhysicalEntry
    let info: PhysicalDeviceInfo?
    let model: AppModel

    var body: some View {
        let resolved = info ?? PhysicalDeviceInfo.make(entry: entry, details: nil, lockState: nil, ddi: nil, displays: nil)
        ForEach(PhysicalInfoProperty.Section.allCases, id: \.self) { section in
            VStack(alignment: .leading, spacing: 0) {
                InspectorHeading(section.title)
                if let subtitle = section.subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                        .padding(.leading, ParityMetrics.inspectorRowTextInset)
                        .padding(.top, 4)
                        .padding(.bottom, -4)
                }
                InspectorCard {
                    ForEach(Array(section.properties.enumerated()), id: \.element) { index, property in
                        if index > 0 { InspectorDivider() }
                        row(property, info: resolved)
                    }
                }
                .padding(.top, 10)
            }
        }
    }

    private func row(_ property: PhysicalInfoProperty, info: PhysicalDeviceInfo) -> some View {
        let isOn = model.preferences.physicalInfoVisible.contains(property)
        return Toggle(isOn: Binding(
            get: { isOn },
            set: { newValue in
                var visible = model.preferences.physicalInfoVisible
                if newValue { visible.insert(property) } else { visible.remove(property) }
                model.preferences.setPhysicalInfoVisible(visible)
            }
        )) {
            InfoTwoColumnLayout {
                Text(property.title)
                    .font(.system(size: ParityMetrics.inspectorRowFontSize))
                    .lineLimit(1)
                Text(PhysicalInfoLayout.value(of: property, entry: entry, info: info) ?? "--")
                    .font(.system(size: ParityMetrics.inspectorRowFontSize))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .toggleStyle(InfoVisibilityToggleStyle())
        .padding(.leading, ParityMetrics.infoEditCheckboxInset)
        .padding(.trailing, ParityMetrics.inspectorRowTextInset)
        .frame(height: ParityMetrics.inspectorRowHeight)
    }
}

/// The message an inspector tab shows for a physical device that is no longer
/// listed.
private struct PhysicalDeviceUnavailableTab: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
    }
}

/// A simulator's Info, Device Hub's (measured on Device Hub 27.0 with an iOS
/// 26.5 simulator, 2026-09-29, `inspector-dh-info-2026-09-28.png`): Name and OS
/// ("iOS 26.5"); Model, Product Type ("iPhone18,3") and UDID (cut in the middle
/// with three dots); Display ("1206 × 2622"); and, for an iPhone, the
/// "Paired Simulators" list. Until 2026-09-29 the tab also showed the device
/// type, runtime, state and a Data row: none is in Device Hub's (Show in Finder
/// is in the ⋯ menu).
struct SimulatorInfoCards: View {
    @Environment(AppModel.self) private var model
    let entry: SimulatorEntry
    @Binding var isEditingVisibility: Bool

    var body: some View {
        if isEditingVisibility {
            InfoVisibilityChecklist(values: values, model: model)
        } else {
            let visible = model.preferences.simulatorInfoVisible
            ForEach(Array(values.cards(visible: visible).enumerated()), id: \.offset) { _, rows in
                InspectorCard {
                    ForEach(Array(rows.enumerated()), id: \.element.property) { index, row in
                        if index > 0 { InspectorDivider() }
                        infoRow(row.property, row.value)
                    }
                }
            }

            // Device Hub's "Paired Simulators" card is not listed: Device Hub Pro pairs no
            // Apple Watch simulators, so its list and +/- footer could never work.

            Button("Edit Visibility") { isEditingVisibility = true }
                .buttonStyle(InfoVisibilityCapsuleStyle())
                .frame(maxWidth: .infinity)
                .padding(.top, ParityMetrics.infoEditVisibilityTopGap)
        }

        Color.clear
            .frame(height: 0)
            .task(id: entry.deviceTypeIdentifier) { await model.simulators.loadDisplayShape(for: entry) }
    }

    /// Device Hub's row: the UDIDs (the CoreDevice ID is the same string) are
    /// cut in the middle to the width the row has, the copy menu and the
    /// full value in the tooltip staying.
    @ViewBuilder
    private func infoRow(_ property: SimulatorInfoProperty, _ value: String) -> some View {
        switch property {
        case .udid, .coreDeviceID:
            InspectorCardRow(label: property.title, value: value, maxValueFraction: ParityMetrics.udidMaxWidthFraction)
                .textSelection(.enabled)
                .contextMenu {
                    Button("Copy UDID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.udid, forType: .string)
                    }
                }
                .help(entry.udid)
        default:
            InspectorCardRow(label: property.title, value: value)
        }
    }

    /// The Display row: the device type's pixels once the simulator has run
    /// (booted now, or `lastUsedAt` set); nil (shown as "--") for one that
    /// never has. Device Hub 27.0 shows "1206 x 2622" for a stopped iPhone 17
    /// that ran once, even in a session that never saw it run, and "--" for
    /// one created a moment ago.
    static func displayText(hasRun: Bool, shape: DisplayShape?) -> String? {
        guard hasRun, let shape else { return nil }
        return "\(shape.width) × \(shape.height)"
    }

    private var values: SimulatorInfoValues {
        SimulatorInfoValues(
            name: entry.name,
            os: entry.osLabel,
            udid: entry.udid,
            isBooted: entry.state == .booted,
            model: entry.modelName,
            productType: entry.modelIdentifier,
            platform: entry.platform,
            display: Self.displayText(
                hasRun: entry.state == .booted || entry.lastUsedAt != nil,
                shape: model.simulators.displayShape(for: entry)
            ),
            lastUsed: entry.lastUsedAt,
            cpuType: SimulatorInfoValues.hostCPU
        )
    }
}

/// The Edit Visibility checklist (Device Hub's, measured on DH 27.0): a
/// small grey heading and a card per section, a tick box, the name and the
/// value on every row. Done is in `InfoVisibilityDoneButton`.
private struct InfoVisibilityChecklist: View {
    let values: SimulatorInfoValues
    let model: AppModel

    var body: some View {
        ForEach(SimulatorInfoProperty.Section.allCases, id: \.self) { section in
            VStack(alignment: .leading, spacing: 0) {
                InspectorHeading(section.title)
                if let subtitle = section.subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                        .padding(.leading, ParityMetrics.inspectorRowTextInset)
                        .padding(.top, 4)
                        .padding(.bottom, -4)
                }
                InspectorCard {
                    ForEach(Array(section.properties.enumerated()), id: \.element) { index, property in
                        if index > 0 { InspectorDivider() }
                        row(property)
                    }
                }
                .padding(.top, 10)
            }
        }
    }

    private func row(_ property: SimulatorInfoProperty) -> some View {
        let isOn = model.preferences.simulatorInfoVisible.contains(property)
        return Toggle(isOn: Binding(
            get: { isOn },
            set: { newValue in
                var visible = model.preferences.simulatorInfoVisible
                if newValue { visible.insert(property) } else { visible.remove(property) }
                model.preferences.setSimulatorInfoVisible(visible)
            }
        )) {
            InfoTwoColumnLayout {
                Text(property.title)
                    .font(.system(size: ParityMetrics.inspectorRowFontSize))
                    .lineLimit(1)
                Text(values.value(of: property) ?? "--")
                    .font(.system(size: ParityMetrics.inspectorRowFontSize))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .toggleStyle(InfoVisibilityToggleStyle())
        .padding(.leading, ParityMetrics.infoEditCheckboxInset)
        .padding(.trailing, ParityMetrics.inspectorRowTextInset)
        .frame(height: ParityMetrics.inspectorRowHeight)
    }
}

/// Device Hub's tick box: a 16 pt rounded square, the accent with a white
/// tick when on, a plain grey square when off, 8 pt left of the row's text.
private struct InfoVisibilityToggleStyle: ToggleStyle {
    /// An inactive window draws the box grey with a dark tick, as DH's does.
    @Environment(\.controlActiveState) private var activeState

    func makeBody(configuration: Configuration) -> some View {
        let inactive = activeState == .inactive
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(configuration.isOn && !inactive ? Color.accentColor : Color.primary.opacity(0.1))
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(inactive ? Color.primary : Color.white)
                    }
                }
                .frame(width: 16, height: 16)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "1" : "0")
    }
}

/// The "Edit Visibility" capsule under the Info cards: a small grey pill
/// (84.5 × 21 pt, 10 pt semibold, measured on DH 27.0).
private struct InfoVisibilityCapsuleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 21)
            .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.07)))
            .contentShape(Capsule())
    }
}

/// The checklist's Done button: DH's full-width accent capsule (248 × 28 pt,
/// grey while the window is inactive) pinned to the bottom of the inspector.
private struct InfoVisibilityDoneButton: View {
    let done: () -> Void
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let inactive = activeState == .inactive
        VStack(spacing: 0) {
            // DH sets the button on a bar with a hairline above it.
            InspectorDivider(leadingInset: 0, trailingInset: 0)
            Button(action: done) {
                Text("Done")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(inactive ? Color.primary : Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .background(Capsule().fill(inactive ? Color.primary.opacity(0.14) : Color.accentColor))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .padding(.horizontal, ParityMetrics.inspectorCardInset + 6)
            .padding(.vertical, 16)
        }
    }
}

/// A small grey section title above a card, Device Hub's ("Paired
/// Simulators"): 10 pt semibold secondary, 10 pt in from the card's edge.
struct InspectorHeading: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, ParityMetrics.inspectorRowTextInset)
            .padding(.bottom, -4)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct InspectorInfoSnapshot {
    let name: String
    let os: String
    let model: String
    let manufacturer: String?
    let serial: String
    let abi: String?
}

/// Device Hub's Reports panel. For a simulator DH shows one placeholder
/// (a slashed page and "Crash, log, spin, and diagnostic reports are
/// unavailable for simulators."); Device Hub Pro keeps its real crash reports, a
/// simulator's `.ips` files from the Mac's reports folder, in a Device Hub card,
/// and shows DH's placeholder when there are none. The live log viewer left the
/// inspector (2026-09-29: a log line wrapped every ten characters in the 260 pt
/// column); an Android device's diagnostics bundle stays, with the logs one
/// click away (`LogsSheet`).
private struct DiagnosticsInspectorView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace

    static let placeholderGlyph = "text.page.slash"
    static let simulatorPlaceholder = "Crash, log, spin, and diagnostic reports are unavailable for simulators."

    var body: some View {
        Group {
            if case .simulator(let udid)? = workspace.deviceSelection {
                // A simulator's crash reports, read from the Mac's reports
                // folder whether it runs or not.
                SimulatorCrashReportsSection(udid: udid)
            } else if case .physicalApple(let udid)? = workspace.deviceSelection {
                // A physical device's crash logs, read through devicectl
                // once the user enabled the device; there is no log stream.
                if let entry = model.physicalInventory.entry(udid: udid) {
                    PhysicalCrashLogsSection(entry: entry)
                } else {
                    DeviceNoLongerListedState(glyph: Self.placeholderGlyph)
                }
            } else if workspace.liveSelectionSerial != nil {
                ScrollView { androidBundleCard }
                    .scrollIndicators(.never)
            } else {
                DHControlsEmptyState(
                    glyph: Self.placeholderGlyph,
                    caption: workspace.deviceSelection == nil
                        ? "Select a device to see its reports."
                        : SelectionRouting.unavailableCaption(
                            for: workspace.deviceSelection,
                            in: workspace.liveRoutingSnapshot,
                            stopped: "Start the device to collect its reports."
                        )
                )
            }
        }
    }

    /// An Android device's diagnostics bundle (spec §6.6): the zip of its logcat
    /// (last 5 minutes), battery and memory dumps, system properties and
    /// device info, and the log window. The button is disabled while a
    /// collection runs.
    private var androidBundleCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            InspectorHeading("Reports")
            DHCard {
                DHControlRow(
                    "Bundle",
                    glyph: "doc.zipper",
                    help: "The last five minutes of logs, battery and memory reports and device details, in one zip."
                ) {
                    HStack(spacing: 8) {
                        if workspace.capture.isCollectingDiagnostics {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Collecting diagnostics")
                        }
                        Button("Download…") {
                            Task { await workspace.capture.downloadDiagnosticsBundle() }
                        }
                        .buttonStyle(.dhPanel)
                        .disabled(workspace.capture.isCollectingDiagnostics)
                    }
                }
                DHHairline()
                DHControlRow("Logs", glyph: "text.alignleft", help: "The device's live logs.") {
                    HStack(spacing: 8) {
                        Button("Focus") { workspace.window.enterLogFocus() }
                            .buttonStyle(.dhPanel)
                            .help("Only the device and its live log, full width (⌥⌘L)")
                        Button("Show…") { workspace.window.isLogsSheetPresented = true }
                            .buttonStyle(.dhPanel)
                    }
                }
            }
        }
        .padding(.horizontal, ParityMetrics.inspectorCardInset)
        .padding(.top, ParityMetrics.controlsPanelTopSpacing)
        .padding(.bottom, ParityMetrics.inspectorCardInset)
    }
}

/// The log window: the log viewer that used to sit in the Reports column, in a
/// sheet of its own size, for the device the stage shows (an Android device's
/// logcat, a booted simulator's unified log). The Device menu presents it
/// (`WindowState.isLogsSheetPresented`).
struct LogsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Logs")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            if let serial = workspace.liveSelectionSerial {
                LogcatView()
                    .onChange(of: serial, initial: true) {
                        workspace.logcat.openLogcatIfNeeded(serial: serial)
                    }
            } else if let udid = readySimulatorUDID {
                LogcatView()
                    .onChange(of: udid, initial: true) {
                        workspace.logcat.openSimulatorLogIfNeeded(udid: udid)
                    }
            } else {
                DHControlsEmptyState(glyph: DiagnosticsInspectorView.placeholderGlyph, caption: "Start a device to read its logs.")
            }
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 480, idealHeight: 640)
    }

    /// The simulator the stage selects, once it is ready (a booting one's
    /// `spawn` would fail).
    private var readySimulatorUDID: String? {
        guard case .simulator(let udid)? = workspace.deviceSelection,
              model.simulatorLifecycle.isReady(udid)
        else { return nil }
        return udid
    }
}

private struct AppsInspectorView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(AppActionDialogs.self) private var appDialogs
    @State private var selectedPackageID: String?
    /// Real-icon cache for the rows. Owned here, not by `AppModel`.
    @State private var icons = AppIconStore()
    /// Keyboard focus of the list: ↑/↓ select, Return launches, Delete asks
    /// to uninstall.
    @FocusState private var isListFocused: Bool
    @FocusState private var isFilterFocused: Bool

    var body: some View {
        if let serial = workspace.inspectorSerial {
            @Bindable var apps = workspace.apps

            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                if workspace.apps.isLoadingApps && workspace.apps.installedAppList.isEmpty {
                                    if workspace.apps.isWaitingForBoot {
                                        ProgressView {
                                            Text("Waiting for Android to finish booting…")
                                                .foregroundStyle(.secondary)
                                        }
                                        .controlSize(.small)
                                        .padding(.vertical, 20)
                                    } else {
                                        ProgressView()
                                            .padding(.vertical, 20)
                                    }
                                } else if workspace.apps.filteredApps.isEmpty {
                                    AppsEmptyState(
                                        message: workspace.apps.appsFilter
                                            .trimmingCharacters(in: .whitespaces).isEmpty
                                            ? workspace.apps.appsScope.emptyLabel
                                            : "No Results",
                                        showAll: workspace.apps.appsScope != .all
                                            && workspace.apps.appsFilter
                                                .trimmingCharacters(in: .whitespaces).isEmpty
                                            ? { workspace.apps.appsScope = .all }
                                            : nil
                                    )
                                } else {
                                    ForEach(workspace.apps.filteredApps, id: \.id) { app in
                                        AppRow(
                                            app: app,
                                            serial: serial,
                                            isSelected: selectedPackageID == app.id
                                        )
                                            .contentShape(Rectangle())
                                            // One tap recognizer, so a single
                                            // click selects at once; a second
                                            // `onTapGesture(count: 2)` made every
                                            // click wait out the double-click
                                            // interval first.
                                            .onTapGesture {
                                                if NSApp.currentEvent?.clickCount == 2 {
                                                    selectedPackageID = app.id
                                                    Task { await workspace.apps.launchApp(package: app.id) }
                                                } else {
                                                    toggleSelection(app.id)
                                                }
                                                isListFocused = true
                                            }
                                            .selectsOnSecondaryClick { selectedPackageID = app.id; isListFocused = true }
                                            .contextMenu {
                                                appMenu(for: app)
                                            }
                                            .accessibilityElement(children: .combine)
                                            .accessibilityAddTraits(
                                                selectedPackageID == app.id
                                                    ? [.isButton, .isSelected]
                                                    : .isButton
                                            )
                                            .accessibilityAction {
                                                toggleSelection(app.id)
                                            }
                                            .accessibilityAction(named: Text("Launch")) {
                                                Task { await workspace.apps.launchApp(package: app.id) }
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
                            moveSelection(direction, proxy: proxy)
                        }
                        .onKeyActivation([.return]) {
                            guard let package = selectedPackageID else { return .ignored }
                            Task { await workspace.apps.launchApp(package: package) }
                            return .handled
                        }
                        .onDeleteCommand {
                            guard let package = selectedPackageID else { return }
                            appDialogs.requestUninstall(package: package, name: AppRow.displayName(for: package))
                        }
                    }

                    // DH's +/− footer: divider above (full-bleed in the
                    // reference), then install/uninstall.
                    InspectorDivider(leadingInset: 0, trailingInset: 0)
                    InspectorActionFooter(
                        isAddingEnabled: true,
                        isRemovingEnabled: selectedPackageID != nil,
                        isBusy: model.isBusy,
                        isInstalling: workspace.apps.isInstallingAPK,
                        addLabel: "Install APK",
                        removeLabel: "Uninstall App",
                        add: chooseAndInstallAPK,
                        remove: uninstallSelection
                    )
                }
                .background(
                    Color.primary.opacity(ParityMetrics.inspectorCardFillOpacity),
                    in: appsListCardShape
                )
                .clipShape(appsListCardShape)
                .padding(.horizontal, ParityMetrics.inspectorCardInset)

                Divider()

                HStack(spacing: 0) {
                    // The whole field part of the capsule — magnifier,
                    // padding, text — focuses the filter under an I-beam.
                    // Only the text line took clicks before, and the field
                    // was half as wide as it looked (it shared the free
                    // space with the spacer).
                    HStack(spacing: 0) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 10)
                        TextField("Filter", text: $apps.appsFilter)
                            .textFieldStyle(.plain)
                            .font(.system(size: ParityMetrics.inspectorAppsFilterFontSize))
                            .focused($isFilterFocused)
                            .padding(.leading, 6)
                    }
                    .frame(maxHeight: .infinity)
                    .textFieldHitArea(Rectangle(), focus: $isFilterFocused)
                    .layoutPriority(1)
                    Spacer(minLength: 6)

                    // DH's scope cell: 1 pt divider then the scope popup.
                    Rectangle()
                        .fill(Color.primary.opacity(ParityMetrics.inspectorAppsScopeDividerOpacity))
                        .frame(
                            width: ParityMetrics.inspectorDividerHeight,
                            height: ParityMetrics.inspectorAppsSeparatorHeight
                        )
                    // The borderless menu style flattens its label to an
                    // AppKit title and truncates it, ignoring Text scaling.
                    // Draw the label ourselves (so "System Apps" can scale
                    // into the audited cell) and overlay an invisible menu
                    // for the interaction.
                    AppsScopePopup(
                        title: workspace.apps.appsScope.label,
                        sections: [
                            .init(items: [
                                (AppsController.AppsScope.all.label, .all),
                                (AppsController.AppsScope.user.label, .user),
                                (AppsController.AppsScope.system.label, .system),
                            ])
                        ],
                        selection: $apps.appsScope
                    )
                }
                .frame(height: ParityMetrics.inspectorAppsFilterHeight)
                .background(
                    Color.primary.opacity(ParityMetrics.inspectorAppsFilterFillOpacity),
                    in: Capsule()
                )
                .padding(.horizontal, ParityMetrics.inspectorCardInset)
                .padding(.top, ParityMetrics.inspectorAppsFilterTopSpacing)
                .padding(.bottom, ParityMetrics.inspectorAppsFilterBottomSpacing)
            }
            .onChange(of: workspace.apps.appsFilter) {
                selectedPackageID = nil
            }
            .onChange(of: workspace.apps.filteredApps) {
                // Uninstall refreshes and scope switches can hide the selected
                // row; `−` must not act on something the tester cannot see.
                selectedPackageID = AppsController.prunedSelection(
                    selectedPackageID,
                    visiblePackageIDs: Set(workspace.apps.filteredApps.map(\.id))
                )
            }
            .task(id: serial) {
                // The selection belongs to the serial whose list supplied it;
                // never let `−` act on a device whose list was never shown.
                selectedPackageID = nil
                // A device switch is the retry point for icons the previous
                // device failed to resolve; it also prunes that device's
                // memoized icons.
                icons.clearDeviceFailures(keepingSerial: serial)
                if workspace.apps.appsSerial != serial {
                    await workspace.apps.loadApps(serial: serial)
                }
            }
            .environment(icons)
        } else {
            DHAppsEmptyState(caption: SelectionRouting.unavailableCaption(
                for: workspace.deviceSelection,
                in: workspace.liveRoutingSnapshot,
                stopped: "Start the device to add or customize apps."
            ))
        }
    }

    /// The row's click selection, shared by the pointer tap and the
    /// accessibility default action so VO-Space toggles exactly like a click.
    private func toggleSelection(_ id: String) {
        selectedPackageID = selectedPackageID == id ? nil : id
    }

    /// ↑/↓ through the visible apps, scrolling the selection into view.
    private func moveSelection(_ direction: MoveCommandDirection, proxy: ScrollViewProxy) {
        let forward: Bool
        switch direction {
        case .down: forward = true
        case .up: forward = false
        default: return
        }
        let ids = workspace.apps.filteredApps.map(\.id)
        guard !ids.isEmpty else { return }
        let next: String
        if let current = selectedPackageID, let index = ids.firstIndex(of: current) {
            next = ids[forward ? min(index + 1, ids.count - 1) : max(index - 1, 0)]
        } else {
            next = forward ? ids[0] : ids[ids.count - 1]
        }
        selectedPackageID = next
        proxy.scrollTo(next)
    }

    /// The row's Device Hub-style action menu (spec §7.3): Launch; the copy
    /// pair; App Info / Copy Data Path in DH's "App Container" slot; then the
    /// tester extras. Clear Data and Uninstall confirm first;
    /// Force Stop is deliberately unconfirmed.
    @ViewBuilder
    private func appMenu(for app: AdbClient.InstalledPackage) -> some View {
        Button("Launch") {
            Task { await workspace.apps.launchApp(package: app.id) }
        }
        Divider()
        Button("Copy Package Name") {
            workspace.apps.copyAppPackageName(app.id)
        }
        // A package with no reported version code (Android older than 8.0 lists none)
        // has nothing to copy: no item.
        if app.versionCode?.isEmpty == false {
            Button("Copy Version") {
                workspace.apps.copyAppVersion(package: app.id)
            }
        }
        Divider()
        Button("App Info") {
            Task { await workspace.apps.openAppInfo(package: app.id) }
        }
        Button("Copy Data Path") {
            workspace.apps.copyAppDataPath(app.id)
        }
        Divider()
        Button("Force Stop") {
            Task { await workspace.apps.forceStopApp(package: app.id) }
        }
        Divider()
        Button("Clear Data…", role: .destructive) {
            appDialogs.requestClearData(
                package: app.id,
                name: AppRow.displayName(for: app.id)
            )
        }
        Button("Uninstall…", role: .destructive) {
            appDialogs.requestUninstall(
                package: app.id,
                name: AppRow.displayName(for: app.id)
            )
        }
    }

    /// DH's list surface: rounded top corners, square bottom against the
    /// panel divider (the reference's bottom corners are not rounded).
    private var appsListCardShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: ParityMetrics.inspectorCardRadius,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: ParityMetrics.inspectorCardRadius,
            style: .continuous
        )
    }

    /// `+` — DH's install control: pick an APK, then hand it to the model.
    private func chooseAndInstallAPK() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an APK to install"
        if let apk = UTType(filenameExtension: "apk") {
            panel.allowedContentTypes = [apk]
        }
        if panel.runModal() == .OK, let url = panel.url {
            Task { await workspace.apps.installAPK(at: url, serial: workspace.inspectorSerial) }
        }
    }

    /// `−` — DH's uninstall control acts on the selected row.
    private func uninstallSelection() {
        guard let package = selectedPackageID else { return }
        selectedPackageID = nil
        Task { await workspace.apps.uninstallApp(package: package) }
    }
}

/// One app row, Device Hub style (IN-03): 26 pt icon tile 14 pt in from the
/// card's edge, name + package id starting at the 52 pt text column (where
/// the dividers start), version right-aligned. The tile shows the APK's real
/// icon once `AppIconStore` has it; until then (and for apps without a usable
/// raster) it keeps the SF placeholder.
private struct AppRow: View {
    let app: AdbClient.InstalledPackage
    /// The inspected device — icons must come from the device whose list this
    /// row belongs to, never the stage's active serial.
    let serial: String
    var isSelected = false
    @Environment(AppIconStore.self) private var icons

    var body: some View {
        HStack(spacing: 0) {
            iconTile
                .padding(.leading, ParityMetrics.inspectorAppsTileInset)

            VStack(alignment: .leading, spacing: 1) {
                // The app's own name once its icon was read ("Example VPN"),
                // the guess from the package id ("Android") until then.
                Text(icons.label(for: app.id, version: app.versionCode) ?? Self.displayName(for: app.id))
                    .font(.system(size: ParityMetrics.inspectorAppsNameFontSize))
                    .lineLimit(1)
                Text(app.id)
                    .font(.system(size: ParityMetrics.inspectorAppsPackageFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.leading, ParityMetrics.inspectorAppsTileTextSpacing)

            Spacer(minLength: 6)

            Text(app.versionCode ?? "")
                .font(.system(size: ParityMetrics.inspectorAppsVersionFontSize))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                // A bare number ("20002000") says nothing by itself.
                .help(app.versionCode.map { "Version code \($0)" } ?? "")
                .accessibilityLabel(app.versionCode.map { "Version code \($0)" } ?? "")
                .padding(.trailing, ParityMetrics.inspectorAppsDividerTrailingInset)
        }
        .frame(height: ParityMetrics.inspectorAppsRowHeight)
        .appRowFocusRing(isSelected)
    }

    /// The 26 pt tile: the same rounded square in both states, the real icon
    /// over its fill (clipped like Android's launcher mask) or the SF glyph.
    private var iconTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ParityMetrics.inspectorAppsTileRadius, style: .continuous)
                .fill(Color.primary.opacity(0.06))

            if let icon = icons.icon(for: app.id, version: app.versionCode, serial: serial) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                AppStoreGlyph()
            }
        }
        .frame(
            width: ParityMetrics.inspectorAppsTileSize,
            height: ParityMetrics.inspectorAppsTileSize
        )
        .clipShape(
            RoundedRectangle(cornerRadius: ParityMetrics.inspectorAppsTileRadius, style: .continuous)
        )
    }

    static func displayName(for id: String) -> String {
        guard let last = id.split(separator: ".").last else { return id }
        return String(last).prefix(1).uppercased() + String(last.dropFirst())
    }
}

/// The shared card footer of Device Hub's Apps card: a `+`/`−` pair on the
/// card's own surface, 24 pt buttons split by a 1 pt divider. The Apps tab
/// adds the inline "Installing…" state.
struct InspectorActionFooter: View {
    var isAddingEnabled = false
    var isRemovingEnabled = false
    /// Set while any app operation runs: `+` and `−` stay disabled through
    /// the operation and its success flash, so a second one cannot start
    /// mid-flash.
    var isBusy = false
    /// Set while an install runs: the row shows the inline "Installing…"
    /// state (the Apps tab only).
    var isInstalling = false
    /// Accessible names for the glyph-only `+`/`−` pair.
    var addLabel = "Add"
    var removeLabel = "Remove"
    var add: () -> Void = {}
    var remove: () -> Void = {}
    var body: some View {
        HStack(spacing: 0) {
            addButton

            Rectangle()
                .fill(Color.primary.opacity(ParityMetrics.inspectorDividerOpacity))
                .frame(
                    width: ParityMetrics.inspectorDividerHeight,
                    height: ParityMetrics.inspectorAppsSeparatorHeight
                )

            Button(action: remove) {
                Image(systemName: "minus")
                    .font(.system(size: ParityMetrics.inspectorAppsFooterIconSize, weight: .medium))
                    // DH greys a disabled footer control.
                    .foregroundStyle(isRemovingEnabled && !isBusy ? Color.primary : Color.primary.opacity(0.3))
                    .frame(
                        width: ParityMetrics.inspectorAppsFooterButtonWidth,
                        height: ParityMetrics.inspectorAppsFooterHeight
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isRemovingEnabled || isBusy)
            .accessibilityLabel(removeLabel)

            if isInstalling {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.leading, ParityMetrics.inspectorAppsInstallSpinnerLeading)
                Text("Installing…")
                    .font(.system(size: ParityMetrics.inspectorAppsInstallLabelFontSize))
                    .foregroundStyle(.secondary)
                    .padding(.leading, ParityMetrics.inspectorAppsInstallLabelLeading)
            }

            Spacer(minLength: 0)
        }
        .frame(height: ParityMetrics.inspectorAppsFooterHeight)
    }

    private var addButton: some View {
        Button(action: add) {
            addButtonLabel
        }
        .buttonStyle(.plain)
        .disabled(!isAddingEnabled || isBusy)
        .accessibilityLabel(addLabel)
    }

    private var addButtonLabel: some View {
        Image(systemName: "plus")
            .font(.system(size: ParityMetrics.inspectorAppsFooterIconSize, weight: .medium))
            .foregroundStyle(isAddingEnabled && !isBusy ? Color.primary : Color.primary.opacity(0.3))
            .frame(
                width: ParityMetrics.inspectorAppsFooterButtonWidth,
                height: ParityMetrics.inspectorAppsFooterHeight
            )
            .contentShape(Rectangle())
    }
}

/// Device Hub-style inspector card: a rounded gray surface holding key/value
/// rows, in the content layer (no glass).
private struct InspectorCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .background(
                Color.primary.opacity(ParityMetrics.inspectorCardFillOpacity),
                in: RoundedRectangle(cornerRadius: ParityMetrics.inspectorCardRadius, style: .continuous)
            )
            .clipShape(
                RoundedRectangle(cornerRadius: ParityMetrics.inspectorCardRadius, style: .continuous)
            )
    }
}

struct InspectorCardRow: View {
    let label: String
    let value: String
    var truncation: Text.TruncationMode = .middle
    /// See `InfoTwoColumnLayout.maxValueFraction`.
    var maxValueFraction: CGFloat?

    var body: some View {
        InfoTwoColumnLayout(maxValueFraction: maxValueFraction) {
            Text(label)
                .font(.system(size: ParityMetrics.inspectorRowFontSize))
                .lineLimit(1)
            valueText
        }
        .padding(.horizontal, ParityMetrics.inspectorRowTextInset)
        .frame(height: ParityMetrics.inspectorRowHeight)
    }

    /// A UDID is cut in the middle to the width the row has, as Device Hub's
    /// text cuts it ("3E4A36D6-25…1225A2ACBA": the split follows the width).
    private var valueText: some View {
        styled(Text(value)).truncationMode(truncation)
    }

    private func styled(_ text: Text) -> some View {
        text
            .font(.system(size: ParityMetrics.inspectorRowFontSize))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
    }
}

/// A row's label on the left and its value on the right: when both do not
/// fit, the longer of the two gives way (Device Hub cuts a long UDID in the
/// middle and a long "Last Connection Date" label at its end, each leaving
/// the other whole), never both at once as a plain `HStack` does.
struct InfoTwoColumnLayout: Layout {
    static let gap: CGFloat = 8
    /// The most of the row the value may take, or nil for what is left.
    /// Device Hub's UDID keeps 76 % (measured on DH 27.0 at 2x: 327 of the
    /// row's 430 px), where the label would leave it 83 %.
    var maxValueFraction: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? (ideals.map(\.width).reduce(0, +) + Self.gap)
        return CGSize(width: width, height: ideals.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let labelIdeal = subviews[0].sizeThatFits(.unspecified)
        let valueIdeal = subviews[1].sizeThatFits(.unspecified)
        var (labelWidth, valueWidth) = Self.widths(label: labelIdeal.width, value: valueIdeal.width, available: bounds.width)
        if let maxValueFraction { valueWidth = min(valueWidth, bounds.width * maxValueFraction) }
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: labelWidth, height: bounds.height)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.maxX, y: bounds.midY),
            anchor: .trailing,
            proposal: ProposedViewSize(width: valueWidth, height: bounds.height)
        )
    }

    /// The widths the label and the value get in `available`.
    static func widths(label: CGFloat, value: CGFloat, available: CGFloat) -> (CGFloat, CGFloat) {
        let room = max(available - gap, 0)
        if label + value <= room { return (label, value) }
        if label <= value { return (label, max(room - label, 0)) }
        return (max(room - value, 0), value)
    }
}

/// DH's 1 pt card divider (IN-02): #dcdcdc over the card fill, inset
/// `inspectorDividerInset` per side like the reference's info cards. The
/// Apps row dividers pass the 52 pt text-column pair, and the Apps footer's
/// divider passes 0/0 (the reference draws it to the card's edges).
struct InspectorDivider: View {
    var leadingInset: CGFloat = ParityMetrics.inspectorDividerInset
    var trailingInset: CGFloat = ParityMetrics.inspectorDividerInset

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(ParityMetrics.inspectorDividerOpacity))
            .frame(height: ParityMetrics.inspectorDividerHeight)
            .padding(.leading, leadingInset)
            .padding(.trailing, trailingInset)
    }
}

// MARK: - Apps row chrome shared by the Android and simulator lists

extension View {
    /// Device Hub's row focus ring: a 2 pt rectangle in the dark accent blue
    /// (#005AD8 over its light-mode accent, measured on Device Hub 27.0:
    /// `inspector-dh-app-menu-2026-09-28.png`) inside the row's frame, on the clicked or
    /// right-clicked row. It replaces the grey selection fill.
    func appRowFocusRing(_ isSelected: Bool) -> some View {
        overlay {
            if isSelected {
                Rectangle()
                    .strokeBorder(AppRowFocusRing.color, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Selects the row when it is right-clicked (or control-clicked), before
    /// its context menu opens, as Device Hub's list does.
    func selectsOnSecondaryClick(_ select: @escaping () -> Void) -> some View {
        modifier(SecondaryClickSelection(select: select))
    }
}

enum AppRowFocusRing {
    /// The accent, darkened to Device Hub's ring blue.
    static var color: Color {
        Color(nsColor: NSColor.controlAccentColor.blended(withFraction: 0.2, of: .black) ?? .controlAccentColor)
    }
}

private struct SecondaryClickSelection: ViewModifier {
    let select: () -> Void

    func body(content: Content) -> some View {
        content.background(SecondaryClickProbe(select: select))
    }
}

/// Watches the window's mouse-downs for one on its own frame: a right or
/// control click selects the row whether or not the pointer was seen
/// hovering first (an inactive window, or a click that arrives with the
/// pointer, sends no hover), so the row shows Device Hub's ring while its
/// context menu is open.
private struct SecondaryClickProbe: NSViewRepresentable {
    let select: () -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.select = select
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.select = select
    }

    final class ProbeView: NSView {
        var select: () -> Void = {}
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard newWindow != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                guard event.type == .rightMouseDown || event.modifierFlags.contains(.control) else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(point), !self.isHiddenOrHasHiddenAncestor { self.select() }
                return event
            }
        }
    }
}

/// The App Store "A" Device Hub draws in every app's tile and its Apps
/// placeholder (the system's "appstore" symbol is private, so it is drawn),
/// measured against DH 27.0's Apps placeholder: three rounded sticks. The
/// "/" stick runs from the apex down to the crossbar and goes on below it as
/// a short foot; the backslash stick crosses it just under the apex, breaks
/// off after the crossing and runs on to the bottom right; the crossbar
/// reaches past both legs. 14 × 13 pt, or larger with `width` (DH's Apps
/// placeholder draws it 36 pt wide).
struct AppStoreGlyph: View {
    var width: CGFloat = 14

    var body: some View {
        Canvas { context, size in
            let unit = size.width / 14
            // Each stick lies on one line, so its pieces stay aligned.
            func slash(_ y: CGFloat) -> CGPoint { CGPoint(x: (8.0 - 0.575 * (y - 1.4)) * unit, y: y * unit) }
            func backslash(_ y: CGFloat) -> CGPoint { CGPoint(x: (5.4 + 0.6 * (y - 1.4)) * unit, y: y * unit) }
            var strokes = Path()
            strokes.move(to: slash(1.4))
            strokes.addLine(to: slash(8.7))
            strokes.move(to: slash(10.4))
            strokes.addLine(to: slash(11.7))
            strokes.move(to: backslash(1.4))
            strokes.addLine(to: backslash(3.8))
            strokes.move(to: backslash(5.9))
            strokes.addLine(to: backslash(12.3))
            strokes.move(to: CGPoint(x: 0.6 * unit, y: 9.15 * unit))
            strokes.addLine(to: CGPoint(x: 12.9 * unit, y: 9.15 * unit))
            context.stroke(
                strokes,
                with: .style(.secondary),
                style: StrokeStyle(lineWidth: 1.55 * unit, lineCap: .round)
            )
        }
        .frame(width: width, height: width * 13 / 14)
        .accessibilityHidden(true)
    }
}

/// Device Hub's Apps placeholder for a device that is off: the App Store
/// glyph over a two-line caption, centred (measured on DH 27.0: 36 pt wide
/// glyph, "Start the simulator to add or customize apps.").
struct DHAppsEmptyState: View {
    let caption: String

    var body: some View {
        DHControlsEmptyState(caption: caption, verticalOffset: ParityMetrics.appsEmptyStateOffset) {
            AppStoreGlyph(width: ParityMetrics.appsEmptyStateGlyphWidth)
        }
    }
}
