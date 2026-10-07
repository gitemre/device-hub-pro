import XCTest
import DeviceHubProKit
@testable import DeviceHubProApp

@MainActor
final class DeviceLifecycleCoordinatorTests: XCTestCase {
    private final class Recorder {
        var snapshots: [(devices: [AndroidDevice], degraded: Bool)] = []
        var teardowns: [TeardownReason] = []
        var resumes: [String] = []
        var statuses: [CanvasStatusKind] = []
        var ghosts: [String?] = []
        var flashes: [String] = []
        var restarts = 0
        /// Every lifecycle state reported through the `lifecycleState` hook,
        /// deduped by the coordinator — for episode-mapping assertions.
        var states: [SessionLifecycleState] = []
        /// Unified order of every hook delivery, for ordering assertions.
        var log: [String] = []
    }

    private func makeCoordinator(
        selected: String? = "HT4CWJT01234",
        policy: ReconnectPolicy = .init(delays: [.milliseconds(5)], maxAttempts: 5),
        isEmulatorRunning: ((String) async -> Bool)? = nil
    ) -> (DeviceLifecycleCoordinator, Recorder) {
        let recorder = Recorder()
        var hooks = DeviceLifecycleCoordinator.Hooks(
            applySnapshot: { devices, degraded in
                recorder.snapshots.append((devices, degraded))
                recorder.log.append("snapshot")
            },
            teardown: {
                recorder.teardowns.append($0)
                recorder.log.append("teardown")
            },
            resume: {
                recorder.resumes.append($0)
                recorder.log.append("resume:\($0)")
            },
            showStatus: {
                recorder.statuses.append($0)
                recorder.log.append("status")
            },
            setGhost: {
                recorder.ghosts.append($0)
                recorder.log.append("ghost:\($0 ?? "nil")")
            },
            healthFlash: {
                recorder.flashes.append($0)
                recorder.log.append("flash")
            },
            transportRestarted: {
                recorder.restarts += 1
                recorder.log.append("restart")
            },
            selectedSerial: { selected },
            lifecycleState: {
                recorder.states.append($0)
            }
        )
        if let isEmulatorRunning {
            hooks.isEmulatorRunning = isEmulatorRunning
        }
        return (DeviceLifecycleCoordinator(hooks: hooks, policy: policy), recorder)
    }

    /// The mirrored phone's USB entry left adb while the same phone is
    /// online over Wi-Fi (the grouped snapshot carries the USB serial as an
    /// alias of the Wi-Fi row). No ghost, no waiting panel; the mirror
    /// restarts on the live transport.
    func testAPhoneThatMovedToWifiResumesOnTheLiveTransportWithoutAGhost() async {
        let usb = "aqaserial001"
        let ip = "198.51.100.11:41473"
        let (coordinator, recorder) = makeCoordinator(selected: ip)
        coordinator.noteMirrorStarted(serial: usb)

        coordinator.decide(
            .snapshot(devices: [AndroidDevice(serial: ip, state: "device")], degraded: false),
            aliases: [usb: ip]
        )
        // Best effort: sleep only fails on cancellation; the assertions still follow.
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(recorder.teardowns, [.disconnected])
        XCTAssertEqual(recorder.resumes, [ip])
        XCTAssertFalse(recorder.ghosts.contains { $0 == usb }, "no ghost row for the unplugged transport")
        XCTAssertTrue(recorder.statuses.isEmpty, "no Currently Unavailable / reconnect status")
        XCTAssertNil(coordinator.reconnectStatus())
    }

    /// An emulator adb loses is torn down only after the grace period, and
    /// only when the VM is gone (the hook's default answer is "gone").
    func testEmulatorAbsenceTearsDownAfterTheLivenessCheck() async {
        let (coordinator, recorder) = makeCoordinator(
            selected: "emulator-5554",
            policy: .init(delays: [.milliseconds(5)], maxAttempts: 5, emulatorAbsenceGrace: .milliseconds(20))
        )
        coordinator.noteMirrorStarted(serial: "emulator-5554")
        coordinator.handle(.snapshot(devices: [], degraded: false))
        XCTAssertTrue(recorder.teardowns.isEmpty, "no teardown on adb absence alone")
        // Best effort: sleep only fails on cancellation; the assertion still follows.
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(recorder.teardowns, [.disconnected])
        XCTAssertTrue(recorder.resumes.isEmpty, "emulators never auto-resume")
    }

    /// A running VM keeps its gRPC mirror through an adb blip.
    func testRunningEmulatorVMSurvivesAnAdbBlip() async {
        let (coordinator, recorder) = makeCoordinator(
            selected: "emulator-5554",
            policy: .init(delays: [.milliseconds(5)], maxAttempts: 5, emulatorAbsenceGrace: .milliseconds(20)),
            isEmulatorRunning: { _ in true }
        )
        coordinator.noteMirrorStarted(serial: "emulator-5554")
        coordinator.handle(.snapshot(devices: [], degraded: false))
        // Best effort: sleep only fails on cancellation; the assertion still follows.
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(recorder.teardowns.isEmpty, "a live VM keeps its mirror")
        coordinator.stop()
    }

