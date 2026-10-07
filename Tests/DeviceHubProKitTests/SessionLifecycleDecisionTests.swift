import XCTest
@testable import DeviceHubProKit

final class SessionLifecycleDecisionTests: XCTestCase {
    private let phone = AndroidDevice(serial: "HT4CWJT01234", state: "device")
    private let emulator = AndroidDevice(serial: "emulator-5554", state: "device")

    private func mirroring(_ serial: String) -> SessionLifecycle {
        var lifecycle = SessionLifecycle()
        lifecycle.handle(.mirrorStarted(serial: serial))
        return lifecycle
    }

    func testPhysicalDisconnectTearsDownKeepsGhostAndArms() {
        var lifecycle = mirroring("HT4CWJT01234")
        let actions = lifecycle.handle(.devicesChanged([]))
        XCTAssertEqual(actions, [
            .teardown(.disconnected),
            .setGhost("HT4CWJT01234"),
            .showStatus(.unreachable)
        ])
        XCTAssertEqual(lifecycle.state, .recovering(serial: "HT4CWJT01234", nextAttempt: 1, deviceBack: false))
    }

    /// An emulator mirror runs over gRPC, so adb losing the emulator (an adb
    /// server restart, `adb root`) is not a teardown by itself (F6): it arms
    /// one liveness check. Only a VM that is really gone tears down — then
    /// without resume, as before.
    func testEmulatorDisconnectChecksTheVMThenTearsDownWithoutResume() {
        var lifecycle = mirroring("emulator-5554")
        let actions = lifecycle.handle(.devicesChanged([]))
        XCTAssertEqual(actions, [.checkEmulatorLiveness(serial: "emulator-5554", after: .seconds(5))])
        XCTAssertEqual(lifecycle.state, .mirroring(serial: "emulator-5554"), "the healthy gRPC mirror stays")
        XCTAssertTrue(lifecycle.handle(.devicesChanged([])).isEmpty, "one check per absence")

        let teardown = lifecycle.handle(.emulatorLivenessChecked(serial: "emulator-5554", vmRunning: false))
        XCTAssertEqual(teardown, [.teardown(.disconnected)])
        XCTAssertEqual(lifecycle.state, .idle)
    }

    func testOfflineEmulatorIsCheckedNotTornDown() {
        var lifecycle = mirroring("emulator-5554")
        let actions = lifecycle.handle(.devicesChanged([AndroidDevice(serial: "emulator-5554", state: "offline")]))
        XCTAssertEqual(actions, [.checkEmulatorLiveness(serial: "emulator-5554", after: .seconds(5))])
        XCTAssertEqual(lifecycle.state, .mirroring(serial: "emulator-5554"))
    }

    /// adb listing the emulator online again disarms the pending check: its
    /// late answer is stale and changes nothing.
    func testEmulatorBackOnlineDisarmsTheLivenessCheck() {
        var lifecycle = mirroring("emulator-5554")
        lifecycle.handle(.devicesChanged([]))
        XCTAssertTrue(lifecycle.handle(.devicesChanged([emulator])).isEmpty)
        XCTAssertTrue(
            lifecycle.handle(.emulatorLivenessChecked(serial: "emulator-5554", vmRunning: false)).isEmpty
        )
        XCTAssertEqual(lifecycle.state, .mirroring(serial: "emulator-5554"))
        // A later absence arms a fresh check.
        XCTAssertEqual(
            lifecycle.handle(.devicesChanged([])),
            [.checkEmulatorLiveness(serial: "emulator-5554", after: .seconds(5))]
        )
    }

    /// A running VM keeps its mirror (a guest reboot keeps adb away for a
    /// while) and is checked again, because a VM that dies while adb stays
    /// quiet produces no further snapshot.
    func testLiveEmulatorVMKeepsTheMirrorAndIsCheckedAgain() {
        var lifecycle = mirroring("emulator-5554")
        lifecycle.handle(.devicesChanged([]))
        let alive = lifecycle.handle(.emulatorLivenessChecked(serial: "emulator-5554", vmRunning: true))
        XCTAssertEqual(alive, [.checkEmulatorLiveness(serial: "emulator-5554", after: .seconds(5))])
        XCTAssertEqual(lifecycle.state, .mirroring(serial: "emulator-5554"))
        let gone = lifecycle.handle(.emulatorLivenessChecked(serial: "emulator-5554", vmRunning: false))
        XCTAssertEqual(gone, [.teardown(.disconnected)])
    }

