import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The sidebar row's trailing text names the OS like Device Hub's "iOS 27.0":
/// "Android 16", "iOS 26.5", "watchOS 26.5"; and what the sidebar says when no
/// usable Xcode is found (iOS simulators and iPhones need it, Android does not).
@MainActor
final class SidebarOSLabelTests: XCTestCase {
    private func row(platform: String, version: String?) -> SidebarDeviceRow {
        SidebarDeviceRow(
            selection: .device("test"),
            title: "Test",
            subtitle: "Emulator",
            version: version,
            isRunning: false,
            symbol: "smartphone",
            isEmulator: true,
            platform: .android,
            platformName: platform
        )
    }

    func testTheTrailingTextIsTheOSNameAndVersion() {
        XCTAssertEqual(row(platform: "iOS", version: "27.0").osLabel, "iOS 27.0")
        XCTAssertEqual(row(platform: "iPadOS", version: "26.5").osLabel, "iPadOS 26.5")
        XCTAssertEqual(row(platform: "watchOS", version: "26.5").osLabel, "watchOS 26.5")
        XCTAssertEqual(row(platform: "tvOS", version: "26.5").osLabel, "tvOS 26.5")
        XCTAssertEqual(row(platform: "visionOS", version: "26.5").osLabel, "visionOS 26.5")
        XCTAssertEqual(row(platform: "Android", version: "16").osLabel, "Android 16")
        XCTAssertEqual(row(platform: "Android", version: nil).osLabel, "Android", "no version known: the bare name, not a dash")
    }

    /// The release the device reports wins; else the API level maps to its
    /// release (36.1 is still Android 16); an API level this build does not
    /// know reads "Android (API N)".
    func testAndroidVersionsComeFromTheReleaseThenTheAPILevel() {
        XCTAssertEqual(SidebarDeviceRow.androidVersionText(release: "16", apiLevel: "36"), "16")
        XCTAssertEqual(SidebarDeviceRow.androidVersionText(release: nil, apiLevel: "36"), "16")
        XCTAssertEqual(SidebarDeviceRow.androidVersionText(release: "?", apiLevel: "36.1"), "16")
        XCTAssertEqual(SidebarDeviceRow.androidVersionText(release: nil, apiLevel: "34"), "14")
        XCTAssertEqual(SidebarDeviceRow.androidVersionText(release: nil, apiLevel: "23"), "(API 23)")
        XCTAssertNil(SidebarDeviceRow.androidVersionText(release: nil, apiLevel: nil))
        XCTAssertNil(SidebarDeviceRow.androidVersionText(release: "?", apiLevel: "?"))
        XCTAssertEqual(row(platform: "Android", version: "(API 23)").osLabel, "Android (API 23)")
    }

    /// The Operating System sort groups by the same text.
    func testTheGroupTitleIsTheLabel() {
        let r = row(platform: "iOS", version: "26.5")
        XCTAssertEqual(r.osGroupTitle, r.osLabel)
    }

    // MARK: Xcode hint

    func testNoXcodeStatusCarriesTheGetXcodeHint() {
        let status = AppleToolingStatus.unavailable
        XCTAssertEqual(status.guidance, .notInstalled)
        XCTAssertEqual(status.setupAdvice, "iOS simulators and iPhones need Xcode.")
        XCTAssertEqual(status.guidance?.actionTitle, "Get Xcode\u{2026}")
        XCTAssertEqual(status.guidance?.actionURL?.absoluteString, "macappstore://apps.apple.com/app/id497799835")
        XCTAssertNil(AppleToolingStatus.probing.guidance, "nothing is said before the probe answers")
        let ready = AppleToolingStatus(isProbed: true, tier: .t1, setupAdvice: nil, xcodeVersion: "27.0", xcodeBuild: "27A266a")
        XCTAssertNil(ready.guidance)
    }

    func testTheHintsForAnInstalledButUnselectedXcodeAndAPendingFirstLaunch() {
        let app = URL(fileURLWithPath: "/Applications/Xcode.app")
        let notSelected = AppleToolchain.XcodeGuidance.notSelected(xcodeName: "Xcode", app: app)
        XCTAssertTrue(notSelected.message.contains("Xcode is not the selected one"))
        XCTAssertEqual(notSelected.actionTitle, "Open Xcode\u{2026}")
        XCTAssertEqual(notSelected.actionURL, app)
        let pending = AppleToolchain.XcodeGuidance.finishInstalling(app: app)
        XCTAssertEqual(pending.message, "Open Xcode, accept the license and let it install its components (a few minutes), then come back.")
        XCTAssertEqual(pending.actionURL, app)
        XCTAssertNil(AppleToolchain.XcodeGuidance.finishInstalling(app: nil).actionURL)
    }
}
