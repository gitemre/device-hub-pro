import XCTest
@testable import DeviceHubProKit

/// Newest-first ordering of skins. The skin ids are the ones in the SDK's
/// `skins/` folder (Android SDK, 2026-10).
final class SkinReleaseOrderTests: XCTestCase {
    private func entry(_ name: String) -> SkinCatalogEntry {
        SkinCatalogEntry(
            name: name,
            displayName: SkinResolver.displayName(forSkinName: name),
            category: SkinResolver.category(forSkinName: name),
            directory: URL(fileURLWithPath: "/tmp/\(name)"),
            variants: []
        )
    }

    private func order(_ names: [String]) -> [String] {
        SkinReleaseOrder.sorted(names.map(entry)).map(\.name)
    }

    func testPhonesListCurrentPixelsThenOlderPixelsThenNexusLast() {
        let shuffled = [
            "galaxy_nexus", "nexus_4", "nexus_5", "nexus_5x", "nexus_6", "nexus_6p", "nexus_one", "nexus_s",
            "pixel_2", "pixel_2_xl", "pixel_3", "pixel_3a", "pixel_3a_xl", "pixel_3_xl", "pixel_4", "pixel_4a",
            "pixel_4_xl", "pixel_5", "pixel_6", "pixel_6a", "pixel_6_pro", "pixel_7", "pixel_7a", "pixel_7_pro",
            "pixel_8", "pixel_8a", "pixel_8_pro", "pixel_9", "pixel_9a", "pixel_9_pro", "pixel_9_pro_xl",
            "pixel_10", "pixel_10_pro", "pixel_10_pro_xl", "pixel_silver", "pixel_xl_silver",
        ]
        let sorted = order(shuffled.reversed())
        XCTAssertEqual(Array(sorted.prefix(5)), ["pixel_10_pro_xl", "pixel_10_pro", "pixel_10", "pixel_9_pro_xl", "pixel_9_pro"])
        XCTAssertEqual(Array(sorted.prefix(8).suffix(3)), ["pixel_9", "pixel_9a", "pixel_8_pro"])
        XCTAssertEqual(Set(sorted.suffix(8)), [
            "galaxy_nexus", "nexus_4", "nexus_5", "nexus_5x", "nexus_6", "nexus_6p", "nexus_one", "nexus_s",
        ])
        XCTAssertEqual(sorted.last, "nexus_one")
        XCTAssertEqual(Set(sorted.prefix(28)).count, 28)
        let pixelRank = { (name: String) in sorted.firstIndex(of: name)! }
        XCTAssertLessThan(pixelRank("pixel_9"), pixelRank("pixel_8"))
        XCTAssertLessThan(pixelRank("pixel_8"), pixelRank("pixel_2"))
        XCTAssertLessThan(pixelRank("pixel_2"), pixelRank("pixel_silver"))
        XCTAssertLessThan(pixelRank("pixel_silver"), pixelRank("nexus_6p"))
    }

    func testFoldablesAndTabletsNewestFirst() {
        XCTAssertEqual(
            order(["pixel_fold", "pixel_9_pro_fold", "pixel_10_pro_fold"]),
            ["pixel_10_pro_fold", "pixel_9_pro_fold", "pixel_fold"]
        )
        XCTAssertEqual(
            order(["nexus_7", "nexus_10", "pixel_c", "nexus_9", "pixel_tablet", "nexus_7_2013"]),
            ["pixel_tablet", "pixel_c", "nexus_9", "nexus_7_2013", "nexus_10", "nexus_7"]
        )
    }

    func testTVGoesByResolutionAndUnknownNamesAreAlphabeticalAfterPixels() {
        XCTAssertEqual(order(["tv_720p", "tv_4k", "tv_1080p"]), ["tv_4k", "tv_1080p", "tv_720p"])
        XCTAssertEqual(
            order(["nexus_6", "zeta_phone", "pixel_9", "alpha_phone", "pixel_11"]),
            ["pixel_11", "pixel_9", "alpha_phone", "zeta_phone", "nexus_6"]
        )
    }

    func testCategoriesKeepTheirFirstAppearanceOrder() {
        let names = ["wearos_square", "pixel_8", "wearos_rect", "pixel_9"]
        XCTAssertEqual(
            SkinReleaseOrder.sortedWithinCategories(names.map(entry)).map(\.name),
            ["wearos_rect", "wearos_square", "pixel_9", "pixel_8"]
        )
    }
}
