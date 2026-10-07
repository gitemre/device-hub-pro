import XCTest
@testable import DeviceHubProKit

/// The simulator memory measurement against a real booted simulator, behind
/// `DHP_IOS_LIVE=1`:
///
///     DHP_IOS_LIVE=1 swift test --filter DeviceProcessMemoryLiveTests
///
/// Creates its own iPhone in a private device set (`LiveTestSimulators`),
/// boots it, prints the kit's number for it (`MEM-LIVE`) next to the pids of
/// its launchd_sim tree and the output of `/usr/bin/footprint` for those same
/// pids, then deletes the device. The number is compared by eye / by the
/// printed total: footprint is read twice, so a few percent of drift is
/// normal on a live device.
final class DeviceProcessMemoryLiveTests: XCTestCase {
    func testMeasurementOnAPrivateSetSimulatorMatchesFootprint() async throws {
        let toolchain = try await LiveTestSimulators.toolchain()
        let session = try LiveTestSimulators.Session(toolchain: toolchain)
        do {
            let device = try await session.createDevice(name: "DeviceHubPro-Live-Memory")
            try await session.simctl.boot(udid: device.udid)
            try await session.simctl.bootStatus(udid: device.udid)
            // Let the first-boot daemons settle.
            try await Task.sleep(for: .seconds(10))

            let table = LiveProcessTable()
            let entries = table.entries()
            let report = DeviceProcessMemory.measure(table: table, simulatorUDIDs: [device.udid])
            let kitBytes = try XCTUnwrap(report.simulators[device.udid], "no launchd_sim tree found")

            // The same tree, spelled out for footprint(1).
            let root = try XCTUnwrap(entries.first {
                $0.name == "launchd_sim" && table.arguments(of: $0.pid).joined().contains(device.udid)
            })
            var pids: [Int32] = [root.pid]
            var index = 0
            while index < pids.count {
                let parent = pids[index]
                index += 1
                pids += entries.filter { $0.parentPid == parent && !pids.contains($0.pid) }.map(\.pid)
            }
            let summed = pids.reduce(UInt64(0)) { $0 + (table.footprint(of: $1) ?? 0) }

            var footprintTotal: UInt64 = 0
            let output = try Self.footprint(pids: pids)
            for line in output.split(separator: "\n") where line.contains("Footprint:") {
                print("MEM-LIVE footprint(1) line: \(line)")
            }
            if let number = Self.parseTotal(output) { footprintTotal = number }
            print("MEM-LIVE pids=\(pids.count) kit=\(kitBytes) bytes (\(DeviceProcessMemory.format(kitBytes))) resum=\(summed) footprint(1) total=\(footprintTotal)")
            XCTAssertGreaterThan(kitBytes, 50 << 20)
            XCTAssertLessThan(kitBytes, 6 << 30)
        } catch {
            let leftovers = await session.tearDown()
            XCTAssertEqual(leftovers, [])
            throw error
        }
        let leftovers = await session.tearDown()
        XCTAssertEqual(leftovers, [])
    }

    /// `/usr/bin/footprint -f bytes --noCategories -p <pid> ...`
    private static func footprint(pids: [Int32]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/footprint")
        process.arguments = ["-f", "bytes", "--noCategories"] + pids.flatMap { ["-p", String($0)] }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Sums the "Footprint: N bytes" figure of each process section (the
    /// per-process total lines of `--noCategories`).
    private static func parseTotal(_ output: String) -> UInt64? {
        var total: UInt64 = 0
        var found = false
        for line in output.split(separator: "\n") {
            // Only the per-process lines ("name [pid]: 64-bit  Footprint: N B"),
            // not a combined total.
            guard line.contains("]: "), let range = line.range(of: "Footprint: ") else { continue }
            let digits = line[range.upperBound...].prefix { $0.isNumber }
            if let value = UInt64(digits) {
                total += value
                found = true
            }
        }
        return found ? total : nil
    }
}
