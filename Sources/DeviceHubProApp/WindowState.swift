import AppKit
import Foundation
import Observation
import SwiftUI
import DeviceHubProKit

/// The window's presentation state: the inspector's tab and visibility, the
/// sidebar's column, sort and filters, the sheets the toolbar and menus
/// present, the stage's frame and stats toggles, and the stage zoom.
///
/// Each `DeviceWorkspace` owns one as `window`, which the views and the
/// menus read (`AppModel.window` names the one workspace's); one per app
/// today, one per window once the stage is per-window (S25). It knows nothing about devices:
/// the Diagnostics tab opens logcat through `openDiagnosticsLogcat`, and the
/// fit and 1:1 zoom read the stream's size through `devicePixelSize`. The
/// model wires both.
@MainActor
@Observable
final class WindowState {
    enum InspectorTab: Hashable {
        case info
        case apps
        case diagnostics
        case controls
    }

    /// Device Hub's Sort By entries, in its order (Availability, then the
    /// five below its separator); the menus title them with `title`.
    enum DeviceSortMode: Hashable, CaseIterable {
        case availability
        case recent
        case name
        case fidelity
        case platform
        case operatingSystem

        var title: String {
            switch self {
            case .availability: "Availability"
            case .recent: "Recent"
            case .name: "Name"
            case .fidelity: "Fidelity"
            case .platform: "Platform"
            case .operatingSystem: "Operating System"
            }
        }
    }

    /// Sidebar type filter, Device Hub's ✓ All Devices / Simulators /
    /// Physical Devices.
    enum DeviceFilter: Hashable {
        case all
        case emulators
        case physical
    }

    /// Sidebar visibility, owned here because the leading toolbar cluster
    var columnVisibility: NavigationSplitViewVisibility = .all
    /// The Pixel catalog sheet's presentation, owned here for the same reason
    /// (the accessory's create menu opens it).
    var isCatalogPresented = false
    /// The inspector's surface. A device opens on Settings (`.controls`, the
    /// sliders panel: a device that is off already shows it when Start is
    /// pressed) unless the user chose another surface for that device in this
    /// session (`inspectorTabByDevice`).
    var inspectorTab: InspectorTab = .controls {
        didSet {
            // A write the window made on showing a device is not a choice.
            guard !isApplyingDefaultInspectorTab, let key = zoomDeviceKey else { return }
            inspectorTabByDevice[key] = inspectorTab
        }
    }
    /// The surface the user picked, by device (`showsDevice`'s key).
    private(set) var inspectorTabByDevice: [String: InspectorTab] = [:]
    @ObservationIgnored private var isApplyingDefaultInspectorTab = false
    var showInspector = true

    /// The layout Log focus mode replaced; non-nil while the mode is on.
    private(set) var logFocusRestore: LogFocusSnapshot?
    /// Whether the window shows only the device stage and the wide log pane.
    var isLogFocus: Bool { logFocusRestore != nil }

    /// Log focus mode: hides the sidebar and the inspector so the window is
    /// the phone and the log. The layout it replaced is put back by
    /// `exitLogFocus`.
    func enterLogFocus() {
        guard logFocusRestore == nil else { return }
        logFocusRestore = LogFocusSnapshot(columnVisibility: columnVisibility, showInspector: showInspector)
        openDiagnosticsLogcat()
        MotionMetrics.run(MotionMetrics.standard) {
            columnVisibility = .detailOnly
            showInspector = false
        }
    }

    func exitLogFocus() {
        guard let snapshot = logFocusRestore else { return }
        logFocusRestore = nil
        MotionMetrics.run(MotionMetrics.standard) {
            columnVisibility = snapshot.columnVisibility
            showInspector = snapshot.showInspector
        }
    }

    func toggleLogFocus() {
        if isLogFocus { exitLogFocus() } else { enterLogFocus() }
    }

