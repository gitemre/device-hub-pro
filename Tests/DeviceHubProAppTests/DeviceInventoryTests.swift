import Darwin
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// `DeviceInventory` on its own, without a model: the rows it merges, what
/// it keeps per device and per adb transport, what it lets go of when
/// emulators leave, and the lifecycle hooks it hands to its owner.
@MainActor
final class DeviceInventoryTests: XCTestCase {
    private let phone = AndroidDevice.online("HT4CWJT01234", transport: "5", model: "Pixel 8")

    /// What its owner's hooks received.
    @MainActor
    private final class Recorder {
        var teardowns: [MirrorController.MirrorTeardownCause] = []
        var resumes: [String] = []
        var selectionFixUps = 0
        /// How many times this coordinator's own `applySnapshot` hook fired
        /// — the pump must never trigger it (`decide(_:)` only); only a
        /// direct `handle(_:)` call should.
        var applySnapshotCalls = 0
    }

    private struct Harness {
        let inventory: DeviceInventory
        let context: ActiveDeviceContext
        let ports: GrpcPortService
        let recorder: Recorder
        /// This harness's own stand-in workspace: `DeviceInventory` no
        /// longer owns a single coordinator — a real
        /// `DeviceWorkspace` registers its own, so a bare-inventory test
        /// names its own id instead.
        let workspaceID = WorkspaceID()
    }

    /// An inventory over its own context and gRPC ports, its selection
    /// fix-up hook recording into a `Recorder`. Without `adb` a snapshot
    /// reads no Info and the watcher never starts. The context reads AVD
    /// configs from an empty directory, never from ~/.android.
    private func makeInventory(adb: AdbClient? = nil) -> Harness {
        let avdHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceInventoryTests-\(UUID().uuidString)", isDirectory: true)
        let context = ActiveDeviceContext(avdHome: avdHome)
        let ports = GrpcPortService(adbClient: nil)
        let inventory = DeviceInventory(adbClient: adb, context: context, status: StatusCenter(), grpcPorts: ports)
        let recorder = Recorder()
        inventory.keepSelectionValid = { recorder.selectionFixUps += 1 }
        return Harness(inventory: inventory, context: context, ports: ports, recorder: recorder)
    }

    /// A coordinator over `harness`'s own workspace id, its `teardown` and
    /// `resume` hooks recording into `harness.recorder` — the harness's
    /// stand-in for what a real `DeviceWorkspace` wires
    /// (`DeviceWorkspace.wireLifecycle`), registered with the inventory so
    /// `startDeviceLifecycle()`'s watcher pumps events to it.
    private func makeCoordinator(_ harness: Harness, selected: String? = nil) -> DeviceLifecycleCoordinator {
        let coordinator = DeviceLifecycleCoordinator(hooks: DeviceLifecycleCoordinator.Hooks(
            applySnapshot: { [weak harness = harness.inventory, recorder = harness.recorder] devices, degraded in
                recorder.applySnapshotCalls += 1
                harness?.applyWatcherSnapshot(devices, degraded: degraded)
            },
            teardown: { [recorder = harness.recorder] reason in
                recorder.teardowns.append(reason == .transportFatal ? .transportFatal : .disconnected)
            },
            resume: { [recorder = harness.recorder] serial in recorder.resumes.append(serial) },
            showStatus: { [inventory = harness.inventory, id = harness.workspaceID] status in
                inventory.lifecycleShowStatus(status, workspace: id)
            },
            setGhost: { [inventory = harness.inventory, id = harness.workspaceID] serial in
                inventory.lifecycleSetGhost(serial, workspace: id)
            },
            healthFlash: { _ in },
            transportRestarted: { [ports = harness.ports] in ports.invalidateAll() },
            selectedSerial: { selected },
            lifecycleState: { _ in }
        ))
        harness.inventory.registerLifecycle(coordinator, workspace: harness.workspaceID)
        return coordinator
    }

    private func info(_ serial: String) -> DeviceInfo {
        DeviceInfo(
            serial: serial,
            model: "sdk_gphone64_arm64",
            manufacturer: "Google",
            androidVersion: "14",
            apiLevel: "34",
            abi: "arm64-v8a",
            isEmulator: true
        )
    }

    // MARK: Rows and the ghost