    func testEmulatorAbsenceGraceComesFromThePolicy() {
        var lifecycle = SessionLifecycle(policy: ReconnectPolicy(emulatorAbsenceGrace: .seconds(9)))
        lifecycle.handle(.mirrorStarted(serial: "emulator-5554"))
        XCTAssertEqual(
            lifecycle.handle(.devicesChanged([])),
            [.checkEmulatorLiveness(serial: "emulator-5554", after: .seconds(9))]
        )
    }

    // MARK: User-initiated stop (F7)

    /// Stop Mirror ends the session for good: a later unplug/replug of the
    /// still-selected phone must not ghost it, show the panel or resume the
    /// mirror the user stopped.
    func testUserStopEndsTheSessionSoAReplugNeverResumes() {
        var lifecycle = mirroring("HT4CWJT01234")
        XCTAssertEqual(lifecycle.handle(.mirrorStopped(serial: "HT4CWJT01234")), [.setGhost(nil)])
        XCTAssertEqual(lifecycle.state, .idle)
        XCTAssertTrue(lifecycle.handle(.devicesChanged([])).isEmpty, "no teardown, ghost or panel")
        XCTAssertTrue(lifecycle.handle(.devicesChanged([phone])).isEmpty, "no resume")
        XCTAssertEqual(lifecycle.state, .idle)
    }

    /// Stopping while the waiting panel holds the stage drops the ghost and
    /// the armed schedule too.
    func testUserStopDuringRecoveryDropsTheEpisode() {
        var lifecycle = mirroring("HT4CWJT01234")
        lifecycle.handle(.transportFatal(serial: "HT4CWJT01234"))
        lifecycle.handle(.resumeTimerFired(serial: "HT4CWJT01234", attempt: 1))
        XCTAssertTrue(lifecycle.isAutoReconnectArmed(serial: "HT4CWJT01234"))
        XCTAssertEqual(lifecycle.handle(.mirrorStopped(serial: "HT4CWJT01234")), [.setGhost(nil)])
        XCTAssertEqual(lifecycle.state, .idle)
        XCTAssertFalse(lifecycle.isAutoReconnectArmed(serial: "HT4CWJT01234"))
        XCTAssertTrue(lifecycle.handle(.resumeTimerFired(serial: "HT4CWJT01234", attempt: 2)).isEmpty)
    }

    func testUserStopOfAnotherSerialIsIgnored() {
        var lifecycle = mirroring("HT4CWJT01234")
        XCTAssertTrue(lifecycle.handle(.mirrorStopped(serial: "emulator-5554")).isEmpty)
        XCTAssertEqual(lifecycle.state, .mirroring(serial: "HT4CWJT01234"))
        var idle = SessionLifecycle()
        XCTAssertTrue(idle.handle(.mirrorStopped(serial: "HT4CWJT01234")).isEmpty)
    }

    func testUserStopClearsAPendingEmulatorCheck() {
        var lifecycle = mirroring("emulator-5554")
        lifecycle.handle(.devicesChanged([]))
        lifecycle.handle(.mirrorStopped(serial: "emulator-5554"))
        XCTAssertTrue(
            lifecycle.handle(.emulatorLivenessChecked(serial: "emulator-5554", vmRunning: false)).isEmpty,
            "the stopped session has nothing left to tear down"
        )
    }

    // MARK: A session off adb (iOS design R1)

    /// An Apple session replacing a phone's ends the phone's episode, into
    /// `.idle`: the phone's later unplug is no teardown, ghost or panel (it
    /// would tear the Apple session down), and its replug resumes nothing.
    func testANonAdbSessionEndsThePhoneSessionItReplaced() {
        var lifecycle = mirroring("HT4CWJT01234")
        XCTAssertEqual(lifecycle.handle(.nonAdbMirrorStarted), [.setGhost(nil)])
        XCTAssertEqual(lifecycle.state, .idle)
        XCTAssertTrue(lifecycle.handle(.devicesChanged([])).isEmpty, "no teardown, ghost or panel")
        XCTAssertTrue(lifecycle.handle(.devicesChanged([phone])).isEmpty, "no resume")
        XCTAssertEqual(lifecycle.state, .idle)
    }

