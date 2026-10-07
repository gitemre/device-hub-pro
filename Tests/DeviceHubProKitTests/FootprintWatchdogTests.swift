import Foundation
import Synchronization
import XCTest
@testable import DeviceHubProKit

final class FootprintWatchdogTests: XCTestCase {
    private func makeLog() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicehubpro-footprint-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("footprint.log")
    }

    private func lines(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func testItLogsCrossingsHeartbeatsAndTheBreakdown() {
        let url = makeLog()
        let value = Mutex<UInt64>(100 << 20)
        let breakdowns = Mutex(0)
        let watchdog = FootprintWatchdog(
            url: url,
            thresholds: [1 << 30, 2 << 30],
            heartbeatEvery: 3,
            breakdownLimit: 1,
            context: { "windows 2" },
            reader: { value.withLock { $0 } },
            breakdown: { breakdowns.withLock { $0 += 1 }; return "IOSurface 900 MB" }
        )
        watchdog.sample()
        watchdog.sample()
        XCTAssertEqual(lines(url).count, 0, "nothing to say below the first threshold")
        watchdog.sample()
        XCTAssertTrue(lines(url).last?.contains(" heartbeat footprint 100.0 MB") == true)

        value.withLock { $0 = 1_200 << 20 }
        watchdog.sample()
        XCTAssertTrue(lines(url).contains { $0.contains(" grew footprint 1200.0 MB") && $0.contains("| windows 2") })
        XCTAssertTrue(lines(url).contains("IOSurface 900 MB"))

        value.withLock { $0 = 2_500 << 20 }
        watchdog.sample()
        XCTAssertEqual(breakdowns.withLock { $0 }, 1, "one breakdown, as limited")

        value.withLock { $0 = 100 << 20 }
        watchdog.sample()
        XCTAssertTrue(lines(url).contains { $0.contains(" fell footprint 100.0 MB") })
    }

    func testTheLogIsRotatedPastItsLimit() {
        let url = makeLog()
        let watchdog = FootprintWatchdog(
            url: url, thresholds: [], heartbeatEvery: 1, maximumBytes: 300,
            reader: { 50 << 20 }, breakdown: { nil }
        )
        for _ in 0..<20 { watchdog.sample() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path))
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        XCTAssertLessThan(size, 600)
    }

    func testTheProcessFootprintIsReadable() {
        XCTAssertGreaterThan(MemoryFootprint.current() ?? 0, 1 << 20)
        XCTAssertNotNil(MemoryFootprint.systemFreePercent())
        XCTAssertNil(MemoryFootprint.soakAbortReason(footprintLimit: UInt64.max, minimumFreePercent: 0))
        XCTAssertNotNil(MemoryFootprint.soakAbortReason(footprintLimit: 1, minimumFreePercent: 0))
    }
}
