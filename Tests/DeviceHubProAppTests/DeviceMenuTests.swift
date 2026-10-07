import SwiftUI
import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// The Device and Controls menus' per-device structure and the window's narrow
/// behaviour: pure decisions, the SwiftUI wiring around them is checked live
/// (parity audit, "Menus and window chrome").
final class DeviceMenuTests: XCTestCase {
    // MARK: - Layout per selected device

    func testASimulatorShowsDeviceHubsSettingsAndNeverAndroidExtras() {
        let layout = DeviceMenuLayout(selection: .simulator("UDID"), isRunning: true)
        XCTAssertEqual(layout.kind, .simulator)
        XCTAssertTrue(layout.hasLifecycle)
        XCTAssertTrue(layout.showsAppleSettings)
        XCTAssertFalse(layout.showsAndroidExtras)
        XCTAssertFalse(layout.usesAndroidControls)
        XCTAssertTrue(layout.showsOpenURL)
    }

    func testAStoppedSimulatorKeepsItsMenusButNoOpenURL() {
        let layout = DeviceMenuLayout(selection: .simulator("UDID"), isRunning: false)
        XCTAssertTrue(layout.showsAppleSettings)
        XCTAssertFalse(layout.showsOpenURL)
    }

    func testARunningAVDShowsTheAndroidExtrasAndControls() {
        let layout = DeviceMenuLayout(selection: .avd("Pixel_9_Pro"), isRunning: true)
        XCTAssertEqual(layout.kind, .android)
        XCTAssertEqual(layout.avdName, "Pixel_9_Pro")
        XCTAssertTrue(layout.hasLifecycle)
        XCTAssertTrue(layout.showsAndroidExtras)
        XCTAssertTrue(layout.usesAndroidControls)
        XCTAssertFalse(layout.showsAppleSettings)
    }

    func testAStoppedAVDHasNoSensorsOrSimulateItems() {
        let layout = DeviceMenuLayout(selection: .avd("Pixel_9_Pro"), isRunning: false)
        XCTAssertTrue(layout.hasLifecycle)
        XCTAssertFalse(layout.showsAndroidExtras)
        XCTAssertFalse(layout.showsOpenURL)
    }

    func testAnAdbDeviceHasNoLifecycleButTheAndroidSet() {
        let layout = DeviceMenuLayout(selection: .device("emulator-5554"), isRunning: true)
        XCTAssertEqual(layout.kind, .android)
        XCTAssertNil(layout.avdName)
        XCTAssertFalse(layout.hasLifecycle)
        XCTAssertTrue(layout.showsAndroidExtras)
    }

    func testAPhysicalAppleDeviceAndNoSelectionShowNoDeviceExtras() {
        for selection in [DeviceSelection.physicalApple("UDID"), .pixel("Pixel 9"), nil] {
            let layout = DeviceMenuLayout(selection: selection, isRunning: true)
            XCTAssertFalse(layout.hasLifecycle)
            XCTAssertFalse(layout.showsAppleSettings)
            XCTAssertFalse(layout.showsAndroidExtras)
            XCTAssertFalse(layout.showsOpenURL)
            XCTAssertFalse(layout.usesAndroidControls)
        }
    }

    // MARK: - Zoom availability

    func testZoomWorksForASimulatorsSessionAsWellAsAnAdbDevice() {
        XCTAssertTrue(stageZoomIsAvailable(liveSelectionSerial: "emulator-5554", hasSession: false))
        XCTAssertTrue(stageZoomIsAvailable(liveSelectionSerial: nil, hasSession: true))
        XCTAssertFalse(stageZoomIsAvailable(liveSelectionSerial: nil, hasSession: false))
    }

    /// The Android mirror outlives the selection that started it: with No
    /// Selection, or a simulator selected, it is not the toolbar's session
    /// (the zoom, keyboard and resize buttons dim, as in Device Hub).
    func testAStaleAndroidSessionIsNotTheSelectionsSession() {
        let android = DeviceRef.android("emulator-5554")
        XCTAssertFalse(DeviceWorkspace.sessionBelongs(to: nil, sessionDevice: android, isPhysicalView: false))
        XCTAssertFalse(DeviceWorkspace.sessionBelongs(to: .simulator("SIM"), sessionDevice: android, isPhysicalView: false))
        XCTAssertFalse(DeviceWorkspace.sessionBelongs(to: .physicalApple("PHONE"), sessionDevice: android, isPhysicalView: false))
        XCTAssertTrue(DeviceWorkspace.sessionBelongs(to: .avd("Pixel"), sessionDevice: android, isPhysicalView: false))
        XCTAssertTrue(DeviceWorkspace.sessionBelongs(to: .device("emulator-5554"), sessionDevice: android, isPhysicalView: false))
        XCTAssertFalse(DeviceWorkspace.sessionBelongs(to: .avd("Pixel"), sessionDevice: nil, isPhysicalView: false))
    }

    func testASimulatorsSessionBelongsToItsOwnRowOnly() {
        let sim = DeviceRef.apple("SIM-A")
        XCTAssertTrue(DeviceWorkspace.sessionBelongs(to: .simulator("SIM-A"), sessionDevice: sim, isPhysicalView: false))
        XCTAssertFalse(DeviceWorkspace.sessionBelongs(to: .simulator("SIM-B"), sessionDevice: sim, isPhysicalView: false))
        XCTAssertFalse(DeviceWorkspace.sessionBelongs(to: .avd("Pixel"), sessionDevice: sim, isPhysicalView: false))
        let phone = DeviceRef.physicalApple("abc")
        XCTAssertTrue(DeviceWorkspace.sessionBelongs(to: .physicalApple("ABC"), sessionDevice: phone, isPhysicalView: true))
        XCTAssertFalse(DeviceWorkspace.sessionBelongs(to: .simulator("ABC"), sessionDevice: phone, isPhysicalView: true))
    }

    // MARK: - Narrow windows

    /// Device Hub keeps its inspector at every width down to its minimum
    /// (876 pt): the window's own minimum follows the stage (881 pt here) and
    /// the toolbar folds into » instead (`NarrowWindowBehavior`).
    func testTheInspectorIsNeverHiddenForANarrowWindow() {
        XCTAssertEqual(NarrowWindowBehavior.minimumWindowWidth, 881)
        XCTAssertLessThan(NarrowWindowBehavior.minimumWindowWidth, 900)
    }

    // MARK: - Toolbar labels

    func testASegmentsAccessibilityNameDefaultsToItsTooltip() {
        let plain = ToolbarSegment(id: "a", help: "Zoom Out", action: {}) { EmptyView() }
        XCTAssertEqual(plain.accessibilityName, "Zoom Out")
        let named = ToolbarSegment(id: "b", help: "Reports", label: "Text Document", action: {}) { EmptyView() }
        XCTAssertEqual(named.accessibilityName, "Text Document")
        XCTAssertEqual(named.help, "Reports")
    }
}
