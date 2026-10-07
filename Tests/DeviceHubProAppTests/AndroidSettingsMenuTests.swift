import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// The Device menu's Android settings block (every
/// setting the Controls panel offers is also in the menu): which items a device
/// shows (the panel's own table, an item that cannot work is not listed), what
/// the steps and toggles write, and that the items act on the window's own tab.
@MainActor
final class AndroidSettingsMenuTests: XCTestCase {
    /// Every probe answered: a phone on an emulator build with TalkBack and a status bar.
    private func fullAvailability(emulator: Bool = true) -> ControlsGroupAvailability {
        var available = ControlsGroupAvailability()
        available.canUseEmulatorControls = emulator
        available.appearance = true
        available.textSize = true
        available.reduceMotion = true
        available.increaseContrast = true
        available.showBorders = true
        available.talkBack = true
        available.sound = true
        available.deviceLanguage = true
        available.timeZone = true
        available.timeFormat24 = true
        available.statusBar = true
        available.appConditions = true
        available.lowMemory = true
        return available
    }

    private func plan(
        _ family: ControlsFamily = .androidHandheld,
        _ available: ControlsGroupAvailability? = nil,
        running: Bool = true
    ) -> AndroidSettingsMenuPlan {
        AndroidSettingsMenuPlan(family: family, availability: available ?? fullAvailability(), isRunning: running)
    }

    // MARK: - Which items a device shows

    func testAnEmulatorPhoneShowsTheWholeBlock() {
        let plan = plan()
        XCTAssertEqual(plan.accessibilityGroups, [
            [.reduceMotion, .increaseContrast, .showBorders], [.textSize], [.talkBack],
        ])
        XCTAssertTrue(plan.showsAppearance)
        XCTAssertTrue(plan.showsLocation)
        XCTAssertTrue(plan.showsSound)
        XCTAssertTrue(plan.showsLanguage)
        XCTAssertTrue(plan.showsTimeFormat24)
        XCTAssertTrue(plan.showsTimeZone)
        XCTAssertTrue(plan.showsCleanStatusBar)
        XCTAssertTrue(plan.showsAnything)
    }

    /// A phone has no emulator console: no Location (the panel's Location group is gRPC-only).
    func testAPhysicalPhoneHasNoLocation() {
        let plan = plan(.androidHandheld, fullAvailability(emulator: false))
        XCTAssertFalse(plan.showsLocation)
        XCTAssertTrue(plan.showsAppearance)
        XCTAssertTrue(plan.showsSound)
    }

    func testAWatchHasNoAppearanceNoStatusBarAndNoDarkLightChoice() {
        let plan = plan(.androidWear)
        XCTAssertFalse(plan.showsAppearance, "Wear OS is always dark")
        XCTAssertFalse(plan.showsCleanStatusBar, "Wear OS has no status bar")
        XCTAssertTrue(plan.showsLocation)
        XCTAssertTrue(plan.showsAccessibility)
    }

    func testATVHasNoStatusBarButKeepsItsAppearanceAndLanguage() {
        let plan = plan(.androidTV)
        XCTAssertFalse(plan.showsCleanStatusBar)
        XCTAssertTrue(plan.showsAppearance)
        XCTAssertTrue(plan.showsLanguageMenu)
    }

    func testAutomotiveKeepsTheStatusBar() {
        XCTAssertTrue(plan(.androidAutomotive).showsCleanStatusBar)
    }

    /// TalkBack needs the package; without it the item is gone, and so is its (own) group.
    func testWithoutTalkBackTheItemAndItsGroupAreGone() {
        var available = fullAvailability()
        available.talkBack = false
        XCTAssertEqual(plan(.androidHandheld, available).accessibilityGroups, [
            [.reduceMotion, .increaseContrast, .showBorders], [.textSize],
        ])
    }

    /// An image whose Settings cannot change the language (a Play Store image) still has the 24-hour toggle.
    func testTheLanguageMenuNeedsEitherItsLocalesOrTheClock() {
        var available = fullAvailability()
        available.deviceLanguage = false
        let clockOnly = plan(.androidHandheld, available)
        XCTAssertFalse(clockOnly.showsLanguage)
        XCTAssertTrue(clockOnly.showsLanguageMenu)
        available.timeFormat24 = false
        XCTAssertFalse(plan(.androidHandheld, available).showsLanguageMenu)
    }

    func testAnUnreadDeviceListsNothingAProbeCouldTakeAway() {
        let phone = AndroidSettingsMenuPlan.unread(family: .androidHandheld, isEmulator: false, isRunning: true)
        XCTAssertTrue(phone.showsAppearance)
        XCTAssertTrue(phone.showsSound)
        XCTAssertTrue(phone.showsLanguage)
        XCTAssertTrue(phone.showsTimeFormat24)
        XCTAssertTrue(phone.showsTimeZone)
        XCTAssertEqual(phone.accessibilityGroups, [[.reduceMotion, .increaseContrast, .showBorders], [.textSize]])
        XCTAssertFalse(phone.showsLocation, "no console, no location")
        XCTAssertFalse(phone.showsCleanStatusBar, "needs its read")
        XCTAssertTrue(AndroidSettingsMenuPlan.unread(family: .androidHandheld, isEmulator: true, isRunning: true).showsLocation)
    }

