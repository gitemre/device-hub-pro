import AppKit
import SwiftUI
import DeviceHubProKit

/// Device Hub's leading toolbar cluster (TB-01/TB-02: create/filter capsule +
/// sidebar toggle), hosted as a titlebar accessory instead of an `NSToolbar`
/// item.
///
/// Why: SwiftUI re-applies the window toolbar on every device switch and
/// re-adds its automatic sidebar toggle before we can remove it. Inside a
/// single toolbar section there is no arrangement that both right-aligns the
/// cluster against the divider and absorbs the 44 pt insertion — a leading
/// flexible spacer lets the insertion shove the cluster left (the flash), and
/// a fixed leading spacer leaves the section too tight and the toggle falls
/// out of the layout. Hosting the cluster in the titlebar takes it out of the
/// toolbar's layout entirely; the system toggle keeps being removed, but even
/// its transient insertion cannot move the accessory.
struct LeadingToolbarCluster: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace

    var body: some View {
        HStack(spacing: ParityMetrics.toolbarLeadingClusterSpacing) {
            // DH drops the + and filter capsule with the sidebar: only the
            // sidebar toggle remains.
            if workspace.window.columnVisibility != .detailOnly {
                createFilterCapsule
            }
            sidebarToggle
        }
        .frame(height: ParityMetrics.toolbarButtonHeight)
    }

    // MARK: - TB-01: + / filter capsule

    private var createFilterCapsule: some View {
        HStack(spacing: ParityMetrics.toolbarLeadingButtonSpacing) {
            // Each button draws its own platter and glyph and pops its menu
            // up from a full-size invisible overlay, below the toolbar like
            // DH's (`LeadingMenuButton`).
            LeadingMenuButton(
                label: "Add Device",
                help: "Add Device",
                symbol: "plus",
                glyphSize: ParityMetrics.toolbarPlusGlyphSize,
                glyphWeight: ParityMetrics.toolbarPlusGlyphWeight,
                glyphNudge: ParityMetrics.toolbarPlusGlyphNudge,
                isActive: false,
                menuLeading: -25.5,
                pressedWhileOpen: true,
                entries: addDeviceEntries
            )

            LeadingMenuButton(
                label: "Filter",
                help: "Sort and Filter",
                accessibilityValue: workspace.window.isSidebarFilterActive ? "Filtered" : "",
                symbol: "line.3.horizontal.decrease",
                glyphSize: ParityMetrics.toolbarFilterGlyphSize,
                glyphWeight: ParityMetrics.toolbarIconWeight,
                glyphNudge: ParityMetrics.toolbarFilterGlyphNudge,
                isActive: workspace.window.isSidebarFilterActive,
                menuLeading: -22.5,
                pressedWhileOpen: false,
                entries: filterEntries
            )
        }
        .frame(height: ParityMetrics.toolbarButtonHeight)
        .padding(.horizontal, ParityMetrics.toolbarLeadingCapsulePadding)
        .toolbarControlSurface()
    }

    /// The `+` menu, DH's order: the simulator families first (DH's
    /// "Simulators" section), then our Android emulators.
    private func addDeviceEntries() -> [ToolbarMenuEntry] {
        var entries: [ToolbarMenuEntry] = []
        // Device Hub's New Simulator items (S6), once Xcode can run
        // simulators; the sheet points to Xcode for a missing runtime.
        if model.simulators.tooling.tier >= .t1 {
            entries.append(.header("Simulators"))
            for family in SimulatorFamily.offered(runtimes: model.simulators.runtimes) {
                entries.append(.item(family.menuTitle) { [workspace] in
                    workspace.window.simulatorCreateFamily = family
                })
            }
            entries.append(.separator)
        } else if let guidance = model.simulators.tooling.guidance, model.simulators.tooling.isProbed {
            // No Xcode that can run simulators: say so where they would be.
            entries.append(.header("Simulators"))
            entries.append(.item(guidance.actionTitle) {
                if let url = guidance.actionURL { NSWorkspace.shared.open(url) }
            })
            entries.append(.separator)
        }
        entries.append(.header("Emulators"))
        let factors: [(String, SkinCatalogEntry.Category)] = [
            ("Phone…", .phone), ("Tablet…", .tablet), ("Foldable…", .foldable),
            ("Wear OS…", .wear), ("TV…", .tv), ("Automotive…", .automotive),
        ]
        for (title, factor) in factors {
            entries.append(.item(title) { [workspace] in workspace.window.createFormFactor = factor })
        }
        entries.append(.separator)
        entries.append(.item("Browse Catalog…") { [workspace] in workspace.window.isCatalogPresented = true })
        entries.append(.separator)
        entries.append(.item("Connect an Android Phone…") { [workspace] in workspace.window.isConnectPhonePresented = true })
        entries.append(.item("Pair Nearby Device…") { [workspace] in workspace.window.isPairSheetPresented = true })
        if Self.offersAndroidSetup(adbAvailable: model.adbIsAvailable) {
            entries.append(.separator)
            entries.append(.item("Set Up Android Tools…") { [workspace] in workspace.window.isAndroidSetupPresented = true })
        }
        return entries
    }

    /// "Set Up Android Tools…" stays in the + menu until the tools exist, so
    /// "Don't show again" on the stage card cannot strand a user without it.
    static func offersAndroidSetup(adbAvailable: Bool) -> Bool { !adbAvailable }

    /// The filter menu: DH's three radio filters, then Sort By.
    private func filterEntries() -> [ToolbarMenuEntry] {
        let window = workspace.window
        return [
            .item("All Devices", isChecked: window.deviceFilter == .all) { [workspace] in
                workspace.window.deviceFilter = .all
            },
            .item("Simulators", isChecked: window.deviceFilter == .emulators) { [workspace] in
                workspace.window.deviceFilter = .emulators
            },
            .item("Physical Devices", isChecked: window.deviceFilter == .physical) { [workspace] in
                workspace.window.deviceFilter = .physical
            },
            .separator,
            .submenu("Sort By", sortEntries()),
        ]
    }

    /// Sort By: Availability, a separator, the other five, a separator, Show
    /// Groups (Device Hub's, measured on 27.0).
    private func sortEntries() -> [ToolbarMenuEntry] {
        let window = workspace.window
        func entry(_ mode: WindowState.DeviceSortMode) -> ToolbarMenuEntry {
            .item(mode.title, isChecked: window.deviceSortMode == mode) { [workspace] in
                workspace.window.deviceSortMode = mode
            }
        }
        return [
            entry(.availability),
            .separator,
            entry(.recent), entry(.name), entry(.fidelity), entry(.platform), entry(.operatingSystem),
            .separator,
            .item("Show Groups", isChecked: window.deviceShowsGroups) { [workspace] in
                workspace.window.deviceShowsGroups.toggle()
            },
        ]
    }

    // MARK: - TB-02: sidebar toggle

    /// A real button (it was a tap gesture, which cannot show DH's hover and
    /// press platter over the whole 36 pt circle, nor cancel a press dragged
    /// off it).
    private var sidebarToggle: some View {
        toolbarCapsule(padding: 0) {
            Button(action: toggleSidebar) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: ParityMetrics.toolbarIconSize, weight: ParityMetrics.toolbarIconWeight))
                    .frame(
                        width: ParityMetrics.toolbarSidebarToggleDiameter,
                        height: ParityMetrics.toolbarSidebarToggleDiameter
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(ChromeButtonStyle(
                platter: .circle(diameter: ParityMetrics.toolbarSidebarTogglePlatterDiameter)
            ))
            // Space presses a focused button natively; Return did too.
            .onKeyActivation([.return]) {
                toggleSidebar()
                return .handled
            }
            .accessibilityLabel(sidebarToggleTitle)
            .help(sidebarToggleTitle)
        }
    }

    /// Slides the sidebar column in/out with the stage token, matching the
    /// inspector's own open/close transition (Reduce Motion snaps).
    /// DH's tooltip and accessibility label name the action.
    private var sidebarToggleTitle: String {
        workspace.window.columnVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar"
    }

    private func toggleSidebar() {
        workspace.window.toggleSidebarColumn()
    }

    // MARK: - Shared chrome

    /// One Device Hub toolbar capsule: one flat surface around controls at the
    /// audited 36 pt height (same treatment as the trailing capsules, minus
    /// their negative `toolbarClusterInset`: that compensates NSToolbar's
    /// item spacing, and this cluster lives in a titlebar accessory).
    private func toolbarCapsule<Content: View>(
        spacing: CGFloat = 0,
        padding: CGFloat,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        HStack(spacing: spacing) {
            content()
        }
        .frame(height: ParityMetrics.toolbarButtonHeight)
        .padding(.horizontal, padding)
        .toolbarControlSurface()
    }
}

