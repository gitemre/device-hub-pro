import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The physical Apple devices in the app: the
/// "Show physical Apple devices" preference gates every `list devices` call,
/// the poll lists while it is on, and a listed device receives no other
/// command until the user enabled it. A stub devicectl replays the real
/// captures of the dedicated test iPhone (`Fixtures/ios27-device/`).
@MainActor
final class ApplePhysicalInventoryTests: XCTestCase {
    // MARK: - The master switch

    /// The preference is off by default, and off means no `list devices`
    /// call and no other command, whatever else asks: the poll never
    /// starts, a refresh does nothing, no client is built. The runtime
    /// counter proves it (the source guard pins the spelling).
    func testPreferenceOffMakesNoListCall() async throws {
        let stub = try makePhysicalStub()
        let preferences = AppPreferences(defaults: .scratch())
        XCTAssertFalse(preferences.showPhysicalAppleDevices)
        let inventory = try makePhysicalInventory(stub: stub, preferences: preferences)
        let before = ApplePhysicalDeviceLister.listCallCount

        inventory.applyPreference()
        await inventory.refreshNow()
        let client = await inventory.client(for: PhysicalFixtures.udid)
        // Long enough for several 40 ms polls, were one running.
        try await Task.sleep(for: .milliseconds(250))
        inventory.setShowing(false)

        XCTAssertNil(client)
        XCTAssertEqual(inventory.entries, [])
        XCTAssertEqual(ApplePhysicalDeviceLister.listCallCount, before)
        XCTAssertEqual(stub.calls, [])
    }

    /// `DHP_IPHONE_UDID` restricts the app to a device; it does not turn
    /// the preference on, so with it off there is still no call.
    func testTheLaunchSwitchDoesNotTurnThePreferenceOn() async throws {
        let stub = try makePhysicalStub()
        let inventory = try makePhysicalInventory(stub: stub, iphoneUDID: PhysicalFixtures.udid)
        let before = ApplePhysicalDeviceLister.listCallCount

        inventory.applyPreference()
        await inventory.refreshNow()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(ApplePhysicalDeviceLister.listCallCount, before)
        XCTAssertEqual(stub.calls, [])
        XCTAssertEqual(inventory.entries, [])
    }

    /// A refresh asked while a listing runs is not dropped: one more listing
    /// follows, and the caller returns after it.
    func testARefreshDuringAListingQueuesOneFollowUp() async throws {
        let stub = try makePhysicalStub(
            listBody: "sleep 0.4; " + PhysicalFixtures.json("devicectl-list-devices.json")
        )
        let preferences = AppPreferences(defaults: .scratch())
        preferences.setShowPhysicalAppleDevices(true)
        let inventory = try makePhysicalInventory(stub: stub, preferences: preferences)

        let first = Task { await inventory.refreshNow() }
        try await Task.sleep(for: .milliseconds(150))
        await inventory.refreshNow()
        await inventory.refreshNow() // a third while idle is a plain listing
        await first.value

        XCTAssertEqual(stub.listCalls.count, 3, "the first, one follow-up for the second, then the third")
    }

    /// Turning it on lists at once and keeps polling; turning it off stops
    /// the poll and empties the list (the selection is then fixed up by
    /// `listChanged`).
    func testPreferenceOnPollsAndOffStops() async throws {
        let stub = try makePhysicalStub()
        let preferences = AppPreferences(defaults: .scratch())
        let inventory = try makePhysicalInventory(stub: stub, preferences: preferences)
        var changes = 0
        inventory.listChanged = { changes += 1 }
        let before = ApplePhysicalDeviceLister.listCallCount

        inventory.setShowing(true)
        XCTAssertTrue(preferences.showPhysicalAppleDevices)
        let listed = await physicalWait { inventory.entries.count == 1 && stub.listCalls.count >= 3 }
        XCTAssertTrue(listed, "the poll keeps listing: \(stub.listCalls.count) calls")

        let entry = try XCTUnwrap(inventory.entries.first)
        XCTAssertEqual(entry.name, "aqa-test-phon")
        XCTAssertEqual(entry.modelName, "iPhone 12")
        XCTAssertEqual(entry.osLabel, "iOS 27.0")
        XCTAssertEqual(entry.stateLabel, "Not enabled")
        XCTAssertTrue(inventory.hasListed)
        XCTAssertGreaterThan(changes, 0)
        XCTAssertGreaterThanOrEqual(ApplePhysicalDeviceLister.listCallCount - before, 3)

        inventory.setShowing(false)
        let stoppedAt = stub.calls.count
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(stub.calls.count, stoppedAt, "no call after the preference went off")
        XCTAssertEqual(inventory.entries, [])
        XCTAssertFalse(inventory.hasListed)
        // Only the list ever reached devicectl.
        XCTAssertEqual(stub.deviceCalls, [])
    }

