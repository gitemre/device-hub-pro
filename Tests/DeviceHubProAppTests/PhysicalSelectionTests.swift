import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// A physical Apple device in the stage selection: it is its
/// own `DeviceSelection` and is never routed down the adb, emulator or
/// simulator paths; it is never selected on its own; it is manage-only, so
/// it takes no part in multi-selection or Apply to Selected; and the
/// preferences and launch switch behave as the opt-in design says.
@MainActor
final class PhysicalSelectionTests: XCTestCase {
    private typealias Routing = SelectionRouting
    private static let udid = PhysicalFixtures.udid
    private static let selection = DeviceSelection.physicalApple(udid)

    private func snapshot(
        devices: [AndroidDevice] = [],
        avdCards: [AvdCard] = [],
        avds: [String] = [],
        simulators: [SimulatorEntry] = [],
        physical: [String] = [PhysicalFixtures.udid]
    ) -> Routing.Snapshot {
        Routing.Snapshot(devices: devices, avdCards: avdCards, avds: avds, simulators: simulators, physicalApple: physical)
    }

    // MARK: - Routing

    /// A physical Apple device routes to no adb serial for the live stage or
    /// the inspector, and Return starts no AVD or simulator for it.
    func testAPhysicalDeviceRoutesToNoSerialAndStartsNothing() async throws {
        let online = AndroidDevice(serial: "emulator-5554", state: "device")
        let snapshot = snapshot(devices: [online])

        XCTAssertNil(Routing.liveSelectionSerial(for: Self.selection, in: snapshot))
        XCTAssertNil(Routing.inspectorSerial(for: Self.selection, in: snapshot))
        XCTAssertNil(Routing.sidebarStartTarget(for: Self.selection, isBusy: false, in: snapshot))

        let model = AppModel.testing()
        XCTAssertNil(model.sidebarSimulatorStartTarget(for: Self.selection))
        XCTAssertNil(model.sidebarStartTarget(for: Self.selection))
    }

    /// The reference of a physical selection is an Apple device of kind
    /// physical, never an adb serial, and distinct from a simulator's.
    func testTheReferenceIsAPhysicalAppleDevice() throws {
        let (ref, kind) = try XCTUnwrap(Self.selection.appleDeviceRef)
        XCTAssertEqual(ref.platform, .apple)
        XCTAssertEqual(kind, .physical)
        XCTAssertNil(ref.adbSerial)
        XCTAssertEqual(ref, DeviceRef.physicalApple(Self.udid.lowercased()))
        XCTAssertTrue(Self.selection.isPhysicalApple)
        XCTAssertEqual(Self.selection.physicalAppleUDID, Self.udid)

        let simulator = try XCTUnwrap(DeviceSelection.simulator("A-B").appleDeviceRef)
        XCTAssertEqual(simulator.kind, .simulator)
        XCTAssertNil(DeviceSelection.avd("Pixel").appleDeviceRef)
        XCTAssertNil(DeviceSelection.device("R58M123").appleDeviceRef)
        XCTAssertNil(DeviceSelection.pixel("pixel_8").appleDeviceRef)
        XCTAssertFalse(DeviceSelection.simulator("A-B").isPhysicalApple)
    }

    /// The selection is kept while the list shows the device and replaced
    /// when it does not (the preference turned off, the list emptied).
    func testAListedPhysicalDeviceIsKept() {
        XCTAssertEqual(Routing.ensureTarget(for: Self.selection, in: snapshot()), .keep)
        XCTAssertEqual(Routing.ensureTarget(for: Self.selection, in: snapshot(physical: [])), .assign(nil))
    }

