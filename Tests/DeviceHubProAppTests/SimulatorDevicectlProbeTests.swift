import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// T2: devicectl is asked about a simulator the user booted
/// and selected once per CoreDevice version, and its answer is kept in the
/// preferences under that version. The stubs replay the real captures (the
/// devicectl `info details` of an iPhone 17 Pro on iOS 27.0, CoreDevice
/// 642.16; the booted listing of `SimctlFixtureTests`).
@MainActor
final class SimulatorDevicectlProbeTests: XCTestCase {
    /// The booted device of `simctl-list-j-devices.booted.json`.
    private static let booted = "95D9676B-3317-4BA5-8CF6-3CDD0488CACA"

    private func simctl(list: String = "simctl-list-j-devices.booted.json") throws -> StubTool {
        try makeStubTool("simctl", arms: """
          *"list -j devices")
            \(SimulatorFixtures.cat(list)) ;;
          *"list -j runtimes")
            \(SimulatorFixtures.cat("simctl-list-j-runtimes.json")) ;;
          *"list -j devicetypes")
            \(SimulatorFixtures.cat("simctl-list-j-devicetypes.json")) ;;
        """)
    }

    private func devicectl(answering: Bool = true) throws -> StubTool {
        let details = SimulatorFixtures.cat("devicectl-device-info-details.json", folder: "devicectl")
        return try makeStubTool("devicectl", arms: answering ? """
          "device info details --device "*" -j - -t 30")
            \(details) ;;
        """ : "")
    }

    /// Apple tooling whose devicectl reports an installed CoreDevice
    /// `coreDevice` (not an override), on the default set.
    private func tooling(simctl: StubTool, devicectl: StubTool, coreDevice: String? = "642.16", privateSet: Bool = false) throws -> AppleTooling {
        let developer = try makeTemporaryFolder("developer")
        let set = try makeTemporaryFolder("set")
        let toolchain = AppleToolchain(
            developerDirectory: developer,
            xcodeVersion: "27.0",
            xcodeBuild: "27A266a",
            firstLaunchComplete: true,
            simctl: .init(binary: simctl.url, installedVersion: nil, expectedVersion: nil, needsFirstLaunch: false, isOverride: true),
            devicectl: .init(binary: devicectl.url, installedVersion: coreDevice, expectedVersion: coreDevice, needsFirstLaunch: false)
        )
        return AppleTooling(
            probe: { toolchain },
            deviceSet: privateSet ? set : nil,
            devicesDirectory: set,
            logsDirectory: try makeTemporaryFolder("logs")
        )
    }

    private func inventory(_ apple: AppleTooling, preferences: AppPreferences) -> SimulatorInventory {
        let inventory = SimulatorInventory(apple: apple, preferences: preferences)
        addTeardownBlock { @MainActor in inventory.stop() }
        return inventory
    }

    /// The first booted simulator is asked once; the answer makes T2 and is
    /// kept under CoreDevice 642.16. A later launch on the same CoreDevice is
    /// T2 without asking at all.
    func testTheAnswerIsKeptPerCoreDeviceVersion() async throws {
        let defaults = UserDefaults.scratch()
        let preferences = AppPreferences(defaults: defaults)
        let devicectl = try devicectl()
        let first = inventory(try tooling(simctl: try simctl(), devicectl: devicectl), preferences: preferences)
        await first.refresh()
        XCTAssertEqual(first.tooling.tier, .t1)
        XCTAssertFalse(first.devicectlReady)

        let answered = await first.probeDevicectlIfNeeded(udid: Self.booted)
        XCTAssertTrue(answered)
        XCTAssertEqual(first.tooling.tier, .t2)
        XCTAssertTrue(first.devicectlReady)
        XCTAssertEqual(devicectl.calls, ["device info details --device \(Self.booted) -j - -t 30"])
        let kept = try XCTUnwrap(preferences.simulatorDevicectlProbe)
        XCTAssertEqual(kept.coreDeviceVersion, "642.16")
        XCTAssertEqual(kept.info.jsonVersion, 5)
        XCTAssertEqual(kept.info.version, "642.16")
        XCTAssertTrue(kept.info.succeeded)

        let again = await first.probeDevicectlIfNeeded(udid: Self.booted)
        XCTAssertTrue(again)
        XCTAssertEqual(devicectl.calls.count, 1, "asked once")

        // A new launch reads the kept answer from the same defaults.
        let relaunchDevicectl = try self.devicectl()
        let second = inventory(
            try tooling(simctl: try simctl(), devicectl: relaunchDevicectl),
            preferences: AppPreferences(defaults: defaults)
        )
        await second.refresh()
        XCTAssertEqual(second.tooling.tier, .t2)
        let secondAnswer = await second.probeDevicectlIfNeeded(udid: Self.booted)
        XCTAssertTrue(secondAnswer)
        XCTAssertEqual(relaunchDevicectl.calls, [], "no probe on the same CoreDevice")
    }

    /// An answer kept for another CoreDevice does not count: the new one is
    /// asked, and its answer replaces the old.
    func testAnotherCoreDeviceAsksAgain() async throws {
        let preferences = AppPreferences(defaults: .scratch())
        let old = try DevicectlJSON.info(from: Data(contentsOf: SimulatorFixtures.url("devicectl-device-info-details.json", folder: "devicectl")))
        preferences.setSimulatorDevicectlProbe(CachedDevicectlProbe(coreDeviceVersion: "642.15", info: old))
        let devicectl = try devicectl()
        let inventory = inventory(try tooling(simctl: try simctl(), devicectl: devicectl), preferences: preferences)
        await inventory.refresh()
        XCTAssertEqual(inventory.tooling.tier, .t1)

        await inventory.probeDevicectlIfNeeded(udid: Self.booted)
        XCTAssertEqual(devicectl.calls.count, 1)
        XCTAssertEqual(preferences.simulatorDevicectlProbe?.coreDeviceVersion, "642.16")
    }

