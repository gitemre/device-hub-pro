import XCTest
@testable import DeviceHubProKit

final class PerfLogTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("perf-log-\(UUID().uuidString).jsonl")
    }

    func testAppendsOneJSONLinePerStats() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = PerfLogWriter(url: url)

        await writer.append(
            MirrorStats(fps: 59.5, totalFrames: 120, dropped: 1, averageLatencyMs: 12.5),
            device: "emulator-5554",
            at: Date(timeIntervalSince1970: 1000)
        )
        await writer.append(
            MirrorStats(fps: 60, totalFrames: 240, dropped: 3, averageLatencyMs: 11),
            device: "emulator-5554",
            at: Date(timeIntervalSince1970: 1000.5)
        )

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let first = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        )
        XCTAssertEqual((first["t"] as? NSNumber)?.doubleValue, 1000)
        XCTAssertEqual(first["device"] as? String, "emulator-5554")
        XCTAssertEqual((first["fps"] as? NSNumber)?.doubleValue, 59.5)
        XCTAssertEqual((first["frames"] as? NSNumber)?.intValue, 120)
        XCTAssertEqual((first["dropped"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((first["latencyMs"] as? NSNumber)?.doubleValue, 12.5)
    }

    /// Two devices logging to the same file (multi-window) keep
    /// their own rows, distinguishable by `device`.
    func testDeviceFieldDistinguishesTwoDevicesInOneLog() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = PerfLogWriter(url: url)

        await writer.append(
            MirrorStats(fps: 60, totalFrames: 100, dropped: 0, averageLatencyMs: 10),
            device: "emulator-5554",
            at: Date(timeIntervalSince1970: 1000)
        )
        await writer.append(
            MirrorStats(fps: 30, totalFrames: 50, dropped: 2, averageLatencyMs: 20),
            device: "11112222-3333-4444-5555-666677778888",
            at: Date(timeIntervalSince1970: 1000)
        )

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        let devices = try lines.map { line -> String in
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            )
            return try XCTUnwrap(object["device"] as? String)
        }
        XCTAssertEqual(Set(devices), ["emulator-5554", "11112222-3333-4444-5555-666677778888"])
    }

    func testFromEnvironment() {
        XCTAssertNil(PerfLogWriter.fromEnvironment([:]))
        XCTAssertNil(PerfLogWriter.fromEnvironment(["DHP_PERF_LOG": ""]))
        XCTAssertNotNil(PerfLogWriter.fromEnvironment(["DHP_PERF_LOG": "/tmp/perf.jsonl"]))
    }
}
