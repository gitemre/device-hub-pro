import AppKit
import SwiftUI
import DeviceHubProKit

/// Whether the sidebar list is drawing its selection emphasised: Device
/// Hub's selected row is the accent colour with white text while the list is
/// the window's focus, and turns gray once focus leaves the list (a click on
/// the stage, the search field) or the window stops being key.
private struct SidebarSelectionEmphasizedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var sidebarSelectionEmphasized: Bool {
        get { self[SidebarSelectionEmphasizedKey.self] }
        set { self[SidebarSelectionEmphasizedKey.self] = newValue }
    }
}

/// Device Hub style sidebar: glass + / filter in the column, glass search,
/// circular form-factor icons, title + Emulator/Physical, version trailing.
struct DeviceSidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(AvdActionDialogs.self) private var avdDialogs
    @Environment(SimulatorActionDialogs.self) private var simulatorDialogs
    @Environment(\.openWindow) private var openWindow
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var query = ""
    /// The groups the user collapsed (a group's `SidebarGroup.id`, newline
    /// separated), which survive a relaunch.
    @AppStorage("collapsedSidebarGroups") private var collapsedGroupsStorage = ""
    /// Keyboard focus of the list itself (arrows move the selection). Read
    /// only for the selection's emphasis (a focus change re-draws the list,
    /// which a selection change never does).
    @FocusState private var isListFocused: Bool
    @FocusState private var isSearchFocused: Bool
    /// Whether the list held the keyboard focus when the current mouse press
    /// began. DH's row click never takes the focus itself (measured
    /// 2026-09-29: a click on a row after a click on the stage leaves the
    /// selection gray and the arrow keys dead; a click while the list is
    /// focused keeps it blue), so a release gives the focus back only when
    /// the list had it before the press.
    @State private var listWasFocusedAtPress = false

    /// The first row is revealed with the list at its top (its bottom edge
    /// anchored, which the top clamps), so the section header above it shows
    /// too; any other row scrolls the least that brings it into view.
    static func revealAnchor(index: Int) -> UnitPoint? { index == 0 ? .bottom : .center }

    /// Whether the selection just changed by the user's own click or key in
    /// the list, which shows the row already (the arrow keys scroll by
    /// themselves): only a change made elsewhere is revealed. Revealing a
    /// clicked row moved the list under the pointer.
    static var changeCameFromTheList: Bool {
        guard let type = NSApp?.currentEvent?.type else { return false }
        return [.leftMouseDown, .leftMouseUp, .keyDown].contains(type)
    }

    var body: some View {
        ScrollViewReader { proxy in
            deviceList
                .environment(\.sidebarSelectionEmphasized, isSelectionEmphasized)
                // Memory labels: refreshed while something runs (see
                // `DeviceMemoryMonitor`).
                .task(id: runningDevicesKey) {
                    model.deviceMemory.update(
                        bootedSimulators: Set(model.simulators.visibleSimulators
                            .filter { $0.state == .booted || $0.state == .booting }.map(\.udid)),
                        androidRunning: model.inventory.devices.contains { $0.isEmulator && $0.isOnline }
                    )
                }
                // Keyboard navigation without `List(selection:)`, whose
                // native highlight would replace the audited selection pill
                // (SB-03). The list is focusable like a native list (Tab
                // reaches it); a row click takes the focus back from the
                // AppKit table, which would otherwise swallow the arrows.
                // Return does nothing, as in Device Hub (measured
                // 2026-09-29: it does not start a stopped simulator).
                .focusable()
                .focused($isListFocused)
                .focusEffectDisabled()
                .onMoveCommand { direction in
                    moveSelection(direction, proxy: proxy)
                }
                // Edit ▸ Select All (⌘A) while the list has the focus: every
                // device row the sidebar shows. The search
                // field keeps its own Select All.
                .onCommand(#selector(NSResponder.selectAll(_:))) {
                    model.selectAllRows(visibleOrder, in: workspace)
                }
                // A selection made elsewhere (a new emulator once created, a
                // Start from the menu bar) brings its row into view: the new
                // row sat selected below the fold of a long list.
                .onChange(of: workspace.deviceSelection) { _, selection in
                    guard !Self.changeCameFromTheList,
                          let selection, let index = visibleOrder.firstIndex(of: selection) else { return }
                    proxy.scrollTo(selection, anchor: Self.revealAnchor(index: index))
                }
                // The selected row moving in the sort (Availability puts a
                // device that starts above, one that shuts down below) keeps
                // it in view: a shut-down emulator's row dropped out of sight.
                .onChange(of: workspace.deviceSelection.flatMap { visibleOrder.firstIndex(of: $0) }) { _, index in
                    guard let index, let selection = workspace.deviceSelection else { return }
                    proxy.scrollTo(selection, anchor: Self.revealAnchor(index: index))
                }
                // A rename ending (Return, Esc, a click elsewhere) hands the
                // focus back to the list, where the edit began.
                // A click elsewhere that ended the edit keeps the focus there.
                .onChange(of: isRenaming) { wasRenaming, nowRenaming in
                    if !wasRenaming, nowRenaming {
                        // The name field takes the keyboard: the list's and
                        // the search field's SwiftUI focus must not claim it back.
                        isListFocused = false
                        isSearchFocused = false
                    }
                    if wasRenaming, !nowRenaming, NSApp.currentEvent?.type != .leftMouseDown {
                        isListFocused = true
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    sidebarSearch
                        .padding(.horizontal, ParityMetrics.sidebarSearchOuterInset)
                        .padding(.top, ParityMetrics.sidebarSearchTopSpacing)
                        .padding(.bottom, ParityMetrics.sidebarSearchBottomSpacing)
                }
        }
        // The window opens with the list focused, as DH's does: AppKit hands
        // a new window's focus to its first key view — the search field,
        // with a blinking caret at every launch (`defaultFocus` does not
        // override that on macOS 27).
        .background(InitialListFocus { isListFocused = true })
        // Tab order as in DH (measured 2026-09-29): the first Tab from the
        // stage lands on the list, the next on the search field, and a
        // Shift-Tab from the search field goes back to the list. SwiftUI's
        // own order walks the sidebar top to bottom, search field first.
        .background(SidebarTabMonitor { shift in handleTab(shift: shift) })
        // A click anywhere else in the window (the stage, the toolbar) takes
        // the selection's emphasis away, as it does in DH: SwiftUI leaves
        // the list focused when the click lands on a view that takes no
        // focus itself.
        .background(SidebarPointerMonitor(
            leave: {
                isListFocused = false
                isSearchFocused = false
            },
            pressInside: { isContextClick in
                if isContextClick {
                    // A row's context menu leaves the list as the focus, so
                    // the selection turns blue while it is open (DH).
                    isListFocused = true
                } else {
                    listWasFocusedAtPress = isListFocused
                }
            }
        ))
    }

    /// Handles a Tab or Shift-Tab press in this window; returns whether it
    /// did (the key is then consumed).
    private func handleTab(shift: Bool) -> Bool {
        if isSearchFocused {
            // Leaves the sidebar: Shift-Tab back to the list, Tab to nothing
            // (the loop then starts again at the list).
            if shift { isListFocused = true }
            isSearchFocused = false
            return true
        }
        if isListFocused {
            guard !shift else { return false }
            isListFocused = false
            isSearchFocused = true
            return true
        }
        // Focus is elsewhere; a device that captures keys keeps its Tab.
        guard !shift, !isRenaming else { return false }
        if let responder = NSApp.keyWindow?.firstResponder {
            if responder is MirrorMetalView || responder is NSText || responder is NSControl { return false }
        }
        isListFocused = true
        return true
    }

    /// A row is being renamed in place (the name editor holds the focus,
    /// and the row keeps its selected colour, as in DH).
    private var isRenaming: Bool {
        avdDialogs.renameAvdName != nil || simulatorDialogs.renameTarget != nil
            || model.physicalActions.renameTarget != nil
    }

    private var isSelectionEmphasized: Bool {
        (isListFocused || isRenaming) && controlActiveState == .key
    }

    private var deviceList: some View {
        // Built once per body: the rows arranged into the sort's groups.
        let groups = arrangedGroups
        let hasQuery = !query.isEmpty
        let nothingListed = groups.isEmpty
        let showsAndroidSetup = !hasQuery && !model.adbIsAvailable && !model.preferences.androidSetupDismissed
        let xcodeGuidance = Self.xcodeCardGuidance(
            tooling: model.simulators.tooling,
            dismissed: model.preferences.xcodeHintDismissed,
            hasQuery: hasQuery
        )
        let showsPlatformCard = Self.platformCardShows(
            tooling: model.simulators.tooling,
            runtimesRead: model.simulators.runtimesRead,
            runtimeCount: model.simulators.runtimes.count,
            hasPhysicalIPhone: model.preferences.showPhysicalAppleDevices && !model.physicalInventory.entries.isEmpty,
            dismissed: model.preferences.iosPlatformCardDismissed,
            hasQuery: hasQuery
        )
        let showsIPhoneCard = Self.iphoneCardShows(
            tooling: model.simulators.tooling,
            showsPhysicalDevices: model.preferences.showPhysicalAppleDevices,
            dismissed: model.preferences.iphoneCardDismissed,
            hasQuery: hasQuery
        )
        let physicalFailure = hasQuery || !model.preferences.showPhysicalAppleDevices
            ? nil
            : model.physicalInventory.listError.map(ApplePhysicalInventory.listFailure)
        return List {
            // A search that matches nothing leaves the list blank, headers
            // and all, as DH's does; the empty line is for a filter that
            // leaves nothing.
            if nothingListed, !hasQuery, !showsAndroidSetup, xcodeGuidance == nil, !showsPlatformCard,
               !showsIPhoneCard, physicalFailure == nil, model.avdCreation.jobs.isEmpty {
                Section {
                    // With a card for a platform that cannot be used yet, the
                    // card says it (and carries the button); this line is for
                    // a filter that leaves nothing, or a closed card.
                    Text(Self.emptyListMessage(tooling: model.simulators.tooling))
                        .font(.system(size: ParityMetrics.sidebarSubtitleFontSize))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 6)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } header: {
                    sectionHeader("Available")
                }
            }

            // Xcode is ready but iPhones are not looked for yet (the
            // preference is off by default): one click turns it on. At the
            // top, so a plugged-in iPhone's owner sees it whatever the list
            // holds. Each
            // device still has to be chosen with "Use This Device\u{2026}".
            if showsIPhoneCard {
                Section {
                    SidebarHintCard(
                        symbol: "iphone",
                        message: Self.iphoneCardMessage,
                        actionTitle: Self.iphoneCardActionTitle,
                        action: { model.physicalInventory.setShowing(true) },
                        dismiss: { model.preferences.setIPhoneCardDismissed(true) }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } header: {
                    sectionHeader("iOS")
                }
            }

            // Emulators being made in the background (system image download,
            // then avdmanager): placeholder rows with their progress. They
            // are not devices yet, so they are not selectable.
            if !model.avdCreation.jobs.isEmpty {
                Section {
                    ForEach(model.avdCreation.jobs) { job in
                        AvdCreationRow(job: job, queue: model.avdCreation)
                            .padding(.horizontal, 10)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    sectionHeader("Creating")
                }
            }

            if groups.count == 1 || groups.first?.title == nil {
                // One group (Availability, or Show Groups off): the system's
                // section, whose header shows the disclosure chevron on hover
                // and toggles the whole row.
                ForEach(groups) { group in
                    if let title = group.title {
                        Section(isExpanded: instantly(expansion(of: group.id))) {
                            ForEach(group.rows) { row in
                                deviceRow(row)
                            }
                        } header: {
                            sectionHeader(title)
                        }
                    } else {
                        // Show Groups off: one flat list.
                        Section {
                            ForEach(group.rows) { row in
                                deviceRow(row)
                            }
                        }
                    }
                }
            } else {
                // Several groups: DH's abut (a header row follows the last
                // row of the group above), where the system's sections keep
                // a 13 pt gap between them, so the headers are rows.
                ForEach(groups) { group in
                    GroupHeaderRow(
                        title: group.title ?? "",
                        isExpanded: isExpanded(group.id),
                        toggle: { expansion(of: group.id).wrappedValue.toggle() }
                    )
                    if isExpanded(group.id) {
                        ForEach(group.rows) { row in
                            deviceRow(row)
                        }
                    }
                }
            }

            // No Android tools yet: where Android devices would appear, a
            // card that says so and starts the guided setup.
            if showsAndroidSetup {
                Section {
                    SidebarHintCard(
                        symbol: "smartphone",
                        message: "Android devices and emulators need Google\u{2019}s Android tools.",
                        actionTitle: "Set Up\u{2026}",
                        action: { workspace.window.isAndroidSetupPresented = true },
                        dismiss: { model.androidSetup.dismissCard() }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } header: {
                    sectionHeader("Android")
                }
            }

            // adb's server would not start: a quiet card, not an alert.
            if model.adbServerProblem, !hasQuery {
                Section {
                    SidebarHintCard(
                        symbol: "exclamationmark.triangle",
                        message: "Couldn\u{2019}t start adb.",
                        actionTitle: "Try Again",
                        action: { Task { await model.refreshAndroid() } }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } header: {
                    sectionHeader("Android")
                }
            }

            // No usable Xcode: where iOS simulators and iPhones would appear,
            // a card with the one button that fixes it ("Get Xcode…", or
            // "Open Xcode…" when one is installed but not selected or not
            // finished), instead of grey text at the bottom the Dock hides.
            if let guidance = xcodeGuidance {
                Section {
                    SidebarHintCard(
                        symbol: "iphone",
                        message: guidance.message,
                        actionTitle: guidance.actionTitle,
                        action: {
                            if let url = guidance.actionURL { NSWorkspace.shared.open(url) }
                        },
                        dismiss: { model.preferences.setXcodeHintDismissed(true) },
                        secondaryTitle: "Check Again",
                        secondaryAction: { Task { await model.checkXcodeAgain() } }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } header: {
                    sectionHeader("iOS")
                }
            }

            // Xcode works but has no simulator runtime: simulators cannot be
            // created until a platform is downloaded, so the iOS card says so
            // and opens Xcode's Components settings.
            if showsPlatformCard, SimulatorCreateSheet.addPlatformsURL != nil {
                Section {
                    SidebarHintCard(
                        symbol: "iphone",
                        message: Self.platformCardMessage,
                        actionTitle: Self.platformCardActionTitle,
                        action: { SimulatorCreateSheet.openAddPlatforms() },
                        dismiss: { model.preferences.setIOSPlatformCardDismissed(true) }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } header: {
                    sectionHeader("iOS")
                }
            }

            // Looking for iPhones failed: say so in words, with a retry.
            if let failure = physicalFailure {
                Section {
                    SidebarHintCard(
                        symbol: "exclamationmark.triangle",
                        message: failure.summary,
                        actionTitle: "Try Again",
                        action: { Task { await model.physicalInventory.refreshNow() } },
                        details: failure.details
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } header: {
                    sectionHeader("iPhones")
                }
            }
        }
        .task(id: model.simulators.tooling.guidance != nil) {
            // While the Xcode card shows, notice Xcode getting set up without
            // leaving the app.
            await model.pollXcodeSetup()
        }
        .listStyle(.sidebar)
        // The list may outgrow the sidebar; Device Hub's sidebar shows no
        // scroll chrome, so hide the indicators (scrolling itself keeps
        // working) and the audited 300 pt edge stays clean.
        // `.scrollIndicators(.hidden)` does not reach the AppKit scroll view
        // behind a SwiftUI List (and `.hidden` lets a legacy-scrollbar
        // setting show them anyway), so `.never` is asked for and the
        // enclosing scroller is also configured directly.
        .scrollIndicators(.never)
        .background(SidebarScrollChromeHider())
    }

    /// One device row (a physical Apple device never joins a multi-selection:
    /// a modified click selects it alone).
    @ViewBuilder
    private func deviceRow(_ row: SidebarDeviceRow) -> some View {
        // The selection is observed *inside* the row views: reading
        // `deviceSelection` in this body re-rendered the whole
        // sidebar (and re-synced the window toolbar) on every
        // selection — the flicker when switching devices.
        SidebarDeviceRowView(row: row, selection: row.selection)
            .contentShape(Rectangle())
            .selectsOnRelease { select(row.selection) } modified: { command, shift in
                if case .physicalApple = row.selection {
                    // Never multi-selected: it selects alone.
                    select(row.selection)
                } else {
                    selectModified(row.selection, command: command, shift: shift)
                }
            } released: { focusList() }
            .listRowInsets(EdgeInsets())
            .listRowBackground(SidebarSelectionBackground(selection: row.selection))
            .contextMenu { rowContextMenu(row) }
            .sendFilesDrop(
                controller: workspace.sendFiles,
                platform: row.platform,
                compact: true,
                confirmCertificates: { confirmCertificates($0, for: row) },
                target: { sendFilesTarget(for: row) }
            )
    }

    /// The device a file dropped on `row` (or Send Files… in its menu) goes
    /// to: a running Android device or simulator, an enabled and connected
    /// physical iPhone; nil for a row that cannot take files.
    private func sendFilesTarget(for row: SidebarDeviceRow) -> SendFilesController.Target? {
        switch row.selection {
        case .device(let serial):
            return row.isRunning ? .android(serial: serial) : nil
        case .simulator(let udid):
            return row.isRunning ? .simulator(udid: udid) : nil
        case .physicalApple(let udid):
            return model.physicalInventory.entry(udid: udid)?.canUseClient == true ? .physical(udid: udid) : nil
        case .avd, .pixel:
            return nil
        }
    }

    private func confirmCertificates(_ certificates: [URL], for row: SidebarDeviceRow) {
        guard case .simulator(let udid) = row.selection else { return }
        let name = model.simulators.entry(udid: udid)?.name ?? udid
        simulatorDialogs.requestTrust(certificates: certificates, udid: udid, simulator: name)
    }

    /// A section's expansion, applied without animation: DH collapses and
    /// expands a sidebar section in one frame (MOTION-04, re-measured with a
    /// real click on 2026-09-25), where the list's own row animation took
    /// 175 ms.
    private func instantly(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { binding.wrappedValue = newValue }
            }
        )
    }

    /// A section header (SB-02). The text sits between equal paddings so the
    /// system's hover chevron, centred in the header, lines up with it (DH:
    /// a 32 pt header row, text centred); `sidebarSearchBottomSpacing` gives
    /// back the added top padding, so the text and the first row keep their
    /// audited positions.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: ParityMetrics.sidebarHeaderFontSize))
            .foregroundStyle(.secondary)
            .padding(.leading, ParityMetrics.sidebarHeaderLeadingInset)
            .padding(.top, ParityMetrics.sidebarHeaderBottomSpacing)
            .padding(.bottom, ParityMetrics.sidebarHeaderBottomSpacing + ParityMetrics.sidebarHeaderExtraBottom)
    }

    /// DH's search field (SB-01): the whole capsule is the field — a click
    /// anywhere in it (the magnifier, the padding) focuses the text, and the
    /// pointer is the I-beam over all of it. Only the 16 pt text line took
    /// clicks before. While focused it wears DH's ring (measured 2026-09-29:
    /// the accent at half strength, 4 pt wide, centred on the capsule's
    /// edge), and Esc clears the text and keeps the focus.
    private var sidebarSearch: some View {
        HStack(spacing: ParityMetrics.sidebarSearchIconSpacing) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 13, weight: .medium))
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    // .tertiary measured 1.87:1 against the search field
                    // (invisible); .secondary reads ~3.9:1 (a11y audit F6).
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(
                            width: ParityMetrics.sidebarSearchClearHitSize,
                            height: ParityMetrics.sidebarSearchClearHitSize
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.default)
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: ParityMetrics.sidebarSearchHeight)
        .textFieldHitArea(Capsule(), focus: $isSearchFocused)
        .dhGlassDepth(in: Capsule(), profile: .recessed)
        .liquidGlass(in: Capsule())
        .dhGlassRim(in: Capsule())
        .overlay {
            if isSearchFocused {
                Capsule()
                    .stroke(
                        Color(nsColor: .controlAccentColor).opacity(ParityMetrics.sidebarSearchFocusRingOpacity),
                        lineWidth: ParityMetrics.sidebarSearchFocusRingWidth
                    )
                    .allowsHitTesting(false)
            }
        }
    }

    /// DH's row menus (measured 2026-09-29), per kind: the lifecycle item(s),
    /// then the open-elsewhere items, then Show in Finder with Rename…, Reset
    /// Content and Settings…, Remove…, each group behind a rule. Nothing
    /// follows Remove….
    @ViewBuilder
    private func rowContextMenu(_ row: SidebarDeviceRow) -> some View {
        // A row of a multi-selection offers what acts on all of them first.
        SelectedRowsContextItems(selection: row.selection)
        switch row.selection {
        case .avd(let name):
            avdMenuItems(name, isRunning: row.isRunning)
        case .device(let serial):
            let device = model.inventory.devices.first(where: { $0.serial == serial })
            if let device, !device.isEmulator {
                androidPhoneMenuItems(device, selection: row.selection)
            } else {
                if model.launchOptions.multiWindowEnabled {
                    openInNewWindowItems(row.selection)
                    Divider()
                }
                if let device, device.isOnline {
                    Button("Mirror") {
                        Task { await workspace.mirror(device: device) }
                    }
                }
            }
        case .pixel:
            // The Pixel catalog has no rows any more; a `.pixel` selection
            // only comes from the smoke-test launch option.
            EmptyView()
        case .simulator(let udid):
            if let entry = model.simulators.entry(udid: udid) {
                simulatorMenuItems(entry)
            }
        case .physicalApple(let udid):
            if let entry = model.physicalInventory.entry(udid: udid) {
                physicalMenuItems(entry, selection: row.selection)
            }
        }
        if let target = sendFilesTarget(for: row) {
            Divider()
            Button("Send Files…") {
                Task {
                    await workspace.sendFiles.presentPanel(for: target) { confirmCertificates($0, for: row) }
                }
            }
        }
    }

    /// A physical Apple device row's menu, Device Hub's (measured
    /// 2026-09-29): Stop Screen
    /// Sharing (ends the live view) │ Restart │ the open-elsewhere pair (with
    /// multi-window on) │ Show in Finder, Rename… │ CarPlay Simulator, Collect
    /// sysdiagnose… │ Unpair…, built like the simulator rows' menu; then the
    /// opt-in item ("Use This Device…" or "Stop Using This Device", ours:
    /// nothing is sent to a device that is not enabled). The commands need a
    /// device that is enabled, paired and connected (`PhysicalDeviceActions`).
    @ViewBuilder
    private func physicalMenuItems(_ entry: ApplePhysicalEntry, selection: DeviceSelection) -> some View {
        let preferences = model.preferences
        let actions = model.physicalActions
        let canManage = actions.canManage(entry)
        Button("Stop Screen Sharing") {
            preferences.setPhysicalLiveViewEnabled(false)
        }
        .disabled(!entry.canUseClient || !preferences.physicalLiveViewEnabled)

        Divider()

        Button("Restart") {
            actions.requestRestart(entry)
        }
        .disabled(!canManage)

        Divider()

        if model.launchOptions.multiWindowEnabled {
            openInNewWindowItems(selection)

            Divider()
        }

        Button("Show in Finder") {
            actions.showInFinder(entry)
        }
        Button("Rename…") {
            actions.requestRename(entry)
        }
        .disabled(!canManage)

        Divider()

        // Only on a Mac that has the CarPlay Simulator app.
        if actions.carPlaySimulatorURL != nil {
            Button("CarPlay Simulator") {
                actions.openCarPlaySimulator()
            }
        }
        Button("Collect sysdiagnose…") {
            let udid = entry.udid
            let name = entry.name
            Task { await actions.collectSysdiagnose(udid: udid, name: name) }
        }
        .disabled(!canManage)

        Divider()

        Button("Unpair…") {
            actions.requestUnpair(entry)
        }
        .disabled(!canManage)

        if !entry.isEnabled || !entry.isEnabledByLaunchOption {
            Divider()
            if entry.isEnabled {
                Button("Stop Using This Device") {
                    model.physicalInventory.disable(udid: entry.udid)
                }
            } else {
                Button("Use This Device…") {
                    model.physicalInventory.requestEnable(entry)
                }
            }
        }
    }

    /// A physical Android phone row's menu, in the physical iPhone's
    /// structure where adb has an equivalent: Restart (`adb reboot`) │ the
    /// open-elsewhere pair │ Collect Bug Report… (the sysdiagnose's
    /// counterpart, `adb bugreport`) │ Disconnect… (Unpair…'s, for a wireless
    /// device only). Show in Finder, Rename… and CarPlay Simulator have no
    /// equivalent and are left out.
    @ViewBuilder
    private func androidPhoneMenuItems(_ device: AndroidDevice, selection: DeviceSelection) -> some View {
        let actions = model.physicalActions
        let serial = device.serial
        let name = device.displayName
        let usable = device.isOnline && !actions.isBusy(serial)
        Button("Restart") {
            actions.requestRestartAndroid(serial: serial, name: name)
        }
        .disabled(!usable)

        Divider()

        if model.launchOptions.multiWindowEnabled {
            openInNewWindowItems(selection)

            Divider()
        }

        Button("Collect Bug Report…") {
            Task { await actions.collectBugReport(serial: serial, name: name) }
        }
        .disabled(!usable)

        if AdbClient.isWirelessSerial(serial) {
            Divider()

            Button("Disconnect…") {
                actions.requestDisconnectAndroid(serial: serial, name: name)
            }
            .disabled(!usable)
        }
    }

    /// the multi-window switch (`DHP_MULTIWINDOW`, on unless 0) only: opens this row's
    /// device in a fresh workspace, in a new window or as a new tab of the
    /// key window (`openWorkspaceTab`).
    @ViewBuilder
    private func openInNewWindowItems(_ selection: DeviceSelection) -> some View {
        Button("Open in New Tab") {
            openWorkspaceTab(seed: WorkspaceSeed(selection: selection), keyWindow: NSApp.keyWindow, openWindow: openWindow)
        }
        Button("Open in New Window") {
            openWindow(value: WorkspaceSeed(selection: selection))
        }
    }

    /// The installed-AVD actions, in DH's simulator menu's grouping: Start or
    /// Stop, then (with multi-window on) the open-elsewhere pair, then the
    /// file actions (disabled while the VM runs), each group behind a rule.
    @ViewBuilder
    private func avdMenuItems(_ avdName: String, isRunning: Bool) -> some View {
        if isRunning {
            // The Device menu's and a simulator's word for it.
            Button("Shut Down") {
                Task { await model.stopEmulator(avd: avdName) }
            }
        } else {
            // Like the detail and catalog Start buttons: a second start
            // while one is in flight would boot concurrently.
            Button("Start") {
                Task { await model.startAndMirror(avd: avdName, workspace: workspace) }
            }
            .disabled(model.isBusy)
        }

        if model.launchOptions.multiWindowEnabled {
            Divider()
            openInNewWindowItems(.avd(avdName))
        }

        Divider()

        Button("Show in Finder") {
            model.catalog.revealAVDInFinder(avdName)
        }
        Button("Rename…") {
            avdDialogs.requestRename(avdName)
        }
        .disabled(isRunning)

        Divider()

        Button("Reset Content and Settings…") {
            avdDialogs.requestWipeData(avdName)
        }
        .disabled(isRunning)

        Divider()

        Button("Remove…") {
            avdDialogs.requestDelete(avdName)
        }
        .disabled(isRunning)
    }

    /// A simulator row's menu, Device Hub's (`p2-dh-rowmenu.png`, re-measured
    /// 2026-09-29): Start, or Shut Down and Restart; the open-elsewhere items
    /// (Open in New Tab / Window with multi-window on); Show in Finder and Rename…; Reset Content and
    /// Settings…; Remove… (both confirmed). An item is off while another
    /// operation runs, except those that may stop a boot waiting to be ready
    /// (the lifecycle decides).
    @ViewBuilder
    private func simulatorMenuItems(_ entry: SimulatorEntry) -> some View {
        let lifecycle = model.simulatorLifecycle
        let operation = lifecycle.operations[entry.udid]
        let isRunning = entry.state == .booted || entry.state == .booting
        // A boot that waits to be ready may be interrupted.
        let isFree = operation == nil || operation == .starting
        if isRunning {
            Button("Shut Down") {
                Task { await lifecycle.shutDown(entry.udid) }
            }
            .disabled(!isFree)

            Divider()

            Button("Restart") {
                Task { await lifecycle.restart(entry.udid) }
            }
            .disabled(!isFree)
        } else if entry.isAvailable {
            // A simulator whose runtime is missing cannot start: no Start item.
            Button("Start") {
                Task { await lifecycle.boot(entry.udid) }
            }
            .disabled(operation != nil)
        }

        if isRunning || entry.isAvailable { Divider() }

        // Device Hub's slot here holds Open in New Tab / Window, behind the
        // multi-window flag; there is no hand-off item (round 3).
        if model.launchOptions.multiWindowEnabled {
            openInNewWindowItems(.simulator(entry.udid))

            Divider()
        }

        Button("Show in Finder") {
            if let folder = model.simulators.deviceFolder(udid: entry.udid) {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
        }
        Button("Rename…") {
            simulatorDialogs.requestRename(entry)
        }
        .disabled(!isFree)

        // Nothing to erase without the runtime.
        if entry.isAvailable {
            Divider()

            Button("Reset Content and Settings…") {
                simulatorDialogs.requestErase(entry)
            }
            .disabled(!isFree)
        }

        Divider()

        Button("Remove…") {
            simulatorDialogs.requestDelete(entry)
        }
        .disabled(!isFree)
    }

    /// The Available section's line when no row passes the filter. On a Mac
    /// whose Xcode cannot run simulators (T0) it is the setup card's advice
    /// ("Install Xcode to use iOS Simulators.", "Open Xcode to finish
    /// installing components."), not an empty filter's line.
    static func emptyListMessage(tooling: AppleToolingStatus) -> String {
        if tooling.tier == .t0, let advice = tooling.setupAdvice {
            return advice
        }
        return "No devices match this filter."
    }

    static let iphoneCardMessage = "Show iPhones connected to this Mac. Each one still has to be chosen before Device Hub Pro uses it."
    static let iphoneCardActionTitle = "Show iPhones"

    /// Whether the sidebar offers to turn on looking for iPhones: Xcode is
    /// usable (probed, no guidance, simulators at least T1), the preference is
    /// still off, the card was not closed, and the sidebar is not searched.
    static func iphoneCardShows(
        tooling: AppleToolingStatus,
        showsPhysicalDevices: Bool,
        dismissed: Bool,
        hasQuery: Bool
    ) -> Bool {
        guard !showsPhysicalDevices, !dismissed, !hasQuery else { return false }
        return tooling.isProbed && tooling.tier >= .t1 && tooling.guidance == nil
    }

    static let platformCardMessage = "Download the iOS platform in Xcode to create simulators."
    static let platformCardActionTitle = "Add Platforms in Xcode\u{2026}"

    /// Whether the iOS card asks for a platform download: Xcode is set up
    /// (simctl usable, the probe has answered) but its runtime listing came
    /// back empty. It leaves once any runtime exists or a physical iPhone is
    /// listed, over a search, and after "Don't show again". Without Xcode the
    /// Xcode card speaks instead.
    static func platformCardShows(
        tooling: AppleToolingStatus,
        runtimesRead: Bool,
        runtimeCount: Int,
        hasPhysicalIPhone: Bool,
        dismissed: Bool,
        hasQuery: Bool
    ) -> Bool {
        guard !dismissed, !hasQuery, tooling.isProbed, tooling.tier >= .t1, tooling.guidance == nil else { return false }
        return runtimesRead && runtimeCount == 0 && !hasPhysicalIPhone
    }

    /// The guidance the sidebar's iOS card shows: only once the Xcode probe
    /// has answered and found none usable, never over a search, and not after
    /// "Don't show again". Android is unaffected.
    static func xcodeCardGuidance(
        tooling: AppleToolingStatus,
        dismissed: Bool,
        hasQuery: Bool
    ) -> AppleToolchain.XcodeGuidance? {
        guard !dismissed, !hasQuery, tooling.isProbed else { return nil }
        return tooling.guidance
    }

    /// A row click: selects it and gives the list the keyboard focus, so the
    /// arrow keys continue from here (the AppKit table under the List takes
    /// first responder on the click and would swallow them).
    private func select(_ selection: DeviceSelection) {
        // Only a change is written (every write notifies the lifecycle). A
        // plain click on a row of a multi-selection selects that row alone.
        if workspace.deviceSelection != selection || workspace.multiSelection.isMultiple {
            model.selectOnlyRow(selection, in: workspace)
        }
    }

    /// A ⌘- or ⇧-click, on release: ⌘ adds or removes the row, ⇧ selects
    /// the range from the anchor (added to the selection with ⌘ too).
    private func selectModified(_ selection: DeviceSelection, command: Bool, shift: Bool) {
        if shift {
            model.extendRows(to: selection, in: visibleOrder, adding: command, in: workspace)
        } else {
            model.toggleRow(selection, in: workspace)
        }
    }

    /// The rows the sidebar shows, in its order: the expanded groups'
    /// devices. Evaluated at event time, so this body never reads the
    /// selection.
    private var visibleOrder: [DeviceSelection] {
        arrangedGroups.flatMap { group in
            isExpanded(group.id) ? group.rows.map(\.selection) : []
        }
    }

    /// The groups of the sort mode, over the filtered and searched rows.
    private var arrangedGroups: [SidebarGroup] {
        SidebarArrangement.groups(
            deviceRows,
            mode: workspace.window.deviceSortMode,
            showGroups: workspace.window.deviceShowsGroups
        )
    }

    private var collapsedGroups: Set<String> {
        Set(collapsedGroupsStorage.split(separator: "\n").map(String.init))
    }

    private func isExpanded(_ id: String) -> Bool {
        !collapsedGroups.contains(id)
    }

    private func expansion(of id: String) -> Binding<Bool> {
        Binding(
            get: { isExpanded(id) },
            set: { expanded in
                var collapsed = collapsedGroups
                if expanded { collapsed.remove(id) } else { collapsed.insert(id) }
                collapsedGroupsStorage = collapsed.sorted().joined(separator: "\n")
            }
        )
    }

    /// On the row click's release: the AppKit table under the List takes the
    /// first responder during the click, which would swallow the arrows, so a
    /// list that had the focus before the press gets it back. A list that did
    /// not have it stays unfocused (gray selection), as in DH.
    private func focusList() {
        if listWasFocusedAtPress { isListFocused = true }
    }

    /// The arrow keys: Up/Down move the selection through the visible rows
    /// (the expanded sections' devices) and scroll it into view; with ⇧ they
    /// extend the multi-selection from its anchor. Evaluated at key time, so
    /// this body never reads the selection.
    private func moveSelection(_ direction: MoveCommandDirection, proxy: ScrollViewProxy) {
        let forward: Bool
        switch direction {
        case .down: forward = true
        case .up: forward = false
        default: return
        }
        let order = visibleOrder
        guard let next = SidebarNavigation.neighbor(
            of: workspace.deviceSelection,
            in: order,
            forward: forward
        ) else { return }
        if NSEvent.modifierFlags.contains(.shift) {
            model.extendRows(to: next, in: order, adding: false, in: workspace)
        } else {
            model.selectOnlyRow(next, in: workspace)
        }
        proxy.scrollTo(next)
    }

    // MARK: - Physical Apple devices

    /// Whether physical Apple devices are listed: the preference is on and
    /// the filter admits devices that are not simulators.
    private var showsPhysicalSection: Bool {
        model.physicalInventory.isShowing
            && workspace.window.deviceFilter != .emulators
    }

    /// The listed physical devices, in the same list as the simulators (DH's
    /// sidebar has no group of their own; the sort places them, measured on
    /// 27.0: Recent and Availability put a connected one first, Name puts it
    /// among the names): name, the model under it ("iPhone 12", as in Device
    /// Hub), the iOS version trailing. A connected one counts as in use now.
    private var physicalRows: [SidebarDeviceRow] {
        guard showsPhysicalSection else { return [] }
        return model.physicalInventory.entries.map { entry in
            SidebarDeviceRow(
                selection: .physicalApple(entry.udid),
                title: entry.name,
                subtitle: Self.physicalSubtitle(entry, operation: model.physicalActions.operations[entry.udid]),
                version: entry.sidebarVersion,
                isRunning: entry.isPresent,
                symbol: entry.symbolName,
                isBusy: entry.isRestarting || model.physicalActions.operations[entry.udid] == .collecting,
                isEmulator: false,
                platform: .apple,
                searchText: SidebarDeviceRow.searchFamily(of: entry.modelName),
                platformName: "iOS",
                lastUsed: entry.isPresent ? Date() : nil
            )
        }
    }

    /// The row's second line: the marketing model ("iPhone 12"), else the
    /// family.
    /// While a restart we issued runs, or a sysdiagnose is collected, Device
    /// Hub's line replaces it ("Collecting sysdiagnose...") and a spinner
    /// takes the version's place.
    static func physicalSubtitle(_ entry: ApplePhysicalEntry, operation: PhysicalDeviceActions.Operation? = nil) -> String {
        if entry.isRestarting { return "Restarting\u{2026}" }
        if operation == .collecting { return "Collecting sysdiagnose..." }
        return entry.modelName ?? (entry.isIPad ? "iPad" : "iPhone")
    }

    /// Changes when a simulator boots or shuts down or an emulator goes
    /// online or offline.
    private var runningDevicesKey: [String] {
        model.simulators.visibleSimulators.filter { $0.state == .booted || $0.state == .booting }.map(\.udid)
            + model.inventory.devices.filter { $0.isEmulator && $0.isOnline }.map(\.serial)
    }

    private var deviceRows: [SidebarDeviceRow] {
        var rows: [SidebarDeviceRow] = model.catalog.avdCards.map { card in
            let online = card.serial.flatMap { serial in
                model.inventory.devices.first(where: { $0.serial == serial })?.isOnline
            } ?? false
            let info = card.serial.flatMap { model.inventory.deviceInfos[$0] }
            let version: String? = if online, let release = SidebarDeviceRow.androidVersionText(
                release: info?.androidVersion, apiLevel: info?.apiLevel
            ) {
                release
            } else {
                SidebarDeviceRow.androidVersionText(
                    release: nil,
                    apiLevel: card.target.flatMap {
                        $0.hasPrefix("android-") ? String($0.dropFirst("android-".count)) : nil
                    }
                )
            }
            return SidebarDeviceRow(
                selection: .avd(card.name),
                title: card.displayName,
                subtitle: "Emulator",
                version: version,
                isRunning: online || card.isRunning,
                symbol: Self.symbol(forSkin: card.skin, formFactor: card.formFactor),
                isEmulator: true,
                platform: .android,
                platformName: "Android",
                lastUsed: online || card.isRunning ? Date() : nil,
                memoryBytes: online || card.isRunning
                    ? model.deviceMemory.report.emulatorBytes(avdName: card.name)
                        ?? card.serial.flatMap { model.deviceMemory.report.emulatorBytes(serial: $0) }
                    : nil
            )
        }

        let matchedSerials = Set(model.catalog.avdCards.compactMap(\.serial))
        for device in model.inventory.devices where !matchedSerials.contains(device.serial) {
            rows.append(
                SidebarDeviceRow(
                    selection: .device(device.serial),
                    title: device.displayName,
                    subtitle: device.isEmulator ? "Emulator" : "Physical",
                    version: SidebarDeviceRow.androidVersionText(
                        release: model.inventory.deviceInfos[device.serial]?.androidVersion,
                        apiLevel: model.inventory.deviceInfos[device.serial]?.apiLevel
                    ),
                    isRunning: device.isOnline,
                    // Both an emulator and a physical Android phone get the
                    // same generic phone frame (SB-02, 2026-09-28): "iphone"
                    // here was Apple's own silhouette on an Android row.
                    symbol: "smartphone",
                    isEmulator: device.isEmulator,
                    platform: .android,
                    platformName: "Android",
                    lastUsed: device.isOnline ? Date() : nil,
                    memoryBytes: device.isEmulator && device.isOnline
                        ? model.deviceMemory.report.emulatorBytes(serial: device.serial) : nil
                )
            )
        }

        // Simulators (the default set's, never-used defaults hidden): Device
        // Hub's row, "Simulator" under the name (or the operation in flight)
        // and the OS version trailing.
        for entry in model.simulators.visibleSimulators {
            let lifecycle = model.simulatorLifecycle
            rows.append(
                SidebarDeviceRow(
                    selection: .simulator(entry.udid),
                    title: entry.name,
                    subtitle: entry.sidebarSubtitle(
                        runState: lifecycle.runState(for: entry),
                        operation: lifecycle.operations[entry.udid]
                    ),
                    version: entry.osVersion,
                    isRunning: entry.state == .booted || entry.state == .booting,
                    symbol: entry.symbolName,
                    isEmulator: true,
                    platform: .apple,
                    isAvailable: entry.isAvailable,
                    searchText: SidebarDeviceRow.searchFamily(of: entry.modelName),
                    platformName: entry.platform ?? "iOS",
                    lastUsed: entry.lastUsedAt,
                    addedAt: entry.createdAt,
                    memoryBytes: entry.state == .booted ? model.deviceMemory.bytes(simulator: entry.udid) : nil
                )
            )
        }

        rows += physicalRows

        switch workspace.window.deviceFilter {
        case .all:
            break
        case .emulators:
            rows.removeAll { !$0.isEmulator }
        case .physical:
            rows.removeAll { $0.isEmulator }
        }

        guard !query.isEmpty else { return rows }
        return rows.filter { $0.matches(query: query) }
    }

    static func symbol(forSkin skin: ResolvedSkin?, formFactor: SystemImage.FormFactor = .handheld) -> String {
        if let name = skin?.name {
            let category = SkinResolver.category(forSkinName: name)
            if category != .phone { return symbol(forCategory: category) }
        }
        // No skin, or a plain phone one: a TV, watch or car image still says
        // what it is (an automotive AVD with no skin showed a phone).
        switch formFactor {
        case .tv: return symbol(forCategory: .tv)
        case .wear: return symbol(forCategory: .wear)
        case .automotive: return symbol(forCategory: .automotive)
        case .xr: return symbol(forCategory: .xr)
        case .handheld, .desktop: return "smartphone"
        }
    }

    /// SB-02 (2026-09-28): the small monochrome silhouette DH's own tile
    /// language calls for. A foldable gets `SidebarDeviceIcon.foldableSymbol`,
    /// an open book-style phone drawn in the same frame-and-screen style (the
    /// SF "flipphone" reads as a walkie-talkie and SF Symbols has no
    /// fold-specific glyph) — everything else already had a reasonable
    /// stand-in. Internal (not private) so the mapping is directly testable.
    static func symbol(forCategory category: SkinCatalogEntry.Category) -> String {
        switch category {
        case .phone, .other: return "smartphone"
        case .foldable: return SidebarDeviceIcon.foldableSymbol
        case .tablet: return "ipad"
        case .tv: return "tv"
        case .wear: return "applewatch.side.right"
        case .automotive: return "car"
        case .xr: return "visionpro"
        }
    }
}

/// A group header that is a list row: DH's 32 pt header (the title 8.5 pt
/// under the top edge), with the disclosure chevron on the trailing edge
/// while hovered; a click anywhere on it collapses or expands the group.
private struct GroupHeaderRow: View {
    let title: String
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: ParityMetrics.sidebarHeaderFontSize))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .opacity(isHovered ? 1 : 0)
                .padding(.trailing, 8)
        }
        .padding(.leading, 16 + ParityMetrics.sidebarHeaderLeadingInset)
        .frame(height: 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { toggle() }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
    }
}

