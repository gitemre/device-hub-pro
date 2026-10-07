import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The workspace registry: device claims, the routing of
/// the app-wide actions to the workspace that owns a device, and quit
/// stopping every workspace's session side by side.
@MainActor
final class WorkspaceRegistryTests: XCTestCase {
    /// A second workspace on `model`'s services, registered beside its own.
    private func addWorkspace(to model: AppModel) -> DeviceWorkspace {
        let workspace = DeviceWorkspace(services: model.services)
        model.registry.register(workspace)
        return workspace
    }

    func testTheModelsWorkspaceIsItsOnlyMemberAndFocused() {
        let model = AppModel.testing()

        XCTAssertEqual(model.registry.workspaces.map(\.id), [model.workspace.id])
        XCTAssertTrue(model.registry.focused === model.workspace)
        XCTAssertTrue(model.workspace.registry === model.registry)
    }

    /// One session per device: a device another workspace holds is
    /// refused, and free again once that workspace gives it up or leaves.
    func testClaimRefusesADeviceAnotherWorkspaceHolds() {
        let model = AppModel.testing()
        let first = model.workspace
        let second = addWorkspace(to: model)
        let phone = DeviceRef.android("HT4CWJT01234")

        XCTAssertTrue(model.registry.claim(phone, for: first))
        XCTAssertTrue(model.registry.claim(phone, for: first), "a workspace's own claim holds")
        XCTAssertFalse(model.registry.claim(phone, for: second))
        XCTAssertTrue(model.registry.owner(of: phone) === first)

        model.registry.release(phone, for: second)
        XCTAssertTrue(model.registry.owner(of: phone) === first, "only the holder releases")
        model.registry.release(phone, for: first)
        XCTAssertNil(model.registry.owner(of: phone))
        XCTAssertTrue(model.registry.claim(phone, for: second))

        model.registry.unregister(second)
        XCTAssertNil(model.registry.owner(of: phone), "a closed window's claims go with it")
        XCTAssertTrue(model.registry.claim(phone, for: first))
    }

    /// Every workspace shares the app's recent APKs and links: each store
    /// writes its whole list, so a copy per window would drop entries.
    func testWorkspacesShareTheRecentStores() {
        let model = AppModel.testing()
        let second = addWorkspace(to: model)

        XCTAssertTrue(second.links.recents === model.links.recents)
        XCTAssertTrue(model.links.recents === model.services.recentLinks)
        XCTAssertTrue(second.apps.recentAPKs === model.apps.recentAPKs)
        XCTAssertTrue(model.apps.recentAPKs === model.services.recentAPKs)
    }

    /// The session hubs keep the claims: a begun session claims its
    /// device, its teardown gives it up.
    func testTheSessionHubsClaimAndRelease() {
        let model = AppModel.testing()
        let second = addWorkspace(to: model)
        let phone = DeviceRef.android("HT4CWJT01234")

        second.beginMirrorSession(FakeMirrorSession(), device: phone, port: nil, capabilities: .android(emulatorGrpc: false))
        XCTAssertTrue(model.registry.owner(of: phone) === second)
        XCTAssertFalse(model.registry.claim(phone, for: model.workspace))

        second.stopMirror()
        XCTAssertNil(model.registry.owner(of: phone))
        XCTAssertTrue(model.registry.claim(phone, for: model.workspace))
    }

