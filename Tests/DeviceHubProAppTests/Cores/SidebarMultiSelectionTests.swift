import XCTest
@testable import DeviceHubProApp

/// The sidebar's multi-selection: ⌘-click, ⇧-click and
/// Select All over the device rows, beside the stage's single primary.
final class SidebarMultiSelectionTests: XCTestCase {
    private let a = DeviceSelection.avd("Pixel_9")
    private let b = DeviceSelection.device("R5CT1234567")
    private let c = DeviceSelection.simulator("95D9676B-3317-4BA5-8CF6-3CDD0488CACA")
    private let d = DeviceSelection.avd("Pixel_Fold")
    private let e = DeviceSelection.simulator("0B8E4B4C-9D8E-4F2A-9C51-2E3F7D1A6B90")
    private let pixel = DeviceSelection.pixel("pixel_9_pro")

    private var order: [DeviceSelection] { [a, b, c, d, e] }

    func testAPlainClickSelectsTheRowAlone() {
        var selection = SidebarMultiSelection()
        selection.selectOnly(b)
        XCTAssertEqual(selection.rows, [b])
        XCTAssertEqual(selection.anchor, b)
        XCTAssertFalse(selection.isMultiple)
        selection.selectOnly(nil)
        XCTAssertEqual(selection.rows, [])
        XCTAssertNil(selection.anchor)
        XCTAssertEqual(selection.count, 0)
    }

    func testCommandClickAddsARowThatBecomesThePrimary() {
        var selection = SidebarMultiSelection()
        // The stage showed `a` before any multi-selection gesture.
        let primary = selection.toggle(b, primary: a)
        XCTAssertEqual(primary, b)
        XCTAssertEqual(selection.rows, [a, b])
        XCTAssertEqual(selection.anchor, b)
        XCTAssertTrue(selection.isMultiple)
        XCTAssertTrue(selection.contains(a))
    }

    func testCommandClickRemovesARowAndKeepsThePrimary() {
        var selection = SidebarMultiSelection()
        selection.selectOnly(a)
        var primary = selection.toggle(b, primary: a)
        primary = selection.toggle(a, primary: primary)
        XCTAssertEqual(primary, b)
        XCTAssertEqual(selection.rows, [b])
        XCTAssertEqual(selection.anchor, b)
    }

    func testRemovingThePrimaryHandsOverToTheRowThatJoinedLast() {
        var selection = SidebarMultiSelection()
        selection.selectOnly(a)
        var primary = selection.toggle(b, primary: a)
        primary = selection.toggle(c, primary: primary)
        XCTAssertEqual(primary, c)
        primary = selection.toggle(c, primary: primary)
        XCTAssertEqual(primary, b)
        XCTAssertEqual(selection.rows, [a, b])
        XCTAssertEqual(selection.anchor, b)
    }

    func testTheLastSelectedRowStays() {
        var selection = SidebarMultiSelection()
        selection.selectOnly(a)
        XCTAssertEqual(selection.toggle(a, primary: a), a)
        XCTAssertEqual(selection.rows, [a])
    }

    func testAPixelRowIsNeverMultiSelected() {
        XCTAssertFalse(SidebarMultiSelection.isMultiSelectable(pixel))
        XCTAssertTrue(SidebarMultiSelection.isMultiSelectable(c))

        var selection = SidebarMultiSelection()
        selection.selectOnly(a)
        _ = selection.toggle(b, primary: a)
        // A modified click on a Pixel row selects it alone, as a plain one.
        XCTAssertEqual(selection.toggle(pixel, primary: b), pixel)
        XCTAssertEqual(selection.rows, [pixel])
        XCTAssertFalse(selection.isMultiple)

        // From a Pixel primary, ⌘-click starts over from the clicked row.
        XCTAssertEqual(selection.toggle(c, primary: pixel), c)
        XCTAssertEqual(selection.rows, [c])
    }

    func testShiftClickSelectsTheRangeFromTheAnchor() {
        var selection = SidebarMultiSelection()
        selection.selectOnly(b)
        XCTAssertEqual(selection.extend(to: d, in: order, adding: false, primary: b), d)
        XCTAssertEqual(selection.rows, [b, c, d])
        XCTAssertEqual(selection.anchor, b)
        // Again from the same anchor, upwards: the range replaces the last.
        XCTAssertEqual(selection.extend(to: a, in: order, adding: false, primary: d), a)
        XCTAssertEqual(selection.rows, [a, b])
        XCTAssertEqual(selection.anchor, b)
    }

