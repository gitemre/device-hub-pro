import XCTest
import DeviceHubProKit
@testable import DeviceHubProApp

@MainActor
final class PixelSelectionTests: XCTestCase {
    private func model() -> AppModel {
        AppModel.testing()
    }

    func testPixelSelectionRoutesToInstalledAvdSerial() {
        let app = model()
        app.catalog.avdCards = [
            AvdCard(
                name: "Pixel_9_Pro",
                displayName: "Pixel 9 Pro",
                target: "android-35",
                skin: ResolvedSkin(
                    name: "pixel_9_pro",
                    directory: URL(fileURLWithPath: "/tmp"),
                    source: .skinName,
                    variants: []
                ),
                isRunning: true,
                serial: "emulator-5554"
            )
        ]
        app.inventory.devices = [
            AndroidDevice(serial: "emulator-5554", state: "device")
        ]
        app.deviceSelection = .pixel("pixel_9_pro")
        XCTAssertEqual(app.liveSelectionSerial, "emulator-5554")
        XCTAssertEqual(app.inspectorSerial, "emulator-5554")
    }

    func testPixelSelectionWithoutAvdIsValid() {
        let app = model()
        app.catalog.skinCatalog = [
            SkinCatalogEntry(
                name: "pixel_9_pro",
                displayName: "Pixel 9 Pro",
                category: .phone,
                directory: URL(fileURLWithPath: "/tmp"),
                variants: []
            )
        ]
        app.deviceSelection = .pixel("pixel_9_pro")
        app.catalog.avdCards = []
        app.inventory.devices = []
        XCTAssertNil(app.liveSelectionSerial)
        XCTAssertNil(app.inspectorSerial)
    }

    func testPixelSelectionSurvivesRefresh() {
        let app = model()
        app.catalog.skinCatalog = [
            SkinCatalogEntry(
                name: "pixel_9_pro",
                displayName: "Pixel 9 Pro",
                category: .phone,
                directory: URL(fileURLWithPath: "/tmp"),
                variants: []
            )
        ]
        app.catalog.avdCards = []
        app.inventory.devices = []
        app.deviceSelection = .pixel("pixel_9_pro")
        app.ensureDeviceSelection()
        XCTAssertEqual(app.deviceSelection, .pixel("pixel_9_pro"))
    }

    func testStalePixelSelectionIsReplaced() {
        let app = model()
        app.catalog.skinCatalog = []
        app.catalog.avdCards = []
        app.inventory.devices = []
        app.deviceSelection = .pixel("pixel_9_pro")
        app.ensureDeviceSelection()
        XCTAssertNil(app.deviceSelection)
    }

    func testPixelHelpersFindCardsBySkin() {
        let skin = ResolvedSkin(
            name: "pixel_9_pro",
            directory: URL(fileURLWithPath: "/tmp"),
            source: .skinName,
            variants: []
        )
        let app = model()
        app.catalog.avdCards = [
            AvdCard(
                name: "Pixel_9_Pro",
                displayName: "Pixel 9 Pro",
                target: "android-35",
                skin: skin,
                isRunning: false,
                serial: nil
            )
        ]
        app.deviceSelection = .pixel("pixel_9_pro")
        XCTAssertEqual(app.selectedPixelSkinName(in: app.workspace), "pixel_9_pro")
        XCTAssertEqual(app.catalog.avdCards(forPixelSkin: "pixel_9_pro").count, 1)
        XCTAssertEqual(app.selectedPixelCard(in: app.workspace)?.name, "Pixel_9_Pro")
    }
}
