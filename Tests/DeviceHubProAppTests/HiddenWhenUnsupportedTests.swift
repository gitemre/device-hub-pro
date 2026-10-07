import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// A control or feature that cannot work on the selected
/// device is not shown on it (no disabled placeholder, no "not available" note).
/// These pin the visibility decisions per device kind; the SwiftUI wiring that
/// renders them is checked live.
final class HiddenWhenUnsupportedTests: XCTestCase {
    // MARK: - Device ▸ Orientation

    /// `.orientation` maps to no Controls row, so the rows table could not answer for it:
    /// every family reported it unavailable, and Device ▸ Orientation went dark on every
    /// simulator once the panel had loaded. Families that turn offer it; the others do not.
    func testOrientationIsOfferedWhereTheDeviceTurns() {
        XCTAssertTrue(ControlsFamily.iPhone.offers(.orientation))
        XCTAssertTrue(ControlsFamily.iPad.offers(.orientation))
        XCTAssertTrue(ControlsFamily.physicalApple.offers(.orientation))
        for family in [ControlsFamily.appleTV, .appleWatch, .appleVision, .androidHandheld, .androidTV] {
            XCTAssertFalse(family.offers(.orientation), family.title)
        }
        XCTAssertNil(ControlsFamily.iPhone.unavailableReason(for: .orientation))
    }

    // MARK: - Simulator settings block per family

    private func plan(_ family: ControlsFamily, running: Bool = true) -> AppleSettingsMenuPlan {
        AppleSettingsMenuPlan(family: family, isRunning: running)
    }

    func testAnIPhoneShowsTheFullSettingsBlockAndOnlyItsOwnBiometric() {
        let plan = plan(.iPhone)
        XCTAssertTrue(plan.showsAccessibility)
        XCTAssertTrue(plan.showsAppearance)
        XCTAssertTrue(plan.showsLocation)
        XCTAssertTrue(plan.showsSound)
        XCTAssertTrue(plan.showsOrientation)
        XCTAssertTrue(plan.showsSampleData)
        XCTAssertTrue(plan.showsStatusBarMenu)
        XCTAssertEqual(plan.biometricMenuTitle, "Face ID", "Face ID until the device type is read")
        var touch = plan
        touch.biometricType = "Touch ID"
        XCTAssertEqual(touch.biometricMenuTitle, "Touch ID")
        var none = plan
        none.supportsBiometrics = false
        XCTAssertNil(none.biometricMenuTitle)
        XCTAssertEqual(plan.accessibilityGroups.count, 3)
    }

    func testAStoppedSimulatorKeepsItsItemsButNotOrientation() {
        let stopped = plan(.iPhone, running: false)
        XCTAssertTrue(stopped.showsAccessibility)
        XCTAssertFalse(stopped.showsOrientation, "Device Hub hides Orientation while the simulator is off")
    }

    /// Language ▸ 24-hour time is the panel's 24-hour row: listed where the panel lists it, and only while the route offers it.
    func testTheTwentyFourHourToggleFollowsThePanelsRow() {
        XCTAssertTrue(plan(.iPhone).showsTimeFormat24)
        XCTAssertTrue(plan(.iPad).showsTimeFormat24)
        XCTAssertFalse(plan(.appleTV).showsTimeFormat24, "tvOS has no 24-hour row")
        var noRoute = plan(.iPhone)
        noRoute.routeOffers = { $0 != .timeFormat24 }
        XCTAssertFalse(noRoute.showsTimeFormat24)
    }

    /// Measured on tvOS 27.0: no Dynamic Type, no status bar, no Photos or Contacts, no
    /// biometrics, no orientation; Appearance, Increase Contrast, Location and Sound work.
    func testAnAppleTVListsOnlyWhatItWorks() {
        let plan = plan(.appleTV)
        XCTAssertTrue(plan.showsAppearance)
        XCTAssertTrue(plan.showsLocation)
        XCTAssertTrue(plan.showsSound)
        XCTAssertEqual(plan.accessibilityGroups, [[.increaseContrast]])
        XCTAssertFalse(plan.showsStatusBarMenu)
        XCTAssertFalse(plan.showsSampleData)
        XCTAssertNil(plan.biometricMenuTitle)
        XCTAssertFalse(plan.showsOrientation)
    }

    func testAWatchOrVisionSimulatorListsNoSettingsAtAll() {
        for family in [ControlsFamily.appleWatch, .appleVision] {
            let plan = plan(family)
            XCTAssertFalse(plan.showsAnything, family.title)
            XCTAssertFalse(plan.showsStatusBarMenu)
            XCTAssertFalse(plan.showsSampleData)
            XCTAssertFalse(family.hasControlsPanel)
        }
    }

    func testAMechanismTheSimulatorLacksHidesItsItem() {
        var plan = plan(.iPhone)
        // No devicectl: Reduce Motion, Show Borders and the like have no route.
        plan.routeOffers = { control in control != .reduceMotion && control != .orientation }
        XCTAssertFalse(plan.accessibilityGroups.flatMap { $0 }.contains(.reduceMotion))
        XCTAssertTrue(plan.accessibilityGroups.flatMap { $0 }.contains(.textSize))
        XCTAssertFalse(plan.showsOrientation)
    }

