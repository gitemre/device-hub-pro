import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// A failed `ps` read must not turn every AVD card to stopped.
@MainActor
final class AvdGalleryRefreshTests: XCTestCase {
    func testACancelledRunningEmulatorReadKeepsTheCardsRunningState() async {
        let controller = AvdCatalogController(status: StatusCenter(), displayShapes: DisplayShapeLibrary(store: nil))
        controller.emulatorManagerProvider = {
            EmulatorManager(emulatorURL: URL(fileURLWithPath: "/nonexistent/emulator"), processScope: .everyVM)
        }
        controller.avds = ["aqa_test_gallery"]
        controller.avdCards = [AvdCard(
            name: "aqa_test_gallery", displayName: "aqa_test_gallery", target: nil, skin: nil,
            isRunning: true, serial: "emulator-5554"
        )]
        // A task that is cancelled before it reads `ps` makes the read throw.
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await controller.refreshGallery()
        }
        await task.value
        XCTAssertEqual(controller.avdCards.first?.isRunning, true)
        XCTAssertEqual(controller.avdCards.first?.serial, "emulator-5554")
    }

    /// A cancelled check (the create sheet closed) is neither "no Java" nor a
    /// failed load, and never leaves the status spinning.
    func testACancelledCreateOptionsCheckLeavesNoSpinnerAndNoFalseVerdict() async {
        let controller = AvdCatalogController(status: StatusCenter(), displayShapes: DisplayShapeLibrary(store: nil))
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await controller.refreshAvdCreateOptions()
        }
        await task.value
        XCTAssertNotEqual(controller.avdCreateStatus, .checking)
        XCTAssertNotEqual(controller.avdCreateStatus, .missingJava)
        if case .loadFailed = controller.avdCreateStatus { XCTFail("cancellation became a load failure") }
    }
}
