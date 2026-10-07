import Darwin
import XCTest
@testable import DeviceHubProKit

/// `ProcessRunner.run` backs the pairing flow, where an unreachable host must
/// not hold the sheet for adb's own minute-plus TCP timeout. These tests pin
/// the two escape hatches: a bounded run throws a typed timeout after
/// terminating the child, and task cancellation terminates it as well. A child
/// that ignores SIGTERM must still not hold the run open: the timeout path
/// escalates to SIGKILL.
final class ProcessRunnerTimeoutTests: XCTestCase {
    func testRunTimesOutAndTerminatesTheChild() async throws {
        let fixture = try makeSleepingChild()

        let started = Date()
        do {
            _ = try await ProcessRunner.run(
                executable: fixture.command,
                arguments: [],
                timeout: .milliseconds(300)
            )
            XCTFail("expected the run to time out")
        } catch let error as ProcessRunnerError {
            guard case .timedOut(let command, let seconds) = error else {
                return XCTFail("expected a timeout error, got \(error)")
            }
            XCTAssertEqual(command, fixture.command.lastPathComponent)
            XCTAssertEqual(seconds, .milliseconds(300))
        }

        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            5,
            "the run must not wait for the script's 60 s sleep"
        )
        try await assertChildTerminated(fixture)
    }

    func testCancellingRunTerminatesTheChildAndThrowsCancellationError() async throws {
        let fixture = try makeSleepingChild()

        let task = Task {
            try await ProcessRunner.run(executable: fixture.command, arguments: [])
        }
        // Cancel only once the child's trap is in place: on a loaded machine
        // the shell can take longer than any fixed delay to get there.
        try await waitForFile(fixture.ready, timeout: 10)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
        try await assertChildTerminated(fixture)
    }

    func testPairTimesOutWithTheTypedError() async throws {
        let fixture = try makeSleepingChild()
        let client = AdbClient(adbURL: fixture.command)

        do {
            _ = try await client.pair(
                address: "192.168.1.42:37000",
                code: "123456",
                timeout: .milliseconds(300)
            )
            XCTFail("expected the pairing to time out")
        } catch let error as ProcessRunnerError {
            guard case .timedOut(_, let seconds) = error else {
                return XCTFail("expected a timeout error, got \(error)")
            }
            XCTAssertEqual(seconds, .milliseconds(300))
        }
        try await assertChildTerminated(fixture)
    }

    func testConnectTimesOutWithTheTypedError() async throws {
        let fixture = try makeSleepingChild()
        let client = AdbClient(adbURL: fixture.command)

        do {
            _ = try await client.connect(
                address: "192.168.1.42:5555",
                timeout: .milliseconds(300)
            )
            XCTFail("expected the connect to time out")
        } catch let error as ProcessRunnerError {
            guard case .timedOut(_, let seconds) = error else {
                return XCTFail("expected a timeout error, got \(error)")
            }
            XCTAssertEqual(seconds, .milliseconds(300))
        }
        try await assertChildTerminated(fixture)
    }

    /// Every one-shot adb call is bounded by the client's `commandTimeout`
    /// (F3): a wedged transport — `getprop` over a Wi-Fi link that dropped, a
    /// frozen emulator console — fails the call instead of hanging the UI.
    /// The error names the adb command that hung.
    func testOneShotAdbCallsAreBoundedByTheCommandTimeout() async throws {
        let fixture = try makeSleepingChild()
        let client = AdbClient(adbURL: fixture.command, commandTimeout: .milliseconds(300))

        let calls: [(String, () async throws -> Void)] = [
            ("getprop", { _ = try await client.getprop(serial: "emulator-5554") }),
            ("shell", { _ = try await client.shell(serial: "emulator-5554", ["dumpsys", "display"]) }),
            ("emu", { _ = try await client.emuCommand(serial: "emulator-5554", ["avd", "name"]) }),
            ("devices", { _ = try await client.listDevices() }),
            ("run", { _ = try await client.run(["-s", "emulator-5554", "forward", "--list"]) }),
        ]
        for (name, call) in calls {
            let started = Date()
            do {
                try await call()
                XCTFail("\(name): expected a timeout")
            } catch let error as ProcessRunnerError {
                guard case .timedOut(let command, let seconds) = error else {
                    XCTFail("\(name): expected a timeout, got \(error)")
                    continue
                }
                XCTAssertEqual(seconds, .milliseconds(300), name)
                XCTAssertTrue(command.hasPrefix("adb "), "\(name): \(command)")
                XCTAssertTrue(error.description.contains(command), name)
            }
            XCTAssertLessThan(Date().timeIntervalSince(started), 5, "\(name) must not wait for the 60 s child")
        }
        XCTAssertEqual(AdbClient(adbURL: fixture.command).commandTimeout, AdbClient.defaultTimeout)
    }

    /// Transfers take their own, longer bound, and callers can pass one.
    func testPullTakesAnExplicitTimeout() async throws {
        let fixture = try makeSleepingChild()
        let client = AdbClient(adbURL: fixture.command)

        do {
            try await client.pull(
                serial: "emulator-5554",
                remotePath: "/sdcard/clip.mp4",
                to: URL(fileURLWithPath: "/tmp/clip.mp4"),
                timeout: .milliseconds(300)
            )
            XCTFail("expected the pull to time out")
        } catch ProcessRunnerError.timedOut(let command, let seconds) {
            XCTAssertEqual(seconds, .milliseconds(300))
            XCTAssertEqual(command, "adb -s emulator-5554 pull /sdcard/clip.mp4 /tmp/clip.mp4")
        }
        try await assertChildTerminated(fixture)
    }

    /// The runner's structured concurrency waits for the cancelled child
    /// before the throwing group can exit, so a child that ignores SIGTERM
    /// would otherwise make a "bounded" run hang forever. The timeout path
    /// must escalate to SIGKILL after a grace period.
    func testTimeoutEscalatesToSIGKILLWhenTheChildIgnoresTERM() async throws {
        let fixture = try makeTermIgnoringChild()

        let started = Date()
        let probe = RunProbe()
        let run = Task {
            do {
                // Long enough for the shell to install its trap on a loaded
                // machine: a SIGTERM before `trap '' TERM` ends it at once,
                // pid never written (seen under a full parallel run).
                _ = try await ProcessRunner.run(
                    executable: fixture.command,
                    arguments: [],
                    timeout: .seconds(2)
                )
                await probe.record("returned")
            } catch {
                await probe.record("\(error)")
            }
        }

        guard let pid = await waitForPID(fixture.pidFile) else {
            run.cancel()
            return XCTFail("the fixture never reported its pid")
        }
        XCTAssertTrue(Self.processIsAlive(pid), "the fixture must be running")

        var outcome: String?
        let deadline = Date().addingTimeInterval(7)
        while Date() < deadline, outcome == nil {
            outcome = await probe.value()
            if outcome == nil {
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        if outcome == nil {
            run.cancel()
            kill(pid, SIGKILL)
            return XCTFail("run() did not return: a SIGTERM-ignoring child stalls it forever")
        }
        XCTAssertTrue(
            outcome?.contains("did not finish within") == true,
            "expected the typed timeout, got \(outcome ?? "nil")"
        )
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            8,
            "the escalation must be bounded by the timeout plus its grace period"
        )
        XCTAssertFalse(
            Self.processIsAlive(pid),
            "the SIGTERM-ignoring child must be SIGKILLed"
        )
    }

    // MARK: - Sleeping child fixture

    private struct SleepingChild {
        let command: URL
        let marker: URL
        /// Written once the SIGTERM trap is installed.
        let ready: URL
    }

    /// A fake command that reports SIGTERM by writing `marker`. The trap plus
    /// a background `wait` makes the shell handle SIGTERM while waiting; a
    /// foreground `sleep` would defer the trap until it finished.
    private func makeSleepingChild() throws -> SleepingChild {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessRunnerTimeoutTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let marker = directory.appendingPathComponent("terminated")
        let ready = directory.appendingPathComponent("ready")
        let command = directory.appendingPathComponent("sleeping-adb")
        let script = """
        #!/bin/sh
        trap 'printf terminated > "\(marker.path)"' TERM
        sleep 60 &
        : > "\(ready.path)"
        wait
        """
        try Data(script.utf8).write(to: command)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: command.path
        )
        return SleepingChild(command: command, marker: marker, ready: ready)
    }

    /// The child got SIGTERM. When its trap was installed it must have run;
    /// a child killed before it got that far (a loaded machine, a short
    /// timeout) must at least be gone.
    private func assertChildTerminated(_ fixture: SleepingChild) async throws {
        if FileManager.default.fileExists(atPath: fixture.ready.path) {
            try await waitForMarker(fixture.marker)
        } else {
            try await waitForNoProcess(running: fixture.command.path)
        }
    }

    private func waitForFile(_ file: URL, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: file.path) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("\(file.lastPathComponent) did not appear within \(timeout) s")
    }

    /// No process runs `path` (each fixture's path is unique).
    private func waitForNoProcess(running path: String, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let pgrep = Process()
            pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrep.arguments = ["-f", path]
            pgrep.standardOutput = FileHandle.nullDevice
            pgrep.standardError = FileHandle.nullDevice
            try pgrep.run()
            pgrep.waitUntilExit()
            if pgrep.terminationStatus == 1 { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("a process still runs \(path)")
    }

    private func waitForMarker(_ marker: URL, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: marker.path) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("the child did not report SIGTERM within \(timeout) s")
    }

    // MARK: - TERM-ignoring child fixture

    private struct TermIgnoringChild {
        let command: URL
        let pidFile: URL
    }

    /// A fake command that ignores SIGTERM and reports its pid. The ignored
    /// disposition is inherited by its `sleep`, so only SIGKILL stops it.
    private func makeTermIgnoringChild() throws -> TermIgnoringChild {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessRunnerTimeoutTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let pidFile = directory.appendingPathComponent("pid")
        let command = directory.appendingPathComponent("stubborn-adb")
        let script = """
        #!/bin/sh
        trap '' TERM
        printf '%s' "$$" > "\(pidFile.path)"
        while true; do sleep 0.2; done
        """
        try Data(script.utf8).write(to: command)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: command.path
        )
        return TermIgnoringChild(command: command, pidFile: pidFile)
    }

    private func waitForPID(_ pidFile: URL, timeout: TimeInterval = 3) async -> pid_t? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private static func processIsAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }
}

/// Completion probe for the bounded run, shared across concurrency domains.
private actor RunProbe {
    private var result: String?

    func record(_ value: String) {
        result = value
    }

    func value() -> String? {
        result
    }
}