/// The sidebar's arrow-key walk.
enum SidebarNavigation {
    /// The row after (or before) `current` in `order`. Without a visible
    /// current row the walk starts at the first (or last) row; at either
    /// end it stays put, like a native list.
    static func neighbor(
        of current: DeviceSelection?,
        in order: [DeviceSelection],
        forward: Bool
    ) -> DeviceSelection? {
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else {
            return forward ? order.first : order.last
        }
        let next = forward ? min(index + 1, order.count - 1) : max(index - 1, 0)
        return order[next]
    }
}

struct SidebarDeviceRow: Hashable, Identifiable {
    let selection: DeviceSelection
    let title: String
    let subtitle: String
    let version: String?
    let isRunning: Bool
    let symbol: String
    /// A long operation runs on this device (a restart, a sysdiagnose): a
    /// spinner shows where the version is.
    var isBusy = false
    /// Whether this row is a virtual device (an AVD, an `emulator-*` adb
    /// device, a simulator): the "Simulators" filter keeps these.
    let isEmulator: Bool
    /// The platform filter's key.
    let platform: DevicePlatform
    /// False for a simulator whose runtime is missing: it is listed in the
    /// Unavailable section.
    var isAvailable = true
    /// Text besides the title the search matches: the device family (measured
    /// on DH 27.0, 2026-09-29: "ipad" lists an iPad simulator named something
    /// else, "iphone" every iPhone, but the model itself does not match:
    /// "A16" misses an iPad (A16) named otherwise and "iphone 17" misses an
    /// iPhone 17 with another name).
    var searchText: String?