    /// Two listings never overlap: a slow `list devices` is waited for, not
    /// started again on the next tick.
    func testPollsNeverOverlap() async throws {
        let marks = try makeTemporaryFolder("marks").appendingPathComponent("marks.txt")
        let quoted = SimulatorFixtures.quoted(marks.path)
        let stub = try makePhysicalStub(
            listBody: "printf S >> \(quoted); sleep 0.25; "
                + PhysicalFixtures.copy(from: PhysicalFixtures.url("devicectl-list-devices.json").path)
                + "; printf E >> \(quoted); exit 0"
        )
        let inventory = try makePhysicalInventory(stub: stub, pollInterval: .milliseconds(10))

        inventory.setShowing(true)
        let listed = await physicalWait(.seconds(8)) { stub.listCalls.count >= 3 }
        inventory.setShowing(false)
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertTrue(listed)
        let text = (try? String(contentsOf: marks, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.hasPrefix("SESE"), "listings ran one after another: \(text)")
        XCTAssertFalse(text.contains("SS"), "a listing started while another ran: \(text)")
    }

    /// A failed listing keeps the last list, and says why.
    func testAFailedListingKeepsTheLastList() async throws {
        let failMarker = try makeTemporaryFolder("fail").appendingPathComponent("fail")
        let stub = try makePhysicalStub(
            listBody: "if [ -e \(SimulatorFixtures.quoted(failMarker.path)) ]; then exit 64; fi; "
                + PhysicalFixtures.json("devicectl-list-devices.json")
        )
        let inventory = try makePhysicalInventory(stub: stub, pollInterval: .seconds(60))
        inventory.setShowing(true)
        let listed = await physicalWait { inventory.entries.count == 1 }
        XCTAssertTrue(listed)
        XCTAssertNil(inventory.listError)

        FileManager.default.createFile(atPath: failMarker.path, contents: Data())
        await inventory.refreshNow()

        XCTAssertNotNil(inventory.listError)
        XCTAssertEqual(inventory.entries.count, 1, "an empty list would read as every device unplugged")
    }

    /// While the app is not active nothing is listed (the poll waits).
    func testNoListingWhileTheAppIsInactive() async throws {
        let stub = try makePhysicalStub()
        let tooling = AppleTooling.stubbed(
            simctl: nil,
            devicectl: stub,
            devicesDirectory: try makeTemporaryFolder("set"),
            logsDirectory: try makeTemporaryFolder("logs")
        )
        var active = false
        let preferences = AppPreferences(defaults: .scratch())
        let inventory = ApplePhysicalInventory(
            preferences: preferences,
            iphoneUDID: nil,
            toolchain: { await tooling.probe() },
            pollInterval: .milliseconds(30),
            isAppActive: { active }
        )
        addTeardownBlock { @MainActor in inventory.stop() }

        inventory.setShowing(true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(stub.calls, [])

        active = true
        let listed = await physicalWait { inventory.entries.count == 1 }
        XCTAssertTrue(listed)
    }

    /// Without a usable devicectl (no Apple tooling) the preference on runs
    /// nothing and lists nothing.
    func testWithoutToolingNothingRuns() async throws {
        let preferences = AppPreferences(defaults: .scratch())
        preferences.setShowPhysicalAppleDevices(true)
        let inventory = ApplePhysicalInventory(
            preferences: preferences,
            iphoneUDID: nil,
            toolchain: { nil },
            pollInterval: .milliseconds(20),
            isAppActive: { true }
        )
        let before = ApplePhysicalDeviceLister.listCallCount
        inventory.applyPreference()
        await inventory.refreshNow()
        try await Task.sleep(for: .milliseconds(100))
        inventory.stop()
        XCTAssertEqual(inventory.entries, [])
        XCTAssertEqual(ApplePhysicalDeviceLister.listCallCount, before)
    }

    // MARK: - Restarts

    /// A restarted phone keeps its row ("Restarting\u{2026}") while devicectl
    /// does not list it, ends it when it is connected again, and gives up
    /// after three minutes.
    func testARestartKeepsTheRowUntilTheDeviceIsBackOrThreeMinutesPass() async throws {
        let marker = try makeTemporaryFolder("absent").appendingPathComponent("away")
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: try PhysicalFixtures.data("devicectl-list-devices.json")) as? [String: Any])
        var result = try XCTUnwrap(document["result"] as? [String: Any])
        result["devices"] = []
        document["result"] = result
        let empty = try makeTemporaryFolder("empty").appendingPathComponent("empty.json")
        try JSONSerialization.data(withJSONObject: document).write(to: empty)
        let body = "if [ -f \(SimulatorFixtures.quoted(marker.path)) ]; then \(PhysicalFixtures.json(from: empty.path)); else \(PhysicalFixtures.json("devicectl-list-devices.json")); fi"
        let stub = try makePhysicalStub(listBody: body)
        let inventory = try await makeListedPhysicalInventory(stub: stub)
        var clock = Date(timeIntervalSince1970: 1_000)
        inventory.now = { clock }

        inventory.beginRestart(udid: PhysicalFixtures.udid)
        XCTAssertEqual(inventory.entries.first?.state, .restarting)
        // Still listed and connected, but not yet seen away: the restart stands.
        await inventory.refreshNow()
        XCTAssertEqual(inventory.entries.first?.state, .restarting)

        FileManager.default.createFile(atPath: marker.path, contents: Data())
        await inventory.refreshNow()
        XCTAssertEqual(inventory.entries.count, 1, "the row stays while the phone is not listed")
        XCTAssertEqual(inventory.entries.first?.state, .restarting)
        XCTAssertFalse(inventory.entries[0].canUseClient)

        try FileManager.default.removeItem(at: marker)
        await inventory.refreshNow()
        XCTAssertEqual(inventory.entries.first?.state, .ready, "back and connected ends the restart")
        XCTAssertNil(inventory.restarting[PhysicalFixtures.udid])

        // A phone that never comes back: the row goes after three minutes.
        inventory.beginRestart(udid: PhysicalFixtures.udid)
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        clock = clock.addingTimeInterval(120)
        await inventory.refreshNow()
        XCTAssertEqual(inventory.entries.count, 1)
        clock = clock.addingTimeInterval(61)
        await inventory.refreshNow()
        XCTAssertEqual(inventory.entries.count, 0)
        XCTAssertTrue(inventory.restarting.isEmpty)
    }