    /// The log window's sheet (`LogsSheet`, in InspectorView.swift): the
    /// Reports panel's Logs button and the Device menu open it.
    var isLogsSheetPresented = false
    var showDeviceFrame = true
    /// The device this window showed disappeared: the stage keeps saying "No
    /// Selection" instead of picking another one (`AppModel.ensureDeviceSelection`).
    var selectionWasLost = false
    /// Our own debug HUD over the live mirror (`DHP_SHOW_MIRROR_STATS=1`;
    /// it had a View menu item, which Device Hub's View menu does not); shows
    /// the stats line the perf harness also reads.
    var showMirrorStats = ProcessInfo.processInfo.environment["DHP_SHOW_MIRROR_STATS"] == "1"
    /// Whether the compact mirror window is on screen; set by its view and read
    /// by the Device menu / toolbar overflow to flip Open ↔ Close.
    var isCompactMirrorPresented = false

    /// Window ▸ Stay on Top, per window: the main window stays above other
    /// windows (`NSWindow.level == .floating`). `DeviceWorkspace.setStaysOnTop`
    /// applies it; the preference only seeds new windows.
    var staysOnTop = false
    /// The same for this workspace's compact mirror window.
    var compactStaysOnTop = false
    /// The compact mirror's `NSWindow`, set by `CompactWindowConfigurator`
    /// while it is open (the menu tells which window is key by it).
    @ObservationIgnored weak var compactNSWindow: NSWindow?
    /// The main window showing this workspace (`MainWindowLevelApplier`).
    @ObservationIgnored weak var mainNSWindow: NSWindow?

    /// The main window the compact window replaced: hidden while the compact
    /// window shows, brought back by its expand button (Device Hub swaps the
    /// windows the same way).
    @ObservationIgnored weak var mainWindowHiddenForCompact: NSWindow?
    var createFormFactor: SkinCatalogEntry.Category?
    /// The New Simulator sheet's family, set by the + menu's Simulators
    /// section (Device Hub's S6/S7).
    var simulatorCreateFamily: SimulatorFamily?
    var deviceSortMode: DeviceSortMode = .availability
    /// Sort By ▸ Show Groups: the list carries a header per group (Available,
    /// a day, a letter, a platform, …); off, it is one flat list.
    var deviceShowsGroups = true
    var deviceFilter: DeviceFilter = .all

    /// Whether the sidebar's Filter menu (TB-01) is narrowing the list from
    /// its default: the type filter set to anything but "All Devices". Sort
    /// order reorders the list rather than narrowing it, so it does not
    /// count. DH's filter toolbar item turns blue while its filter is
    /// applied (SB-02/TB-01, 2026-09-28); this drives the same tint here.
    var isSidebarFilterActive: Bool {
        deviceFilter != .all
    }
    /// Stage zoom relative to fit (nil = fit the stage).
    var stageZoom: Double?

    /// The stage is zoomed past its own size, so it scrolls: the fitted
    /// device carries a margin, so a zoom just above fit already overflows.
    static func zoomOverflows(_ zoom: Double?) -> Bool {
        (zoom ?? 1) > 1.05
    }

    /// Whether the "Hold ⌥⌘ and drag to move around." hint shows over the
    /// pill: while the stage is zoomed past its size and the hint was never
    /// closed. Device Hub remembers the ×: measured on 27.0, a closed hint
    /// did not come back at any later zoom-in (`AppPreferences.zoomHintDismissed`).
    func showsZoomHint(dismissed: Bool) -> Bool {
        !dismissed && Self.zoomOverflows(stageZoom)
    }

    /// The one-time "Choose a development team" sheet: asked only when the
    /// iPhone input runner is needed and the keychain holds several Apple
    /// Development teams (`DeviceWorkspace.pickSigningTeam`).
    var teamPickerRequest: TeamPickerRequest?

    /// The Pair Nearby Device sheet (iPhone and Android Phone; it holds the
    /// pairing-code form of spec §11.3), presented from the File menu and
    /// the + menu.
    var isPairSheetPresented = false

    /// The "Connect an Android Phone…" help sheet from the + menu.
    var isConnectPhonePresented = false

