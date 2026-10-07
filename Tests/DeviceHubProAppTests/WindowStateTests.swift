import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// The window's presentation state on its own, with no model: the inspector
/// routing, the Diagnostics hook, the toggles and the stage zoom.
@MainActor
final class WindowStateTests: XCTestCase {
    /// Compact mode hides the main window (`orderOut`) while the compact
    /// mirror shows the same session: the stage still counts as on screen,
    /// or the compact mirror froze and a physical iPhone's capture stopped.
    func testTheCompactMirrorKeepsTheStageVisibleWhileTheMainWindowIsHidden() {
        let window = WindowState()
        XCTAssertTrue(window.isStageVisible)
        window.isWindowVisible = false
        XCTAssertFalse(window.isStageVisible, "hidden, no compact mirror: nothing shows the stage")
        window.isCompactMirrorPresented = true
        XCTAssertTrue(window.isStageVisible, "the compact mirror shows it")
        window.isCompactMirrorPresented = false
        window.isWindowVisible = true
        XCTAssertTrue(window.isStageVisible)
    }

    /// A window whose Diagnostics hook counts its calls.
    private func makeWindow(tab: WindowState.InspectorTab, showing: Bool) -> (WindowState, () -> Int) {
        let window = WindowState()
        window.inspectorTab = tab
        window.showInspector = showing
        var diagnosticsOpens = 0
        window.openDiagnosticsLogcat = { diagnosticsOpens += 1 }
        return (window, { diagnosticsOpens })
    }

    // MARK: - Defaults

    /// A new window starts with the Settings panel in a shown inspector, the frame on, the stats HUD off, every device listed
    /// running-first, the sidebar shown, no sheet up and the stage fitted.
    func testANewWindowStartsWithTheSettingsInspectorAndAFittedStage() {
        let window = WindowState()
        XCTAssertEqual(window.inspectorTab, .controls)
        XCTAssertTrue(window.showInspector)
        XCTAssertTrue(window.showDeviceFrame)
        XCTAssertFalse(window.showMirrorStats)
        XCTAssertFalse(window.isCompactMirrorPresented)
        XCTAssertEqual(window.deviceSortMode, .availability)
        XCTAssertTrue(window.deviceShowsGroups)
        XCTAssertEqual(window.deviceFilter, .all)
        XCTAssertEqual(window.columnVisibility, .all)
        XCTAssertFalse(window.isCatalogPresented)
        XCTAssertFalse(window.isPairSheetPresented)
        XCTAssertNil(window.createFormFactor)
        XCTAssertNil(window.stageZoom)
        XCTAssertTrue(window.isWindowVisible, "visible until a real occlusion signal says otherwise")
        XCTAssertTrue(window.zoomIsFit)
        XCTAssertEqual(window.zoomPresentation, 1)
        XCTAssertEqual(window.stageViewportSize, .zero)
    }

    // MARK: - Inspector tabs

    /// A device opens on Settings; a surface the user picked for a device
    /// comes back with that device and does not follow to another one.
    func testADeviceOpensOnSettingsUnlessTheUserChoseAnotherSurfaceForIt() {
        let window = WindowState()
        window.showsDevice("a")
        XCTAssertEqual(window.inspectorTab, .controls)
        window.inspectorTab = .apps
        window.showsDevice("b")
        XCTAssertEqual(window.inspectorTab, .controls, "a new device opens on Settings")
        window.showsDevice("a")
        XCTAssertEqual(window.inspectorTab, .apps, "the choice made for a is kept")
        window.showsDevice("b")
        XCTAssertEqual(window.inspectorTab, .controls, "b never chose")
        window.showsDevice(nil)
        window.showsDevice("a")
        XCTAssertEqual(window.inspectorTab, .apps)
    }

    func testReselectingTheShownTabHidesTheInspectorAndKeepsTheTab() {
        let (window, _) = makeWindow(tab: .controls, showing: true)
        window.selectInspectorTab(.controls)
        XCTAssertFalse(window.showInspector)
        XCTAssertEqual(window.inspectorTab, .controls)
    }

    func testSelectingATabShowsItFromAnotherTabOrAHiddenInspector() {
        let (shown, _) = makeWindow(tab: .apps, showing: true)
        shown.selectInspectorTab(.controls)
        XCTAssertTrue(shown.showInspector)
        XCTAssertEqual(shown.inspectorTab, .controls)

        // A hidden inspector reopens on the tab asked for, even its last one.
        let (hidden, _) = makeWindow(tab: .controls, showing: false)
        hidden.selectInspectorTab(.controls)
        XCTAssertTrue(hidden.showInspector)
        XCTAssertEqual(hidden.inspectorTab, .controls)
    }

