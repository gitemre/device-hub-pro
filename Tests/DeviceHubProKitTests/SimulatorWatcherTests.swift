import XCTest
@testable import DeviceHubProKit

/// `SimulatorWatcher` against a stub `simctl` whose `list -j devices` answer
/// (a real capture, see `SimctlFixtureTests`), exit code and delay the test
/// swaps, and a temporary device-set folder the test writes `device.plist`
/// files into (the captured ones), the way CoreSimulator does.
final class SimulatorWatcherTests: XCTestCase {
    private static let udid = SimctlFixtureTests.udid

    private struct Stub {
        let simctl: SimctlClient
        let devices: URL
        let answer: URL
        let code: URL
        let delay: URL
        let log: URL

        func answer(with fixture: String) throws {
            let data = try Data(contentsOf: SimctlFixtureTests.url("simctl-core", fixture))
            try data.write(to: answer)
        }

        func exit(with code: Int32) throws {
            try Data("\(code)".utf8).write(to: self.code)
        }

        /// Makes every later call sleep `seconds` before answering (`nil`:
        /// answer at once), the way a stuck CoreSimulatorService holds
        /// `list` until the call times out.
        func delay(by seconds: String?) throws {
            try Data((seconds ?? "").utf8).write(to: delay)
        }

        var listCalls: Int {
            // Best effort: no log yet means no calls.
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
                .split(separator: "\n")
                .filter { $0.contains("list -j devices") }
                .count
        }

        func writeDevicePlist(_ fixture: String, udid: String = SimulatorWatcherTests.udid) throws {
            let folder = devices.appendingPathComponent(udid, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try Data(contentsOf: SimctlFixtureTests.url("simctl-core", fixture))
            try data.write(to: folder.appendingPathComponent("device.plist"), options: .atomic)
        }
    }

