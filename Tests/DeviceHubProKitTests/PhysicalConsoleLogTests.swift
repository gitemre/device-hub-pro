import XCTest
@testable import DeviceHubProKit

/// The physical iPhone's log source: the parser of
/// `devicectl device process launch --console` output, the one argv shape the
/// client may run for it, and the stream's start, end and teardown.
///
/// `Fixtures/ios27-device/devicectl-console-launch.txt` is a real capture
/// (devicectl 642.16, Xcode 27.0 27A266a, the dedicated test iPhone on iOS
/// 27.0, 2026-10-01) of Device Hub Pro's host app (`com.devicehubpro.agent.host`) launched
/// with `OS_ACTIVITY_DT_MODE=enable` and `OS_ACTIVITY_MODE=debug`, byte-exact
/// but for the process and thread ids, replaced by same-length zeros. The
/// host app's launch code of that build also logged one line per level and an
/// NSLog, a bare os_log, a print and a two-line message (the `TMP` lines).
/// The flags are HELP-DERIVED (`devicectl device process launch -h`, Xcode
/// 27.0 27A266a); the console bridge itself was captured live.
final class PhysicalConsoleLogTests: XCTestCase {
    private static let id = ApplePhysicalDeviceTests.coreDeviceIdentifier
    private static let bundle = "com.devicehubpro.agent.host"
    private static let environmentJSON = #"{"OS_ACTIVITY_DT_MODE":"enable","OS_ACTIVITY_MODE":"debug"}"#

    private func fixtureLines() throws -> [String] {
        let text = try String(contentsOf: ApplePhysicalDeviceTests.url("devicectl-console-launch.txt"), encoding: .utf8)
        return text.components(separatedBy: "\n")
    }

    private func makeClient(_ fake: FakeTool) throws -> DevicectlPhysicalClient {
        try DevicectlPhysicalClient(
            devicectlURL: fake.executableURL,
            device: try ApplePhysicalDeviceTests.device(),
            commandTimeout: .seconds(30)
        )
    }

    // MARK: - Parser (real captured lines)

    func testAMirroredLogLineParsesIntoItsFields() {
        let line = "2026-10-01 23:53:20.030000+0300 DeviceHubProAgentHost[0000:000000] [host] host app launched"
        XCTAssertEqual(PhysicalConsoleLogParsing.parse(line), .entry(
            timestamp: "2026-10-01 23:53:20.030000+0300", process: "DeviceHubProAgentHost",
            pid: 0, tid: 0, category: "host", message: "host app launched"
        ))
    }

    func testEveryCapturedLineParsesAsItsKind() throws {
        let kinds = try fixtureLines().map { PhysicalConsoleLogParsing.parse($0) }
        var entries: [(String, String)] = []
        var plain: [String] = []
        var ended: [String] = []
        for kind in kinds {
            switch kind {
            case .entry(_, let process, _, _, let category, let message):
                XCTAssertEqual(process, "DeviceHubProAgentHost")
                entries.append((category, message))
            case .plain(let text): plain.append(text)
            case .ended(let text): ended.append(text)
            case .ignored: break
            }
        }
        // Debug, info, error and fault all arrive with the same prefix: the
        // level is not part of the bridged line.
        XCTAssertEqual(entries.map(\.1), [
            "host app launched", "TMP info", "TMP debug", "TMP error", "TMP fault",
            "TMP nocategory", "TMP default osmessage", "TMP nslog 7", "TMP multi",
        ])
        // A Logger category in brackets; none for a bare os_log and NSLog; an
        // empty one for a Logger without a category.
        XCTAssertEqual(entries.map(\.0), ["host", "host", "host", "host", "host", "", "", "", "host"])
        // `print` and the second line of a multi-line message have no prefix.
        XCTAssertEqual(plain, ["TMP print stdout", "line"])
        XCTAssertEqual(ended, ["App terminated due to signal 2."])
    }

    func testDevicectlsOpeningStatusLinesAreIgnoredAndBlanksToo() {
        XCTAssertEqual(PhysicalConsoleLogParsing.parse("Launched application with com.devicehubpro.agent.host bundle identifier."), .ignored)
        XCTAssertEqual(PhysicalConsoleLogParsing.parse("Waiting for the application to terminate..."), .ignored)
        XCTAssertEqual(PhysicalConsoleLogParsing.parse(""), .ignored)
        XCTAssertEqual(PhysicalConsoleLogParsing.parse("   "), .ignored)
    }

