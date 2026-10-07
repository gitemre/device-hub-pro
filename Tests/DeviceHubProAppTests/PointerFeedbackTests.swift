import SwiftUI
import XCTest
@testable import DeviceHubProApp

/// Device Hub's pointer feedback (parity audit, "Pointer feedback"):
/// which state draws which platter, where segmented separators show, what a
/// pill press counts as inside, and the measured platter geometry.
@MainActor
final class PointerFeedbackTests: XCTestCase {
    // MARK: - Platter fill

    func testHoverAndPressUseTheSystemFillsDeviceHubMeasures() {
        XCTAssertEqual(
            PointerFeedback.fill(isHovered: true, isPressed: false),
            PointerFeedback.hoverFill
        )
        XCTAssertEqual(
            PointerFeedback.fill(isHovered: false, isPressed: true),
            PointerFeedback.pressedFill
        )
        // A press outranks the hover it always comes with.
        XCTAssertEqual(
            PointerFeedback.fill(isHovered: true, isPressed: true),
            PointerFeedback.pressedFill
        )
        XCTAssertNil(PointerFeedback.fill(isHovered: false, isPressed: false))
    }

    func testDisabledControlsShowNoPlatter() {
        XCTAssertNil(PointerFeedback.fill(isHovered: true, isPressed: false, isEnabled: false))
        XCTAssertNil(PointerFeedback.fill(isHovered: true, isPressed: true, isEnabled: false))
    }

    // MARK: - Segmented separators

    private func segments(_ ids: [String], active: Set<String> = []) -> [ToolbarSegment] {
        ids.map { id in
            ToolbarSegment(id: id, isActive: active.contains(id), help: id, action: {}) {
                EmptyView()
            }
        }
    }

    private func visibleSeparators(_ segments: [ToolbarSegment], hovered: String? = nil) -> [Bool] {
        (1..<segments.count).map {
            ToolbarSegmentedCapsule.separatorVisible(before: $0, in: segments, hoveredID: hovered)
        }
    }

    func testAllSeparatorsShowWithNothingSelectedOrHovered() {
        let zoom = segments(["out", "fit", "physical", "in"])
        XCTAssertEqual(visibleSeparators(zoom), [true, true, true])
    }

    func testTheSelectedSegmentHidesBothNeighbouringSeparators() {
        // DH at Physical Size: − │ fit  (1)  + — only the − │ fit line shows.
        let zoom = segments(["out", "fit", "physical", "in"], active: ["physical"])
        XCTAssertEqual(visibleSeparators(zoom), [true, false, false])
    }

    func testHoverHidesSeparatorsLikeSelection() {
        // DH hovering fit while Physical Size is selected: no line at all.
        let zoom = segments(["out", "fit", "physical", "in"], active: ["physical"])
        XCTAssertEqual(visibleSeparators(zoom, hovered: "fit"), [false, false, false])
    }

    func testADisabledCapsuleShowsNoSelection() {
        // DH's zoom capsule with the device stopped: all separators, no
        // platter, although a zoom mode is still recorded.
        let zoom = ["out", "fit", "physical", "in"].map { id in
            ToolbarSegment(id: id, isActive: id == "fit", isDisabled: true, help: id, action: {}) {
                EmptyView()
            }
        }
        XCTAssertEqual(visibleSeparators(zoom), [true, true, true])
        XCTAssertFalse(zoom[1].showsSelection)
    }

    func testInspectorCapsuleWithControlsOpen() {
        // DH with Settings open: [sliders  doc │ i].
        let inspector = segments(["controls", "diagnostics", "info"], active: ["controls"])
        XCTAssertEqual(visibleSeparators(inspector), [false, true])
    }

    // MARK: - Pill press

