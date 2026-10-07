import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// Menus and buttons act for the window they were used in: with a second tab focused, Shut Down, Rename, Reset, Start,
/// Apply to Selected and the settings must reach that tab's device and leave
/// the first tab's alone. They read the model's facade, the first window's
/// workspace, before.
@MainActor
final class WorkspaceRoutingTests: XCTestCase {
    private func card(_ name: String, running: Bool = false, serial: String? = nil) -> AvdCard {
        AvdCard(name: name, displayName: name, target: "android-36", skin: nil, isRunning: running, serial: serial)
    }

    private func twoTabs(adb: AdbClient? = nil, emulator: EmulatorManager? = EmulatorManager.inert)
        -> (model: AppModel, tabA: DeviceWorkspace, tabB: DeviceWorkspace)
    {
        let model = AppModel.testing(adb: adb, emulator: emulator)
        let tabA = model.workspace
        let tabB = DeviceWorkspace(services: model.services)
        model.registry.register(tabB)
        model.registry.focusedID = tabB.id
        return (model, tabA, tabB)
    }

    func testAvdMenuStateReadsTheFocusedTabsSelection() {
        let (model, tabA, tabB) = twoTabs()
        model.catalog.avdCards = [card("Running_A", running: true, serial: "emulator-5554"), card("Stopped_B")]
        tabA.deviceSelection = .avd("Running_A")
        tabB.deviceSelection = .avd("Stopped_B")

        XCTAssertEqual(model.selectedAvdName(in: tabB), "Stopped_B")
        XCTAssertEqual(model.selectedAvdName(in: tabA), "Running_A")
        XCTAssertTrue(model.avdFileActionsEnabled(in: tabB), "tab B's AVD is stopped: Rename, Reset and Start are on")
        XCTAssertFalse(model.avdFileActionsEnabled(in: tabA), "tab A's AVD runs")
        XCTAssertFalse(model.avdFileActionsEnabled(in: nil), "no window, nothing to act on")
    }

    func testShutDownAvailabilityFollowsTheTabNotTheFirstWindow() {
        let (model, tabA, tabB) = twoTabs()
        tabA.beginMirrorSession(
            FakeMirrorSession(), device: .android("emulator-5554"), port: nil,
            avdName: "Pixel_A", capabilities: .android(emulatorGrpc: true)
        )
        XCTAssertTrue(model.canStopActiveEmulator(in: tabA))
        XCTAssertFalse(model.canStopActiveEmulator(in: tabB), "tab B mirrors nothing")
        XCTAssertFalse(model.canStopActiveEmulator(in: nil), "defaults to the focused tab, B")
    }

    func testShutDownFromTheSecondTabStopsOnlyItsOwnEmulator() async {
        let (model, tabA, tabB) = twoTabs()
        let sessionA = FakeMirrorSession()
        let sessionB = FakeMirrorSession()
        tabA.beginMirrorSession(
            sessionA, device: .android("emulator-5554"), port: nil,
            avdName: "Pixel_A", capabilities: .android(emulatorGrpc: true)
        )
        tabB.beginMirrorSession(
            sessionB, device: .android("emulator-5556"), port: nil,
            avdName: "Pixel_B", capabilities: .android(emulatorGrpc: true)
        )

        await model.stopActiveEmulator(in: tabB)

        XCTAssertEqual(sessionA.stopCount, 0, "tab A's mirror is untouched")
        XCTAssertTrue(tabA.mirror.session === sessionA)
        XCTAssertEqual(tabA.context.avdName, "Pixel_A")
        XCTAssertGreaterThanOrEqual(sessionB.stopCount, 1, "tab B's own emulator went down")
    }

    func testShutDownWithoutAKnownAvdReportsInTheTabThatAsked() async {
        let (model, tabA, tabB) = twoTabs()
        tabA.beginMirrorSession(
            FakeMirrorSession(), device: .android("emulator-5554"), port: nil,
            avdName: "Pixel_A", capabilities: .android(emulatorGrpc: true)
        )
        await model.stopActiveEmulator(in: tabB)
        XCTAssertNotNil(tabB.status.errorMessage)
        XCTAssertNil(tabA.status.errorMessage)
        XCTAssertNotNil(tabA.mirror.session, "the first tab's emulator is not shut down")
    }

