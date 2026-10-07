import XCTest
import SwiftUI
import DeviceHubProKit
@testable import DeviceHubProApp

// `@MainActor`: `FoldControlDriving` is a main-actor protocol because
// `AppModel` is main-actor isolated, so the strip actions and the tests that
// drive them run on the main actor.
private final class MockDriver: FoldControlDriving {
    var hingeAngle: Double? = 180
    var presets: [PostureKind] = []
    var sliders: [Double] = []
    func setPostureAnimated(_ posture: PostureKind) { presets.append(posture) }
    // The mock mirrors `AppModel.setHingeAngle`: the reported angle lands
    // immediately, so the slider thumb reads back the clamped value.
    func setHingeAngle(_ degrees: Double) {
        sliders.append(degrees)
        hingeAngle = degrees
    }
}

@MainActor
final class FoldControlStripTests: XCTestCase {
    func testPresetCallsDriver() {
        let driver = MockDriver()
        FoldStripActions.presetTapped(.halfOpened, driver: driver)
        FoldStripActions.presetTapped(.closed, driver: driver)
        XCTAssertEqual(driver.presets, [.halfOpened, .closed])
    }

    func testSliderClamps() {
        let driver = MockDriver()
        FoldStripActions.sliderChanged(-20, driver: driver)
        FoldStripActions.sliderChanged(220, driver: driver)
        FoldStripActions.sliderChanged(90, driver: driver)
        XCTAssertEqual(driver.sliders, [0, 180, 90])
    }

    func testSliderIgnoresNonFiniteInput() {
        // NaN currently reached the gRPC sender; it must stop at the action.
        let driver = MockDriver()
        FoldStripActions.sliderChanged(.nan, driver: driver)
        FoldStripActions.sliderChanged(.infinity, driver: driver)
        FoldStripActions.sliderChanged(-.infinity, driver: driver)
        XCTAssertEqual(driver.sliders, [])
        XCTAssertEqual(driver.hingeAngle, 180)
    }

    func testSliderThumbFollowsDriverAngle() {
        // Clamp-through: presets/polls and the clamped drag move the thumb,
        // because the binding's getter reads the driver's live angle.
        let driver = MockDriver()
        driver.hingeAngle = 45
        XCTAssertEqual(FoldStripActions.thumbAngle(driver: driver, local: 180), 45)
        FoldStripActions.sliderChanged(220, driver: driver)
        XCTAssertEqual(FoldStripActions.thumbAngle(driver: driver, local: 0), 180)
        driver.hingeAngle = nil
        XCTAssertEqual(FoldStripActions.thumbAngle(driver: driver, local: 70), 70)
    }

    // MARK: - Stage layout

    /// The stage starts from `estimatedHeight` before the strip reports its
    /// own, so it has to be the strip's real height, with the live slider
    /// and without.
    func testEstimatedHeightIsTheStripsLaidOutHeight() {
        for showsSlider in [true, false] {
            let strip = NSHostingView(rootView: FoldControlStrip(driver: MockDriver(), showsSlider: showsSlider))
            XCTAssertEqual(strip.fittingSize.height, FoldControlStrip.estimatedHeight, "slider \(showsSlider)")
        }
    }

    /// Started from the kept height, the device is laid out once, at the
    /// top of the stage and down to the strip: a fit↔zoom switch rebuilds
    /// the stage, and a second, re-fitted layout would resize the drawable
    /// mid-animation. The strip sits 8 pt above the stage's bottom edge.
    func testTheDeviceIsLaidOutOnceAboveTheStrip() throws {
        let log = StageLog(stripHeight: FoldControlStrip.estimatedHeight)
        Self.host(StageHost(stage: CGSize(width: 1300, height: 866), showsStrip: true, log: log))

        let height = FoldControlStrip.estimatedHeight
        XCTAssertEqual(log.device, [CGRect(x: 0, y: 0, width: 1300, height: 866 - height - 8)])
        let strip = try XCTUnwrap(log.strip.last)
        XCTAssertEqual(strip.height, height)
        XCTAssertEqual(strip.maxY, 866 - FoldControlStrip.stageBottomPadding)
        XCTAssertEqual(try XCTUnwrap(log.device.last).maxY, strip.minY, "the device ends where the strip starts")
        XCTAssertEqual(log.stripHeight, height)
    }