    /// The ghost stands in for its device only while the device is absent:
    /// it never replaces nor duplicates a present row, carries the device's
    /// last-known details while it waits, and gives way when it returns.
    func testTheGhostNeverReplacesAPresentRow() {
        let harness = makeInventory()
        let inventory = harness.inventory

        inventory.applyWatcherSnapshot([phone], degraded: false)
        inventory.lifecycleSetGhost(phone.serial, workspace: harness.workspaceID)
        XCTAssertEqual(inventory.devices, [phone], "a present row survives its ghost untouched")

        inventory.applyWatcherSnapshot([], degraded: false)
        XCTAssertEqual(inventory.devices.map(\.serial), [phone.serial])
        XCTAssertEqual(inventory.devices.first?.state, "offline")
        XCTAssertEqual(inventory.devices.first?.model, "Pixel 8", "the ghost carries the last-known details")
        XCTAssertTrue(inventory.realDevices.isEmpty, "the ghost is no real row")

        inventory.lifecycleShowStatus(.unauthorized, workspace: harness.workspaceID)
        XCTAssertEqual(inventory.devices.first?.state, "unauthorized")

        inventory.applyWatcherSnapshot([phone], degraded: false)
        XCTAssertEqual(inventory.devices, [phone], "the returning device replaces its ghost")
        XCTAssertEqual(inventory.realDevices, [phone])
        XCTAssertEqual(harness.recorder.selectionFixUps, 3, "every snapshot hands the selection to its owner")
    }

    /// Only the live rows and the ghost keep their last-known details, so
    /// hot-plug churn cannot grow the map.
    func testLastKnownDetailsStayBounded() {
        let harness = makeInventory()
        let inventory = harness.inventory

        for index in 0..<50 {
            inventory.applyWatcherSnapshot([.online("SER-\(index)", transport: "\(index)")], degraded: false)
        }
        XCTAssertEqual(Array(inventory.lastKnownDetails.keys), ["SER-49"])

        inventory.applyWatcherSnapshot([phone], degraded: false)
        inventory.lifecycleSetGhost(phone.serial, workspace: harness.workspaceID)
        inventory.applyWatcherSnapshot([.online("emulator-5554", transport: "3")], degraded: false)
        XCTAssertEqual(
            Set(inventory.lastKnownDetails.keys), [phone.serial, "emulator-5554"],
            "the ghost's details survive the snapshot it is missing from"
        )

        inventory.lifecycleSetGhost(nil, workspace: harness.workspaceID)
        inventory.applyWatcherSnapshot([], degraded: false)
        XCTAssertTrue(inventory.lastKnownDetails.isEmpty)
    }

    // MARK: Per-transport state

    /// A device's Info is dropped when its serial comes back on another
    /// transport (a new VM on a reused emulator serial), but kept for the
    /// ghost while it waits to reconnect.
    func testInfoIsPrunedOnATransportChangeButKeptForTheGhost() {
        let harness = makeInventory()
        let inventory = harness.inventory
        let vm = AndroidDevice.online("emulator-5554", transport: "3")
        inventory.applyWatcherSnapshot([vm], degraded: false)
        inventory.storeDeviceInfo(info(vm.serial), for: vm)

        inventory.lifecycleSetGhost(vm.serial, workspace: harness.workspaceID)
        inventory.applyWatcherSnapshot([], degraded: false)
        XCTAssertNotNil(inventory.deviceInfos[vm.serial], "the ghost keeps its Info while it waits")

        inventory.applyWatcherSnapshot([vm], degraded: false)
        XCTAssertNotNil(inventory.deviceInfos[vm.serial], "the same transport keeps its Info")

        let next = AndroidDevice.online("emulator-5554", transport: "7")
        inventory.applyWatcherSnapshot([next], degraded: false)
        XCTAssertNil(inventory.deviceInfos[vm.serial], "a new transport on the serial is a new device")
    }