    private func makeStub(answer fixture: String = "simctl-list-j-devices.shutdown.json") throws -> Stub {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimulatorWatcherTests-\(UUID().uuidString)", isDirectory: true)
        let devices = root.appendingPathComponent("set", isDirectory: true)
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        // Best effort: a leftover temporary folder must not fail the test.
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let answer = root.appendingPathComponent("answer.json")
        let code = root.appendingPathComponent("code.txt")
        let delay = root.appendingPathComponent("delay.txt")
        let log = root.appendingPathComponent("calls.log")
        let script = root.appendingPathComponent("simctl")
        try Data("""
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(log.path)'
        if [ -s '\(delay.path)' ]; then sleep "$(cat '\(delay.path)')"; fi
        cat '\(answer.path)'
        exit $(cat '\(code.path)')
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let stub = Stub(
            simctl: SimctlClient(simctlURL: script, deviceSet: devices),
            devices: devices,
            answer: answer,
            code: code,
            delay: delay,
            log: log
        )
        try stub.answer(with: fixture)
        try stub.exit(with: 0)
        return stub
    }

    // MARK: Relevance (pure)

    func testOnlyTheSetFolderAndDeviceFoldersAreRelevant() {
        let root = "/Users/x/Library/Developer/CoreSimulator/Devices"
        XCTAssertTrue(SimulatorWatcher.isRelevant(eventPath: root, devicesDirectory: root))
        XCTAssertTrue(SimulatorWatcher.isRelevant(eventPath: root + "/", devicesDirectory: root))
        XCTAssertTrue(SimulatorWatcher.isRelevant(eventPath: root + "/\(Self.udid)/", devicesDirectory: root))
        XCTAssertFalse(SimulatorWatcher.isRelevant(eventPath: root + "/\(Self.udid)/data", devicesDirectory: root))
        XCTAssertFalse(
            SimulatorWatcher.isRelevant(eventPath: root + "/\(Self.udid)/data/Library/Logs/", devicesDirectory: root)
        )
        XCTAssertFalse(SimulatorWatcher.isRelevant(eventPath: "/Users/x/Library/Developer/CoreSimulator", devicesDirectory: root))
        XCTAssertFalse(SimulatorWatcher.isRelevant(eventPath: root + "Other/x", devicesDirectory: root))
    }

    // MARK: Snapshots

    func testStartEmitsTheCurrentList() async throws {
        let stub = try makeStub()
        let watcher = SimulatorWatcher(simctl: stub.simctl, pollInterval: .seconds(60), fullRefreshInterval: .seconds(60))
        let recorder = record(watcher)

        let events = try await recorder.wait { Self.snapshots(in: $0).count >= 1 }
        let snapshot = try XCTUnwrap(Self.snapshots(in: events).first)
        XCTAssertEqual(snapshot.map(\.udid), [Self.udid])
        XCTAssertEqual(snapshot.first?.state, .shutdown)
        XCTAssertEqual(Self.degradedFlags(in: events), [false])
    }

    /// A `device.plist` rewrite (the boot's state 1 → 3) triggers a list
    /// read without waiting for the poll.
    func testADevicePlistChangeTriggersARead() async throws {
        let stub = try makeStub()
        try stub.writeDevicePlist("device.plist.created")
        let watcher = SimulatorWatcher(simctl: stub.simctl, pollInterval: .seconds(60), fullRefreshInterval: .seconds(60))
        let recorder = record(watcher)
        _ = try await recorder.wait { Self.snapshots(in: $0).count >= 1 }

        try stub.answer(with: "simctl-list-j-devices.booted.json")
        try stub.writeDevicePlist("device.plist.booted")
        let events = try await recorder.wait { Self.snapshots(in: $0).count >= 2 }
        XCTAssertEqual(Self.snapshots(in: events).last?.first?.state, .booted)
    }

    /// A burst of rewrites (create, boot, rename in quick succession) is
    /// coalesced: one read after the debounce, at most one more for events
    /// that land while it runs.
    func testABurstOfChangesCostsOneRead() async throws {
        let stub = try makeStub()
        try stub.writeDevicePlist("device.plist.created")
        let watcher = SimulatorWatcher(simctl: stub.simctl, pollInterval: .seconds(60), fullRefreshInterval: .seconds(60))
        let recorder = record(watcher)
        _ = try await recorder.wait { Self.snapshots(in: $0).count >= 1 }
        try await Task.sleep(for: .milliseconds(800))
        let callsBefore = stub.listCalls

        try stub.answer(with: "simctl-list-j-devices.booted.json")
        for index in 0..<12 {
            try stub.writeDevicePlist(index.isMultiple(of: 2) ? "device.plist.booted" : "device.plist.created")
            try await Task.sleep(for: .milliseconds(15))
        }
        _ = try await recorder.wait { Self.snapshots(in: $0).count >= 2 }
        try await Task.sleep(for: .milliseconds(1500))
        let reads = stub.listCalls - callsBefore
        XCTAssertGreaterThanOrEqual(reads, 1)
        XCTAssertLessThanOrEqual(reads, 2, "a burst must not cost a read per event")
    }

    /// Writes inside a running device's `data/` folder never trigger a read.
    func testWritesInsideDeviceDataAreIgnored() async throws {
        let stub = try makeStub()
        let data = stub.devices.appendingPathComponent("\(Self.udid)/data/Library/Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let watcher = SimulatorWatcher(simctl: stub.simctl, pollInterval: .seconds(60), fullRefreshInterval: .seconds(60))
        let recorder = record(watcher)
        _ = try await recorder.wait { Self.snapshots(in: $0).count >= 1 }
        // Let any event from the setup settle before counting.
        try await Task.sleep(for: .milliseconds(800))
        let callsBefore = stub.listCalls

        for index in 0..<20 {
            try Data("line \(index)\n".utf8).write(to: data.appendingPathComponent("system.log"))
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(stub.listCalls, callsBefore, "data writes must not cost list reads")
    }

    /// Without the file-system trigger the watcher reports `.degraded` and
    /// finds changes by polling; an unchanged folder costs no read until the
    /// full-refresh interval.
    func testPollingOnlyModeFindsChangesAndSkipsIdleReads() async throws {
        let stub = try makeStub()
        try stub.writeDevicePlist("device.plist.created")
        let watcher = SimulatorWatcher(
            simctl: stub.simctl,
            pollInterval: .milliseconds(150),
            fullRefreshInterval: .seconds(60),
            usesFileEvents: false
        )
        let recorder = record(watcher)

        let first = try await recorder.wait { Self.snapshots(in: $0).count >= 1 }
        XCTAssertTrue(first.contains { if case .health(.degraded) = $0 { return true } else { return false } })
        XCTAssertEqual(Self.degradedFlags(in: first), [true])

        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(stub.listCalls, 1, "idle polls compare the fingerprint only")

        try stub.answer(with: "simctl-list-j-devices.booted.json")
        try stub.writeDevicePlist("device.plist.booted")
        let events = try await recorder.wait { Self.snapshots(in: $0).count >= 2 }
        XCTAssertEqual(Self.snapshots(in: events).last?.first?.state, .booted)
    }

    /// Only identity and state changes produce snapshots: the booted listing
    /// read again and again (full refreshes) emits nothing new.
    func testUnchangedListsAreNotReEmitted() async throws {
        let stub = try makeStub(answer: "simctl-list-j-devices.booted.json")
        let watcher = SimulatorWatcher(
            simctl: stub.simctl,
            pollInterval: .milliseconds(100),
            fullRefreshInterval: .milliseconds(100),
            usesFileEvents: false
        )
        let recorder = record(watcher)
        _ = try await recorder.wait { Self.snapshots(in: $0).count >= 1 }
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertGreaterThan(stub.listCalls, 3, "full refreshes ran")
        XCTAssertEqual(Self.snapshots(in: recorder.events).count, 1)
    }

    /// A failing read reports health and keeps the last snapshot; the first
    /// read after the failures emits again.
    func testListFailuresReportHealthAndRecover() async throws {
        let stub = try makeStub()
        try stub.exit(with: 1)
        let watcher = SimulatorWatcher(
            simctl: stub.simctl,
            pollInterval: .milliseconds(100),
            fullRefreshInterval: .seconds(60),
            usesFileEvents: false
        )
        let recorder = record(watcher)

        let failing = try await recorder.wait { events in
            events.contains { if case .health(.listFailing(2)) = $0 { return true } else { return false } }
        }
        XCTAssertEqual(Self.snapshots(in: failing).count, 0, "a failed read is not an empty list")

        try stub.exit(with: 0)
        let recovered = try await recorder.wait { Self.snapshots(in: $0).count >= 1 }
        XCTAssertEqual(Self.snapshots(in: recovered).first?.map(\.udid), [Self.udid])
    }

    /// A read that hangs across many polls (CoreSimulatorService stuck,
    /// every `list` waiting out its timeout) must not cost the file-system
    /// trigger. The polls queued behind such a read once pushed a waiting
    /// file event out of a bounded trigger buffer, and the gate that lets one
    /// file event wait then swallowed every later one. After recovery a
    /// change only FSEvents sees (a new file in a device folder: no
    /// `device.plist` changed, so the fingerprint poll stays quiet) must
    /// still trigger a read.
    func testAHangingReadDoesNotLoseTheFileTrigger() async throws {
        let stub = try makeStub()
        try stub.writeDevicePlist("device.plist.created")
        try stub.delay(by: "0.8")
        try stub.exit(with: 1)
        let watcher = SimulatorWatcher(
            simctl: stub.simctl,
            debounce: .milliseconds(100),
            pollInterval: .milliseconds(20),
            fullRefreshInterval: .seconds(60)
        )
        let recorder = record(watcher)

        // The first read hangs; a device changes meanwhile, and about forty
        // polls arrive before the read fails.
        try await Task.sleep(for: .milliseconds(100))
        try stub.writeDevicePlist("device.plist.booted")
        _ = try await recorder.wait { events in
            events.contains { if case .health(.listFailing) = $0 { return true } else { return false } }
        }
        try stub.delay(by: nil)
        try stub.exit(with: 0)
        _ = try await recorder.wait { Self.snapshots(in: $0).count >= 1 }
        try await Task.sleep(for: .milliseconds(500))

        try stub.answer(with: "simctl-list-j-devices.booted.json")
        try Data().write(to: stub.devices.appendingPathComponent("\(Self.udid)/marker"))
        let events = try await recorder.wait(timeout: .seconds(3)) { Self.snapshots(in: $0).count >= 2 }
        XCTAssertEqual(Self.snapshots(in: events).last?.first?.state, .booted)
    }

    func testStopEndsTheWatcher() async throws {
        let stub = try makeStub()
        let watcher = SimulatorWatcher(
            simctl: stub.simctl,
            pollInterval: .milliseconds(100),
            fullRefreshInterval: .milliseconds(100)
        )
        let recorder = record(watcher)
        _ = try await recorder.wait { Self.snapshots(in: $0).count >= 1 }
        watcher.stop()
        try await Task.sleep(for: .milliseconds(300))
        let calls = stub.listCalls
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(stub.listCalls, calls, "no reads after stop")
    }

    /// The stream's `onTermination` calls `stop()` inside the consumer's
    /// cancellation, with the consumer's status-record lock held, and an
    /// emission's `yield` needs that lock to resume the consumer: `stop()`
    /// must not wait for a yield in flight (see the `DeviceWatcher` test of
    /// the same name).
    func testStopReturnsWhileAYieldIsStalledOnTheConsumer() throws {
        let stub = try makeStub()
        // Without file events `start()` itself emits `.health(.degraded)`.
        let watcher = SimulatorWatcher(
            simctl: stub.simctl,
            pollInterval: .seconds(60),
            fullRefreshInterval: .seconds(60),
            usesFileEvents: false
        )
        defer { watcher.stop() }

        let returned = StalledYieldProbe.stopReturnsWhileAYieldIsStalled(
            consuming: watcher.events(),
            emit: { watcher.start() },
            stop: { watcher.stop() }
        )
        XCTAssertTrue(
            returned,
            "stop() waited for a yield stalled on the consumer: a cancelled consumer deadlocks in onTermination"
        )
    }

    // MARK: Helpers

    /// Starts `watcher` and records its events on a task that lives until
    /// the test ends (cancelling a consumer terminates the stream, so the
    /// stream is read by one long-lived task).
    private func record(_ watcher: SimulatorWatcher) -> Recorder {
        let recorder = Recorder()
        let stream = watcher.events()
        let task = Task {
            for await event in stream {
                recorder.append(event)
            }
        }
        watcher.start()
        addTeardownBlock {
            watcher.stop()
            task.cancel()
        }
        return recorder
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [SimulatorWatcherEvent] = []

        func append(_ event: SimulatorWatcherEvent) {
            lock.lock()
            stored.append(event)
            lock.unlock()
        }

        var events: [SimulatorWatcherEvent] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        /// Waits until `condition` holds for the events so far.
        func wait(
            timeout: Duration = .seconds(10),
            file: StaticString = #filePath,
            line: UInt = #line,
            until condition: ([SimulatorWatcherEvent]) -> Bool
        ) async throws -> [SimulatorWatcherEvent] {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while !condition(events) {
                guard clock.now < deadline else {
                    XCTFail("condition not met within \(timeout): \(events)", file: file, line: line)
                    return events
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            return events
        }
    }

    private static func snapshots(in events: [SimulatorWatcherEvent]) -> [[SimulatorDevice]] {
        events.compactMap {
            guard case .snapshot(let devices, _) = $0 else { return nil }
            return devices
        }
    }

    private static func degradedFlags(in events: [SimulatorWatcherEvent]) -> [Bool] {
        events.compactMap {
            guard case .snapshot(_, let degraded) = $0 else { return nil }
            return degraded
        }
    }
}
