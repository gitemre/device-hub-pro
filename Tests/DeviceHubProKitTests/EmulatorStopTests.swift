import XCTest
@testable import DeviceHubProKit

/// Stopping emulator VMs: `ps` parsing plus the safe no-op path of `stop`.
final class EmulatorStopTests: XCTestCase {
    func testParseRunningEmulatorsFindsAvdPidAndGrpcPort() {
        let output = """
        123 /Applications/SomeApp.app/Contents/MacOS/SomeApp
        4567 /Users/test/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64 -avd Pixel_Fold -grpc 8554 -gpu host -qt-hide-window
        8910 /Users/test/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64 -avd Pixel_9 -gpu host
        """
        let running = EmulatorManager.parseRunningEmulators(psOutput: output)
        XCTAssertEqual(running.count, 2)
        XCTAssertEqual(running[0].avd, "Pixel_Fold")
        XCTAssertEqual(running[0].processID, 4567)
        XCTAssertEqual(running[0].grpcPort, 8554)
        XCTAssertEqual(running[1].avd, "Pixel_9")
        XCTAssertEqual(running[1].processID, 8910)
        XCTAssertNil(running[1].grpcPort)
    }

    func testParseRunningEmulatorsIgnoresQemuWithoutAvd() {
        let output = "111 /usr/local/bin/qemu-system-aarch64 -m 2048\n"
        XCTAssertTrue(EmulatorManager.parseRunningEmulators(psOutput: output).isEmpty)
    }

    func testParseRunningEmulatorsKeepsFirstOfDuplicateAvds() {
        let output = """
        100 /sdk/emulator/qemu/qemu-system-x86_64 -avd Pixel_Fold -grpc 8554
        200 /sdk/emulator/qemu/qemu-system-x86_64 -avd Pixel_Fold -grpc 8555
        """
        let running = EmulatorManager.parseRunningEmulators(psOutput: output)
        XCTAssertEqual(running.count, 1)
        XCTAssertEqual(running[0].processID, 100)
        XCTAssertEqual(running[0].grpcPort, 8554)
    }

    func testParseRunningEmulatorsHandlesEmptyOutput() {
        XCTAssertTrue(EmulatorManager.parseRunningEmulators(psOutput: "").isEmpty)
    }

    // MARK: Graceful stop sequence (F13)

    /// A scripted VM: it records every step taken against it and exits when
    /// the script says so (SIGKILL always works).
    private final class FakeVM: @unchecked Sendable {
        private let lock = NSLock()
        private let consoleDelivers: Bool
        private let exitsOnConsoleKill: Bool
        /// The signal that makes the VM exit; nil when it ignores SIGTERM.
        private let exitsOnSignal: Int32?
        private var checks = 0
        /// The running check at which the VM is first reported gone.
        private var goneAtCheck: Int?
        private var log: [String] = []

        init(consoleDelivers: Bool, exitsOnConsoleKill: Bool, exitsOnSignal: Int32?) {
            self.consoleDelivers = consoleDelivers
            self.exitsOnConsoleKill = exitsOnConsoleKill
            self.exitsOnSignal = exitsOnSignal
        }

        var recorded: [String] {
            lock.lock()
            defer { lock.unlock() }
            return log
        }

        var steps: EmulatorStopSteps {
            EmulatorStopSteps(
                requestShutdown: { self.requestShutdown() },
                isRunning: { self.isRunning() },
                signal: { self.signal($0) }
            )
        }

        private func requestShutdown() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            log.append("console kill")
            // A clean shutdown takes a moment (the snapshot save).
            if consoleDelivers, exitsOnConsoleKill { goneAtCheck = checks + 3 }
            return consoleDelivers
        }

