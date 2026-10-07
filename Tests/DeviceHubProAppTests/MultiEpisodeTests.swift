import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// one `DeviceLifecycleCoordinator` per workspace. Two
/// windows mirroring different devices must run two independent episodes —
/// a phone's unplug in one window must not tear down, ghost or resume the
/// other window's emulator, and vice versa — and a workspace built the way
/// a second window would be must come out fully wired, the same as the
/// model's own.
@MainActor
final class MultiEpisodeTests: XCTestCase {
    private let phoneA = AndroidDevice.online("HT4CWJT01234", transport: "5", model: "Pixel 8")
    private let emulatorB = AndroidDevice.online("emulator-5554", transport: "3", model: "sdk_gphone64_arm64")

    /// A second workspace on `model`'s services, registered beside its own
    /// (`WorkspaceRegistryTests.addWorkspace`).
    private func addWorkspace(to model: AppModel) -> DeviceWorkspace {
        let workspace = DeviceWorkspace(services: model.services)
        model.registry.register(workspace)
        return workspace
    }

    /// Two workspaces, each mirroring its own device over a fake session
    /// (`beginMirrorSession` directly, as `WorkspaceRegistryTests` does, so
    /// no real transport or gRPC port resolution is needed) — phone A in
    /// workspace 1 (the model's own), emulator B in workspace 2. The
    /// lifecycle watcher runs (its adb is `/usr/bin/false`, so it reports
    /// nothing on its own); events are driven directly at each workspace's
    /// own coordinator, exactly as the real pump would deliver them.
    private func twoMirroredWorkspaces() -> (model: AppModel, workspace1: DeviceWorkspace, workspace2: DeviceWorkspace, sessionA: FakeMirrorSession, sessionB: FakeMirrorSession) {
        let model = AppModel.testing(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        let workspace1 = model.workspace
        let workspace2 = addWorkspace(to: model)
        model.inventory.startDeviceLifecycle()

        let sessionA = FakeMirrorSession()
        workspace1.beginMirrorSession(
            sessionA,
            device: .android(phoneA.serial),
            port: nil,
            capabilities: .android(emulatorGrpc: false)
        )
        // `beginMirrorSession` does not select: the resume hook's pre-mirror
        // re-check (`DeviceWorkspace.lifecycleResume`) requires the intent
        // (the workspace's own selection) to still name the serial.
        workspace1.deviceSelection = .device(phoneA.serial)

        let sessionB = FakeMirrorSession()
        workspace2.beginMirrorSession(
            sessionB,
            device: .android(emulatorB.serial),
            port: nil,
            avdName: "Pixel_9",
            capabilities: .android(emulatorGrpc: true)
        )
        workspace2.deviceSelection = .device(emulatorB.serial)

        return (model, workspace1, workspace2, sessionA, sessionB)
    }

    /// Unplugging A tears down and ghosts only workspace 1: workspace 2's
    /// emulator B session, selection and ghost state are untouched.
    func testUnplugTearsDownAndGhostsOnlyItsOwnWorkspace() {
        let (model, workspace1, workspace2, sessionA, sessionB) = twoMirroredWorkspaces()
        addTeardownBlock { @MainActor in model.inventory.stopDeviceLifecycle() }

        // Only workspace 1's coordinator hears about A's disappearance —
        // exactly as the real pump would (workspace 2's own coordinator
        // never received this event, so nothing about it can move).
        workspace1.lifecycle.handle(.snapshot(devices: [emulatorB], degraded: false))

        XCTAssertEqual(sessionA.stopCount, 1, "workspace 1's session is torn down")
        XCTAssertNil(workspace1.mirror.session)
        XCTAssertEqual(
            model.services.inventory.ghostSerial(for: workspace1.id), phoneA.serial,
            "workspace 1's own episode ghosts its row"
        )

        XCTAssertEqual(sessionB.stopCount, 0, "workspace 2's session survives untouched")
        XCTAssertTrue(workspace2.mirror.session === sessionB)
        XCTAssertEqual(workspace2.context.device, .android(emulatorB.serial))
        XCTAssertNil(
            model.services.inventory.ghostSerial(for: workspace2.id),
            "workspace 2's episode never ran, so it never ghosts anything"
        )
    }

    /// Replugging resumes only workspace 1: its own coordinator's resume
    /// hook re-attaches A, while workspace 2's emulator session is left
    /// exactly as it was.
    func testReplugResumesOnlyItsOwnWorkspace() async {
        let (model, workspace1, workspace2, sessionA, sessionB) = twoMirroredWorkspaces()
        addTeardownBlock { @MainActor in model.inventory.stopDeviceLifecycle() }
        var resumed: [FakeMirrorSession] = []
        workspace1.mirror.sessionFactoryOverride = { _, _ in
            let session = FakeMirrorSession()
            resumed.append(session)
            return session
        }

        workspace1.lifecycle.handle(.snapshot(devices: [emulatorB], degraded: false))
        XCTAssertEqual(sessionA.stopCount, 1)

        // A comes back: only workspace 1 hears about it.
        workspace1.lifecycle.handle(.snapshot(devices: [phoneA, emulatorB], degraded: false))
        await waitUntil("workspace 1 never resumed A") {
            workspace1.mirror.session != nil && !resumed.isEmpty
        }

        XCTAssertTrue(workspace1.mirror.session === resumed.first, "workspace 1 re-attached A")
        XCTAssertNil(
            model.services.inventory.ghostSerial(for: workspace1.id),
            "the returning device replaces workspace 1's ghost"
        )
        XCTAssertTrue(workspace2.mirror.session === sessionB, "workspace 2's session was never touched")
        XCTAssertEqual(sessionB.stopCount, 0)
    }

    /// An Apple session starting in workspace 2 does not end A's episode in
    /// workspace 1: `noteNonAdbMirrorStarted` only reaches workspace 2's own
    /// coordinator, so workspace 1's phone keeps its episode intact.
    func testAnAppleSessionInOneWorkspaceDoesNotEndAnotherWorkspacesEpisode() {
        let (model, workspace1, workspace2, sessionA, sessionB) = twoMirroredWorkspaces()
        addTeardownBlock { @MainActor in model.inventory.stopDeviceLifecycle() }

        let simulator = DeviceRef.apple("00000000-0000-4000-8000-00000000B002")
        let appleSession = FakeMirrorSession()
        // Replaces workspace 2's emulator session with an Apple one: its own
        // coordinator hears `.nonAdbMirrorStarted`, never workspace 1's.
        workspace2.beginMirrorSession(appleSession, device: simulator, port: nil, capabilities: [.mirror])
        XCTAssertEqual(sessionB.stopCount, 1, "workspace 2's own emulator session was replaced")

        // Workspace 1's phone is still selected and mirrored — its episode
        // (armed by its own `noteMirrorStarted`) is unaffected by workspace
        // 2's Apple session starting.
        workspace1.lifecycle.handle(.snapshot(devices: [], degraded: false))
        XCTAssertEqual(sessionA.stopCount, 1, "workspace 1's own disconnect episode still runs")
        XCTAssertEqual(model.services.inventory.ghostSerial(for: workspace1.id), phoneA.serial)

        XCTAssertTrue(workspace2.mirror.session === appleSession, "workspace 2's Apple session keeps running")
        XCTAssertEqual(appleSession.stopCount, 0)
    }

    /// B's VM liveness check belongs to workspace 2 only: an emulator adb
    /// loses is not torn down until its own coordinator's grace period and
    /// liveness probe say so — and workspace 1's unrelated phone episode
    /// never moves while that runs.
    func testEmulatorLivenessCheckBelongsToItsOwnWorkspace() async {
        let (model, workspace1, workspace2, sessionA, sessionB) = twoMirroredWorkspaces()
        addTeardownBlock { @MainActor in model.inventory.stopDeviceLifecycle() }
        // No VM anywhere: `EmulatorManager.inert` sees only this process's
        // own children, so the liveness probe answers "gone" once it runs.
        model.services.inventory.emulatorManagerProvider = { EmulatorManager.inert }

        // Only workspace 2's coordinator hears B's disappearance.
        workspace2.lifecycle.handle(.snapshot(devices: [phoneA], degraded: false))
        XCTAssertEqual(sessionB.stopCount, 0, "an emulator's adb absence alone never tears it down at once")

        // Workspace 1's phone A is present throughout and entirely
        // untouched by workspace 2's liveness check running its course.
        XCTAssertEqual(sessionA.stopCount, 0)
        XCTAssertTrue(workspace1.mirror.session === sessionA)
        XCTAssertNil(model.services.inventory.ghostSerial(for: workspace1.id))

        await waitUntil(timeout: 8, "workspace 2's own liveness check never tore B down") {
            sessionB.stopCount == 1
        }
        // Emulators never ghost (`SessionLifecycle.enterDisconnected`: no
        // auto-resume, the AVD row returns to its stopped hero instead) —
        // the scoping this asserts is that workspace 2's own check ran the
        // teardown at all, on its own, without workspace 1 moving.
        XCTAssertNil(model.services.inventory.ghostSerial(for: workspace2.id))
        XCTAssertEqual(sessionA.stopCount, 0, "workspace 1's session never moved during workspace 2's check")
        XCTAssertNil(model.services.inventory.ghostSerial(for: workspace1.id))
    }

    /// A second workspace's `deviceSelection` reaches its own coordinator on
    /// its own — `selectionChanged` is now wired by `DeviceWorkspace` itself
    /// (`wireLifecycle`), not only for `model.workspace` by `AppModel` — so
    /// moving a second workspace's selection away from a device waiting to
    /// reconnect clears that workspace's own ghost and cancels its own
    /// pending resume, exactly as it always did for the model's own.
    func testASecondWorkspacesSelectionChangeReachesItsOwnCoordinator() {
        let model = AppModel.testing(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        addTeardownBlock { @MainActor in model.inventory.stopDeviceLifecycle() }
        let second = addWorkspace(to: model)
        model.inventory.startDeviceLifecycle()

        let session = FakeMirrorSession()
        second.beginMirrorSession(
            session,
            device: .android(phoneA.serial),
            port: nil,
            capabilities: .android(emulatorGrpc: false)
        )
        second.deviceSelection = .device(phoneA.serial)

        second.lifecycle.handle(.snapshot(devices: [], degraded: false))
        XCTAssertEqual(
            model.services.inventory.ghostSerial(for: second.id), phoneA.serial,
            "the second workspace ghosts the phone it was mirroring"
        )

        // No AppModel involvement at all: the second workspace's own
        // `deviceSelection` didSet reaches its own coordinator directly.
        second.deviceSelection = .device(emulatorB.serial)
        XCTAssertNil(
            model.services.inventory.ghostSerial(for: second.id),
            "moving the second workspace's own selection away must clear its own ghost"
        )

        // The device coming back must not resume over the workspace's new
        // selection — the pending resume was cancelled with the ghost, so
        // the decider (now `.idle`) has no episode left to react with.
        second.lifecycle.handle(.snapshot(devices: [phoneA], degraded: false))
        XCTAssertNil(second.mirror.session, "no session was ever re-attached")
        XCTAssertNil(
            model.services.inventory.ghostSerial(for: second.id),
            "the replug must not re-arm a ghost for an episode that already ended"
        )
    }

    /// `stopDeviceLifecycle()` clears every workspace's own waiting panel:
    /// no panel outlives its decider, even though (unlike the old
    /// single-coordinator model) the coordinator behind it is not discarded.
    func testStoppingTheLifecycleClearsEveryWorkspacesReconnectPanel() {
        let (model, workspace1, workspace2, _, _) = twoMirroredWorkspaces()
        addTeardownBlock { @MainActor in model.inventory.stopDeviceLifecycle() }

        workspace1.lifecycle.handle(.snapshot(devices: [emulatorB], degraded: false))
        XCTAssertNotNil(workspace1.reconnect, "the panel is up while the episode runs")
        XCTAssertNil(workspace2.reconnect, "workspace 2 never had an episode")

        model.inventory.stopDeviceLifecycle()

        XCTAssertNil(workspace1.reconnect, "no panel outlives its decider")
        XCTAssertNil(workspace2.reconnect)
    }

    // MARK: Full wiring parity ("Open for steps 6–8")

    /// A workspace built the way a second window would be
    /// (`DeviceWorkspace.init(services:context:)`) comes out with the same
    /// hooks wired as the model's own — not just its lifecycle coordinator,
    /// but every per-device feature `AppModel`'s wire* methods used to reach
    /// only through `model.workspace`. Every hook checked here defaults to a
    /// no-op / nil / `false` (`DeviceWorkspace`'s own controllers'
    /// defaults): the assertions below only hold once `wireAppHooks()` has
    /// actually replaced them, so this is a wiring check, not a behavior one.
    func testASecondWorkspaceGetsTheSameHooksWiredAsTheModelsOwn() async throws {
        let model = AppModel.testing(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        addTeardownBlock { @MainActor in model.inventory.stopDeviceLifecycle() }
        let second = addWorkspace(to: model)
        // The lifecycle calls below are gated on the watcher running (LOW1):
        // matches how a real window's workspace always has one by the time
        // it can mirror anything.
        model.inventory.startDeviceLifecycle()

        // The lifecycle: its own coordinator notes a mirror start and later
        // reports a ghost/reconnect episode, exactly like the model's own —
        // then a clean stop, so the rest of this test mirrors a fresh device.
        second.beginMirrorSession(
            FakeMirrorSession(),
            device: .android(phoneA.serial),
            port: nil,
            capabilities: .android(emulatorGrpc: false)
        )
        second.deviceSelection = .device(phoneA.serial)
        second.lifecycle.handle(.snapshot(devices: [], degraded: false))
        XCTAssertEqual(
            model.services.inventory.ghostSerial(for: second.id), phoneA.serial,
            "the second workspace's own coordinator is wired to the inventory's ghost, like the model's own"
        )
        second.lifecycle.handle(.snapshot(devices: [phoneA], degraded: false))
        second.stopMirror()

        // mirror.physicalModel: names a device from the shared rows (the
        // default answers nil for every serial).
        model.services.inventory.setRealDevices([phoneA])
        XCTAssertEqual(second.mirror.physicalModel(phoneA.serial), phoneA.model)

        // media.displayName: the shared display-name lookup (the default
        // echoes the `DeviceRef`'s own id, the adb serial here).
        XCTAssertEqual(second.media.displayName(.android(phoneA.serial)), phoneA.model)

        // A live, still-running session, so the session-dependent hooks
        // below have something real to read.
        let session = FakeMirrorSession()
        second.beginMirrorSession(
            session,
            device: .android(phoneA.serial),
            port: nil,
            capabilities: .android(emulatorGrpc: false)
        )
        second.deviceSelection = .device(phoneA.serial)
        addTeardownBlock { @MainActor in second.stopMirror() }

        // capture.liveSelectionSerialProvider: this workspace's own live
        // selection (the default is always nil).
        XCTAssertEqual(second.capture.liveSelectionSerialProvider(), phoneA.serial)

        // window.devicePixelSize: this workspace's own mirror view state
        // (the default is always nil).
        second.mirror.mirrorViewState.devicePixelSize = CGSize(width: 1080, height: 2400)
        XCTAssertEqual(second.window.devicePixelSize(), CGSize(width: 1080, height: 2400))

        // controlsPanel.hasSession: this workspace's own mirror (the default
        // is always false).
        XCTAssertTrue(second.controlsPanel.hasSession())

        // hardware.devicesSource: the shared rows (the default is always empty).
        XCTAssertEqual(second.hardware.devicesSource(), model.services.inventory.devices)

        // apps.activeSerialSource: this workspace's own mirrored serial (the
        // default is always nil).
        XCTAssertEqual(second.apps.activeSerialSource(), phoneA.serial)

        // simulatorApps.recordRecentURL: this workspace's own Links recents
        // (the default drops it on the floor).
        second.simulatorApps.recordRecentURL("https://example.com/deep-link")
        XCTAssertTrue(second.links.recents.links.contains("https://example.com/deep-link"))
    }
}