    /// The user's stop ends the episode: a later unplug neither tears down
    /// again nor ghosts the row, and a replug never resumes the mirror.
    func testUserStopEndsTheEpisode() async {
        let (coordinator, recorder) = makeCoordinator()
        let phone = AndroidDevice(serial: "HT4CWJT01234", state: "device")
        coordinator.noteMirrorStarted(serial: "HT4CWJT01234")

        coordinator.noteMirrorStopped(serial: "HT4CWJT01234")
        coordinator.handle(.snapshot(devices: [], degraded: false))
        coordinator.handle(.snapshot(devices: [phone], degraded: false))
        // Best effort: sleep only fails on cancellation; the assertion still follows.
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(recorder.teardowns.isEmpty, "the stop already ended the session")
        XCTAssertTrue(recorder.resumes.isEmpty, "a stopped mirror never comes back on its own")
        XCTAssertTrue(recorder.ghosts.compactMap { $0 }.isEmpty)
        XCTAssertEqual(recorder.states.last, .idle)
    }

    /// A stop for a serial that is not the one mirrored changes nothing.
    func testStopOfAnotherSerialIsIgnored() {
        let (coordinator, recorder) = makeCoordinator()
        coordinator.noteMirrorStarted(serial: "HT4CWJT01234")

        coordinator.noteMirrorStopped(serial: "emulator-5554")
        coordinator.handle(.snapshot(devices: [], degraded: false))

        XCTAssertEqual(recorder.teardowns, [.disconnected], "the mirrored phone's episode is untouched")
    }

    /// Stopping an emulator's mirror while adb has lost it cancels the
    /// pending VM check: no teardown and no probe follow.
    func testUserStopCancelsAPendingLivenessCheck() async {
        let probes = ProbeCounter()
        let (coordinator, recorder) = makeCoordinator(
            selected: "emulator-5554",
            policy: .init(delays: [.milliseconds(5)], maxAttempts: 5, emulatorAbsenceGrace: .milliseconds(20)),
            isEmulatorRunning: { _ in
                await probes.increment()
                return false
            }
        )
        coordinator.noteMirrorStarted(serial: "emulator-5554")
        coordinator.handle(.snapshot(devices: [], degraded: false))

        coordinator.noteMirrorStopped(serial: "emulator-5554")
        // Best effort: sleep only fails on cancellation; the assertion still follows.
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertTrue(recorder.teardowns.isEmpty)
        let count = await probes.count
        XCTAssertEqual(count, 0, "the VM probe is not run for an episode the user ended")
    }

    /// An Apple session replacing an emulator's cancels the pending VM
    /// check: the AVD stopped meanwhile tears nothing down (it would tear
    /// the Apple session down) and the probe is not run.
    func testANonAdbSessionCancelsTheReplacedEmulatorsLivenessCheck() async {
        let probes = ProbeCounter()
        let (coordinator, recorder) = makeCoordinator(
            selected: "emulator-5554",
            policy: .init(delays: [.milliseconds(5)], maxAttempts: 5, emulatorAbsenceGrace: .milliseconds(20)),
            isEmulatorRunning: { _ in
                await probes.increment()
                return false
            }
        )
        coordinator.noteMirrorStarted(serial: "emulator-5554")
        coordinator.handle(.snapshot(devices: [], degraded: false))

        coordinator.noteNonAdbMirrorStarted()
        coordinator.handle(.snapshot(devices: [], degraded: false))
        // Best effort: sleep only fails on cancellation; the assertion still follows.
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertTrue(recorder.teardowns.isEmpty)
        let count = await probes.count
        XCTAssertEqual(count, 0, "the VM probe is not run for a session that was replaced")
        XCTAssertEqual(recorder.states.last, .idle)
    }

    /// The phone variant: the replaced phone's unplug and replug neither
    /// tear down, ghost nor resume.
    func testANonAdbSessionEndsTheReplacedPhonesEpisode() async {
        let (coordinator, recorder) = makeCoordinator()
        let phone = AndroidDevice(serial: "HT4CWJT01234", state: "device")
        coordinator.noteMirrorStarted(serial: "HT4CWJT01234")

        coordinator.noteNonAdbMirrorStarted()
        coordinator.handle(.snapshot(devices: [], degraded: false))
        coordinator.handle(.snapshot(devices: [phone], degraded: false))
        // Best effort: sleep only fails on cancellation; the assertion still follows.
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(recorder.teardowns.isEmpty)
        XCTAssertTrue(recorder.resumes.isEmpty)
        XCTAssertTrue(recorder.ghosts.compactMap { $0 }.isEmpty)
        XCTAssertNil(coordinator.reconnectStatus())
    }

