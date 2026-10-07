import XCTest
@testable import DeviceHubProKit

/// The sensor range table against the AOSP goldfish `sensor_list.cpp`
/// (fixture `Fixtures/goldfish-sensors/sensor_list.cpp`, branch `main`,
/// fetched 2026-10-05), and the presets and descriptions around it.
final class SensorGuideTests: XCTestCase {
    private func fixture() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/goldfish-sensors/sensor_list.cpp")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// (maxRange, resolution) of the first entry of each `SensorType::X`.
    private func entries() throws -> [String: (max: Float, resolution: Float)] {
        var found: [String: (max: Float, resolution: Float)] = [:]
        var type: String?
        var max: Float?
        let trim = CharacterSet(charactersIn: ", ")
        for raw in try fixture().split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(".type = SensorType::") {
                type = String(line.dropFirst(".type = SensorType::".count)).trimmingCharacters(in: trim)
                max = nil
            } else if line.hasPrefix(".maxRange = ") {
                max = Float(line.dropFirst(".maxRange = ".count).trimmingCharacters(in: trim))
            } else if line.hasPrefix(".resolution = "), let t = type, let m = max, found[t] == nil {
                let text = line.dropFirst(".resolution = ".count).trimmingCharacters(in: trim)
                let parts = text.components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespaces) }
                let value = parts.count == 2 ? Float(parts[0])! / Float(parts[1])! : Float(text)!
                found[t] = (m, value)
            }
        }
        return found
    }

    func testRangeTableMatchesTheFixture() throws {
        let types: [SensorKind: String] = [
            .acceleration: "ACCELEROMETER", .gyroscope: "GYROSCOPE", .magneticField: "MAGNETIC_FIELD",
            .orientation: "ORIENTATION", .temperature: "AMBIENT_TEMPERATURE", .proximity: "PROXIMITY",
            .light: "LIGHT", .pressure: "PRESSURE", .humidity: "RELATIVE_HUMIDITY", .heartRate: "HEART_RATE",
        ]
        let entries = try entries()
        for kind in SensorKind.allCases {
            let entry = try XCTUnwrap(entries[try XCTUnwrap(types[kind])], "\(kind)")
            XCTAssertEqual(kind.range.maximum, entry.max, "\(kind) max")
            XCTAssertEqual(kind.range.resolution, entry.resolution, accuracy: 1e-7, "\(kind) resolution")
            let signed: Set<SensorKind> = [.acceleration, .gyroscope, .magneticField]
            if signed.contains(kind) {
                XCTAssertEqual(kind.range.minimum, -entry.max, "\(kind) min")
            } else if kind != .temperature {
                XCTAssertEqual(kind.range.minimum, 0, "\(kind) min")
            }
        }
    }

    func testClampingPullsEveryAxisIntoTheRange() {
        XCTAssertEqual(SensorKind.acceleration.clamped([100, -100, 5]), [39.3, -39.3, 5])
        XCTAssertEqual(SensorKind.light.clamped([-3]), [0])
        XCTAssertEqual(SensorKind.light.clamped([50_000]), [40_000])
        XCTAssertEqual(SensorKind.proximity.clamped([7]), [1])
        XCTAssertEqual(SensorKind.orientation.clamped([400, 0, 10]), [360, 0, 10])
    }

    func testEveryPresetFitsItsSensorAndHasTheRightAxisCount() {
        for kind in SensorKind.allCases {
            XCTAssertFalse(kind.presets.isEmpty, "\(kind)")
            for preset in kind.presets {
                XCTAssertEqual(preset.values.count, kind.axisLabels.count, "\(kind) \(preset.title)")
                XCTAssertEqual(kind.clamped(preset.values), preset.values, "\(kind) \(preset.title)")
            }
        }
    }

    func testThePresetValues() {
        func values(_ kind: SensorKind) -> [String: [Float]] {
            Dictionary(uniqueKeysWithValues: kind.presets.map { ($0.title, $0.values) })
        }
        XCTAssertEqual(values(.acceleration), [
            "Flat on a table": [0, 0, 9.81], "Held upright": [0, 9.81, 0],
            "Landscape left": [9.81, 0, 0], "Landscape right": [-9.81, 0, 0],
            "Face down": [0, 0, -9.81], "Free fall": [0, 0, 0],
        ])
        XCTAssertEqual(values(.proximity), ["Near": [0], "Far": [1]])
        XCTAssertEqual(values(.light), ["Dark room": [10], "Office": [400], "Daylight": [10_000], "Direct sun": [40_000]])
        XCTAssertEqual(values(.temperature), ["Cold": [0], "Room": [22], "Hot": [40]])
        XCTAssertEqual(values(.humidity), ["Dry": [20], "Normal": [50], "Humid": [90]])
        XCTAssertEqual(values(.gyroscope), ["Still": [0, 0, 0]])
        XCTAssertEqual(values(.pressure), ["High altitude": [700], "Maximum": [800]])
        XCTAssertEqual(values(.heartRate), ["Resting": [60], "Walking": [100], "Running": [150]])
        XCTAssertEqual(values(.orientation).mapValues { $0[0] }, ["North": 0, "East": 90, "South": 180, "West": 270])
        XCTAssertEqual(Set(values(.magneticField).keys), ["North", "East", "South", "West"])
        XCTAssertEqual(SensorKind.pressure.presetCaption?.contains("800 hPa"), true)
    }

    func testDescriptionsAreNonEmptyAndTheNamedOnesExact() {
        for kind in SensorKind.allCases { XCTAssertFalse(kind.guideDescription.isEmpty, "\(kind)") }
        XCTAssertEqual(SensorKind.proximity.guideDescription, "Screen turning off when the phone is held to the ear.")
        XCTAssertEqual(SensorKind.light.guideDescription, "Auto-brightness and light/dark switching.")
        XCTAssertEqual(SensorKind.acceleration.guideDescription, "Device posture, tilt controls, step counting, shake.")
    }

    func testRangeCaption() {
        XCTAssertEqual(SensorKind.light.range.caption(unit: "lx"), "0 – 40\u{202F}000 lx")
        XCTAssertEqual(SensorKind.acceleration.range.caption(unit: "m/s²"), "-39.3 – 39.3 m/s²")
    }
}
