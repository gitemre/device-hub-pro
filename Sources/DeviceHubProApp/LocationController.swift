import Foundation
import Observation
import DeviceHubProKit

/// The Location row: the shared Location menu's choices applied to the
/// emulator (a place or a coordinate is one GPS fix; a trip or a custom route
/// is played by `GpsRoutePlayer` at about 1 Hz until another location or None
/// is chosen), the saved locations the batch menu uses, and the fix an
/// opening Custom Location sheet starts from.
///
/// One long-lived instance, owned by `DeviceWorkspace` as `location`; the
/// views read it there. It reads the emulator port from the shared
/// `ActiveDeviceContext`, reports through
/// `StatusCenter`, and reaches the Controls panel only through `currentFix`
/// and `refreshControls`, which `AppModel` wires.
/// What the Location row set on the emulator.
enum EmulatorLocationChoice: Equatable {
    case place(AppleLocationPlace)
    case trip(LocationScenario)
    case coordinate(latitude: Double, longitude: Double)
    case route(from: GpsPoint, to: GpsPoint, speed: Double)

    var title: String {
        switch self {
        case .place(let place): place.name
        case .trip(let trip): trip.name
        case .coordinate(let latitude, let longitude):
            String(format: "%.4f, %.4f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
        case .route: "Custom route"
        }
    }

    /// The route a trip or a custom route plays; nil for a fixed location.
    var route: GpsRoute? {
        switch self {
        case .trip(let trip): trip.route
        case .route(let from, let to, let speed): GpsRoute(points: [from, to], speed: speed, repeats: false)
        case .place, .coordinate: nil
        }
    }
}

@MainActor
@Observable
final class LocationController {
    var locationPresets: [SavedLocation] = []
    /// What the Location row last set (nil: None).
    private(set) var current: EmulatorLocationChoice?
    /// Sends one GPS fix to the emulator on `port`; tests replace it.
    @ObservationIgnored var gpsSink: @Sendable (Int, GpsSample) async -> Bool = { port, sample in
        await EmulatorControls.setLocation(port: port, sample: sample)
    }
    /// How a playing route waits between fixes; tests make it instant.
    @ObservationIgnored var routeSleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    @ObservationIgnored private(set) var routeTask: Task<Void, Never>?
    /// The Location row's custom popup (lat/long entry + the saved list).
    /// Opening it fills the draft from the device's current fix once; the
    /// Controls poll never writes into a draft the user may be typing.
    var isLocationSheetPresented = false {
        didSet {
            guard isLocationSheetPresented != oldValue else { return }
            if isLocationSheetPresented {
                primeLocationDraft(from: currentFix())
            }
            // While the sheet is up the draft is the user's; closed, the
            // polls keep it current for the next opening.
            locationDraftPrimed = isLocationSheetPresented
        }
    }
    var selectedLocationID: UUID?
    var locationNameDraft = ""
    var locationLatText = ""
    var locationLngText = ""
    /// Whether the lat/long draft belongs to the user (the sheet is open), so
    /// the Controls poll leaves it alone. A device switch hands it back.
    private var locationDraftPrimed = false

    /// The device's current fix, which opening the sheet fills the draft
    /// from. `AppModel` wires it to the Controls panel.
    @ObservationIgnored var currentFix: @MainActor () -> GpsFix? = { nil }
    /// Re-reads the Controls panel once the emulator took a fix. `AppModel`
    /// wires it to its `refreshControls()`.
    @ObservationIgnored var refreshControls: @MainActor () async -> Void = {}

    private let context: ActiveDeviceContext
    private let status: StatusCenter
    /// Where `locationPresets` persist.
    private let locationPresetStore: LocationPresetStore

    init(context: ActiveDeviceContext, status: StatusCenter, presetStore: LocationPresetStore) {
        self.context = context
        self.status = status
        self.locationPresetStore = presetStore
        loadLocationPresets()
    }

    /// Fills the Location sheet's lat/long draft from the device's fix,
    /// unless the sheet is open: from its opening on, the draft is what the
    /// user types (or a preset they pick), and no poll overwrites it.
    func primeLocationDraft(from location: GpsFix?) {
        guard !locationDraftPrimed, let location else { return }
        locationLatText = String(format: "%.4f", location.latitude)
        locationLngText = String(format: "%.4f", location.longitude)
    }

    /// Applies the preset the Controls row picked, through the sheet's one
    /// validated path (`applySavedLocation`): a preset off the globe never
    /// reaches the emulator. The row has no inline message, so a failure goes
    /// to the window alert and a success flashes.
    func applyLocationPreset() async {
        guard let id = selectedLocationID,
              let preset = locationPresets.first(where: { $0.id == id }) else { return }
        if let failure = await applySavedLocation(preset) {
            status.errorMessage = failure
            return
        }
        status.flash("Location set")
    }

    /// Saves the draft as a preset. Validates it here as well as in the
    /// sheet: a NaN preset would make every later save of the list fail
    /// (JSONEncoder throws on it), and an off-globe one would be offered by
    /// the Controls row.
    func saveCurrentLocation() {
        let input = CoordinateInput(latitude: locationLatText, longitude: locationLngText)
        guard case .valid(let latitude, let longitude) = input else {
            status.errorMessage = "Enter a valid latitude and longitude before saving."
            return
        }

        let name = locationNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = SavedLocation(
            name: name.isEmpty ? "Location \(locationPresets.count + 1)" : name,
            latitude: latitude,
            longitude: longitude
        )
        locationPresets.append(preset)
        selectedLocationID = preset.id
        locationNameDraft = ""
        persistLocationPresets()
    }