    func testUnplugTearsDownOnceAndSetsGhost() {
        let (coordinator, recorder) = makeCoordinator()
        coordinator.noteMirrorStarted(serial: "HT4CWJT01234")
        coordinator.handle(.snapshot(devices: [], degraded: false))
        XCTAssertEqual(recorder.teardowns, [.disconnected])
        XCTAssertEqual(recorder.ghosts.compactMap { $0 }, ["HT4CWJT01234"])
        XCTAssertEqual(recorder.statuses, [.unreachable])
    }

    /// The decider must run before the snapshot hook: `AppModel`'s
    /// `applyWatcherSnapshot` merges the ghost the decider just built, so its
    /// `ensureDeviceSelection()` still sees the selected serial and keeps it
    /// (the "Device unreachable" panel needs the selection to survive).
    func testGhostArrivesBeforeTheSnapshotSoTheSelectionSurvives() {
        let (coordinator, recorder) = makeCoordinator()
        coordinator.noteMirrorStarted(serial: "HT4CWJT01234")
        coordinator.handle(.snapshot(devices: [], degraded: false))
        guard let ghostIndex = recorder.log.firstIndex(of: "ghost:HT4CWJT01234"),
              let snapshotIndex = recorder.log.firstIndex(of: "snapshot")
        else {
            XCTFail("expected a ghost hook and a snapshot hook; log: \(recorder.log)")
            return
        }
        XCTAssertLessThan(
            ghostIndex,
            snapshotIndex,
            "the ghost must be delivered before the snapshot hook; log: \(recorder.log)"
        )
        XCTAssertEqual(recorder.ghosts.compactMap { $0 }, ["HT4CWJT01234"])
    }

    func testRepeatedAbsenceCallsTeardownOnce() {
        let (coordinator, recorder) = makeCoordinator()
        coordinator.noteMirrorStarted(serial: "HT4CWJT01234")
        coordinator.handle(.snapshot(devices: [], degraded: false))
        coordinator.handle(.snapshot(devices: [], degraded: false))
        XCTAssertEqual(recorder.teardowns, [.disconnected], "teardown happens once per incident")
    }

    func testReplugResumesThroughHook() async {
        let (coordinator, recorder) = makeCoordinator()
        let phone = AndroidDevice(serial: "HT4CWJT01234", state: "device")
        coordinator.noteMirrorStarted(serial: "HT4CWJT01234")
        coordinator.handle(.snapshot(devices: [], degraded: false))
        coordinator.handle(.snapshot(devices: [phone], degraded: false))
        await waitUntil { recorder.resumes == ["HT4CWJT01234"] }
        XCTAssertEqual(recorder.resumes, ["HT4CWJT01234"])
    }

    func testStaleTimerNeverResumesAfterSelectionChange() async {
        let (coordinator, recorder) = makeCoordinator(selected: "emulator-5554")
        let phone = AndroidDevice(serial: "HT4CWJT01234", state: "device")
        coordinator.noteMirrorStarted(serial: "HT4CWJT01234")
        coordinator.handle(.snapshot(devices: [], degraded: false))
        coordinator.handle(.snapshot(devices: [phone], degraded: false))
        coordinator.noteSelectionChanged()
        // Best effort: sleep only fails on cancellation; the assertion still follows.
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(recorder.resumes.isEmpty, "a cancelled resume timer must not steal the stage")
        XCTAssertEqual(recorder.ghosts.last, .some(nil))
    }

    func testHealthRestartCallsTransportRestartedOncePerIncident() {
        let (coordinator, recorder) = makeCoordinator()
        coordinator.handle(.health(.restarting(attempt: 1)))
        coordinator.handle(.health(.restarting(attempt: 2)))
        XCTAssertEqual(recorder.restarts, 2, "one call per restart signal; cache invalidation is idempotent")
        XCTAssertEqual(recorder.flashes.count, 1, "one flashStatus per incident (spec §5.2), not per signal")
    }

    func testHealthFlashReturnsAfterASnapshotEndsTheIncident() {
        let (coordinator, recorder) = makeCoordinator()
        coordinator.handle(.health(.restarting(attempt: 1)))
        coordinator.handle(.snapshot(devices: [], degraded: false))
        coordinator.handle(.health(.restarting(attempt: 1)))
        XCTAssertEqual(recorder.flashes.count, 2, "the snapshot closed the incident; the next one flashes again")
    }

    func testSnapshotHookReceivesDegradedFlag() {
        let (coordinator, recorder) = makeCoordinator()
        coordinator.handle(.snapshot(devices: [], degraded: true))
        XCTAssertEqual(recorder.snapshots.count, 1)
        XCTAssertTrue(recorder.snapshots[0].degraded)
    }