    func testAPillPressCountsOnlyInsideTheButton() {
        let size = CGSize(width: ParityMetrics.pillButtonWidth, height: ParityMetrics.pillHeight)
        XCTAssertTrue(EmulatorPressButton<EmptyView>.contains(CGPoint(x: 17, y: 18), in: size))
        XCTAssertTrue(EmulatorPressButton<EmptyView>.contains(.zero, in: size))
        // Dragged off the button: the release must not tap.
        XCTAssertFalse(EmulatorPressButton<EmptyView>.contains(CGPoint(x: -1, y: 18), in: size))
        XCTAssertFalse(EmulatorPressButton<EmptyView>.contains(CGPoint(x: 17, y: 40), in: size))
        XCTAssertFalse(EmulatorPressButton<EmptyView>.contains(CGPoint(x: 34, y: 18), in: size))
    }

    // MARK: - Measured geometry (2026-09-25, DH 27.0 at 2x)

    func testPlattersMatchDeviceHubsHoverBoxes() {
        XCTAssertEqual(ParityMetrics.toolbarItemPlatterSize, CGSize(width: 30, height: 28))
        XCTAssertEqual(ParityMetrics.toolbarTogglePlatterSize, CGSize(width: 34, height: 28))
        XCTAssertEqual(ParityMetrics.toolbarSegmentPlatterSize, CGSize(width: 31, height: 28))
        XCTAssertEqual(ParityMetrics.toolbarSidebarTogglePlatterDiameter, 36)
        XCTAssertEqual(ParityMetrics.pillPlatterSize, CGSize(width: 32, height: 28))
        XCTAssertEqual(ParityMetrics.pillCirclePlatterDiameter, 36)
        XCTAssertEqual(ParityMetrics.controlsPopupPlatterHeight, 24)
        XCTAssertEqual(ParityMetrics.controlsPopupPlatterLeadingOutset, 13)
    }

    func testEveryPlatterFitsInsideItsButton() {
        // A platter wider or taller than its hit cell would show where a
        // click does nothing.
        for size in [ParityMetrics.toolbarTogglePlatterSize, ParityMetrics.toolbarSegmentPlatterSize] {
            XCTAssertLessThanOrEqual(size.width, ParityMetrics.toolbarButtonWidth)
            XCTAssertLessThanOrEqual(size.height, ParityMetrics.toolbarButtonHeight)
        }
        XCTAssertLessThanOrEqual(ParityMetrics.pillPlatterSize.width, ParityMetrics.pillButtonWidth)
        XCTAssertLessThanOrEqual(ParityMetrics.pillPlatterSize.height, ParityMetrics.pillHeight)
        // The leading items' 30 pt platter overhangs their 28 pt cells by
        // 1 pt a side, inside the capsule's 6 pt padding and 5 pt gap.
        let overhang = (ParityMetrics.toolbarItemPlatterSize.width - ParityMetrics.toolbarLeadingButtonWidth) / 2
        XCTAssertLessThanOrEqual(overhang * 2, ParityMetrics.toolbarLeadingButtonSpacing)
        XCTAssertLessThanOrEqual(overhang, ParityMetrics.toolbarLeadingCapsulePadding)
    }

    func testTheSidebarHeaderKeepsTheAuditedRhythm() {
        // SB-01/SB-02: the header has a top padding (the hover chevron
        // centres on the text) and the search spacing gives it back. DH
        // (2x, 2026-09-29): the search capsule ends at y=119, the "Available"
        // text starts at 136.5, the list starts at 128 with a 32 pt header
        // row and the first device row at 160.
        XCTAssertEqual(
            ParityMetrics.sidebarSearchBottomSpacing + ParityMetrics.sidebarHeaderBottomSpacing,
            17.5
        )
        XCTAssertEqual(
            ParityMetrics.sidebarSearchTopSpacing + ParityMetrics.sidebarSearchHeight
                + ParityMetrics.sidebarSearchBottomSpacing,
            46,
            "the list starts 46 pt under the toolbar's bottom edge (y=128)"
        )
        let header = 14 + ParityMetrics.sidebarHeaderBottomSpacing * 2 + ParityMetrics.sidebarHeaderExtraBottom
        XCTAssertEqual(header, 32, "DH's Available row is 32 pt tall")
    }
}