    /// A console's AVD name is kept only for the transport it answered on.
    func testConsoleAnswersArePrunedPerTransport() {
        let inventory = makeInventory().inventory
        let vm = AndroidDevice.online("emulator-5554", transport: "3")
        let other = AndroidDevice.online("emulator-5556", transport: "4")
        inventory.applyWatcherSnapshot([vm, other], degraded: false)
        inventory.avdNamesBySerial = [vm.serial: ("3", "Pixel_A"), other.serial: ("4", "Pixel_B")]

        inventory.applyWatcherSnapshot([vm, .online(other.serial, transport: "9")], degraded: false)
        XCTAssertEqual(inventory.avdNamesBySerial[vm.serial]?.avd, "Pixel_A")
        XCTAssertNil(inventory.avdNamesBySerial[other.serial], "a new VM on the serial is asked again")

        inventory.applyWatcherSnapshot([], degraded: false)
        XCTAssertTrue(inventory.avdNamesBySerial.isEmpty, "a serial that left takes its answer with it")
    }

    /// An emulator that left adb gives its gRPC port reservation back, except
    /// the mirrored one's: its VM may only be hidden from adb for a moment,
    /// and its own teardown releases the port. The snapshot forgets both
    /// serials' recorded ports.
    func testVanishedEmulatorPortsExcludeTheActivePort() throws {
        let (activePort, vanishedPort) = try reserveAdjacentPorts()
        let harness = makeInventory()
        let inventory = harness.inventory
        let mirrored = AndroidDevice.online("emulator-5580", transport: "4")
        let other = AndroidDevice.online("emulator-5582", transport: "6")
        inventory.applyWatcherSnapshot([mirrored, other], degraded: false)
        harness.ports.store(activePort, for: mirrored.serial)
        harness.ports.store(vanishedPort, for: other.serial)
        harness.context.serial = mirrored.serial
        harness.context.port = activePort

        inventory.applyWatcherSnapshot([], degraded: false)

        // The pool hands out the first unreserved port: the vanished
        // emulator's is free again, the mirrored one's is still taken.
        XCTAssertEqual(EmulatorManager.firstFreePort(startingAt: activePort, limit: 2), vanishedPort)
        XCTAssertNil(harness.ports.port(for: mirrored.serial))
        XCTAssertNil(harness.ports.port(for: other.serial))
    }

    /// Reserves two adjacent ports in the emulator's in-process pool, both
    /// released when the test ends.
    private func reserveAdjacentPorts() throws -> (Int, Int) {
        for base in stride(from: 8700, to: 8800, by: 2) {
            let first = EmulatorManager.firstFreePort(startingAt: base, limit: 2)
            let second = EmulatorManager.firstFreePort(startingAt: base, limit: 2)
            if first == base, second == base + 1 {
                addTeardownBlock {
                    EmulatorManager.releasePortReservation(first)
                    EmulatorManager.releasePortReservation(second)
                }
                return (first, second)
            }
            EmulatorManager.releasePortReservation(first)
            EmulatorManager.releasePortReservation(second)
        }
        throw XCTSkip("no two adjacent free ports in 8700..<8800")
    }

    // MARK: Lifecycle