    func testResumeFailedSchedulesAnotherAttemptThroughHooks() async {
        let (coordinator, recorder) = makeCoordinator()
        let phone = AndroidDevice(serial: "HT4CWJT01234", state: "device")
        coordinator.noteMirrorStarted(serial: "HT4CWJT01234")
        coordinator.handle(.snapshot(devices: [], degraded: false))
        coordinator.handle(.snapshot(devices: [phone], degraded: false))
        await waitUntil { recorder.resumes.count == 1 }
        coordinator.noteResumeFailed(serial: "HT4CWJT01234")
        await waitUntil { recorder.resumes.count == 2 }
        XCTAssertEqual(recorder.resumes, ["HT4CWJT01234", "HT4CWJT01234"])
    }

    // MARK: Ghost merge (pure)

    func testGhostMergeAppendsGhostOnlyWhileAbsent() {
        let ghost = AndroidDevice(serial: "HT4CWJT01234", state: "offline")
        let merged = GhostEntry.merge(snapshot: [], ghost: ghost)
        XCTAssertEqual(merged.map(\.serial), ["HT4CWJT01234"])
        XCTAssertTrue(GhostEntry.merge(snapshot: [], ghost: nil).isEmpty)
    }

    func testGhostMergeRealDeviceWins() {
        let ghost = AndroidDevice(serial: "HT4CWJT01234", state: "offline")
        let real = AndroidDevice(serial: "HT4CWJT01234", state: "device")
        XCTAssertEqual(GhostEntry.merge(snapshot: [real], ghost: ghost), [real])
    }

    // MARK: Ghost rows (model — spec §5.2 amendment)

    func testGhostNeverReplacesAPresentRealRow() {
        let model = AppModel.testing()
        let real = AndroidDevice(serial: "HT4CWJT01234", state: "device", model: "Pixel 8")
        model.inventory.applyWatcherSnapshot([real], degraded: false)
        model.inventory.lifecycleSetGhost("HT4CWJT01234", workspace: model.workspace.id)
        XCTAssertEqual(model.inventory.devices, [real], "a present real row survives the ghost untouched")

        model.inventory.applyWatcherSnapshot([], degraded: false)
        model.inventory.lifecycleSetGhost("HT4CWJT01234", workspace: model.workspace.id)
        XCTAssertEqual(model.inventory.devices.map(\.serial), ["HT4CWJT01234"])
        XCTAssertEqual(model.inventory.devices.first?.state, "offline", "an absent serial gains the synthetic entry")

        model.inventory.lifecycleSetGhost(nil, workspace: model.workspace.id)
        XCTAssertTrue(model.inventory.devices.isEmpty, "clearing removes only the synthetic entry")
    }

    func testClearingTheGhostKeepsAPresentRealRow() {
        let model = AppModel.testing()
        let real = AndroidDevice(serial: "HT4CWJT01234", state: "device", model: "Pixel 8")
        model.inventory.applyWatcherSnapshot([], degraded: false)
        model.inventory.lifecycleSetGhost("HT4CWJT01234", workspace: model.workspace.id)
        XCTAssertEqual(model.inventory.devices.first?.state, "offline")
        model.inventory.applyWatcherSnapshot([real], degraded: false)
        model.inventory.lifecycleSetGhost(nil, workspace: model.workspace.id)
        XCTAssertEqual(model.inventory.devices, [real], "setGhost(nil) removes only the synthetic entry")
    }

    func testGhostKeepsLastKnownDetailsWhileStaleSerialsArePruned() {
        let model = AppModel.testing()
        let a = AndroidDevice(serial: "SER-A", state: "device", model: "ModelA")
        let b = AndroidDevice(serial: "SER-B", state: "device", model: "ModelB")
        model.inventory.applyWatcherSnapshot([a, b], degraded: false)
        model.inventory.lifecycleSetGhost("SER-B", workspace: model.workspace.id)
        model.inventory.applyWatcherSnapshot([], degraded: false)
        XCTAssertEqual(model.inventory.devices.map(\.model), ["ModelB"], "the ghost keeps its last-known details")

        model.inventory.lifecycleSetGhost(nil, workspace: model.workspace.id)
        model.inventory.applyWatcherSnapshot([], degraded: false)
        model.inventory.lifecycleSetGhost("SER-B", workspace: model.workspace.id)
        XCTAssertEqual(
            model.inventory.devices.map(\.displayName), ["SER-B"],
            "pruned serials leave no details behind — the map stays bounded"
        )
    }

    // MARK: Resume hook — pre-mirror re-check (model)

    func testResumeHookBailsBeforeMirrorWhenTheSelectionMovedOn() async {
        let model = AppModel.testing()
        // `state: "offline"` keeps `mirror()` transport-free: its first guard
        // surfaces the error synchronously, so `errorMessage` pins whether
        // `mirror()` was reached at all.
        let phone = AndroidDevice(serial: "HT4CWJT01234", state: "offline", model: "Pixel 8")
        model.inventory.devices = [phone]
        model.select(phone)
        // The user moved on before the resume task ran.
        model.deviceSelection = .device("emulator-5554")
        await model.lifecycleResume(serial: "HT4CWJT01234")
        XCTAssertNil(model.workspace.status.errorMessage, "a stale auto-resume must bail before mirror()")
        XCTAssertEqual(model.deviceSelection, .device("emulator-5554"), "mirror()'s select(device) must not run")
    }