    /// The phone listed with an unavailable tunnel (devicectl's word for a
    /// restarting phone) keeps its "Restarting\u{2026}" row and comes back
    /// as ready when it is connected again, with the app in the background
    /// the whole time (a restart in progress is polled regardless).
    func testUnavailableThenConnectedBringsTheRowBackWhileTheAppIsInactive() async throws {
        let marker = try makeTemporaryFolder("unavail").appendingPathComponent("away")
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: try PhysicalFixtures.data("devicectl-list-devices.json")) as? [String: Any])
        var result = try XCTUnwrap(document["result"] as? [String: Any])
        var entries = try XCTUnwrap(result["devices"] as? [[String: Any]])
        let index = try XCTUnwrap(entries.firstIndex {
            ($0["hardwareProperties"] as? [String: Any])?["reality"] as? String == "physical"
        })
        var connection = try XCTUnwrap(entries[index]["connectionProperties"] as? [String: Any])
        connection["tunnelState"] = "unavailable"
        entries[index]["connectionProperties"] = connection
        result["devices"] = entries
        document["result"] = result
        let unavailable = try makeTemporaryFolder("unavail-json").appendingPathComponent("unavailable.json")
        try JSONSerialization.data(withJSONObject: document).write(to: unavailable)
        let body = "if [ -f \(SimulatorFixtures.quoted(marker.path)) ]; then \(PhysicalFixtures.json(from: unavailable.path)); else \(PhysicalFixtures.json("devicectl-list-devices.json")); fi"
        let stub = try makePhysicalStub(listBody: body)

        let tooling = AppleTooling.stubbed(
            simctl: nil, devicectl: stub,
            devicesDirectory: try makeTemporaryFolder("set"), logsDirectory: try makeTemporaryFolder("logs")
        )
        let preferences = AppPreferences(defaults: .scratch())
        preferences.setPhysicalAppleDevice(PhysicalFixtures.udid, enabled: true)
        let inventory = ApplePhysicalInventory(
            preferences: preferences, iphoneUDID: nil, toolchain: { await tooling.probe() },
            pollInterval: .milliseconds(30), isAppActive: { false }
        )
        addTeardownBlock { @MainActor in inventory.stop() }
        inventory.setShowing(true)
        await inventory.refreshNow()
        XCTAssertEqual(inventory.entries.first?.state, .ready)

        inventory.beginRestart(udid: PhysicalFixtures.udid)
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        let away = await physicalWait { inventory.restartSeenAwayForTesting }
        XCTAssertTrue(away, "the poll runs for a restart although the app is inactive")
        XCTAssertEqual(inventory.entries.first?.state, .restarting)
        XCTAssertEqual(inventory.entries.count, 1)

        try FileManager.default.removeItem(at: marker)
        let back = await physicalWait { inventory.entries.first?.state == .ready }
        XCTAssertTrue(back)
        XCTAssertTrue(inventory.restarting.isEmpty)
    }

    // MARK: - Enabling a device

    /// Every listed device starts "Not enabled" and gets nothing but the
    /// list: no client, and none of the controller's commands reach it.
    func testANonEnabledDeviceReceivesNoOtherCommand() async throws {
        let stub = try makePhysicalStub(extra: """
          *"capture screenshot"*) \(PhysicalFixtures.capture("devicectl-capture-screenshot.json")) ;;
        """)
        let preferences = AppPreferences(defaults: .scratch())
        let inventory = try makePhysicalInventory(stub: stub, preferences: preferences, pollInterval: .seconds(60))
        let controller = ApplePhysicalController(
            inventory: inventory,
            picker: TestPicker(),
            temporaryDirectory: try makeTemporaryFolder("shots")
        )
        inventory.setShowing(true)
        let listed = await physicalWait { inventory.entries.count == 1 }
        XCTAssertTrue(listed)

        let entry = try XCTUnwrap(inventory.entries.first)
        XCTAssertFalse(entry.isEnabled)
        XCTAssertEqual(entry.state, .notEnabled)
        XCTAssertFalse(entry.canUseClient)
        let client = await inventory.client(for: entry.udid)
        XCTAssertNil(client)
        await controller.refreshInfo(udid: entry.udid)
        let screenshot = await controller.takeScreenshot(udid: entry.udid)
        await controller.recordScreen(udid: entry.udid)

        XCTAssertNil(screenshot)
        XCTAssertNil(controller.infos[entry.udid])
        XCTAssertEqual(stub.deviceCalls, [], "only `list devices` ever ran: \(stub.calls)")
    }

    /// "Use This Device…" asks first (nothing persisted until confirmed);
    /// enabling persists by hardware UDID, gives the device a client, and
    /// "Stop Using This Device" removes it again.
    func testEnablingPersistsAndGivesAClient() async throws {
        let stub = try makePhysicalStub()
        let defaults = UserDefaults.scratch()
        let preferences = AppPreferences(defaults: defaults)
        let inventory = try makePhysicalInventory(stub: stub, preferences: preferences, pollInterval: .seconds(60))
        var disabled: [String] = []
        inventory.deviceDisabled = { disabled.append($0) }
        inventory.setShowing(true)
        let listed = await physicalWait { inventory.entries.count == 1 }
        XCTAssertTrue(listed)
        let entry = try XCTUnwrap(inventory.entries.first)

        inventory.requestEnable(entry)
        XCTAssertEqual(inventory.pendingEnable?.udid, entry.udid)
        XCTAssertFalse(preferences.isPhysicalAppleDeviceEnabled(entry.udid), "asking persists nothing")
        XCTAssertEqual(AppPreferences(defaults: defaults).enabledPhysicalAppleDevices, [])

        inventory.enable(udid: entry.udid)
        XCTAssertNil(inventory.pendingEnable)
        XCTAssertTrue(preferences.isPhysicalAppleDeviceEnabled(entry.udid))
        XCTAssertEqual(AppPreferences(defaults: defaults).enabledPhysicalAppleDevices, [PhysicalFixtures.udid])
        let enabled = try XCTUnwrap(inventory.entry(udid: entry.udid))
        XCTAssertTrue(enabled.isEnabled)
        XCTAssertFalse(enabled.isEnabledByLaunchOption)
        XCTAssertEqual(enabled.state, .ready)
        let client = await inventory.client(for: entry.udid)
        XCTAssertEqual(client?.device.coreDeviceIdentifier, PhysicalFixtures.coreDeviceIdentifier)

        // The choice survives a relaunch: a new inventory on the same defaults.
        let second = try makePhysicalInventory(
            stub: stub,
            preferences: AppPreferences(defaults: defaults),
            pollInterval: .seconds(60)
        )
        second.applyPreference()
        await second.refreshNow()
        XCTAssertEqual(second.entries.first?.isEnabled, true)

        inventory.disable(udid: entry.udid)
        XCTAssertEqual(disabled, [PhysicalFixtures.udid])
        XCTAssertFalse(preferences.isPhysicalAppleDeviceEnabled(entry.udid))
        XCTAssertEqual(inventory.entry(udid: entry.udid)?.isEnabled, false)
        let stopped = await inventory.client(for: entry.udid)
        XCTAssertNil(stopped)
    }

    /// Asking to use an enabled device does nothing.
    func testRequestingAnEnabledDeviceAsksNothing() async throws {
        let preferences = AppPreferences(defaults: .scratch())
        preferences.setPhysicalAppleDevice(PhysicalFixtures.udid, enabled: true)
        let inventory = try makePhysicalInventory(stub: try makePhysicalStub(), preferences: preferences, pollInterval: .seconds(60))
        inventory.setShowing(true)
        let listed = await physicalWait { inventory.entries.count == 1 }
        XCTAssertTrue(listed)
        inventory.requestEnable(try XCTUnwrap(inventory.entries.first))
        XCTAssertNil(inventory.pendingEnable)
    }

    // MARK: - DHP_IPHONE_UDID

    /// The launch switch restricts the app to that one device: it is the only
    /// one listed and counts as enabled without the dialog or a stored
    /// choice, and "Stop Using" has nothing to remove.
    func testTheLaunchSwitchRestrictsAndAutoEnables() async throws {
        let stub = try makePhysicalStub()
        let preferences = AppPreferences(defaults: .scratch())
        preferences.setShowPhysicalAppleDevices(true)
        let inventory = try makePhysicalInventory(
            stub: stub,
            preferences: preferences,
            iphoneUDID: " " + PhysicalFixtures.udid.lowercased() + "\n",
            pollInterval: .seconds(60)
        )
        inventory.applyPreference()
        let listed = await physicalWait { inventory.entries.count == 1 }
        XCTAssertTrue(listed)

        let entry = try XCTUnwrap(inventory.entries.first)
        XCTAssertTrue(entry.isEnabled)
        XCTAssertTrue(entry.isEnabledByLaunchOption)
        XCTAssertEqual(entry.state, .ready)
        XCTAssertEqual(inventory.restrictedUDID, PhysicalFixtures.udid)
        XCTAssertEqual(preferences.enabledPhysicalAppleDevices, [], "nothing was stored")
        let client = await inventory.client(for: entry.udid)
        XCTAssertNotNil(client)
        inventory.disable(udid: entry.udid)
        XCTAssertEqual(inventory.entry(udid: entry.udid)?.isEnabled, true, "the launch switch stays in force")
    }

    /// A launch switch naming another device lists nothing: the phone in the
    /// capture is not the one named.
    func testTheLaunchSwitchListsOnlyTheNamedDevice() async throws {
        let stub = try makePhysicalStub()
        let preferences = AppPreferences(defaults: .scratch())
        preferences.setShowPhysicalAppleDevices(true)
        let inventory = try makePhysicalInventory(
            stub: stub,
            preferences: preferences,
            iphoneUDID: "00000000-1111111111111111",
            pollInterval: .seconds(60)
        )
        inventory.applyPreference()
        await inventory.refreshNow()
        XCTAssertGreaterThanOrEqual(stub.listCalls.count, 1)
        XCTAssertEqual(inventory.entries, [])
        XCTAssertEqual(stub.deviceCalls, [])
    }

    // MARK: - States

    /// The state the sidebar and stage show, in the order unpaired,
    /// disconnected, Developer Mode off, ready; a device that is not enabled
    /// is "Not enabled" whatever else is true.
    func testEntryStatesAndHints() throws {
        let ready = try PhysicalFixtures.entry()
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(ready.stateLabel, "Ready")
        XCTAssertNil(ready.hint)
        XCTAssertTrue(ready.canUseClient)

        let notEnabled = try PhysicalFixtures.entry(enabled: false)
        XCTAssertEqual(notEnabled.state, .notEnabled)
        XCTAssertEqual(notEnabled.stateLabel, "Not enabled")
        XCTAssertNotNil(notEnabled.hint)
        XCTAssertFalse(notEnabled.canUseClient)

        let unpaired = try PhysicalFixtures.entry { entry in
            Self.set(&entry, "connectionProperties", "pairingState", to: "unpaired")
            Self.set(&entry, "properties", "connection", "pairingState", to: "unpaired")
        }
        XCTAssertEqual(unpaired.state, .unpaired)
        XCTAssertEqual(unpaired.stateLabel, "Unpaired")
        XCTAssertTrue(unpaired.hint?.contains("Pair Nearby Device") == true)
        XCTAssertTrue(unpaired.hint?.contains("Developer Mode") == true)
        XCTAssertFalse(unpaired.canUseClient)

        // A phone that is not paired reads Unpaired before Not enabled.
        let unpairedNotEnabled = try PhysicalFixtures.entry(enabled: false) { entry in
            Self.set(&entry, "connectionProperties", "pairingState", to: "unpaired")
            Self.set(&entry, "properties", "connection", "pairingState", to: "unpaired")
        }
        XCTAssertEqual(unpairedNotEnabled.state, .unpaired)
        XCTAssertEqual(unpairedNotEnabled.stateLabel, "Unpaired")

        // A cabled, paired phone whose idle tunnel CoreDevice closed is still usable:
        // the next command opens the tunnel again.
        let idleOnTheCable = try PhysicalFixtures.entry { entry in
            Self.set(&entry, "connectionProperties", "tunnelState", to: "disconnected")
        }
        XCTAssertEqual(idleOnTheCable.state, .ready)
        XCTAssertTrue(idleOnTheCable.isPresent)

        let disconnected = try PhysicalFixtures.entry { entry in
            Self.set(&entry, "connectionProperties", "tunnelState", to: "disconnected")
            Self.set(&entry, "connectionProperties", "transportType", to: "localNetwork")
            Self.set(&entry, "properties", "connection", "transportType", to: "localNetwork")
        }
        XCTAssertEqual(disconnected.state, .disconnected)
        XCTAssertEqual(disconnected.stateLabel, "Disconnected")
        XCTAssertFalse(disconnected.canUseClient)
        XCTAssertFalse(disconnected.isPresent)

        let developerModeOff = try PhysicalFixtures.entry { entry in
            Self.set(&entry, "deviceProperties", "developerModeStatus", to: "disabled")
            Self.set(&entry, "properties", "state", "developerModeStatus", to: ["disabled": ["mode": 0]])
        }
        XCTAssertEqual(developerModeOff.state, .developerModeOff)
        XCTAssertEqual(developerModeOff.stateLabel, "Developer Mode off")
        XCTAssertTrue(developerModeOff.hint?.contains("Developer Mode") == true)
        XCTAssertTrue(developerModeOff.canUseClient, "Info can still read what CoreDevice answers")
    }

    /// The glyph follows the model; a summary is a physical Apple device.
    func testEntryGlyphAndSummary() throws {
        let entry = try PhysicalFixtures.entry()
        XCTAssertEqual(entry.symbolName, "iphone")
        XCTAssertFalse(entry.isIPad)
        let summary = entry.summary
        XCTAssertEqual(summary.kind, .physical)
        XCTAssertEqual(summary.ref.platform, .apple)
        XCTAssertNil(summary.ref.adbSerial)
        XCTAssertEqual(summary.ref.id, PhysicalFixtures.udid)
        XCTAssertEqual(summary.osName, "iOS")
        XCTAssertEqual(summary.osVersion, "27.0")
    }

    /// Sets `value` at a nested key path of a list entry, creating dictionaries.
    private static func set(_ entry: inout [String: Any], _ path: String..., to value: Any) {
        func assign(_ dictionary: [String: Any], _ keys: ArraySlice<String>, _ value: Any) -> [String: Any] {
            var copy = dictionary
            guard let key = keys.first else { return copy }
            if keys.count == 1 {
                copy[key] = value
            } else {
                copy[key] = assign(copy[key] as? [String: Any] ?? [:], keys.dropFirst(), value)
            }
            return copy
        }
        // The last element of `path` is the leaf key; `value` is the value.
        entry = assign(entry, path[...], value)
    }
}