/// Installs the leading cluster as a titlebar accessory on the window that
/// hosts the representable, once per window.
struct LeadingToolbarAccessoryInstaller: NSViewRepresentable {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        install(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        install(from: nsView)
    }

    private func install(from view: NSView) {
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            guard !window.titlebarAccessoryViewControllers.contains(
                where: { $0 is LeadingToolbarAccessoryController }
            ) else { return }
            let controller = LeadingToolbarAccessoryController(model: model, workspace: workspace)
            controller.layoutAttribute = .left
            window.addTitlebarAccessoryViewController(controller)
        }
    }
}

/// Hosts ``LeadingToolbarCluster`` in the titlebar, right-aligned against the
/// sidebar divider at the audited inset, and tracks sidebar resizes.
@MainActor
final class LeadingToolbarAccessoryController: NSTitlebarAccessoryViewController {
    /// The width the accessory starts with, wide enough for the widest
    /// (320 pt) sidebar; `updateTrailing` then keeps it ending at the
    /// sidebar divider. Only the cluster takes hits, the rest passes clicks
    /// through to the titlebar.
    private static let containerWidth: CGFloat = 420

    private let model: AppModel
    /// The window's workspace, handed to the hosted cluster (an
    /// `NSHostingView` does not inherit the window's environment).
    private let workspace: DeviceWorkspace
    private var trailingConstraint: NSLayoutConstraint?
    private weak var sidebarView: NSView?
    private var sidebarObservations: [NSKeyValueObservation] = []
    private var observesColumnVisibility = false