    func testResumeHookProceedsWhileTheSerialStaysSelected() async {
        let model = AppModel.testing()
        let phone = AndroidDevice(serial: "HT4CWJT01234", state: "offline", model: "Pixel 8")
        model.inventory.devices = [phone]
        model.select(phone)
        await model.lifecycleResume(serial: "HT4CWJT01234")
        XCTAssertNotNil(model.workspace.status.errorMessage, "mirror() was reached and surfaced its own guard error")
    }

    // MARK: Reconnect-cycle alert suppression (S2)

    /// Item 12, 2026-09-28: only `PhysicalMirrorSession`'s own EOF message
    /// ("the transport went away") is a disconnect; every other fatal
    /// message — a decode failure, a corrupt protocol header, an
    /// unsupported codec, a plain test fixture string — still needs the
    /// user and stays off this policy.
    func testIsDisconnectMatchesOnlyTheTransportsOwnEOFMessage() {
        XCTAssertTrue(TransportErrorPolicy.isDisconnect("The mirror stream ended unexpectedly"))
        XCTAssertTrue(TransportErrorPolicy.isDisconnect(
            "The mirror stream ended unexpectedly (scrcpy server: [server] INFO: Device: [Xiaomi] Redmi 2209116AG (Android 13))"
        ))
        XCTAssertFalse(TransportErrorPolicy.isDisconnect("scrcpy decode: corrupt packet"))
        XCTAssertFalse(TransportErrorPolicy.isDisconnect("scrcpy: unsupportedCodec(0)"))
        XCTAssertFalse(TransportErrorPolicy.isDisconnect("The device went away."))
        XCTAssertFalse(TransportErrorPolicy.isDisconnect(""))
    }

