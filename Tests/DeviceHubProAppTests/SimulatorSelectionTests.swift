import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// A simulator in the stage selection: the routing core's answers for
/// `.simulator(udid)` and the order it picks a selection in, and a model on
/// a stub simctl whose refresh lists the simulators, keeps the selection
/// valid when a simulator is hidden or deleted, and wires the lifecycle.
@MainActor
final class SimulatorSelectionTests: XCTestCase {
    private typealias Routing = SelectionRouting

    private static let udid = SimulatorFixtures.udid

    private func booted() throws -> SimulatorEntry {
        try SimulatorFixtures.entry("simctl-list-j-devices.booted-after-rename.json", udid: Self.udid)
    }

    private func stoppedClone() throws -> SimulatorEntry {
        try SimulatorFixtures.entry("simctl-list-j-devices.cloned.json", udid: SimulatorFixtures.cloneUDID)
    }

    private static func card(_ name: String) -> AvdCard {
        AvdCard(name: name, displayName: name, target: "android-35", skin: nil, isRunning: false, serial: nil)
    }

    // MARK: - Routing

    /// A simulator is no adb device: it routes to no serial for the live
    /// stage or the inspector, and Return starts no AVD for it.
    func testASimulatorRoutesToNoSerial() throws {
        let snapshot = Routing.Snapshot(
            devices: [AndroidDevice(serial: "emulator-5554", state: "device")],
            simulators: [try booted()]
        )
        let selection = DeviceSelection.simulator(Self.udid)

        XCTAssertNil(Routing.liveSelectionSerial(for: selection, in: snapshot))
        XCTAssertNil(Routing.inspectorSerial(for: selection, in: snapshot))
        XCTAssertNil(Routing.sidebarStartTarget(for: selection, isBusy: false, in: snapshot))
    }

    /// A listed simulator stays selected; one the list no longer shows (or
    /// hides) is replaced.
    func testAListedSimulatorIsKept() throws {
        let snapshot = Routing.Snapshot(avdCards: [Self.card("Pixel_8")], avds: ["Pixel_8"], simulators: [try booted()])
        XCTAssertEqual(Routing.ensureTarget(for: .simulator(Self.udid), in: snapshot), .keep)
        XCTAssertEqual(
            Routing.ensureTarget(for: .simulator(SimulatorFixtures.cloneUDID), in: snapshot),
            .assign(nil),
            "a simulator that disappeared leaves No Selection, as in Device Hub"
        )
    }

    /// With nothing selected: an online adb device, then a booted simulator,
    /// then the first AVD, then the first simulator.
    func testTheSelectionOrder() throws {
        let online = AndroidDevice(serial: "R58M123", state: "device")
        let offline = AndroidDevice(serial: "emulator-5556", state: "offline")
        let booted = try booted()
        let stopped = try stoppedClone()

        XCTAssertEqual(
            Routing.ensureTarget(for: nil, in: Routing.Snapshot(devices: [online], avdCards: [Self.card("Pixel_8")], simulators: [booted])),
            .assign(.device("R58M123"))
        )
        XCTAssertEqual(
            Routing.ensureTarget(for: nil, in: Routing.Snapshot(devices: [offline], avdCards: [Self.card("Pixel_8")], simulators: [stopped, booted])),
            .assign(.simulator(Self.udid)),
            "a booted simulator runs; the AVD does not"
        )
        XCTAssertEqual(
            Routing.ensureTarget(for: nil, in: Routing.Snapshot(avdCards: [Self.card("Pixel_8")], simulators: [stopped])),
            .assign(.avd("Pixel_8"))
        )
        XCTAssertEqual(
            Routing.ensureTarget(for: nil, in: Routing.Snapshot(simulators: [stopped])),
            .assign(.simulator(SimulatorFixtures.cloneUDID))
        )
    }

    // MARK: - The model

    /// Return on a stopped, available simulator's row starts it, as on a
    /// stopped AVD's; nothing for a running one, one with an operation in
    /// flight (a second Return during its boot), or a row that is no
    /// simulator.
    func testReturnStartsAStoppedSimulator() async throws {
        let gate = try makeTemporaryFolder("gate").appendingPathComponent("boot").path
        let (model, _) = try defaultSetModel(
            listFile: SimulatorFixtures.url("simctl-list-j-devices.cloned.json"),
            extraArms: """
              *" boot \(Self.udid)")
                while [ ! -f \(SimulatorFixtures.quoted(gate)) ]; do sleep 0.05; done ;;
            """
        )
        await model.refresh()
        let stopped = DeviceSelection.simulator(Self.udid)
        XCTAssertEqual(model.sidebarSimulatorStartTarget(for: stopped), Self.udid)
        XCTAssertNil(model.sidebarSimulatorStartTarget(for: .simulator("00000000-0000-0000-0000-000000000000")))
        XCTAssertNil(model.sidebarSimulatorStartTarget(for: .avd("Pixel_8")))
        XCTAssertNil(model.sidebarSimulatorStartTarget(for: nil))
        XCTAssertNil(model.sidebarStartTarget(for: stopped), "no AVD for a simulator")

        // Its boot waits on the stub: an operation in flight.
        let boot = Task { await model.simulatorLifecycle.boot(Self.udid) }
        await waitUntil("starting") { model.simulatorLifecycle.operations[Self.udid] == .starting }
        XCTAssertNil(model.sidebarSimulatorStartTarget(for: stopped))
        FileManager.default.createFile(atPath: gate, contents: Data())
        _ = await boot.value

        let (running, _) = try defaultSetModel(
            listFile: SimulatorFixtures.url("simctl-list-j-devices.booted-after-rename.json")
        )
        await running.refresh()
        XCTAssertNil(running.sidebarSimulatorStartTarget(for: stopped))
    }

