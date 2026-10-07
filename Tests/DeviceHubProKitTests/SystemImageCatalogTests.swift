import XCTest
@testable import DeviceHubProKit

/// Naming, filtering, ordering and grouping of system images for the create
/// sheet's OS Version popup. SOURCE-DERIVED: the package ids follow
/// sdkmanager's `system-images;<api>;<tag>;<abi>` naming (Android SDK
/// command-line tools); the model is pure, no tool output is involved.
final class SystemImageCatalogTests: XCTestCase {
    private func image(_ api: String, _ tag: String, _ abi: String = "arm64-v8a") -> SystemImage {
        SystemImage(package: "system-images;android-\(api);\(tag);\(abi)", api: "android-\(api)", tag: tag, abi: abi)
    }

    func testVersionTitles() {
        XCTAssertEqual(image("37.1", "google_apis").versionTitle, "Android 17 (API 37.1)")
        XCTAssertEqual(image("35", "google_apis").versionTitle, "Android 15 (API 35)")
        XCTAssertEqual(image("23", "default").versionTitle, "API 23")
        XCTAssertEqual(image("CinnamonBun", "google_apis").versionTitle, "API CinnamonBun \u{00B7} Preview")
        XCTAssertEqual(image("33-ext4", "google_apis_playstore").versionTitle, "Android 13 (API 33)")
        XCTAssertEqual(image("37.2-beta1", "google_apis_ps16k").versionTitle, "API 37.2-beta1 \u{00B7} Preview")
    }

    func testNewestFirstWithPlayBeforeApisBeforeAosp() {
        let images = [
            image("34", "google_apis"),
            image("36.1", "google_apis"),
            image("35", "default"),
            image("36", "google_apis_playstore"),
            image("36", "google_apis"),
            image("CinnamonBun", "google_apis"),
            image("9", "google_apis"),
        ]
        XCTAssertEqual(
            SystemImageCatalog.sorted(images).map(\.api),
            ["android-36.1", "android-36", "android-36", "android-35", "android-34", "android-9", "android-CinnamonBun"]
        )
        let level36 = SystemImageCatalog.sorted(images).filter { $0.api == "android-36" }
        XCTAssertEqual(level36.map(\.variantTitle), ["Google Play", "Google APIs"])
    }

    func testOnlyImagesForTheProfilesFormFactorAreCompatible() {
        let images = [
            image("36", "google_apis"),
            image("36", "android-wear"),
            image("36", "android-tv"),
            image("36", "google-tv"),
            image("36", "android-automotive-playstore"),
            image("36", "android-desktop"),
        ]
        XCTAssertEqual(SystemImageCatalog.compatible(images, with: .phone).map(\.tag), ["google_apis"])
        XCTAssertEqual(SystemImageCatalog.compatible(images, with: .tablet).map(\.tag), ["google_apis"])
        XCTAssertEqual(SystemImageCatalog.compatible(images, with: .wear).map(\.tag), ["android-wear"])
        XCTAssertEqual(Set(SystemImageCatalog.compatible(images, with: .tv).map(\.tag)), ["android-tv", "google-tv"])
        XCTAssertEqual(SystemImageCatalog.compatible(images, with: .automotive).map(\.tag), ["android-automotive-playstore"])
    }

    func testAVariantShowsOnlyWhereTheTitleAloneIsAmbiguous() {
        let options = SystemImageCatalog.options([
            image("37.1", "google_apis"),
            image("36", "google_apis_playstore"),
            image("36", "google_apis"),
            image("35", "google_apis"),
            image("35", "google_apis", "x86_64"),
        ])
        XCTAssertEqual(options.map(\.menuTitle), [
            "Android 17 (API 37.1)",
            "Android 16 (API 36) \u{00B7} Google Play",
            "Android 16 (API 36) \u{00B7} Google APIs",
            "Android 15 (API 35) \u{00B7} Google APIs \u{00B7} arm64",
            "Android 15 (API 35) \u{00B7} Google APIs \u{00B7} x86_64",
        ])
    }

    func testGroupsByReleaseNewestFirst() {
        let groups = SystemImageCatalog.groups([
            image("35", "google_apis"),
            image("36", "google_apis"),
            image("36", "google_apis_playstore"),
        ])
        XCTAssertEqual(groups.map(\.title), ["Android 16 (API 36)", "Android 15 (API 35)"])
        XCTAssertEqual(groups[0].images.map(\.variantTitle), ["Google Play", "Google APIs"])
    }