    /// The emulator variant: no liveness check is armed for the replaced
    /// emulator, and a check already pending finds nothing to tear down
    /// when its VM is gone (the user stopped the AVD).
    func testANonAdbSessionEndsTheEmulatorSessionItReplaced() {
        var replaced = mirroring("emulator-5554")
        replaced.handle(.nonAdbMirrorStarted)
        XCTAssertTrue(replaced.handle(.devicesChanged([])).isEmpty, "no liveness check")

        var pending = mirroring("emulator-5554")
        XCTAssertEqual(
            pending.handle(.devicesChanged([])),
            [.checkEmulatorLiveness(serial: "emulator-5554", after: .seconds(5))]
        )
        XCTAssertEqual(pending.handle(.nonAdbMirrorStarted), [.setGhost(nil)])
        XCTAssertTrue(
            pending.handle(.emulatorLivenessChecked(serial: "emulator-5554", vmRunning: false)).isEmpty,
            "the replaced session has nothing left to tear down"
        )
        XCTAssertEqual(pending.state, .idle)
    }

    /// An episode under way ends too, as another serial's start ends it:
    /// the ghost drops and the armed attempt no longer resumes.
    func testANonAdbSessionEndsAnEpisodeUnderWay() {
        var lifecycle = mirroring("HT4CWJT01234")
        lifecycle.handle(.transportFatal(serial: "HT4CWJT01234"))
        XCTAssertEqual(lifecycle.handle(.nonAdbMirrorStarted), [.setGhost(nil)])
        XCTAssertEqual(lifecycle.state, .idle)
        XCTAssertTrue(lifecycle.handle(.resumeTimerFired(serial: "HT4CWJT01234", attempt: 1)).isEmpty)
        XCTAssertFalse(lifecycle.isAutoReconnectArmed(serial: "HT4CWJT01234"))
    }

    /// From idle there is nothing to end, so nothing is emitted.
    func testANonAdbSessionFromIdleEmitsNothing() {
        var lifecycle = SessionLifecycle()
        XCTAssertTrue(lifecycle.handle(.nonAdbMirrorStarted).isEmpty)
        XCTAssertEqual(lifecycle.state, .idle)
    }

    // MARK: Reconnect while the device is away (F8)

    /// Reconnect pressed before the phone is plugged back in must not burn
    /// the attempts against an absent device: it re-arms from attempt 1 and
    /// waits for the return edge, which schedules the resume as usual.
    func testReconnectWhileTheDeviceIsAwayWaitsForItsReturn() {
        var lifecycle = mirroring("HT4CWJT01234")
        lifecycle.handle(.devicesChanged([]))
        XCTAssertTrue(lifecycle.handle(.reconnectRequested(serial: "HT4CWJT01234")).isEmpty)
        XCTAssertEqual(
            lifecycle.state,
            .recovering(serial: "HT4CWJT01234", nextAttempt: 1, deviceBack: false)
        )
        XCTAssertEqual(
            lifecycle.handle(.devicesChanged([phone])),
            [.scheduleResume(serial: "HT4CWJT01234", after: .milliseconds(500), attempt: 1)]
        )
    }

    /// From the exhausted state (which ignores snapshots) a Reconnect while
    /// the phone is away turns auto-resume back on instead of off.
    func testReconnectFromTheExhaustedStateWhileAwayReArmsAutoResume() {
        var lifecycle = mirroring("HT4CWJT01234")
        lifecycle.handle(.devicesChanged([]))
        lifecycle.handle(.devicesChanged([phone]))
        lifecycle.handle(.resumeTimerFired(serial: "HT4CWJT01234", attempt: 1))
        for _ in 0..<5 {
            lifecycle.handle(.resumeFailed(serial: "HT4CWJT01234"))
        }
        XCTAssertEqual(lifecycle.state, .ghostSelected(serial: "HT4CWJT01234"))
        lifecycle.handle(.devicesChanged([]))

        XCTAssertTrue(lifecycle.handle(.reconnectRequested(serial: "HT4CWJT01234")).isEmpty)
        XCTAssertEqual(
            lifecycle.state,
            .recovering(serial: "HT4CWJT01234", nextAttempt: 1, deviceBack: false)
        )
        XCTAssertEqual(
            lifecycle.handle(.devicesChanged([phone])),
            [.scheduleResume(serial: "HT4CWJT01234", after: .milliseconds(500), attempt: 1)]
        )
    }

