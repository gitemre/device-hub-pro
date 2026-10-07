import XCTest
@testable import DeviceHubProApp

/// The Apps-tab selection contract: a selected package that leaves the
/// visible list — uninstalled, or filtered out by a scope change — must not
/// stay selected, or the footer `−` could uninstall a row the tester cannot
/// see.
@MainActor
final class AppsSelectionTests: XCTestCase {
    func testKeepsASelectionThatIsStillVisible() {
        XCTAssertEqual(
            AppsController.prunedSelection(
                "com.example.app",
                visiblePackageIDs: ["com.example.app", "com.other.app"]
            ),
            "com.example.app"
        )
    }

    func testDropsASelectionThatLeftTheVisibleList() {
        XCTAssertNil(
            AppsController.prunedSelection("com.example.app", visiblePackageIDs: ["com.other.app"])
        )
    }

    func testDropsASelectionWhenNothingIsVisible() {
        XCTAssertNil(AppsController.prunedSelection("com.example.app", visiblePackageIDs: []))
    }

    func testNilSelectionStaysNil() {
        XCTAssertNil(AppsController.prunedSelection(nil, visiblePackageIDs: ["com.example.app"]))
    }
}