    init(model: AppModel, workspace: DeviceWorkspace) {
        self.model = model
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
        // Must be set before the accessory is added: the system sizes the
        // titlebar container at insertion and ignores later changes.
        preferredContentSize = NSSize(
            width: Self.containerWidth,
            height: NSWindow.frameRect(forContentRect: .zero, styleMask: .titled).height
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let cluster = NSHostingView(rootView: LeadingToolbarCluster().environment(model).environment(workspace))
        cluster.translatesAutoresizingMaskIntoConstraints = false

        let container = TitlebarPassthroughView()
        container.interactiveView = cluster
        // The system sizes the titlebar container from `preferredContentSize`
        // at insertion time; the explicit frame keeps the container's bounds
        // non-empty (and therefore hit-testable) if that is ignored.
        container.frame = NSRect(
            origin: .zero,
            size: NSSize(width: Self.containerWidth, height: preferredContentSize.height)
        )
        container.addSubview(cluster)

        let trailing = cluster.trailingAnchor.constraint(equalTo: container.leadingAnchor, constant: 0)
        NSLayoutConstraint.activate([
            cluster.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            trailing,
        ])
        trailingConstraint = trailing
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if !observesColumnVisibility {
            observesColumnVisibility = true
            observeColumnVisibility()
        }
        guard sidebarObservations.isEmpty else { return }
        guard findSidebarView() != nil else {
            // The split view may not exist yet on the first appearance.
            DispatchQueue.main.async { [weak self] in self?.observeSidebar() }
            return
        }
        observeSidebar()
    }

    private func observeSidebar() {
        guard sidebarObservations.isEmpty, let sidebar = findSidebarView() else { return }
        // Held once found: the width filter below only recognises an
        // expanded sidebar, so rescanning on every change lost the sidebar
        // the moment it collapsed and left the cluster where it was.
        sidebarView = sidebar
        sidebar.postsFrameChangedNotifications = true
        sidebarObservations = [
            sidebar.observe(\.frame, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateTrailing() }
            },
            sidebar.observe(\.isHidden, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateTrailing() }
            },
        ]
        updateTrailing()
    }

    /// The sidebar toggle flips `columnVisibility`; the cluster moves with
    /// it (animated like the column) even when AppKit reports no frame change
    /// for the collapsed column.
    private func observeColumnVisibility() {
        withObservationTracking {
            _ = workspace.window.columnVisibility
        } onChange: { [weak self] in
            // Fires before the new value is stored; act on the next turn.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateTrailing(animated: !MotionMetrics.reduceMotion)
                    self.observeColumnVisibility()
                }
            }
        }
    }

    /// The split view's sidebar column: the leading-edge subview at the
    /// sidebar's width (the inspector has a similar width but sits at the
    /// trailing edge). Only an expanded sidebar matches, so this runs once to
    /// find it.
    private func findSidebarView() -> NSView? {
        guard let window = view.window, let content = window.contentView else { return nil }
        for split in content.devicehubproDescendants(ofType: NSSplitView.self) {
            for sub in split.subviews {
                let frame = sub.convert(sub.bounds, to: nil)
                if frame.minX < 8, frame.width > 200, frame.width < 340, frame.height > 400 {
                    return sub
                }
            }
        }
        return nil
    }

    private func updateTrailing(animated: Bool = false) {
        guard let window = view.window else { return }
        let sidebarMaxX: CGFloat? = {
            guard workspace.window.columnVisibility != .detailOnly,
                  let sidebar = sidebarView, sidebar.window === window, !sidebar.isHidden
            else { return nil }
            let frame = sidebar.convert(sidebar.bounds, to: nil)
            return frame.width >= 1 ? frame.maxX : nil
        }()
        let buttons = window.standardWindowButton(.zoomButton)
            ?? window.standardWindowButton(.closeButton)
        let windowButtonsMaxX = buttons.map { $0.convert($0.bounds, to: nil).maxX }
            ?? ParityMetrics.toolbarWindowButtonsFallbackMaxX
        let targetInWindow = Self.clusterTrailingX(
            sidebarMaxX: sidebarMaxX,
            windowButtonsMaxX: windowButtonsMaxX
        )
        // The accessory ends at the sidebar divider (at the cluster while the
        // sidebar is collapsed): the toolbar and the window title start where
        // it ends, and at its first 420 pt it pushed the stage title to
        // 512 pt, where DH's starts at 304 pt (ST-01).
        let width = Self.accessoryWidth(
            endX: sidebarMaxX ?? targetInWindow,
            containerMinX: view.convert(NSPoint.zero, to: nil).x
        )
        if abs(view.frame.width - width) > 0.5 {
            preferredContentSize = NSSize(width: width, height: preferredContentSize.height)
            view.setFrameSize(NSSize(width: width, height: view.frame.height))
        }
        let targetInContainer = view.convert(NSPoint(x: targetInWindow, y: 0), from: nil).x
        guard let trailingConstraint, trailingConstraint.constant != targetInContainer else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = MotionMetrics.standardDuration
                context.allowsImplicitAnimation = true
                trailingConstraint.animator().constant = targetInContainer
            }
        } else {
            trailingConstraint.constant = targetInContainer
        }
    }

    /// The accessory's width so that it ends at `endX` (window coordinates)
    /// from its own leading edge at `containerMinX`; never below 1 pt.
    static func accessoryWidth(endX: CGFloat, containerMinX: CGFloat) -> CGFloat {
        max(1, endX - containerMinX)
    }

    /// Where the cluster's trailing edge goes, in window coordinates: against
    /// the sidebar divider while the sidebar shows (`sidebarMaxX`), and never
    /// further left than right after the traffic lights — so a collapsed (or
    /// collapsing) sidebar leaves the cluster beside the window buttons
    /// instead of floating over the detail's toolbar band.
    static func clusterTrailingX(sidebarMaxX: CGFloat?, windowButtonsMaxX: CGFloat) -> CGFloat {
        let besideWindowButtons = windowButtonsMaxX
            + ParityMetrics.toolbarLeadingCollapsedGap
            + ParityMetrics.toolbarLeadingCollapsedClusterWidth
        guard let sidebarMaxX else { return besideWindowButtons }
        return max(sidebarMaxX - ParityMetrics.toolbarLeadingAccessoryTrailingInset, besideWindowButtons)
    }
}