    /// The guided "Set up Android tools" sheet, opened by the toolbar
    /// warning, the sidebar row and the dead ends of New Emulator, Pair
    /// Nearby Device and the catalog.
    var isAndroidSetupPresented = false

    /// The sheet the Device menu's extras present (Push Notification…,
    /// Permissions…, Time Zone…, Sensors…, Simulate ▸ …; `DeviceExtrasSheets`).
    var deviceExtrasSheet: DeviceExtrasSheet?

    /// Slides the sidebar column in or out with the stage token, matching the
    /// inspector's own open/close transition (Reduce Motion snaps): the
    /// toolbar's toggle and View ▸ Hide Sidebar.
    func toggleSidebarColumn() {
        if isLogFocus { return exitLogFocus() }
        let target: NavigationSplitViewVisibility = columnVisibility == .all ? .detailOnly : .all
        MotionMetrics.run(MotionMetrics.standard) {
            columnVisibility = target
        }
    }

    /// The soft session cap's warning (the multi-window switch (`DHP_MULTIWINDOW`, on unless 0)
    /// only): offered, never forced. Set on this workspace when starting its
    /// session puts a 5th live mirror session (cap 4) on screen; an alert
    /// bound to it offers Stop & Continue (ends `leastRecentlyFocusedID`'s
    /// session) or Continue Anyway (just clears it) — either way this
    /// workspace's own session, already started, is left running.
    struct SessionCapWarning: Equatable {
        let leastRecentlyFocusedID: WorkspaceID
        let leastRecentlyFocusedName: String
    }
    var sessionCapWarning: SessionCapWarning?

    /// Whether this workspace's own main window is on screen — not fully
    /// occluded and not miniaturized: read by the stage's
    /// Metal view (`MirrorMetalView`) and the Controls poll to stop
    /// per-frame and polling work while the window cannot be seen. Kept
    /// true until a window binds (`WindowVisibilityView`, single-window
    /// mode's one window, and every window before its first occlusion
    /// notification), so nothing is gated before a real signal arrives.
    var isWindowVisible = true

    /// Whether this workspace's stage is on screen anywhere: its main window
    /// (`isWindowVisible`) or its compact mirror, which shows the same
    /// session while the main window is hidden (`orderOut`) in compact mode.
    /// The mirror's draws and a physical iPhone's capture follow this; the
    /// main-window-only work (the inspector's reads, the Controls poll)
    /// follows `isWindowVisible`.
    var isStageVisible: Bool { isWindowVisible || isCompactMirrorPresented }

    /// Called when `selectInspectorTab` shows the Diagnostics tab. The model
    /// opens logcat for the live device unless it already streams it.
    @ObservationIgnored var openDiagnosticsLogcat: @MainActor () -> Void = {}
    /// The live stream's size in device pixels, nil before its first frame;
    /// the fit and 1:1 zoom are measured against it.
    @ObservationIgnored var devicePixelSize: @MainActor () -> CGSize? = { nil }

    /// Opens `tab` in the inspector, or hides the inspector if that tab is
    /// already selected — Device Hub's toolbar-icon inspector pattern.
    func selectInspectorTab(_ tab: InspectorTab) {
        if isLogFocus { return exitLogFocus() }
        if showInspector && inspectorTab == tab {
            showInspector = false
            return
        }
        inspectorTab = tab
        showInspector = true
        if tab == .diagnostics {
            openDiagnosticsLogcat()
        }
    }

    /// The (i) button: Device Hub's Info/Apps inspector. It hides the
    /// inspector only while Info or Apps is on screen; from Controls or
    /// Diagnostics — where the segmented control is not shown — it switches
    /// to Info instead of closing, and a hidden inspector reopens on the
    /// Info/Apps tab it last showed.
    func toggleDeviceInfoInspector() {
        if isLogFocus { return exitLogFocus() }
        if showInspector && inspectorTab.isDeviceInfoSurface {
            showInspector = false
            return
        }
        if !inspectorTab.isDeviceInfoSurface {
            inspectorTab = .info
        }
        showInspector = true
    }