    /// Stop Emulator reaches the workspace that mirrors the AVD's VM, not
    /// the focused one: that window's session ends as the user's stop and
    /// the focused window's session is left alone.
    func testStopEmulatorReachesTheOwnerNotTheFocusedWorkspace() async throws {
        let target = "Owned_\(UUID().uuidString.prefix(6))"
        let emulator = try makeStubEmulator(avds: [target])
        let adb = try makeStubAdb(arms: """
          "devices -l")
            printf 'List of devices attached\\n' ;;
          "track-devices"*)
            exec sleep 30 ;;
        """)
        let model = AppModel.testing(adb: adb.client, emulator: emulator.manager)
        addTeardownBlock { @MainActor in model.inventory.stopDeviceLifecycle() }
        let other = addWorkspace(to: model)
        model.registry.focusedID = model.workspace.id
        let focusedSession = FakeMirrorSession()
        model.workspace.beginMirrorSession(
            focusedSession,
            device: .android("HT4CWJT01234"),
            port: nil,
            capabilities: .android(emulatorGrpc: false)
        )
        let ownedSession = FakeMirrorSession()
        other.beginMirrorSession(
            ownedSession,
            device: .android("emulator-5556"),
            port: nil,
            avdName: target,
            capabilities: .android(emulatorGrpc: true)
        )
        XCTAssertTrue(model.registry.owner(ofAvd: target, serial: nil) === other)

        await model.stopEmulator(avd: target)

        XCTAssertNil(other.mirror.session, "the owning workspace's session ends")
        XCTAssertEqual(ownedSession.stopCount, 1)
        XCTAssertNil(other.context.device)
        XCTAssertTrue(model.workspace.mirror.session === focusedSession, "the focused window keeps its session")
        XCTAssertEqual(focusedSession.stopCount, 0)
        XCTAssertEqual(model.activeDeviceSerial, "HT4CWJT01234")
        // `stopEmulator` routes its status line and error to the device's
        // owner (`deviceStatus(for:)`), not the focused
        // workspace or the app-global center.
        XCTAssertNil(other.status.errorMessage)
        model.stopMirror()
    }

    // MARK: - Per-workspace status

    /// Each workspace's own `StatusCenter` never crosses into another
    /// window's: an error a per-device flow raised in workspace B
    /// (`stopEmulator`'s owner routing above raises one the same way) is
    /// invisible to the merge `ContentView` builds for workspace A
    /// (`StatusCenter.active(error:_:)` over the app-global center and A's
    /// own), while B's own merge still shows it.
    func testAWorkspacesErrorNeverShowsInAnotherWorkspacesMerge() {
        let model = AppModel.testing()
        let other = addWorkspace(to: model)

        other.status.errorMessage = "Could not resize the display of Pixel_9."

        XCTAssertNil(
            StatusCenter.active(error: model.status, model.workspace.status).errorMessage,
            "workspace B's error must not surface in workspace A's merge"
        )
        XCTAssertEqual(
            StatusCenter.active(error: model.status, other.status).errorMessage,
            "Could not resize the display of Pixel_9.",
            "workspace B's own merge still shows it"
        )
    }

    /// A global error (inventory, refresh, pairing, the AVD catalog, the
    /// SDK, preferences, a batch's aggregate line) shows in every window's
    /// merge, the focused one included: `AppModel.errorMessage` stays the
    /// app-global center's value.
    func testAGlobalErrorShowsInEveryWorkspacesMerge() {
        let model = AppModel.testing()
        let other = addWorkspace(to: model)

        model.status.errorMessage = "Could not list the AVDs: some failure"

        XCTAssertEqual(
            StatusCenter.active(error: model.status, model.workspace.status).errorMessage,
            "Could not list the AVDs: some failure",
            "the key window's merge shows the global error"
        )
        XCTAssertEqual(
            StatusCenter.active(error: model.status, other.status).errorMessage,
            "Could not list the AVDs: some failure",
            "every other window's merge shows the same global error"
        )
    }

    /// Quit with three phone sessions (three windows) whose stops each
    /// block for 1.5 s: every stop begins before any is waited for, so quit
    /// takes about one stop, well inside its bound, not the three in a row.
    func testQuitStopsEveryWorkspacesSessionSideBySide() async {
        let model = AppModel.testing(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        let workspaces = [model.workspace, addWorkspace(to: model), addWorkspace(to: model)]
        var sessions: [FakePhysicalSession] = []
        for (index, workspace) in workspaces.enumerated() {
            let session = FakePhysicalSession(serial: "HT4CWJT0123\(index)")
            session.stopAndWaitDelay = 1.5
            workspace.beginMirrorSession(
                session,
                device: .android(session.serial),
                port: nil,
                capabilities: .android(emulatorGrpc: false)
            )
            sessions.append(session)
        }

        let started = Date()
        await model.prepareForTermination(timeout: .seconds(6))
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 3.0, "the stops ran side by side (in a row they take 4.5 s): \(elapsed) s")
        XCTAssertEqual(sessions.map(\.stopAndWaitCount), [1, 1, 1], "every stop finished inside the bound")
        XCTAssertTrue(workspaces.allSatisfy { $0.mirror.session == nil && $0.context.device == nil })
    }

