import XCTest
@testable import DeviceHubProKit

/// The exact commands behind the Network and App conditions rows, their
/// input validation and their support gates.
final class ConditionsCommandTests: XCTestCase {
    private let serial = "emulator-5554"

    // MARK: - Network conditions

    func testMeterCommands() async throws {
        let adb = try FakeAdb([.init("emu gsm", output: "OK\r\n")])
        try await adb.client.setEmulatorMobileDataMetered(serial: serial, metered: false)
        try await adb.client.setEmulatorMobileDataMetered(serial: serial, metered: true)
        XCTAssertEqual(adb.calls, [
            "-s emulator-5554 emu gsm meter off",
            "-s emulator-5554 emu gsm meter on",
        ])
    }

    /// Which emulator answers: its console's `avd name` and `avd
    /// discoverypath`, both needed.
    func testEmulatorInstanceReadsTheAvdAndItsProcess() async throws {
        let adb = try FakeAdb([
            .init("emu avd name", output: try AdbCoreFixtureTests.text("emu-avd-name.txt")),
            .init("emu avd discoverypath", output: try ConditionsAPI37Fixture.text("emu-avd-discoverypath-second-process.txt")),
        ])
        let instance = await adb.client.emulatorInstance(serial: serial)
        XCTAssertEqual(instance, EmulatorInstance(
            avdName: "Pixel_9_Pro_Fold",
            discoveryPath: "/Users/testeruser/Library/Caches/TemporaryItems/avd/running/pid_20284.ini"
        ))
        XCTAssertEqual(Set(adb.calls), ["-s emulator-5554 emu avd name", "-s emulator-5554 emu avd discoverypath"])

        let silent = try FakeAdb([
            .init("emu avd name", output: try AdbCoreFixtureTests.text("emu-avd-name.txt")),
            .init("emu avd discoverypath", exitCode: 1),
        ])
        let unanswered = await silent.client.emulatorInstance(serial: serial)
        XCTAssertNil(unanswered, "a console that does not name its process identifies nothing")
    }

    /// The probe is one shell round trip.
    func testNetworkReadIsOneShellCall() async throws {
        let adb = try FakeAdb([
            .init("@@devicehubpro:net:", output: try ConditionsAPI37Fixture.text("network-probe-mobile-data.txt")),
        ])
        let snapshot = try await adb.client.networkConditions(serial: serial)
        XCTAssertEqual(snapshot.connectivity.dataPath, .mobileData)
        XCTAssertEqual(adb.calls.count, 1)
    }

    func testCustomLatencyValidation() {
        XCTAssertEqual(ConnectionLatency.custom(minimum: "100", maximum: "300"), .success(ConnectionLatency(minimumMs: 100, maximumMs: 300)))
        XCTAssertEqual(ConnectionLatency.custom(minimum: " 1 ", maximum: "1"), .success(ConnectionLatency(minimumMs: 1, maximumMs: 1)))
        XCTAssertEqual(ConnectionLatency.custom(minimum: "0", maximum: "500"), .failure(.minimumBelowOne))
        XCTAssertEqual(ConnectionLatency.custom(minimum: "500", maximum: "200"), .failure(.minimumAboveMaximum))
        XCTAssertEqual(ConnectionLatency.custom(minimum: "", maximum: "200"), .failure(.notANumber))
        XCTAssertEqual(ConnectionLatency.custom(minimum: "1.5", maximum: "200"), .failure(.notANumber))
        XCTAssertEqual(ConnectionLatency.custom(minimum: "-5", maximum: "200"), .failure(.minimumBelowOne))
        XCTAssertEqual(
            ConnectionLatency.custom(minimum: "10", maximum: "\(ConnectionLatency.customLimitMs + 1)"),
            .failure(.aboveLimit(ConnectionLatency.customLimitMs))
        )
    }