    /// "iPhone", "iPad", "Apple TV", "Apple Watch" or "Apple Vision" for a
    /// model name such as "iPad Pro 13-inch (M5)"; nil for anything else.
    static func searchFamily(of model: String?) -> String? {
        guard let model else { return nil }
        return ["iPhone", "iPad", "Apple TV", "Apple Watch", "Apple Vision"].first {
            model.hasPrefix($0)
        }
    }
    /// The Platform and Operating System sorts' key: "iOS", "tvOS", …,
    /// "Android".
    var platformName = "Android"
    /// When the device was last used (a simulator's last boot; a connected
    /// or running device is in use now): the Recent sort's date.
    var lastUsed: Date?
    /// When the device was created, for a device never used (Availability
    /// lists a new simulator by it).
    var addedAt: Date?
    /// The running device's memory (`phys_footprint`, summed over its
    /// processes), nil when not running or not measured yet.
    var memoryBytes: UInt64?

    var id: DeviceSelection { selection }

    /// The Operating System sort's group title: "iOS 26.5".
    var osGroupTitle: String {
        version.map { "\(platformName) \($0)" } ?? platformName
    }

    /// The row's trailing text, Device Hub's "iOS 27.0" style: the OS name and
    /// version ("Android 16", "watchOS 26.5"); the bare name when the version
    /// is not known yet.
    var osLabel: String { osGroupTitle }

