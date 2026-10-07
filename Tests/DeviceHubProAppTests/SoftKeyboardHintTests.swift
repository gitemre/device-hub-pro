import XCTest
@testable import DeviceHubProApp

@MainActor
final class SoftKeyboardHintTests: XCTestCase {
    func testShowsOnlyWhenCaptureTurnedOffOnAnEmulatorFirstTime() {
        XCTAssertTrue(SoftKeyboardHint.shouldShow(captureEnabled: false, serial: "emulator-5554", alreadyShown: false))
        XCTAssertFalse(SoftKeyboardHint.shouldShow(captureEnabled: true, serial: "emulator-5554", alreadyShown: false))
        XCTAssertFalse(SoftKeyboardHint.shouldShow(captureEnabled: false, serial: "emulator-5554", alreadyShown: true))
    }

    func testNeverForPhonesIOSOrNoDevice() {
        XCTAssertFalse(SoftKeyboardHint.shouldShow(captureEnabled: false, serial: "R5CT1234", alreadyShown: false))
        XCTAssertFalse(SoftKeyboardHint.shouldShow(captureEnabled: false, serial: "A1B2C3D4-0000", alreadyShown: false))
        XCTAssertFalse(SoftKeyboardHint.shouldShow(captureEnabled: false, serial: nil, alreadyShown: false))
    }

    func testTooltipSuffixOnlyForEmulatorWithCaptureOff() {
        let base = "Capture Keyboard"
        XCTAssertTrue(SoftKeyboardHint.tooltip(base: base, captureEnabled: false, serial: "emulator-5554")
            .hasSuffix("Show on-screen keyboard (Alt+K)"))
        XCTAssertEqual(SoftKeyboardHint.tooltip(base: base, captureEnabled: true, serial: "emulator-5554"), base)
        XCTAssertEqual(SoftKeyboardHint.tooltip(base: base, captureEnabled: false, serial: "R5CT1234"), base)
        XCTAssertEqual(SoftKeyboardHint.tooltip(base: base, captureEnabled: false, serial: nil), base)
    }

    func testShownFlagIsPersistedOnce() {
        let defaults = UserDefaults.scratch()
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.softKeyboardHintShown)
        preferences.markSoftKeyboardHintShown()
        XCTAssertTrue(AppPreferences(defaults: defaults).softKeyboardHintShown)
    }
}