    func testAnErrorLineIsPlainTextNotAnEntry() {
        XCTAssertEqual(
            PhysicalConsoleLogParsing.parse("ERROR: The application failed to launch. (com.apple.dt.CoreDeviceError error 10002)"),
            .plain("ERROR: The application failed to launch. (com.apple.dt.CoreDeviceError error 10002)")
        )
    }

    // MARK: - The gate

    func testTheConsoleLaunchArgvIsExactAndHasNoTimeoutOrJSONFile() throws {
        let fake = try FakeTool(name: "devicectl", rules: [])
        let client = try makeClient(fake)
        let argv = try client.consoleCommandLine(bundleID: Self.bundle)
        XCTAssertEqual(argv, [
            "device", "process", "launch", "--device", Self.id,
            "--console", "--terminate-existing", "--environment-variables", Self.environmentJSON, Self.bundle,
        ])
        XCTAssertFalse(argv.contains("-t"), "a timeout would end a long session")
        XCTAssertFalse(argv.contains("--json-output"))
        ApplePhysicalDeviceTests.assertSafeArguments(argv)
    }

    func testOnlyAllowlistedEnvironmentKeysAndValuesPass() throws {
        let fake = try FakeTool(name: "devicectl", rules: [])
        let client = try makeClient(fake)
        XCTAssertNoThrow(try client.consoleCommandLine(bundleID: Self.bundle, environment: ["OS_ACTIVITY_DT_MODE": "YES"]))
        let refused: [[String: String]] = [
            [:],
            ["PATH": "/usr/bin"],
            ["DYLD_INSERT_LIBRARIES": "/tmp/x.dylib"],
            ["IDEPreferLogStreaming": "YES"],
            ["OS_ACTIVITY_DT_MODE": "enable", "EXTRA": "1"],
            ["OS_ACTIVITY_DT_MODE": "$(rm -rf /)"],
            ["OS_ACTIVITY_MODE": "info"],
        ]
        for environment in refused {
            XCTAssertThrowsError(try client.consoleCommandLine(bundleID: Self.bundle, environment: environment), "\(environment)") { error in
                guard case DevicectlClientError.refusedCommand = error else { return XCTFail("\(error)") }
            }
        }
    }

    func testEveryOtherShapeOfTheConsoleLaunchIsRefused() throws {
        let words = ["device", "process", "launch"]
        let json = Self.environmentJSON
        let refused: [[String]] = [
            words + ["--console", Self.bundle],
            words + ["--console", "--terminate-existing", Self.bundle],
            words + ["--console", "--terminate-existing", "--environment-variables", json],
            words + ["--console", "--terminate-existing", "--environment-variables", json, Self.bundle, "extra"],
            words + ["--console", "--terminate-existing", "--environment-variables", json, "-x"],
            words + ["--console", "--terminate-existing", "--environment-variables", json, "not a bundle"],
            words + ["--terminate-existing", "--console", "--environment-variables", json, Self.bundle],
            words + ["--console", "--environment-variables", json, Self.bundle],
            words + ["--console", "--terminate-existing", "--environment-variables", "not json", Self.bundle],
            words + ["--console", "--terminate-existing", "--environment-variables", #"{"OS_ACTIVITY_DT_MODE":1}"#, Self.bundle],
            words + ["--console", "--terminate-existing", "--environment-variables", #"["x"]"#, Self.bundle],
            words + ["--console", "--start-stopped", Self.bundle],
            // `--console` through the ordinary launch is refused (it blocks).
            words + [Self.bundle, "--console"],
            words + ["--terminate-existing", Self.bundle, "--console"],
        ]
        for command in refused {
            XCTAssertThrowsError(try DevicectlPhysicalClient.validate(command), "\(command)") { error in
                guard case DevicectlClientError.refusedCommand = error else { return XCTFail("\(error)") }
            }
        }
        XCTAssertNoThrow(try DevicectlPhysicalClient.validate(
            words + ["--console", "--terminate-existing", "--environment-variables", json, Self.bundle]
        ))
    }

    func testTheOrdinaryLaunchStillRefusesDashArguments() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [])
        let client = try makeClient(fake)
        do {
            _ = try await client.launchApp(bundleID: Self.bundle, arguments: ["--console"])
            XCTFail("expected a refusal")
        } catch DevicectlClientError.refusedCommand {
            // refused
        }
        XCTAssertEqual(fake.calls, [])
    }

