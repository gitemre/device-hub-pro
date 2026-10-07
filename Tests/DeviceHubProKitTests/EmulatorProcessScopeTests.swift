import Darwin
import XCTest
@testable import DeviceHubProKit

/// `EmulatorProcessScope`: an `.ownProcesses` manager sees, stops and probes
/// only the VMs its process started; an `.everyVM` one (the app's) sees
/// every VM `ps` lists.
final class EmulatorProcessScopeTests: XCTestCase {
    /// A shell script named like a VM (`qemu-system-…`) that runs until
    /// killed: `ps` lists it as a VM of whatever `-avd` it is given.
    private func makeVMScript() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmulatorProcessScopeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("qemu-system-scope-test")
        try Data("#!/bin/sh\ntrap 'exit 0' TERM\nwhile :; do sleep 0.2; done\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// A VM launched through an own-process manager is listed; one started
    /// any other way (the stand-in for a VM someone else runs) is not, so
    /// neither `stop` nor `killWithoutSaving` can find and signal it.
    func testAnOwnProcessManagerSeesAndSignalsOnlyTheVMsItsProcessStarted() async throws {
        let script = try makeVMScript()
        let own = EmulatorManager(emulatorURL: script, processScope: .ownProcesses)
        let ownAvd = "DeviceHubPro_Own_\(UUID().uuidString.prefix(8))"
        let foreignAvd = "DeviceHubPro_Foreign_\(UUID().uuidString.prefix(8))"

        let launched = try own.launch(avd: ownAvd, grpcPort: own.reserveGrpcPort())
        let launchedPID = launched.processIdentifier
        addTeardownBlock {
            if EmulatorManager.processExists(launchedPID) { kill(launchedPID, SIGKILL) }
            try? FileManager.default.removeItem(at: own.logFileURL(forAvd: ownAvd))
        }
        let foreign = Process()
        foreign.executableURL = script
        foreign.arguments = ["-avd", foreignAvd, "-grpc", "\(EmulatorManager.unreachableGrpcPort)"]
        try foreign.run()
        let foreignPID = foreign.processIdentifier
        addTeardownBlock { if EmulatorManager.processExists(foreignPID) { kill(foreignPID, SIGKILL) } }

        let everything: [RunningEmulator]
        do {
            everything = try await own.scoped(to: .everyVM).runningEmulators()
        } catch {
            throw XCTSkip("process list unavailable: \(error)")
        }
        XCTAssertTrue(everything.contains { $0.avd == foreignAvd }, "the stand-in must look like a VM: \(everything)")
        XCTAssertTrue(everything.contains { $0.avd == ownAvd }, "\(everything)")

        let visible = try await own.runningEmulators()
        XCTAssertEqual(visible.filter { [ownAvd, foreignAvd].contains($0.avd) }.map(\.avd), [ownAvd])
        XCTAssertEqual(visible.first { $0.avd == ownAvd }?.grpcPort, EmulatorManager.unreachableGrpcPort)

        // Reading every VM is still allowed, for a check that refuses: the
        // foreign VM's AVD is not taken for stopped.
        let foreignRuns = try await own.isAnyVMRunning(avd: foreignAvd)
        XCTAssertTrue(foreignRuns)
        let noneRuns = try await own.isAnyVMRunning(avd: "DeviceHubPro_None_\(UUID().uuidString.prefix(8))")
        XCTAssertFalse(noneRuns)

        let stopped = try await own.stop(avd: foreignAvd, adb: nil, gracefulTimeout: 1)
        XCTAssertEqual(stopped, .notRunning)
        let killed = try await own.killWithoutSaving(avd: foreignAvd, exitTimeout: 1)
        XCTAssertEqual(killed, .notRunning)
        XCTAssertTrue(foreign.isRunning, "a VM the process did not start was signalled")

        let ownStopped = try await own.stop(avd: ownAvd, adb: nil, gracefulTimeout: 5)
        XCTAssertEqual(ownStopped, .stopped(gracefully: true), "its own VM is found and stopped")
    }

    /// The filter runs before the de-duplication by AVD name, and needs both
    /// the pid and the AVD: another VM of the same name listed first does not
    /// hide the own one, and a recycled pid running another AVD is not own.
    func testTheOwnFilterMatchesThePidAndTheAvd() {
        let output = """
          100 /sdk/emulator/qemu/qemu-system-aarch64 -avd Shared -grpc 8554
          200 /tmp/qemu-system-stub -avd Shared -grpc 0
          300 /sdk/emulator/qemu/qemu-system-aarch64 -avd Recycled -grpc 8556
        """
        let own: [Int32: String] = [200: "Shared", 300: "Mine"]

        let running = EmulatorManager.parseRunningEmulators(psOutput: output) { pid, avd in
            own[pid] == avd
        }

        XCTAssertEqual(running, [RunningEmulator(avd: "Shared", processID: 200, grpcPort: 0)])
        XCTAssertEqual(
            EmulatorManager.parseRunningEmulators(psOutput: output).map(\.processID),
            [100, 300],
            "unfiltered, the first VM of a name wins, as before"
        )
    }

    /// An own-process manager probes no port and launches on the port
    /// nothing can serve, and its logs stay out of the app's `/tmp` files;
    /// the app's manager keeps the emulator's default ports and `/tmp`.
    func testAnOwnProcessManagerNeverProbesAndKeepsItsFilesApart() {
        let app = EmulatorManager(emulatorURL: URL(fileURLWithPath: "/nonexistent/emulator"), processScope: .everyVM)
        let own = app.scoped(to: .ownProcesses)

        XCTAssertEqual(own.processScope, .ownProcesses)
        XCTAssertTrue(app.scoped(to: .everyVM) === app)
        XCTAssertEqual(own.emulatorURL, app.emulatorURL)
        XCTAssertEqual(app.grpcScanPorts, Array(8554...8563))
        XCTAssertEqual(own.grpcScanPorts, [])
        XCTAssertEqual(own.reserveGrpcPort(), EmulatorManager.unreachableGrpcPort)
        XCTAssertEqual(
            app.logFileURL(forAvd: "Pixel 9").path,
            FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Logs/DeviceHubPro/devicehubpro-emulator-Pixel-9.log"
        )
        XCTAssertEqual(
            own.logFileURL(forAvd: "Pixel 9"),
            FileManager.default.temporaryDirectory.appendingPathComponent("devicehubpro-emulator-Pixel-9.log")
        )
    }

    /// A located emulator sees the VMs its caller names: there is no
    /// default, so no construction ends up with the app's view unasked.
    func testALocatedEmulatorSeesTheScopeItIsAskedFor() throws {
        let script = try makeVMScript()
        let environment = ["DHP_EMULATOR": script.path]

        XCTAssertEqual(EmulatorManager.locateBinary(environment: environment), script)
        let own = try XCTUnwrap(EmulatorManager.locate(processScope: .ownProcesses, environment: environment))
        XCTAssertEqual(own.emulatorURL, script)
        XCTAssertEqual(own.processScope, .ownProcesses)
        let app = try XCTUnwrap(EmulatorManager.locate(processScope: .everyVM, environment: environment))
        XCTAssertEqual(app.processScope, .everyVM)
    }
}
