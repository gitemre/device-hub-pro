import XCTest
@testable import DeviceHubProApp

/// The toolbar's "..." per-device menu: its enablement,
/// independent of SwiftUI.
final class ToolbarDeviceMenuTests: XCTestCase {
    // MARK: - AVD

    func testAStoppedAVDOffersStartAndTheFileActions() {
        let section = ToolbarDeviceMenu.avdSection(isRunning: false, isBusy: false)
        XCTAssertEqual(section.lifecycle, .init(title: "Start", isEnabled: true))
        XCTAssertEqual(section.showInFinder, .init(title: "Show in Finder"))
        XCTAssertEqual(section.rename, .init(title: "Rename…", isEnabled: true))
        XCTAssertEqual(section.reset, .init(title: "Reset Content and Settings…", isEnabled: true))
        XCTAssertEqual(section.remove, .init(title: "Remove…", isEnabled: true))
    }

    func testARunningAVDOffersShutDownAndTurnsOffTheFileActions() {
        let section = ToolbarDeviceMenu.avdSection(isRunning: true, isBusy: false)
        XCTAssertEqual(section.lifecycle, .init(title: "Shut Down", isEnabled: true))
        XCTAssertFalse(section.rename!.isEnabled)
        XCTAssertFalse(section.reset!.isEnabled)
        XCTAssertFalse(section.remove!.isEnabled)
        // Show in Finder needs no running check.
        XCTAssertTrue(section.showInFinder!.isEnabled)
    }

    func testAStartAlreadyInFlightForAnotherAVDTurnsOffStart() {
        let section = ToolbarDeviceMenu.avdSection(isRunning: false, isBusy: true)
        XCTAssertEqual(section.lifecycle!.title, "Start")
        XCTAssertFalse(section.lifecycle!.isEnabled)
    }

    func testABusyStateNeverTurnsOffShutDownOnARunningAVD() {
        let section = ToolbarDeviceMenu.avdSection(isRunning: true, isBusy: true)
        XCTAssertEqual(section.lifecycle, .init(title: "Shut Down", isEnabled: true))
    }

    // MARK: - Simulator

    func testAStoppedAvailableSimulatorOffersEverything() {
        let section = ToolbarDeviceMenu.simulatorSection(isRunning: false, isFree: true, isAvailable: true)
        XCTAssertEqual(section.lifecycle, .init(title: "Start", isEnabled: true))
        XCTAssertTrue(section.rename!.isEnabled)
        XCTAssertTrue(section.reset!.isEnabled)
        XCTAssertTrue(section.remove!.isEnabled)
    }

    func testAnUnavailableRuntimeListsNeitherStartNorReset() {
        let section = ToolbarDeviceMenu.simulatorSection(isRunning: false, isFree: true, isAvailable: false)
        XCTAssertNil(section.lifecycle, "Start needs the runtime: not listed")
        XCTAssertNil(section.reset, "nothing to reset without the runtime: not listed")
        // Rename and remove still work on an uninstalled-runtime simulator.
        XCTAssertTrue(section.rename!.isEnabled)
        XCTAssertTrue(section.remove!.isEnabled)
        XCTAssertFalse(section.isEmpty)
    }

    func testARunningSimulatorOffersShutDownAndKeepsFileActionsOnWhileFree() {
        let section = ToolbarDeviceMenu.simulatorSection(isRunning: true, isFree: true, isAvailable: true)
        XCTAssertEqual(section.lifecycle, .init(title: "Shut Down", isEnabled: true))
        XCTAssertTrue(section.rename!.isEnabled)
        XCTAssertTrue(section.reset!.isEnabled)
        XCTAssertTrue(section.remove!.isEnabled)
    }

    /// Measured live against Device Hub 27.0 (a running simulator): Shut
    /// Down │ Restart │ Show in Finder, Rename… │ Reset… │ Remove…, every
    /// item enabled. The stopped menu has no Restart.
    func testARunningSimulatorHasARestartOfItsOwnAStoppedOneHasNone() {
        let running = ToolbarDeviceMenu.simulatorSection(isRunning: true, isFree: true, isAvailable: true)
        XCTAssertEqual(running.restart, .init(title: "Restart", isEnabled: true))
        let stopped = ToolbarDeviceMenu.simulatorSection(isRunning: false, isFree: true, isAvailable: true)
        XCTAssertNil(stopped.restart)
        let busy = ToolbarDeviceMenu.simulatorSection(isRunning: true, isFree: false, isAvailable: true)
        XCTAssertEqual(busy.restart, .init(title: "Restart", isEnabled: false))
    }

    func testNoOtherMenuOffersARestart() {
        XCTAssertNil(ToolbarDeviceMenu.avdSection(isRunning: true, isBusy: false).restart)
        XCTAssertNil(ToolbarDeviceMenu.Section.unavailable.restart)
    }

    func testAnOperationInFlightTurnsOffShutDownAndTheFileActions() {
        let section = ToolbarDeviceMenu.simulatorSection(isRunning: true, isFree: false, isAvailable: true)
        XCTAssertFalse(section.lifecycle!.isEnabled, "a boot waiting to be interrupted is the only free case")
        XCTAssertFalse(section.rename!.isEnabled)
        XCTAssertFalse(section.reset!.isEnabled)
        XCTAssertFalse(section.remove!.isEnabled)
    }

    // MARK: - Unavailable (physical device, unprovisioned Pixel, no selection)

    /// Nothing that cannot work is shown, so the menu is empty
    /// (and the "..." button is not drawn) for these selections.
    func testUnavailableListsNoItem() {
        let section = ToolbarDeviceMenu.Section.unavailable
        XCTAssertTrue(section.isEmpty)
        for item in [section.lifecycle, section.restart, section.showInFinder, section.rename, section.reset, section.remove] {
            XCTAssertNil(item)
        }
    }
}