    func testTheStreamRefusesWithoutRunningAnythingForABadBundleID() throws {
        let fake = try FakeTool(name: "devicectl", rules: [])
        let client = try makeClient(fake)
        XCTAssertThrowsError(try PhysicalConsoleLogStream(client: client, bundleID: "bad id; rm"))
        XCTAssertEqual(fake.calls, [])
    }

    // MARK: - The stream

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testTheStreamReadsTheCapturedConsoleIntoEntries() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("--console", stdoutFile: ApplePhysicalDeviceTests.url("devicectl-console-launch.txt")),
        ])
        let stream = try PhysicalConsoleLogStream(client: try makeClient(fake), bundleID: Self.bundle)
        stream.start()
        try await waitUntil { if case .stopped = stream.status { return true } else { return false } }

        let entries = stream.snapshot()
        XCTAssertEqual(entries.map(\.message), [
            "host app launched", "TMP info", "TMP debug", "TMP print stdout", "TMP error", "TMP fault",
            "TMP nocategory", "TMP default osmessage", "TMP nslog 7", "TMP multi", "line",
        ])
        XCTAssertEqual(entries.first?.timestamp, "10-01 23:53:20.030")
        XCTAssertEqual(entries.first?.tag, "DeviceHubProAgentHost")
        XCTAssertEqual(entries.first?.subsystem, "host")
        XCTAssertTrue(entries.allSatisfy { $0.level == .info }, "the bridge reports no level")
        XCTAssertEqual(entries.map(\.id), Array(1...UInt64(entries.count)))
        // The output that has no prefix keeps the app's name and the last time.
        let print = try XCTUnwrap(entries.first { $0.message == "TMP print stdout" })
        XCTAssertEqual(print.tag, "DeviceHubProAgentHost")
        XCTAssertEqual(print.subsystem, "stdout")
        XCTAssertEqual(entries.dropFirst(5).first?.id, 6)
        XCTAssertEqual(stream.entries(after: 9).map(\.message), ["TMP multi", "line"])

        guard case .stopped(let reason) = stream.status else { return XCTFail("\(stream.status)") }
        XCTAssertTrue(reason.contains("App terminated due to signal 2."), reason)
        XCTAssertEqual(fake.invocations.count, 1)
        XCTAssertEqual(fake.invocations.first?.prefix(3).map { $0 }, ["device", "process", "launch"])
    }

    func testAFailedLaunchEndsWithDevicectlsErrorAsTheReason() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("--console", stderr: "ERROR: The application failed to launch. (error 10002)", exitCode: 1),
        ])
        let stream = try PhysicalConsoleLogStream(client: try makeClient(fake), bundleID: Self.bundle)
        stream.start()
        try await waitUntil { if case .stopped = stream.status { return true } else { return false } }
        guard case .stopped(let reason) = stream.status else { return XCTFail() }
        XCTAssertTrue(reason.contains("failed to launch"), reason)
        XCTAssertTrue(reason.contains("status 1"), reason)
    }

    /// A devicectl that logs one line and then waits: stopping the stream ends
    /// it (SIGINT) and leaves no process behind.
    func testStoppingTheStreamLeavesNoOrphanedDevicectl() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeConsole-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let script = directory.appendingPathComponent("devicectl")
        let body = """
        #!/bin/sh
        echo $$ > '\(pidFile.path)'
        echo '2026-10-01 23:53:20.030000+0300 Demo[0000:000000] [cat] first line'
        exec sleep 120
        """
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let client = try DevicectlPhysicalClient(
            devicectlURL: script, device: try ApplePhysicalDeviceTests.device(), commandTimeout: .seconds(30)
        )
        let stream = try PhysicalConsoleLogStream(client: client, bundleID: Self.bundle)
        stream.start()
        try await waitUntil { stream.snapshot().count == 1 }
        XCTAssertEqual(stream.status, .running)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), 0, "devicectl runs while streaming")

        await stream.stopAndWait()
        XCTAssertEqual(stream.status, .idle)
        XCTAssertEqual(kill(pid, 0), -1, "the child is gone")
        XCTAssertEqual(errno, ESRCH)
        // Lines on screen stay after the stop.
        XCTAssertEqual(stream.snapshot().map(\.message), ["first line"])
    }
}