    /// Whether `button` draws its active circle: only the button whose
    /// surface the inspector currently shows.
    func isInspectorToolbarButtonActive(_ button: InspectorToolbarButton) -> Bool {
        guard showInspector else { return false }
        switch button {
        case .controls: return inspectorTab == .controls
        case .diagnostics: return inspectorTab == .diagnostics
        case .deviceInfo: return inspectorTab.isDeviceInfoSurface
        }
    }

    /// View ▸ Hide/Show Inspector: leaves Log focus mode instead when it is on.
    func toggleInspector() {
        if isLogFocus { return exitLogFocus() }
        showInspector.toggle()
    }

    func toggleDeviceFrame() {
        showDeviceFrame.toggle()
    }

    func toggleMirrorStats() {
        showMirrorStats.toggle()
    }

    func zoomIn() {
        stepZoom(up: true)
    }

    func zoomOut() {
        stepZoom(up: false)
    }

    /// What the zoom controls show as selected (TB-08). Fit and Physical
    /// Size are modes Device Hub keeps while the window or stream changes;
    /// a step leaves both.
    ///
    /// Physical Size, Point Accurate and Pixel Accurate are the scale modes
    /// (Simulator.app's Window ▸ Physical Size / Point Accurate / Pixel
    /// Accurate): each names a scale on screen and is kept while the window
    /// or stream changes.
    enum ZoomMode: Equatable {
        case fit
        case physical
        /// One device point (dp on Android) per Mac point.
        case pointAccurate
        /// One device pixel per Mac screen pixel.
        case pixelAccurate
        case custom

        /// Whether the mode names a scale the stage keeps (all but Fit and
        /// a free step).
        var isScaleMode: Bool {
            switch self {
            case .physical, .pointAccurate, .pixelAccurate: true
            case .fit, .custom: false
            }
        }
    }
    private(set) var zoomMode: ZoomMode = .fit

    /// A zoom choice the user makes (the buttons, the menu, the shortcuts)
    /// settles the opening zoom: the default is only for a device the
    /// window has not shown a zoom for yet.
    func resetZoom() {
        pendingZoom = nil
        zoomMode = .fit
        applyZoom(nil)
    }

    // MARK: - Per-device zoom (opening zoom, Device Hub's Physical Size default)

    /// What one device was last shown at.
    struct RememberedZoom: Equatable {
        var mode: ZoomMode
        var zoom: Double?
    }

    /// What the window still has to settle for the device it now shows,
    /// once the stream is drawing and the panel's density is known.
    enum PendingZoom: Equatable {
        /// A device the window has not shown before: Physical Size when the
        /// device at its real size fits the stage, else Fit (Device Hub
        /// opens an iPhone at Physical Size and an iPad Pro 13" at Fit).
        case openingDefault
        /// A device the window showed before: back to what it was at.
        case restore(ZoomMode, Double?)
    }

    /// Device Hub keeps the zoom per device for the session: what each
    /// device the window has shown was last at (memory only, not persisted).
    private(set) var zoomByDevice: [String: RememberedZoom] = [:]
    private(set) var zoomDeviceKey: String?
    private(set) var pendingZoom: PendingZoom?

    /// Settings for a device the user has not chosen a surface for, else the
    /// surface they chose for it.
    private func applyInspectorTab(forDevice key: String) {
        let tab = inspectorTabByDevice[key] ?? .controls
        guard tab != inspectorTab else { return }
        isApplyingDefaultInspectorTab = true
        inspectorTab = tab
        isApplyingDefaultInspectorTab = false
        if tab == .diagnostics, showInspector {
            openDiagnosticsLogcat()
        }
    }