    /// With the phone present, Reconnect still resumes at once.
    func testReconnectWithTheDevicePresentResumesImmediately() {
        var lifecycle = mirroring("HT4CWJT01234")
        lifecycle.handle(.devicesChanged([]))
        lifecycle.handle(.devicesChanged([phone]))
        lifecycle.handle(.resumeTimerFired(serial: "HT4CWJT01234", attempt: 1))
        for _ in 0..<5 {
            lifecycle.handle(.resumeFailed(serial: "HT4CWJT01234"))
        }
        XCTAssertEqual(
            lifecycle.handle(.reconnectRequested(serial: "HT4CWJT01234")),
            [.resume(serial: "HT4CWJT01234")]
        )
        XCTAssertEqual(
            lifecycle.state,
            .recovering(serial: "HT4CWJT01234", nextAttempt: 1, deviceBack: true)
        )
    }

    func testUnauthorizedDisconnectShowsUnauthorizedPanel() {
        var lifecycle = mirroring("HT4CWJT01234")
        let actions = lifecycle.handle(.devicesChanged([AndroidDevice(serial: "HT4CWJT01234", state: "unauthorized")]))
        XCTAssertEqual(actions, [
            .teardown(.unauthorizedPrompt),
            .setGhost("HT4CWJT01234"),
            .showStatus(.unauthorized)
        ])
    }

    func testReturnOnlineSchedulesFirstAttemptOnce() {
        var lifecycle = mirroring("HT4CWJT01234")
        lifecycle.handle(.devicesChanged([]))
        let actions = lifecycle.handle(.devicesChanged([phone]))
        XCTAssertEqual(actions, [.scheduleResume(serial: "HT4CWJT01234", after: .milliseconds(500), attempt: 1)])
        XCTAssertTrue(lifecycle.handle(.devicesChanged([phone])).isEmpty, "no double schedule while back")
        XCTAssertEqual(lifecycle.state, .recovering(serial: "HT4CWJT01234", nextAttempt: 2, deviceBack: true))
    }

    func testFlappingBackOfflineRearmsWaiting() {
        var lifecycle = mirroring("HT4CWJT01234")
        lifecycle.handle(.devicesChanged([]))
        lifecycle.handle(.devicesChanged([phone]))
        lifecycle.handle(.devicesChanged([]))
        XCTAssertEqual(lifecycle.state, .recovering(serial: "HT4CWJT01234", nextAttempt: 2, deviceBack: false))
        let actions = lifecycle.handle(.devicesChanged([phone]))
        XCTAssertEqual(actions, [.scheduleResume(serial: "HT4CWJT01234", after: .seconds(1), attempt: 2)])
    }

    func testTimerFiresResume() {
        var lifecycle = mirroring("HT4CWJT01234")
        lifecycle.handle(.devicesChanged([]))
        lifecycle.handle(.devicesChanged([phone]))
        let actions = lifecycle.handle(.resumeTimerFired(serial: "HT4CWJT01234", attempt: 1))
        XCTAssertEqual(actions, [.resume(serial: "HT4CWJT01234")])
    }

    func testTimerIgnoredAfterMirrorStarted() {
        var lifecycle = mirroring("HT4CWJT01234")
        lifecycle.handle(.devicesChanged([]))
        lifecycle.handle(.devicesChanged([phone]))
        lifecycle.handle(.mirrorStarted(serial: "HT4CWJT01234"))
        XCTAssertTrue(lifecycle.handle(.resumeTimerFired(serial: "HT4CWJT01234", attempt: 1)).isEmpty)
    }