    /// The presets are external/qemu constants.h's latency columns; the
    /// 0–0 profiles (HSDPA, LTE, EVDO, 5G) delay nothing and are left out.
    func testLatencyPresets() {
        XCTAssertEqual(LatencyPreset.allCases.map(\.latency), [
            ConnectionLatency(minimumMs: 0, maximumMs: 0),
            ConnectionLatency(minimumMs: 35, maximumMs: 200),
            ConnectionLatency(minimumMs: 80, maximumMs: 400),
            ConnectionLatency(minimumMs: 150, maximumMs: 550),
        ])
        XCTAssertTrue(LatencyPreset.allCases.dropFirst().allSatisfy(\.latency.isActive))
        XCTAssertEqual(ConnectionLatency(minimumMs: 0, maximumMs: 500).isActive, false)
    }

    func testDataPathFromTransports() {
        func reading(_ transports: [String], default id: Int? = 1) -> ConnectivityReading {
            ConnectivityReading(
                defaultNetworkID: id,
                answered: true,
                agents: [NetworkAgent(id: 1, transports: transports, capabilities: [], interfaceName: nil)]
            )
        }
        XCTAssertEqual(reading(["CELLULAR"]).dataPath, .mobileData)
        XCTAssertEqual(reading(["WIFI"]).dataPath, .wifi)
        XCTAssertEqual(reading(["ETHERNET"]).dataPath, .other("ETHERNET"))
        XCTAssertEqual(reading(["WIFI"], default: nil).dataPath, .noNetwork)
        XCTAssertNil(ConnectivityReading.parse("").dataPath, "an unanswered dump is unknown, not no network")
        // A dump that answers `none`: `ConditionsDeviceOutputTests.testTheNoNetworkProbe`.
    }

    // MARK: - App conditions

    func testAppCommands() async throws {
        let adb = try FakeAdb([])
        try await adb.client.sendTrimMemory(serial: serial, package: "com.example.app", level: .uiHidden)
        try await adb.client.killBackgroundProcesses(serial: serial, package: "com.example.app")
        XCTAssertEqual(adb.calls, [
            // UI_HIDDEN is `HIDDEN` for am.
            "-s emulator-5554 shell am send-trim-memory --user current com.example.app HIDDEN",
            "-s emulator-5554 shell am kill --user current com.example.app",
        ])
    }

    /// A package name reaches the device shell quoted when it needs it.
    func testTheAppProbeQuotesThePackage() {
        let script = AppConditionsSnapshot.probeScript(package: "com.example;reboot")
        XCTAssertTrue(script.contains("pidof 'com.example;reboot'"), script)
        XCTAssertFalse(script.contains("pidof com.example;reboot"))
    }

    func testTrimLevelTokensAndGates() {
        XCTAssertEqual(TrimMemoryLevel.allCases.map(\.commandToken), [
            "RUNNING_MODERATE", "RUNNING_LOW", "RUNNING_CRITICAL", "HIDDEN", "BACKGROUND", "MODERATE", "COMPLETE",
        ])
        XCTAssertEqual(TrimMemoryLevel.allCases.map(\.rawValue), [5, 10, 15, 20, 40, 60, 80])
        XCTAssertEqual(TrimMemoryLevel.allCases.filter(\.isBackgroundLevel), [.uiHidden, .background, .moderate, .complete])

        let foreground = AppProcessState(processName: "p", pid: 1, trimMemoryLevel: 0, procState: 6)
        let cached = AppProcessState(processName: "p", pid: 1, trimMemoryLevel: 0, procState: 19)
        XCTAssertEqual(TrimMemoryGate.evaluate(.uiHidden, process: foreground, apiLevel: 37), .foreground(procState: 6))
        XCTAssertEqual(TrimMemoryGate.evaluate(.runningCritical, process: foreground, apiLevel: 37), .allowed)
        XCTAssertEqual(TrimMemoryGate.evaluate(.complete, process: cached, apiLevel: 37), .allowed)
        // Before API 30 the process-state numbering differs: AMS decides.
        XCTAssertEqual(TrimMemoryGate.evaluate(.uiHidden, process: foreground, apiLevel: 29), .allowed)
        XCTAssertEqual(TrimMemoryGate.evaluate(.runningLow, process: cached, apiLevel: 22), .unsupported)
        XCTAssertEqual(TrimMemoryGate.evaluate(.runningLow, process: nil, apiLevel: 37), .notRunning)
        XCTAssertNil(TrimMemoryGate.allowed.reason)
        XCTAssertNotNil(TrimMemoryGate.notHigher(current: 40).reason)
    }
}
