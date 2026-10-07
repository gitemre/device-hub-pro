import XCTest
@testable import DeviceHubProApp

/// The pure parts of the physical rows' right-click actions: where CarPlay Simulator and the device's folder are, and what
/// the confirmations say. The commands themselves are pinned in the Kit's
/// `ApplePhysicalManagementTests` (no test runs one against a device).
@MainActor
final class PhysicalDeviceActionsTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/tester")

    func testDeviceHubIsFoundByBundleIdentifierFirst() {
        let found = URL(fileURLWithPath: "/Somewhere/DeviceHub.app")
        XCTAssertEqual(DeviceHubLocator.locate(applicationURL: { $0 == "com.apple.dt.DeviceHub" ? found : nil }, exists: { _ in false }), found)
    }

    func testDeviceHubFallsBackToXcodesCopyAndIsNilWhenAbsent() {
        let xcode = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Applications/DeviceHub.app")
        XCTAssertEqual(DeviceHubLocator.locate(applicationURL: { _ in nil }, exists: { $0 == xcode }), xcode)
        XCTAssertNil(DeviceHubLocator.locate(applicationURL: { _ in nil }, exists: { _ in false }))
    }

    private func makeActions() throws -> (PhysicalDeviceActions, StatusCenter) {
        let status = StatusCenter()
        let inventory = ApplePhysicalInventory(
            preferences: AppPreferences(defaults: .scratch()),
            iphoneUDID: nil,
            toolchain: { nil },
            isAppActive: { true }
        )
        let actions = PhysicalDeviceActions(inventory: inventory, status: status, picker: TestPicker(), adbClient: nil, defaults: .scratch())
        return (actions, status)
    }

    /// The CarPlay item opens Device Hub, and says why the first time only.
    func testCarPlayOpensDeviceHubWithAOneTimeExplanation() throws {
        let (actions, status) = try makeActions()
        let hub = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Applications/DeviceHub.app")
        actions.carPlaySimulator = { hub }
        var opened: [URL] = []
        actions.openApplication = { opened.append($0) }

        actions.openCarPlaySimulator()
        XCTAssertEqual(opened, [hub])
        XCTAssertEqual(status.statusMessage, PhysicalDeviceActions.carPlayExplanation)
        XCTAssertEqual(
            PhysicalDeviceActions.carPlayExplanation,
            "CarPlay Simulator runs in Device Hub. Device Hub opens; choose CarPlay Simulator on the iPhone there."
        )

        status.flash("other")
        actions.openCarPlaySimulator()
        XCTAssertEqual(opened, [hub, hub])
        XCTAssertEqual(status.statusMessage, "other", "the explanation shows once")
    }

    func testCarPlayDoesNothingWithoutDeviceHub() throws {
        let (actions, _) = try makeActions()
        actions.carPlaySimulator = { nil }
        var opened = 0
        actions.openApplication = { _ in opened += 1 }
        XCTAssertNil(actions.carPlaySimulatorURL)
        actions.openCarPlaySimulator()
        XCTAssertEqual(opened, 0)
    }

    /// Device Hub's sysdiagnose save panel: its message and button.
    func testTheSysdiagnosePanelSaysWhatDeviceHubSays() {
        XCTAssertEqual(PhysicalDeviceActions.sysdiagnosePanelMessage, "Choose a location to save the sysdiagnose.")
        XCTAssertEqual(PhysicalDeviceActions.sysdiagnosePanelPrompt, "Select")
    }

    func testTheRowSubtitleFollowsTheOperation() throws {
        let entry = try PhysicalFixtures.entry()
        XCTAssertEqual(DeviceSidebarView.physicalSubtitle(entry, operation: .collecting), "Collecting sysdiagnose...")
        XCTAssertEqual(DeviceSidebarView.physicalSubtitle(entry, operation: .renaming), "iPhone 12")
        var restarting = entry
        restarting.isRestarting = true
        XCTAssertEqual(DeviceSidebarView.physicalSubtitle(restarting, operation: nil), "Restarting\u{2026}")
        XCTAssertFalse(restarting.canUseClient)
        XCTAssertEqual(restarting.state, .restarting)
    }

    func testTheDeviceFolderPrefersItsOwnCrashReportFolder() {
        let own = home.appendingPathComponent("Library/Logs/CrashReporter/MobileDevice/Test Phone")
        let parent = own.deletingLastPathComponent()
        XCTAssertEqual(PhysicalDeviceFolder.locate(deviceName: "Test Phone", home: home, exists: { _ in true })?.path, own.path)
        XCTAssertEqual(PhysicalDeviceFolder.locate(deviceName: "Test Phone", home: home, exists: { $0.path == parent.path })?.path, parent.path)
        XCTAssertNil(PhysicalDeviceFolder.locate(deviceName: "Test Phone", home: home, exists: { _ in false }))
    }

    func testADeviceNameWithASlashIsNotAPathComponent() {
        let url = PhysicalDeviceFolder.locate(deviceName: "A/B", home: home, exists: { $0.lastPathComponent == "A-B" })
        XCTAssertEqual(url?.lastPathComponent, "A-B")
    }

    func testTheConfirmationsNameTheDeviceAndAreDestructiveAlerts() {
        let restart = PhysicalDeviceActions.Confirmation.restartApple(udid: "U", name: "Test Phone")
        XCTAssertEqual(restart.title, "Restart Test Phone?")
        XCTAssertEqual(restart.alertSpec.confirmTitle, "Restart")
        XCTAssertEqual(restart.alertSpec.style, .destructive)
        let unpair = PhysicalDeviceActions.Confirmation.unpairApple(udid: "U", name: "Test Phone")
        XCTAssertEqual(unpair.title, "Unpair Test Phone?")
        XCTAssertEqual(unpair.alertSpec.confirmTitle, "Unpair")
        let disconnect = PhysicalDeviceActions.Confirmation.disconnectAndroid(serial: "S", name: "Pixel")
        XCTAssertEqual(disconnect.alertSpec.confirmTitle, "Disconnect")
    }
}