    /// An Android row's version: the release the device reports ("16"), else
    /// the release its API level ships with, else "(API 23)" for a level this
    /// build does not know; nil when neither is known.
    static func androidVersionText(release: String?, apiLevel: String?) -> String? {
        if let release, !release.isEmpty, release != "?" { return release }
        guard let apiLevel, !apiLevel.isEmpty, apiLevel != "?" else { return nil }
        return SystemImage.androidRelease(forAPILevel: apiLevel) ?? "(API \(apiLevel))"
    }

    /// Whether the search field's text finds this row: in the title, or in
    /// its device family.
    func matches(query: String) -> Bool {
        title.localizedCaseInsensitiveContains(query)
            || (searchText?.localizedCaseInsensitiveContains(query) ?? false)
    }
}

/// A zero-size probe that hides the sidebar's AppKit scroller chrome.
/// SwiftUI's `scrollIndicators(.hidden)` does not reach the `NSScrollView`
/// a `List(.sidebar)` is built on, and SwiftUI re-applies
/// `hasVerticalScroller` on later layout passes. The probe finds the list's
/// scroll view once, searching outward from itself, and re-asserts the
/// configuration through KVO the moment SwiftUI writes it (a timer alone
/// left the scroller visible for up to half a second after a device switch —
/// the flash). A short retry covers the list not being laid out yet when
/// the probe lands in the window; after that nothing runs periodically.
/// SwiftUI rebuilding the list re-runs `updateNSView`, which re-attaches if
/// the observed scroll view left the window.
struct SidebarScrollChromeHider: NSViewRepresentable {
    @MainActor
    final class Coordinator {
        weak var scrollView: NSScrollView?
        var observations: [NSKeyValueObservation] = []
        var retryTimer: Timer?