    /// An AVD that is off keeps its items, off (as the simulator block does); a family keeps its rules.
    func testAStoppedAVDKeepsItsItemsByItsClass() {
        let phone = AndroidSettingsMenuPlan.unread(family: .androidHandheld, isEmulator: true, isRunning: false)
        XCTAssertFalse(phone.isRunning)
        XCTAssertTrue(phone.showsAnything)
        XCTAssertTrue(phone.showsAppearance)
        let watch = AndroidSettingsMenuPlan.unread(family: .androidWear, isEmulator: true, isRunning: false)
        XCTAssertFalse(watch.showsAppearance)
    }

    func testMakeUsesThePanelsFlagsOnceItHasRead() {
        var read = ControlsGroupAvailability()
        read.appearance = true
        let made = AndroidSettingsMenuPlan.make(family: .androidHandheld, readAvailability: read, isEmulator: true, isRunning: true)
        XCTAssertTrue(made.showsAppearance)
        XCTAssertFalse(made.showsSound, "the read said no Sound row")
        XCTAssertFalse(made.showsLocation, "the read said no emulator")
        let unread = AndroidSettingsMenuPlan.make(family: .androidHandheld, readAvailability: nil, isEmulator: true, isRunning: true)
        XCTAssertTrue(unread.showsSound)
    }

    func testNothingReadMeansNoBlock() {
        XCTAssertFalse(plan(.androidHandheld, ControlsGroupAvailability()).showsAnything)
    }

    /// Whatever the plan shows, the panel lists: one table decides both.
    func testEveryItemIsARowOfThePanel() {
        for family in ControlsFamily.allCases where family.platform == .android {
            let plan = plan(family)
            let panel = Set(
                controlsGroups(fullAvailability(), family: family).flatMap(\.rows)
                    + controlsTrailingRows(fullAvailability(), family: family)
            )
            XCTAssertTrue(plan.rows.isSubset(of: panel), "\(family)")
            XCTAssertEqual(plan.showsAppearance, panel.contains(.appearance), "\(family)")
            XCTAssertEqual(plan.showsCleanStatusBar, panel.contains(.cleanStatusBar), "\(family)")
            XCTAssertEqual(plan.showsLocation, panel.contains(.location), "\(family)")
        }
    }

    // MARK: - Steps

    func testTextSizeStepsThroughTheRowsList() {
        let classic = FontScaleStep.classicSteps
        XCTAssertEqual(AndroidSettingsMenuPlan.steppedTextSize(current: 1.0, steps: classic, by: 1), .large)
        XCTAssertEqual(AndroidSettingsMenuPlan.steppedTextSize(current: 1.0, steps: classic, by: -1), .small)
        XCTAssertNil(AndroidSettingsMenuPlan.steppedTextSize(current: 1.3, steps: classic, by: 1), "the largest classic step ends the list")
        XCTAssertNil(AndroidSettingsMenuPlan.steppedTextSize(current: 0.85, steps: classic, by: -1))
        XCTAssertEqual(AndroidSettingsMenuPlan.steppedTextSize(current: 1.3, steps: FontScaleStep.allCases, by: 1), .percent150, "API 34 lists seven")
        XCTAssertEqual(AndroidSettingsMenuPlan.steppedTextSize(current: nil, steps: classic, by: 1), .large, "an unset scale is the default")
    }

    func testVolumeStepsOneIndexAndStopsAtTheEnds() {
        let reading = MediaVolumeReading(index: 5, minimum: 0, maximum: 15)
        XCTAssertEqual(AndroidSettingsMenuPlan.steppedVolume(reading, by: 1), 6)
        XCTAssertEqual(AndroidSettingsMenuPlan.steppedVolume(reading, by: -1), 4)
        XCTAssertNil(AndroidSettingsMenuPlan.steppedVolume(MediaVolumeReading(index: 15, minimum: 0, maximum: 15), by: 1))
        XCTAssertNil(AndroidSettingsMenuPlan.steppedVolume(MediaVolumeReading(index: 0, minimum: 0, maximum: 15), by: -1))
    }

    func testToggleAppearanceFlipsToDarkUnlessDark() {
        XCTAssertEqual(AndroidSettingsMenuPlan.toggledAppearance(from: .mode(.dark)), .light)
        XCTAssertEqual(AndroidSettingsMenuPlan.toggledAppearance(from: .mode(.light)), .dark)
        XCTAssertEqual(AndroidSettingsMenuPlan.toggledAppearance(from: .mode(.system)), .dark)
        XCTAssertEqual(AndroidSettingsMenuPlan.toggledAppearance(from: nil), .dark)
    }

