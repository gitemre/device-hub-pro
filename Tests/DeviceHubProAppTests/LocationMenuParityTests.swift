import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The Location menu is one model for Android emulators and iOS simulators:
/// the same titles in the same order, and the same None option. The
/// controllers carry the choices out differently; a trip plays through the
/// route player on an emulator and is stopped by the next choice.
@MainActor
final class LocationMenuParityTests: XCTestCase {
    private func titles(_ entries: [LocationMenuEntry]) -> [String?] { entries.map(\.title) }

    func testTheMenuListsNonePlacesTripsAndCustomInOrder() {
        let entries = LocationMenuModel.entries()
        XCTAssertEqual(entries.first, LocationMenuEntry.none)
        XCTAssertEqual(entries.last, LocationMenuEntry.custom)
        let titled = titles(entries).compactMap { $0 }
        XCTAssertEqual(titled.first, "None")
        XCTAssertEqual(titled.last, "Custom Location…")
        XCTAssertEqual(
            Array(titled.dropFirst().prefix(14)),
            AppleLocationPlaces.all.map(\.name),
            "Device Hub's fourteen places, in its order"
        )
        XCTAssertEqual(Array(titled.suffix(5).dropLast()), ["Trips", "City Run", "City Bicycle Ride", "Freeway Drive"])
    }

    /// An Android emulator runs all three trips itself; a simulator lists the
    /// ones `simctl location list` names (its capture also names "Apple",
    /// which is not a trip). With the three named the menus are identical.
    func testAnEmulatorAndASimulatorShowTheSameItems() throws {
        let capture = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("DeviceHubProKitTests/Fixtures/ios27-simulator/controls/simctl-location-list.stdout.txt"),
            encoding: .utf8
        )
        let simulatorNames = SimctlParsing.locationScenarios(from: capture).map(\.name)
        XCTAssertEqual(simulatorNames, ["City Run", "City Bicycle Ride", "Freeway Drive", "Apple"])

