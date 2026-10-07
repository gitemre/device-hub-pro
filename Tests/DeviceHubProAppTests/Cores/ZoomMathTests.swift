import XCTest
import DeviceHubProKit
@testable import DeviceHubProApp

/// Device Hub's multiplicative zoom steps, its limits, the physical size and
/// the presentation ratio. The steps and limits are DH 27.0's, measured live
/// (parity audit, TB-08): × 1.25 in, × 0.75 out, greyed at 0.45 of the
/// physical scale below and at ten times it (here capped at the native
/// pixel) above.
final class ZoomMathTests: XCTestCase {
    /// An AVD's stage: 0.23 points per pixel at fit, physical 0.20.
    private let measured = 0.23
    private let physical = 0.20

    // MARK: - Steps

    func testStepsMultiplyByOneAndAQuarterAndThreeQuarters() {
        XCTAssertEqual(ZoomMath.step(from: nil, up: true, measured: measured, physical: physical), 1.25, accuracy: 1e-12)
        XCTAssertEqual(ZoomMath.step(from: nil, up: false, measured: measured, physical: physical), 0.75, accuracy: 1e-12)
        XCTAssertEqual(ZoomMath.step(from: 1.25, up: true, measured: 0.2875, physical: physical), 1.5625, accuracy: 1e-12)
        XCTAssertEqual(ZoomMath.step(from: 0.75, up: false, measured: 0.1725, physical: physical), 0.5625, accuracy: 1e-12)
    }

    func testAStepDownIsNotTheInverseOfAStepUp() {
        let up = ZoomMath.step(from: nil, up: true, measured: measured, physical: physical)
        let back = ZoomMath.step(from: up, up: false, measured: measured * up, physical: physical)
        XCTAssertEqual(back, 0.9375, accuracy: 1e-12, "1.25 × 0.75, as Device Hub lands")
    }

    func testTheBottomStopsAtFortyFivePercentOfPhysical() {
        // Physical 0.20 → floor 0.09. From 0.10 a step down would reach 0.075.
        let stepped = ZoomMath.step(from: 0.4348, up: false, measured: 0.10, physical: physical)
        XCTAssertEqual(0.10 * stepped / 0.4348, 0.09, accuracy: 1e-9)
        XCTAssertTrue(ZoomMath.isAtMinimum(zoom: 0.39, measured: 0.09, physical: physical))
        XCTAssertFalse(ZoomMath.isAtMinimum(zoom: 0.5, measured: 0.115, physical: physical))
    }

    func testTheTopStopsAtTenTimesPhysicalOrTheNativePixel() {
        // Physical 0.05 → ten times is 0.5, under the native pixel.
        XCTAssertEqual(ZoomMath.maximum(physical: 0.05), 0.5, accuracy: 1e-12)
        // Physical 0.2 → ten times is 2, capped at one point per pixel.
        XCTAssertEqual(ZoomMath.maximum(physical: 0.2), 1.0, accuracy: 1e-12)
        XCTAssertTrue(ZoomMath.isAtMaximum(zoom: 4.3, measured: 1.0, physical: 0.2))
        XCTAssertFalse(ZoomMath.isAtMaximum(zoom: 4, measured: 0.9, physical: 0.2))

        let stepped = ZoomMath.step(from: 4.0, up: true, measured: 0.9, physical: 0.2)
        XCTAssertEqual(0.9 * stepped / 4.0, 1.0, accuracy: 1e-9, "clamped to the ceiling, not 1.125")
    }

    func testWithoutAPhysicalScaleTheLimitsAreRelativeToFit() {
        XCTAssertEqual(ZoomMath.step(from: 0.3, up: false, measured: nil, physical: nil), 0.25, "0.225 clamps")
        XCTAssertEqual(ZoomMath.step(from: 7, up: true, measured: nil, physical: nil), 8)
        XCTAssertTrue(ZoomMath.isAtMinimum(zoom: 0.25, measured: nil, physical: nil))
        XCTAssertTrue(ZoomMath.isAtMaximum(zoom: 8, measured: nil, physical: nil))
        XCTAssertFalse(ZoomMath.isAtMinimum(zoom: nil, measured: nil, physical: nil))
    }

    // MARK: - Fit and physical

    func testFitIsTheNilZoom() {
        XCTAssertTrue(ZoomMath.isFit(zoom: nil))
        XCTAssertFalse(ZoomMath.isFit(zoom: 1.0))
    }

