import XCTest
@testable import DeviceHubProApp

/// Window chrome measured on Device Hub 27.0 (2026-09-29): the compact
/// window's frame, the narrowest window, the sheet metrics and the alert
/// styles.
final class ChromeRound2Tests: XCTestCase {
    func testTheCompactWindowIsDeviceHubs258By587() {
        XCTAssertEqual(CompactMirrorWindow.frameSize, CGSize(width: 258, height: 587))
        XCTAssertEqual(CompactMirrorWindow.defaultSize.height + CompactMirrorWindow.toolbarHeight, 587)
    }

    func testTheNarrowestWindowKeepsTheInspector() {
        // Device Hub's minimum is 876 pt wide with the inspector open.
        XCTAssertLessThanOrEqual(NarrowWindowBehavior.minimumWindowWidth, 900)
        XCTAssertGreaterThanOrEqual(NarrowWindowBehavior.minimumWindowWidth, 876)
    }

    func testTheForceShutDownAlternateFollowsShutDown() {
        XCTAssertEqual(DeviceMenuAlternates.shutDownTitle, "Shut Down")
        XCTAssertEqual(DeviceMenuAlternates.forceShutDownTitle, "Force Shut Down")
    }

    @MainActor
    func testTheAlertStylesFollowDeviceHubs() {
        let remove = DHAlertSpec(title: "Remove A?", message: "m", confirmTitle: "Remove", style: .plain)
        let reset = DHAlertSpec(
            title: "Reset", message: "m", confirmTitle: "Reset",
            cancelTitle: "Don\u{2019}t Reset", style: .caution
        )
        let removeAlert = remove.makeAlert()
        XCTAssertEqual(removeAlert.buttons.map(\.title), ["Remove", "Cancel"], "the answer first: the blue default on the right")
        XCTAssertFalse(removeAlert.buttons[0].hasDestructiveAction, "Remove is blue")
        XCTAssertEqual(removeAlert.alertStyle, .warning)
        let resetAlert = reset.makeAlert()
        XCTAssertEqual(resetAlert.buttons.map(\.title), ["Reset", "Don\u{2019}t Reset"])
        XCTAssertTrue(resetAlert.buttons[0].hasDestructiveAction, "Reset is red")
        XCTAssertEqual(resetAlert.alertStyle, .critical, "under the caution triangle")
        XCTAssertNotNil(resetAlert.icon)
    }

    @MainActor
    func testReturnNeverConfirmsAnAlert() {
        for style in [DHAlertSpec.Style.plain, .destructive, .caution] {
            let spec = DHAlertSpec(title: "t", message: "m", confirmTitle: "Remove", style: style)
            XCTAssertFalse(spec.confirmsOnReturn)
            let alert = spec.makeAlert()
            XCTAssertNotEqual(alert.buttons[0].keyEquivalent, "\r", "Return must not answer \(style)")
            XCTAssertEqual(alert.buttons[1].keyEquivalent, "\u{1b}")
        }
    }

    func testTheQuotedNameUsesCurlyQuotes() {
        XCTAssertEqual(dhQuoted("AQA"), "\u{201C}AQA\u{201D}")
    }

    func testTheSheetRowsAreDeviceHubsHeight() {
        // Three rows plus two 1 pt rules make the 119.5 pt card of the 470 × 217 sheet.
        XCTAssertEqual(DHSheetMetrics.rowHeight * 3 + 2, 119.5, accuracy: 0.6)
    }
}
