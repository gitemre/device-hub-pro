import XCTest
@testable import DeviceHubProKit

final class PixelImageSuggestionTests: XCTestCase {
    private func device(minApi: String?, playstore: Bool) -> PixelDevice {
        PixelDevice(
            skinName: "pixel_9_pro",
            displayName: "Pixel 9 Pro",
            category: .phone,
            skin: PixelCatalogTests.entry(name: "pixel_9_pro"),
            deviceProfileID: "pixel_9_pro",
            minApi: minApi,
            playstoreEnabled: playstore,
            installedAvdNames: []
        )
    }

    private func image(
        _ api: String,
        tag: String = "google_apis",
        abi: String = "arm64-v8a"
    ) -> SystemImage {
        SystemImage(
            package: "system-images;android-\(api);\(tag);\(abi)",
            api: "android-\(api)",
            tag: tag,
            abi: abi
        )
    }

    func testBelowMinimumIsExcludedFromSelection() {
        let candidates = PixelImageSuggestion.candidates(
            device: device(minApi: "35", playstore: true),
            installed: [image("34"), image("35")],
            available: [],
            hostAbi: "arm64-v8a"
        )
        XCTAssertEqual(
            candidates.first(where: { $0.image.api == "android-34" })?.meetsMinimum,
            false
        )
        XCTAssertEqual(
            candidates.first(where: { $0.image.api == "android-35" })?.meetsMinimum,
            true
        )
    }

    func testPreferredIsInstalledHighest() {
        let candidates = PixelImageSuggestion.candidates(
            device: device(minApi: "35", playstore: true),
            installed: [image("35"), image("36")],
            available: [image("37.1", tag: "google_apis_playstore_ps16k")],
            hostAbi: "arm64-v8a"
        )
        let preferred = PixelImageSuggestion.preferred(in: candidates)
        XCTAssertEqual(preferred?.image.api, "android-36")
        XCTAssertEqual(preferred?.isInstalled, true)
    }

    func testPreferredFallsBackToNewestAvailable() {
        let candidates = PixelImageSuggestion.candidates(
            device: device(minApi: "35", playstore: true),
            installed: [],
            available: [
                image("35", tag: "google_apis_playstore"),
                image("36.1", tag: "google_apis_playstore"),
                image("36.1", tag: "google_apis"),
            ],
            hostAbi: "arm64-v8a"
        )
        let preferred = PixelImageSuggestion.preferred(in: candidates)
        XCTAssertEqual(preferred?.image.api, "android-36.1")
        XCTAssertEqual(preferred?.image.tag, "google_apis_playstore")
        XCTAssertEqual(preferred?.isInstalled, false)
    }

    func testPlaystorePreferenceAndAtdExclusion() {
        let candidates = PixelImageSuggestion.candidates(
            device: device(minApi: "30", playstore: false),
            installed: [],
            available: [
                image("35", tag: "google_atd"),
                image("35", tag: "google_apis"),
                image("35", tag: "google_apis_playstore"),
            ],
            hostAbi: "arm64-v8a"
        )
        let tags = candidates.map(\.image.tag)
        XCTAssertFalse(tags.contains("google_atd"))
        XCTAssertEqual(
            PixelImageSuggestion.preferred(in: candidates)?.image.tag,
            "google_apis"
        )
    }

    func testPs16kSupersedesPlainSibling() {
        let candidates = PixelImageSuggestion.candidates(
            device: device(minApi: "35", playstore: true),
            installed: [],
            available: [
                image("36.1", tag: "google_apis_playstore"),
                image("36.1", tag: "google_apis_playstore_ps16k"),
            ],
            hostAbi: "arm64-v8a"
        )
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.image.tag, "google_apis_playstore_ps16k")
    }

    /// An installed plain image must never be collapsed away in favour of a
    /// downloadable ps16k sibling: the installed one is what the flow uses.
    func testInstalledPlainBeatsDownloadablePs16k() {
        let candidates = PixelImageSuggestion.candidates(
            device: device(minApi: "35", playstore: true),
            installed: [image("36.1", tag: "google_apis_playstore")],
            available: [image("36.1", tag: "google_apis_playstore_ps16k")],
            hostAbi: "arm64-v8a"
        )
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.image.tag, "google_apis_playstore")
        XCTAssertEqual(candidates.first?.isInstalled, true)
    }

    func testUnknownMinimumKeepsEverythingSelectable() {
        let candidates = PixelImageSuggestion.candidates(
            device: device(minApi: nil, playstore: true),
            installed: [image("30")],
            available: [],
            hostAbi: "arm64-v8a"
        )
        XCTAssertTrue(candidates.allSatisfy(\.meetsMinimum))
        XCTAssertEqual(PixelImageSuggestion.preferred(in: candidates)?.image.api, "android-30")
    }

    func testHostAbiFilter() {
        let candidates = PixelImageSuggestion.candidates(
            device: device(minApi: nil, playstore: false),
            installed: [],
            available: [image("35", abi: "x86_64"), image("35", abi: "arm64-v8a")],
            hostAbi: "arm64-v8a"
        )
        XCTAssertEqual(candidates.map(\.image.abi), ["arm64-v8a"])
    }

    /// Preview channels and non-phone image families never reach a Pixel's
    /// picker; stable google_apis/playstore images do.
    func testBetaCanaryAndForeignFamiliesExcluded() {
        let candidates = PixelImageSuggestion.candidates(
            device: device(minApi: nil, playstore: true),
            installed: [],
            available: [
                image("CANARY", tag: "google_apis_ps16k"),
                image("37.2-beta2", tag: "google_apis_playstore"),
                image("37.0", tag: "android-wear-signed"),
                image("37.0", tag: "android-automotive"),
                image("37.0", tag: "android-desktop"),
                image("36", tag: "android-tv"),
                image("36", tag: "google-tv-ps16k"),
                image("36", tag: "aosp_atd"),
                image("36", tag: "google-xr"),
                image("36", tag: "google_apis_playstore"),
            ],
            hostAbi: "arm64-v8a"
        )
        XCTAssertEqual(candidates.map(\.image.tag), ["google_apis_playstore"])
    }

    func testInstalledBelowMinimumIsNotPreferred() {
        let candidates = PixelImageSuggestion.candidates(
            device: device(minApi: "35", playstore: false),
            installed: [image("34")],
            available: [image("35", tag: "google_apis")],
            hostAbi: "arm64-v8a"
        )
        let preferred = PixelImageSuggestion.preferred(in: candidates)
        XCTAssertEqual(preferred?.image.api, "android-35")
        XCTAssertEqual(preferred?.isInstalled, false)
    }

    func testReadinessOrderAndContent() {
        let missing = PixelReadiness.missing(
            hasAdb: false,
            hasEmulator: true,
            hasCommandLineTools: false,
            hasJava: false,
            hasUsableImage: false
        )
        XCTAssertEqual(missing, [.platformTools, .commandLineTools, .java, .systemImage])
        XCTAssertTrue(
            PixelReadiness.missing(
                hasAdb: true,
                hasEmulator: true,
                hasCommandLineTools: true,
                hasJava: true,
                hasUsableImage: true
            ).isEmpty
        )
    }
}
