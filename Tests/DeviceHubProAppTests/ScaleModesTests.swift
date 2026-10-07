import AppKit
import XCTest
@testable import DeviceHubProApp

/// Simulator.app's Point Accurate / Pixel Accurate scale modes: the
/// arithmetic and the window's sticky modes (the live checks are on the
/// running app).
final class ScaleModesTests: XCTestCase {
    // MARK: - Arithmetic

    /// An iPhone at 3x (densityDpi 480): a device point is three panel
    /// pixels, so one Mac point per device point draws a streamed pixel at
    /// one third of a Mac point.
    func testPointAccurateIsOneOverTheScale() throws {
        let iphone = try XCTUnwrap(ZoomMath.pointAccuratePointsPerPixel(densityDpi: 480, panelLongSide: nil, streamLongSide: nil))
        XCTAssertEqual(iphone, 1.0 / 3.0, accuracy: 1e-12)
        // Android: 420 dpi is 2.625 px per dp.
        let android = try XCTUnwrap(ZoomMath.pointAccuratePointsPerPixel(densityDpi: 420, panelLongSide: nil, streamLongSide: nil))
        XCTAssertEqual(android, 160.0 / 420.0, accuracy: 1e-12)
    }

    /// A stream downscaled to half the panel covers two panel pixels per
    /// streamed pixel: each streamed pixel is worth twice the Mac points.
    func testTheStreamRatioCarriesToBothModes() throws {
        let point = try XCTUnwrap(ZoomMath.pointAccuratePointsPerPixel(densityDpi: 480, panelLongSide: 2400, streamLongSide: 1200))
        XCTAssertEqual(point, 2.0 / 3.0, accuracy: 1e-12)
        let pixel = try XCTUnwrap(ZoomMath.pixelAccuratePointsPerPixel(backingScaleFactor: 2, panelLongSide: 2400, streamLongSide: 1200))
        XCTAssertEqual(pixel, 1.0, accuracy: 1e-12)
    }

    func testPixelAccurateFollowsTheBackingScale() throws {
        let retina = try XCTUnwrap(ZoomMath.pixelAccuratePointsPerPixel(backingScaleFactor: 2, panelLongSide: nil, streamLongSide: nil))
        XCTAssertEqual(retina, 0.5, accuracy: 1e-12)
        let standard = try XCTUnwrap(ZoomMath.pixelAccuratePointsPerPixel(backingScaleFactor: 1, panelLongSide: nil, streamLongSide: nil))
        XCTAssertEqual(standard, 1.0, accuracy: 1e-12)
        XCTAssertNil(ZoomMath.pixelAccuratePointsPerPixel(backingScaleFactor: 0, panelLongSide: nil, streamLongSide: nil))
    }

    func testPointAccurateNeedsTheDensity() {
        XCTAssertNil(ZoomMath.pointAccuratePointsPerPixel(densityDpi: nil, panelLongSide: 2400, streamLongSide: 2400))
        XCTAssertNil(ZoomMath.pointAccuratePointsPerPixel(densityDpi: 0, panelLongSide: nil, streamLongSide: nil))
    }

    // MARK: - The window's modes

    private final class Stream {
        var measured: Double? = 0.5
        var physical: Double? = 0.2
        var point: Double? = 1.0 / 3.0
        var pixel: Double? = 0.5
        var pixels: CGSize? = CGSize(width: 1080, height: 2400)
    }

    @MainActor
    private func makeWindow() -> (WindowState, Stream) {
        let window = WindowState()
        let stream = Stream()
        window.devicePixelSize = { stream.pixels }
        window.videoPointsPerPixel = { stream.measured }
        window.physicalPointsPerPixel = { stream.physical }
        window.pointAccuratePointsPerPixel = { stream.point }
        window.pixelAccuratePointsPerPixel = { stream.pixel }
        return (window, stream)
    }

    @MainActor
    func testPointAndPixelAccurateSelectTheirScale() {
        let (window, stream) = makeWindow()
        window.pointAccurateZoom()
        XCTAssertEqual(window.zoomMode, .pointAccurate)
        XCTAssertTrue(window.zoomIsPointAccurate)
        XCTAssertEqual(window.stageZoom ?? 0, (1.0 / 3.0) / 0.5, accuracy: 1e-12)
        // The layout lands: the drawn scale is Fit's 0.5 times the zoom.
        stream.measured = 0.5 * (window.stageZoom ?? 1)

        window.pixelAccurateZoom()
        XCTAssertEqual(window.zoomMode, .pixelAccurate)
        XCTAssertFalse(window.zoomIsPointAccurate)
        XCTAssertEqual(window.stageZoom ?? 0, 1.0, accuracy: 1e-12, "0.5 over 0.5 drawn")

        window.physicalSizeZoom()
        XCTAssertTrue(window.zoomIsPhysicalSize)
        window.resetZoom()
        XCTAssertTrue(window.zoomIsFit)
    }

    /// The mode is sticky like Physical Size: the stage's reconcile closes
    /// the gap after a layout change.
    @MainActor
    func testAPointAccurateModeStaysThroughALayoutChange() {
        let (window, stream) = makeWindow()
        window.pointAccurateZoom()
        let zoom = window.stageZoom ?? 0
        stream.measured = 0.35
        window.reconcileScaleZoom()
        XCTAssertEqual(window.stageZoom ?? 0, zoom * (1.0 / 3.0) / 0.35, accuracy: 1e-12)
        XCTAssertEqual(window.zoomMode, .pointAccurate)

        stream.measured = 1.0 / 3.0 + 0.0001
        let settled = window.stageZoom
        window.reconcileScaleZoom()
        XCTAssertEqual(window.stageZoom, settled, "within tolerance")
    }

    @MainActor
    func testAFreeStepLeavesTheAccurateMode() {
        let (window, _) = makeWindow()
        window.pixelAccurateZoom()
        window.zoomIn()
        XCTAssertEqual(window.zoomMode, .custom)
        let zoom = window.stageZoom
        window.reconcileScaleZoom()
        XCTAssertEqual(window.stageZoom, zoom, "a custom zoom is not reconciled")
    }

    @MainActor
    func testAnUnknownScaleDisablesAndIgnoresTheMode() {
        let (window, stream) = makeWindow()
        stream.point = nil
        XCTAssertFalse(window.canShowPointAccurate)
        XCTAssertTrue(window.canShowPixelAccurate)
        window.pointAccurateZoom()
        XCTAssertNil(window.stageZoom)
        XCTAssertTrue(window.zoomIsFit)
    }

    @MainActor
    func testTheModeIsRememberedPerDevice() {
        let (window, stream) = makeWindow()
        window.showsDevice("a")
        window.resolvePendingZoom()
        stream.measured = 0.5 * (window.stageZoom ?? 1)
        window.pixelAccurateZoom()
        let zoom = window.stageZoom
        window.showsDevice("b")
        window.resolvePendingZoom()
        window.showsDevice("a")
        XCTAssertEqual(window.pendingZoom, .restore(.pixelAccurate, zoom))
        window.resolvePendingZoom()
        XCTAssertEqual(window.zoomMode, .pixelAccurate)
    }
}
