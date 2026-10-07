import Foundation
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The scrubbed captures of the dedicated test iPhone under
/// `DeviceHubProKitTests/Fixtures/ios27-device/` (provenance in
/// `ApplePhysicalDeviceTests`), replayed byte for byte by the stub devicectl
/// below. The hardware UDID and CoreDevice identifier are the captures'
/// same-length placeholders, not a real device's.
enum PhysicalFixtures {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("DeviceHubProKitTests/Fixtures/ios27-device", isDirectory: true)

    static let udid = "00000000-0000000000000000"
    static let coreDeviceIdentifier = "00000000-0000-4000-8000-000000000001"

    static func url(_ name: String) -> URL {
        root.appendingPathComponent(name)
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    /// A stub arm body: copies the fixture to the call's `--json-output`
    /// path (devicectl's file form).
    static func json(_ name: String, exitCode: Int32 = 0) -> String {
        json(from: url(name).path, exitCode: exitCode)
    }

    static func json(from path: String, exitCode: Int32 = 0) -> String {
        "\(copy(from: path)); exit \(exitCode)"
    }

    /// The shell that copies the file at `path` to the call's
    /// `--json-output` path, without ending the arm.
    static func copy(from path: String) -> String {
        "PREV=\"\"; for ARG in \"$@\"; do if [ \"$PREV\" = \"--json-output\" ]; then cp \(SimulatorFixtures.quoted(path)) \"$ARG\"; fi; PREV=\"$ARG\"; done"
    }

    /// A stub arm body for a capture: the JSON to `--json-output` and a
    /// small file to `--destination`.
    static func capture(_ name: String, exitCode: Int32 = 0) -> String {
        """
        PREV=""; for ARG in "$@"; do
          if [ "$PREV" = "--json-output" ]; then cp \(SimulatorFixtures.quoted(url(name).path)) "$ARG"; fi
          if [ "$PREV" = "--destination" ]; then printf 'captured' > "$ARG"; fi
          PREV="$ARG"
        done; exit \(exitCode)
        """
    }

    /// The test iPhone as the lister reads it from the list capture,
    /// optionally edited (`edit` gets the physical entry's dictionary).
    static func device(edit: ((inout [String: Any]) -> Void)? = nil) throws -> ApplePhysicalDevice {
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: try data("devicectl-list-devices.json")) as? [String: Any])
        var result = try XCTUnwrap(document["result"] as? [String: Any])
        var entries = try XCTUnwrap(result["devices"] as? [[String: Any]])
        let index = try XCTUnwrap(entries.firstIndex {
            ($0["hardwareProperties"] as? [String: Any])?["reality"] as? String == "physical"
        })
        if let edit { edit(&entries[index]) }
        result["devices"] = entries
        document["result"] = result
        let edited = try JSONSerialization.data(withJSONObject: document)
        let optIn = try XCTUnwrap(PhysicalDeviceOptIn(allowedHardwareUDIDs: [udid]))
        return try XCTUnwrap(ApplePhysicalDeviceLister.devices(fromListJSON: edited, optIn: optIn).first)
    }

    static func entry(
        enabled: Bool = true,
        edit: ((inout [String: Any]) -> Void)? = nil
    ) throws -> ApplePhysicalEntry {
        ApplePhysicalEntry(device: try device(edit: edit), isEnabled: enabled)
    }
}

extension XCTestCase {
    /// A stub devicectl answering `list devices` with the capture and the
    /// `device info` reads with theirs; `extra` arms come first.
    func makePhysicalStub(extra: String = "", listBody: String? = nil) throws -> StubTool {
        try makeStubTool("devicectl", arms: """
          \(extra)
          *"list devices"*)
            \(listBody ?? PhysicalFixtures.json("devicectl-list-devices.json")) ;;
          *"device info details"*)
            \(PhysicalFixtures.json("devicectl-info-details.json")) ;;
          *"device info lockState"*)
            \(PhysicalFixtures.json("devicectl-info-lockState.json")) ;;
          *"device info ddiServices"*)
            \(PhysicalFixtures.json("devicectl-info-ddiServices.json")) ;;
          *"device info displays"*)
            \(PhysicalFixtures.json("devicectl-info-displays.json")) ;;
        """)
    }

    /// An inventory on a stub devicectl, its preferences and launch
    /// restriction its own. `pollInterval` is short so a poll shows in a
    /// test; the app is treated as active.
    @MainActor
    func makePhysicalInventory(
        stub: StubTool,
        preferences: AppPreferences = AppPreferences(defaults: .scratch()),
        iphoneUDID: String? = nil,
        pollInterval: Duration = .milliseconds(40)
    ) throws -> ApplePhysicalInventory {
        let tooling = AppleTooling.stubbed(
            simctl: nil,
            devicectl: stub,
            devicesDirectory: try makeTemporaryFolder("set"),
            logsDirectory: try makeTemporaryFolder("logs")
        )
        let inventory = ApplePhysicalInventory(
            preferences: preferences,
            iphoneUDID: iphoneUDID,
            toolchain: { await tooling.probe() },
            pollInterval: pollInterval,
            isAppActive: { true }
        )
        addTeardownBlock { @MainActor in inventory.stop() }
        return inventory
    }

    /// An inventory with the test iPhone listed and (unless `enabled` is
    /// false) enabled, its list read.
    @MainActor
    func makeListedPhysicalInventory(stub: StubTool, enabled: Bool = true) async throws -> ApplePhysicalInventory {
        let preferences = AppPreferences(defaults: .scratch())
        if enabled { preferences.setPhysicalAppleDevice(PhysicalFixtures.udid, enabled: true) }
        let inventory = try makePhysicalInventory(stub: stub, preferences: preferences, pollInterval: .seconds(60))
        inventory.setShowing(true)
        let listed = await physicalWait { inventory.entries.first?.state == (enabled ? .ready : .notEnabled) }
        XCTAssertTrue(listed)
        return inventory
    }
}

/// Polls `condition` until it holds or `timeout` passes.
@MainActor
func physicalWait(
    _ timeout: Duration = .seconds(5),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        // Ends early when the test task is cancelled.
        try? await Task.sleep(for: .milliseconds(15))
    }
    return condition()
}

extension StubTool {
    /// The calls that are the physical list.
    var listCalls: [String] { calls.filter { $0.contains("list devices") } }
    /// Every call that is not the list: what reached a device itself.
    var deviceCalls: [String] { calls.filter { !$0.contains("list devices") } }
}