    /// The fresh VM's sdkmanager listing (cmdline-tools 23.0.0, arm64 images):
    /// `android-33-ext4` used to parse as a preview and list first.
    func testRealListingOrderRecommendationAndExtensionFolding() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/cmdline-tools-23/sdkmanager-list.stdout")
        let all = SdkmanagerParsing.availableImages(fromListOutput: try String(contentsOf: url, encoding: .utf8))
        let arm = all.filter { $0.abi == "arm64-v8a" }

        let phone = SystemImageCatalog.compatible(arm, with: .phone)
        let titles = SystemImageCatalog.groups(phone).map(\.title)
        XCTAssertEqual(titles.prefix(4), [
            "Android 17 (API 37.2)", "Android 17 (API 37.1)", "Android 17 (API 37.0)", "Android 16 (API 36.1)",
        ])
        // Previews after every stable release, codename first.
        let firstPreview = try XCTUnwrap(titles.firstIndex { $0.hasSuffix("Preview") })
        XCTAssertTrue(titles[firstPreview...].allSatisfy { $0.hasSuffix("Preview") })
        XCTAssertEqual(titles[firstPreview], "API canary-20260909 \u{00B7} Preview")
        XCTAssertEqual(titles.last, "API 37.2-beta1 \u{00B7} Preview")

        // Android 13: the release's images and the two extension builds, folded.
        let thirteen = try XCTUnwrap(SystemImageCatalog.groups(phone).first { $0.title == "Android 13 (API 33)" })
        XCTAssertEqual(thirteen.extensionImages.map(\.api).sorted(), ["android-33-ext4", "android-33-ext5"])
        XCTAssertFalse(thirteen.baseImages.isEmpty)
        XCTAssertEqual(thirteen.images.prefix(thirteen.baseImages.count).map(\.id), thirteen.baseImages.map(\.id))

        XCTAssertEqual(
            SystemImageCatalog.recommended(phone)?.package,
            "system-images;android-37.0;google_apis;arm64-v8a"
        )
        XCTAssertEqual(
            SystemImageCatalog.recommended(SystemImageCatalog.compatible(arm, with: .tv))?.package,
            "system-images;android-36;google-tv;arm64-v8a"
        )
        XCTAssertEqual(
            SystemImageCatalog.recommended(SystemImageCatalog.compatible(arm, with: .wear))?.package,
            "system-images;android-37.0;android-wear-signed;arm64-v8a"
        )
    }

    func testFriendlyLabelIsUnchanged() {
        XCTAssertEqual(image("35", "google_apis_playstore").friendlyLabel, "Android 15 \u{00B7} Google Play \u{00B7} arm64")
    }

    /// Package ids as `sdkmanager --list` printed them (Android SDK
    /// command-line tools, 2026-10): Android 16's two Google TV images and the
    /// phone images that differ only in a qualifier.
    func testRowsThatReadTheSameAreToldApartByTheTagQualifier() {
        let images = [
            image("36", "google-tv"),
            image("36", "google-tv-ps16k"),
            image("36", "google_apis"),
            image("36", "google_apis_ps16k"),
            image("36", "google_apis_playstore"),
            image("36", "google_apis_playstore_ps16k"),
            image("36", "google_atd"),
            image("36", "aosp_atd"),
        ]
        let group = SystemImageCatalog.groups(images)[0]
        let titles = group.images.map { group.variantTitle(for: $0) }
        XCTAssertEqual(Set(titles).count, titles.count, "no two rows read the same")
        XCTAssertEqual(group.variantTitle(for: images[0]), "Google TV")
        XCTAssertEqual(group.variantTitle(for: images[1]), "Google TV (16 KB)")

        let options = SystemImageCatalog.options([image("36", "google-tv"), image("36", "google-tv-ps16k")])
        XCTAssertEqual(options.map(\.menuTitle), [
            "Android 16 (API 36) \u{00B7} Google TV",
            "Android 16 (API 36) \u{00B7} Google TV (16 KB)",
        ])
    }

    func testTabletImagesAreNotCalledLikeThePhoneImages() {
        XCTAssertEqual(image("35", "google_apis_tablet").variantTitle, "Google APIs (Tablet)")
        XCTAssertEqual(image("35", "google_apis_playstore_tablet").variantTitle, "Google Play (Tablet)")
    }

    func testAnUnknownCollidingTagFallsBackToItsRawWords() {
        let a = image("36", "google_apis_playstore_foo")
        let b = image("36", "google_apis_playstore_bar")
        let titles = SystemImageCatalog.variantTitles([a, b])
        XCTAssertEqual(titles[a.id], "Google Play (google apis playstore foo)")
        XCTAssertEqual(titles[b.id], "Google Play (google apis playstore bar)")
    }
}