    func testPhysicalZoomScalesTheCurrentZoomByTheScaleRatio() {
        // Fit (1.0) draws 0.23; the real size is 0.20.
        XCTAssertEqual(ZoomMath.physicalZoom(from: nil, measured: 0.23, physical: 0.20) ?? 0, 0.20 / 0.23, accuracy: 1e-12)
        // Already at 2.0 drawing 0.46: the same target from there.
        XCTAssertEqual(ZoomMath.physicalZoom(from: 2.0, measured: 0.46, physical: 0.20) ?? 0, 2.0 * 0.20 / 0.46, accuracy: 1e-12)
        XCTAssertNil(ZoomMath.physicalZoom(from: nil, measured: nil, physical: 0.2))
        XCTAssertNil(ZoomMath.physicalZoom(from: nil, measured: 0.2, physical: nil))
    }

    func testTheCorrectionClosesWhatTheLayoutLeftAndStopsWithinTolerance() {
        // Drew 0.2062 for a 0.20 target: 3% over.
        XCTAssertEqual(ZoomMath.correction(from: 0.87, measured: 0.2062, physical: 0.20) ?? 0, 0.87 * 0.20 / 0.2062, accuracy: 1e-12)
        XCTAssertNil(ZoomMath.correction(from: 0.87, measured: 0.2003, physical: 0.20), "0.15% is within tolerance")
        XCTAssertNil(ZoomMath.correction(from: 0.87, measured: nil, physical: 0.20))
    }

    func testFitScaleFitsTheTighterAxis() {
        let scale = ZoomMath.fitScale(
            devicePixelSize: CGSize(width: 1080, height: 2400),
            viewport: CGSize(width: 800, height: 600)
        )
        XCTAssertEqual(scale, 600 * 0.96 / 2400, accuracy: 1e-12)
        XCTAssertEqual(ZoomMath.fitScale(devicePixelSize: nil, viewport: CGSize(width: 800, height: 600)), 0)
        XCTAssertEqual(ZoomMath.fitScale(devicePixelSize: CGSize(width: 1080, height: 2400), viewport: .zero), 0)
    }

    // MARK: - Physical size

    func testTheDensityIsThePanelsXDpiThenTheLogicalOneThenTheFallback() {
        XCTAssertEqual(ZoomMath.devicePixelsPerInch(xDpi: 460, densityDpi: 480, fallback: 420), 460)
        XCTAssertEqual(ZoomMath.devicePixelsPerInch(xDpi: 12, densityDpi: 480, fallback: 420), 480, "an implausible xDpi is ignored")
        XCTAssertEqual(ZoomMath.devicePixelsPerInch(xDpi: nil, densityDpi: nil, fallback: 420), 420)
        XCTAssertNil(ZoomMath.devicePixelsPerInch(xDpi: nil, densityDpi: nil, fallback: nil), "no density, no physical size")
    }

    /// This Mac's display (EDID 598.38 mm for 1920 pt): 81.5 points per
    /// inch; an iPhone 17's 460 dpi then shows at 0.1772 pt per pixel, and
    /// its 436 pt-wide chrome (1308 px) at 231.8 pt, which Device Hub
    /// measured at 234.5 pt with the side buttons.
    func testTheMacsPointsPerInchComesFromTheDisplaysSize() {
        let ppi = ZoomMath.macPointsPerInch(screenWidthMillimetres: 598.380359, screenWidthPoints: 1920)
        XCTAssertEqual(ppi, 81.5, accuracy: 0.05)
        let physical = ZoomMath.physicalPointsPerPixel(
            macPointsPerInch: ppi, devicePixelsPerInch: 460, panelLongSide: 2622, streamLongSide: 2622
        )
        XCTAssertEqual(physical ?? 0, 0.1772, accuracy: 0.0005)
    }

    func testADisplayThatReportsNoSizeFallsBack() {
        XCTAssertEqual(ZoomMath.macPointsPerInch(screenWidthMillimetres: 0, screenWidthPoints: 1920), 110)
        XCTAssertEqual(ZoomMath.macPointsPerInch(screenWidthMillimetres: 20, screenWidthPoints: 1920), 110)
        XCTAssertEqual(ZoomMath.macPointsPerInch(screenWidthMillimetres: 600, screenWidthPoints: 60), 110)
    }