/// The accessory's container spans past the cluster (it pushes the cluster to
/// the divider), but only the cluster itself may take hits — the empty part
/// must let the traffic lights and the titlebar drag region work.
private final class TitlebarPassthroughView: NSView {
    weak var interactiveView: NSView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let interactiveView else { return nil }
        let local = convert(point, from: superview)
        let clusterFrame = interactiveView.convert(interactiveView.bounds, to: self)
        return clusterFrame.contains(local) ? super.hitTest(point) : nil
    }
}

/// Makes a borderless `Menu` (`.menuStyle(.borderlessButton)`) respond across
/// its WHOLE declared frame (TB-01 click area, 2026-09-28). Sizing and
/// content-shaping the menu itself — even placed as an `.overlay` on top of a
/// properly sized sibling, the fix that already works for the Apps scope
/// popup's *layout* (`InspectorView.swift`, IN-03) — left its real native hit
/// region a few points wide around dead centre: confirmed live with
/// real `CGEvent` clicks at this button's edges, and at several points a few
/// pt off its own glyph in every direction, none of which opened anything;
/// only a click within roughly a point of dead centre did. A plain `NSView`
/// has no such shrinkage (`hitTest` uses its full bounds), so this view is
/// placed as the topmost, same-size, invisible overlay: it catches the
/// `mouseDown` itself and forwards it to the nearest `NSPopUpButton` it can
/// find (an ancestor-then-descendant search, like `SidebarScrollChrome`'s for
/// the sidebar's scroll view — but by centre-to-centre *distance*, not the
/// first match: the `+` and filter buttons are siblings a couple of points
/// apart, and "first in view-tree order" resolved to the `+` button for both
/// forwarders, opening Create a Device from a filter-button click) with
/// `performClick`, which opens the menu exactly as a direct native click on
/// it would.
struct MenuHitAreaOverlay: NSViewRepresentable {
    final class ClickForwardingView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let button = Self.nearestPopUpButton(from: self) else {
                super.mouseDown(with: event)
                return
            }
            button.performClick(nil)
        }

        // A borderless NSPopUpButton with a blank label computes its own
        // (small) cell frame for hit-testing regardless of its view's
        // bounds; a plain NSView never does, so it must claim every point
        // inside itself rather than deferring to `super`.
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : super.hitTest(point)
        }

        /// The closest `NSPopUpButton` to `probe`, by centre-to-centre
        /// distance in window coordinates — not simply the first one found:
        /// the `+` and filter buttons are siblings a couple of points apart
        /// under the same ancestor, and "first in view-tree order" resolved
        /// to the `+` button for both forwarders, so a click meant for the
        /// filter button opened Create a Device instead.
        static func nearestPopUpButton(from probe: NSView) -> NSPopUpButton? {
            let probeCenter = probe.convert(
                NSPoint(x: probe.bounds.midX, y: probe.bounds.midY),
                to: nil
            )
            var ancestor = probe.superview
            while let current = ancestor {
                let candidates = allDescendants(of: current)
                if let closest = candidates.min(by: {
                    distance(from: $0, to: probeCenter) < distance(from: $1, to: probeCenter)
                }) {
                    return closest
                }
                ancestor = current.superview
            }
            return nil
        }

        private static func distance(from button: NSPopUpButton, to point: NSPoint) -> CGFloat {
            let center = button.convert(
                NSPoint(x: button.bounds.midX, y: button.bounds.midY),
                to: nil
            )
            return hypot(center.x - point.x, center.y - point.y)
        }

        private static func allDescendants(of view: NSView) -> [NSPopUpButton] {
            var result: [NSPopUpButton] = []
            for subview in view.subviews {
                if let button = subview as? NSPopUpButton { result.append(button) }
                result.append(contentsOf: allDescendants(of: subview))
            }
            return result
        }
    }

    func makeNSView(context: Context) -> ClickForwardingView { ClickForwardingView() }
    func updateNSView(_ nsView: ClickForwardingView, context: Context) {}
}