        /// Attaches to the sidebar's scroll view near `probe`, retrying every
        /// `retryInterval` (up to `maxRetries`) while the list is not there.
        func attach(from probe: NSView) {
            // `viewDidMoveToWindow` calls again once the probe has a window.
            guard let window = probe.window else { return }
            if let scrollView, scrollView.window === window { return }
            guard let found = SidebarScrollChrome.scrollView(near: probe) else {
                scheduleRetry(from: probe)
                return
            }
            retryTimer?.invalidate()
            retryTimer = nil
            retries = 0
            observe(found)
        }

        private func observe(_ found: NSScrollView) {
            scrollView = found
            SidebarScrollChrome.hide(found)
            // KVO fires synchronously on the thread that sets the value;
            // AppKit sets these on the main thread.
            observations = [
                found.observe(\.hasVerticalScroller, options: [.new]) { scrollView, _ in
                    MainActor.assumeIsolated { SidebarScrollChrome.hide(scrollView) }
                },
                found.observe(\.hasHorizontalScroller, options: [.new]) { scrollView, _ in
                    MainActor.assumeIsolated { SidebarScrollChrome.hide(scrollView) }
                },
            ]
        }

        private var retries = 0
        private static let retryInterval: TimeInterval = 0.25
        private static let maxRetries = 20