        let android = LocationMenuModel.entries()
        let simulator = LocationMenuModel.entries(trips: LocationMenuModel.trips(named: simulatorNames))
        XCTAssertEqual(titles(android), titles(simulator))
        XCTAssertEqual(android.map(\.id), simulator.map(\.id))
    }

    func testASimulatorWithoutTripsDropsTheSection() {
        let entries = LocationMenuModel.entries(trips: LocationMenuModel.trips(named: []))
        XCTAssertFalse(titles(entries).contains("Trips"))
        XCTAssertEqual(entries.last, LocationMenuEntry.custom)
    }

    func testTheTripsKeepTheSharedOrderWhateverSimctlListsFirst() {
        XCTAssertEqual(
            LocationMenuModel.trips(named: ["Freeway Drive", "Apple", "City Run"]),
            [.cityRun, .freewayDrive]
        )
    }

    // MARK: - The emulator's choices

    private func rig(port: Int? = 5554) -> (location: LocationController, context: ActiveDeviceContext, fixes: FixLog, status: StatusCenter) {
        let context = ActiveDeviceContext()
        context.port = port
        let status = StatusCenter()
        let location = LocationController(
            context: context,
            status: status,
            presetStore: LocationPresetStore(defaults: .scratch())
        )
        let fixes = FixLog()
        location.gpsSink = { port, sample in
            await fixes.record(port, sample)
            return true
        }
        location.routeSleep = { _ in try await Task.sleep(for: .milliseconds(2)) }
        return (location, context, fixes, status)
    }

    func testAPlaceIsOneFix() async throws {
        let (location, _, fixes, _) = rig()
        let place = try XCTUnwrap(AppleLocationPlaces.all.first { $0.name == "Tokyo, Japan" })
        let failure = await location.choose(.place(place))
        XCTAssertNil(failure)
        XCTAssertEqual(location.current, .place(place))
        let samples = await fixes.samples
        XCTAssertEqual(samples, [GpsSample(latitude: 35.6762, longitude: 139.6503)])
        XCTAssertNil(location.routeTask)
    }

    /// A typed or saved location ends a playing route: its next sample
    /// would otherwise overwrite the fix a second later.
    func testATypedLocationStopsAPlayingRoute() async throws {
        let (location, _, fixes, _) = rig()
        _ = await location.choose(.trip(.cityRun))
        try await waitFor(fixes, atLeast: 2)
        location.locationLatText = "41.0082"
        location.locationLngText = "28.9784"

        let failure = await location.applyTypedLocation()
        XCTAssertNil(failure)
        XCTAssertNil(location.routeTask)
        XCTAssertEqual(location.current, .coordinate(latitude: 41.0082, longitude: 28.9784))
        let afterTyped = await fixes.samples.count
        try await Task.sleep(for: .milliseconds(60))
        let later = await fixes.samples.count
        XCTAssertEqual(later, afterTyped, "no route sample lands after the typed fix")
        let last = await fixes.samples.last
        XCTAssertEqual(last, GpsSample(latitude: 41.0082, longitude: 28.9784))
    }

    func testATripPlaysAtAboutOneHertzUntilNoneStopsIt() async throws {
        let (location, _, fixes, status) = rig()
        let failure = await location.choose(.trip(.cityRun))
        XCTAssertNil(failure)
        XCTAssertEqual(location.current, .trip(.cityRun))
        try await waitFor(fixes, atLeast: 4)
        let first = await fixes.samples.first
        XCTAssertEqual(first?.speed, 3, "a run is about 3 m/s")
        XCTAssertEqual(first?.latitude ?? 0, LocationScenario.cityRun.route.points[0].latitude, accuracy: 1e-9)

        await location.choose(nil)
        XCTAssertNil(location.current)
        XCTAssertNil(location.routeTask)
        XCTAssertEqual(status.statusMessage, "Route stopped; the emulator keeps its last position")
        let stopped = await fixes.samples.count
        try await Task.sleep(for: .milliseconds(60))
        let later = await fixes.samples.count
        XCTAssertEqual(later, stopped, "no fix after None")
    }

    func testChoosingAnotherLocationStopsTheTrip() async throws {
        let (location, _, fixes, _) = rig()
        await location.choose(.trip(.freewayDrive))
        try await waitFor(fixes, atLeast: 3)
        let place = try XCTUnwrap(AppleLocationPlaces.all.first)

        await location.choose(.place(place))

        XCTAssertEqual(location.current, .place(place))
        XCTAssertNil(location.routeTask)
        let stopped = await fixes.samples.count
        try await Task.sleep(for: .milliseconds(60))
        let later = await fixes.samples.count
        XCTAssertEqual(later, stopped, "the trip stopped and only the place's own fix is the last one")
        let last = await fixes.samples.last
        XCTAssertEqual(last, GpsSample(latitude: place.latitude, longitude: place.longitude))
    }

    func testChoosingTheSameTripAgainRestartsIt() async throws {
        let (location, _, fixes, _) = rig()
        await location.choose(.trip(.cityBicycleRide))
        try await waitFor(fixes, atLeast: 3)
        await location.choose(.trip(.cityBicycleRide))
        let starts = await fixes.samples.filter { $0.latitude == LocationScenario.cityBicycleRide.route.points[0].latitude }
        XCTAssertGreaterThanOrEqual(starts.count, 1)
        XCTAssertNotNil(location.routeTask, "the second player is running")
        location.detach()
    }

    func testACustomRoutePlaysOnceAndEndsOnItsLastPoint() async throws {
        let (location, _, fixes, _) = rig()
        // About 30 m due north at 15 m/s: three fixes.
        let from = GpsPoint(latitude: 37.0, longitude: -122.0)
        let to = GpsPoint(latitude: 37.0 + 30 / (GpsRoute.earthRadius * .pi / 180), longitude: -122.0)
        await location.choose(.route(from: from, to: to, speed: 15))
        try await waitFor(fixes, atLeast: 3)
        for _ in 0..<200 where location.routeTask != nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(location.routeTask)
        XCTAssertEqual(location.current, .coordinate(latitude: to.latitude, longitude: to.longitude))
        let samples = await fixes.samples
        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples.last?.speed, 0, "arrived")
    }

    func testADeviceChangeStopsTheTrip() async throws {
        let (location, _, fixes, _) = rig()
        await location.choose(.trip(.cityRun))
        try await waitFor(fixes, atLeast: 2)
        location.detach()
        XCTAssertNil(location.current)
        XCTAssertNil(location.routeTask)
    }

    func testWithoutAnEmulatorNothingPlays() async {
        let (location, _, fixes, _) = rig(port: nil)
        let failure = await location.choose(.trip(.cityRun))
        XCTAssertEqual(failure, "Location control requires a running emulator.")
        let count = await fixes.samples.count
        XCTAssertEqual(count, 0)
    }

    func testARefusedFixEndsTheTripWithAnAlert() async throws {
        let (location, _, _, status) = rig()
        location.gpsSink = { _, _ in false }
        await location.choose(.trip(.cityRun))
        for _ in 0..<200 where location.current != nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(location.current)
        XCTAssertEqual(status.errorMessage, "The emulator stopped accepting the route.")
    }

    private func waitFor(_ fixes: FixLog, atLeast count: Int) async throws {
        for _ in 0..<500 {
            if await fixes.samples.count >= count { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("fewer than \(count) fixes")
    }
}

private actor FixLog {
    var samples: [GpsSample] = []
    func record(_ port: Int, _ sample: GpsSample) { samples.append(sample) }
}