// MARK: - Toolbar menu buttons (TB-01)

/// One entry of a toolbar menu popped up by ``ToolbarMenuButtonOverlay``.
enum ToolbarMenuEntry {
    /// DH's bold gray section title ("Simulators").
    case header(String)
    case item(String, isChecked: Bool = false, action: () -> Void)
    case separator
    case submenu(String, [ToolbarMenuEntry])

    /// Builds the native menu. Actions are held by the items (`representedObject`
    /// keeps each target alive; `NSMenuItem.target` alone does not).
    @MainActor
    static func makeMenu(_ entries: [ToolbarMenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .header(let title):
                menu.addItem(NSMenuItem.sectionHeader(title: title))
            case .separator:
                menu.addItem(.separator())
            case .item(let title, let isChecked, let action):
                let target = ActionTarget(action)
                let item = NSMenuItem(title: title, action: #selector(ActionTarget.fire), keyEquivalent: "")
                item.target = target
                item.representedObject = target
                item.state = isChecked ? .on : .off
                menu.addItem(item)
            case .submenu(let title, let children):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = makeMenu(children)
                menu.addItem(item)
            }
        }
        return menu
    }

    private final class ActionTarget: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}

/// A leading toolbar button (`+`, filter): DH's platter behind the glyph
/// (gray on hover, darker while its menu is open, the accent for an active
/// filter) and a menu that opens below the toolbar, not over it. The whole
/// button takes the press: the overlay is a plain `NSView` that pops the menu
/// itself (a borderless `Menu`'s own hit region was a few points wide, and it
/// always opened over the toolbar).
private struct LeadingMenuButton: View {
    let label: String
    let help: String
    var accessibilityValue = ""
    let symbol: String
    let glyphSize: CGFloat
    let glyphWeight: Font.Weight
    let glyphNudge: CGFloat
    let isActive: Bool
    let menuLeading: CGFloat
    /// DH draws the pressed platter under the `+` while its menu is open, and
    /// none under the filter (measured 2026-09-29, menus open on both).
    let pressedWhileOpen: Bool
    let entries: () -> [ToolbarMenuEntry]