        private func scheduleRetry(from probe: NSView) {
            guard retryTimer == nil, retries < Self.maxRetries else { return }
            retries += 1
            // Timer callbacks arrive on the main run loop, so the main actor
            // is already current; `assumeIsolated` states that without a hop.
            retryTimer = Timer.scheduledTimer(withTimeInterval: Self.retryInterval, repeats: false) {
                [weak self, weak probe] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.retryTimer = nil
                    guard let probe else { return }
                    self.attach(from: probe)
                }
            }
        }

        func detach() {
            retryTimer?.invalidate()
            retryTimer = nil
            observations.removeAll()
            scrollView = nil
        }
    }

    /// Reports joining a window, the earliest point the search can run.
    final class ProbeView: NSView {
        var onWindow: (@MainActor (NSView) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { onWindow?(self) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView(frame: .zero)
        let coordinator = context.coordinator
        view.onWindow = { probe in
            // The list lays out in the same pass; look after it.
            DispatchQueue.main.async { [weak probe] in
                MainActor.assumeIsolated {
                    guard let probe else { return }
                    coordinator.attach(from: probe)
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(from: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }
}

/// Finding and configuring the sidebar list's scroll view.
enum SidebarScrollChrome {
    /// The sidebar's list scroll view: the nearest one to `probe` (searching
    /// each ancestor's subtree, innermost first) that hugs the window's
    /// leading edge at sidebar width — the canvas and inspector scroll views
    /// start further right. Stops at the first match instead of collecting
    /// every scroll view in the window.
    @MainActor
    static func scrollView(near probe: NSView) -> NSScrollView? {
        var ancestor = probe.superview
        while let current = ancestor {
            if let match = firstDescendant(of: current, where: isSidebarList) {
                return match
            }
            ancestor = current.superview
        }
        return nil
    }

    @MainActor
    static func isSidebarList(_ scrollView: NSScrollView) -> Bool {
        let frame = scrollView.convert(scrollView.bounds, to: nil)
        return frame.minX < 8 && frame.width < 340
    }

    /// Re-asserting is guarded by reads so the KVO callback's own write
    /// cannot recurse.
    @MainActor
    static func hide(_ scrollView: NSScrollView) {
        if scrollView.hasVerticalScroller { scrollView.hasVerticalScroller = false }
        if scrollView.hasHorizontalScroller { scrollView.hasHorizontalScroller = false }
        if scrollView.verticalScroller?.isHidden == false {
            scrollView.verticalScroller?.isHidden = true
        }
    }

    @MainActor
    private static func firstDescendant(
        of view: NSView,
        where matches: (NSScrollView) -> Bool
    ) -> NSScrollView? {
        for subview in view.subviews {
            if let scrollView = subview as? NSScrollView, matches(scrollView) {
                return scrollView
            }
            if let match = firstDescendant(of: subview, where: matches) {
                return match
            }
        }
        return nil
    }
}

/// Runs `focus` once per window, the first time it turns key (right away if
/// it already is), on the next main-queue turn — after AppKit has picked the
/// window's initial first responder. A sidebar rebuilt later in the same
/// window (collapsed and shown again) does not take the focus back.
private struct InitialListFocus: NSViewRepresentable {
    let focus: () -> Void

    func makeNSView(context: Context) -> NSView {
        Probe(focus: focus)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        /// The windows whose initial focus has been handled (weakly held: a
        /// window reopened later is a new one and gets its initial focus).
        private static let handledWindows = NSHashTable<NSWindow>.weakObjects()

        private let focus: () -> Void
        private var observer: NSObjectProtocol?
        private var hasFired = false

        init(focus: @escaping () -> Void) {
            self.focus = focus
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else {
                // Left its window before it turned key.
                removeObserver()
                return
            }
            guard !hasFired, observer == nil else { return }
            guard !Self.handledWindows.contains(window) else {
                hasFired = true
                return
            }
            if window.isKeyWindow {
                fire()
            } else {
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.fire() }
                }
            }
        }

        private func fire() {
            guard !hasFired else { return }
            hasFired = true
            if let window {
                Self.handledWindows.add(window)
            }
            removeObserver()
            DispatchQueue.main.async { [focus] in focus() }
        }

        private func removeObserver() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
        }
    }
}

/// Tab and Shift-Tab in the probe's window, before the key loop sees them:
/// `handle(shift)` returns true to consume the key.
private struct SidebarTabMonitor: NSViewRepresentable {
    let handle: (_ shift: Bool) -> Bool

    func makeNSView(context: Context) -> NSView { Probe(handle: handle) }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? Probe)?.handle = handle }

    final class Probe: NSView {
        var handle: (Bool) -> Bool
        private var monitor: Any?

        init(handle: @escaping (Bool) -> Bool) {
            self.handle = handle
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, window.isKeyWindow,
                      event.keyCode == 48 else { return event }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard flags.subtracting(.shift).isEmpty else { return event }
                let consumed = MainActor.assumeIsolated { self.handle(flags.contains(.shift)) }
                return consumed ? nil : event
            }
        }
    }
}

/// Watches mouse-downs in the probe's window (the probe is the sidebar's
/// background, so its frame is the sidebar column). One outside the column
/// runs `leave`; one inside runs `pressInside` (true for a context click: a
/// right or Control-click) before the list handles it. The event is only
/// observed, never consumed.
private struct SidebarPointerMonitor: NSViewRepresentable {
    let leave: () -> Void
    let pressInside: (_ isContextClick: Bool) -> Void