    /// The wiring, not `!armed`: a machine-driven resume that fails must
    /// stash the failure for the waiting panel's Details and leave the alert
    /// surface alone, while the identical failure with no armed cycle
    /// surfaces. The decider arms its own schedule here (default policy,
    /// attempt 1 after 500 ms) so the marker comes from the real arming path
    /// rather than from the assertion's assumption.
    func testArmedResumeFailureIsStashedAndUnarmedSurfaces() async {
        let phone = AndroidDevice(serial: "HT4CWJT01234", state: "offline", model: "Pixel 8")

        // Machine-driven half. `/usr/bin/false` yields no device, so the
        // watcher's snapshots stay far behind the 500 ms arming timer, and
        // the offline row keeps `mirror()` transport-free.
        let model = AppModel.testing(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        defer { model.inventory.stopDeviceLifecycle() }
        model.inventory.devices = [phone]
        model.select(phone)
        model.inventory.startDeviceLifecycle()
        model.workspace.lifecycleIfRunning?.noteMirrorStarted(serial: phone.serial)
        model.workspace.lifecycleIfRunning?.noteTransportFatal(serial: phone.serial)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, model.workspace.mirror.lastTransportError == nil {
            // Best effort: a sleep only fails on cancellation; the loop re-checks the deadline.
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(
            model.workspace.lifecycleIfRunning?.isAutoReconnectArmed(serial: phone.serial) ?? false,
            "the schedule armed the cycle the resume hook just ran under"
        )
        XCTAssertNotNil(
            model.workspace.mirror.lastTransportError,
            "the auto attempt ran through the wired resume hook and recorded its failure"
        )
        XCTAssertNil(
            model.workspace.status.errorMessage,
            "a machine-driven cycle's failure stays off the alert surface (S2)"
        )

        // Unarmed half: the same offline row with no cycle in flight.
        let manual = AppModel.testing()
        manual.inventory.devices = [phone]
        manual.select(phone)
        await manual.lifecycleResume(serial: phone.serial)
        XCTAssertNotNil(
            manual.workspace.status.errorMessage,
            "without an armed cycle the identical failure surfaces"
        )
    }

    /// S21: a machine-driven resume that fails with the very message the
    /// alert already shows is still recorded for the panel's Details — the
    /// errorMessage diff used to miss it — and still reported to the
    /// decider, while the alert it did not raise stays as it was.
    func testArmedResumeRecordsAFailureTheAlertAlreadyShows() async throws {
        // No model: the fatal's ghost row carries no details either, so the
        // resume fails with exactly the message the manual attempt raised.
        let phone = AndroidDevice(serial: "HT4CWJT01234", state: "offline")
        // As above: `/usr/bin/false` keeps the watcher's snapshots behind the
        // 500 ms arming timer, and the offline row keeps `mirror()`
        // transport-free.
        let model = AppModel.testing(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        defer { model.inventory.stopDeviceLifecycle() }
        model.inventory.devices = [phone]
        model.select(phone)
        // A manual attempt already raised the failure the resume will repeat.
        await model.mirror(device: phone)
        let shown = try XCTUnwrap(model.workspace.status.errorMessage)
        XCTAssertNil(model.workspace.mirror.lastTransportError)

        model.inventory.startDeviceLifecycle()
        model.workspace.lifecycleIfRunning?.noteMirrorStarted(serial: phone.serial)
        model.workspace.lifecycleIfRunning?.noteTransportFatal(serial: phone.serial)
        XCTAssertEqual(model.workspace.reconnect, ReconnectStatus(serial: phone.serial, isArmed: true, attempt: 1))

        // The default policy runs attempt 1 after 500 ms; its failure
        // schedules attempt 2 (1 s later), which the panel then narrates.
        await waitUntil("the armed resume never reported its failure") {
            model.workspace.reconnect == ReconnectStatus(serial: phone.serial, isArmed: true, attempt: 2)
        }
        XCTAssertTrue(
            model.workspace.lifecycleIfRunning?.isAutoReconnectArmed(serial: phone.serial) ?? false,
            "the failed attempt ran inside the machine's armed cycle"
        )
        XCTAssertEqual(
            model.workspace.mirror.lastTransportError,
            shown,
            "the failure is recorded for the panel's Details even though the alert already showed it"
        )
        XCTAssertEqual(model.workspace.status.errorMessage, shown, "the alert this attempt did not raise stays as it was")
    }

    /// m2: the Details disclosure must not carry a previous episode's
    /// failure into the session that follows — `stopMirror` clears the
    /// stash alongside `reportedMirrorError`.
    func testStopMirrorClearsTheStashedTransportError() async {
        let model = AppModel.testing()
        let phone = AndroidDevice(serial: "HT4CWJT01234", state: "offline", model: "Pixel 8")
        model.inventory.devices = [phone]
        model.select(phone)
        await model.lifecycleResume(serial: phone.serial)
        XCTAssertNotNil(
            model.workspace.mirror.lastTransportError,
            "the failed attempt is recorded for the panel's Details"
        )
        model.stopMirror()
        XCTAssertNil(
            model.workspace.mirror.lastTransportError,
            "a fresh session must not show the previous episode's error"
        )
    }

    /// The waiting panel's model comes from the decider's episode state plus
    /// the armed marker: recovering is armed with the attempt the schedule
    /// will run, exhausted is manual, `.mirroring` shows only while the
    /// machine's attempt is armed (so the panel spans the whole episode,
    /// attempt windows included), and idle hides.
    func testReconnectStatusMapsTheLifecycleState() {
        XCTAssertNil(ReconnectStatus(state: .idle, armedAttempt: nil))
        XCTAssertNil(
            ReconnectStatus(state: .mirroring(serial: "HT4CWJT01234"), armedAttempt: nil),
            "a healthy or manual session has no panel"
        )
        XCTAssertEqual(
            ReconnectStatus(state: .mirroring(serial: "HT4CWJT01234"), armedAttempt: 3),
            ReconnectStatus(serial: "HT4CWJT01234", isArmed: true, attempt: 3),
            "the armed attempt window keeps the panel up and narrates its attempt"
        )
        XCTAssertEqual(
            ReconnectStatus(state: .recovering(serial: "HT4CWJT01234", nextAttempt: 3, deviceBack: true), armedAttempt: nil),
            ReconnectStatus(serial: "HT4CWJT01234", isArmed: true, attempt: 2),
            "deviceBack means the schedule is armed for nextAttempt - 1"
        )
        XCTAssertEqual(
            ReconnectStatus(state: .recovering(serial: "HT4CWJT01234", nextAttempt: 2, deviceBack: false), armedAttempt: nil),
            ReconnectStatus(serial: "HT4CWJT01234", isArmed: true, attempt: 2),
            "waiting for the device still reports the attempt a return would run"
        )
        XCTAssertEqual(
            ReconnectStatus(state: .ghostSelected(serial: "HT4CWJT01234"), armedAttempt: nil),
            ReconnectStatus(serial: "HT4CWJT01234", isArmed: false, attempt: nil),
            "attempts exhausted: manual only, no attempt line"
        )
    }

    /// The panel copy's two halves: the armed cycle's reassurance and the
    /// honest exhausted state's instruction (S4 round 1, m3).
    func testWaitingPanelCopyMatchesTheArmedAndExhaustedStates() {
        XCTAssertEqual(
            ReconnectWaitingCopy.body(isArmed: true),
            "Plug the cable back in. Device Hub Pro reconnects automatically."
        )
        XCTAssertEqual(
            ReconnectWaitingCopy.body(isArmed: false),
            "Reconnect the device, then press Reconnect or Rescan."
        )
    }

    /// DH's own headline's secondary line adapted
    /// from "<name> must be nearby or plugged in to
    /// connect with this Mac." for adb's own transports.
    func testUnavailableLineNamesTheDeviceAndBothTransports() {
        XCTAssertEqual(
            ReconnectWaitingCopy.unavailableLine(deviceName: "Pixel 8"),
            "Pixel 8 must be plugged in or on the same network (wireless debugging) to connect with this Mac."
        )
    }

    /// The armed marker spans exactly the machine's own cycle — set when the
    /// resume timer fires, kept through the attempt's mirror start, dropped
    /// by a healthy session — and the hook reports every state transition.
    func testArmedMarkerSpansTheAutoCycleAndTheHookReportsStates() async {
        let (coordinator, recorder) = makeCoordinator()
        coordinator.noteMirrorStarted(serial: "HT4CWJT01234")
        coordinator.noteTransportFatal(serial: "HT4CWJT01234")
        XCTAssertFalse(
            coordinator.isAutoReconnectArmed(serial: "HT4CWJT01234"),
            "arming happens at the resume timer, not at the teardown"
        )
        // The test policy schedules attempt 1 after 5 ms.
        await waitUntil { coordinator.isAutoReconnectArmed(serial: "HT4CWJT01234") }
        XCTAssertTrue(coordinator.isAutoReconnectArmed(serial: "HT4CWJT01234"))
        XCTAssertEqual(recorder.states.last, .recovering(serial: "HT4CWJT01234", nextAttempt: 2, deviceBack: true))
        coordinator.noteMirrorStarted(serial: "HT4CWJT01234")
        XCTAssertTrue(
            coordinator.isAutoReconnectArmed(serial: "HT4CWJT01234"),
            "the attempt's mirror start continues the machine-driven episode"
        )
        coordinator.noteMirrorHealthy(serial: "HT4CWJT01234")
        XCTAssertFalse(
            coordinator.isAutoReconnectArmed(serial: "HT4CWJT01234"),
            "a healthy session ends the episode and reopens the alert surface"
        )
        XCTAssertEqual(recorder.states.last, .mirroring(serial: "HT4CWJT01234"))
    }

    /// The panel spans the WHOLE machine-driven episode (S4 round 1): it
    /// holds the stage through every armed attempt window — an armed
    /// `.mirroring` used to vacate it, and that alternating surface *was*
    /// the flicker — and vacates when the resumed stream actually delivers
    /// (frame evidence, the round-2 grace), not on a count of clean polls.
    func testWaitingPanelHoldsThroughTheArmedAttemptAndVacatesWhenHealthy() async {
        let serial = "HT4CWJT01234"
        let phone = AndroidDevice(serial: serial, state: "offline", model: "Pixel 8")
        let model = AppModel.testing(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        defer { model.inventory.stopDeviceLifecycle() }
        model.inventory.devices = [phone]
        model.select(phone)
        model.inventory.startDeviceLifecycle()

        model.workspace.lifecycleIfRunning?.noteMirrorStarted(serial: serial)
        XCTAssertNil(model.workspace.reconnect, "a fresh manual session has no episode to wait on")
        model.workspace.lifecycleIfRunning?.noteTransportFatal(serial: serial)
        XCTAssertNotNil(model.workspace.reconnect, "the episode is under way, so the panel holds the stage")

        // The default policy arms attempt 1 after 500 ms.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !(model.workspace.lifecycleIfRunning?.isAutoReconnectArmed(serial: serial) ?? false) {
            // Best effort: a sleep only fails on cancellation; the loop re-checks the deadline.
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(
            model.workspace.lifecycleIfRunning?.isAutoReconnectArmed(serial: serial) ?? false,
            "the attempt never armed"
        )

        model.workspace.lifecycleIfRunning?.noteMirrorStarted(serial: serial)
        XCTAssertEqual(
            model.workspace.reconnect,
            ReconnectStatus(serial: serial, isArmed: true, attempt: 1),
            "the attempt window must NOT vacate the stage — it narrates attempt 1 instead"
        )

        // Round 2 grace: one clean poll with no frames is not proof — a
        // stalled stream keeps the panel narrating the attempt.
        model.workspace.mirror.noteCleanStatsPoll(
            serial: serial,
            stats: MirrorStats(fps: 0, totalFrames: 0, dropped: 0, averageLatencyMs: 0)
        )
        XCTAssertNotNil(
            model.workspace.reconnect,
            "a frameless poll must NOT vacate the panel over a stalled stream"
        )
        // First frames: the stream is actually delivering, so the panel
        // vacates within a single poll (~500 ms, the ≤3 s expectation).
        model.workspace.mirror.noteCleanStatsPoll(
            serial: serial,
            stats: MirrorStats(fps: 60, totalFrames: 17, dropped: 0, averageLatencyMs: 8)
        )
        XCTAssertTrue(model.workspace.mirror.healthGate.reported, "frame evidence ends the episode")
        XCTAssertNil(model.workspace.reconnect, "frames are flowing: the panel vacates (≤1 poll)")
    }

    /// The round-2 grace rule on its own: frame delivery proves the resumed
    /// stream immediately (≤1 poll), and a transport reporting no frames
    /// falls back to 2 consecutive clean polls (~1 s) — never the old 6
    /// (~3 s), which covered an already-live mirror with the panel.
    func testHealthSignalIsFrameDeliveryOrTwoCleanPolls() {
        let delivering = MirrorStats(fps: 60, totalFrames: 17, dropped: 0, averageLatencyMs: 8)
        let silent = MirrorStats(fps: 0, totalFrames: 0, dropped: 0, averageLatencyMs: 0)

        XCTAssertTrue(
            MirrorHealthGate.signalReached(stats: delivering, cleanPolls: 1),
            "frame evidence vacates the panel within one poll"
        )
        XCTAssertTrue(
            MirrorHealthGate.signalReached(stats: MirrorStats(fps: 60, totalFrames: 0, dropped: 0, averageLatencyMs: 0), cleanPolls: 1),
            "fps alone is frame evidence too"
        )
        XCTAssertFalse(
            MirrorHealthGate.signalReached(stats: silent, cleanPolls: 1),
            "one frameless clean poll keeps the panel"
        )
        XCTAssertTrue(
            MirrorHealthGate.signalReached(stats: silent, cleanPolls: 2),
            "the no-frame fallback is 2 consecutive clean polls (~1 s)"
        )
    }

    /// The panel's grace wiring, end to end: frameless polls accumulate the
    /// fallback, the first frame-bearing read fires exactly once, and a
    /// reported health stops the count for the rest of the session.
    func testCleanStatsPollReportsHealthOnFramesOrTheSecondPoll() {
        let silent = MirrorStats(fps: 0, totalFrames: 0, dropped: 0, averageLatencyMs: 0)
        let delivering = MirrorStats(fps: 60, totalFrames: 17, dropped: 0, averageLatencyMs: 8)

        let frameless = AppModel.testing()
        frameless.workspace.mirror.noteCleanStatsPoll(serial: "HT4CWJT01234", stats: silent)
        XCTAssertFalse(
            frameless.workspace.mirror.healthGate.reported,
            "the first frameless poll is only ~0.5 s: the panel holds"
        )
        frameless.workspace.mirror.noteCleanStatsPoll(serial: "HT4CWJT01234", stats: silent)
        XCTAssertTrue(
            frameless.workspace.mirror.healthGate.reported,
            "the second consecutive clean poll (~1 s) is the fallback"
        )
        let pollsAtReport = frameless.workspace.mirror.healthGate.cleanPolls
        frameless.workspace.mirror.noteCleanStatsPoll(serial: "HT4CWJT01234", stats: silent)
        XCTAssertEqual(
            frameless.workspace.mirror.healthGate.cleanPolls,
            pollsAtReport,
            "health reports once per physical session: the count stops there"
        )

        let frames = AppModel.testing()
        frames.workspace.mirror.noteCleanStatsPoll(serial: "HT4CWJT01234", stats: delivering)
        XCTAssertTrue(
            frames.workspace.mirror.healthGate.reported,
            "the first frame-bearing read fires immediately (≤1 poll)"
        )
    }

    /// The waiting panel's Reconnect: re-arms from the episode, resumes
    /// exactly once (cancelling the pending schedule), and — being user
    /// initiated — never marks the attempt as auto.
    func testManualReconnectResumesOnceAndStaysUnarmed() async {
        let (coordinator, recorder) = makeCoordinator()
        coordinator.noteMirrorStarted(serial: "HT4CWJT01234")
        coordinator.noteTransportFatal(serial: "HT4CWJT01234")
        coordinator.noteReconnectRequested(serial: "HT4CWJT01234")
        XCTAssertFalse(
            coordinator.isAutoReconnectArmed(serial: "HT4CWJT01234"),
            "a manual click keeps surfacing its failures"
        )
        XCTAssertEqual(
            recorder.states.last,
            .recovering(serial: "HT4CWJT01234", nextAttempt: 1, deviceBack: true),
            "the reset is observable in the reported state"
        )
        await waitUntil { !recorder.resumes.isEmpty }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(
            recorder.resumes,
            ["HT4CWJT01234"],
            "the manual resume supersedes the pending auto schedule"
        )
    }

    // MARK: Stale-effect guard (pure)

    func testShouldApplyLifecycleEffectMatrix() {
        XCTAssertTrue(DeviceLifecycleCoordinator.shouldApplyLifecycleEffect(
            isCancelled: false, isCurrentGeneration: true))
        XCTAssertFalse(DeviceLifecycleCoordinator.shouldApplyLifecycleEffect(
            isCancelled: true, isCurrentGeneration: true))
        XCTAssertFalse(DeviceLifecycleCoordinator.shouldApplyLifecycleEffect(
            isCancelled: false, isCurrentGeneration: false))
    }
}

/// Counts VM liveness probes across the coordinator's task.
private actor ProbeCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}
