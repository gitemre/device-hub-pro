import AppKit
import SwiftUI
import DeviceHubProKit

// The toolbar's "..." pill and its menu, shared by the main window and the
// compact window: a leading button (compact ↔ expand) and Device Hub's device
// menu (Shut Down / Restart, Show in Finder, Rename…, Reset Content and
// Settings…, Remove…).
//
// The menu is an AppKit `NSMenu` popped up under the toolbar, as Device Hub's
// is (measured on DH 27.0: the menu's top edge is the toolbar's bottom edge,
// 5 pt left of the button group, and the "..." platter stays drawn while it
// is open); SwiftUI's own toolbar menus opened over the toolbar with no
// pressed platter.

/// One row of a pop-up menu: an item, or the rule between groups.
enum PopUpMenuEntry {
    case item(title: String, isEnabled: Bool, action: () -> Void)
    /// Shown while Option is held, in place of the item before it.
    case alternate(title: String, isEnabled: Bool, action: () -> Void)
    case separator
}

/// Target of the items' actions, retained while the menu shows.
@MainActor
final class PopUpMenuTarget: NSObject {
    private var actions: [() -> Void] = []

    func menu(for entries: [PopUpMenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        actions = []
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .item(let title, let isEnabled, let action):
                menu.addItem(makeItem(title, isEnabled, action))
            case .alternate(let title, let isEnabled, let action):
                let item = makeItem(title, isEnabled, action)
                item.isAlternate = true
                item.keyEquivalentModifierMask = [.option]
                menu.addItem(item)
            }
        }
        return menu
    }

    private func makeItem(_ title: String, _ isEnabled: Bool, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: "")
        item.target = self
        item.tag = actions.count
        item.isEnabled = isEnabled
        actions.append(action)
        return item
    }

    @objc private func fire(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }
}

/// Covers a toolbar button and pops `entries()` up on mouse-down, under the
/// toolbar. `isOpen` is true while the menu shows (the button's pressed
/// platter).
struct PopUpMenuHitArea: NSViewRepresentable {
    let entries: () -> [PopUpMenuEntry]
    @Binding var isOpen: Bool
    @Binding var isHovered: Bool
    var isEnabled = true

    func makeNSView(context: Context) -> HitView {
        let view = HitView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: HitView, context: Context) {
        context.coordinator.entries = entries
        context.coordinator.isEnabled = isEnabled
        context.coordinator.setOpen = { isOpen = $0 }
        context.coordinator.setHovered = { isHovered = $0 }
    }

    func makeCoordinator() -> Coordinator { Coordinator(entries: entries) }

    @MainActor
    final class Coordinator {
        var entries: () -> [PopUpMenuEntry]
        var isEnabled = true
        var setOpen: (Bool) -> Void = { _ in }
        var setHovered: (Bool) -> Void = { _ in }
        let target = PopUpMenuTarget()

        init(entries: @escaping () -> [PopUpMenuEntry]) {
            self.entries = entries
        }
    }

    final class HitView: NSView {
        var coordinator: Coordinator?

        override var isFlipped: Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { nil }
        override func isAccessibilityElement() -> Bool { false }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self
            ))
        }

        override func mouseEntered(with event: NSEvent) {
            MainActor.assumeIsolated { coordinator?.setHovered(true) }
        }

        override func mouseExited(with event: NSEvent) {
            MainActor.assumeIsolated { coordinator?.setHovered(false) }
        }

        override func mouseDown(with event: NSEvent) {
            MainActor.assumeIsolated { present() }
        }

        /// The menu, its top-left under the toolbar and 5 pt left of the
        /// button group's leading edge.
        @MainActor
        private func present() {
            guard let coordinator, coordinator.isEnabled, let window else { return }
            let menu = coordinator.target.menu(for: coordinator.entries())
            let inWindow = convert(NSPoint(x: bounds.minX - Self.leadingOutset, y: 0), to: nil)
            // The content layout rect's top edge is the toolbar's bottom edge.
            let toolbarBottom = window.contentLayoutRect.maxY
            let point = window.contentView.map {
                $0.convert(NSPoint(x: inWindow.x, y: toolbarBottom - Self.topOverlap), from: nil)
            } ?? .zero
            coordinator.setOpen(true)
            // Let the pressed platter draw before the menu takes over.
            DispatchQueue.main.async {
                _ = menu.popUp(positioning: nil, at: point, in: window.contentView)
                coordinator.setOpen(false)
            }
        }

        /// A pop-up menu's frame reaches this far above its first item.
        static let topOverlap: CGFloat = 5

        /// DH's menu starts 5 pt before the platter group (the group is
        /// 41 pt wide around a 30 pt platter: 5.5 pt of margin).
        static let leadingOutset: CGFloat = 7.5
    }
}