    func makeNSView(context: Context) -> NSView { Probe(leave: leave, pressInside: pressInside) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Probe)?.leave = leave
        (nsView as? Probe)?.pressInside = pressInside
    }

    final class Probe: NSView {
        var leave: () -> Void
        var pressInside: (Bool) -> Void
        private var monitor: Any?

        init(leave: @escaping () -> Void, pressInside: @escaping (Bool) -> Void) {
            self.leave = leave
            self.pressInside = pressInside
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let frame = self.convert(self.bounds, to: nil)
                if frame.contains(event.locationInWindow) {
                    let isContext = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
                    MainActor.assumeIsolated { self.pressInside(isContext) }
                } else {
                    MainActor.assumeIsolated { self.leave() }
                }
                return event
            }
        }
    }
}

private extension View {
    /// Selects on mouse-up, as DH's list does (measured 2026-09-29 with a
    /// held button: the row stays unselected, and unpainted, until release;
    /// an earlier "selects on mouse-down" reading was wrong), and not at all
    /// once the press moved (a drag). Runs `released` when the button comes
    /// up. A Control-click is the context menu's and selects nothing. A ⌘- or
    /// ⇧-click runs `modified` instead of `action`.
    func selectsOnRelease(
        _ action: @escaping () -> Void,
        modified: @escaping (_ command: Bool, _ shift: Bool) -> Void,
        released: @escaping () -> Void
    ) -> some View {
        gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    let flags = NSEvent.modifierFlags
                    let moved = hypot(value.translation.width, value.translation.height)
                        > ParityMetrics.sidebarRowDragThreshold
                    if !flags.contains(.control), !moved {
                        if flags.contains(.command) || flags.contains(.shift) {
                            modified(flags.contains(.command), flags.contains(.shift))
                        } else {
                            action()
                        }
                    }
                    released()
                }
        )
    }
}

/// A multi-selected row's context menu starts with the Selected Devices
/// items. Self-observing, like the pill below, so the sidebar's body never
/// reads the multi-selection.
private struct SelectedRowsContextItems: View {
    @Environment(DeviceWorkspace.self) private var workspace
    let selection: DeviceSelection
    @Environment(AppModel.self) private var model

    var body: some View {
        if workspace.multiSelection.isMultiple, workspace.multiSelection.contains(selection) {
            ApplyToSelectedMenuItems(model: model, workspace: workspace, showsShortcuts: false)

            Divider()
        }
    }
}

/// Self-observing selection pill: keeps the parent sidebar body free of
/// `deviceSelection` reads. While the list is the window's focus the pill is
/// the accent colour (DH's `#0070f5`),
/// else the audited gray. The fill crossfades on selection (short HIG fade;
/// Device Hub itself swaps instantly, MOTION-03).
private struct SidebarSelectionBackground: View {
    @Environment(DeviceWorkspace.self) private var workspace
    let selection: DeviceSelection
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sidebarSelectionEmphasized) private var emphasized
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        RoundedRectangle(cornerRadius: ParityMetrics.sidebarSelectionRadius, style: .continuous)
            .fill(isSelected ? fill : Color.clear)
            .padding(.horizontal, ParityMetrics.sidebarSelectionInset)
            .animation(
                reduceMotion ? nil : MotionMetrics.selection,
                value: isSelected
            )
    }

    /// The primary, or a row of the multi-selection: the same pill.
    private var isSelected: Bool {
        workspace.deviceSelection == selection || workspace.multiSelection.contains(selection)
    }

    private var fill: Color {
        if emphasized { return ParityMetrics.sidebarSelectionAccent(isDark: colorScheme == .dark) }
        // A window that is not key draws the paler gray (DH: #e7e7e8 against
        // the key window's unfocused #d7d7d7; the dark value was not measured).
        if controlActiveState != .key, colorScheme != .dark {
            return ParityMetrics.sidebarSelectionInactive
        }
        return Color(white: colorScheme == .dark
            ? ParityMetrics.sidebarSelectionWhiteDark
            : ParityMetrics.sidebarSelectionWhite)
    }
}

/// Device Hub's sidebar icon tile (SB-02, 2026-09-28): a 32 pt circle whose
/// fill and glyph rendering flip with the row's run state, replacing the
/// flat solid-blue-on-white glyph. Measured on DH 27.0's sidebar (light
/// appearance; dark mode not measured, see `ParityMetrics`'s dark constants):
/// booted rows draw a white circle behind the device's SF Symbol in
/// `.palette` mode — a near-black frame over a blue "lit screen" gradient,
/// the two layers DH's own `iphone`/`ipad`/`tv` glyphs already carry; stopped
/// rows draw a light gray circle, a medium-gray frame and a flat lighter-gray
/// screen (no gradient).
struct SidebarDeviceIcon: View {
    let symbol: String
    let isRunning: Bool
    /// The row is the emphasised selection (accent pill): DH draws the tile
    /// and the glyph as translucent white (measured 2026-09-29: the tile is
    /// white at 20 % over the accent, the outline white at about 36 %).
    var isEmphasized = false
    @Environment(\.colorScheme) private var colorScheme

    /// Only a stopped row's glyph and tile turn translucent white on the
    /// accent pill; a booted row keeps its colours on a light tile.
    private var usesTranslucentGlyph: Bool { isEmphasized && !isRunning }

    /// The sentinel `symbol` of a foldable: drawn, not an SF Symbol.
    static let foldableSymbol = "aqa.foldable"

    var body: some View {
        if symbol == Self.foldableSymbol {
            foldableGlyph
        } else {
            symbolGlyph
        }
    }

    /// An open book-style foldable: a rounded frame around two panels with
    /// the hinge between them, in the colours and (about) the 21 pt box of
    /// the other glyphs.
    private var foldableGlyph: some View {
        Canvas { context, size in
            let frame = CGRect(x: 1, y: 1.5, width: size.width - 2, height: size.height - 3)
            let body = Path(roundedRect: frame, cornerRadius: 3)
            context.fill(body, with: .style(screenStyle))
            context.stroke(body, with: .color(frameColor), lineWidth: 1)
            var hinge = Path()
            hinge.move(to: CGPoint(x: size.width / 2, y: frame.minY + 1))
            hinge.addLine(to: CGPoint(x: size.width / 2, y: frame.maxY - 1))
            context.stroke(hinge, with: .color(frameColor), lineWidth: 1)
        }
        .frame(width: 21, height: 17)
        .frame(width: ParityMetrics.sidebarIconDiameter, height: ParityMetrics.sidebarIconDiameter)
        .background(Circle().fill(tileFill))
        .overlay { runningRing }
    }

    @ViewBuilder
    private var runningRing: some View {
        if isRunning && !isEmphasized {
            Circle().inset(by: -0.5).strokeBorder(
                isDark ? Color.white.opacity(0.12) : Color.black.opacity(ParityMetrics.sidebarBootedTileRingOpacity),
                lineWidth: 0.5
            )
        }
    }

    private var symbolGlyph: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.palette)
            .foregroundStyle(
                usesTranslucentGlyph ? AnyShapeStyle(Color.white.opacity(ParityMetrics.sidebarSelectedGlyphOpacity)) : AnyShapeStyle(frameColor),
                usesTranslucentGlyph ? AnyShapeStyle(Color.white.opacity(ParityMetrics.sidebarSelectedScreenOpacity)) : AnyShapeStyle(screenStyle)
            )
            .font(glyphFont)
            .frame(width: ParityMetrics.sidebarIconDiameter, height: ParityMetrics.sidebarIconDiameter)
            .background(Circle().fill(tileFill))
            .overlay {
                // A booted row's white tile has a faint hairline ring in DH,
                // just outside the disc (2x, 2026-09-29: #eaeaeb over the
                // sidebar's #f2f2f3, one pixel wide).
                if isRunning && !isEmphasized {
                    Circle().inset(by: -0.5).strokeBorder(
                        isDark ? Color.white.opacity(0.12) : Color.black.opacity(ParityMetrics.sidebarBootedTileRingOpacity),
                        lineWidth: 0.5
                    )
                }
            }
    }

    /// DH fits every glyph into a 21 pt box (2026-09-29, AX frames: the
    /// phone 12 x 21, the iPad 15 x 21, the TV 21 x 17) and draws a frame
    /// under 1 pt; the fixed medium 17 pt glyph drew a phone 11 x 18 pt with
    /// a 1.5 pt frame. Sizes and weights per family reproduce those boxes
    /// (measured by rendering the symbols at candidate sizes).
    private var glyphFont: Font {
        if symbol.hasPrefix("iphone") { return .system(size: 21, weight: .thin) }
        if symbol == "tv" { return .system(size: 18, weight: .thin) }
        if symbol.hasPrefix("ipad") { return .system(size: 19.5, weight: .thin) }
        return .system(size: ParityMetrics.sidebarIconGlyphSize, weight: .medium)
    }

    private var tileFill: Color {
        guard isEmphasized else { return tileColor }
        return Color.white.opacity(
            isRunning ? ParityMetrics.sidebarSelectedBootedTileOpacity : ParityMetrics.sidebarSelectedTileOpacity
        )
    }

    private var isDark: Bool { colorScheme == .dark }

    /// A stopped row's tile, frame and screen are black at fixed opacities
    /// over whatever is behind them (DH 27.0, 2x, 2026-09-29: over the key
    /// window's #ededed the tile reads #e2e2e2, over the selected gray #d7d7d7
    /// #cdcdcd, over an inactive window's #f2f2f3 #e7e7e8: the same 4.6 %; the
    /// screen 12.2 % and the frame 29.3 % in total, drawn over the tile).
    /// Flat colours measured on the inactive window left the tile 5 levels
    /// too light in a key window.
    private var tileColor: Color {
        if isRunning { return isDark ? ParityMetrics.sidebarIconTileBootedDark : ParityMetrics.sidebarIconTileBooted }
        return isDark
            ? ParityMetrics.sidebarIconTileStoppedDark
            : Color.black.opacity(ParityMetrics.sidebarIconTileStoppedOpacity)
    }

    private var frameColor: Color {
        if isRunning { return isDark ? ParityMetrics.sidebarIconFrameBootedDark : ParityMetrics.sidebarIconFrameBooted }
        return isDark
            ? ParityMetrics.sidebarIconFrameStoppedDark
            : Color.black.opacity(ParityMetrics.sidebarIconFrameStoppedOpacity)
    }

    private var screenStyle: some ShapeStyle {
        if isRunning {
            AnyShapeStyle(LinearGradient(
                colors: [
                    ParityMetrics.sidebarIconScreenGradientTopBooted,
                    ParityMetrics.sidebarIconScreenGradientBottomBooted,
                ],
                startPoint: .top,
                endPoint: .bottom
            ))
        } else {
            AnyShapeStyle(
                isDark
                    ? ParityMetrics.sidebarIconScreenStoppedDark
                    : Color.black.opacity(ParityMetrics.sidebarIconScreenStoppedOpacity)
            )
        }
    }
}

