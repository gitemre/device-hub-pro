import XCTest
import SwiftUI
@testable import DeviceHubProApp
import DeviceHubProKit

/// When the stage's navigation bar shows, what it says, and its preference.
@MainActor
final class NavigationButtonBarTests: XCTestCase {
    func testShownForAnAndroidHandheldWhileThePreferenceIsOn() {
        let phone = DeviceRef.android("emulator-5554")
        XCTAssertTrue(NavigationBarSpec.isShown(preference: true, device: phone, formFactor: .handheld))
        XCTAssertTrue(NavigationBarSpec.isShown(preference: true, device: phone, formFactor: nil))
        XCTAssertFalse(NavigationBarSpec.isShown(preference: false, device: phone, formFactor: .handheld))
    }

    func testNotShownForWearTvAutomotiveOrApple() {
        let device = DeviceRef.android("emulator-5554")
        for factor: SystemImage.FormFactor in [.wear, .tv, .automotive, .desktop, .xr] {
            XCTAssertFalse(NavigationBarSpec.isShown(preference: true, device: device, formFactor: factor), "\(factor)")
        }
        XCTAssertFalse(NavigationBarSpec.isShown(preference: true, device: .apple("UDID"), formFactor: .handheld))
        XCTAssertFalse(NavigationBarSpec.isShown(preference: true, device: nil, formFactor: .handheld))
    }

    func testTitlesAndToolTipsNameTheShortcuts() {
        XCTAssertEqual(NavigationKey.allCases.map(NavigationBarSpec.title(for:)), ["Back", "Home", "Recents"])
        XCTAssertEqual(NavigationBarSpec.toolTip(for: .back), "Back (\u{2318}[)")
        XCTAssertEqual(NavigationBarSpec.toolTip(for: .home), "Home (\u{21E7}\u{2318}H)")
        XCTAssertTrue(NavigationBarSpec.toolTip(for: .recents).hasSuffix("(\u{2318}])"))
    }

    func testThePreferenceIsOnByDefaultAndPersists() {
        let defaults = UserDefaults.scratch()
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.showNavigationButtons)
        XCTAssertNil(defaults.object(forKey: "showNavigationButtons"))
        preferences.setShowNavigationButtons(false)
        XCTAssertEqual(defaults.object(forKey: "showNavigationButtons") as? Bool, false)
        XCTAssertFalse(AppPreferences(defaults: defaults).showNavigationButtons)
    }
}

/// Renders the bar to PNGs for a look at it (no assertions beyond the file
/// being written): `DHP_NAV_RENDER_DIR=<dir>` turns it on.
@MainActor
final class NavigationButtonBarRenderTests: XCTestCase {
    func testRenderBarAtSeveralScalesInBothAppearances() throws {
        guard let directory = ProcessInfo.processInfo.environment["DHP_NAV_RENDER_DIR"] else {
            throw XCTSkip("set DHP_NAV_RENDER_DIR to render the bar")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            for scale in [1.0, 2.0, 3.0] {
                let view = NavigationButtonBar(press: { _ in }, rendersStatically: true)
                    .padding(24)
                    .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96))
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = scale
                let image = try XCTUnwrap(renderer.nsImage)
                let tiff = try XCTUnwrap(image.tiffRepresentation)
                let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory + "/nav-bar-\(name)-\(Int(scale))x.png"))
            }
        }
    }
}
