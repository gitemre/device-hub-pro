import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The Location row's controller on its own: the sheet's draft, the hand-back
/// on a device switch and the saved locations' persistence. No emulator is
/// involved; nothing here reaches a device.
@MainActor
final class LocationControllerTests: XCTestCase {
    private func controller(
        defaults: UserDefaults = .scratch(),
        context: ActiveDeviceContext = ActiveDeviceContext(),
        status: StatusCenter = StatusCenter()
    ) -> LocationController {
        LocationController(
            context: context,
            status: status,
            presetStore: LocationPresetStore(defaults: defaults)
        )
    }

    // MARK: The sheet's draft

    /// Opening the sheet fills the draft from the device's fix once; the fix
    /// moving afterwards does not refill it.
    func testOpeningTheSheetPrimesTheDraftOnce() {
        let location = controller()
        location.currentFix = { GpsFix(latitude: 37.422, longitude: -122.084) }

        location.isLocationSheetPresented = true
        XCTAssertEqual(location.locationLatText, "37.4220")
        XCTAssertEqual(location.locationLngText, "-122.0840")

        location.currentFix = { GpsFix(latitude: 1, longitude: 2) }
        location.isLocationSheetPresented = true
        XCTAssertEqual(location.locationLatText, "37.4220", "re-setting an open sheet primes nothing")
    }

    /// Opening the sheet without a fix leaves the draft as it was.
    func testOpeningTheSheetWithoutAFixKeepsTheDraft() {
        let location = controller()
        location.locationLatText = "41.0082"
        location.locationLngText = "28.9784"

        location.isLocationSheetPresented = true

        XCTAssertEqual(location.locationLatText, "41.0082")
        XCTAssertEqual(location.locationLngText, "28.9784")
    }

    /// While the sheet is open the draft is the user's: a poll never
    /// overwrites it. Closed, it follows the device again.
    func testAPollNeverOverwritesAnOpenDraft() {
        let location = controller()
        location.isLocationSheetPresented = true
        location.locationLatText = "48.8566"
        location.locationLngText = "2.3522"

        location.primeLocationDraft(from: GpsFix(latitude: 1, longitude: 2))
        XCTAssertEqual(location.locationLatText, "48.8566")
        XCTAssertEqual(location.locationLngText, "2.3522")

        location.isLocationSheetPresented = false
        location.primeLocationDraft(from: GpsFix(latitude: 1, longitude: 2))
        XCTAssertEqual(location.locationLatText, "1.0000")
        XCTAssertEqual(location.locationLngText, "2.0000")
    }

    /// `detach` hands the draft back to the next device's fix even while the
    /// sheet stays open, and forgets nothing else.
    func testDetachHandsTheDraftBack() {
        let location = controller()
        location.isLocationSheetPresented = true
        location.locationLatText = "48.8566"
        location.locationNameDraft = "Office"
        let presets = location.locationPresets
        let selected = location.selectedLocationID

        location.detach()

        XCTAssertTrue(location.isLocationSheetPresented)
        XCTAssertEqual(location.locationLatText, "48.8566", "detach itself leaves the text alone")
        XCTAssertEqual(location.locationNameDraft, "Office")
        XCTAssertEqual(location.locationPresets, presets)
        XCTAssertEqual(location.selectedLocationID, selected)

        location.primeLocationDraft(from: GpsFix(latitude: 1, longitude: 2))
        XCTAssertEqual(location.locationLatText, "1.0000")
    }

    // MARK: Saved locations

    /// A fresh install starts on the ready locations with the first selected.
    func testAFreshControllerLoadsTheReadyLocations() {
        let location = controller()

        XCTAssertEqual(location.locationPresets, SavedLocation.defaults)
        XCTAssertEqual(location.selectedLocationID, SavedLocation.defaults.first?.id)
    }

    /// A save selects the new preset, clears the name and persists in the
    /// suite; a delete persists too and drops the selection it removed.
    func testPresetsPersistInTheSuite() throws {
        let defaults = UserDefaults.scratch()
        let location = controller(defaults: defaults)
        location.locationNameDraft = "  Office  "
        location.locationLatText = "41,0082"
        location.locationLngText = "28.9784"

        location.saveCurrentLocation()

        let saved = try XCTUnwrap(location.locationPresets.last)
        XCTAssertEqual(saved.name, "Office")
        XCTAssertEqual(saved.latitude, 41.0082)
        XCTAssertEqual(saved.longitude, 28.9784)
        XCTAssertEqual(location.selectedLocationID, saved.id)
        XCTAssertEqual(location.locationNameDraft, "")
        XCTAssertEqual(controller(defaults: defaults).locationPresets, location.locationPresets)

        location.deleteLocation(saved)

        XCTAssertNil(location.selectedLocationID)
        XCTAssertEqual(controller(defaults: defaults).locationPresets, SavedLocation.defaults)
    }

    /// An unnamed preset is numbered after the list it joins.
    func testAnUnnamedPresetIsNumbered() {
        let location = controller()
        location.locationLatText = "10"
        location.locationLngText = "20"

        location.saveCurrentLocation()

        XCTAssertEqual(location.locationPresets.last?.name, "Location \(SavedLocation.defaults.count + 1)")
    }