/// The device's "..." menu as pop-up entries: Device Hub's (re-measured 2026-09-29): Start, or Shut Down (Force Shut Down on Option)
/// while running, Restart, then Show in Finder and Rename…, Reset Content
/// and Settings…, Remove…. Every item dispatches to the same actions the
/// sidebar's row menu calls.
@MainActor
struct DeviceLifecycleMenu {
    let model: AppModel
    let workspace: DeviceWorkspace
    let avdDialogs: AvdActionDialogs
    let simulatorDialogs: SimulatorActionDialogs
    /// Run before Rename… (the compact window has no sidebar row to edit in,
    /// so it brings the main window back first).
    var beforeRename: (() -> Void)?
    /// Opens a workspace window or tab (`Open in New Tab / Window`, with
    /// multi-window on).
    var openWindow: OpenWindowAction?

    var section: ToolbarDeviceMenu.Section {
        switch workspace.deviceSelection {
        case .avd(let name):
            guard let card = model.catalog.avdCards.first(where: { $0.name == name }) else { return .unavailable }
            return ToolbarDeviceMenu.avdSection(isRunning: card.isRunning, isBusy: model.isBusy)
        case .simulator(let udid):
            guard let entry = model.simulators.entry(udid: udid) else { return .unavailable }
            let operation = model.simulatorLifecycle.operations[udid]
            let isRunning = entry.state == .booted || entry.state == .booting
            let isFree = operation == nil || operation == .starting
            return ToolbarDeviceMenu.simulatorSection(isRunning: isRunning, isFree: isFree, isAvailable: entry.isAvailable)
        case .device, .pixel, .physicalApple, nil:
            return .unavailable
        }
    }

    /// A physical iPhone's menu: Device Hub's items that have a route here
    /// (`PhysicalMenuLayout.moreEntries`).
    private func physicalEntries(udid: String) -> [PopUpMenuEntry] {
        let entry = model.physicalInventory.entry(udid: udid)
        let selection = DeviceSelection.physicalApple(udid)
        let window = openWindow
        return PhysicalMenuLayout.moreEntries(
            canUseClient: entry?.canUseClient == true,
            liveViewOn: workspace.physicalLive.liveViewEnabled,
            multiWindow: model.launchOptions.multiWindowEnabled && window != nil
        ).map { row in
            switch row {
            case .separator:
                return .separator
            case .stopScreenSharing(let isEnabled):
                return .item(title: row.title ?? "", isEnabled: isEnabled) { workspace.physicalLive.setLiveView(false) }
            case .openInNewTab:
                return .item(title: row.title ?? "", isEnabled: true) {
                    if let window {
                        openWorkspaceTab(seed: WorkspaceSeed(selection: selection), keyWindow: NSApp.keyWindow, openWindow: window)
                    }
                }
            case .openInNewWindow:
                return .item(title: row.title ?? "", isEnabled: true) {
                    window?(value: WorkspaceSeed(selection: selection))
                }
            }
        }
    }

    func entries() -> [PopUpMenuEntry] {
        if case .physicalApple(let udid)? = workspace.deviceSelection { return physicalEntries(udid: udid) }
        let section = section
        // Groups, each drawn only when it has an item; a rule between groups.
        var groups: [[PopUpMenuEntry]] = []
        if let lifecycle = section.lifecycle {
            var group: [PopUpMenuEntry] = [
                .item(title: lifecycle.title, isEnabled: lifecycle.isEnabled, action: lifecycleAction),
            ]
            if case .simulator? = workspace.deviceSelection, section.restart != nil {
                group.append(.alternate(
                    title: DeviceMenuAlternates.forceShutDownTitle,
                    isEnabled: lifecycle.isEnabled,
                    action: lifecycleAction
                ))
            }
            groups.append(group)
        }
        if let restart = section.restart {
            groups.append([.item(title: restart.title, isEnabled: restart.isEnabled, action: restartAction)])
        }
        var files: [PopUpMenuEntry] = []
        if let item = section.showInFinder { files.append(.item(title: item.title, isEnabled: item.isEnabled, action: showInFinder)) }
        if let item = section.rename { files.append(.item(title: item.title, isEnabled: item.isEnabled, action: rename)) }
        if !files.isEmpty { groups.append(files) }
        if let item = section.reset { groups.append([.item(title: item.title, isEnabled: item.isEnabled, action: reset)]) }
        if let item = section.remove { groups.append([.item(title: item.title, isEnabled: item.isEnabled, action: remove)]) }
        var entries: [PopUpMenuEntry] = []
        for group in groups {
            if !entries.isEmpty { entries.append(.separator) }
            entries.append(contentsOf: group)
        }
        return entries
    }

    private func restartAction() {
        guard case .simulator(let udid) = workspace.deviceSelection else { return }
        Task { await model.simulatorLifecycle.restart(udid) }
    }

    private func lifecycleAction() {
        switch workspace.deviceSelection {
        case .avd(let name):
            if model.catalog.avdCards.first(where: { $0.name == name })?.isRunning == true {
                Task { await model.stopEmulator(avd: name) }
            } else {
                Task { await model.startAndMirror(avd: name, workspace: workspace) }
            }
        case .simulator(let udid):
            guard let entry = model.simulators.entry(udid: udid) else { return }
            let lifecycle = model.simulatorLifecycle
            if entry.state == .booted || entry.state == .booting {
                Task { await lifecycle.shutDown(udid) }
            } else {
                Task { await lifecycle.boot(udid) }
            }
        case .device, .pixel, .physicalApple, nil:
            break
        }
    }