    /// The window now shows the device `key` (nil: none). Keeps the leaving
    /// device's zoom, snaps to Fit (its own zoom is applied once measured),
    /// and leaves resize mode, which belongs to the device it was entered on.
    func showsDevice(_ key: String?) {
        guard key != zoomDeviceKey else { return }
        if let old = zoomDeviceKey {
            zoomByDevice[old] = RememberedZoom(mode: zoomMode, zoom: stageZoom)
        }
        zoomDeviceKey = key
        isResizeModeActive = false
        graceTask?.cancel()
        graceTask = nil
        guard let key else {
            pendingZoom = nil
            return
        }
        applyInspectorTab(forDevice: key)
        if let remembered = zoomByDevice[key] {
            switch remembered.mode {
            case .fit:
                snapZoom(mode: .fit, zoom: nil)
                pendingZoom = nil
            case .custom:
                snapZoom(mode: .custom, zoom: remembered.zoom)
                pendingZoom = nil
            case .physical, .pointAccurate, .pixelAccurate:
                snapZoom(mode: .fit, zoom: nil)
                pendingZoom = .restore(remembered.mode, remembered.zoom)
            }
        } else {
            snapZoom(mode: .fit, zoom: nil)
            pendingZoom = .openingDefault
        }
    }

    /// Sets the mode and zoom without the presentation animation (a device
    /// switch is a new picture, not a zoom step).
    private func snapZoom(mode: ZoomMode, zoom: Double?) {
        zoomMode = mode
        stageZoom = zoom
        zoomPresentation = 1
        physicalCorrections = 0
    }

    /// The smallest screen (its longest side, in points) a new device opens
    /// at Physical Size with: a watch is smaller than this and opens at Fit.
    static let minimumOpeningPoints: Double = 200

    /// Whether a device the window has not shown yet would open at Physical
    /// Size: its real size is no larger than what Fit draws (`measured`,
    /// the scale on screen at Fit). Nil until both are known.
    static func opensAtPhysicalSize(
        fitScale measured: Double?,
        physical: Double?,
        screenPixels: CGSize? = nil
    ) -> Bool? {
        guard let measured, measured > 0, let physical, physical > 0 else { return nil }
        // A watch at its real size is a ~100 pt dot on a Mac: a screen whose
        // longest side would be under `minimumOpeningPoints` opens at Fit.
        if let screenPixels, max(screenPixels.width, screenPixels.height) * physical < minimumOpeningPoints {
            return false
        }
        return physical <= measured * (1 + ZoomMath.tolerance)
    }

    /// How long a stream may draw without the panel's density before the
    /// opening default gives up (a device whose density never arrives stays
    /// at Fit).
    static let densityGrace: Duration = .seconds(2)
    @ObservationIgnored private var graceTask: Task<Void, Never>?

    /// Settles the pending zoom as soon as the stream draws and the density
    /// is known. Called when the drawn scale or the density changes; does
    /// nothing while a user's choice or an earlier resolution ended it.
    func resolvePendingZoom() {
        guard let pending = pendingZoom, devicePixelSize() != nil,
              let measured = videoPointsPerPixel(), measured > 0
        else { return }
        let physical = physicalPointsPerPixel()
        switch pending {
        case .openingDefault:
            guard let physicalFits = Self.opensAtPhysicalSize(
                fitScale: measured, physical: physical, screenPixels: devicePixelSize()
            ) else {
                awaitDensity()
                return
            }
            pendingZoom = nil
            graceTask?.cancel()
            graceTask = nil
            if physicalFits { physicalSizeZoom(animated: false) }
        case .restore(let mode, _):
            guard targetPointsPerPixel(for: mode) != nil else {
                awaitDensity()
                return
            }
            pendingZoom = nil
            graceTask?.cancel()
            graceTask = nil
            scaleModeZoom(mode, animated: false)
        }
    }

