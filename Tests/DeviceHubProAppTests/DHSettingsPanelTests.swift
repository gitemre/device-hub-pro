import XCTest
@testable import DeviceHubProApp

final class DHSettingsPanelTests: XCTestCase {
    func testSliderIndexIsTheNearestPosition() {
        let steps = [0.85, 1.0, 1.15, 1.3]

        XCTAssertEqual(nearestSliderIndex(positions: steps, to: 0.85), 0)
        XCTAssertEqual(nearestSliderIndex(positions: steps, to: 1.3), 3)
        XCTAssertEqual(nearestSliderIndex(positions: steps, to: 1.13), 2)
        XCTAssertEqual(nearestSliderIndex(positions: steps, to: 0.9), 0)
    }

    func testSliderTieTakesTheSmallerPosition() {
        // 1.075 is exactly between 1.0 and 1.15; FontScaleStep.nearest keeps
        // the smaller step, and the slider follows it so a device value is
        // never rounded up.
        XCTAssertEqual(nearestSliderIndex(positions: [0.85, 1.0, 1.15, 1.3], to: 1.075), 1)
    }

    func testSliderWithNoPositionsHasNoIndex() {
        XCTAssertNil(nearestSliderIndex(positions: [], to: 0.4))
    }

    func testSliderWithOnePositionIsIndexZero() {
        XCTAssertEqual(nearestSliderIndex(positions: [7], to: 0.9), 0)
    }

    func testSliderClampsAValueOutsideTheRange() {
        let steps = [0.0, 1.0]
        XCTAssertEqual(nearestSliderIndex(positions: steps, to: -0.5), 0)
        XCTAssertEqual(nearestSliderIndex(positions: steps, to: 1.5), 1)
    }

    func testSoundSliderHasDHsNineDecorationDots() {
        XCTAssertEqual(ParityMetrics.controlsSoundTickCount, 9)
        XCTAssertEqual(ParityMetrics.controlsSliderWidth, 120)
        XCTAssertEqual(ParityMetrics.controlsSwitchWidth, 36)
        XCTAssertEqual(ParityMetrics.controlsSwitchHeight, 16)
    }

    // MARK: - Switch appearance

    func testAnUnknownReadingIsNotDrawnAsOff() {
        let unknown = DHSwitchAppearance(isOn: nil, isEnabled: false)
        let off = DHSwitchAppearance(isOn: false, isEnabled: true)
        XCTAssertEqual(unknown.knob, .center)
        XCTAssertEqual(off.knob, .leading)
        XCTAssertNotEqual(unknown, off)
        XCTAssertEqual(unknown.accessibilityValue, "unknown")
    }

    func testOnFillsTheTrack() {
        let on = DHSwitchAppearance(isOn: true, isEnabled: true)
        XCTAssertEqual(on.knob, .trailing)
        XCTAssertTrue(on.isFilled)
        XCTAssertEqual(on.accessibilityValue, "on")
    }

    func testADisabledSwitchIsDimmed() {
        XCTAssertEqual(DHSwitchAppearance(isOn: false, isEnabled: true).opacity, 1)
        XCTAssertEqual(
            DHSwitchAppearance(isOn: false, isEnabled: false).opacity,
            ParityMetrics.controlsDisabledOpacity
        )
        XCTAssertLessThan(ParityMetrics.controlsDisabledOpacity, 1)
    }

    func testTheSharedLabelGapIsTheAuditedRemainder() {
        // Four rows used to recompute it privately; the label box starts at
        // 37.5 pt and the glyph frame ends at 12 + 16 pt.
        XCTAssertEqual(ParityMetrics.controlsLabelGap, 9.5)
    }
}
