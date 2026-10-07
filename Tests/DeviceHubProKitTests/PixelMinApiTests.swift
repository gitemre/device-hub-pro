import XCTest
@testable import DeviceHubProKit

final class PixelMinApiTests: XCTestCase {
    /// Trimmed from the real cmdline-tools `com/android/sdklib/devices/nexus.xml`.
    static let fixture = """
    <?xml version="1.0" encoding="UTF-8"?>
    <d:devices xmlns:d="http://schemas.android.com/sdk/devices/9">
        <d:device>
            <d:name>Pixel 9 Pro</d:name>
            <d:id>pixel_9_pro</d:id>
            <d:manufacturer>Google</d:manufacturer>
            <d:playstore-enabled>true</d:playstore-enabled>
            <d:software>
                <d:api-level>35-</d:api-level>
            </d:software>
        </d:device>
        <d:device>
            <d:name>Pixel 10 Pro</d:name>
            <d:id>pixel_10_pro</d:id>
            <d:manufacturer>Google</d:manufacturer>
            <d:playstore-enabled>true</d:playstore-enabled>
            <d:software>
                <d:api-level>36.1-</d:api-level>
            </d:software>
        </d:device>
        <d:device>
            <d:name>Pixel 5</d:name>
            <d:id>pixel_5</d:id>
            <d:manufacturer>Google</d:manufacturer>
            <d:playstore-enabled>false</d:playstore-enabled>
            <d:software>
                <d:api-level>30-</d:api-level>
            </d:software>
        </d:device>
    </d:devices>
    """

    func testParse() {
        let table = PixelMinApiTable.parse(nexusXML: Self.fixture)
        XCTAssertEqual(
            table.entries["pixel_9_pro"],
            .init(minApi: "35", playstoreEnabled: true)
        )
        XCTAssertEqual(
            table.entries["pixel_10_pro"],
            .init(minApi: "36.1", playstoreEnabled: true)
        )
        XCTAssertEqual(
            table.entries["pixel_5"],
            .init(minApi: "30", playstoreEnabled: false)
        )
        XCTAssertNil(table.entries["pixel_6"])
    }

    func testApiComparison() {
        XCTAssertEqual(PixelMinApiTable.compare("36.1", "36"), .orderedDescending)
        XCTAssertEqual(PixelMinApiTable.compare("35", "35"), .orderedSame)
        XCTAssertEqual(PixelMinApiTable.compare("34", "35"), .orderedAscending)
        XCTAssertEqual(PixelMinApiTable.compare("37.1", "36.1"), .orderedDescending)
        XCTAssertEqual(PixelMinApiTable.compare("android-35", "35"), .orderedSame)
        XCTAssertEqual(PixelMinApiTable.compare("android-37.1", "37"), .orderedDescending)
    }

    func testMissingTableLoadsNil() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-sdk-\(UUID().uuidString)", isDirectory: true)
        let table = await PixelMinApiTable.load(sdkRoot: root)
        XCTAssertNil(table)
    }

    func testApplyingMinApi() {
        let entry = PixelCatalogTests.entry(name: "pixel_9_pro")
        let table = PixelMinApiTable.parse(nexusXML: Self.fixture)
        let pixel = PixelDevice(
            skinName: entry.name,
            displayName: entry.displayName,
            category: entry.category,
            skin: entry,
            deviceProfileID: "pixel_9_pro",
            minApi: nil,
            playstoreEnabled: false,
            installedAvdNames: []
        )
        let applied = PixelCatalog.applying(table, to: pixel)
        XCTAssertEqual(applied.minApi, "35")
        XCTAssertTrue(applied.playstoreEnabled)
    }

    /// Guards the jar reader against the real SDK when cmdline-tools is
    /// installed; skipped on machines without it.
    func testRealSdkMinApiTable() async throws {
        guard let root = AvdmanagerClient.sdkRoot() else {
            throw XCTSkip("no Android SDK root")
        }
        guard let table = await PixelMinApiTable.load(sdkRoot: root) else {
            throw XCTSkip("no cmdline-tools nexus.xml")
        }
        XCTAssertEqual(table.entries["pixel_2"]?.minApi, "27")
        XCTAssertEqual(table.entries["pixel_5"]?.playstoreEnabled, false)
        // Newer definitions ship only with newer cmdline-tools.
        guard table.entries["pixel_9_pro"] != nil, table.entries["pixel_10_pro"] != nil else {
            throw XCTSkip("this cmdline-tools release predates the Pixel 9 Pro / 10 Pro definitions")
        }
        XCTAssertEqual(table.entries["pixel_9_pro"]?.minApi, "35")
        XCTAssertEqual(table.entries["pixel_10_pro"]?.minApi, "36.1")
        XCTAssertEqual(table.entries["pixel_9_pro"]?.playstoreEnabled, true)
    }
}