    private func awaitDensity() {
        guard graceTask == nil else { return }
        graceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.densityGrace)
            guard !Task.isCancelled, let self else { return }
            self.pendingZoom = nil
            self.graceTask = nil
        }
    }

    // MARK: - Resize mode

    /// Device Hub's "Enter resize mode" (the aspect-ratio toggle in the
    /// first toolbar capsule, and Device > Enter Resize Mode): the stage
    /// offers the device's display sizes. Left with the same control, Esc,
    /// or by switching device.
    var isResizeModeActive = false

    func toggleResizeMode() {
        isResizeModeActive.toggle()
    }

    func exitResizeMode() {
        isResizeModeActive = false
    }

    /// Zoom-to-fit: the stage fits the device (Device Hub's "Zoom to Fit").
    var zoomIsFit: Bool { zoomMode == .fit }

    /// The video's points per streamed pixel now; nil before the first draw.
    @ObservationIgnored var videoPointsPerPixel: @MainActor () -> Double? = { nil }
    /// The points per streamed pixel that show the device at its real size
    /// on this Mac's screen; nil while the panel's density is unknown.
    @ObservationIgnored var physicalPointsPerPixel: @MainActor () -> Double? = { nil }

    /// Whether the device can be shown at its real size (its density and the
    /// stage's scale are both known).
    var canShowPhysicalSize: Bool {
        guard let measured = videoPointsPerPixel(), measured > 0,
              let physical = physicalPointsPerPixel(), physical > 0
        else { return false }
        return true
    }

    /// Zoom Out has nowhere left to go (DH greys the button out here).
    var isAtMinZoom: Bool {
        ZoomMath.isAtMinimum(zoom: stageZoom, measured: videoPointsPerPixel(), physical: physicalPointsPerPixel())
    }

    /// Zoom In has nowhere left to go (DH greys the button out here).
    var isAtMaxZoom: Bool {
        ZoomMath.isAtMaximum(zoom: stageZoom, measured: videoPointsPerPixel(), physical: physicalPointsPerPixel())
    }

    /// Physical Size is the selected mode.
    var zoomIsPhysicalSize: Bool { zoomMode == .physical }
    var zoomIsPointAccurate: Bool { zoomMode == .pointAccurate }
    var zoomIsPixelAccurate: Bool { zoomMode == .pixelAccurate }

    /// Mac points per streamed pixel that show one device point per Mac
    /// point (Point Accurate); nil while the density is unknown.
    @ObservationIgnored var pointAccuratePointsPerPixel: @MainActor () -> Double? = { nil }
    /// Mac points per streamed pixel that show one device pixel per Mac
    /// screen pixel (Pixel Accurate); nil before the first frame.
    @ObservationIgnored var pixelAccuratePointsPerPixel: @MainActor () -> Double? = { nil }

    /// The scale (Mac points per streamed pixel) a scale mode asks for.
    func targetPointsPerPixel(for mode: ZoomMode) -> Double? {
        switch mode {
        case .physical: physicalPointsPerPixel()
        case .pointAccurate: pointAccuratePointsPerPixel()
        case .pixelAccurate: pixelAccuratePointsPerPixel()
        case .fit, .custom: nil
        }
    }

    /// Whether Point Accurate can be applied (the stream's density is known).
    var canShowPointAccurate: Bool { canShow(.pointAccurate) }
    /// Whether Pixel Accurate can be applied.
    var canShowPixelAccurate: Bool { canShow(.pixelAccurate) }

    private func canShow(_ mode: ZoomMode) -> Bool {
        guard let measured = videoPointsPerPixel(), measured > 0,
              let target = targetPointsPerPixel(for: mode), target > 0
        else { return false }
        return true
    }

    func pointAccurateZoom(animated: Bool = true) { scaleModeZoom(.pointAccurate, animated: animated) }
    func pixelAccurateZoom(animated: Bool = true) { scaleModeZoom(.pixelAccurate, animated: animated) }

    /// Shows the device at its real size on this Mac's screen (Device Hub's
    /// "Physical Size"), staying there while the window or stream changes
    /// (`reconcileScaleZoom`). Does nothing while the density is unknown.
    func physicalSizeZoom(animated: Bool = true) {
        scaleModeZoom(.physical, animated: animated)
    }

    /// Shows the device at the scale `mode` names and keeps it there
    /// (`reconcileScaleZoom`). Does nothing while that scale is unknown.
    func scaleModeZoom(_ mode: ZoomMode, animated: Bool = true) {
        guard mode.isScaleMode, let zoom = ZoomMath.physicalZoom(
            from: stageZoom,
            measured: videoPointsPerPixel(),
            physical: targetPointsPerPixel(for: mode)
        ) else { return }
        pendingZoom = nil
        zoomMode = mode
        physicalCorrections = 0
        if animated {
            applyZoom(zoom)
        } else {
            stageZoom = zoom
            zoomPresentation = 1
        }
    }

    /// How many silent corrections the current physical-size request has
    /// used: the layout is only nearly proportional to the zoom, so the
    /// first landing is corrected by measuring, a few times at most.
    @ObservationIgnored private var physicalCorrections = 0

    /// A new stage size starts a new round of corrections.
    func noteViewportChanged() {
        physicalCorrections = 0
    }

    /// While a scale mode (Physical Size, Point or Pixel Accurate) is
    /// selected, closes what is left of the gap between the drawn scale and
    /// the one it names. Called when the drawn scale or the viewport
    /// changes; never animates.
    func reconcileScaleZoom() {
        guard zoomMode.isScaleMode, physicalCorrections < 6,
              let corrected = ZoomMath.correction(
                  from: stageZoom,
                  measured: videoPointsPerPixel(),
                  physical: targetPointsPerPixel(for: zoomMode)
              )
        else { return }
        physicalCorrections += 1
        stageZoom = corrected
    }

    /// Visual zoom multiplier applied on top of the committed layout. Set to
    /// the old/new zoom ratio in the same update as `stageZoom` (so the
    /// content never flashes at the new size), then animated to 1 — the Metal
    /// drawable is always at its final resolution, only the wrapper scales.
    private(set) var zoomPresentation: CGFloat = 1

    private func applyZoom(_ newZoom: Double?) {
        // Relative to the *current* presentation so a second step while the
        // first is still animating continues from what is on screen instead
        // of jumping back to the nominal size.
        let transition = ZoomMath.transition(
            from: stageZoom,
            to: newZoom,
            currentPresentation: zoomPresentation,
            reduceMotion: MotionMetrics.reduceMotion
        )
        stageZoom = newZoom
        zoomPresentation = transition.presentation
        guard transition.animatesToIdentity else { return }
        // Let the ratio render with the committed layout first, then animate
        // it away on the next runloop turn; animating in the same turn would
        // coalesce with the commit and skip the transition.
        Task { @MainActor [weak self] in
            guard let self else { return }
            MotionMetrics.run(MotionMetrics.zoom) {
                self.zoomPresentation = 1
            }
        }
    }

    /// Stage viewport, published by the device stage for zoom math.
    var stageViewportSize: CGSize = .zero
    /// The size the device composition occupies on the main stage at rest
    /// (`PosePresentation.restExtent`); the TV remote sits right under it.
    var deviceExtent: CGSize = .zero

    private func stepZoom(up: Bool) {
        let target = ZoomMath.step(
            from: stageZoom,
            up: up,
            measured: videoPointsPerPixel(),
            physical: physicalPointsPerPixel()
        )
        // A step at its limit stays where it is (and keeps the mode).
        guard abs(target - (stageZoom ?? 1.0)) > 1e-9 || stageZoom == nil else { return }
        pendingZoom = nil
        zoomMode = .custom
        applyZoom(target)
    }
}

/// A pending choice among development teams. `answer` is idempotent: the
/// first call resumes the waiting runner start, later ones do nothing.
@MainActor
final class TeamPickerRequest: Identifiable {
    let id = UUID()
    let teams: [SigningTeam]
    private var completion: ((SigningTeam?) -> Void)?

    init(teams: [SigningTeam], completion: @escaping (SigningTeam?) -> Void) {
        self.teams = teams
        self.completion = completion
    }

    func answer(_ team: SigningTeam?) {
        completion?(team)
        completion = nil
    }
}
