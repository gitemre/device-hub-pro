import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// Apply to Selected's targets: each selected row resolved to its device and
/// how ready it is when the action runs.
final class BatchTargetingTests: XCTestCase {
    private static let udid = "95D9676B-3317-4BA5-8CF6-3CDD0488CACA"
    private static let tvUDID = "0B8E4B4C-9D8E-4F2A-9C51-2E3F7D1A6B90"
    private static let missingRuntimeUDID = "5A2C1E3B-7F40-4D6A-8B19-C0E2D4F6A8B1"

    private static func card(_ name: String, running: Bool = false, serial: String? = nil) -> AvdCard {
        AvdCard(name: name, displayName: name.replacingOccurrences(of: "_", with: " "), target: "android-36", skin: nil, isRunning: running, serial: serial)
    }

    private static func info(_ serial: String, api: String) -> DeviceInfo {
        DeviceInfo(
            serial: serial, model: "Pixel", manufacturer: "Google", androidVersion: "16",
            apiLevel: api, abi: "arm64-v8a", isEmulator: serial.hasPrefix("emulator-")
        )
    }

    private static func simulator(
        _ udid: String,
        name: String = "iPhone 17 Pro",
        osName: String = "iOS",
        runState: DeviceRunState = .ready,
        isAvailable: Bool = true
    ) -> DeviceSummary {
        DeviceSummary(
            ref: .apple(udid), kind: .simulator, name: name, osName: osName, osVersion: "27.0",
            model: name, runState: runState, isAvailable: isAvailable
        )
    }

    /// A running Pixel 9 on emulator-5554, a stopped Pixel 8, an AVD whose
    /// emulator is still offline, an AVD an in-app start is booting, a phone
    /// online, an unauthorized phone, a ghost row, a phone in recovery, and
    /// three simulators: a ready iPhone, a booting Apple TV and one whose
    /// runtime is missing.
    private static let snapshot = BatchTargeting.Snapshot(
        devices: [
            AndroidDevice(serial: "emulator-5554", state: "device"),
            AndroidDevice(serial: "emulator-5556", state: "offline"),
            AndroidDevice(serial: "R58M123", state: "device", model: "SM-S921B"),
            AndroidDevice(serial: "R58M999", state: "unauthorized"),
            AndroidDevice(serial: "GHOST01", state: "offline", model: "Pixel 7"),
            AndroidDevice(serial: "R58M777", state: "recovery"),
        ],
        avdCards: [
            card("Pixel_9", running: true, serial: "emulator-5554"),
            card("Pixel_8"),
            card("Booting_AVD", running: true, serial: "emulator-5556"),
            card("Starting_AVD"),
        ],
        startingAvdNames: ["Starting_AVD"],
        deviceInfos: [
            "emulator-5554": info("emulator-5554", api: "36"),
            "R58M123": info("R58M123", api: "?"),
        ],
        simulators: [
            simulator(udid),
            simulator(tvUDID, name: "Apple TV 4K", osName: "tvOS", runState: .booting(.waitingOnSystemApp)),
            simulator(missingRuntimeUDID, name: "iPhone 15", runState: .stopped, isAvailable: false),
        ],
        unavailableReasons: [missingRuntimeUDID: "runtime profile not found"]
    )

    private func target(_ row: DeviceSelection) throws -> BatchTarget {
        try XCTUnwrap(BatchTargeting.target(for: row, in: Self.snapshot))
    }

    func testRowKeysNeverCollideAcrossKinds() {
        XCTAssertEqual(BatchTargeting.id(for: .avd("X")), "avd:X")
        XCTAssertEqual(BatchTargeting.id(for: .device("X")), "device:X")
        XCTAssertEqual(BatchTargeting.id(for: .simulator("X")), "simulator:X")
        XCTAssertEqual(BatchTargeting.id(for: .pixel("X")), "pixel:X")
    }

    func testARunningAVDIsItsEmulator() throws {
        let pixel9 = try target(.avd("Pixel_9"))
        XCTAssertEqual(pixel9.id, "avd:Pixel_9")
        XCTAssertEqual(pixel9.readiness, .ready)
        XCTAssertEqual(pixel9.ref, .android("emulator-5554"))
        XCTAssertEqual(pixel9.kind, .emulator)
        XCTAssertEqual(pixel9.platform, .android)
        XCTAssertEqual(pixel9.name, "Pixel 9")
        XCTAssertEqual(pixel9.osLabel, "Android 16")
        XCTAssertEqual(pixel9.apiLevel, 36)
    }