    /// A physical device is never picked automatically: with nothing selected
    /// (or a stale selection) the order is an online adb device, a booted
    /// simulator, an AVD, a simulator, else nothing, whatever the physical
    /// list holds.
    func testAPhysicalDeviceIsNeverSelectedAutomatically() {
        XCTAssertEqual(Routing.ensureTarget(for: nil, in: snapshot()), .assign(nil))
        XCTAssertEqual(Routing.ensureTarget(for: .device("gone"), in: snapshot()), .assign(nil))
        let card = AvdCard(name: "Pixel_8", displayName: "Pixel 8", target: nil, skin: nil, isRunning: false, serial: nil)
        XCTAssertEqual(
            Routing.ensureTarget(for: nil, in: snapshot(avdCards: [card], avds: ["Pixel_8"])),
            .assign(.avd("Pixel_8"))
        )
        let online = AndroidDevice(serial: "R58M123", state: "device")
        XCTAssertEqual(
            Routing.ensureTarget(for: nil, in: snapshot(devices: [online])),
            .assign(.device("R58M123"))
        )
    }

    // MARK: - Multi-selection and Apply to Selected

    func testAPhysicalDeviceTakesNoPartInMultiSelection() {
        XCTAssertFalse(SidebarMultiSelection.isMultiSelectable(Self.selection))
        var multi = SidebarMultiSelection()
        multi.selectOnly(.device("R58M123"))
        let primary = multi.toggle(Self.selection, primary: .device("R58M123"))
        XCTAssertEqual(primary, Self.selection)
        XCTAssertEqual(multi.rows, [Self.selection], "it selects alone")
        var all = SidebarMultiSelection()
        _ = all.selectAll([Self.selection, .device("R58M123")], primary: nil)
        XCTAssertEqual(all.rows, [.device("R58M123")])
    }

    func testAPhysicalDeviceIsNoBatchTarget() {
        XCTAssertNil(BatchTargeting.target(for: Self.selection, in: BatchTargeting.Snapshot()))
        XCTAssertEqual(BatchTargeting.id(for: Self.selection), "physicalApple:\(Self.udid)")
        XCTAssertNotEqual(BatchTargeting.id(for: Self.selection), BatchTargeting.id(for: .simulator(Self.udid)))
    }

    // MARK: - Codable

    /// A new window's seed carries a physical selection through
    /// `WindowGroup`'s persistence.
    func testASeedRoundTrips() throws {
        let seed = WorkspaceSeed(selection: Self.selection)
        let decoded = try JSONDecoder().decode(WorkspaceSeed.self, from: JSONEncoder().encode(seed))
        XCTAssertEqual(decoded, seed)
        XCTAssertEqual(decoded.selection, .physicalApple(Self.udid))
        XCTAssertNotEqual(DeviceSelection.physicalApple("X"), DeviceSelection.simulator("X"))
    }

    // MARK: - A model with the inventory

    /// A model whose devicectl lists the test iPhone (the preference is on):
    /// the sidebar has the device, and nothing selected it — not the launch
    /// refresh, not the list change.
    func testTheModelNeverSelectsAPhysicalDevice() async throws {
        let stub = try makePhysicalStub()
        let tooling = AppleTooling.stubbed(
            simctl: nil,
            devicectl: stub,
            devicesDirectory: try makeTemporaryFolder("set"),
            logsDirectory: try makeTemporaryFolder("logs")
        )
        let defaults = UserDefaults.scratch()
        AppPreferences(defaults: defaults).setShowPhysicalAppleDevices(true)
        let model = AppModel.testing(apple: tooling, defaults: defaults)
        addTeardownBlock { @MainActor in model.physicalInventory.stop() }
        XCTAssertNil(model.deviceSelection)

        await model.refresh()
        let listed = await physicalWait { model.physicalInventory.entries.count == 1 }
        XCTAssertTrue(listed)
        model.ensureDeviceSelection()

        XCTAssertNil(model.deviceSelection, "a physical device is selected by the user only")
        XCTAssertEqual(model.physicalInventory.listedUDIDs, [Self.udid])
        XCTAssertEqual(stub.deviceCalls, [], "and nothing but the list reached it")

        // A user's selection stays while the device is listed, and goes when
        // the preference is turned off.
        model.deviceSelection = Self.selection
        model.ensureDeviceSelection()
        XCTAssertEqual(model.deviceSelection, Self.selection)
        model.physicalInventory.setShowing(false)
        XCTAssertNotEqual(model.deviceSelection, Self.selection)
    }

