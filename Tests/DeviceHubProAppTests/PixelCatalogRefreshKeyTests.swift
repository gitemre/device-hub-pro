import XCTest
import DeviceHubProKit
@testable import DeviceHubProApp

/// The Pixel catalog refresh is keyed on `AppModel.pixelCatalogInputs`: it
/// must change exactly when the list `PixelCatalogModel.refresh(from:)`
/// builds could change.
@MainActor
final class PixelCatalogRefreshKeyTests: XCTestCase {
    private func entry(_ name: String) -> SkinCatalogEntry {
        SkinCatalogEntry(
            name: name,
            displayName: name,
            category: .phone,
            directory: URL(fileURLWithPath: "/tmp"),
            variants: []
        )
    }

    func testTheSkinCatalogLandingRefreshesWithZeroAvds() {
        // The old refresh was keyed on the AVD and profile counts: with no
        // AVDs neither changed when the skins arrived, so a new user never
        // saw the Pixel Devices section.
        let app = AppModel.testing()
        let empty = app.catalog.pixelCatalogInputs
        app.catalog.skinCatalog = [entry("pixel_9_pro")]
        XCTAssertNotEqual(app.catalog.pixelCatalogInputs, empty)
    }

    func testARenameRefreshesAlthoughTheCountIsUnchanged() {
        let app = AppModel.testing()
        app.catalog.avds = ["Pixel_9_Pro_API_35"]
        let before = app.catalog.pixelCatalogInputs
        app.catalog.avds = ["My_Pixel"]
        XCTAssertNotEqual(app.catalog.pixelCatalogInputs, before)
    }

    func testLoadedProfilesRefresh() {
        let app = AppModel.testing()
        let before = app.catalog.pixelCatalogInputs
        app.catalog.avdDevices = [AvdDevice(id: "pixel_9_pro", name: "Pixel 9 Pro")]
        XCTAssertNotEqual(app.catalog.pixelCatalogInputs, before)
    }

    func testUnrelatedStateDoesNotRefresh() {
        let app = AppModel.testing()
        app.catalog.skinCatalog = [entry("pixel_9_pro")]
        let before = app.catalog.pixelCatalogInputs
        app.deviceSelection = .pixel("pixel_9_pro")
        app.status.showOutcome("Replay saved")
        XCTAssertEqual(app.catalog.pixelCatalogInputs, before)
    }
}