    func testADownscaledStreamCoversMoreOfThePanelPerPixel() {
        // Half the panel's resolution: each streamed pixel is two panel pixels.
        let full = ZoomMath.physicalPointsPerPixel(
            macPointsPerInch: 81.5, devicePixelsPerInch: 400, panelLongSide: 2400, streamLongSide: 2400
        )
        let half = ZoomMath.physicalPointsPerPixel(
            macPointsPerInch: 81.5, devicePixelsPerInch: 400, panelLongSide: 2400, streamLongSide: 1200
        )
        XCTAssertEqual((half ?? 0) / (full ?? 1), 2, accuracy: 1e-12)
        XCTAssertNil(ZoomMath.physicalPointsPerPixel(macPointsPerInch: 0, devicePixelsPerInch: 400, panelLongSide: nil, streamLongSide: nil))
    }

    /// A physical iPhone 12 (1170x2532 panel at 460 dpi, streamed whole) is the same physical size
    /// in either pose: the scale counts long sides, so the portrait and the landscape frame of
    /// one stream give the same points per pixel, and the long edge lands on the same length.
    func testAPhoneHasTheSamePhysicalScaleInPortraitAndLandscape() throws {
        let profile = try XCTUnwrap(SimulatorDisplayProfile.parse(capabilities: [
            "displays": [["displayType": "integrated", "width": 1170, "height": 2532, "scale": 3.0, "hdpi": 460.0, "vdpi": 460.0]],
        ]))
        let shapes = [profile.displayShape(id: "iphone12")]
        func scale(frame: CGSize) -> Double? {
            let shape = DisplayShape.matching(frame: frame, in: shapes)
            guard let dpi = ZoomMath.devicePixelsPerInch(xDpi: shape?.xDpi, densityDpi: shape?.densityDpi, fallback: nil) else { return nil }
            return ZoomMath.physicalPointsPerPixel(
                macPointsPerInch: 110,
                devicePixelsPerInch: dpi,
                panelLongSide: shape.map { Double(max($0.width, $0.height)) },
                streamLongSide: Double(max(frame.width, frame.height))
            )
        }
        let portrait = try XCTUnwrap(scale(frame: CGSize(width: 1170, height: 2532)))
        let landscape = try XCTUnwrap(scale(frame: CGSize(width: 2532, height: 1170)))
        XCTAssertEqual(portrait, landscape, accuracy: 1e-12)
        XCTAssertEqual(portrait, 110.0 / 460.0, accuracy: 1e-12)
        XCTAssertEqual(2532 * portrait, 2532 / 460.0 * 110, accuracy: 1e-9, "the long edge in points")
        // A stream at half the panel's size covers two panel pixels per pixel, in both poses.
        XCTAssertEqual(scale(frame: CGSize(width: 585, height: 1266)) ?? 0, 2 * portrait, accuracy: 1e-12)
        XCTAssertEqual(scale(frame: CGSize(width: 1266, height: 585)) ?? 0, 2 * portrait, accuracy: 1e-12)
    }

    // MARK: - Presentation

    func testAZoomChangeStartsFromTheOldOverNewRatio() {
        let transition = ZoomMath.transition(from: nil, to: 2.0, currentPresentation: 1, reduceMotion: false)
        XCTAssertEqual(transition, ZoomMath.Transition(presentation: 0.5, animatesToIdentity: true))
    }

    func testASecondStepContinuesFromTheCurrentPresentation() {
        let transition = ZoomMath.transition(from: 2.0, to: 3.0, currentPresentation: 0.5, reduceMotion: false)
        XCTAssertEqual(transition.presentation, CGFloat(2.0 / 3.0) * 0.5, accuracy: 1e-12)
        XCTAssertTrue(transition.animatesToIdentity)
    }

    func testReduceMotionNoChangeAndNonPositiveZoomsSnapToIdentity() {
        let snap = ZoomMath.Transition(presentation: 1, animatesToIdentity: false)
        XCTAssertEqual(ZoomMath.transition(from: nil, to: 2.0, currentPresentation: 0.7, reduceMotion: true), snap)
        XCTAssertEqual(ZoomMath.transition(from: 1.0, to: nil, currentPresentation: 0.7, reduceMotion: false), snap)
        XCTAssertEqual(ZoomMath.transition(from: 2.0, to: 0, currentPresentation: 0.7, reduceMotion: false), snap)
    }

    // MARK: - The window's zoom, driven by the same numbers