    func testResumeFailedSchedulesNextAttempt() {
        var lifecycle = mirroring("HT4CWJT01234")
        lifecycle.handle(.devicesChanged([]))
        lifecycle.handle(.devicesChanged([phone]))
        let actions = lifecycle.handle(.resumeFailed(serial: "HT4CWJT01234"))
        XCTAssertEqual(actions, [.scheduleResume(serial: "HT4CWJT01234", after: .seconds(1), attempt: 2)])
        XCTAssertEqual(lifecycle.state, .recovering(serial: "HT4CWJT01234", nextAttempt: 3, deviceBack: true))
    }

    func testExhaustedAttemptsGoManual() {
        var lifecycle = mirroring("HT4CWJT01234")
        lifecycle.handle(.devicesChanged([]))
        lifecycle.handle(.devicesChanged([phone]))
        for _ in 0..<5 {
            lifecycle.handle(.resumeFailed(serial: "HT4CWJT01234"))
        }
        XCTAssertTrue(lifecycle.handle(.resumeFailed(serial: "HT4CWJT01234")).isEmpty)
        XCTAssertEqual(lifecycle.state, .ghostSelected(serial: "HT4CWJT01234"))
    }

    func testSelectionChangeDropsGhostAndIntent() {
        var lifecycle = mirroring("HT4CWJT01234")
        lifecycle.handle(.devicesChanged([]))
        let actions = lifecycle.handle(.selectionChanged(selectedSerial: "emulator-5554"))
        XCTAssertEqual(actions, [.setGhost(nil)])
        XCTAssertEqual(lifecycle.state, .idle)
    }

    func testSelectionChangeToSameSerialKeepsGhost() {
        var lifecycle = mirroring("HT4CWJT01234")
        lifecycle.handle(.devicesChanged([]))
        XCTAssertTrue(lifecycle.handle(.selectionChanged(selectedSerial: "HT4CWJT01234")).isEmpty)
        XCTAssertEqual(lifecycle.state, .recovering(serial: "HT4CWJT01234", nextAttempt: 1, deviceBack: false))
    }

    func testUserMirrorStartClearsGhost() {
        var lifecycle = mirroring("HT4CWJT01234")
        lifecycle.handle(.devicesChanged([]))
        let actions = lifecycle.handle(.mirrorStarted(serial: "emulator-5554"))
        XCTAssertEqual(actions, [.setGhost(nil)])
        XCTAssertEqual(lifecycle.state, .mirroring(serial: "emulator-5554"))
    }

    func testTransportFatalArmsPhysicalResume() {
        var lifecycle = mirroring("HT4CWJT01234")
        let actions = lifecycle.handle(.transportFatal(serial: "HT4CWJT01234"))
        XCTAssertEqual(actions, [
            .teardown(.transportFatal),
            .setGhost("HT4CWJT01234"),
            .showStatus(.unreachable),
            // Spec §5.2 amendment: armed immediately — adb still lists the
            // device, so no watcher edge would ever re-arm the schedule.
            .scheduleResume(serial: "HT4CWJT01234", after: .milliseconds(500), attempt: 1)
        ])
        XCTAssertEqual(
            lifecycle.state,
            .recovering(serial: "HT4CWJT01234", nextAttempt: 2, deviceBack: true),
            "the listed device counts as back; the schedule is armed for attempt 2"
        )
    }

    func testTransportFatalThenTrueVanishDisarmsToWaiting() {
        var lifecycle = mirroring("HT4CWJT01234")
        lifecycle.handle(.transportFatal(serial: "HT4CWJT01234"))
        XCTAssertTrue(lifecycle.handle(.devicesChanged([])).isEmpty, "the vanish only disarms")
        XCTAssertEqual(lifecycle.state, .recovering(serial: "HT4CWJT01234", nextAttempt: 2, deviceBack: false))
    }

    func testTransportFatalTimerFiresWithoutAnyWatcherEdge() {
        var lifecycle = mirroring("HT4CWJT01234")
        lifecycle.handle(.transportFatal(serial: "HT4CWJT01234"))
        XCTAssertEqual(
            lifecycle.handle(.resumeTimerFired(serial: "HT4CWJT01234", attempt: 1)),
            [.resume(serial: "HT4CWJT01234")],
            "the armed attempt fires with no devicesChanged edge in between"
        )
    }