    func testCommandShiftClickAddsTheRange() {
        var selection = SidebarMultiSelection()
        selection.selectOnly(a)
        let primary = selection.toggle(e, primary: a)
        XCTAssertEqual(selection.extend(to: c, in: order, adding: true, primary: primary), c)
        XCTAssertEqual(selection.rows, [a, e, c, d])
        XCTAssertEqual(selection.anchor, e)
    }

    func testARangeSkipsPixelRows() {
        var selection = SidebarMultiSelection()
        selection.selectOnly(a)
        _ = selection.extend(to: b, in: [a, pixel, b], adding: false, primary: a)
        XCTAssertEqual(selection.rows, [a, b])
    }

    func testARangeWithoutItsAnchorInViewSelectsTheRowAlone() {
        var selection = SidebarMultiSelection()
        selection.selectOnly(a)
        // `a` is filtered out of the visible rows.
        XCTAssertEqual(selection.extend(to: d, in: [b, c, d], adding: false, primary: a), d)
        XCTAssertEqual(selection.rows, [d])
        XCTAssertEqual(selection.anchor, d)
    }

    func testShiftClickOnAPixelRowSelectsItAlone() {
        var selection = SidebarMultiSelection()
        selection.selectOnly(a)
        XCTAssertEqual(selection.extend(to: pixel, in: [a, pixel], adding: false, primary: a), pixel)
        XCTAssertEqual(selection.rows, [pixel])
    }

    func testSelectAllKeepsAPrimaryItCovers() {
        var selection = SidebarMultiSelection()
        selection.selectOnly(c)
        XCTAssertEqual(selection.selectAll([a, pixel, b, c], primary: c), c)
        XCTAssertEqual(selection.rows, [a, b, c])
        XCTAssertEqual(selection.anchor, c)
    }

    func testSelectAllFromAPixelPrimaryStartsAtTheFirstRow() {
        var selection = SidebarMultiSelection()
        selection.selectOnly(pixel)
        XCTAssertEqual(selection.selectAll([a, pixel, b], primary: pixel), a)
        XCTAssertEqual(selection.rows, [a, b])
        XCTAssertEqual(selection.anchor, a)
    }

    func testSelectAllWithNoDeviceRowsChangesNothing() {
        var selection = SidebarMultiSelection()
        selection.selectOnly(pixel)
        XCTAssertEqual(selection.selectAll([pixel], primary: pixel), pixel)
        XCTAssertEqual(selection.rows, [pixel])
    }

    func testThePrimaryMovingInsideTheSelectionKeepsIt() {
        var selection = SidebarMultiSelection()
        selection.selectOnly(a)
        _ = selection.toggle(b, primary: a)
        selection.follow(primary: a)
        XCTAssertEqual(selection.rows, [a, b])
    }

    func testThePrimaryMovingOutsideTheSelectionReplacesIt() {
        var selection = SidebarMultiSelection()
        selection.selectOnly(a)
        _ = selection.toggle(b, primary: a)
        selection.follow(primary: d)
        XCTAssertEqual(selection.rows, [d])
        XCTAssertEqual(selection.anchor, d)
        selection.follow(primary: nil)
        XCTAssertEqual(selection.rows, [])
    }

    func testAGestureBuildsOnThePrimaryWhenTheSelectionIsOutOfStep() {
        var selection = SidebarMultiSelection()
        selection.selectOnly(a)
        _ = selection.toggle(b, primary: a)
        // The stage moved to `d` without the selection following.
        XCTAssertEqual(selection.toggle(e, primary: d), e)
        XCTAssertEqual(selection.rows, [d, e])
    }

    func testRowsNoLongerListedAreDroppedButThePrimaryStays() {
        var selection = SidebarMultiSelection()
        selection.selectOnly(a)
        var primary = selection.toggle(b, primary: a)
        primary = selection.toggle(c, primary: primary)
        // `b` was unplugged; `c`, the primary, is gone from the list too.
        selection.prune(keeping: [a], primary: primary)
        XCTAssertEqual(selection.rows, [a, c])
        XCTAssertEqual(selection.anchor, c)

        selection.prune(keeping: [a], primary: a)
        XCTAssertEqual(selection.rows, [a])
        XCTAssertEqual(selection.anchor, a)
    }
}
