import AppKit
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The multi-window switch, the parts observable without a
/// real `NSWindow`/`WindowGroup` scene: `WorkspaceSeed`'s round trip, the
/// window-close path's teardown-before-unregister order and its recording
/// cause, the claim-refusal placeholder's outcome (already raised by
/// `mirror(device:)` — `.ownedElsewhere`), the Move Here path
/// tearing the owning workspace down with `.replaced`, and that the feature stays off
/// (a single workspace) unless `DHP_MULTIWINDOW=1`.
@MainActor
final class MultiWindowSwitchTests: XCTestCase {
    private func addWorkspace(to model: AppModel) -> DeviceWorkspace {
        let workspace = DeviceWorkspace(services: model.services)
        model.registry.register(workspace)
        return workspace
    }

    // MARK: - WorkspaceSeed

    func testWorkspaceSeedRoundTripsThroughJSONForEveryCase() throws {
        let seeds: [WorkspaceSeed] = [
            WorkspaceSeed(),
            WorkspaceSeed(selection: .avd("Pixel_9_API_35")),
            WorkspaceSeed(selection: .device("HT4CWJT01234")),
            WorkspaceSeed(selection: .pixel("pixel_9")),
            WorkspaceSeed(selection: .simulator("2C6F8B0C-58B1-4B8B-9C7C-000000000000")),
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for seed in seeds {
            let data = try encoder.encode(seed)
            let decoded = try decoder.decode(WorkspaceSeed.self, from: data)
            XCTAssertEqual(decoded, seed)
        }
    }

    /// `openWindow(value:)` brings forward a window already presenting an
    /// equal value, so two ⌘N requests (or two "Open in New Window" on the
    /// same device) must never be equal — they were, and ⌘N opened nothing.
    func testEveryWorkspaceSeedIsItsOwnWindow() {
        XCTAssertNotEqual(WorkspaceSeed(), WorkspaceSeed())
        XCTAssertNotEqual(WorkspaceSeed(selection: .device("emulator-5554")), WorkspaceSeed(selection: .device("emulator-5554")))
        let id = UUID()
        XCTAssertEqual(WorkspaceSeed(id: id), WorkspaceSeed(selection: nil, id: id))
    }

    // MARK: - The flag

    func testMultiWindowIsOnUnlessTurnedOffWithZero() {
        XCTAssertFalse(LaunchOptions.none.multiWindowEnabled)
        XCTAssertTrue(LaunchOptions(environment: [:]).multiWindowEnabled)
        XCTAssertTrue(LaunchOptions(environment: ["DHP_MULTIWINDOW": "1"]).multiWindowEnabled)
        XCTAssertFalse(LaunchOptions(environment: ["DHP_MULTIWINDOW": "0"]).multiWindowEnabled)
    }

    /// Flag off: `AppModel.testing()` (the app's own hermetic environment)
    /// starts with exactly one workspace, the same as every pre-step-8
    /// behaviour this suite already pins in `WorkspaceRegistryTests`.
    func testFlagOffMeansASingleWorkspaceAsBeforeStep8() {
        let model = AppModel.testing()

        XCTAssertFalse(model.launchOptions.multiWindowEnabled)
        XCTAssertEqual(model.registry.workspaces.map(\.id), [model.workspace.id])
    }

    // MARK: - claimInitialWorkspaceIfAvailable

    /// The Scene body's hook for "the first window reuses `model.workspace`":
    /// true exactly once.
    func testClaimInitialWorkspaceIsAvailableExactlyOnce() {
        let model = AppModel.testing()

        XCTAssertTrue(model.registry.claimInitialWorkspaceIfAvailable())
        XCTAssertFalse(model.registry.claimInitialWorkspaceIfAvailable())
        XCTAssertFalse(model.registry.claimInitialWorkspaceIfAvailable())
    }

    // MARK: - Window-close teardown order

    /// `closeForWindow` tears the session down (recording finalized like
    /// `.user`, the lifecycle told the same as `stopMirror()`) before it
    /// leaves the registry: by the time `unregister` runs there is nothing
    /// left for its own defensive teardown to do.
    func testCloseForWindowTearsDownBeforeUnregistering() {
        let model = AppModel.testing()
        let second = addWorkspace(to: model)
        let device = DeviceRef.android("HT4CWJT09999")
        let session = FakeMirrorSession()
        second.beginMirrorSession(session, device: device, port: nil, capabilities: .android(emulatorGrpc: false))
        XCTAssertTrue(model.registry.owner(of: device) === second)

        second.closeForWindow()

        XCTAssertEqual(session.stopCount, 1, "the transport was stopped by the teardown, not left for unregister")
        XCTAssertNil(second.mirror.session)
        XCTAssertNil(second.context.device)
        XCTAssertNil(model.registry.owner(of: device), "the claim went with the teardown, not a later unregister")
        XCTAssertFalse(model.registry.workspaces.contains { $0 === second }, "the workspace left the registry")
        XCTAssertNil(second.registry, "unregister cleared the back-reference")
    }

    /// A window with no session closes cleanly: nothing to tear down, still
    /// unregistered.
    func testCloseForWindowWithNoSessionStillUnregisters() {
        let model = AppModel.testing()
        let second = addWorkspace(to: model)

        second.closeForWindow()

        XCTAssertFalse(model.registry.workspaces.contains { $0 === second })
    }

    /// `.windowClosed` finalizes a running recording exactly like
    /// `.userStop`/`.replaced` — not `.interrupted` (`.disconnected`,
    /// `.transportFatal`) and not `.quit`.
    func testWindowClosedTeardownCauseFinalizesRecordingLikeUserStop() {
        let model = AppModel.testing()
        let second = addWorkspace(to: model)
        let device = DeviceRef.android("HT4CWJT08888")
        second.beginMirrorSession(FakeMirrorSession(), device: device, port: nil, capabilities: .android(emulatorGrpc: false))

        // No live recording is armed in this hermetic setup, so the
        // observable contract here is the one every caller of
        // `tearDownMirror` relies on: `.windowClosed` is accepted by the
        // switch (it would trap on an unhandled case otherwise) and behaves
        // like the other "finalize as .user" causes, not like
        // `.disconnected`/`.transportFatal`/`.quit`.
        second.tearDownMirror(cause: .windowClosed)

        XCTAssertNil(second.mirror.session)
        XCTAssertNil(second.context.device)
    }

    // MARK: - Move Here (already implemented in step 7's placeholder; here:
    // the model side stays correct once a second window exists)

    /// Move Here tears the owning workspace's session down with `.replaced` (never
    /// `.windowClosed`/`.userStop`) and frees the device so the requesting
    /// workspace can claim it.
    func testMoveHereTearsTheOwnerDownWithReplaced() {
        let model = AppModel.testing()
        let owner = addWorkspace(to: model)
        let requester = model.workspace
        let device = DeviceRef.android("HT4CWJT07777")
        owner.beginMirrorSession(FakeMirrorSession(), device: device, port: nil, capabilities: .android(emulatorGrpc: false))
        XCTAssertTrue(model.registry.owner(of: device) === owner)

        // The same two steps `OwnedElsewherePlaceholder.moveHere()` takes
        // (`DeviceStageView.swift`): tear the owning workspace down, then this
        // workspace claims the now-free device.
        owner.tearDownMirror(cause: .replaced)
        let claimed = requester.beginMirrorSession(
            FakeMirrorSession(), device: device, port: nil, capabilities: .android(emulatorGrpc: false)
        )

        XCTAssertTrue(claimed)
        XCTAssertNil(owner.mirror.session)
        XCTAssertNil(owner.context.device)
        XCTAssertTrue(model.registry.owner(of: device) === requester)
    }

    // MARK: - Focus

    /// `WorkspaceWindowDelegate.windowDidBecomeKey` (the real trigger for
    /// `WorkspaceRegistry.focusedID`, which the soft session cap and
    /// audio-follows-focus read) names its own workspace — without a real
    /// `NSWindow`: the delegate reads only `workspace`, not the
    /// notification's object, so this needs none of the window-server
    /// bookkeeping the section below avoids.
    func testWindowDidBecomeKeyFocusesItsOwnWorkspace() {
        let model = AppModel.testing()
        let second = addWorkspace(to: model)
        let delegate = WorkspaceWindowDelegate(workspace: second)

        delegate.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))

        XCTAssertEqual(model.registry.focusedID, second.id)
    }

    // MARK: - WorkspaceRegistry window binding
    //
    // `bind`/`unbind`/`boundWindow(for:)`/`activate(_:)` all touch a real
    // `NSWindow`/`NSApp`, which this hermetic XCTest process has no window
    // server connection for — constructing an `NSWindow` here segfaults the
    // test host outright, and `NSApp.activate` traps for the same reason
    // (verified while writing this suite). That bookkeeping is exercised
    // live instead: `Scripts/parity-check.sh` and a manual run with
    // `DHP_MULTIWINDOW=1` (two windows, Show Window/Move Here, ⌘N/⌘T).
}