    // MARK: - Diagnostics hook

    func testShowingDiagnosticsCallsTheHookOnce() {
        let (window, opens) = makeWindow(tab: .apps, showing: true)
        window.selectInspectorTab(.diagnostics)
        XCTAssertEqual(opens(), 1)
        XCTAssertEqual(window.inspectorTab, .diagnostics)
        XCTAssertTrue(window.showInspector)

        // Hidden, then shown again: each showing asks, the hiding does not.
        window.selectInspectorTab(.diagnostics)
        XCTAssertFalse(window.showInspector)
        XCTAssertEqual(opens(), 1, "hiding Diagnostics opens nothing")
        window.selectInspectorTab(.diagnostics)
        XCTAssertEqual(opens(), 2)
    }

    func testOtherTabsAndTheInfoButtonNeverCallTheHook() {
        let (window, opens) = makeWindow(tab: .diagnostics, showing: false)
        for tab in [WindowState.InspectorTab.info, .apps, .controls] {
            window.selectInspectorTab(tab)
        }
        window.toggleDeviceInfoInspector()
        window.toggleDeviceInfoInspector()
        XCTAssertEqual(opens(), 0)
    }

    // MARK: - Sidebar filter (TB-01, 2026-09-28)

    /// DH's filter toolbar item turns blue once its filter narrows the list:
    /// the type filter off "All Devices". Sort order is not a filter (it
    /// reorders, not narrows), so it stays unlit.
    func testTheFilterIsActiveOnlyWhileSomethingNarrowsTheList() {
        let window = WindowState()
        XCTAssertFalse(window.isSidebarFilterActive, "the defaults show every device")

        window.deviceFilter = .emulators
        XCTAssertTrue(window.isSidebarFilterActive)
        window.deviceFilter = .all
        XCTAssertFalse(window.isSidebarFilterActive)

        window.deviceFilter = .physical
        XCTAssertTrue(window.isSidebarFilterActive)
        window.deviceFilter = .all

        // Not a filter: sorting.
        window.deviceSortMode = .name
        XCTAssertFalse(window.isSidebarFilterActive)
    }

    // MARK: - Toggles

    func testTheFrameAndStatsTogglesFlipTheirFlag() {
        let window = WindowState()
        window.toggleDeviceFrame()
        XCTAssertFalse(window.showDeviceFrame)
        window.toggleDeviceFrame()
        XCTAssertTrue(window.showDeviceFrame)

        window.toggleMirrorStats()
        XCTAssertTrue(window.showMirrorStats)
        window.toggleMirrorStats()
        XCTAssertFalse(window.showMirrorStats)
    }

    // MARK: - Zoom

    func testZoomStepsMultiplyAndResetFits() {
        let window = WindowState()
        window.zoomIn()
        XCTAssertEqual(window.stageZoom ?? 0, 1.25, accuracy: 1e-12, "fit counts as 1.0")
        window.zoomIn()
        XCTAssertEqual(window.stageZoom ?? 0, 1.5625, accuracy: 1e-12)
        window.zoomOut()
        XCTAssertEqual(window.stageZoom ?? 0, 1.171875, accuracy: 1e-12, "0.75, not the inverse of 1.25")
        XCTAssertFalse(window.zoomIsFit)

        // Without a physical scale the limits are 0.25 and 8 times the fit.
        for _ in 0..<30 { window.zoomOut() }
        XCTAssertEqual(window.stageZoom, 0.25)
        for _ in 0..<30 { window.zoomIn() }
        XCTAssertEqual(window.stageZoom, 8)

        window.resetZoom()
        XCTAssertNil(window.stageZoom)
        XCTAssertTrue(window.zoomIsFit)
    }

    // MARK: - Opening zoom and per-device memory

    /// A window whose stream draws `measured` points per pixel at Fit and
    /// whose panel would show `physical` points per pixel at its real size
    /// (nil: density unknown). The hooks read the boxes, so a test moves them.
    private final class Stream {
        var measured: Double? = 0.5
        var physical: Double? = 0.2
        var pixels: CGSize? = CGSize(width: 1080, height: 2400)
    }

    private func makeStreamingWindow() -> (WindowState, Stream) {
        let window = WindowState()
        let stream = Stream()
        window.devicePixelSize = { stream.pixels }
        window.videoPointsPerPixel = { stream.measured }
        window.physicalPointsPerPixel = { stream.physical }
        return (window, stream)
    }