    @State private var isHovered = false
    @State private var isOpen = false

    var body: some View {
        Color.clear
            .frame(
                width: ParityMetrics.toolbarLeadingButtonWidth,
                height: ParityMetrics.toolbarButtonHeight
            )
            .contentShape(Rectangle())
            .background {
                PlatterView(
                    shape: .capsule(ParityMetrics.toolbarItemPlatterSize),
                    fill: PointerFeedback.fill(isHovered: isHovered, isPressed: isOpen && pressedWhileOpen)
                )
            }
            .background {
                // TB-01 (2026-09-28): measured on DH 27.0 by picking
                // "Simulators" then reverting to "All Devices" — while any
                // filter narrows the list, DH fills the item's own 30×28 pt
                // platter shape solid with the system accent behind the
                // (still gray) hover/press platter.
                if isActive {
                    Capsule()
                        .fill(PointerFeedback.filterActiveFill)
                        .frame(
                            width: ParityMetrics.toolbarItemPlatterSize.width,
                            height: ParityMetrics.toolbarItemPlatterSize.height
                        )
                }
            }
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: glyphSize, weight: glyphWeight))
                    // DH draws these two in the label colour (85% black,
                    // #262626 over the glass), white on the active filter's
                    // accent (TB-06 stroke pass).
                    .foregroundStyle(isActive ? AnyShapeStyle(Color.white) : AnyShapeStyle(ToolbarInk.label))
                    .offset(x: glyphNudge)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay {
                ToolbarMenuButtonOverlay(
                    label: label,
                    help: help,
                    value: accessibilityValue,
                    entries: entries,
                    menuLeading: menuLeading,
                    isHovered: $isHovered,
                    isOpen: $isOpen
                )
                .frame(
                    width: ParityMetrics.toolbarLeadingButtonWidth,
                    height: ParityMetrics.toolbarButtonHeight
                )
            }
    }
}

