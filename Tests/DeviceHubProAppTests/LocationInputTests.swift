import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// The Location sheet's coordinates (F10) and its inline failures (F9).
@MainActor
final class LocationInputTests: XCTestCase {
    func testOrdinaryCoordinatesAreValid() {
        XCTAssertEqual(
            CoordinateInput(latitude: "41.0082", longitude: " 28.9784 "),
            .valid(latitude: 41.0082, longitude: 28.9784)
        )
        XCTAssertEqual(
            CoordinateInput(latitude: "-90", longitude: "180"),
            .valid(latitude: -90, longitude: 180)
        )
    }

    func testCommaIsADecimalPoint() {
        XCTAssertEqual(
            CoordinateInput(latitude: "41,5", longitude: "29,25"),
            .valid(latitude: 41.5, longitude: 29.25)
        )
    }

    func testNonFiniteValuesAreRejected() {
        // `Double("nan")` parses; one NaN preset stopped every later preset
        // from being persisted (JSONEncoder throws on it, behind `try?`).
        XCTAssertEqual(
            CoordinateInput(latitude: "nan", longitude: "0"),
            .invalid("Latitude must be a number from -90 to 90.")
        )
        XCTAssertEqual(
            CoordinateInput(latitude: "0", longitude: "inf"),
            .invalid("Longitude must be a number from -180 to 180.")
        )
    }

    func testOutOfRangeValuesAreRejected() {
        XCTAssertFalse(CoordinateInput(latitude: "200", longitude: "0").isValid)
        XCTAssertFalse(CoordinateInput(latitude: "0", longitude: "-180.5").isValid)
        XCTAssertFalse(CoordinateInput(latitude: "1e9", longitude: "0").isValid)
        XCTAssertFalse(CoordinateInput(latitude: "abc", longitude: "0").isValid)
    }

    func testEmptyFieldsAreIncompleteNotAnError() {
        XCTAssertEqual(CoordinateInput(latitude: "", longitude: "28"), .incomplete)
        XCTAssertEqual(CoordinateInput(latitude: "41", longitude: "  "), .incomplete)
    }

    func testApplyWithoutAnEmulatorReportsToTheSheet() async {
        let model = AppModel.testing()
        model.workspace.location.locationLatText = "41.0082"
        model.workspace.location.locationLngText = "28.9784"

        let failure = await model.workspace.location.applyTypedLocation()

        XCTAssertEqual(failure, "Location control requires a running emulator.")
        XCTAssertNil(model.workspace.status.errorMessage, "the window alert sits behind the Location sheet")
    }

    func testApplyWithInvalidInputReportsTheField() async {
        let model = AppModel.testing()
        model.workspace.location.locationLatText = "nan"
        model.workspace.location.locationLngText = "28"

        let failure = await model.workspace.location.applyTypedLocation()

        XCTAssertEqual(failure, "Latitude must be a number from -90 to 90.")
        XCTAssertNil(model.workspace.status.errorMessage)
    }

    func testApplyingASavedLocationFillsTheFieldsAndSelectsIt() async {
        let model = AppModel.testing()
        let preset = SavedLocation(name: "Somewhere", latitude: 12.5, longitude: -45.25)

        let failure = await model.workspace.location.applySavedLocation(preset)

        XCTAssertEqual(model.workspace.location.selectedLocationID, preset.id)
        XCTAssertEqual(model.workspace.location.locationLatText, "12.5000")
        XCTAssertEqual(model.workspace.location.locationLngText, "-45.2500")
        XCTAssertEqual(failure, "Location control requires a running emulator.")
    }
}