    func testEveryAccessibilityGroupIsNonEmpty() {
        for family in ControlsFamily.allCases {
            for group in plan(family).accessibilityGroups { XCTAssertFalse(group.isEmpty) }
        }
    }

    // MARK: - Device menu kinds

    func testResetIsOnlyForAnAVDOrAnAvailableSimulator() {
        XCTAssertTrue(DeviceMenuLayout(selection: .avd("A"), isRunning: false).offersReset(simulatorIsAvailable: false))
        XCTAssertTrue(DeviceMenuLayout(selection: .simulator("U"), isRunning: false).offersReset(simulatorIsAvailable: true))
        XCTAssertFalse(DeviceMenuLayout(selection: .simulator("U"), isRunning: false).offersReset(simulatorIsAvailable: false))
        for selection in [DeviceSelection.device("phone"), .pixel("Pixel 9"), .physicalApple("U"), nil] {
            XCTAssertFalse(DeviceMenuLayout(selection: selection, isRunning: true).offersReset(simulatorIsAvailable: true))
        }
    }

    func testSensorsAndSimulateNeedAConsolePort() {
        let running = DeviceMenuLayout(selection: .device("emulator-5554"), isRunning: true)
        XCTAssertTrue(running.offersEmulatorConsoleItems(hasConsolePort: true))
        XCTAssertFalse(running.offersEmulatorConsoleItems(hasConsolePort: false), "a phone has no console")
        let stopped = DeviceMenuLayout(selection: .avd("A"), isRunning: false)
        XCTAssertFalse(stopped.offersEmulatorConsoleItems(hasConsolePort: true))
    }

    func testNoLifecycleKindListsNoPowerItems() {
        for selection in [DeviceSelection.device("phone"), .pixel("Pixel 9"), nil] {
            XCTAssertFalse(DeviceMenuLayout(selection: selection, isRunning: true).hasLifecycle)
        }
    }

    // MARK: - View ▸ Show Navigation Buttons

    func testTheNavigationToggleIsListedOnlyForAnAndroidHandheld() {
        XCTAssertTrue(NavigationBarSpec.offersToggle(family: .androidHandheld))
        for family in ControlsFamily.allCases where family != .androidHandheld {
            XCTAssertFalse(NavigationBarSpec.offersToggle(family: family), family.title)
        }
        XCTAssertFalse(NavigationBarSpec.offersToggle(family: nil))
    }

    // MARK: - Physical iPhone menus

    func testAPhysicalPhoneListsNoResizeModeAndTidiesWhatItDrops() {
        let all = PhysicalMenuLayout.deviceEntries()
        XCTAssertFalse(all.contains { $0.title == "Enter Resize Mode" })
        let bare = PhysicalMenuLayout.deviceEntries(
            showsAccessibility: false, showsAppearance: false, showsLocation: false, hasAudio: false
        )
        XCTAssertEqual(bare.compactMap(\.title), ["Keyboard", "Open URL…", "Live View", "Auto-refresh Screenshots", "Control This iPhone"])
        XCTAssertNotEqual(bare.first, .separator)
        XCTAssertNotEqual(bare.last, .separator)
        for pair in zip(bare, bare.dropFirst()) {
            XCTAssertFalse(pair.0 == .separator && pair.1 == .separator)
        }
    }

    func testMuteIsListedOnlyWhileTheAudioPlays() {
        XCTAssertTrue(PhysicalMenuLayout.deviceEntries(hasAudio: true).contains(.muteAudio))
        XCTAssertFalse(PhysicalMenuLayout.deviceEntries(hasAudio: false).contains(.muteAudio))
    }

    func testRecordScreenIsListedOnlyWithTheUSBCapture() {
        XCTAssertTrue(PhysicalMenuLayout.controlsEntries(showsRecordScreen: true).contains(.recordScreen))
        let without = PhysicalMenuLayout.controlsEntries(showsRecordScreen: false)
        XCTAssertFalse(without.contains(.recordScreen))
        XCTAssertEqual(without.last, .screenshot)
    }

    func testAPhysicalPhonePlanFollowsItsCapabilityRows() {
        let plan = AppleSettingsMenuPlan(family: .physicalApple)
        XCTAssertTrue(plan.showsAppearance)
        XCTAssertTrue(plan.showsLocation)
        // Rows the allowed CoreDevice commands do not reach are never listed.
        XCTAssertFalse(plan.accessibilityGroups.flatMap { $0 }.isEmpty)
        var nothing = plan
        nothing.routeOffers = { _ in false }
        XCTAssertFalse(nothing.showsAccessibility)
        XCTAssertFalse(nothing.showsAppearance)
        XCTAssertFalse(nothing.showsLocation)
    }

    // MARK: - Controls panel rows

    func testTheNetworkBaseRowsFollowTheirReadings() {
        var available = ControlsGroupAvailability()
        let all = controlsGroups(available).first { $0.id == .network }?.rows
        XCTAssertEqual(all, [.wifi, .bluetooth, .airplaneMode, .mobileData])
        available.mobileData = false
        available.bluetooth = false
        XCTAssertEqual(controlsGroups(available).first { $0.id == .network }?.rows, [.wifi, .airplaneMode])
        available.wifi = false
        available.airplaneMode = false
        XCTAssertNil(controlsGroups(available).first { $0.id == .network })
    }
}