    func deleteLocation(_ preset: SavedLocation) {
        locationPresets.removeAll { $0.id == preset.id }
        if selectedLocationID == preset.id {
            selectedLocationID = nil
        }
        persistLocationPresets()
    }

    private func persistLocationPresets() {
        locationPresetStore.persist(locationPresets)
    }

    private func loadLocationPresets() {
        locationPresets = locationPresetStore.load()
        selectedLocationID = locationPresets.first?.id
    }

    /// Applies the Location sheet's typed coordinates. Returns the message
    /// the sheet shows inline (nil on success): the sheet covers the
    /// window's `errorMessage` alert, and a GPS fix the emulator refused used
    /// to vanish without a word.
    func applyTypedLocation() async -> String? {
        let input = CoordinateInput(latitude: locationLatText, longitude: locationLngText)
        guard case .valid(let latitude, let longitude) = input else {
            if case .invalid(let message) = input { return message }
            return "Enter a latitude and a longitude."
        }
        guard let port = context.port else {
            return "Location control requires a running emulator."
        }
        // A playing route would overwrite the typed fix at its next sample.
        await stopRouteAndWait()
        guard await gpsSink(port, GpsSample(latitude: latitude, longitude: longitude)) else {
            return "The emulator did not accept the location."
        }
        current = .coordinate(latitude: latitude, longitude: longitude)
        await refreshControls()
        return nil
    }

    /// Selects `preset`, fills the fields from it and applies it like
    /// `applyTypedLocation`.
    func applySavedLocation(_ preset: SavedLocation) async -> String? {
        selectedLocationID = preset.id
        locationLatText = String(format: "%.4f", preset.latitude)
        locationLngText = String(format: "%.4f", preset.longitude)
        return await applyTypedLocation()
    }

    // MARK: - The shared Location menu

    /// Sets (nil: None) the emulator's location. A place or a coordinate is
    /// one fix; a trip or a route plays until another choice, None or a
    /// device change. Returns the message to show when the emulator did not
    /// take it (nil on success). Android cannot clear a fix, so None only
    /// stops a playing route and leaves the last position.
    @discardableResult
    func choose(_ choice: EmulatorLocationChoice?) async -> String? {
        let wasPlaying = routeTask != nil
        await stopRouteAndWait()
        guard let choice else {
            current = nil
            if wasPlaying { status.flash("Route stopped; the emulator keeps its last position") }
            return nil
        }
        guard let port = context.port else { return "Location control requires a running emulator." }
        if let route = choice.route {
            guard route.isWalkable else { return "That route has no length to walk." }
            current = choice
            let sink = gpsSink
            let sleep = routeSleep
            routeTask = Task { [weak self] in
                let ending = await GpsRoutePlayer.play(route, interval: 1, sleep: sleep) { sample in
                    await sink(port, sample)
                }
                await self?.routeEnded(ending, choice: choice)
            }
            return nil
        }
        let sample: GpsSample
        switch choice {
        case .place(let place): sample = GpsSample(latitude: place.latitude, longitude: place.longitude)
        case .coordinate(let latitude, let longitude): sample = GpsSample(latitude: latitude, longitude: longitude)
        case .trip, .route: return nil
        }
        guard await gpsSink(port, sample) else { return "The emulator did not accept the location." }
        current = choice
        await refreshControls()
        return nil
    }

    /// The Location row picked something: failures go to the window alert.
    func chooseFromMenu(_ choice: EmulatorLocationChoice?) async {
        if let failure = await choose(choice) {
            status.errorMessage = failure
        }
    }

    /// Stops a playing route (the emulator keeps the last fix it got).
    func stopRoute() {
        routeTask?.cancel()
        routeTask = nil
    }

    /// Stops a playing route and waits until its player has ended, so the
    /// sample it was sending cannot land after the write that follows.
    func stopRouteAndWait() async {
        let playing = routeTask
        stopRoute()
        await playing?.value
    }

    private func routeEnded(_ ending: GpsRoutePlayer.Ending, choice: EmulatorLocationChoice) async {
        // A cancelled player was replaced (or stopped) by a newer choice.
        guard ending != .cancelled, current == choice else { return }
        routeTask = nil
        switch ending {
        case .cancelled:
            break
        case .refused:
            current = nil
            status.errorMessage = "The emulator stopped accepting the route."
        case .finished:
            if case .route(_, let to, _) = choice {
                current = .coordinate(latitude: to.latitude, longitude: to.longitude)
            }
            await refreshControls()
        case .notWalkable:
            current = nil
        }
    }

    /// Hands the draft back to the Controls poll, which primes it from the
    /// next device's fix, and stops a playing route (it belonged to the
    /// device going away). Called by `AppModel` when the mirrored device goes
    /// away; the presets, the selection and the typed text stay.
    func detach() {
        locationDraftPrimed = false
        stopRoute()
        current = nil
    }
}