    /// The strip reports its own height to the stage, which re-fits the
    /// device above it (here from a start that knows nothing of the strip).
    func testTheStripReportsItsHeightToTheStage() throws {
        let log = StageLog(stripHeight: 0)
        Self.host(StageHost(stage: CGSize(width: 1300, height: 866), showsStrip: true, log: log))

        let strip = try XCTUnwrap(log.strip.last)
        XCTAssertEqual(log.stripHeight, strip.height)
        XCTAssertEqual(try XCTUnwrap(log.device.last).maxY, strip.minY, "the device ends where the strip starts")
    }

    /// Without the strip the device gets the whole stage; a stage shorter
    /// than the strip still gives it a height.
    func testTheDeviceFillsTheStageWithoutTheStrip() throws {
        let log = StageLog(stripHeight: FoldControlStrip.estimatedHeight)
        Self.host(StageHost(stage: CGSize(width: 1300, height: 866), showsStrip: false, log: log))
        XCTAssertEqual(log.device, [CGRect(x: 0, y: 0, width: 1300, height: 866)])
        XCTAssertEqual(log.strip, [])

        let short = StageLog(stripHeight: FoldControlStrip.estimatedHeight)
        Self.host(StageHost(stage: CGSize(width: 300, height: 20), showsStrip: true, log: short))
        XCTAssertEqual(try XCTUnwrap(short.device.last).size, CGSize(width: 300, height: 1))
    }

    /// Lays `root` out once in a hosting view of its own size (layout runs
    /// the geometry callbacks and the updates they cause).
    private static func host(_ root: StageHost) {
        let view = NSHostingView(rootView: root)
        view.frame = CGRect(origin: .zero, size: root.stage)
        view.layoutSubtreeIfNeeded()
    }
}

/// Where `StageHost`'s stand-ins laid out, in the stage's coordinates, and
/// the strip height the stage keeps.
@MainActor
@Observable
private final class StageLog {
    var stripHeight: CGFloat
    @ObservationIgnored var device: [CGRect] = []
    @ObservationIgnored var strip: [CGRect] = []

    init(stripHeight: CGFloat) {
        self.stripHeight = stripHeight
    }
}

/// `FoldStripStage` with a plain stand-in for the framed device and the real
/// strip, each recording its frame in the stage whenever it changes.
private struct StageHost: View {
    let stage: CGSize
    let showsStrip: Bool
    let log: StageLog

    var body: some View {
        FoldStripStage(
            available: stage,
            stripHeight: showsStrip
                ? Binding(get: { log.stripHeight }, set: { log.stripHeight = $0 })
                : nil
        ) { fitted in
            Color.clear
                .frame(width: fitted.width, height: fitted.height)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("stage")) } action: {
                    log.device.append($0)
                }
        } strip: {
            FoldControlStrip(driver: MockDriver(), showsSlider: true)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("stage")) } action: {
                    log.strip.append($0)
                }
        }
        .coordinateSpace(.named("stage"))
    }
}

/// A narrow stage column (Log focus) compacts the strip instead of clipping it.
final class FoldControlStripCompactionTests: XCTestCase {
    func testCompactionsGetNarrowerInOrder() {
        let all = FoldControlStrip.Compaction.allCases
        XCTAssertEqual(all, [.full, .icons, .presetsOnly])
        XCTAssertTrue(all.first!.showsLabels)
        XCTAssertFalse(FoldControlStrip.Compaction.icons.showsLabels)
        let widths = all.map { $0.sliderWidth ?? 0 }
        XCTAssertEqual(widths, widths.sorted(by: >))
        XCTAssertNil(FoldControlStrip.Compaction.presetsOnly.sliderWidth)
    }
}