    func testAnAVDThatIsNotOnlineIsStoppedOrStarting() throws {
        let stopped = try target(.avd("Pixel_8"))
        XCTAssertEqual(stopped.readiness, .stopped)
        XCTAssertNil(stopped.ref)
        // Its emulator runs, adb lists it offline: still booting.
        XCTAssertEqual(try target(.avd("Booting_AVD")).readiness, .starting)
        XCTAssertEqual(try target(.avd("Starting_AVD")).readiness, .starting)
        XCTAssertEqual(try target(.avd("Removed_AVD")).readiness, .notListed)
    }

    func testAnAdbRowTakesAdbsState() throws {
        let phone = try target(.device("R58M123"))
        XCTAssertEqual(phone.readiness, .ready)
        XCTAssertEqual(phone.kind, .physical)
        XCTAssertEqual(phone.name, "SM-S921B")
        // "?" when getprop had no answer.
        XCTAssertNil(phone.apiLevel)
        XCTAssertEqual(try target(.device("R58M999")).readiness, .unauthorized)
        XCTAssertEqual(try target(.device("GHOST01")).readiness, .offline)
        XCTAssertEqual(try target(.device("R58M777")).readiness, .unavailable("Recovery"))
        let gone = try target(.device("emulator-5570"))
        XCTAssertEqual(gone.readiness, .notListed)
        XCTAssertEqual(gone.kind, .emulator)
    }

    func testASimulatorTakesItsRunState() throws {
        let iPhone = try target(.simulator(Self.udid))
        XCTAssertEqual(iPhone.readiness, .ready)
        XCTAssertEqual(iPhone.ref, .apple(Self.udid))
        XCTAssertEqual(iPhone.osLabel, "iOS 27.0")
        XCTAssertEqual(iPhone.kind, .simulator)

        let tv = try target(.simulator(Self.tvUDID))
        XCTAssertEqual(tv.readiness, .starting)
        XCTAssertEqual(tv.osName, "tvOS")

        let missing = try target(.simulator(Self.missingRuntimeUDID))
        XCTAssertEqual(missing.readiness, .unavailable("runtime profile not found"))
        XCTAssertEqual(try target(.simulator("F00D")).readiness, .notListed)
    }

    func testTargetsKeepTheRowsOrderAndDropPixelRows() {
        let targets = BatchTargeting.targets(
            for: [.simulator(Self.udid), .pixel("pixel_9"), .avd("Pixel_9"), .device("R58M123")],
            in: Self.snapshot
        )
        XCTAssertEqual(targets.map(\.id), ["simulator:\(Self.udid)", "avd:Pixel_9", "device:R58M123"])
        XCTAssertNil(BatchTargeting.target(for: .pixel("pixel_9"), in: Self.snapshot))
    }

    func testTheTargetsPlanAsTheirReadinessSays() throws {
        let steps = BatchPlanner.plan(
            .appearance(dark: true),
            for: BatchTargeting.targets(for: [.avd("Pixel_9"), .avd("Pixel_8"), .simulator(Self.tvUDID)], in: Self.snapshot)
        )
        XCTAssertEqual(steps["avd:Pixel_9"], .run(.appearance(dark: true)))
        XCTAssertEqual(steps["avd:Pixel_8"], .skip("Not running"))
        XCTAssertEqual(steps["simulator:\(Self.tvUDID)"], .skip("Still starting"))
    }

    func testOnlyPixelAndPhysicalAppleRowsAreExcluded() {
        let rows: [DeviceSelection] = [
            .avd("Pixel_9"), .pixel("pixel_10_pro"), .device("emulator-5554"),
            .physicalApple("00008140-000000000000001C"), .simulator(Self.udid),
        ]
        XCTAssertEqual(
            BatchTargeting.excludedRows(in: rows),
            [.pixel("pixel_10_pro"), .physicalApple("00008140-000000000000001C")]
        )
        XCTAssertEqual(BatchTargeting.excludedRows(in: [.avd("A"), .device("d"), .simulator("s")]), [])
    }
}
