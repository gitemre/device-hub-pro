import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// The Device, Controls and "..." menus of a selected physical iPhone
/// (`PhysicalDeviceMenus.swift`): Device Hub's structure for the phone with
/// only the items the app can carry out. The views render from
/// `PhysicalMenuLayout`, so these read exactly what the menus list; the
/// SwiftUI wiring is checked live (the parity audit).
final class PhysicalDeviceMenuTests: XCTestCase {
    private func titles<Entry>(_ entries: [Entry], _ title: (Entry) -> String?) -> [String] {
        entries.compactMap(title)
    }

    // MARK: - Layout kind

    func testAPhysicalPhoneUsesItsOwnMenus() {
        let layout = DeviceMenuLayout(selection: .physicalApple("UDID"), isRunning: false)
        XCTAssertEqual(layout.kind, .physicalApple)
        XCTAssertTrue(layout.usesPhysicalMenus)
        XCTAssertFalse(layout.hasLifecycle)
        for selection in [DeviceSelection.simulator("U"), .avd("A"), .device("d"), .pixel("P"), nil] {
            XCTAssertFalse(DeviceMenuLayout(selection: selection, isRunning: true).usesPhysicalMenus)
        }
    }

    // MARK: - Device menu

    func testTheDeviceMenuIsDeviceHubsStructureThenOurToggles() {
        let entries = PhysicalMenuLayout.deviceEntries
        XCTAssertEqual(
            titles(entries, \.title),
            [
                "Accessibility", "Appearance", "Location", "Keyboard", "Open URL…",
                "Live View", "Auto-refresh Screenshots", "Control This iPhone", "Mute iPhone Audio",
            ]
        )
        XCTAssertEqual(entries.first, .accessibility)
        XCTAssertNotEqual(entries.last, .separator)
        // No two rules in a row, none at the ends.
        XCTAssertNotEqual(entries.first, .separator)
        for pair in zip(entries, entries.dropFirst()) {
            XCTAssertFalse(pair.0 == .separator && pair.1 == .separator)
        }
    }

    func testTheDeviceMenuHasNothingItCannotDo() {
        let all = titles(PhysicalMenuLayout.deviceEntries, \.title)
        for absent in ["Start", "Restart", "Shut Down", "Force Shut Down", "Reset Content and Settings…",
                       "Battery", "Face ID", "Touch ID", "Optic ID", "Sound", "Orientation", "CarPlay Simulator",
                       "Lock", "Rename…", "Show in Finder", "Unpair…", "Collect sysdiagnose…"] {
            XCTAssertFalse(all.contains(absent), absent)
        }
    }

    func testMuteIsOnlyEnabledWithAudio() {
        XCTAssertTrue(PhysicalMenuLayout.muteAudioEnabled(hasAudio: true))
        XCTAssertFalse(PhysicalMenuLayout.muteAudioEnabled(hasAudio: false))
    }

    // MARK: - Controls menu

    func testTheControlsMenuIsDeviceHubsLessLockAndActionButton() {
        XCTAssertEqual(
            titles(PhysicalMenuLayout.controlsEntries, \.title),
            ["Home", "Siri", "App Switcher", "Rotate Left", "Rotate Right", "Screenshot", "Record Screen"]
        )
        let all = titles(PhysicalMenuLayout.controlsEntries, \.title)
        for absent in ["Lock", "Action Button", "Volume Up", "Volume Down"] {
            XCTAssertFalse(all.contains(absent), absent)
        }
    }

    func testThePressesFollowControlAvailabilityAndSayWhy() {
        let presses: [PhysicalMenuLayout.ControlsEntry] = [.home, .siri, .appSwitcher, .rotateLeft, .rotateRight]
        for entry in presses {
            XCTAssertTrue(entry.isEnabled(controlAvailability: nil, canTakeScreenshot: false), entry.title ?? "")
            XCTAssertNil(entry.help(controlAvailability: nil))
            let reason = "Set your Development Team ID in Settings."
            XCTAssertFalse(entry.isEnabled(controlAvailability: reason, canTakeScreenshot: true), entry.title ?? "")
            XCTAssertEqual(entry.help(controlAvailability: reason), reason)
        }
    }

    func testScreenshotNeedsAPictureNotControlAndRecordFollowsTheLiveCapture() {
        let reason = "No Development Team ID."
        XCTAssertTrue(PhysicalMenuLayout.ControlsEntry.screenshot.isEnabled(controlAvailability: reason, canTakeScreenshot: true))
        XCTAssertFalse(PhysicalMenuLayout.ControlsEntry.screenshot.isEnabled(controlAvailability: nil, canTakeScreenshot: false))
        for control: String? in [nil, "reason"] {
            XCTAssertFalse(PhysicalMenuLayout.ControlsEntry.recordScreen.isEnabled(controlAvailability: control, canTakeScreenshot: true))
            XCTAssertTrue(PhysicalMenuLayout.ControlsEntry.recordScreen.isEnabled(controlAvailability: control, canTakeScreenshot: false, canRecord: true))
        }
    }

    // MARK: - "..." menu

    func testTheMoreMenuIsStopScreenSharingAloneWithoutMultiWindow() {
        let entries = PhysicalMenuLayout.moreEntries(canUseClient: true, liveViewOn: true, multiWindow: false)
        XCTAssertEqual(entries, [.stopScreenSharing(isEnabled: true)])
        XCTAssertEqual(titles(entries, \.title), ["Stop Screen Sharing"])
    }

    func testTheMoreMenuAddsTheOpenPairOnlyWithMultiWindow() {
        let entries = PhysicalMenuLayout.moreEntries(canUseClient: true, liveViewOn: true, multiWindow: true)
        XCTAssertEqual(
            titles(entries, \.title),
            ["Stop Screen Sharing", "Open in New Tab", "Open in New Window"]
        )
        XCTAssertEqual(entries[1], .separator)
    }

    func testStopScreenSharingNeedsAUsableDeviceSharingItsScreen() {
        XCTAssertEqual(
            PhysicalMenuLayout.moreEntries(canUseClient: false, liveViewOn: true, multiWindow: false),
            [.stopScreenSharing(isEnabled: false)]
        )
        XCTAssertEqual(
            PhysicalMenuLayout.moreEntries(canUseClient: true, liveViewOn: false, multiWindow: false),
            [.stopScreenSharing(isEnabled: false)]
        )
    }

    func testTheMoreMenuHasNoSimulatorOnlyItems() {
        let all = titles(
            PhysicalMenuLayout.moreEntries(canUseClient: true, liveViewOn: true, multiWindow: true), \.title
        )
        for absent in ["Start", "Shut Down", "Restart", "Show in Finder", "Rename…", "Reset Content and Settings…",
                       "Remove…", "Unpair…", "CarPlay Simulator", "Collect sysdiagnose…"] {
            XCTAssertFalse(all.contains(absent), absent)
        }
    }
}
