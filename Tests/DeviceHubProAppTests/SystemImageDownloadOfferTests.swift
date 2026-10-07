import XCTest
import DeviceHubProKit
@testable import DeviceHubProApp

/// The download sheet offers what the host runs and the profile accepts.
final class SystemImageDownloadOfferTests: XCTestCase {
    private func image(_ api: String, _ tag: String, _ abi: String) -> SystemImage {
        SystemImage(package: "system-images;android-\(api);\(tag);\(abi)", api: "android-\(api)", tag: tag, abi: abi)
    }

    func testOfferedImagesFitTheHostAndTheProfile() {
        let all = [
            image("36", "google_apis", "arm64-v8a"),
            image("36", "google_apis", "x86_64"),
            image("36", "android-wear", "arm64-v8a"),
            image("35", "google_apis_playstore", "arm64-v8a"),
        ]
        let phone = SystemImageDownloadSheet.offered(all, category: .phone, hostAbi: "arm64-v8a")
        XCTAssertEqual(phone.map(\.package), [all[0].package, all[3].package])
        let wear = SystemImageDownloadSheet.offered(all, category: .wear, hostAbi: "arm64-v8a")
        XCTAssertEqual(wear.map(\.package), [all[2].package])
    }
}
