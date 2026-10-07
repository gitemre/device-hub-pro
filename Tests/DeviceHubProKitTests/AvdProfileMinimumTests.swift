import XCTest
@testable import DeviceHubProKit

/// The create sheet's use of a profile's minimum API: the same table and
/// comparison as the Pixel catalog. The table values come from the real
/// `sdklib-devices-nexus.xml` fixture; image lists are built from package ids.
final class AvdProfileMinimumTests: XCTestCase {
    private func table() throws -> PixelMinApiTable {
        PixelMinApiTable.parse(nexusXML: try LogcatSdkApkFixtures.text("sdklib-devices-nexus.xml"))
    }

    private static func image(_ package: String) -> SystemImage {
        let parts = package.split(separator: ";").map(String.init)
        return SystemImage(package: package, api: parts[1], tag: parts[2], abi: parts[3])
    }

    private let abi = "arm64-v8a"

    func testMinimumsComeFromTheRealTable() throws {
        let table = try table()
        XCTAssertEqual(AvdProfileMinimum.minApi(profileID: "pixel_10_pro", table: table), "36.1")
        XCTAssertEqual(AvdProfileMinimum.minApi(profileID: "pixel_10_pro_fold", table: table), "36.1")
        XCTAssertEqual(AvdProfileMinimum.minApi(profileID: "pixel_9_pro_fold", table: table), "35")
        XCTAssertEqual(AvdProfileMinimum.minApi(profileID: "pixel_fold", table: table), "34")
    }

    func testNoTableNoEntryOrBareDashMeansNoMinimum() {
        XCTAssertNil(AvdProfileMinimum.minApi(profileID: "pixel_10_pro", table: nil))
        XCTAssertNil(AvdProfileMinimum.minApi(profileID: nil, table: PixelMinApiTable(entries: [:])))
        XCTAssertNil(AvdProfileMinimum.minApi(profileID: "nope", table: PixelMinApiTable(entries: [:])))
        // SOURCE-DERIVED: wear.xml / devices.xml write "-" for no minimum.
        let dash = PixelMinApiTable.parse(
            nexusXML: "<d:device><d:id>wear_round</d:id><d:api-level>-</d:api-level></d:device>"
        )
        XCTAssertNil(AvdProfileMinimum.minApi(profileID: "wear_round", table: dash))
        XCTAssertTrue(AvdProfileMinimum.meets(Self.image("system-images;android-30;google_apis;arm64-v8a"), minApi: nil))
    }

    func testMeetsHandles36vs36_1AndExtensions() {
        let plain36 = Self.image("system-images;android-36;google_apis;arm64-v8a")
        let ext19 = Self.image("system-images;android-36-ext19;google_apis;arm64-v8a")
        let v361 = Self.image("system-images;android-36.1;google_apis;arm64-v8a")
        let v37 = Self.image("system-images;android-37.0;google_apis;arm64-v8a")
        let canary = Self.image("system-images;android-CANARY;google_apis;arm64-v8a")
        XCTAssertFalse(AvdProfileMinimum.meets(plain36, minApi: "36.1"))
        XCTAssertFalse(AvdProfileMinimum.meets(ext19, minApi: "36.1"))
        XCTAssertTrue(AvdProfileMinimum.meets(ext19, minApi: "36"))
        XCTAssertTrue(AvdProfileMinimum.meets(v361, minApi: "36.1"))
        XCTAssertTrue(AvdProfileMinimum.meets(v37, minApi: "36.1"))
        XCTAssertFalse(AvdProfileMinimum.meets(canary, minApi: "36.1"))
        XCTAssertTrue(AvdProfileMinimum.meets(plain36, minApi: "35"))
    }

    func testDefaultIsNewestInstalledMeetingTheMinimum() {
        let installed = [
            "system-images;android-35;google_apis_playstore;arm64-v8a",
            "system-images;android-36;google_apis_playstore;arm64-v8a",
            "system-images;android-36.1;google_apis_playstore;arm64-v8a",
        ].map(Self.image)
        let pick = AvdProfileMinimum.defaultImage(
            installed: installed, available: [], minApi: "36.1", category: .phone, hostAbi: abi
        )
        XCTAssertEqual(pick?.api, "android-36.1")
        // Without a minimum the newest installed image wins, as before.
        let any = AvdProfileMinimum.defaultImage(
            installed: installed, available: [], minApi: nil, category: .phone, hostAbi: abi
        )
        XCTAssertEqual(any?.api, "android-36.1")
    }

    func testDefaultNeverPicksBelowMinimumInstalledAndOffersDownload() throws {
        let installed = [
            "system-images;android-35;google_apis_playstore;arm64-v8a",
            "system-images;android-36;google_apis_playstore;arm64-v8a",
        ].map(Self.image)
        let available = [
            "system-images;android-35;google_apis_playstore;arm64-v8a",
            "system-images;android-36-ext19;google_apis_playstore;arm64-v8a",
            "system-images;android-36.1;google_apis_playstore;arm64-v8a",
            "system-images;android-37.0;google_apis_playstore;arm64-v8a",
            "system-images;android-CANARY;google_apis_playstore;arm64-v8a",
            "system-images;android-37.0;google_apis_playstore;x86_64",
        ].map(Self.image)
        let pick = try XCTUnwrap(AvdProfileMinimum.defaultImage(
            installed: installed, available: available, minApi: "36.1", category: .phone, hostAbi: abi
        ))
        XCTAssertEqual(pick.package, "system-images;android-37.0;google_apis_playstore;arm64-v8a")
        XCTAssertTrue(AvdProfileMinimum.meets(pick, minApi: "36.1"))
        // Nothing offered meets it: no default at all, never a below-minimum one.
        let none = AvdProfileMinimum.defaultImage(
            installed: installed,
            available: available.filter { $0.api == "android-35" || $0.api == "android-36-ext19" },
            minApi: "36.1", category: .phone, hostAbi: abi
        )
        XCTAssertNil(none)
    }

    func testWithoutAMinimumAndNothingInstalledTheDefaultIsADownloadSuggestion() throws {
        let available = [
            "system-images;android-35;google_apis_playstore;arm64-v8a",
            "system-images;android-36;google_apis_playstore;arm64-v8a",
            "system-images;android-36;google_apis_playstore;x86_64",
        ].map(Self.image)
        let pick = try XCTUnwrap(AvdProfileMinimum.defaultImage(
            installed: [], available: available, minApi: nil, category: .phone, hostAbi: abi
        ))
        XCTAssertEqual(pick.package, "system-images;android-36;google_apis_playstore;arm64-v8a")
        XCTAssertNil(AvdProfileMinimum.defaultImage(
            installed: [], available: [], minApi: nil, category: .phone, hostAbi: abi
        ))
    }

    func testTextsMatchThePixelCatalog() {
        XCTAssertEqual(AvdProfileMinimum.requiresSuffix(minApi: "36.1"), " \u{00B7} Requires API 36.1+")
        XCTAssertEqual(
            AvdProfileMinimum.explanation(deviceName: "Pixel 10 Pro Fold", minApi: "36.1"),
            "Pixel 10 Pro Fold requires API 36.1 or newer."
        )
    }
}
