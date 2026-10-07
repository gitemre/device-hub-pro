import XCTest
@testable import DeviceHubProKit

/// A fake process table: the shapes are made up for the arithmetic; the
/// live path is compared against `footprint(1)` by hand (see the commit).
private struct FakeTable: ProcessTable {
    var list: [ProcessEntry]
    var args: [Int32: [String]] = [:]
    var footprints: [Int32: UInt64] = [:]
    func entries() -> [ProcessEntry] { list }
    func arguments(of pid: Int32) -> [String] { args[pid] ?? [] }
    func footprint(of pid: Int32) -> UInt64? { footprints[pid] }
}

final class DeviceProcessMemoryTests: XCTestCase {
    private let udidA = "AAAAAAAA-1111-2222-3333-444444444444"
    private let udidB = "BBBBBBBB-1111-2222-3333-444444444444"

    func testSumsTheWholeLaunchdSimTreeOfEachDevice() {
        let table = FakeTable(
            list: [
                ProcessEntry(pid: 1, parentPid: 0, name: "launchd"),
                ProcessEntry(pid: 10, parentPid: 1, name: "launchd_sim"),
                ProcessEntry(pid: 11, parentPid: 10, name: "SpringBoard"),
                ProcessEntry(pid: 12, parentPid: 11, name: "MyApp"),
                ProcessEntry(pid: 20, parentPid: 1, name: "launchd_sim"),
                ProcessEntry(pid: 21, parentPid: 20, name: "SpringBoard"),
                ProcessEntry(pid: 99, parentPid: 1, name: "Safari"),
            ],
            args: [
                10: ["/x/Devices/\(udidA)/data/launchd_sim"],
                20: ["/x/Devices/\(udidB)/data/launchd_sim"],
            ],
            footprints: [10: 100, 11: 200, 12: 300, 20: 5, 21: 7, 99: 1_000_000]
        )
        let report = DeviceProcessMemory.measure(table: table, simulatorUDIDs: [udidA, udidB])
        XCTAssertEqual(report.simulators[udidA], 600)
        XCTAssertEqual(report.simulators[udidB], 12)
    }

    func testAShutDownDeviceAndAnUnknownLaunchdSimAreNotReported() {
        let table = FakeTable(
            list: [ProcessEntry(pid: 10, parentPid: 1, name: "launchd_sim")],
            args: [10: ["/x/Devices/CCCCCCCC-0000-0000-0000-000000000000/launchd_sim"]],
            footprints: [10: 50]
        )
        let report = DeviceProcessMemory.measure(table: table, simulatorUDIDs: [udidA])
        XCTAssertTrue(report.simulators.isEmpty)
    }

    func testAnUnreadableChildCountsAsZeroAndACycleTerminates() {
        let table = FakeTable(
            list: [
                ProcessEntry(pid: 10, parentPid: 11, name: "launchd_sim"),
                ProcessEntry(pid: 11, parentPid: 10, name: "loop"),
                ProcessEntry(pid: 12, parentPid: 10, name: "gone"),
            ],
            args: [10: [udidA]],
            footprints: [10: 1, 11: 2]
        )
        XCTAssertEqual(DeviceProcessMemory.measure(table: table, simulatorUDIDs: [udidA]).simulators[udidA], 3)
    }

    func testEmulatorQemuProcessIsMatchedByAvdNameAndPort() {
        let table = FakeTable(
            list: [
                ProcessEntry(pid: 30, parentPid: 1, name: "qemu-system-aarc"),
                ProcessEntry(pid: 31, parentPid: 1, name: "qemu-system-x86_"),
            ],
            args: [
                30: ["qemu-system-aarch64", "-avd", "Pixel_8", "-ports", "5554,5555"],
                31: ["qemu-system-x86_64", "@Tablet", "-port", "5556"],
            ],
            footprints: [30: 3 << 30, 31: 2 << 30]
        )
        let report = DeviceProcessMemory.measure(table: table, simulatorUDIDs: [])
        XCTAssertEqual(report.emulatorBytes(avdName: "Pixel_8"), 3 << 30)
        XCTAssertEqual(report.emulatorBytes(serial: "emulator-5554"), 3 << 30)
        XCTAssertEqual(report.emulatorBytes(avdName: "Tablet"), 2 << 30)
        XCTAssertEqual(report.emulatorBytes(serial: "emulator-5556"), 2 << 30)
        XCTAssertNil(report.emulatorBytes(avdName: "Nope"))
    }

    func testFormatAndThreshold() {
        XCTAssertEqual(DeviceProcessMemory.format(640 << 20), "640 MB")
        XCTAssertEqual(DeviceProcessMemory.format((1 << 30) + (800 << 20)), "1.8 GB")
        XCTAssertEqual(DeviceProcessMemory.warningThreshold, 4 << 30)
    }

    func testLiveTableSeesThisProcess() {
        let table = LiveProcessTable()
        let me = getpid()
        XCTAssertTrue(table.entries().contains { $0.pid == me })
        XCTAssertGreaterThan(table.footprint(of: me) ?? 0, 0)
        XCTAssertFalse(table.arguments(of: me).isEmpty)
    }
}
