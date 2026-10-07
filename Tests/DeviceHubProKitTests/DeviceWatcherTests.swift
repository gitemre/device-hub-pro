import Darwin
import XCTest
@testable import DeviceHubProKit

final class DeviceWatcherTests: XCTestCase {
    private func makeStubADB(_ script: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stub-adb-\(UUID().uuidString)")
        try "#!/bin/sh\n\(script)".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makeFixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Best effort: a leftover fixture directory must not fail the test.
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private static func readLines(_ url: URL) -> [String] {
        // Best effort: a missing log means no calls were made.
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .map(String.init)
    }

    /// Polls the fixture's pid file the way the fixtures write it (`$$`, no
    /// trailing newline).
    private static func waitForPID(_ pidFile: URL, timeout: TimeInterval = 3) async -> pid_t? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // Best effort: the fixture may not have written the pid yet, so a
            // read failure just means "poll again".
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            // Best effort: a sleep only fails on cancellation; the loop re-checks the deadline.
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private static func processIsAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    /// Collects the watcher's events until `done` accepts them or `timeout`
    /// elapses. The wait is raced against the deadline, so a stream that goes
    /// silent ends the collection instead of hanging the test (`for await`
    /// alone only re-checks a deadline when an event arrives).
    private static func collect(
        _ stream: AsyncStream<DeviceWatcherEvent>,
        timeout: Duration,
        until done: @escaping @Sendable ([DeviceWatcherEvent]) -> Bool = { _ in false }
    ) async -> [DeviceWatcherEvent] {
        let box = EventBox()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in stream where done(box.append(event)) {
                    return
                }
            }
            group.addTask {
                // Best effort: sleep only fails on cancellation (`done` won).
                try? await Task.sleep(for: timeout)
            }
            await group.next()
            group.cancelAll()
        }
        return box.events
    }

    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [DeviceWatcherEvent] = []

        /// Appends and returns everything collected so far.
        func append(_ event: DeviceWatcherEvent) -> [DeviceWatcherEvent] {
            lock.lock()
            defer { lock.unlock() }
            stored.append(event)
            return stored
        }

        var events: [DeviceWatcherEvent] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private static func snapshots(
        in events: [DeviceWatcherEvent],
        degraded wanted: Bool? = nil
    ) -> [[AndroidDevice]] {
        events.compactMap {
            guard case .snapshot(let devices, let degraded) = $0 else { return nil }
            if let wanted, wanted != degraded { return nil }
            return devices
        }
    }

    private static func restartAttempts(in events: [DeviceWatcherEvent]) -> [Int] {
        events.compactMap {
            guard case .health(.restarting(let attempt)) = $0 else { return nil }
            return attempt
        }
    }

    private static func sawDegraded(_ events: [DeviceWatcherEvent]) -> Bool {
        events.contains {
            if case .health(.degraded) = $0 { return true }
            return false
        }
    }

    /// One adb host-protocol frame as the real `track-devices` writes it: four
    /// hex digits of payload length, then the payload — no header line and no
    /// blank terminator (platform-tools 37.0.0 writes `0000` for no devices).
    private static func frame(_ payload: String) -> String {
        String(format: "%04x", payload.utf8.count) + payload
    }

    /// A shell `printf` writing `frames` verbatim: single-quoted, so the tabs
    /// and newlines inside the payloads survive.
    private static func printFrames(_ frames: String...) -> String {
        let text = frames.joined().replacingOccurrences(of: "'", with: "'\\''")
        return "printf '%s' '\(text)'"
    }

    /// A `track-devices -l` row, formatted the way adb formats `devices -l`.
    private static let emulatorRow =
        "emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64 device:emu64a transport_id:1\n"

    // MARK: Restart policy (pure)

    func testRestartPolicyCapsAtLastDelay() {
        let policy = DeviceWatcherRestartPolicy(
            delays: [.milliseconds(500), .seconds(1), .seconds(2), .seconds(5)],
            degradedAfterFailures: 10
        )
        XCTAssertEqual(policy.delay(afterFailures: 1), .milliseconds(500))
        XCTAssertEqual(policy.delay(afterFailures: 4), .seconds(5))
        XCTAssertEqual(policy.delay(afterFailures: 9), .seconds(5))
        XCTAssertFalse(policy.shouldDegrade(afterFailures: 9))
    }

    func testRestartPolicyDegradesAfterConsecutiveFailures() {
        let policy = DeviceWatcherRestartPolicy(degradedAfterFailures: 3)
        XCTAssertFalse(policy.shouldDegrade(afterFailures: 2))
        XCTAssertTrue(policy.shouldDegrade(afterFailures: 3))
    }

    // MARK: Transport (stub adb)

    func testRestartsTrackDevicesAfterExitAndEmitsDetailedSnapshots() async throws {
        let directory = try makeFixtureDirectory()
        let log = directory.appendingPathComponent("calls.log")
        let adb = try makeStubADB("""
        printf '%s\\n' "$*" >> "\(log.path)"
        case "$1" in
          track-devices)
            \(Self.printFrames(Self.frame(Self.emulatorRow)))
            exit 0 ;;
        esac
        exit 1
        """)
        let watcher = DeviceWatcher(
            adbURL: adb,
            restartPolicy: .init(delays: [.milliseconds(5)], degradedAfterFailures: 100),
            debounce: .milliseconds(20)
        )
        let stream = watcher.events()
        watcher.start()
        defer { watcher.stop() }

        let events = await Self.collect(stream, timeout: .seconds(5)) { events in
            Self.snapshots(in: events).count >= 2 && !Self.restartAttempts(in: events).isEmpty
        }
        let snapshots = Self.snapshots(in: events)
        XCTAssertGreaterThanOrEqual(snapshots.count, 2, "each restarted run emits a fresh snapshot")
        XCTAssertFalse(Self.restartAttempts(in: events).isEmpty, "an exiting track-devices is restarted")
        XCTAssertFalse(Self.sawDegraded(events), "must not degrade with a working stub")
        XCTAssertTrue(Self.snapshots(in: events, degraded: true).isEmpty)
        for devices in snapshots {
            XCTAssertEqual(devices.map(\.serial), ["emulator-5554"])
            // The -l frame itself carries the details.
            XCTAssertEqual(devices.first?.model, "sdk_gphone64")
            XCTAssertEqual(devices.first?.transportID, "1")
        }
        let calls = Self.readLines(log)
        XCTAssertFalse(calls.isEmpty)
        XCTAssertTrue(
            calls.allSatisfy { $0 == "track-devices -l" },
            "details come from the -l frames; no `devices -l` read per emission: \(calls)"
        )
    }

    /// Real adb writes frames back to back with no blank line between them;
    /// the first frame here is the empty list (`0000`), the second adds a
    /// device — inside one debounce window, so only the newest list leaves.
    func testBurstCoalescesIntoOneSnapshotAndTheLastFrameWins() async throws {
        let adb = try makeStubADB("""
        case "$1" in
          track-devices)
            \(Self.printFrames(Self.frame(""), Self.frame("HT4CWJT01234\tdevice\n")))
            exec sleep 30 ;;
        esac
        exit 1
        """)
        let watcher = DeviceWatcher(
            adbURL: adb,
            restartPolicy: .init(delays: [.seconds(5)], degradedAfterFailures: 100),
            debounce: .milliseconds(300)
        )
        let stream = watcher.events()
        watcher.start()
        defer { watcher.stop() }

        // The stub holds the stream open (`exec sleep 30`) and the restart
        // delay is 5 s, so nothing else can emit inside this window: it can
        // be long enough to absorb a slow spawn on a loaded machine and
        // still prove the burst coalesced. A 1 s window used to fail here
        // when the stub took most of it to start.
        let snapshots = Self.snapshots(in: await Self.collect(stream, timeout: .seconds(3)))
        XCTAssertEqual(snapshots.count, 1, "a burst coalesces into one emission")
        XCTAssertEqual(snapshots.first?.map(\.serial), ["HT4CWJT01234"], "the last frame wins")
        XCTAssertEqual(snapshots.first?.first?.state, "device")
    }

    /// An empty device list is a real frame (`0000`) and must be emitted as
    /// an empty snapshot — the "phone unplugged" edge the lifecycle needs.
    func testEmptyFrameEmitsAnEmptySnapshot() async throws {
        let adb = try makeStubADB("""
        case "$1" in
          track-devices)
            \(Self.printFrames(Self.frame("")))
            exec sleep 30 ;;
        esac
        exit 1
        """)
        let watcher = DeviceWatcher(
            adbURL: adb,
            restartPolicy: .init(delays: [.seconds(5)], degradedAfterFailures: 100),
            debounce: .milliseconds(20)
        )
        let stream = watcher.events()
        watcher.start()
        defer { watcher.stop() }

        let events = await Self.collect(stream, timeout: .seconds(3)) { events in
            !Self.snapshots(in: events).isEmpty
        }
        XCTAssertEqual(Self.snapshots(in: events).first, [])
    }

    /// The format the watcher used to expect — a `List of devices attached`
    /// header and a blank line — is not adb framing: the run is dropped at
    /// once instead of parsing `List` as a frame length.
    func testUnframedOutputEndsTheRunWithoutASnapshot() async throws {
        let adb = try makeStubADB("""
        case "$1" in
          track-devices)
            printf 'List of devices attached\\nemulator-5554\\tdevice\\n\\n'
            # exec: one process, like the real adb client, so terminating it
            # closes the pipe (a forked `sleep` would hold it open).
            exec sleep 5 ;;
        esac
        exit 1
        """)
        let watcher = DeviceWatcher(
            adbURL: adb,
            restartPolicy: .init(delays: [.seconds(5)], degradedAfterFailures: 100),
            debounce: .milliseconds(20)
        )
        let stream = watcher.events()
        watcher.start()
        defer { watcher.stop() }

        let started = Date()
        let events = await Self.collect(stream, timeout: .seconds(4)) { events in
            !Self.restartAttempts(in: events).isEmpty
        }
        XCTAssertTrue(Self.snapshots(in: events).isEmpty, "unframed output must not become a snapshot")
        XCTAssertEqual(Self.restartAttempts(in: events), [1])
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            4,
            "the undecodable child is stopped at once, not after its 5 s sleep"
        )
    }

    /// A child that never writes a frame (a wedged adb server) must not keep
    /// the watcher silent forever: the first-frame watchdog stops it and the
    /// failure is reported like any other failed start.
    func testSilentTrackDevicesIsStoppedByTheFirstFrameWatchdog() async throws {
        let adb = try makeStubADB("""
        case "$1" in
          track-devices) exec sleep 30 ;;
        esac
        exit 1
        """)
        let watcher = DeviceWatcher(
            adbURL: adb,
            restartPolicy: .init(delays: [.seconds(5)], degradedAfterFailures: 100),
            firstFrameTimeout: .milliseconds(200)
        )
        let stream = watcher.events()
        watcher.start()
        defer { watcher.stop() }

        let started = Date()
        let events = await Self.collect(stream, timeout: .seconds(5)) { events in
            !Self.restartAttempts(in: events).isEmpty
        }
        XCTAssertEqual(Self.restartAttempts(in: events), [1], "a silent child is a failed start")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testDegradesToPollingWhenTrackDevicesCannotStart() async throws {
        let adb = try makeStubADB("""
        case "$1" in
          devices)
            printf 'List of devices attached\\nemulator-5554 device product:sdk model:sdk_gphone64 device:emu64 transport_id:3\\n'
            exit 0 ;;
        esac
        exit 1
        """)
        let watcher = DeviceWatcher(
            adbURL: adb,
            restartPolicy: .init(delays: [.milliseconds(5)], degradedAfterFailures: 1),
            pollInterval: .milliseconds(50)
        )
        let stream = watcher.events()
        watcher.start()
        defer { watcher.stop() }

        let events = await Self.collect(stream, timeout: .seconds(5)) { events in
            Self.sawDegraded(events) && !Self.snapshots(in: events, degraded: true).isEmpty
        }
        let degradedSnapshot = Self.snapshots(in: events, degraded: true).first
        XCTAssertTrue(Self.sawDegraded(events))
        XCTAssertEqual(
            degradedSnapshot?.map(\.serial),
            ["emulator-5554"],
            "the polling fallback emits tagged snapshots"
        )
        XCTAssertEqual(degradedSnapshot?.first?.model, "sdk_gphone64")
    }

    /// A failed `devices -l` poll (daemon restarting, "cannot connect",
    /// timeout) is "no answer", never "no devices": an empty snapshot would
    /// tear every session down and ghost every physical row.
    func testFailedPollsEmitNoSnapshot() async throws {
        let adb = try makeStubADB("""
        case "$1" in
          devices)
            printf 'List of devices attached\\n'
            printf 'error: cannot connect to daemon\\n' >&2
            exit 1 ;;
        esac
        exit 1
        """)
        let watcher = DeviceWatcher(
            adbURL: adb,
            restartPolicy: .init(delays: [.milliseconds(5)], degradedAfterFailures: 1),
            pollInterval: .milliseconds(20)
        )
        let stream = watcher.events()
        watcher.start()
        defer { watcher.stop() }

        let events = await Self.collect(stream, timeout: .milliseconds(800))
        XCTAssertTrue(Self.sawDegraded(events))
        XCTAssertTrue(Self.snapshots(in: events).isEmpty, "a failed poll must not emit a snapshot")
    }

    /// Polling is a fallback, not a one-way door: once `track-devices` works
    /// again the watcher is back on live, non-degraded snapshots.
    func testDegradedModeRetriesTrackDevicesAndRecovers() async throws {
        let directory = try makeFixtureDirectory()
        let attempts = directory.appendingPathComponent("attempts")
        let adb = try makeStubADB("""
        case "$1" in
          track-devices)
            printf 'x' >> "\(attempts.path)"
            if [ "$(wc -c < "\(attempts.path)" | tr -d ' ')" -le 2 ]; then exit 1; fi
            \(Self.printFrames(Self.frame(Self.emulatorRow)))
            exec sleep 30 ;;
          devices)
            printf 'List of devices attached\\n'
            exit 0 ;;
        esac
        exit 1
        """)
        let watcher = DeviceWatcher(
            adbURL: adb,
            restartPolicy: .init(
                delays: [.milliseconds(5)],
                degradedAfterFailures: 2,
                degradedRetryInterval: .milliseconds(150)
            ),
            debounce: .milliseconds(20),
            pollInterval: .milliseconds(30)
        )
        let stream = watcher.events()
        watcher.start()
        defer { watcher.stop() }

        let events = await Self.collect(stream, timeout: .seconds(5)) { events in
            !Self.snapshots(in: events, degraded: false).isEmpty
        }
        XCTAssertTrue(Self.sawDegraded(events))
        XCTAssertEqual(
            Self.snapshots(in: events, degraded: false).first?.map(\.serial),
            ["emulator-5554"],
            "a recovered track-devices ends degraded mode"
        )
    }

    /// Polling pauses while a degraded-mode retry of `track-devices` waits
    /// for its first frame. A retry that hangs (a wedged server) must give up
    /// after the short `degradedFirstFrameTimeout`, not the full
    /// `firstFrameTimeout`, or every retry blacks out device updates for
    /// that long.
    func testAHungRetryFromDegradedModeGivesUpQuicklyAndPollingResumes() async throws {
        let directory = try makeFixtureDirectory()
        let calls = directory.appendingPathComponent("calls")
        let adb = try makeStubADB("""
        case "$1" in
          track-devices)
            printf 'track\\n' >> "\(calls.path)"
            if [ "$(grep -c track "\(calls.path)")" -le 1 ]; then exit 1; fi
            exec sleep 30 ;;
          devices)
            printf 'devices\\n' >> "\(calls.path)"
            printf 'List of devices attached\\n'
            exit 0 ;;
        esac
        exit 1
        """)
        let watcher = DeviceWatcher(
            adbURL: adb,
            restartPolicy: .init(
                delays: [.milliseconds(5)],
                degradedAfterFailures: 1,
                degradedRetryInterval: .milliseconds(150)
            ),
            pollInterval: .milliseconds(30),
            firstFrameTimeout: .seconds(30),
            degradedFirstFrameTimeout: .milliseconds(200)
        )
        let stream = watcher.events()
        watcher.start()
        defer { watcher.stop() }

        let events = await Self.collect(stream, timeout: .seconds(3)) { _ in
            Self.readLines(calls).filter { $0 == "track" }.count >= 3
        }
        watcher.stop()

        XCTAssertTrue(Self.sawDegraded(events))
        let log = Self.readLines(calls)
        let tracks = log.indices.filter { log[$0] == "track" }
        XCTAssertGreaterThanOrEqual(tracks.count, 3, "the hung retry gave up and the next one ran: \(log)")
        if tracks.count >= 3 {
            XCTAssertTrue(
                log[tracks[1]..<tracks[2]].contains("devices"),
                "polling resumed between the hung retry and the next one: \(log)"
            )
        }
    }

    // MARK: Quit hygiene (S1)

    /// The `track-devices` child must not outlive its watcher: an app that
    /// quits through `stop()` would otherwise orphan a process that keeps
    /// streaming adb (S1). The fixture reports its own pid, writes one frame
    /// and then `exec`s into `sleep`, so one pid covers the whole child
    /// lifetime.
    func testStopTerminatesTheTrackDevicesChild() async throws {
        let directory = try makeFixtureDirectory()
        let pidFile = directory.appendingPathComponent("pid")
        let adb = try makeStubADB("""
        case "$1" in
          track-devices)
            printf '%s' "$$" > "\(pidFile.path)"
            \(Self.printFrames(Self.frame("")))
            exec sleep 60 ;;
        esac
        exit 1
        """)
        let watcher = DeviceWatcher(
            adbURL: adb,
            restartPolicy: .init(delays: [.milliseconds(50)], degradedAfterFailures: 100)
        )
        watcher.start()

        guard let pid = await Self.waitForPID(pidFile) else {
            watcher.stop()
            return XCTFail("the fixture never reported its track-devices pid")
        }
        // Whatever the assertions conclude, this test leaves no stray sleep.
        addTeardownBlock { if Self.processIsAlive(pid) { kill(pid, SIGKILL) } }
        XCTAssertTrue(Self.processIsAlive(pid), "the child must be running before stop()")

        watcher.stop()

        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline, Self.processIsAlive(pid) {
            // Best effort: a sleep only fails on cancellation; the loop re-checks the deadline.
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(
            Self.processIsAlive(pid),
            "stop() must take the track-devices child with it, or quitting the app orphans it (S1)"
        )
    }

    // MARK: Consumer cancellation

    /// The stream's `onTermination` calls `stop()` inside the consumer's
    /// cancellation, with the consumer's status-record lock held, and an
    /// emission's `yield` needs that lock to resume the consumer. A `yield`
    /// made under the lock `stop()` takes made each wait for the other: a
    /// full `swift test` run hung in `DeviceLifecycleCoordinator.stop()`
    /// (from `testArmedResumeRecordsAFailureTheAlertAlreadyShows`), whose
    /// teardown cancelled the consumer as the watcher reported a restart.
    func testStopReturnsWhileAYieldIsStalledOnTheConsumer() throws {
        let directory = try makeFixtureDirectory()
        let invoked = directory.appendingPathComponent("invoked")
        // One failed start: one `.restarting(attempt: 1)`, then a long wait.
        let adb = try makeStubADB("""
        : > "\(invoked.path)"
        exit 1
        """)
        let watcher = DeviceWatcher(
            adbURL: adb,
            restartPolicy: .init(delays: [.seconds(60)], degradedAfterFailures: 100)
        )
        defer { watcher.stop() }

        let returned = StalledYieldProbe.stopReturnsWhileAYieldIsStalled(
            consuming: watcher.events(),
            emit: {
                watcher.start()
                // The emission follows the stub's exit within milliseconds.
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline, !FileManager.default.fileExists(atPath: invoked.path) {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            },
            stop: { watcher.stop() }
        )
        XCTAssertTrue(
            returned,
            "stop() waited for a yield stalled on the consumer: a cancelled consumer deadlocks in onTermination"
        )
    }
}
