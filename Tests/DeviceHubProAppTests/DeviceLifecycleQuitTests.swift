import AppKit
import Darwin
import XCTest
import DeviceHubProKit
@testable import DeviceHubProApp

/// Quit hygiene (S1): terminating the app must take the `adb track-devices`
/// child with it. `DeviceWatcher.stop()` already does that (pinned by
/// `DeviceWatcherTests.testStopTerminatesTheTrackDevicesChild`), so the
/// remaining question is whether the app ever *reaches* `stop()` when it
/// quits — that is what these tests exercise end to end.
private func quitFixturePID(_ pidFile: URL, timeout: TimeInterval = 3) async -> pid_t? {
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

/// File-level so the helpers stay nonisolated and usable from teardown blocks.
private func quitProcessIsAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0
}

@MainActor
final class DeviceLifecycleQuitTests: XCTestCase {
    private struct Fixture {
        let pidFile: URL
        let adbURL: URL
    }

    /// A stub adb whose `track-devices` reports its own pid and then `exec`s
    /// into `sleep`, so one pid covers the whole child lifetime.
    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceLifecycleQuitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Best effort: a leftover fixture directory must not fail the test.
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let pidFile = directory.appendingPathComponent("pid")
        let adbURL = directory.appendingPathComponent("stub-adb")
        let script = """
        #!/bin/sh
        case "$1" in
          track-devices)
            printf '%s' "$$" > "\(pidFile.path)"
            exec sleep 60 ;;
          devices)
            printf 'List of devices attached\\n'
            exit 0 ;;
        esac
        exit 0
        """
        try script.write(to: adbURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adbURL.path)
        return Fixture(pidFile: pidFile, adbURL: adbURL)
    }

    /// Starts the lifecycle and returns the running child's pid, registering
    /// the backstop that keeps a failing test from leaving an orphan.
    private func startLifecycleFixture() async throws -> (AppModel, pid_t) {
        let fixture = try makeFixture()
        let model = AppModel.testing(adb: AdbClient(adbURL: fixture.adbURL))
        model.inventory.startDeviceLifecycle()
        guard let pid = await quitFixturePID(fixture.pidFile) else {
            XCTFail("the watcher never spawned its track-devices child")
            return (model, -1)
        }
        // Whatever the assertions conclude, this test leaves no stray sleep.
        // The backstop is deliberately independent of the API under test.
        addTeardownBlock {
            if quitProcessIsAlive(pid) { kill(pid, SIGKILL) }
        }
        XCTAssertTrue(quitProcessIsAlive(pid), "the child must be running before quit")
        return (model, pid)
    }

    /// The real quit path: `NSApplication` posts `willTerminate` before the
    /// process exits, and that must reach the watcher's `stop()` — otherwise
    /// the child outlives the app (S1).
    func testWillTerminateStopsTheTrackDevicesChild() async throws {
        let (model, pid) = try await startLifecycleFixture()
        guard pid > 0 else { return }

        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, quitProcessIsAlive(pid) {
            // Best effort: a sleep only fails on cancellation; the loop re-checks the deadline.
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(
            quitProcessIsAlive(pid),
            "the willTerminate hook must terminate the track-devices child, or quitting orphans it (S1)"
        )
        _ = model
    }

    /// The awaited quit cleanup (`applicationShouldTerminate`): a running
    /// recording is finalized and saved (not abandoned), the mirror is torn
    /// down, logcat and the watcher's child stop — within the bound (F11).
    func testPrepareForTerminationCleansUpWithinTheBound() async throws {
        let (model, pid) = try await startLifecycleFixture()
        guard pid > 0 else { return }
        let session = FakeMirrorSession()
        model.workspace.mirror.sessionFactoryOverride = { _, _ in session }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuitRecording-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        model.recordingFinalizer.recordingAutoSaveDirectory = directory
        let phone = AndroidDevice(serial: "HT4CWJT01234", state: "device", model: "Pixel 8")
        model.inventory.applyWatcherSnapshot([phone], degraded: false)
        await model.mirror(device: phone)
        await model.workspace.media.toggleRecording()
        for index in 0..<10 {
            session.putFrame(width: 128, height: 256, shade: UInt8(index * 20))
            try await Task.sleep(for: .milliseconds(40))
        }

        let started = Date()
        await model.prepareForTermination(timeout: .seconds(5))

        XCTAssertLessThan(Date().timeIntervalSince(started), 5.5, "quit must never wait past its bound")
        XCTAssertEqual(session.stopCount, 1)
        XCTAssertNil(model.activeDeviceSerial)
        XCTAssertFalse(model.workspace.media.isRecording)
        XCTAssertNil(model.workspace.lifecycleIfRunning)
        let clips = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(clips.map(\.pathExtension), ["mp4"], "the recording is saved, not abandoned")
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, quitProcessIsAlive(pid) {
            // Best effort: a sleep only fails on cancellation; the loop re-checks the deadline.
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(quitProcessIsAlive(pid), "the track-devices child stops with the app")
    }

    /// The bound holds even when the work does not finish.
    func testBoundedWaitReturnsAtItsTimeout() async {
        let started = Date()
        await AppModel.awaitBounded(.milliseconds(200)) {
            // Best effort: the sleep is the hung work; its cancellation is irrelevant.
            try? await Task.sleep(for: .seconds(10))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
}