    /// Only a booted, listed default-set simulator is asked; a failed answer
    /// keeps T1, is not kept, and that simulator is not asked again in the
    /// run.
    func testWhoIsAskedAndAFailedAnswer() async throws {
        let preferences = AppPreferences(defaults: .scratch())
        let silent = try devicectl(answering: false)
        let inventory = inventory(try tooling(simctl: try simctl(), devicectl: silent), preferences: preferences)
        await inventory.refresh()

        let unknown = await inventory.probeDevicectlIfNeeded(udid: "00000000-0000-0000-0000-000000000000")
        XCTAssertFalse(unknown)
        XCTAssertEqual(silent.calls, [], "not a listed simulator")

        let failed = await inventory.probeDevicectlIfNeeded(udid: Self.booted)
        XCTAssertFalse(failed)
        XCTAssertEqual(silent.calls.count, 1)
        XCTAssertEqual(inventory.tooling.tier, .t1)
        XCTAssertNil(preferences.simulatorDevicectlProbe)
        // A failed answer is not definitive: it is asked again, a few times.
        for expected in 2...SimulatorInventory.maxDevicectlAttempts {
            await inventory.probeDevicectlIfNeeded(udid: Self.booted)
            XCTAssertEqual(silent.calls.count, expected)
        }
        await inventory.probeDevicectlIfNeeded(udid: Self.booted)
        XCTAssertEqual(silent.calls.count, SimulatorInventory.maxDevicectlAttempts, "then given up for the run")

        // A shut-down simulator (the default set: none booted).
        let shutDown = try devicectl()
        let other = self.inventory(
            try tooling(simctl: try simctl(list: "simctl-list-j-devices.default-set.json"), devicectl: shutDown),
            preferences: AppPreferences(defaults: .scratch())
        )
        await other.refresh()
        let stopped = try XCTUnwrap(other.simulators.first { $0.state == .shutdown })
        let askedStopped = await other.probeDevicectlIfNeeded(udid: stopped.udid)
        XCTAssertFalse(askedStopped)
        XCTAssertEqual(shutDown.calls, [], "a simulator that is off is not asked")
    }

    /// A caller that arrives while the probe runs waits for its answer
    /// instead of being told devicectl is not ready (first-run Controls).
    func testALaterCallerAwaitsTheProbeInFlight() async throws {
        let devicectl = try makeStubTool("devicectl", arms: """
          "device info details --device "*" -j - -t 30")
            sleep 1; \(SimulatorFixtures.cat("devicectl-device-info-details.json", folder: "devicectl")) ;;
        """)
        let inventory = inventory(try tooling(simctl: try simctl(), devicectl: devicectl), preferences: AppPreferences(defaults: .scratch()))
        await inventory.refresh()
        async let first = inventory.probeDevicectlIfNeeded(udid: Self.booted)
        async let second = inventory.probeDevicectlIfNeeded(udid: Self.booted)
        let answers = await [first, second]
        XCTAssertEqual(answers, [true, true])
        XCTAssertEqual(devicectl.calls.count, 1, "one probe, awaited by both")
    }

    /// A private set is never asked, and a kept answer does not apply to it.
    func testAPrivateSetIsNeverT2() async throws {
        let preferences = AppPreferences(defaults: .scratch())
        let info = try DevicectlJSON.info(from: Data(contentsOf: SimulatorFixtures.url("devicectl-device-info-details.json", folder: "devicectl")))
        preferences.setSimulatorDevicectlProbe(CachedDevicectlProbe(coreDeviceVersion: "642.16", info: info))
        let devicectl = try devicectl()
        let inventory = inventory(try tooling(simctl: try simctl(), devicectl: devicectl, privateSet: true), preferences: preferences)
        await inventory.refresh()

        XCTAssertEqual(inventory.tooling.tier, .t1)
        XCTAssertFalse(inventory.devicectlReady)
        let asked = await inventory.probeDevicectlIfNeeded(udid: Self.booted)
        XCTAssertFalse(asked)
        XCTAssertEqual(devicectl.calls, [])
    }

    /// The kept answer round-trips through the defaults as JSON with
    /// devicectl's own keys.
    func testTheKeptAnswerRoundTrips() throws {
        let defaults = UserDefaults.scratch()
        let info = try DevicectlJSON.info(from: Data(contentsOf: SimulatorFixtures.url("devicectl-device-info-details.json", folder: "devicectl")))
        AppPreferences(defaults: defaults).setSimulatorDevicectlProbe(CachedDevicectlProbe(coreDeviceVersion: "642.16", info: info))
        XCTAssertEqual(AppPreferences(defaults: defaults).simulatorDevicectlProbe?.info, info)
        let stored = try XCTUnwrap(defaults.data(forKey: AppPreferences.Keys.simulatorDevicectlProbe))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        let infoObject = try XCTUnwrap(object["info"] as? [String: Any])
        XCTAssertEqual(Set(infoObject.keys), ["arguments", "commandType", "jsonVersion", "outcome", "version"])
        XCTAssertEqual(object["coreDeviceVersion"] as? String, "642.16")

        AppPreferences(defaults: defaults).setSimulatorDevicectlProbe(nil)
        XCTAssertNil(defaults.data(forKey: AppPreferences.Keys.simulatorDevicectlProbe))
    }
}