    /// Device Hub opens an iPhone at Physical Size (TB-08, measured on
    /// Xcode 27.0): a device whose real size fits opens there, the scale
    /// on screen becoming the physical one.
    func testANewDeviceOpensAtPhysicalSizeWhenItFits() {
        let (window, _) = makeStreamingWindow()
        window.showsDevice("simulator(iPhone)")
        XCTAssertEqual(window.pendingZoom, .openingDefault)
        XCTAssertTrue(window.zoomIsFit, "Fit until the stream draws")
        window.resolvePendingZoom()
        XCTAssertTrue(window.zoomIsPhysicalSize)
        XCTAssertEqual(window.stageZoom ?? 0, 0.4, accuracy: 1e-12, "physical 0.2 over drawn 0.5")
        XCTAssertNil(window.pendingZoom)
        XCTAssertEqual(window.zoomPresentation, 1, "a new device is a new picture, not an animation")
    }

    /// An iPad Pro 13" at its real size is larger than Fit in the stage, and
    /// Device Hub opens it at Fit.
    func testANewDeviceThatDoesNotFitAtItsRealSizeOpensAtFit() {
        let (window, stream) = makeStreamingWindow()
        stream.physical = 0.62
        window.showsDevice("simulator(iPad)")
        window.resolvePendingZoom()
        XCTAssertTrue(window.zoomIsFit)
        XCTAssertNil(window.stageZoom)
        XCTAssertNil(window.pendingZoom, "decided")
        XCTAssertTrue(window.canShowPhysicalSize, "the button still offers Physical Size, which then clips and pans")
    }

    func testTheOpeningDefaultWaitsForTheStreamAndTheDensity() {
        let (window, stream) = makeStreamingWindow()
        stream.pixels = nil
        window.showsDevice("device(emulator-5554)")
        window.resolvePendingZoom()
        XCTAssertEqual(window.pendingZoom, .openingDefault, "no frame yet")

        stream.pixels = CGSize(width: 1080, height: 2400)
        stream.physical = nil
        window.resolvePendingZoom()
        XCTAssertEqual(window.pendingZoom, .openingDefault, "a physical device with no density stays at Fit for now")
        XCTAssertTrue(window.zoomIsFit)

        stream.physical = 0.25
        window.resolvePendingZoom()
        XCTAssertTrue(window.zoomIsPhysicalSize, "the density arrived")
    }

    /// A choice the user makes settles the zoom: the default never moves the
    /// stage under them afterwards.
    func testAUserZoomChoiceEndsTheOpeningDefault() {
        let (window, stream) = makeStreamingWindow()
        stream.physical = nil
        window.showsDevice("a")
        window.zoomIn()
        XCTAssertNil(window.pendingZoom)
        stream.physical = 0.25
        window.resolvePendingZoom()
        XCTAssertEqual(window.zoomMode, .custom)

        window.showsDevice("b")
        window.resetZoom()
        XCTAssertNil(window.pendingZoom)
        window.resolvePendingZoom()
        XCTAssertTrue(window.zoomIsFit)
    }

    /// Device Hub keeps the zoom per device for the session: a device the
    /// window shows again comes back to what it was at, not to a neighbour's.
    func testTheZoomIsRememberedPerDevice() {
        let (window, _) = makeStreamingWindow()
        window.showsDevice("a")
        window.resolvePendingZoom()
        XCTAssertTrue(window.zoomIsPhysicalSize)

        window.showsDevice("b")
        XCTAssertTrue(window.zoomIsFit, "a device the window has not shown starts from Fit")
        window.resolvePendingZoom()
        XCTAssertTrue(window.zoomIsPhysicalSize)
        window.resetZoom()

        window.showsDevice("a")
        XCTAssertEqual(window.pendingZoom, .restore(.physical, 0.4), "physical again, once measured")
        window.resolvePendingZoom()
        XCTAssertTrue(window.zoomIsPhysicalSize)

        window.showsDevice("b")
        XCTAssertTrue(window.zoomIsFit, "b was left at Fit")
        XCTAssertNil(window.pendingZoom, "and no default overrides it")
        window.resolvePendingZoom()
        XCTAssertTrue(window.zoomIsFit)

        window.zoomIn()
        window.showsDevice("a")
        window.showsDevice("b")
        XCTAssertEqual(window.zoomMode, .custom)
        XCTAssertEqual(window.stageZoom ?? 0, 1.25, accuracy: 1e-12)
    }

    func testOpensAtPhysicalSizeNeedsBothScales() {
        XCTAssertNil(WindowState.opensAtPhysicalSize(fitScale: nil, physical: 0.2))
        XCTAssertNil(WindowState.opensAtPhysicalSize(fitScale: 0.5, physical: nil))
        XCTAssertEqual(WindowState.opensAtPhysicalSize(fitScale: 0.5, physical: 0.5), true, "equal fits")
        XCTAssertEqual(WindowState.opensAtPhysicalSize(fitScale: 0.5, physical: 0.51), false)
    }