    private func defaultSetModel(listFile: URL? = nil, extraArms: String = "") throws -> (AppModel, StubTool) {
        let list = listFile.map { "cat " + SimulatorFixtures.quoted($0.path) }
            ?? SimulatorFixtures.cat("simctl-list-j-devices.default-set.json")
        let simctl = try makeStubTool("simctl", arms: """
        \(extraArms)
          *"list -j devices")
            \(list) ;;
          *"list -j runtimes")
            \(SimulatorFixtures.cat("simctl-list-j-runtimes.json")) ;;
          *"list -j devicetypes")
            \(SimulatorFixtures.cat("simctl-list-j-devicetypes.json")) ;;
          *" bootstatus \(Self.udid)")
            \(SimulatorFixtures.cat("simctl-bootstatus.already-booted.stdout.txt")) ;;
          *" spawn \(Self.udid) launchctl list")
            \(SimulatorFixtures.cat("simctl-spawn-launchctl-list.ready.stdout.txt")) ;;
          *" io \(Self.udid) screenshot --type=png "*)
            \(SimulatorFixtures.screenshot("simctl-io-screenshot.home-screen-loading.png")) ;;
        """)
        let set = try makeTemporaryFolder("set")
        try FileManager.default.copyItem(
            at: SimulatorFixtures.url("device_set.plist.default-set"),
            to: set.appendingPathComponent("device_set.plist")
        )
        let model = AppModel.testing(apple: .stubbed(
            simctl: simctl,
            devicesDirectory: set,
            logsDirectory: try makeTemporaryFolder("logs")
        ))
        addTeardownBlock { @MainActor in model.stopSimulatorProvider() }
        return (model, simctl)
    }

    /// A Mac with only Xcode (no adb, no AVD): the refresh lists the
    /// simulators, raises no alert, and selects the first one the sidebar
    /// lists, which routes to no serial.
    func testRefreshListsTheSimulatorsAndSelectsOne() async throws {
        let (model, _) = try defaultSetModel()

        await model.refresh()

        XCTAssertNil(model.status.errorMessage)
        XCTAssertEqual(model.simulators.tooling.tier, .t1)
        XCTAssertEqual(model.simulators.visibleSimulators.count, 12)
        let first = try XCTUnwrap(model.simulators.visibleSimulators.first)
        XCTAssertEqual(model.deviceSelection, .simulator(first.udid))
        XCTAssertNil(model.liveSelectionSerial)
        XCTAssertNil(model.inspectorSerial)
        XCTAssertNil(model.activeDeviceSerial)
        XCTAssertNil(model.sidebarStartTarget(for: model.deviceSelection))
    }

    /// A selected simulator the sidebar does not list (a never-used default,
    /// which Device Hub hides and nothing can reveal) leaves "No Selection".
    func testASelectedHiddenSimulatorLeavesNoSelection() async throws {
        let (model, _) = try defaultSetModel()
        await model.refresh()
        let unused = try XCTUnwrap(model.simulators.simulators.first(where: \.isUnusedDefault))
        model.deviceSelection = .simulator(unused.udid)

        model.ensureDeviceSelection()

        XCTAssertNil(model.deviceSelection)
        // ... and stays so until the user picks a device: the window does not
        // jump to another one on the next refresh.
        model.ensureDeviceSelection()
        XCTAssertNil(model.deviceSelection)
    }

    /// A deleted simulator's selection ends in "No Selection" with the next
    /// listing (Device Hub does not jump to another device).
    func testDeletingTheSelectedSimulatorLeavesNoSelection() async throws {
        let answers = try makeTemporaryFolder("answers")
        let list = answers.appendingPathComponent("list.json")
        try FileManager.default.copyItem(at: SimulatorFixtures.url("simctl-list-j-devices.cloned.json"), to: list)
        let (model, _) = try defaultSetModel(listFile: list)
        await model.refresh()
        model.deviceSelection = .simulator(SimulatorFixtures.cloneUDID)

        try FileManager.default.removeItem(at: list)
        try FileManager.default.copyItem(at: SimulatorFixtures.url("simctl-list-j-devices.booted-after-rename.json"), to: list)
        await model.simulators.reloadList()

        XCTAssertNil(model.deviceSelection)
    }

    /// The model hands the lifecycle its listing: a simulator found booted is
    /// followed to ready (a finished boot's `bootstatus`, SpringBoard, the
    /// home screen on a screenshot)
    /// without becoming Device Hub Pro's, and the lifecycle reaches simctl through
    /// the inventory. Nothing reaches adb: the model has none.
    func testTheLifecycleFollowsWhatTheListingShows() async throws {
        let (model, simctl) = try defaultSetModel(
            listFile: SimulatorFixtures.url("simctl-list-j-devices.booted-after-rename.json")
        )

        await model.refresh()
        await waitUntil(timeout: 10, "ready") { model.simulatorLifecycle.isReady(Self.udid) }

        XCTAssertEqual(model.deviceSelection, .simulator(Self.udid))
        let entry = try XCTUnwrap(model.simulators.entry(udid: Self.udid))
        XCTAssertEqual(model.simulatorLifecycle.runState(for: entry), .ready)
        XCTAssertEqual(entry.summary(runState: .ready).model, "iPhone 17 Pro")
        XCTAssertEqual(model.simulatorLifecycle.bootedByDeviceHubPro, [])
        XCTAssertEqual(
            simctl.calls.filter { !$0.hasPrefix("list -j ") },
            ["bootstatus \(Self.udid)", "spawn \(Self.udid) launchctl list", "io \(Self.udid) screenshot --type=png"]
        )
        XCTAssertFalse(model.adbIsAvailable)
    }
}