    func testTheClockToggleWritesTwentyFourOrTwelve() {
        XCTAssertEqual(AndroidSettingsMenuPlan.timeFormat(is24Hour: true), .twentyFourHour)
        XCTAssertEqual(AndroidSettingsMenuPlan.timeFormat(is24Hour: false), .twelveHour)
    }

    // MARK: - Simulate Low Memory in the Controls menu

    func testLowMemoryIsListedWhereThePanelListsItsRow() {
        XCTAssertTrue(AndroidLowMemoryMenu.isShown(family: .androidHandheld, showsAppConditions: true, showsLowMemory: true))
        XCTAssertFalse(AndroidLowMemoryMenu.isShown(family: .androidHandheld, showsAppConditions: false, showsLowMemory: true))
        XCTAssertFalse(AndroidLowMemoryMenu.isShown(family: .androidHandheld, showsAppConditions: true, showsLowMemory: false), "API below 23")
    }

    func testLowMemoryIsOffUntilAnAppIsChosenAndTheDeviceAcceptsTheLevel() {
        XCTAssertFalse(AndroidLowMemoryMenu.isEnabled(targetPackage: nil, gate: .allowed, isWriting: false))
        XCTAssertFalse(AndroidLowMemoryMenu.isEnabled(targetPackage: "com.example", gate: nil, isWriting: false))
        XCTAssertFalse(AndroidLowMemoryMenu.isEnabled(targetPackage: "com.example", gate: .notRunning, isWriting: false))
        XCTAssertFalse(AndroidLowMemoryMenu.isEnabled(targetPackage: "com.example", gate: .allowed, isWriting: true))
        XCTAssertTrue(AndroidLowMemoryMenu.isEnabled(targetPackage: "com.example", gate: .allowed, isWriting: false))
    }

    // MARK: - The items act on their own tab

    private func twoTabs(adb: AdbClient) -> (tabA: DeviceWorkspace, tabB: DeviceWorkspace) {
        let model = AppModel.testing(adb: adb)
        let tabA = model.workspace
        let tabB = DeviceWorkspace(services: model.services)
        model.registry.register(tabB)
        model.registry.focusedID = tabB.id
        tabA.beginMirrorSession(
            FakeMirrorSession(), device: .android("emulator-5554"), port: nil,
            avdName: "Pixel_A", capabilities: .android(emulatorGrpc: true)
        )
        tabB.beginMirrorSession(
            FakeMirrorSession(), device: .android("emulator-5556"), port: nil,
            avdName: "Pixel_B", capabilities: .android(emulatorGrpc: true)
        )
        return (tabA, tabB)
    }

    /// With a second tab focused, a menu item reaches that tab's device and
    /// leaves the first tab's alone (the menus read the model's facade, the
    /// first window's workspace, before the fix).
    func testAnItemActsOnTheWorkspaceItWasGiven() async throws {
        let stub = try makeStubAdb(arms: "  *shell*) exit 0 ;;")
        let (_, tabB) = twoTabs(adb: stub.client)

        await AndroidSettingsMenuActions(workspace: tabB).setShowBorders(true)

        XCTAssertFalse(stub.calls.isEmpty, "the write reached adb")
        XCTAssertTrue(stub.calls.allSatisfy { $0.contains("-s emulator-5556") }, "\(stub.calls)")
    }

    /// A switch item flips the device's fresh reading, not the menu's shown
    /// one: with the panel hidden its reading was unread or stale, and a click
    /// on a Reduce Motion that was on wrote "on" again.
    func testASwitchItemPollsThenWritesTheOppositeOfTheFreshReading() async throws {
        let stub = try makeStubAdb(arms: "  *shell*) exit 0 ;;")
        let (_, tabB) = twoTabs(adb: stub.client)
        let actions = AndroidSettingsMenuActions(workspace: tabB)
        var written: [Bool] = []

        await actions.toggle({ _ in true }) { _, on in written.append(on) }
        await actions.toggle({ _ in nil }) { _, on in written.append(on) }

        XCTAssertEqual(written, [false, true], "on reads back off; unknown turns on")
        XCTAssertFalse(stub.calls.isEmpty, "it polled the device first")
        XCTAssertTrue(stub.calls.allSatisfy { $0.contains("-s emulator-5556") }, "\(stub.calls)")
    }

    /// Toggle Appearance reads the panel first (its poll runs only while the panel shows), then writes.
    func testToggleAppearanceWritesToItsOwnTab() async throws {
        let stub = try makeStubAdb(arms: "  *shell*) exit 0 ;;")
        let (_, tabB) = twoTabs(adb: stub.client)

        await AndroidSettingsMenuActions(workspace: tabB).toggleAppearance()

        let writes = stub.calls(containing: "uimode")
        XCTAssertFalse(writes.isEmpty, "Toggle Appearance wrote")
        XCTAssertTrue(writes.allSatisfy { $0.contains("-s emulator-5556") }, "\(writes)")
        XCTAssertTrue(stub.calls.allSatisfy { !$0.contains("emulator-5554") }, "tab A is untouched: \(stub.calls)")
    }
}