    /// A model without the preference on runs no listing at all.
    func testTheModelWithThePreferenceOffMakesNoListCall() async throws {
        let stub = try makePhysicalStub()
        let tooling = AppleTooling.stubbed(
            simctl: nil,
            devicectl: stub,
            devicesDirectory: try makeTemporaryFolder("set"),
            logsDirectory: try makeTemporaryFolder("logs")
        )
        let before = ApplePhysicalDeviceLister.listCallCount
        let model = AppModel.testing(apple: tooling)
        addTeardownBlock { @MainActor in model.physicalInventory.stop() }

        await model.refresh()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(ApplePhysicalDeviceLister.listCallCount, before)
        XCTAssertEqual(stub.calls, [])
        XCTAssertEqual(model.physicalInventory.entries, [])
    }

    // MARK: - Preferences and launch options

    func testThePreferencesDefaultOffAndPersist() {
        let defaults = UserDefaults.scratch()
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.showPhysicalAppleDevices)
        XCTAssertEqual(preferences.enabledPhysicalAppleDevices, [])

        preferences.setShowPhysicalAppleDevices(true)
        preferences.setPhysicalAppleDevice(" " + Self.udid.lowercased() + " ", enabled: true)
        preferences.setPhysicalAppleDevice("00000000-1111111111111111", enabled: true)
        preferences.setPhysicalAppleDevice("  ", enabled: true)

        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertTrue(reloaded.showPhysicalAppleDevices)
        XCTAssertEqual(reloaded.enabledPhysicalAppleDevices, ["00000000-0000000000000000", "00000000-1111111111111111"])
        XCTAssertTrue(reloaded.isPhysicalAppleDeviceEnabled(Self.udid))
        reloaded.setPhysicalAppleDevice(Self.udid, enabled: false)
        XCTAssertFalse(AppPreferences(defaults: defaults).isPhysicalAppleDeviceEnabled(Self.udid))
        XCTAssertEqual(defaults.array(forKey: "enabledPhysicalAppleDevices") as? [String], ["00000000-1111111111111111"])
        XCTAssertEqual(defaults.object(forKey: "showPhysicalAppleDevices") as? Bool, true)
    }

    func testTheLaunchSwitchIsParsed() {
        XCTAssertNil(LaunchOptions.none.iphoneUDID)
        XCTAssertNil(LaunchOptions(environment: [:]).iphoneUDID)
        XCTAssertNil(LaunchOptions(environment: ["DHP_IPHONE_UDID": "  "]).iphoneUDID)
        XCTAssertEqual(
            LaunchOptions(environment: ["DHP_IPHONE_UDID": " 00000000-abcdef0123456789\n"]).iphoneUDID,
            "00000000-ABCDEF0123456789"
        )
    }

    /// The two ways an app source reaches a physical device are the lister
    /// and the client, and each is made in one place only: the app's
    /// inventory (the client behind the enabled/paired/connected check).
    func testTheClientIsMadeOnlyByTheInventory() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DeviceHubProApp", isDirectory: true)
        var clientMakers: Set<String> = []
        var listerMakers: Set<String> = []
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(whereSeparator: \.isNewline) {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { continue }
                if code.contains("makeDevicectlPhysicalClient(") { clientMakers.insert(url.lastPathComponent) }
                if code.contains("makePhysicalDeviceLister(") { listerMakers.insert(url.lastPathComponent) }
            }
        }
        XCTAssertEqual(clientMakers, ["ApplePhysicalInventory.swift"])
        XCTAssertEqual(listerMakers, ["ApplePhysicalInventory.swift"])
    }
}