    // MARK: Applying

    /// Without an emulator port the sheet gets the reason inline, the window
    /// alert stays down and the Controls panel is not re-read.
    func testApplyWithoutAPortReportsInlineAndRefreshesNothing() async {
        let status = StatusCenter()
        let location = controller(status: status)
        var refreshes = 0
        location.refreshControls = { refreshes += 1 }
        location.locationLatText = "41.0082"
        location.locationLngText = "28.9784"

        let failure = await location.applyTypedLocation()

        XCTAssertEqual(failure, "Location control requires a running emulator.")
        XCTAssertNil(status.errorMessage)
        XCTAssertEqual(refreshes, 0)
    }

    // MARK: Validation at the model

    /// `Double("nan")` parses, so the save used to append a NaN preset, and
    /// JSONEncoder then refused every later save of the list. Only the
    /// sheet's disabled Save button stood in the way.
    func testSaveRefusesNonFiniteCoordinates() {
        let defaults = UserDefaults.scratch()
        let status = StatusCenter()
        let location = controller(defaults: defaults, status: status)
        let selected = location.selectedLocationID
        location.locationNameDraft = "Nowhere"
        location.locationLatText = "nan"
        location.locationLngText = "1"

        location.saveCurrentLocation()

        XCTAssertEqual(location.locationPresets, SavedLocation.defaults)
        XCTAssertEqual(location.selectedLocationID, selected)
        XCTAssertEqual(location.locationNameDraft, "Nowhere", "a refused save keeps the typed name")
        XCTAssertEqual(status.errorMessage, "Enter a valid latitude and longitude before saving.")
        XCTAssertEqual(controller(defaults: defaults).locationPresets, SavedLocation.defaults)
    }

    /// A fix off the globe is refused the same way.
    func testSaveRefusesOutOfRangeCoordinates() {
        let location = controller()

        for (latitude, longitude) in [("91", "0"), ("0", "-180.5"), ("1e9", "0"), ("0", "inf")] {
            location.locationLatText = latitude
            location.locationLngText = longitude
            location.saveCurrentLocation()
        }

        XCTAssertEqual(location.locationPresets, SavedLocation.defaults)
    }

    /// A saved preset off the globe (stored before the sheet validated its
    /// input) is refused before it reaches the emulator, with the field's
    /// reason in the window alert: the Controls row has no inline message.
    func testAPresetOutsideTheGlobeIsRefused() async {
        let status = StatusCenter()
        let location = controller(status: status)
        var refreshes = 0
        location.refreshControls = { refreshes += 1 }
        let pole = SavedLocation(name: "Beyond the pole", latitude: 200, longitude: 0)
        let dateLine = SavedLocation(name: "Beyond the date line", latitude: 0, longitude: 181)
        location.locationPresets += [pole, dateLine]

        location.selectedLocationID = pole.id
        await location.applyLocationPreset()
        XCTAssertEqual(status.errorMessage, "Latitude must be a number from -90 to 90.")

        location.selectedLocationID = dateLine.id
        await location.applyLocationPreset()
        XCTAssertEqual(status.errorMessage, "Longitude must be a number from -180 to 180.")
        XCTAssertEqual(refreshes, 0)
    }

    /// The Controls row reports a valid preset it cannot apply through the
    /// window alert, in the sheet's words.
    func testAPresetWithoutAPortReportsInTheWindowAlert() async {
        let status = StatusCenter()
        let location = controller(status: status)
        let preset = SavedLocation.defaults[1]

        location.selectedLocationID = preset.id
        await location.applyLocationPreset()

        XCTAssertEqual(location.locationLatText, String(format: "%.4f", preset.latitude))
        XCTAssertEqual(location.locationLngText, String(format: "%.4f", preset.longitude))
        XCTAssertEqual(status.errorMessage, "Location control requires a running emulator.")
    }

    // MARK: AppModel wiring

    /// The model's forwarders and the two closures reach the one controller:
    /// the sheet primes from the Controls panel's fix, and a refresh asked for
    /// by the controller is the model's Controls poll.
    func testTheModelWiresTheControllerToTheControlsPanel() async {
        let phone = AndroidDevice.online("HT4CWJT0000A", model: "Pixel A")
        let model = AppModel.testing(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        model.workspace.mirror.sessionFactoryOverride = { _, _ in FakeMirrorSession() }
        model.inventory.applyWatcherSnapshot([phone], degraded: false)
        model.workspace.controlsPanel.controls.location = GpsFix(latitude: 37.422, longitude: -122.084)

        model.workspace.location.isLocationSheetPresented = true

        XCTAssertTrue(model.location.isLocationSheetPresented)
        XCTAssertEqual(model.location.locationLatText, "37.4220")

        await model.mirror(device: phone)
        XCTAssertFalse(model.workspace.controlsPanel.controlsLoaded)
        await model.location.refreshControls()
        XCTAssertTrue(model.workspace.controlsPanel.controlsLoaded, "the controller's refresh is the model's Controls poll")
    }
}
