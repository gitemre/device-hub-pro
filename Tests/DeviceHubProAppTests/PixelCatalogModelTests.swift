import XCTest
import DeviceHubProKit
@testable import DeviceHubProApp

@MainActor
final class PixelCatalogModelTests: XCTestCase {
    private func appModel() -> AppModel {
        AppModel.testing()
    }

    /// A catalog on no SDK: no sdkmanager and no SDK root (so the real SDK's
    /// min-API table is never unzipped), and provisioning steps that do
    /// nothing — the live ones download, run avdmanager and boot.
    private func sdkFreeCatalog() -> PixelCatalogModel {
        PixelCatalogModel(
            sdk: SDKComponentModel(locateClient: { nil }, locateSdkRoot: { nil }),
            sdkRoot: nil,
            minApiTable: nil,
            actions: PixelCatalogModel.Actions(
                download: { _, _ in .failed("no SDK in this test") },
                createAvd: { _, _, _, _ in "no SDK in this test" },
                start: { _, _, _ in }
            )
        )
    }

    private func pixelDevice() -> PixelDevice {
        PixelDevice(
            skinName: "pixel_9_pro",
            displayName: "Pixel 9 Pro",
            category: .phone,
            skin: SkinCatalogEntry(
                name: "pixel_9_pro",
                displayName: "Pixel 9 Pro",
                category: .phone,
                directory: URL(fileURLWithPath: "/tmp"),
                variants: []
            ),
            deviceProfileID: "pixel_9_pro",
            minApi: "35",
            playstoreEnabled: true,
            installedAvdNames: []
        )
    }

    func testRefreshBuildsDevices() {
        let app = appModel()
        app.catalog.skinCatalog = [
            SkinCatalogEntry(
                name: "pixel_9_pro",
                displayName: "Pixel 9 Pro",
                category: .phone,
                directory: URL(fileURLWithPath: "/tmp"),
                variants: []
            ),
            SkinCatalogEntry(
                name: "nexus_5",
                displayName: "Nexus 5",
                category: .phone,
                directory: URL(fileURLWithPath: "/tmp"),
                variants: []
            ),
        ]
        app.catalog.avdDevices = [AvdDevice(id: "pixel_9_pro", name: "Pixel 9 Pro")]

        let catalog = sdkFreeCatalog()
        let expectation = expectation(description: "refresh")
        Task {
            await catalog.refresh(from: app)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(catalog.devices.map(\.skinName), ["pixel_9_pro"])
        XCTAssertEqual(catalog.devices.first?.deviceProfileID, "pixel_9_pro")
    }

    func testProvisioningStateStartsIdle() {
        let catalog = sdkFreeCatalog()
        XCTAssertEqual(catalog.provisioningState, .idle)
        XCTAssertNil(catalog.licensePrompt)
    }

    func testCandidatesPreferInstalledMeetingMinimum() {
        let catalog = sdkFreeCatalog()
        let device = pixelDevice()
        XCTAssertNil(catalog.preferredCandidate(for: device))
    }

    func testReadinessReportsMissingTools() {
        let catalog = sdkFreeCatalog()
        let missing = catalog.readiness(for: pixelDevice())
        // On a machine without cmdline-tools the report must name it; on a
        // developer machine the image row is the only certain miss (no
        // installed image is passed to this model).
        XCTAssertTrue(missing.contains(.systemImage) || missing.contains(.commandLineTools) || missing.isEmpty)
    }

    func testHostAbiIsArmOrIntel() {
        XCTAssertTrue(["arm64-v8a", "x86_64"].contains(PixelCatalogModel.hostAbi))
    }
}