    @MainActor
    func testTheWindowStepsAndSelectsLikeDeviceHub() {
        let window = WindowState()
        var drawn = 0.23
        window.videoPointsPerPixel = { drawn }
        window.physicalPointsPerPixel = { 0.20 }

        XCTAssertTrue(window.zoomIsFit)
        window.zoomOut()
        XCTAssertEqual(window.stageZoom ?? 0, 0.75, accuracy: 1e-12)
        XCTAssertFalse(window.zoomIsFit)
        XCTAssertFalse(window.zoomIsPhysicalSize, "a step is neither mode")

        drawn = 0.23 * 0.75
        window.physicalSizeZoom()
        XCTAssertTrue(window.zoomIsPhysicalSize)
        XCTAssertEqual(window.stageZoom ?? 0, 0.75 * 0.20 / drawn, accuracy: 1e-12)

        drawn = 0.20
        window.zoomIn()
        XCTAssertFalse(window.zoomIsPhysicalSize, "stepping leaves the mode")
        window.resetZoom()
        XCTAssertTrue(window.zoomIsFit)
        XCTAssertNil(window.stageZoom)
    }

    @MainActor
    func testPhysicalSizeStaysThroughALayoutChangeAndClosesTheGap() {
        let window = WindowState()
        var drawn = 0.23
        window.videoPointsPerPixel = { drawn }
        window.physicalPointsPerPixel = { 0.20 }

        window.physicalSizeZoom()
        // The layout landed 3% over; the reconcile the stage triggers fixes it.
        drawn = 0.206
        let zoom = window.stageZoom ?? 0
        window.reconcileScaleZoom()
        XCTAssertEqual(window.stageZoom ?? 0, zoom * 0.20 / 0.206, accuracy: 1e-12)
        XCTAssertTrue(window.zoomIsPhysicalSize)

        // Within tolerance: nothing more to do.
        drawn = 0.2001
        let settled = window.stageZoom
        window.reconcileScaleZoom()
        XCTAssertEqual(window.stageZoom, settled)
    }

    @MainActor
    func testTheReconcileGivesUpAfterAFewRoundsUntilTheViewportMoves() {
        let window = WindowState()
        window.videoPointsPerPixel = { 0.3 }   // never converges
        window.physicalPointsPerPixel = { 0.2 }
        window.physicalSizeZoom()
        for _ in 0..<10 { window.reconcileScaleZoom() }
        let stuck = window.stageZoom
        window.reconcileScaleZoom()
        XCTAssertEqual(window.stageZoom, stuck, "six corrections at most per request")
        window.noteViewportChanged()
        window.reconcileScaleZoom()
        XCTAssertNotEqual(window.stageZoom, stuck, "a new viewport starts a new round")
    }

    @MainActor
    func testWithoutADensityThereIsNoPhysicalSize() {
        let window = WindowState()
        window.videoPointsPerPixel = { 0.23 }
        XCTAssertFalse(window.canShowPhysicalSize)
        window.physicalSizeZoom()
        XCTAssertNil(window.stageZoom)
        XCTAssertFalse(window.zoomIsPhysicalSize)
    }

    @MainActor
    func testTheEndsOfTheRangeDisableTheirButton() {
        let window = WindowState()
        window.physicalPointsPerPixel = { 0.2 }
        window.videoPointsPerPixel = { 0.09 }
        XCTAssertTrue(window.isAtMinZoom)
        XCTAssertFalse(window.isAtMaxZoom)
        window.videoPointsPerPixel = { 1.0 }
        XCTAssertTrue(window.isAtMaxZoom)
        XCTAssertFalse(window.isAtMinZoom)
        window.videoPointsPerPixel = { 0.23 }
        XCTAssertFalse(window.isAtMinZoom)
        XCTAssertFalse(window.isAtMaxZoom)
    }

    @MainActor
    func testTheModelMeasuresTheMirrorsStreamAndPanel() {
        let model = AppModel.testing()
        let window = model.workspace.window
        XCTAssertNil(model.workspace.physicalPointsPerPixel(), "no stream yet")
        XCTAssertFalse(window.canShowPhysicalSize)

        model.workspace.mirror.mirrorViewState.devicePixelSize = CGSize(width: 1080, height: 2400)
        model.workspace.mirror.mirrorViewState.publishVideoScale(0.23)
        XCTAssertNil(model.workspace.physicalPointsPerPixel(), "no density read yet")
    }
}