    /// `beginMirrorSession` honours `claim`: a device
    /// another workspace's session already owns is refused, and this
    /// workspace's own running session is left exactly as it was — no
    /// teardown, no claim change.
    func testBeginMirrorSessionRefusesADeviceAnotherWorkspaceOwnsWithoutTouchingItsOwnSession() {
        let model = AppModel.testing()
        let first = model.workspace
        let second = addWorkspace(to: model)
        let ownSession = FakeMirrorSession()
        let ownDevice = DeviceRef.android("HT4CWJT01111")
        XCTAssertTrue(first.beginMirrorSession(
            ownSession, device: ownDevice, port: nil, capabilities: .android(emulatorGrpc: false)
        ))
        let contested = DeviceRef.android("HT4CWJT02222")
        second.beginMirrorSession(
            FakeMirrorSession(), device: contested, port: nil, capabilities: .android(emulatorGrpc: false)
        )

        let refused = first.beginMirrorSession(
            FakeMirrorSession(), device: contested, port: nil, capabilities: .android(emulatorGrpc: false)
        )

        XCTAssertFalse(refused)
        XCTAssertTrue(first.mirror.session === ownSession, "the refused start left the running session alone")
        XCTAssertEqual(first.context.device, ownDevice)
        XCTAssertTrue(model.registry.owner(of: ownDevice) === first)
        XCTAssertTrue(model.registry.owner(of: contested) === second)
    }

    /// `mirror(device:)` returns `.ownedElsewhere` ahead of any attach when
    /// another workspace's session already owns the device, so the caller
    /// can show "Shown in another window" instead of racing an attach that
    /// `beginMirrorSession` would refuse anyway.
    func testMirrorReturnsOwnedElsewhereForADeviceAnotherWorkspaceOwns() async {
        let model = AppModel.testing()
        let first = model.workspace
        let second = addWorkspace(to: model)
        let owned = AndroidDevice(serial: "HT4CWJT03333", state: "device")
        second.beginMirrorSession(
            FakeMirrorSession(), device: .android(owned.serial), port: nil,
            capabilities: .android(emulatorGrpc: false)
        )

        let outcome = await first.mirror(device: owned)

        XCTAssertEqual(outcome, .ownedElsewhere(second.id))
        XCTAssertNil(first.mirror.session)
        XCTAssertNil(first.mirror.mirrorAttach, "no attaching/failed state was raised for it")
    }

    /// A quit stop begun for one workspace does not block the main actor:
    /// the teardown returns at once and the wait is the caller's.
    func testBeginQuitTeardownDoesNotBlock() async throws {
        let model = AppModel.testing(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        let session = FakePhysicalSession(serial: "HT4CWJT01234")
        session.stopAndWaitDelay = 1.0
        model.workspace.beginMirrorSession(
            session,
            device: .android(session.serial),
            port: nil,
            capabilities: .android(emulatorGrpc: false)
        )

        let started = Date()
        let stop = try XCTUnwrap(model.workspace.beginQuitTeardown())
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "the teardown did not wait for the stop")
        XCTAssertNil(model.workspace.mirror.session)
        await stop.value
        XCTAssertEqual(session.stopAndWaitCount, 1)
        XCTAssertFalse(model.mirror.defersQuitStop, "only that teardown defers its stop")
    }

    // MARK: - Soft session cap

    /// A model built with `DHP_MULTIWINDOW=1`.
    private func multiWindowModel() -> AppModel {
        AppModel.testing(launch: LaunchOptions(environment: ["DHP_MULTIWINDOW": "1"]))
    }