/// The invisible, full-button `NSView` over a ``LeadingMenuButton``: reports
/// hover, and on mouse-down (or an accessibility press) pops the menu up
/// below the toolbar. DH 27.0 (measured 2026-09-29, menu windows): the `+`
/// menu at (169, 82) and the filter menu at (205, 82), for buttons centred at
/// (193, 56) and (228.5, 56); the top is the toolbar's bottom, 26 pt under
/// the button centre. Our buttons sit at 194.5 and 227.5, so the left edges
/// are 25.5 and 22.5 pt left of the centres. It is an AX menu button and
/// carries the tooltip.
struct ToolbarMenuButtonOverlay: NSViewRepresentable {
    let label: String
    let help: String
    let value: String
    let entries: () -> [ToolbarMenuEntry]
    /// The menu's left edge relative to the button's centre (negative: left).
    let menuLeading: CGFloat
    @Binding var isHovered: Bool
    @Binding var isOpen: Bool

    /// Where the menu's origin goes under the button's centre so that its top
    /// lands on the toolbar's bottom (26 pt down): `NSMenu.popUp` puts the
    /// window's top 5 pt above the point it is given (measured: origin 26 pt
    /// under the centre gave a top at 77 where DH's is at 82).
    static let menuTopBelowCentre: CGFloat = 31

    func makeNSView(context: Context) -> View { View() }

    func updateNSView(_ view: View, context: Context) {
        view.entries = entries
        view.menuLeading = menuLeading
        view.label = label
        view.value = value
        view.toolTip = help
        view.onHover = { isHovered = $0 }
        view.onOpenChange = { isOpen = $0 }
    }

    /// Where the menu's top-left goes, in screen coordinates, for a button
    /// centred at `center` (screen space, y up).
    static func menuOrigin(center: NSPoint, leading: CGFloat) -> NSPoint {
        NSPoint(x: center.x + leading, y: center.y - menuTopBelowCentre)
    }

    final class View: NSView {
        var entries: () -> [ToolbarMenuEntry] = { [] }
        var menuLeading: CGFloat = 0
        var label = ""
        var value = ""
        var onHover: (Bool) -> Void = { _ in }
        var onOpenChange: (Bool) -> Void = { _ in }
        private var trackingArea: NSTrackingArea?

        // A plain view claims every point inside itself (see
        // `MenuHitAreaOverlay`), so the whole button is the target.
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(convert(point, from: superview)) ? self : nil
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) { onHover(true) }
        override func mouseExited(with event: NSEvent) { onHover(false) }

        override func mouseDown(with event: NSEvent) { popUp() }

        private func popUp() {
            guard let window else { return }
            let center = window.convertPoint(
                toScreen: convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
            )
            let menu = ToolbarMenuEntry.makeMenu(entries())
            onOpenChange(true)
            onHover(false)
            menu.popUp(
                positioning: nil,
                at: ToolbarMenuButtonOverlay.menuOrigin(center: center, leading: menuLeading),
                in: nil
            )
            onOpenChange(false)
            // The pointer may have stayed on the button.
            let mouse = window.mouseLocationOutsideOfEventStream
            onHover(bounds.contains(convert(mouse, from: nil)) && window.isKeyWindow)
        }

        // MARK: Accessibility

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .menuButton }
        override func accessibilityLabel() -> String? { label }
        override func accessibilityValue() -> Any? { value.isEmpty ? nil : value }
        override func accessibilityHelp() -> String? { toolTip }
        override func accessibilityPerformPress() -> Bool {
            popUp()
            return true
        }
    }
}