    /// A registered coordinator reaches its owner through its hooks (the
    /// harness's stand-in for `DeviceWorkspace.wireLifecycle`): a device
    /// that left mid-mirror is torn down as a disconnect and ghosts its row,
    /// its return resumes the selected device, a restarted adb server
    /// forgets the recorded ports, and stopping takes the decider's own
    /// timers with it — though the coordinator itself, like a workspace's,
    /// stays registered.
    func testTheLifecycleHooksReachTheOwner() async throws {
        // The watcher's adb is `/usr/bin/false`: it reports nothing itself.
        let harness = makeInventory(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        let inventory = harness.inventory
        addTeardownBlock { @MainActor in inventory.stopDeviceLifecycle() }
        let lifecycle = makeCoordinator(harness, selected: phone.serial)
        inventory.startDeviceLifecycle()
        inventory.startDeviceLifecycle()

        inventory.applyWatcherSnapshot([phone], degraded: false)
        lifecycle.noteMirrorStarted(serial: phone.serial)
        lifecycle.handle(.snapshot(devices: [], degraded: false))

        XCTAssertEqual(harness.recorder.teardowns, [.disconnected])
        XCTAssertEqual(inventory.ghostSerial(for: harness.workspaceID), phone.serial)
        XCTAssertEqual(inventory.devices.map(\.model), ["Pixel 8"])
        XCTAssertEqual(lifecycle.reconnectStatus()?.serial, phone.serial, "the waiting panel follows the episode")

        lifecycle.handle(.snapshot(devices: [phone], degraded: false))
        await waitUntil("the returning device was never resumed") {
            harness.recorder.resumes == [phone.serial]
        }

        harness.ports.store(8554, for: "emulator-5554")
        lifecycle.handle(.health(.restarting(attempt: 1)))
        XCTAssertNil(harness.ports.port(for: "emulator-5554"), "a restarted adb server can move every port")

        // Stopping the watcher resets every registered coordinator: its own
        // pending timers cancel and its episode clears — no panel outlives
        // its decider — but, unlike the old single-coordinator model, the
        // coordinator itself is not discarded: a workspace's episode
        // decider lives as long as the workspace does, not as long as the
        // watcher runs, and a later `startDeviceLifecycle`
        // resumes pumping to this very same registered coordinator, freshly
        // reset.
        inventory.stopDeviceLifecycle()
        XCTAssertNil(lifecycle.reconnectStatus(), "no panel outlives its decider")
    }

    /// The two-phase pump fix: `DeviceInventory.pump(_:)` decides every
    /// registered coordinator first — never through its own `applySnapshot`
    /// hook — and applies the snapshot itself exactly once, only once every
    /// coordinator has decided. Registration order must not matter: the
    /// second-registered workspace's own ghost, Info and selection survive a
    /// snapshot that also carries the first workspace's own (unrelated)
    /// decision, and it resumes on replug.
    func testPumpDecidesEveryCoordinatorBeforeApplyingTheSnapshotOnce() async {
        let harness1 = makeInventory()
        let inventory = harness1.inventory
        let emulator = AndroidDevice.online("emulator-5554", transport: "9")
        inventory.applyWatcherSnapshot([phone, emulator], degraded: false)
        inventory.storeDeviceInfo(info(phone.serial), for: phone)

        // Registered first: an unrelated emulator, present the whole time —
        // its own decider has nothing to do on either event below.
        let coordinator1 = makeCoordinator(harness1, selected: emulator.serial)
        coordinator1.noteMirrorStarted(serial: emulator.serial)

        // Registered SECOND: the phone, about to be unplugged — the one the
        // bug moved off its own device before its own ghost had even landed.
        let harness2 = Harness(inventory: inventory, context: harness1.context, ports: harness1.ports, recorder: Recorder())
        let coordinator2 = makeCoordinator(harness2, selected: phone.serial)
        coordinator2.noteMirrorStarted(serial: phone.serial)

        // One pump round, exactly as `DeviceInventory.pump(_:)` runs it:
        // every coordinator decides, then the inventory applies the
        // snapshot itself, once.
        coordinator1.decide(.snapshot(devices: [emulator], degraded: false))
        coordinator2.decide(.snapshot(devices: [emulator], degraded: false))
        inventory.applyWatcherSnapshot([emulator], degraded: false)

        XCTAssertEqual(harness1.recorder.applySnapshotCalls, 0, "decide(_:) must never call a coordinator's own applySnapshot hook")
        XCTAssertEqual(harness2.recorder.applySnapshotCalls, 0)
        XCTAssertEqual(harness2.recorder.teardowns, [.disconnected])
        XCTAssertEqual(
            inventory.ghostSerial(for: harness2.workspaceID), phone.serial,
            "the second-registered workspace still ghosts its own phone"
        )
        XCTAssertNotNil(
            inventory.deviceInfos[phone.serial],
            "the ghost's Info must not be pruned before its own workspace's decider ran"
        )
        XCTAssertEqual(harness1.recorder.teardowns, [], "the first workspace's own device never left")

        coordinator1.decide(.snapshot(devices: [emulator, phone], degraded: false))
        coordinator2.decide(.snapshot(devices: [emulator, phone], degraded: false))
        inventory.applyWatcherSnapshot([emulator, phone], degraded: false)
        await waitUntil("the second-registered workspace never resumed its own phone") {
            harness2.recorder.resumes == [phone.serial]
        }
        XCTAssertTrue(harness1.recorder.resumes.isEmpty, "the first workspace's device was never gone")
    }

    /// The liveness probe names the AVD behind a serial from the mirrored
    /// device's context, then the AVD cards, then the consoles' answers, and
    /// asks the process list for it; an unknown serial answers "gone".
    func testLivenessNamesTheAvdFromTheContextCardsAndConsoles() async throws {
        let avd = "DeviceHubPro_Inventory_\(UUID().uuidString.prefix(8))"
        let vm = try startFakeEmulatorProcess(avd: avd)
        let harness = makeInventory()
        let inventory = harness.inventory
        inventory.emulatorManagerProvider = { EmulatorManager.inert }

        harness.context.serial = "emulator-5580"
        harness.context.avdName = avd
        let mirrored = await inventory.isEmulatorVMRunning(serial: "emulator-5580")
        XCTAssertTrue(mirrored, "the mirrored device's AVD comes from the context")

        inventory.avdCardsSource = {
            [AvdCard(name: avd, displayName: avd, target: nil, skin: nil, isRunning: true, serial: "emulator-5582")]
        }
        let carded = await inventory.isEmulatorVMRunning(serial: "emulator-5582")
        XCTAssertTrue(carded, "a card names the AVD behind its serial")

        inventory.avdNamesBySerial["emulator-5584"] = ("8", avd)
        let answered = await inventory.isEmulatorVMRunning(serial: "emulator-5584")
        XCTAssertTrue(answered, "a console's answer names the AVD")

        let unknown = await inventory.isEmulatorVMRunning(serial: "emulator-5590")
        XCTAssertFalse(unknown, "an unknown AVD answers 'gone'")

        vm.terminate()
        vm.waitUntilExit()
        let gone = await inventory.isEmulatorVMRunning(serial: "emulator-5580")
        XCTAssertFalse(gone, "the VM exited")
    }

    /// An adb server restart (`AdbServerRecovery`) drops every device from
    /// the watcher's list for a moment and brings them back: a device that
    /// was only listed leaves no row at all, one a mirror is open on keeps
    /// one "waiting" ghost row meanwhile, and once the device is back the
    /// list is exactly the real row, with no leftover "Unavailable" ghost.
    func testAnAdbServerRestartLeavesNoGhostRowBehind() async {
        let harness = makeInventory()
        let inventory = harness.inventory
        let lifecycle = makeCoordinator(harness, selected: phone.serial)

        // Listed only: gone while the server restarts, no ghost.
        inventory.applyWatcherSnapshot([phone], degraded: false)
        lifecycle.handle(.health(.restarting(attempt: 1)))
        lifecycle.handle(.snapshot(devices: [], degraded: false))
        XCTAssertTrue(inventory.devices.isEmpty, "a device nothing mirrors leaves no ghost")
        lifecycle.handle(.snapshot(devices: [phone], degraded: false))
        XCTAssertEqual(inventory.devices, [phone])

        // Mirrored: one ghost during the restart, none afterwards.
        lifecycle.noteMirrorStarted(serial: phone.serial)
        lifecycle.handle(.health(.restarting(attempt: 1)))
        lifecycle.handle(.snapshot(devices: [], degraded: false))
        XCTAssertEqual(inventory.devices.map(\.serial), [phone.serial], "one waiting row")
        XCTAssertTrue(inventory.realDevices.isEmpty)
        lifecycle.handle(.snapshot(devices: [phone], degraded: false))
        await waitUntil("the returning device was never resumed") {
            harness.recorder.resumes == [phone.serial]
        }
        XCTAssertEqual(inventory.devices, [phone], "the ghost gave way to the real row")
        XCTAssertEqual(inventory.realDevices, [phone])
        // The resumed mirror (a recorder here) clears the episode's ghost; the
        // merge already never shows it next to the returned real row.
        lifecycle.noteMirrorStarted(serial: phone.serial)
        XCTAssertNil(inventory.ghostSerial(for: harness.workspaceID))
        XCTAssertEqual(inventory.devices, [phone])
    }

    /// A process `EmulatorManager.runningEmulators()` lists as a VM for
    /// `avd`: a shell script named `qemu-system-…`, run with `-avd` (and a
    /// port nothing serves), adopted as this process's own so an
    /// own-process emulator sees it.
    private func startFakeEmulatorProcess(avd: String) throws -> Process {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeVM-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("qemu-system-fake")
        try Data("#!/bin/sh\nwhile :; do sleep 0.2; done\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let process = Process()
        process.executableURL = script
        process.arguments = ["-avd", avd, "-grpc", "\(EmulatorManager.unreachableGrpcPort)"]
        try process.run()
        EmulatorManager.adoptProcess(process.processIdentifier, avd: avd)
        addTeardownBlock {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? FileManager.default.removeItem(at: directory)
        }
        return process
    }
}