    func testStartFromTheSecondTabMovesOnlyItsOwnSelectionAndMirror() async throws {
        let target = "Routing_\(UUID().uuidString.prefix(6))"
        let serial = "emulator-5556"
        let emulator = try makeStubEmulator(avds: [target])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoutingStart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let discovery = directory.appendingPathComponent("discovery.ini")
        let port = try makeOwnedGrpcPort()
        try Data("grpc.port=\(port)\n".utf8).write(to: discovery)
        let adb = try makeStubAdb(arms: """
          "devices -l")
            printf 'List of devices attached\\n'
            printf '\(serial)          device product:sdk model:Target transport_id:8\\n' ;;
          "-s \(serial) emu avd name")
            printf '%s\\r\\nOK\\r\\n' "\(target)" ;;
          "-s \(serial) emu avd discoverypath")
            printf '%s\\r\\nOK\\r\\n' "\(discovery.path)" ;;
          "track-devices"*)
            exec sleep 30 ;;
        """)
        _ = try emulator.manager.launch(avd: target, grpcPort: port)
        await waitUntil("the VM never started") { !emulator.launches.isEmpty }
        let (model, tabA, tabB) = twoTabs(adb: adb.client, emulator: emulator.manager)
        addTeardownBlock { @MainActor in model.inventory.stopDeviceLifecycle() }
        tabB.mirror.sessionFactoryOverride = { _, _ in FakeMirrorSession() }
        let sessionA = FakeMirrorSession()
        tabA.beginMirrorSession(
            sessionA, device: .android("emulator-5554"), port: nil,
            avdName: "Pixel_A", capabilities: .android(emulatorGrpc: true)
        )
        tabA.deviceSelection = .avd("Pixel_A")

        await model.startAndMirror(avd: target, workspace: tabB)

        XCTAssertEqual(tabB.deviceSelection, .avd(target))
        XCTAssertNotNil(tabB.mirror.session, "the second tab mirrors the started AVD")
        XCTAssertEqual(tabA.deviceSelection, .avd("Pixel_A"), "tab A's selection is untouched")
        XCTAssertTrue(tabA.mirror.session === sessionA, "tab A's mirror is untouched")
        XCTAssertEqual(sessionA.stopCount, 0)
    }

    func testApplyToSelectedReadsTheTabItIsAskedFor() {
        let (model, tabA, tabB) = twoTabs()
        model.catalog.avdCards = [card("Pixel_9"), card("Pixel_8"), card("Pixel_7")]
        model.selectOnlyRow(.avd("Pixel_9"), in: tabA)
        model.toggleRow(.avd("Pixel_8"), in: tabA)
        model.selectOnlyRow(.avd("Pixel_7"), in: tabB)

        XCTAssertTrue(model.canActOnSelected(in: tabA))
        XCTAssertFalse(model.canActOnSelected(in: tabB))
        XCTAssertFalse(model.canActOnSelected(), "defaults to the focused tab, B")
        XCTAssertEqual(model.batchTargets(in: tabB).map(\.id), ["avd:Pixel_7"])
        XCTAssertEqual(model.batchTargets(in: tabA).map(\.id), ["avd:Pixel_9", "avd:Pixel_8"])
        XCTAssertEqual(model.profileTargets(in: tabB).map(\.id), ["avd:Pixel_7"])

        model.toggleRow(.avd("Pixel_9"), in: tabB)
        XCTAssertTrue(model.canActOnSelected(), "the focused tab now has two rows")
        XCTAssertEqual(model.batchTargets().map(\.id), ["avd:Pixel_7", "avd:Pixel_9"])
    }

    func testSettingsApplyToEveryWindow() {
        let (model, tabA, tabB) = twoTabs()
        XCTAssertTrue(tabA.window.showDeviceFrame)
        model.setShowDeviceFrameInAllWindows(false)
        XCTAssertFalse(tabA.window.showDeviceFrame)
        XCTAssertFalse(tabB.window.showDeviceFrame)
        model.setShowDeviceFrameInAllWindows(true)
        XCTAssertTrue(tabA.window.showDeviceFrame)
        XCTAssertTrue(tabB.window.showDeviceFrame)
        XCTAssertTrue(model.focusedWorkspace === tabB)
    }

    /// A new tab does not refresh the app again: the lists are app-wide.
    func testANewTabsAppearanceDoesNotRefreshAgain() async {
        let (model, _, tabB) = twoTabs()
        await model.refreshForNewWindow()
        let token = tabB.deviceSelection
        await model.refreshForNewWindow()
        XCTAssertEqual(tabB.deviceSelection, token)
    }
}