    /// Wear OS Large Round is 454 px and about 100 pt at its real size: a new
    /// watch opens at Fit, a phone (1080x2400, ~400 pt long side at 1x) at Physical Size.
    func testAWatchTooSmallAtItsRealSizeOpensAtFit() {
        XCTAssertEqual(
            WindowState.opensAtPhysicalSize(
                fitScale: 1.5, physical: 0.22, screenPixels: CGSize(width: 454, height: 454)
            ),
            false
        )
        XCTAssertEqual(
            WindowState.opensAtPhysicalSize(
                fitScale: 0.5, physical: 0.4, screenPixels: CGSize(width: 1080, height: 2400)
            ),
            true
        )
    }

    // MARK: - Resize mode

    func testResizeModeTogglesAndEndsWithTheDevice() {
        let window = WindowState()
        window.showsDevice("a")
        XCTAssertFalse(window.isResizeModeActive)
        window.toggleResizeMode()
        XCTAssertTrue(window.isResizeModeActive)
        window.toggleResizeMode()
        XCTAssertFalse(window.isResizeModeActive)

        window.toggleResizeMode()
        window.showsDevice("b")
        XCTAssertFalse(window.isResizeModeActive, "resize mode belongs to the device it was entered on")
        window.toggleResizeMode()
        window.exitResizeMode()
        XCTAssertFalse(window.isResizeModeActive)
    }

    func testAZoomStepEndsWithTheIdentityPresentation() async {
        let window = WindowState()
        window.zoomIn()
        // With motion, the old/new ratio animates back to 1 on the next turn;
        // with Reduce Motion it snaps to 1 at once.
        await waitUntil("the presentation never settled") { window.zoomPresentation == 1 }
        XCTAssertEqual(window.stageZoom, 1.25)
    }

    /// The animation task holds the window weakly: a window closed right
    /// after a zoom step is not kept alive by it.
    func testTheZoomAnimationDoesNotKeepTheWindowAlive() {
        weak var released: WindowState?
        do {
            let window = WindowState()
            released = window
            window.zoomIn()
        }
        XCTAssertNil(released)
    }
}

/// The two hooks as the model wires them: Diagnostics opens logcat for the
/// live device unless it already streams it, and the zoom measures the
/// mirror's stream. The model has no adb, so an open only records its serial.
@MainActor
final class WindowStateModelWiringTests: XCTestCase {
    private let serial = "emulator-5554"

    private func liveModel() -> AppModel {
        let model = AppModel.testing()
        addTeardownBlock { @MainActor in model.workspace.logcat.stopLogcat() }
        model.inventory.devices = [.online(serial)]
        model.deviceSelection = .device(serial)
        return model
    }

    /// Main-actor jobs run in the order they were queued, so a logcat open
    /// the hook queued has run once this barrier has.
    private func drainQueuedOpens() async {
        await Task { @MainActor in }.value
    }

    func testDiagnosticsOpensLogcatForTheLiveDevice() async {
        let model = liveModel()
        model.workspace.window.selectInspectorTab(.diagnostics)
        await waitUntil("Diagnostics never opened logcat") { model.workspace.logcat.logcatSerial == self.serial }
    }

    func testDiagnosticsKeepsTheStreamAlreadyOnTheLiveDevice() async {
        let model = liveModel()
        model.workspace.window.selectInspectorTab(.diagnostics)
        await waitUntil("Diagnostics never opened logcat") { model.workspace.logcat.logcatSerial == self.serial }
        // A reopen would clear the search field along with the stream.
        model.workspace.logcat.logcatSearch = "kept"

        model.workspace.window.selectInspectorTab(.diagnostics)
        model.workspace.window.selectInspectorTab(.diagnostics)
        await drainQueuedOpens()

        XCTAssertTrue(model.workspace.window.showInspector)
        XCTAssertEqual(model.workspace.logcat.logcatSerial, serial)
        XCTAssertEqual(model.workspace.logcat.logcatSearch, "kept", "showing Diagnostics again restarted the stream")
    }

    func testDiagnosticsWithoutALiveDeviceOpensNothing() async {
        let model = AppModel.testing()
        addTeardownBlock { @MainActor in model.workspace.logcat.stopLogcat() }
        // Selected but not online: nothing is live.
        model.deviceSelection = .device(serial)

        model.workspace.window.selectInspectorTab(.diagnostics)
        await drainQueuedOpens()

        XCTAssertEqual(model.workspace.window.inspectorTab, .diagnostics)
        XCTAssertNil(model.workspace.logcat.logcatSerial)
    }
}
