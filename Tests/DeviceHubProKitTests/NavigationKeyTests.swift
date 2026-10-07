import XCTest
@testable import DeviceHubProKit

/// The navigation keys behind the stage's Back / Home / Recents bar. The
/// key codes are SOURCE-DERIVED: Android's from AOSP
/// `frameworks/base/core/java/android/view/KeyEvent.java` (BACK 4, HOME 3,
/// APP_SWITCH 187). The emulator takes the W3C key names (GoBack, GoHome,
/// AppSwitch), checked live against an API 35 emulator on 2026-10-01 by
/// `NavigationKeyLiveTests`.
final class NavigationKeyTests: XCTestCase {
    func testKeyCodes() {
        XCTAssertEqual(NavigationKey.allCases, [.back, .home, .recents])
        XCTAssertEqual(NavigationKey.allCases.map(\.androidKeyCode), [4, 3, 187])
        XCTAssertEqual(NavigationKey.allCases.map(\.w3cKey), ["GoBack", "GoHome", "AppSwitch"])
    }

    func testAdbFallbackNamesTheSerialAndTheAndroidKeyCode() {
        XCTAssertEqual(
            NavigationKey.recents.adbArguments(serial: "emulator-5554"),
            ["-s", "emulator-5554", "shell", "input", "keyevent", "187"]
        )
    }

    func testTheEmulatorRequestIsOneEvdevKeypress() {
        let request = NavigationKey.keyboardEvent(for: .home)
        XCTAssertEqual(request.eventType, .keypress)
        XCTAssertEqual(request.key, "GoHome")
    }

    func testOnlyHandheldsGetTheBar() {
        XCTAssertTrue(NavigationBarRules.appliesTo(.handheld))
        XCTAssertTrue(NavigationBarRules.appliesTo(nil), "a device not read yet is handheld")
        for other: SystemImage.FormFactor in [.wear, .tv, .automotive, .desktop, .xr] {
            XCTAssertFalse(NavigationBarRules.appliesTo(other), "\(other)")
        }
    }
}