    func testRepeatedAbsenceTearsDownOnce() {
        var lifecycle = mirroring("HT4CWJT01234")
        lifecycle.handle(.devicesChanged([]))
        XCTAssertTrue(lifecycle.handle(.devicesChanged([])).isEmpty, "second absence event is a no-op")
    }

    // MARK: Fatal-streak damping (S3)

    /// A stream that dies ~1 s after every start must not loop at stream
    /// lifetime: the second fatal carries the first one's attempt counter, so
    /// the backoff grows instead of re-arming attempt 1 every cycle.
    func testTransportFatalStreakCarriesAndBackoffGrows() {
        var lifecycle = mirroring("HT4CWJT01234")
        let first = lifecycle.handle(.transportFatal(serial: "HT4CWJT01234"))
        XCTAssertEqual(
            first.last,
            .scheduleResume(serial: "HT4CWJT01234", after: .milliseconds(500), attempt: 1)
        )
        // The auto-resume attempt runs (timer → resume → mirror start) and
        // the stream dies again.
        lifecycle.handle(.resumeTimerFired(serial: "HT4CWJT01234", attempt: 1))
        lifecycle.handle(.mirrorStarted(serial: "HT4CWJT01234"))
        let second = lifecycle.handle(.transportFatal(serial: "HT4CWJT01234"))
        XCTAssertEqual(
            second.last,
            .scheduleResume(serial: "HT4CWJT01234", after: .seconds(1), attempt: 2),
            "the streak carries across the auto-resume, so the delay grows"
        )
    }

    /// Past `policy.maxAttempts` the machine lands in `.ghostSelected`: the
    /// Rescan affordance (manual) takes over instead of looping forever.
    func testTransportFatalStreakExhaustsToManual() {
        var lifecycle = mirroring("HT4CWJT01234")
        var scheduled: [Int] = []
        for _ in 0..<5 {
            let fatal = lifecycle.handle(.transportFatal(serial: "HT4CWJT01234"))
            guard case .scheduleResume(_, _, let attempt) = fatal.last else {
                XCTFail("expected a scheduleResume, got \(fatal)")
                return
            }
            scheduled.append(attempt)
            lifecycle.handle(.resumeTimerFired(serial: "HT4CWJT01234", attempt: attempt))
            lifecycle.handle(.mirrorStarted(serial: "HT4CWJT01234"))
        }
        XCTAssertEqual(scheduled, [1, 2, 3, 4, 5])
        let sixth = lifecycle.handle(.transportFatal(serial: "HT4CWJT01234"))
        XCTAssertEqual(lifecycle.state, .ghostSelected(serial: "HT4CWJT01234"))
        XCTAssertFalse(
            sixth.contains { action in
                if case .scheduleResume = action { return true }
                return false
            },
            "attempt 6 is past the policy: no schedule, only the Rescan path"
        )
    }

