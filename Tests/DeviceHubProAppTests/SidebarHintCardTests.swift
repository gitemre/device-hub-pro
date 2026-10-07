import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The sidebar's iOS card: when the "iOS simulators and iPhones need Xcode"
/// line shows as a card in the list (not as grey text at the bottom), for
/// which guidance, and when it stays away.
@MainActor
final class SidebarHintCardTests: XCTestCase {
    private func status(probed: Bool = true, guidance: AppleToolchain.XcodeGuidance?) -> AppleToolingStatus {
        AppleToolingStatus(
            isProbed: probed,
            tier: guidance == nil ? .t1 : .t0,
            setupAdvice: guidance?.message,
            guidance: guidance,
            xcodeVersion: nil,
            xcodeBuild: nil
        )
    }

    func testTheCardShowsForEveryKindOfMissingXcode() {
        let app = URL(fileURLWithPath: "/Applications/Xcode.app")
        for guidance in [
            AppleToolchain.XcodeGuidance.notInstalled,
            .notSelected(xcodeName: "Xcode", app: app),
            .finishInstalling(app: app),
        ] {
            let shown = DeviceSidebarView.xcodeCardGuidance(
                tooling: status(guidance: guidance), dismissed: false, hasQuery: false
            )
            XCTAssertEqual(shown, guidance)
        }
        XCTAssertEqual(AppleToolchain.XcodeGuidance.notInstalled.actionTitle, "Get Xcode\u{2026}")
        XCTAssertEqual(AppleToolchain.XcodeGuidance.finishInstalling(app: app).actionTitle, "Open Xcode\u{2026}")
    }

    func testTheCardStaysAwayWhenItWouldMislead() {
        let missing = status(guidance: .notInstalled)
        XCTAssertNil(
            DeviceSidebarView.xcodeCardGuidance(tooling: missing, dismissed: true, hasQuery: false),
            "closed with Don't show again"
        )
        XCTAssertNil(
            DeviceSidebarView.xcodeCardGuidance(tooling: missing, dismissed: false, hasQuery: true),
            "a search that matches nothing leaves the list blank"
        )
        XCTAssertNil(
            DeviceSidebarView.xcodeCardGuidance(
                tooling: status(probed: false, guidance: .notInstalled), dismissed: false, hasQuery: false
            ),
            "not before the probe has answered"
        )
        XCTAssertNil(
            DeviceSidebarView.xcodeCardGuidance(tooling: status(guidance: nil), dismissed: false, hasQuery: false),
            "Xcode works: nothing to say"
        )
    }

    func testAClosedCardIsRememberedThroughThePreferences() {
        let defaults = UserDefaults.scratch()
        let model = AppModel.testing(defaults: defaults)
        XCTAssertFalse(model.preferences.xcodeHintDismissed)
        model.preferences.setXcodeHintDismissed(true)
        XCTAssertTrue(AppModel.testing(defaults: defaults).preferences.xcodeHintDismissed)
    }
}

/// The iOS card on a Mac whose Xcode works but has no simulator runtime.
@MainActor
final class SidebarPlatformCardTests: XCTestCase {
    private let ready = AppleToolingStatus(isProbed: true, tier: .t1, setupAdvice: nil, xcodeVersion: "27.0", xcodeBuild: "27A266a")

    private func shows(
        tooling: AppleToolingStatus? = nil,
        read: Bool = true,
        runtimes: Int = 0,
        iPhone: Bool = false,
        dismissed: Bool = false,
        query: Bool = false
    ) -> Bool {
        DeviceSidebarView.platformCardShows(
            tooling: tooling ?? ready, runtimesRead: read, runtimeCount: runtimes,
            hasPhysicalIPhone: iPhone, dismissed: dismissed, hasQuery: query
        )
    }

    func testTheCardShowsWithXcodeAndNoRuntime() {
        XCTAssertTrue(shows())
        XCTAssertEqual(DeviceSidebarView.platformCardMessage, "Download the iOS platform in Xcode to create simulators.")
        XCTAssertEqual(DeviceSidebarView.platformCardActionTitle, "Add Platforms in Xcode\u{2026}")
        XCTAssertEqual(SimulatorCreateSheet.addPlatformsURL?.absoluteString, "xcode://settings/components/addSimulator")
    }

    func testTheCardLeavesWhenARuntimeExistsOrAnIPhoneShows() {
        XCTAssertFalse(shows(runtimes: 1))
        XCTAssertFalse(shows(iPhone: true))
    }

    func testTheCardStaysAwayWhenItWouldMislead() {
        XCTAssertFalse(shows(read: false), "before the runtime listing was read")
        XCTAssertFalse(shows(tooling: .probing))
        XCTAssertFalse(shows(tooling: .unavailable), "no Xcode: the Xcode card speaks")
        XCTAssertFalse(shows(dismissed: true))
        XCTAssertFalse(shows(query: true))
    }
}