        private func isRunning() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            checks += 1
            guard let goneAtCheck else { return true }
            return checks < goneAtCheck
        }

        private func signal(_ signal: Int32) {
            lock.lock()
            defer { lock.unlock() }
            log.append(signal == SIGKILL ? "SIGKILL" : signal == SIGTERM ? "SIGTERM" : "signal \(signal)")
            if signal == SIGKILL || signal == exitsOnSignal { goneAtCheck = checks + 1 }
        }
    }

    private func stop(
        _ vm: FakeVM,
        killAllowed: Bool,
        withConsole: Bool = true
    ) async throws -> EmulatorStopResult {
        var steps = vm.steps
        if !withConsole { steps.requestShutdown = nil }
        return try await EmulatorManager.stopSequence(
            avd: "Pixel_9",
            processID: 4242,
            steps: steps,
            shutdownTimeout: 0.3,
            gracefulTimeout: 0.3,
            killAllowed: killAllowed,
            pollInterval: .milliseconds(10)
        )
    }

    /// The console's `kill` is the emulator's own clean shutdown (it saves the
    /// quick-boot snapshot); no signal is sent when it works.
    func testStopShutsDownThroughTheConsoleFirst() async throws {
        let vm = FakeVM(consoleDelivers: true, exitsOnConsoleKill: true, exitsOnSignal: nil)
        let result = try await stop(vm, killAllowed: false)
        XCTAssertEqual(result, .stopped(gracefully: true))
        XCTAssertEqual(vm.recorded, ["console kill"])
    }

    /// Without a console (no adb transport, or it refused) SIGTERM is next.
    func testStopFallsBackToSIGTERMWhenTheConsoleIsUnavailable() async throws {
        let refused = FakeVM(consoleDelivers: false, exitsOnConsoleKill: false, exitsOnSignal: SIGTERM)
        let refusedResult = try await stop(refused, killAllowed: false)
        XCTAssertEqual(refusedResult, .stopped(gracefully: true))
        XCTAssertEqual(refused.recorded, ["console kill", "SIGTERM"])

        let noAdb = FakeVM(consoleDelivers: false, exitsOnConsoleKill: false, exitsOnSignal: SIGTERM)
        let noAdbResult = try await stop(noAdb, killAllowed: false, withConsole: false)
        XCTAssertEqual(noAdbResult, .stopped(gracefully: true))
        XCTAssertEqual(noAdb.recorded, ["SIGTERM"])
    }

    /// A VM this app did not start may be mid-snapshot: it is never
    /// SIGKILLed on the app's own initiative.
    func testStopNeverKillsAVMTheAppDidNotStart() async throws {
        let vm = FakeVM(consoleDelivers: true, exitsOnConsoleKill: false, exitsOnSignal: nil)
        do {
            _ = try await stop(vm, killAllowed: false)
            XCTFail("expected stopFailed")
        } catch let error as EmulatorError {
            guard case .stopFailed(let reason) = error else {
                return XCTFail("expected stopFailed, got \(error)")
            }
            XCTAssertTrue(reason.contains("not started by Device Hub Pro"), reason)
        }
        XCTAssertEqual(vm.recorded, ["console kill", "SIGTERM"], "no SIGKILL")
    }

    /// The app's own VM (or a forced stop) escalates to SIGKILL, last.
    func testStopKillsItsOwnVMOnlyAfterTheGentleSteps() async throws {
        let vm = FakeVM(consoleDelivers: true, exitsOnConsoleKill: false, exitsOnSignal: nil)
        let result = try await stop(vm, killAllowed: true)
        XCTAssertEqual(result, .stopped(gracefully: false))
        XCTAssertEqual(vm.recorded, ["console kill", "SIGTERM", "SIGKILL"])
    }

    // MARK: Killing a broken VM without saving it

    /// Recovering a powered-off guest must not save it: no console `kill`
    /// and no SIGTERM (both save the quick-boot snapshot), only SIGKILL.
    func testKillSequenceSendsOnlySIGKILL() async throws {
        let vm = FakeVM(consoleDelivers: true, exitsOnConsoleKill: true, exitsOnSignal: SIGTERM)
        let result = try await EmulatorManager.killSequence(
            avd: "Pixel_9",
            processID: 4242,
            steps: vm.steps,
            exitTimeout: 1,
            pollInterval: .milliseconds(10)
        )
        XCTAssertEqual(result, .stopped(gracefully: false))
        XCTAssertEqual(vm.recorded, ["SIGKILL"])
    }

    /// A VM that survives SIGKILL still holds the AVD: the caller must not
    /// relaunch it, so this throws instead of returning.
    func testKillSequenceThrowsWhenTheProcessOutlivesTheWait() async throws {
        let steps = EmulatorStopSteps(requestShutdown: nil, isRunning: { true }, signal: { _ in })
        do {
            _ = try await EmulatorManager.killSequence(
                avd: "Pixel_9",
                processID: 4242,
                steps: steps,
                exitTimeout: 0.1,
                pollInterval: .milliseconds(10)
            )
            XCTFail("expected stopFailed")
        } catch EmulatorError.stopFailed(let reason) {
            XCTAssertTrue(reason.contains("still running"), reason)
        }
    }

    /// End to end against a real process that looks like a VM to `ps`: it
    /// "saves its snapshot" (writes a marker) when asked to quit with
    /// SIGTERM, as the emulator does. `killWithoutSaving` must end it without
    /// that save and return only once the pid is gone (reaped) — the point
    /// at which the emulator treats the AVD lock as stale.
    func testKillWithoutSavingEndsTheVMWithoutItsExitSave() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmulatorKillTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let saved = directory.appendingPathComponent("saved")
        let vmScript = directory.appendingPathComponent("qemu-system-devicehubpro-test")
        try Data("""
        #!/bin/sh
        trap 'touch "\(saved.path)"; exit 0' TERM
        while :; do sleep 1; done
        """.utf8).write(to: vmScript)
        let avd = "DeviceHubPro_Kill_\(UUID().uuidString.prefix(8))"
        let vm = Process()
        vm.executableURL = URL(fileURLWithPath: "/bin/sh")
        vm.arguments = [vmScript.path, "-avd", avd]
        vm.standardInput = FileHandle.nullDevice
        try vm.run()
        let pid = vm.processIdentifier
        addTeardownBlock { if EmulatorManager.processExists(pid) { kill(pid, SIGKILL) } }
        // The test's own VM, so a manager that sees only this process's VMs
        // lists it — and can never find (and SIGKILL) another VM of the name.
        EmulatorManager.adoptProcess(pid, avd: avd)

        let manager = EmulatorManager(
            emulatorURL: URL(fileURLWithPath: "/nonexistent/emulator"),
            processScope: .ownProcesses
        )
        let listed: Bool
        do {
            listed = try await manager.runningEmulators().contains { $0.avd == avd && $0.processID == pid }
        } catch {
            throw XCTSkip("process list unavailable: \(error)")
        }
        XCTAssertTrue(listed, "the fixture must look like a running VM")

        let result = try await manager.killWithoutSaving(avd: avd, exitTimeout: 5)

        XCTAssertEqual(result, .stopped(gracefully: false))
        XCTAssertFalse(EmulatorManager.processExists(pid), "returns only once the pid is gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path), "the VM must not get to save its state")
        let afterwards = try await manager.killWithoutSaving(avd: avd)
        XCTAssertEqual(afterwards, .notRunning)
    }

    /// The console request goes to the AVD's own serial, found through
    /// `emu avd name` when the caller does not know it.
    func testConsoleShutdownFindsTheSerialAndSendsEmuKill() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmulatorStopTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("calls.log")
        let adbURL = directory.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(log.path)"
        case "$*" in
          "devices -l")
            printf 'List of devices attached\\nemulator-5554 device transport_id:1\\nemulator-5556 device transport_id:2\\n' ;;
          "-s emulator-5554 emu avd name") printf 'Other_AVD\\r\\nOK\\r\\n' ;;
          "-s emulator-5556 emu avd name") printf 'Pixel_9\\r\\nOK\\r\\n' ;;
          "-s emulator-5556 emu kill") printf 'OK: killing emulator, bye bye\\r\\n' ;;
          *) exit 1 ;;
        esac
        """
        try Data(script.utf8).write(to: adbURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adbURL.path)
        let adb = AdbClient(adbURL: adbURL)

        let delivered = await EmulatorManager.requestConsoleShutdown(avd: "Pixel_9", serial: nil, adb: adb)
        XCTAssertTrue(delivered)
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(calls.last, "-s emulator-5556 emu kill")
        XCTAssertFalse(calls.contains("-s emulator-5554 emu kill"), "only the AVD's own VM is asked")

        let unknown = await EmulatorManager.requestConsoleShutdown(avd: "Missing_AVD", serial: nil, adb: adb)
        XCTAssertFalse(unknown, "no serial for the AVD: nothing delivered")
    }

    /// Stopping an AVD that is not running must be a no-op that signals
    /// nothing. Needs the process list; skipped where `ps` is unavailable.
    /// The manager sees only this process's VMs and has no adb, so nothing
    /// running on the Mac can be asked, matched or signalled.
    func testStopNotRunningAvdIsNoop() async throws {
        let manager = EmulatorManager(
            emulatorURL: URL(fileURLWithPath: "/nonexistent/emulator"),
            processScope: .ownProcesses
        )
        let result: EmulatorStopResult
        do {
            result = try await manager.stop(avd: "devicehubpro-avd-that-cannot-exist", adb: nil)
        } catch {
            throw XCTSkip("process list unavailable: \(error)")
        }
        XCTAssertEqual(result, .notRunning)
    }
}