    /// Decision-table row: exhaustion through `resumeFailed` must leave the
    /// same bookkeeping as exhaustion through `enterDisconnected` (S4/I3) —
    /// no armed cycle survives it, so a session started later is
    /// user-initiated and its next fatal starts back at attempt 1.
    func testResumeFailedExhaustionClearsTheMarkerAndStreak() {
        var lifecycle = SessionLifecycle(
            policy: ReconnectPolicy(delays: [.milliseconds(50)], maxAttempts: 2)
        )
        lifecycle.handle(.mirrorStarted(serial: "HT4CWJT01234"))
        lifecycle.handle(.transportFatal(serial: "HT4CWJT01234")) // streak 1
        lifecycle.handle(.resumeTimerFired(serial: "HT4CWJT01234", attempt: 1))
        XCTAssertTrue(lifecycle.isAutoReconnectArmed(serial: "HT4CWJT01234"))
        // Attempt 2 is still inside the policy, so this failure only reschedules.
        lifecycle.handle(.resumeFailed(serial: "HT4CWJT01234"))
        lifecycle.handle(.resumeTimerFired(serial: "HT4CWJT01234", attempt: 2))
        // Attempt 3 is past `maxAttempts: 2` — the machine gives up.
        let exhausted = lifecycle.handle(.resumeFailed(serial: "HT4CWJT01234"))
        XCTAssertTrue(exhausted.isEmpty, "exhaustion schedules nothing")
        XCTAssertEqual(lifecycle.state, .ghostSelected(serial: "HT4CWJT01234"))
        XCTAssertFalse(
            lifecycle.isAutoReconnectArmed(serial: "HT4CWJT01234"),
            "the episode's end must drop the armed marker"
        )

        // A session started later is user-initiated: fresh streak, attempt 1.
        lifecycle.handle(.mirrorStarted(serial: "HT4CWJT01234"))
        XCTAssertFalse(
            lifecycle.isAutoReconnectArmed(serial: "HT4CWJT01234"),
            "exhaustion ended the cycle; the marker must not outlive it"
        )
        let fatal = lifecycle.handle(.transportFatal(serial: "HT4CWJT01234"))
        XCTAssertEqual(
            fatal.last,
            .scheduleResume(serial: "HT4CWJT01234", after: .milliseconds(50), attempt: 1),
            "the streak was reset at exhaustion, so the next fatal starts at attempt 1"
        )
    }

    /// Decision-table row: the armed marker is false in EVERY window where
    /// the machine is not driving — including the `deviceBack: false` gap,
    /// where the schedule waits for the device instead of running an attempt
    /// (S4/I3 audit).
    func testDeviceAwayDropsTheArmedMarkerUntilItReturns() {
        var lifecycle = mirroring("HT4CWJT01234")
        lifecycle.handle(.transportFatal(serial: "HT4CWJT01234"))
        lifecycle.handle(.resumeTimerFired(serial: "HT4CWJT01234", attempt: 1))
        XCTAssertTrue(lifecycle.isAutoReconnectArmed(serial: "HT4CWJT01234"))
        lifecycle.handle(.devicesChanged([]))
        XCTAssertEqual(
            lifecycle.state,
            .recovering(serial: "HT4CWJT01234", nextAttempt: 2, deviceBack: false)
        )
        XCTAssertFalse(
            lifecycle.isAutoReconnectArmed(serial: "HT4CWJT01234"),
            "an away device has no running attempt, so no cycle is armed"
        )
        XCTAssertEqual(
            lifecycle.handle(.devicesChanged([phone])),
            [.scheduleResume(serial: "HT4CWJT01234", after: .seconds(1), attempt: 2)],
            "the return edge only re-schedules; arming still happens at the timer"
        )
        XCTAssertFalse(
            lifecycle.isAutoReconnectArmed(serial: "HT4CWJT01234"),
            "scheduling is not arming"
        )
    }

    /// The waiting panel holds the stage through the armed attempt window
    /// (S4), so its Reconnect button has to be live there: the click takes
    /// the machine's cycle over manually — marker cleared, failures surface
    /// again — while a stale click on a healthy session stays a no-op.
    func testReconnectRequestedDuringTheArmedAttemptTakesOver() {
        var lifecycle = mirroring("HT4CWJT01234")
        lifecycle.handle(.transportFatal(serial: "HT4CWJT01234"))
        lifecycle.handle(.resumeTimerFired(serial: "HT4CWJT01234", attempt: 1))
        lifecycle.handle(.mirrorStarted(serial: "HT4CWJT01234")) // the attempt's own start
        XCTAssertTrue(lifecycle.isAutoReconnectArmed(serial: "HT4CWJT01234"))
        XCTAssertEqual(
            lifecycle.handle(.reconnectRequested(serial: "HT4CWJT01234")),
            [.resume(serial: "HT4CWJT01234")]
        )
        XCTAssertFalse(
            lifecycle.isAutoReconnectArmed(serial: "HT4CWJT01234"),
            "the click is user-initiated, so its failures surface again"
        )
        XCTAssertEqual(
            lifecycle.state,
            .recovering(serial: "HT4CWJT01234", nextAttempt: 1, deviceBack: true),
            "the panel holds the stage across the manual restart"
        )

        var healthy = mirroring("HT4CWJT01234")
        XCTAssertTrue(
            healthy.handle(.reconnectRequested(serial: "HT4CWJT01234")).isEmpty,
            "a healthy session has no episode, so there is no button to press"
        )
    }

