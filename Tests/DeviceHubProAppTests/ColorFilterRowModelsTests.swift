import AppKit
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// What the Color Filter and Color inversion rows say, from the API 37
/// emulator's readings probes (`DeviceHubProKitTests/Fixtures/api37-emulator/
/// color-filters`, byte-exact).
final class ColorFilterRowModelsTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("DeviceHubProKitTests/Fixtures/api37-emulator/color-filters")

    private func readings(_ state: String) throws -> ColorFilterReadings {
        ColorFilterReadings.parse(
            try String(contentsOf: Self.fixtures.appendingPathComponent("readings-probe-\(state).txt"), encoding: .utf8),
            apiLevel: 37
        )
    }

    private static let emulatorBase =
        "Android's Color correction. The emulator draws it wrongly and screenshots leave it out: check the look on a phone."
    private static let phoneBase =
        "Android's Color correction. Only the phone's own screen is sure to show it: screenshots leave it out, and recordings and the mirror may too."

    /// The caption for a capture on an API 37 device.
    private func caption(_ readings: ColorFilterReadings, isEmulator: Bool = true, apiLevel: Int = 37) -> String {
        colorFilterCaption(
            readings: readings,
            check: readings.check(apiLevel: apiLevel),
            isEmulator: isEmulator,
            apiLevel: apiLevel
        )
    }

    // MARK: - Popup

    func testThePopupSelectsTheFilterOrNamesTheState() throws {
        XCTAssertEqual(
            colorFilterPopupModel(for: try readings("protanopia")),
            ColorFilterPopupModel(selection: .protanopia, placeholder: nil, help: nil)
        )
        XCTAssertEqual(colorFilterPopupModel(for: try readings("off")).selection, ColorFilterOption.none)
        XCTAssertEqual(colorFilterPopupModel(for: try readings("mode-unset")).selection, .deuteranopia)

        let simulated = colorFilterPopupModel(for: try readings("simulate-deuteranopia"))
        XCTAssertNil(simulated.selection)
        XCTAssertEqual(simulated.placeholder, "Simulated")
        XCTAssertEqual(
            simulated.help,
            "Developer options ▸ Simulate color space is simulating Deuteranopia. Choose a filter to change it; None turns it off."
        )

        let unmapped = colorFilterPopupModel(for: try readings("mode-21"))
        XCTAssertNil(unmapped.selection)
        XCTAssertEqual(unmapped.placeholder, "Mode 21")
        XCTAssertEqual(unmapped.help, "The device's color correction mode is 21, which Android's Settings doesn't offer. Choose a filter to change it.")

        XCTAssertEqual(colorFilterPopupModel(for: nil), ColorFilterPopupModel(selection: nil, placeholder: "Unknown", help: nil))
        XCTAssertEqual(colorFilterPopupModel(for: try readings("invalid-user")).placeholder, "Unknown", "a failed read")
        XCTAssertEqual(
            colorFilterPopupModel(for: try readings("mode-empty")).selection,
            .deuteranopia,
            "an empty mode is 12, as SurfaceFlinger draws it"
        )
        XCTAssertEqual(colorFilterPopupModel(for: try readings("mode-space-11")).selection, .deuteranopia)
        XCTAssertEqual(colorFilterPopupModel(for: try readings("enabled-space-1")).selection, ColorFilterOption.none)
        XCTAssertEqual(
            colorFilterPopupModel(for: try readings("keys-only-off")).selection,
            ColorFilterOption.none,
            "the keys alone name the filter"
        )
    }

    /// The row's value is drawn on one line in the system font at 13 pt; a
    /// placeholder no wider than the widest short title fits wherever the
    /// titles do (about 120 pt at the inspector's default width).
    func testPlaceholdersFitWhereTheShortTitlesDo() throws {
        let font = NSFont.systemFont(ofSize: 13)
        func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        let widest = ColorFilterOption.allCases.map { width($0.shortTitle) }.max() ?? 0
        for state in ["simulate-protanopia", "simulate-deuteranopia", "simulate-tritanopia", "mode-21", "mode-minus-1"] {
            let placeholder = try XCTUnwrap(colorFilterPopupModel(for: try readings(state)).placeholder, state)
            XCTAssertLessThanOrEqual(width(placeholder), widest, "\(state): \(placeholder)")
        }
    }

    func testTheValueShowsTheShortLabel() {
        XCTAssertEqual(ColorFilterOption.allCases.map(\.title), [
            "None", "Grayscale", "Red/Green (Protanopia)", "Green/Red (Deuteranopia)", "Blue/Yellow (Tritanopia)",
        ])
        XCTAssertEqual(ColorFilterOption.allCases.map(\.shortTitle), [
            "None", "Grayscale", "Protanopia", "Deuteranopia", "Tritanopia",
        ])
    }

    // MARK: - Captions

    func testCaptionsSayWhereTheFilterShows() throws {
        XCTAssertEqual(caption(try readings("off")), Self.emulatorBase)
        XCTAssertEqual(caption(try readings("off"), isEmulator: false), Self.phoneBase)
        XCTAssertEqual(caption(try readings("protanopia")), Self.emulatorBase, "applied at the default level: nothing more to say")
        XCTAssertEqual(caption(try readings("inversion-grayscale"), isEmulator: false), Self.phoneBase)
        XCTAssertEqual(colorFilterCaption(readings: nil, check: nil, isEmulator: true, apiLevel: nil), Self.emulatorBase)
    }

    func testEveryStatusSentence() throws {
        XCTAssertEqual(
            caption(try readings("simulate-protanopia")),
            "\(Self.emulatorBase) Developer options ▸ Simulate color space is simulating Protanopia."
        )
        XCTAssertEqual(
            caption(try readings("mode-99"), isEmulator: false),
            "\(Self.phoneBase) Mode 99 isn't one of Android's Settings options."
        )

        // SOURCE-DERIVED display-off section (ColorFiltersTests.testADisplayThatIsOffReadsAsDisplayOff).
        let offText = try String(contentsOf: Self.fixtures.appendingPathComponent("readings-probe-grayscale.txt"), encoding: .utf8)
            .replacingOccurrences(of: "isEnabled=true", with: "isEnabled=false")
        let screenOff = ColorFilterReadings.parse(offText, apiLevel: 37)
        XCTAssertEqual(caption(screenOff), "\(Self.emulatorBase) The screen is off, so the applied filter can't be read.")
        var nothingSetScreenOff = try readings("off")
        nothingSetScreenOff.display = screenOff.display
        XCTAssertEqual(caption(nothingSetScreenOff), Self.emulatorBase, "nothing set: nothing to confirm")

        var ignored = try readings("protanopia")
        ignored.display = try readings("off").display
        XCTAssertEqual(
            caption(ignored, isEmulator: false),
            "\(Self.phoneBase) SurfaceFlinger shows no color transform: this device may not draw the filter."
        )

        var combined = try readings("protanopia")
        combined.display = try readings("grayscale").display
        XCTAssertEqual(
            caption(combined, isEmulator: false),
            "\(Self.phoneBase) SurfaceFlinger also applies another color transform (Night Light, Extra dim, Bedtime mode or the display's color mode), so the filter can't be confirmed."
        )
        var bothCombined = try readings("inversion-protanopia")
        bothCombined.display = try readings("grayscale").display
        XCTAssertEqual(
            caption(bothCombined),
            "\(Self.emulatorBase) SurfaceFlinger also applies another color transform (Night Light, Extra dim, Bedtime mode or the display's color mode), so the filter and color inversion can't be confirmed."
        )
        var otherTransformOnly = try readings("off")
        otherTransformOnly.display = try readings("grayscale").display
        XCTAssertEqual(caption(otherTransformOnly), Self.emulatorBase, "no combined sentence while nothing is set")

        let keysOnlyGrayscale = try readings("off").writing(.grayscale)
        XCTAssertEqual(
            colorFilterCaption(readings: keysOnlyGrayscale, check: .unavailable, isEmulator: false, apiLevel: 32),
            "\(Self.phoneBase) Android 12L and older don't report the applied filter."
        )
        XCTAssertEqual(
            colorFilterCaption(readings: try readings("keys-only-off"), check: .unavailable, isEmulator: false, apiLevel: 32),
            Self.phoneBase,
            "nothing set"
        )
        XCTAssertEqual(
            colorFilterCaption(readings: keysOnlyGrayscale, check: .unavailable, isEmulator: false, apiLevel: nil),
            Self.phoneBase,
            "an unknown API level says nothing"
        )

        XCTAssertEqual(
            caption(try readings("deuteranopia-intensity-3")),
            "\(Self.emulatorBase) Intensity 3 of 10, set on the device."
        )
        XCTAssertEqual(caption(try readings("deuteranopia-intensity-10")), "\(Self.emulatorBase) Intensity 10 of 10, set on the device.")
        XCTAssertEqual(caption(try readings("deuteranopia-intensity-7")), Self.emulatorBase, "the default intensity")
        XCTAssertEqual(caption(try readings("deuteranopia-intensity-0")), "\(Self.emulatorBase) Intensity 0 of 10, set on the device.")
    }

    /// Settings' Color correction lists Grayscale from Android 12
    /// (accessibility_daltonizer_settings.xml, android-12.0.0_r34; not in
    /// android-11.0.0_r48); before, mode 0 is Developer options' Monochromacy.
    func testGrayscaleBeforeAndroid12NamesWhereSettingsKeepsIt() throws {
        let grayscale = try readings("keys-only-off").writing(.grayscale)
        XCTAssertEqual(
            colorFilterCaption(readings: grayscale, check: .unavailable, isEmulator: false, apiLevel: 30),
            "\(Self.phoneBase) Before Android 12, Settings shows Grayscale as Developer options ▸ Simulate color space ▸ Monochromacy. Android 12L and older don't report the applied filter."
        )
        XCTAssertEqual(
            colorFilterCaption(readings: grayscale, check: .unavailable, isEmulator: false, apiLevel: 31),
            "\(Self.phoneBase) Android 12L and older don't report the applied filter."
        )
        XCTAssertEqual(
            colorFilterCaption(readings: try readings("keys-only-off").writing(.protanopia), check: .unavailable, isEmulator: false, apiLevel: 30),
            "\(Self.phoneBase) Android 12L and older don't report the applied filter.",
            "the other filters are on Color correction"
        )
    }

    // MARK: - Write messages

    func testWriteMessages() {
        XCTAssertTrue(colorFilterWriteMessage(option: .protanopia, check: .applied(level: 0.7)) == ("Color filter set to Red/Green (Protanopia)", nil))
        XCTAssertTrue(colorFilterWriteMessage(option: .none, check: .applied(level: nil)) == ("Color filter turned off", nil))
        XCTAssertTrue(colorFilterWriteMessage(option: .grayscale, check: .unavailable) == ("Color filter set to Grayscale", nil))
        XCTAssertTrue(colorFilterWriteMessage(option: .grayscale, check: .displayOff) == ("Color filter set to Grayscale", nil))
        XCTAssertTrue(
            colorFilterWriteMessage(option: .tritanopia, check: .combined)
                == ("Color filter set to Blue/Yellow (Tritanopia); another color transform is on too", nil)
        )
        XCTAssertTrue(
            colorFilterWriteMessage(option: .deuteranopia, check: .notApplied)
                == (nil, "Color filter set to Green/Red (Deuteranopia), but SurfaceFlinger shows no color transform")
        )
    }
}