    /// Starts a live session on `workspace` for a distinct android device.
    @discardableResult
    private func beginSession(_ workspace: DeviceWorkspace, serial: String) -> FakeMirrorSession {
        let session = FakeMirrorSession()
        workspace.beginMirrorSession(
            session, device: .android(serial), port: nil,
            capabilities: .android(emulatorGrpc: false)
        )
        return session
    }

    /// Starting a 5th live session (cap 4) warns, naming whichever other
    /// workspace was focused longest ago; a 4th or earlier starts clean.
    func testTheFifthLiveSessionWarnsNamingTheLeastRecentlyFocusedWorkspace() throws {
        let model = multiWindowModel()
        let workspaces = [model.workspace] + (0..<4).map { _ in addWorkspace(to: model) }
        // Focus every workspace but the last, oldest first: [0] is focused
        // longest ago, [4] never becomes key.
        for workspace in workspaces.dropLast() {
            model.registry.focusedID = workspace.id
        }

        for (index, workspace) in workspaces.enumerated() {
            beginSession(workspace, serial: "serial-\(index)")
            if index < 4 {
                XCTAssertNil(workspace.window.sessionCapWarning, "session \(index + 1) of 4 must not warn")
            }
        }

        let warning = try XCTUnwrap(workspaces[4].window.sessionCapWarning)
        XCTAssertEqual(warning.leastRecentlyFocusedID, workspaces[0].id)
    }

    /// The same five sessions never warn with the flag off.
    func testNoWarningWithMultiWindowDisabled() {
        let model = AppModel.testing()
        let workspaces = [model.workspace] + (0..<4).map { _ in addWorkspace(to: model) }

        for (index, workspace) in workspaces.enumerated() {
            beginSession(workspace, serial: "serial-\(index)")
        }

        XCTAssertNil(workspaces[4].window.sessionCapWarning)
    }

    /// Stop & Continue ends the suggested workspace's session and clears the
    /// warning; the workspace that triggered it is untouched.
    func testResolveSessionCapWarningStopEndsTheCandidatesSession() {
        let model = multiWindowModel()
        let workspaces = [model.workspace] + (0..<4).map { _ in addWorkspace(to: model) }
        for workspace in workspaces.dropLast() {
            model.registry.focusedID = workspace.id
        }
        for (index, workspace) in workspaces.enumerated() {
            beginSession(workspace, serial: "serial-\(index)")
        }
        let warned = workspaces[4]
        XCTAssertNotNil(warned.window.sessionCapWarning)

        warned.resolveSessionCapWarning(stop: true)

        XCTAssertNil(warned.window.sessionCapWarning)
        XCTAssertNil(workspaces[0].mirror.session, "the least recently focused workspace's session was stopped")
        XCTAssertNotNil(warned.mirror.session, "the workspace that triggered the warning keeps its own session")
    }

    /// Continue Anyway just dismisses the warning: every session is left as
    /// it was.
    func testResolveSessionCapWarningContinueAnywayLeavesEverySessionRunning() {
        let model = multiWindowModel()
        let workspaces = [model.workspace] + (0..<4).map { _ in addWorkspace(to: model) }
        for workspace in workspaces.dropLast() {
            model.registry.focusedID = workspace.id
        }
        for (index, workspace) in workspaces.enumerated() {
            beginSession(workspace, serial: "serial-\(index)")
        }
        let warned = workspaces[4]

        warned.resolveSessionCapWarning(stop: false)

        XCTAssertNil(warned.window.sessionCapWarning)
        for workspace in workspaces {
            XCTAssertNotNil(workspace.mirror.session)
        }
    }

    /// `focusOrder` names the workspace that has waited longest for
    /// attention: a re-focus moves it to the back.
    func testLeastRecentlyFocusedFollowsRefocusing() {
        let model = AppModel.testing()
        let second = addWorkspace(to: model)
        beginSession(model.workspace, serial: "serial-a")
        beginSession(second, serial: "serial-b")
        model.registry.focusedID = model.workspace.id
        model.registry.focusedID = second.id

        XCTAssertTrue(model.registry.leastRecentlyFocused(excluding: second.id) === model.workspace)

        model.registry.focusedID = model.workspace.id
        XCTAssertTrue(model.registry.leastRecentlyFocused(excluding: model.workspace.id) === second)
    }