    /// Canonical streak rule, manual half: a session that starts OUTSIDE the
    /// current auto episode — here a start with no armed cycle in flight, the
    /// same serial included — begins a fresh one, so the streak resets and
    /// the next transport death schedules attempt 1 again. This is the Reconnect
    /// button's contract — a successful start earns a clean slate. The other
    /// half of the rule (the episode's own auto `mirrorStarted` keeps the
    /// streak) is pinned by `testTransportFatalStreakCarriesAndBackoffGrows`.
    func testMirrorStartedResetsTheStreak() {
        var lifecycle = mirroring("HT4CWJT01234")
        lifecycle.handle(.transportFatal(serial: "HT4CWJT01234")) // streak 1
        // The manual path (panel Reconnect → resume → mirror start): no
        // machine-driven resume is in flight, so the start is user-initiated.
        lifecycle.handle(.mirrorStarted(serial: "HT4CWJT01234"))
        let fatal = lifecycle.handle(.transportFatal(serial: "HT4CWJT01234"))
        XCTAssertEqual(
            fatal.last,
            .scheduleResume(serial: "HT4CWJT01234", after: .milliseconds(500), attempt: 1),
            "a fresh mirror start resets the streak to a clean attempt 1"
        )
    }

    /// The waiting panel's Reconnect: re-arms the machine from either episode
    /// state (recovering or exhausted) and runs the existing resume path.
    func testReconnectRequestedReArmsAndResets() {
        var lifecycle = mirroring("HT4CWJT01234")
        lifecycle.handle(.transportFatal(serial: "HT4CWJT01234"))
        lifecycle.handle(.resumeTimerFired(serial: "HT4CWJT01234", attempt: 1))
        lifecycle.handle(.mirrorStarted(serial: "HT4CWJT01234"))
        lifecycle.handle(.transportFatal(serial: "HT4CWJT01234")) // streak 2
        let actions = lifecycle.handle(.reconnectRequested(serial: "HT4CWJT01234"))
        XCTAssertEqual(actions, [.resume(serial: "HT4CWJT01234")])
        XCTAssertEqual(
            lifecycle.state,
            .recovering(serial: "HT4CWJT01234", nextAttempt: 1, deviceBack: true)
        )
        // The reset is observable: the next fatal starts back at attempt 1.
        lifecycle.handle(.mirrorStarted(serial: "HT4CWJT01234"))
        let fatal = lifecycle.handle(.transportFatal(serial: "HT4CWJT01234"))
        XCTAssertEqual(
            fatal.last,
            .scheduleResume(serial: "HT4CWJT01234", after: .milliseconds(500), attempt: 1)
        )
    }

    /// A session that proves healthy ends the reconnect episode: the streak
    /// (and the auto-resume marker that silences transport alerts) clear, so
    /// a much-later death starts a fresh episode instead of marching toward
    /// the attempt cap.
    func testMirrorHealthyEndsTheReconnectEpisode() {
        var lifecycle = mirroring("HT4CWJT01234")
        lifecycle.handle(.transportFatal(serial: "HT4CWJT01234"))
        lifecycle.handle(.resumeTimerFired(serial: "HT4CWJT01234", attempt: 1))
        XCTAssertTrue(lifecycle.isAutoReconnectArmed(serial: "HT4CWJT01234"))
        lifecycle.handle(.mirrorStarted(serial: "HT4CWJT01234"))
        XCTAssertTrue(lifecycle.isAutoReconnectArmed(serial: "HT4CWJT01234"))
        lifecycle.handle(.mirrorHealthy(serial: "HT4CWJT01234"))
        XCTAssertFalse(lifecycle.isAutoReconnectArmed(serial: "HT4CWJT01234"))
        let fatal = lifecycle.handle(.transportFatal(serial: "HT4CWJT01234"))
        XCTAssertEqual(
            fatal.last,
            .scheduleResume(serial: "HT4CWJT01234", after: .milliseconds(500), attempt: 1),
            "the healthy session ended the episode; the next death is attempt 1"
        )
    }
}