private struct SidebarDeviceRowView: View {
    @Environment(DeviceWorkspace.self) private var workspace
    let row: SidebarDeviceRow
    let selection: DeviceSelection
    @Environment(AppModel.self) private var model
    @Environment(AvdActionDialogs.self) private var avdDialogs
    @Environment(SimulatorActionDialogs.self) private var simulatorDialogs
    @Environment(\.sidebarSelectionEmphasized) private var listEmphasized
    @Environment(\.controlActiveState) private var controlActiveState
    /// The AVD names in use, read when an AVD rename starts (its validation).
    @State private var existingAvdNames: [String] = []

    private var isSelected: Bool {
        workspace.deviceSelection == selection || workspace.multiSelection.contains(selection)
    }

    /// The row is drawn on the accent pill: white text, translucent tile.
    private var isEmphasized: Bool { isSelected && listEmphasized }

    var body: some View {
        HStack(spacing: ParityMetrics.sidebarRowContentSpacing) {
            SidebarDeviceIcon(symbol: row.symbol, isRunning: row.isRunning, isEmphasized: isEmphasized)

            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    renameField
                } else {
                    Text(row.title)
                        .font(.system(size: ParityMetrics.sidebarTitleFontSize, weight: .semibold))
                        .foregroundStyle(titleStyle)
                        .lineLimit(1)
                }
                subtitleText
            }
            .frame(maxWidth: isRenaming ? .infinity : nil, alignment: .leading)

            if !isRenaming {
                Spacer(minLength: 8)
            }

            // Apply to Selected works on this device: a spinner where the
            // version shows.
            if row.isBusy || model.multiDevice.rowStates[BatchTargeting.id(for: selection)] != nil {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Working")
            } else {
                Text(row.osLabel)
                    .font(.system(size: ParityMetrics.sidebarVersionFontSize))
                    .monospacedDigit()
                    .foregroundStyle(secondaryStyle)
                    // While renaming, the version keeps a fixed column, so
                    // the name field ends where DH's does.
                    .frame(width: isRenaming ? ParityMetrics.sidebarRenameVersionColumnWidth : nil, alignment: .trailing)
            }
        }
        .frame(minHeight: ParityMetrics.sidebarRowHeight)
        // While renaming, the name field must be reachable (VoiceOver found
        // no field at all: the row's children were all ignored).
        .accessibilityElement(children: isRenaming ? .contain : .ignore)
        .accessibilityLabel(DeviceRowAccessibility.label(
            title: row.title, subtitle: row.subtitle, memoryBytes: row.memoryBytes, osLabel: row.osLabel))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            model.selectOnlyRow(selection, in: workspace)
        }
    }

    /// The second line: the subtitle, then the memory ("1.8 GB") of a
    /// running device, orange from 4 GB (not on the accent pill, where
    /// orange would not read).
    private var subtitleText: some View {
        let memory = DeviceMemoryMonitor.label(row.memoryBytes)
        return HStack(spacing: 0) {
            Text(row.subtitle)
            if let memory {
                Text(" \u{00B7} \(memory.text)")
                    .foregroundStyle(memory.warning && !isEmphasized ? AnyShapeStyle(Color.orange) : secondaryStyle)
            }
        }
        .font(.system(size: ParityMetrics.sidebarSubtitleFontSize))
        .foregroundStyle(secondaryStyle)
        .lineLimit(1)
        .help(DeviceRowAccessibility.tooltip(memoryBytes: row.memoryBytes, isAndroidEmulator: row.isEmulator && row.platformName == "Android"))
    }

    /// White on the accent pill; in a window that is not key DH dims the
    /// title to the secondary ink (#8c8c8c, darkest title pixel on a 2x
    /// capture, 2026-09-29; it is black in the key window).
    private var titleStyle: AnyShapeStyle {
        if isEmphasized { return AnyShapeStyle(Color.white) }
        return controlActiveState == .key ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }

    private var secondaryStyle: AnyShapeStyle {
        isEmphasized
            ? AnyShapeStyle(Color.white.opacity(ParityMetrics.sidebarSelectedSecondaryTextOpacity))
            : AnyShapeStyle(.secondary)
    }

    // MARK: - Inline rename

    /// Which kind of rename this row is in the middle of, if any.
    private enum Rename {
        case avd(String)
        case simulator(udid: String, name: String)
        case physical(udid: String, name: String)
    }

    private var rename: Rename? {
        switch selection {
        case .avd(let name) where avdDialogs.renameAvdName == name:
            return .avd(name)
        case .simulator(let udid):
            guard let target = simulatorDialogs.renameTarget, target.udid == udid else { return nil }
            return .simulator(udid: udid, name: target.name)
        case .physicalApple(let udid):
            guard let target = model.physicalActions.renameTarget, target.udid == udid else { return nil }
            return .physical(udid: udid, name: target.name)
        default:
            return nil
        }
    }

    private var isRenaming: Bool { rename != nil }

    /// DH's name editor in the title's place (measured 2026-09-29: the
    /// field starts 2 pt left of the title's text, is the title line's
    /// height, and ends 6 pt before the version).
    private var renameField: some View {
        SidebarInlineRenameField(
            text: draftBinding,
            isValid: draftIsValid,
            commit: commitRename,
            cancel: cancelRename
        )
        .frame(height: ParityMetrics.sidebarRenameFieldHeight)
        .padding(.leading, -ParityMetrics.sidebarRenameFieldLeadingInset)
        .task { existingAvdNames = model.catalog.existingAvdNames() }
    }

    private var draftBinding: Binding<String> {
        switch rename {
        case .avd:
            Binding(get: { avdDialogs.renameDraft }, set: { avdDialogs.renameDraft = $0 })
        case .simulator:
            Binding(get: { simulatorDialogs.renameDraft }, set: { simulatorDialogs.renameDraft = $0 })
        case .physical:
            Binding(get: { model.physicalActions.renameDraft }, set: { model.physicalActions.renameDraft = $0 })
        case nil:
            .constant("")
        }
    }

    private var draftIsValid: Bool {
        switch rename {
        case .avd(let name):
            SidebarRenameOutcome.avd(draft: avdDialogs.renameDraft, current: name, existing: existingAvdNames) != .refused
        case .simulator, .physical, nil:
            // An unchanged or empty name is not an error, just nothing to apply.
            true
        }
    }

    /// Applies the draft. An unchanged name ends the edit (nothing to
    /// rename); a refused one (an AVD name that is invalid or taken, an
    /// empty simulator name) leaves it open.
    private func commitRename() -> Bool {
        switch rename {
        case .avd(let name):
            switch SidebarRenameOutcome.avd(draft: avdDialogs.renameDraft, current: name, existing: existingAvdNames) {
            case .unchanged:
                avdDialogs.renameAvdName = nil
            case .apply(let newName):
                avdDialogs.renameAvdName = nil
                Task { await model.catalog.renameAVD(name, to: newName) }
            case .refused:
                return false
            }
            return true
        case .simulator(let udid, let name):
            switch SidebarRenameOutcome.simulator(draft: simulatorDialogs.renameDraft, current: name) {
            case .unchanged:
                simulatorDialogs.renameTarget = nil
            case .apply(let newName):
                simulatorDialogs.renameTarget = nil
                Task { await model.simulatorLifecycle.rename(udid, to: newName) }
            case .refused:
                return false
            }
            return true
        case .physical(let udid, let name):
            let actions = model.physicalActions
            switch SidebarRenameOutcome.simulator(draft: actions.renameDraft, current: name) {
            case .unchanged:
                actions.renameTarget = nil
            case .apply(let newName):
                actions.renameTarget = nil
                Task { await actions.rename(udid: udid, from: name, to: newName) }
            case .refused:
                return false
            }
            return true
        case nil:
            return true
        }
    }

    private func cancelRename() {
        model.physicalActions.renameTarget = nil
        avdDialogs.renameAvdName = nil
        simulatorDialogs.renameTarget = nil
    }
}
