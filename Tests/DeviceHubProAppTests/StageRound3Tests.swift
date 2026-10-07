import SwiftUI
import XCTest
import DeviceHubProKit
@testable import DeviceHubProApp

/// The third stage / inspector parity pass (2026-09-29): a stopped
/// simulator's Display, the UDID's cut, the plain-language rule for what the
/// user reads, the pill's fill and the compact window's band.
final class StageRound3Tests: XCTestCase {
    // MARK: - Info

    func testASimulatorsDisplayIsShownOnceItHasRun() {
        let shape = DisplayShape(uniqueId: "local:1", name: "Built-in Screen", width: 1206, height: 2622)
        XCTAssertNil(SimulatorInfoCards.displayText(hasRun: false, shape: shape), "a simulator that never ran shows --")
        XCTAssertEqual(SimulatorInfoCards.displayText(hasRun: true, shape: shape), "1206 × 2622")
        XCTAssertNil(SimulatorInfoCards.displayText(hasRun: true, shape: nil))
    }

    // MARK: - Boot

    func testABootingSimulatorShowsItsDeviceOnceItsCanvasHasAFrame() {
        let booting = SimulatorStagePhase.booting("Starting…")
        XCTAssertTrue(SimulatorStageView.showsBootingDevice(phase: booting, hasFirstFrame: true))
        XCTAssertFalse(SimulatorStageView.showsBootingDevice(phase: booting, hasFirstFrame: false))
        XCTAssertFalse(SimulatorStageView.showsBootingDevice(phase: .live, hasFirstFrame: true))
        XCTAssertFalse(SimulatorStageView.showsBootingDevice(phase: .stopped(activity: nil), hasFirstFrame: true))
    }

    // MARK: - Plain language

    func testAToolsFailureLineReadsAsPlainWords() {
        XCTAssertEqual(
            UserFacingText.plain("adb -s emulator-5570 shell svc wifi disable failed (1): cmd: Failure calling service\n"),
            "The device returned an error: cmd: Failure calling service"
        )
        XCTAssertEqual(
            UserFacingText.plain("simctl io ABC recordVideo failed (exit 1): "),
            "The simulator returned an error."
        )
        XCTAssertEqual(UserFacingText.plain("Couldn't reach the emulator"), "Couldn't reach the emulator")
    }

    func testTheTooltipFilterAlsoDropsCodeNames() {
        XCTAssertEqual(DHHelp.tooltip("Calls onTrimMemory(5) in the app."), "")
        XCTAssertEqual(DHHelp.tooltip("Sets the debug.layout property."), "")
        XCTAssertEqual(DHHelp.tooltip("Outlines the edges and margins of every view."), "Outlines the edges and margins of every view.")
    }

    func testNoUserFacingTooltipOrStateMentionsTheTools() {
        for text in [
            StatusBarRowText.cleanStatusBarHelp, StatusBarRowText.demoModeOff, StatusBarRowText.onByDeviceHubPro, StatusBarRowText.stuck,
            StatusBarRowText.unreportedLegacy, StatusBarRowText.unreportedSystemUI,
        ] {
            XCTAssertFalse(DHHelp.isTechnical(text), text)
        }
        XCTAssertFalse(AdbError.adbNotFound.description.contains("adb "), AdbError.adbNotFound.description)
    }

    // MARK: - Pill and compact window

    func testThePillIsLiftedWhiteGlassNotAGrayTint() {
        XCTAssertNil(ParityMetrics.pillTint, "any glass tint darkens it")
        var light = EnvironmentValues()
        light.colorScheme = .light
        XCTAssertGreaterThan(ParityMetrics.pillLift.resolve(in: light).opacity, 0.5)
        // Dark keeps the dark glass: white symbols over a light lift read about 2:1.
        var dark = EnvironmentValues()
        dark.colorScheme = .dark
        XCTAssertLessThan(ParityMetrics.pillLift.resolve(in: dark).opacity, 0.2)
    }

    func testTheCompactWindowKeepsTheBandDeviceHubsPillNeeds() {
        XCTAssertEqual(
            ParityMetrics.compactStagePillBand,
            ParityMetrics.pillHeight + ParityMetrics.pillBottomInset + 1
        )
    }

    func testAStoppedEmulatorsSettingsShowThePlaceholderNotAList() {
        XCTAssertEqual(controlsPanelContent(activeSerial: nil, controlsLoaded: true), .noDevice)
    }
}
