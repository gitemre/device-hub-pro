import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// The model's multi-selection: the sidebar's gestures, the primary it
/// follows, the rows it drops, and the targets Apply to Selected resolves.
@MainActor
final class MultiSelectionModelTests: XCTestCase {
    private func card(_ name: String, running: Bool = false, serial: String? = nil) -> AvdCard {
        AvdCard(name: name, displayName: name, target: "android-36", skin: nil, isRunning: running, serial: serial)
    }

    func testCommandClickGathersRowsAndAPlainClickEndsIt() {
        let model = AppModel.testing()
        model.deviceSelection = .avd("Pixel_9")
        model.toggleRow(.device("R58M123"))
        XCTAssertEqual(model.multiSelection.rows, [.avd("Pixel_9"), .device("R58M123")])
        XCTAssertEqual(model.deviceSelection, .device("R58M123"))
        XCTAssertTrue(model.canActOnSelected())

        // The stage moving to another selected row keeps the selection.
        model.deviceSelection = .avd("Pixel_9")
        XCTAssertEqual(model.multiSelection.count, 2)

        model.selectOnlyRow(.avd("Pixel_9"))
        XCTAssertEqual(model.multiSelection.rows, [.avd("Pixel_9")])
        XCTAssertFalse(model.canActOnSelected())
    }

    func testAPrimaryOutsideTheSelectionReplacesIt() {
        let model = AppModel.testing()
        model.deviceSelection = .avd("Pixel_9")
        model.toggleRow(.avd("Pixel_8"))
        // A start, an arrow or a stale selection's replacement.
        model.deviceSelection = .simulator("95D9676B-3317-4BA5-8CF6-3CDD0488CACA")
        XCTAssertEqual(model.multiSelection.rows, [.simulator("95D9676B-3317-4BA5-8CF6-3CDD0488CACA")])
    }

    func testSelectAllAndShiftClickTakeTheVisibleDeviceRows() {
        let model = AppModel.testing()
        let order: [DeviceSelection] = [.avd("A"), .avd("B"), .pixel("pixel_9"), .avd("C")]
        model.deviceSelection = .avd("B")
        model.selectAllRows(order)
        XCTAssertEqual(model.multiSelection.rows, [.avd("A"), .avd("B"), .avd("C")])
        XCTAssertEqual(model.deviceSelection, .avd("B"))

        model.selectOnlyRow(.avd("A"))
        model.extendRows(to: .avd("C"), in: order, adding: false)
        XCTAssertEqual(model.multiSelection.rows, [.avd("A"), .avd("B"), .avd("C")])
        XCTAssertEqual(model.deviceSelection, .avd("C"))
    }

    func testRowsNoLongerListedLeaveTheSelection() {
        let model = AppModel.testing()
        model.catalog.avds = ["A", "B"]
        model.catalog.avdCards = [card("A"), card("B")]
        model.deviceSelection = .avd("A")
        model.toggleRow(.avd("B"))
        model.toggleRow(.device("R58M123"))
        // The phone (the primary row) is gone: the stage says "No
        // Selection", as Device Hub's does, and the phone's row leaves the
        // selection with the rows that were gathered around it.
        model.ensureDeviceSelection()
        XCTAssertNil(model.deviceSelection)
        XCTAssertFalse(model.multiSelection.rows.contains(.device("R58M123")))
        XCTAssertTrue(model.workspace.window.selectionWasLost)
    }

    func testTheSelectedRowsResolveToTargets() {
        let model = AppModel.testing()
        model.inventory.devices = [AndroidDevice(serial: "emulator-5554", state: "device")]
        model.catalog.avdCards = [card("Pixel_9", running: true, serial: "emulator-5554"), card("Pixel_8")]
        model.deviceSelection = .avd("Pixel_9")
        model.toggleRow(.avd("Pixel_8"))
        model.toggleRow(.avd("Removed"))
        XCTAssertEqual(model.batchTargets().map(\.id), ["avd:Pixel_9", "avd:Pixel_8", "avd:Removed"])
        XCTAssertEqual(model.batchTargets().map(\.readiness), [.ready, .stopped, .notListed])
        XCTAssertEqual(model.batchTargets().first?.ref, .android("emulator-5554"))
    }
}
