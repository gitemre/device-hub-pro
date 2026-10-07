import XCTest
@testable import DeviceHubProKit

/// The route math and the player behind the Location menu's Trips on an
/// emulator. Nothing here reaches a device: the sink is a recording fake.
final class GpsRouteTests: XCTestCase {
    /// A straight line of exactly 1,000 m along a meridian (one degree of
    /// latitude is 111,195 m on the model's sphere).
    private var meridian: GpsRoute {
        let degrees = 1_000.0 / (GpsRoute.earthRadius * .pi / 180)
        return GpsRoute(
            points: [GpsPoint(latitude: 10, longitude: 20), GpsPoint(latitude: 10 + degrees, longitude: 20)],
            speed: 10
        )
    }

    func testTheDistanceAndBearingOfAMeridianLeg() throws {
        let route = meridian
        XCTAssertEqual(route.length, 1_000, accuracy: 0.001)
        XCTAssertEqual(GpsRoute.bearing(route.points[0], route.points[1]), 0, accuracy: 0.001, "due north")
        XCTAssertEqual(
            GpsRoute.bearing(GpsPoint(latitude: 0, longitude: 0), GpsPoint(latitude: 0, longitude: 1)),
            90,
            accuracy: 0.001,
            "due east"
        )
        XCTAssertEqual(
            GpsRoute.bearing(GpsPoint(latitude: 0, longitude: 1), GpsPoint(latitude: 0, longitude: 0)),
            270,
            accuracy: 0.001
        )
    }

    func testASampleIsInterpolatedAlongTheRoute() {
        let route = meridian
        let halfway = route.sample(atDistance: 500)
        XCTAssertEqual(halfway.latitude, (route.points[0].latitude + route.points[1].latitude) / 2, accuracy: 1e-9)
        XCTAssertEqual(halfway.longitude, 20, accuracy: 1e-9)
        XCTAssertEqual(halfway.speed, 10)
        XCTAssertEqual(halfway.bearing, 0, accuracy: 0.001)

        let start = route.sample(atDistance: 0)
        XCTAssertEqual(start.latitude, 10, accuracy: 1e-9)
    }

    func testARouteThatDoesNotRepeatStopsOnItsLastPointAtRest() {
        let route = meridian
        let end = route.sample(atDistance: 5_000)
        XCTAssertEqual(end.latitude, route.points[1].latitude, accuracy: 1e-9)
        XCTAssertEqual(end.speed, 0, "arrived")
        XCTAssertTrue(route.isFinished(atDistance: 1_000))
        XCTAssertFalse(route.isFinished(atDistance: 999))
    }

    func testARepeatingRouteWrapsAround() {
        let degrees = 500.0 / (GpsRoute.earthRadius * .pi / 180)
        let there = GpsPoint(latitude: 10 + degrees, longitude: 20)
        let route = GpsRoute(
            points: [GpsPoint(latitude: 10, longitude: 20), there, GpsPoint(latitude: 10, longitude: 20)],
            speed: 5,
            repeats: true
        )
        XCTAssertEqual(route.length, 1_000, accuracy: 0.001)
        let back = route.sample(atDistance: 750)
        XCTAssertEqual(back.latitude, 10 + degrees / 2, accuracy: 1e-9, "on the way back")
        XCTAssertEqual(back.bearing, 180, accuracy: 0.001)
        let wrapped = route.sample(atDistance: 1_250)
        XCTAssertEqual(wrapped.latitude, 10 + degrees / 2, accuracy: 1e-9, "250 m into the second lap")
        XCTAssertEqual(wrapped.bearing, 0, accuracy: 0.001)
        XCTAssertEqual(wrapped.speed, 5)
        XCTAssertFalse(route.isFinished(atDistance: 1_000_000))
    }

    func testARouteWithoutLengthOrSpeedCannotBeWalked() {
        let point = GpsPoint(latitude: 1, longitude: 1)
        XCTAssertFalse(GpsRoute(points: [point], speed: 3).isWalkable)
        XCTAssertFalse(GpsRoute(points: [point, point], speed: 3).isWalkable)
        XCTAssertFalse(GpsRoute(points: [point, GpsPoint(latitude: 2, longitude: 2)], speed: 0).isWalkable)
        XCTAssertTrue(GpsRoute(points: [point, GpsPoint(latitude: 2, longitude: 2)], speed: 1).isWalkable)
    }

    // MARK: - The three scenarios

    func testTheScenariosKeepAppleNamesInOrderWithTheirSpeeds() {
        XCTAssertEqual(LocationScenario.allCases.map(\.name), ["City Run", "City Bicycle Ride", "Freeway Drive"])
        XCTAssertEqual(LocationScenario.allCases.map(\.speed), [3, 6, 30], "about a run, a bicycle ride and a drive")
        XCTAssertEqual(LocationScenario(name: "Freeway Drive"), .freewayDrive)
        XCTAssertNil(LocationScenario(name: "Apple"), "simctl's other scenario is not a trip")
    }