    private func showInFinder() {
        switch workspace.deviceSelection {
        case .avd(let name):
            model.catalog.revealAVDInFinder(name)
        case .simulator(let udid):
            if let folder = model.simulators.deviceFolder(udid: udid) {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
        case .device, .pixel, .physicalApple, nil:
            break
        }
    }

    private func rename() {
        switch workspace.deviceSelection {
        case .avd(let name):
            beforeRename?()
            avdDialogs.requestRename(name)
        case .simulator(let udid):
            if let entry = model.simulators.entry(udid: udid) {
                beforeRename?()
                simulatorDialogs.requestRename(entry)
            }
        case .device, .pixel, .physicalApple, nil:
            break
        }
    }

    private func reset() {
        switch workspace.deviceSelection {
        case .avd(let name):
            avdDialogs.requestWipeData(name)
        case .simulator(let udid):
            if let entry = model.simulators.entry(udid: udid) {
                simulatorDialogs.requestErase(entry)
            }
        case .device, .pixel, .physicalApple, nil:
            break
        }
    }

    private func remove() {
        switch workspace.deviceSelection {
        case .avd(let name):
            avdDialogs.requestDelete(name)
        case .simulator(let udid):
            if let entry = model.simulators.entry(udid: udid) {
                simulatorDialogs.requestDelete(entry)
            }
        case .device, .pixel, .physicalApple, nil:
            break
        }
    }
}

/// DH's pill of two 36 pt buttons: a leading button (the compress arrows in
/// the main window, the expand arrows in the compact one) and the "..." menu.
struct ToolbarMoreCapsule: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(AvdActionDialogs.self) private var avdDialogs
    @Environment(SimulatorActionDialogs.self) private var simulatorDialogs
    @Environment(\.openWindow) private var openWindow

    let leadingSymbol: String
    let leadingHelp: String
    let leadingAccessibilityLabel: String
    let leadingAction: () -> Void
    var beforeRename: (() -> Void)?

    @State private var isMenuOpen = false
    @State private var isMoreHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: leadingAction) {
                Image(systemName: leadingSymbol)
                    .font(.system(size: ParityMetrics.toolbarIconSize, weight: ParityMetrics.toolbarIconWeight))
                    .foregroundStyle(ToolbarInk.label)
                    .frame(
                        width: ParityMetrics.toolbarButtonWidth,
                        height: ParityMetrics.toolbarButtonHeight
                    )
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(leadingAccessibilityLabel)
            .help(leadingHelp)

            // No "..." where it would list nothing that works (an adb device, a
            // catalog entry, no selection).
            if hasMoreActions { moreButton }
        }
        .buttonStyle(ChromeButtonStyle(platter: .capsule(ParityMetrics.toolbarItemPlatterSize)))
        .frame(height: ParityMetrics.toolbarButtonHeight)
        .padding(.horizontal, ParityMetrics.toolbarRotateCapsulePadding)
        .toolbarControlSurface()
        .padding(.horizontal, -ParityMetrics.toolbarClusterInset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("")
    }

    private var lifecycleMenu: DeviceLifecycleMenu {
        DeviceLifecycleMenu(
            model: model, workspace: workspace,
            avdDialogs: avdDialogs, simulatorDialogs: simulatorDialogs,
            beforeRename: beforeRename, openWindow: openWindow
        )
    }

    private var hasMoreActions: Bool { !lifecycleMenu.entries().isEmpty }

    private var moreButton: some View {
        let menu = lifecycleMenu
        return Color.clear
            .frame(width: ParityMetrics.toolbarButtonWidth, height: ParityMetrics.toolbarButtonHeight)
            .contentShape(Rectangle())
            .background {
                PlatterView(
                    shape: .capsule(ParityMetrics.toolbarItemPlatterSize),
                    fill: PointerFeedback.fill(isHovered: isMoreHovered, isPressed: isMenuOpen, isEnabled: true)
                )
            }
            .overlay { moreDots }
            .overlay {
                PopUpMenuHitArea(entries: { menu.entries() }, isOpen: $isMenuOpen, isHovered: $isMoreHovered)
            }
            .accessibilityElement()
            .accessibilityLabel("More Actions")
            .accessibilityAddTraits(.isButton)
            .help("More Actions")
    }

    /// DH's overflow glyph: three 3 pt dots at a 3 pt gap.
    private var moreDots: some View {
        HStack(spacing: ParityMetrics.toolbarMoreDotSpacing) {
            ForEach(0..<3, id: \.self) { _ in
                Circle()
                    .fill(ToolbarInk.label)
                    .frame(
                        width: ParityMetrics.toolbarMoreDotDiameter,
                        height: ParityMetrics.toolbarMoreDotDiameter
                    )
            }
        }
        .allowsHitTesting(false)
    }
}
