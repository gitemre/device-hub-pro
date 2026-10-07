import XCTest
import DeviceHubProKit
@testable import DeviceHubProApp

/// The Sensors sheet's presets, slider and clamping, against a recording sink
/// (nothing reaches an emulator).
@MainActor
final class SensorPresetControllerTests: XCTestCase {
    private final class Sink: @unchecked Sendable {
        var calls: [(Int, SensorKind, [Float])] = []
        var succeed = true
    }

    private func make(_ sink: Sink) -> (EmulatorExtrasController, StatusCenter) {
        let context = ActiveDeviceContext()
        context.port = 5554
        let status = StatusCenter()
        let extras = EmulatorExtrasController(context: context, status: status)
        extras.sensorSink = { port, kind, values in
            sink.calls.append((port, kind, values))
            return sink.succeed
        }
        return (extras, status)
    }

    func testAPresetSendsItsValuesAtOnce() async throws {
        let sink = Sink()
        let (extras, status) = make(sink)
        extras.selectedSensor = .acceleration
        let preset = try XCTUnwrap(SensorKind.acceleration.presets.first { $0.title == "Held upright" })

        await extras.applyPreset(preset)

        XCTAssertEqual(sink.calls.count, 1)
        XCTAssertEqual(sink.calls[0].0, 5554)
        XCTAssertEqual(sink.calls[0].1, .acceleration)
        XCTAssertEqual(sink.calls[0].2, [0, 9.81, 0])
        XCTAssertEqual(extras.sensorReadings[.acceleration], [0, 9.81, 0])
        XCTAssertEqual(extras.sensorDraft, ["0.000", "9.810", "0.000"])
        XCTAssertNil(status.errorMessage)
    }

    func testTypedValuesAreClampedToTheOfficialRange() async {
        let sink = Sink()
        let (extras, _) = make(sink)
        extras.selectedSensor = .light
        extras.sensorDraft = ["99999"]

        await extras.applySensorValues()

        XCTAssertEqual(sink.calls.last?.2, [40_000])
        XCTAssertEqual(extras.sensorDraft, ["40000.000"])
    }

    func testClampDraftPullsTypedValuesIn() {
        let (extras, _) = make(Sink())
        extras.selectedSensor = .acceleration
        extras.sensorDraft = ["50", "-50", "x"]
        extras.clampDraft()
        XCTAssertEqual(extras.sensorDraft, ["39.300", "-39.300", "x"])
    }

    func testASliderMovesOneAxisAndKeepsTheOthers() async {
        let sink = Sink()
        let (extras, _) = make(sink)
        extras.selectedSensor = .acceleration
        extras.sensorDraft = ["1", "2", "3"]

        await extras.setAxis(1, to: 100)

        XCTAssertEqual(sink.calls.last?.2, [1, 39.3, 3])
    }

    func testARejectedPresetSetsTheErrorAndKeepsTheReading() async {
        let sink = Sink()
        sink.succeed = false
        let (extras, status) = make(sink)
        extras.selectedSensor = .proximity

        await extras.applyPreset(SensorKind.proximity.presets[0])

        XCTAssertEqual(status.errorMessage, "The emulator rejected the sensor value.")
        XCTAssertNil(extras.sensorReadings[.proximity])
    }

    func testWithoutAPortAPresetDoesNothing() async {
        let sink = Sink()
        let extras = EmulatorExtrasController(context: ActiveDeviceContext(), status: StatusCenter())
        extras.sensorSink = { _, _, _ in sink.calls.append((0, .light, [])); return true }
        await extras.applyPreset(SensorKind.light.presets[0])
        XCTAssertTrue(sink.calls.isEmpty)
    }
}