    // MARK: - Audio follows the key window

    /// Starts an emulator session with a gRPC port, so `shouldPlayInAppAudio`
    /// has something to play.
    @discardableResult
    private func beginEmulatorSession(_ workspace: DeviceWorkspace, serial: String, port: Int) -> FakeMirrorSession {
        let session = FakeMirrorSession()
        workspace.beginMirrorSession(
            session, device: .android(serial), port: port,
            capabilities: .android(emulatorGrpc: true)
        )
        return session
    }

    /// With multi-window enabled, only the focused workspace should play;
    /// switching focus moves which one without touching either session.
    func testOnlyTheFocusedWorkspaceShouldPlayInAppAudio() {
        let model = multiWindowModel()
        model.setEmulatorAudioMode(.inApp)
        let second = addWorkspace(to: model)
        beginEmulatorSession(model.workspace, serial: "serial-a", port: 5001)
        beginEmulatorSession(second, serial: "serial-b", port: 5002)

        model.registry.focusedID = model.workspace.id
        XCTAssertTrue(model.workspace.shouldPlayInAppAudio)
        XCTAssertFalse(second.shouldPlayInAppAudio)
        XCTAssertTrue(second.mirror.audioPlayer.isRunning == false, "the unfocused workspace must not play")

        model.registry.focusedID = second.id
        XCTAssertFalse(model.workspace.shouldPlayInAppAudio, "focus moved away")
        XCTAssertTrue(second.shouldPlayInAppAudio)
        XCTAssertTrue(model.workspace.mirror.audioPlayer.isRunning == false, "the session was not restarted into playing muted")

        // Neither session was touched by the focus change.
        XCTAssertNotNil(model.workspace.mirror.session)
        XCTAssertNotNil(second.mirror.session)
    }

    /// With the flag off, every workspace should play (single-window mode).
    func testEveryWorkspaceShouldPlayWithMultiWindowDisabled() {
        let model = AppModel.testing()
        model.setEmulatorAudioMode(.inApp)
        let second = addWorkspace(to: model)
        beginEmulatorSession(model.workspace, serial: "serial-a", port: 5001)
        beginEmulatorSession(second, serial: "serial-b", port: 5002)

        model.registry.focusedID = model.workspace.id

        XCTAssertTrue(model.workspace.shouldPlayInAppAudio)
        XCTAssertTrue(second.shouldPlayInAppAudio, "single-window mode: focus never mutes another workspace")
    }

    /// Before any window has become key (`focusedID` nil), every workspace
    /// should still play, even with multi-window enabled.
    func testEveryWorkspaceShouldPlayBeforeAnyWindowIsFocused() {
        let model = multiWindowModel()
        model.setEmulatorAudioMode(.inApp)
        let second = addWorkspace(to: model)
        beginEmulatorSession(model.workspace, serial: "serial-a", port: 5001)
        beginEmulatorSession(second, serial: "serial-b", port: 5002)

        XCTAssertNil(model.registry.focusedID)
        XCTAssertTrue(model.workspace.shouldPlayInAppAudio)
        XCTAssertTrue(second.shouldPlayInAppAudio)
    }

    /// Settings' Enabled/Disabled modes never play in-app audio, focused or
    /// not.
    func testHostOrDisabledAudioModeNeverPlaysInApp() {
        let model = multiWindowModel()
        beginEmulatorSession(model.workspace, serial: "serial-a", port: 5001)
        model.registry.focusedID = model.workspace.id

        XCTAssertEqual(model.preferences.emulatorAudioMode, .enabled, "the default is host audio")
        XCTAssertFalse(model.workspace.shouldPlayInAppAudio)

        model.setEmulatorAudioMode(.disabled)
        XCTAssertFalse(model.workspace.shouldPlayInAppAudio)
    }
}