    func testEveryScenarioRoutesNearAppleParkAndRepeats() throws {
        for scenario in LocationScenario.allCases {
            let route = scenario.route
            XCTAssertTrue(route.isWalkable, scenario.name)
            XCTAssertTrue(route.repeats, scenario.name)
            XCTAssertEqual(route.speed, scenario.speed, scenario.name)
            XCTAssertEqual(route.points.first, route.points.last, "\(scenario.name) comes back to where it began")
            let first = try XCTUnwrap(route.points.first)
            XCTAssertEqual(first.latitude, 37.33, accuracy: 0.05, scenario.name)
            XCTAssertEqual(first.longitude, -122.03, accuracy: 0.05, scenario.name)
        }
        XCTAssertEqual(LocationScenario.cityRun.route.length, 1_950, accuracy: 100)
        XCTAssertEqual(LocationScenario.cityBicycleRide.route.length, 6_300, accuracy: 300)
        XCTAssertEqual(LocationScenario.freewayDrive.route.length, 33_000, accuracy: 2_000, "out and back")
    }

    // MARK: - The player

    private actor Recorder {
        var samples: [GpsSample] = []
        func record(_ sample: GpsSample) { samples.append(sample) }
    }

    /// One fix per second at the route's speed: the tick sequence.
    func testThePlayerSendsOneFixPerTickAtTheRoutesSpeed() async {
        let recorder = Recorder()
        let slept = Recorder2()
        let route = meridian
        let ending = await GpsRoutePlayer.play(
            route,
            interval: 1,
            sleep: { await slept.record($0) },
            sink: { sample in
                await recorder.record(sample)
                return true
            }
        )
        XCTAssertEqual(ending, .finished, "1,000 m at 10 m/s is 100 s")
        let samples = await recorder.samples
        XCTAssertEqual(samples.count, 101, "the start and one fix per second until the end")
        XCTAssertEqual(samples[0].latitude, route.points[0].latitude, accuracy: 1e-9)
        for (tick, sample) in samples.enumerated().prefix(100) {
            XCTAssertEqual(
                GpsRoute.distance(route.points[0], GpsPoint(latitude: sample.latitude, longitude: sample.longitude)),
                Double(tick) * 10,
                accuracy: 0.01,
                "tick \(tick)"
            )
            XCTAssertEqual(sample.speed, 10)
        }
        XCTAssertEqual(samples[100].speed, 0, "the last fix says it arrived")
        let waits = await slept.durations
        XCTAssertEqual(waits.count, 100)
        XCTAssertTrue(waits.allSatisfy { $0 == .milliseconds(1000) }, "about 1 Hz")
    }

    func testThePlayerStopsWhenTheTaskIsCancelled() async throws {
        let recorder = Recorder()
        let route = LocationScenario.cityRun.route
        let task = Task {
            await GpsRoutePlayer.play(
                route,
                interval: 1,
                sleep: { _ in try await Task.sleep(for: .milliseconds(2)) },
                sink: { sample in
                    await recorder.record(sample)
                    return true
                }
            )
        }
        try await waitForSamples(recorder, atLeast: 5)
        task.cancel()
        let ending = await task.value
        XCTAssertEqual(ending, .cancelled)
        let stopped = await recorder.samples.count
        try await Task.sleep(for: .milliseconds(60))
        let later = await recorder.samples.count
        XCTAssertEqual(later, stopped, "nothing is sent after the stop")
    }

    func testThePlayerEndsWhenTheDeviceRefusesAFix() async {
        let recorder = Recorder()
        let ending = await GpsRoutePlayer.play(
            LocationScenario.cityRun.route,
            interval: 1,
            sleep: { _ in },
            sink: { sample in
                await recorder.record(sample)
                return await recorder.samples.count < 3
            }
        )
        XCTAssertEqual(ending, .refused)
        let count = await recorder.samples.count
        XCTAssertEqual(count, 3)
    }

    func testAnUnwalkableRouteSendsNothing() async {
        let recorder = Recorder()
        let point = GpsPoint(latitude: 1, longitude: 1)
        let ending = await GpsRoutePlayer.play(GpsRoute(points: [point, point], speed: 5), sink: { sample in
            await recorder.record(sample)
            return true
        })
        XCTAssertEqual(ending, .notWalkable)
        let count = await recorder.samples.count
        XCTAssertEqual(count, 0)
    }

    private func waitForSamples(_ recorder: Recorder, atLeast count: Int) async throws {
        for _ in 0..<500 {
            if await recorder.samples.count >= count { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("the player never sent \(count) fixes")
    }
}

private actor Recorder2 {
    var durations: [Duration] = []
    func record(_ duration: Duration) { durations.append(duration) }
}
