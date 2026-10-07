import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// Device Hub's Unavailable section and its too-old rule (S1) over a real
/// listing: `simctl-list-j-devices.unavailable.json` is `simctl --set <tmp>
/// list -j devices` (Xcode 27.0, 27A266a, CoreSimulator 1171.7, 2026-09-26)
/// of a private set holding three never-booted iPhone 17 Pro devices
/// created on iOS 27.0: one as created, two copied into a fresh set with the
/// `runtime` of their `device.plist` changed to runtimes this Mac does not
/// have (iOS 26.2, iOS 17.5), which is how a deleted runtime leaves its
/// devices. simctl lists those two as unavailable ("runtime profile not
/// found using “System” match policy"). Redaction as in
/// `SimctlFixtureTests` (the set sat in the session's scratch folder).
@MainActor
final class SimulatorUnavailableTests: XCTestCase {
    private static let available = "57115356-41CB-4225-B08F-FB0DC4159E0D"
    private static let missingRuntime = "EC1D7ABE-94C4-4FF4-9047-235ABF87C569"
    /// On iOS 17.5, which is not installed: unavailable, not too old.
    private static let missingOldRuntime = "DC327F5C-B982-438A-8208-789CEAA842CB"

    private func inventory(preferences: AppPreferences = AppPreferences(defaults: .scratch())) async throws -> SimulatorInventory {
        let simctl = try makeStubTool("simctl", arms: """
          *"list -j devices")
            \(SimulatorFixtures.cat("simctl-list-j-devices.unavailable.json")) ;;
          *"list -j runtimes")
            \(SimulatorFixtures.cat("simctl-list-j-runtimes.json")) ;;
          *"list -j devicetypes")
            \(SimulatorFixtures.cat("simctl-list-j-devicetypes.json")) ;;
        """)
        let inventory = SimulatorInventory(
            apple: .stubbed(
                simctl: simctl,
                devicesDirectory: try makeTemporaryFolder("set"),
                logsDirectory: try makeTemporaryFolder("logs")
            ),
            preferences: preferences
        )
        addTeardownBlock { @MainActor in inventory.stop() }
        await inventory.refresh()
        return inventory
    }

    /// A missing runtime makes the device unavailable, named from its
    /// identifier. Device Hub's too-old rule needs the runtime, so neither
    /// is hidden: iOS 17.5 is not older than 17.0 anyway (the rule hid it
    /// when the cutoff was an unsourced iOS 18), and a missing runtime has
    /// no equivalent iOS version to compare.
    func testUnavailableSimulatorsAreListed() async throws {
        let inventory = try await inventory()
        XCTAssertEqual(inventory.simulators.count, 3)

        let missing = try XCTUnwrap(inventory.entry(udid: Self.missingRuntime))
        XCTAssertFalse(missing.isAvailable)
        XCTAssertEqual(missing.availabilityError, "runtime profile not found using “System” match policy")
        XCTAssertEqual(missing.osLabel, "iOS 26.2")
        XCTAssertNil(missing.osBuild, "the runtime is not installed")
        XCTAssertFalse(missing.isTooOld)
        XCTAssertEqual(missing.sidebarSubtitle(runState: .stopped, operation: nil), "Unavailable")

        let old = try XCTUnwrap(inventory.entry(udid: Self.missingOldRuntime))
        XCTAssertFalse(old.isAvailable)
        XCTAssertEqual(old.osLabel, "iOS 17.5")
        XCTAssertFalse(old.isTooOld)
        XCTAssertFalse(old.isHiddenByDefault)

        XCTAssertEqual(Set(inventory.visibleSimulators.map(\.udid)), [Self.available, Self.missingRuntime, Self.missingOldRuntime])

        // The stage of an unavailable simulator says why and offers nothing.
        XCTAssertEqual(
            SimulatorStagePhase.resolve(
                isAvailable: missing.isAvailable,
                availabilityError: missing.availabilityError,
                runState: .stopped,
                operation: nil,
                platform: missing.platform
            ),
            .unavailable("runtime profile not found using “System” match policy")
        )
    }

    /// The sidebar keeps the rows' order and puts the unavailable ones in
    /// their own section.
    func testTheSidebarSections() {
        func row(_ id: String, available: Bool) -> SidebarDeviceRow {
            SidebarDeviceRow(
                selection: .simulator(id),
                title: id,
                subtitle: "Simulator",
                version: nil,
                isRunning: false,
                symbol: "iphone",
                isEmulator: true,
                platform: .apple,
                isAvailable: available
            )
        }
        let rows = [row("a", available: true), row("b", available: false), row("c", available: true), row("d", available: false)]
        let groups = SidebarArrangement.groups(rows, mode: .name, showGroups: true)
        XCTAssertEqual(groups.last?.title, "Unavailable")
        XCTAssertEqual(groups.last?.rows.map(\.title), ["b", "d"])
        XCTAssertEqual(groups.dropLast().flatMap(\.rows).map(\.title), ["a", "c"])
        XCTAssertTrue(SidebarDeviceRow(
            selection: .avd("Pixel"), title: "Pixel", subtitle: "Emulator", version: nil,
            isRunning: false, symbol: "smartphone", isEmulator: true, platform: .android
        ).isAvailable, "Android rows are available")
    }

    /// An installed runtime below iOS 17.0, or a tvOS, watchOS or visionOS
    /// one of that generation, is hidden; iOS 17.0 and later stay, as in
    /// Device Hub (see `SimulatorOSSupport` for where the cutoff comes from).
    func testTheEquivalentVersionDecides() throws {
        let device = try XCTUnwrap(try SimulatorFixtures.devices("simctl-list-j-devices.unavailable.json").first)
        func entry(runtime: SimulatorRuntime) -> SimulatorEntry {
            SimulatorEntry(
                device: SimulatorDevice(
                    udid: device.udid,
                    name: device.name,
                    state: .shutdown,
                    isAvailable: true,
                    deviceTypeIdentifier: device.deviceTypeIdentifier,
                    runtimeIdentifier: runtime.identifier
                ),
                runtimes: [runtime],
                deviceTypes: [],
                defaultDeviceUDIDs: []
            )
        }
        func runtime(_ platform: String, _ version: String) -> SimulatorRuntime {
            SimulatorRuntime(identifier: "rt.\(platform).\(version)", name: "", version: version, buildVersion: "", platform: platform, isAvailable: true)
        }
        XCTAssertTrue(entry(runtime: runtime("iOS", "16.4")).isTooOld)
        XCTAssertTrue(entry(runtime: runtime("tvOS", "16.4")).isTooOld)
        XCTAssertTrue(entry(runtime: runtime("watchOS", "9.4")).isTooOld)
        XCTAssertFalse(entry(runtime: runtime("iOS", "17.0")).isTooOld)
        XCTAssertFalse(entry(runtime: runtime("iOS", "17.5")).isTooOld)
        XCTAssertFalse(entry(runtime: runtime("tvOS", "17.4")).isTooOld)
        XCTAssertFalse(entry(runtime: runtime("watchOS", "10.4")).isTooOld)
        XCTAssertFalse(entry(runtime: runtime("xrOS", "1.1")).isTooOld)
        XCTAssertFalse(entry(runtime: runtime("iOS", "26.5")).isTooOld)
        XCTAssertTrue(entry(runtime: runtime("iOS", "16.4")).isHiddenByDefault)
    }
}
