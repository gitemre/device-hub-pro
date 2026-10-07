import XCTest
@testable import DeviceHubProKit

/// The physical-iPhone actions: install, uninstall, launch,
/// terminate, open URL, screenshot, screen recording, `info files` and `copy
/// from` on `DevicectlPhysicalClient`, each with an exact argv test and a
/// decode of its real capture.
///
/// The `devicectl-…` fixtures added for this phase (capture-screenshot,
/// capture-screen-record, process-launch, process-launch-verifier,
/// process-launch-missing, process-terminate, process-terminate-nopid,
/// process-openURL, install-app, install-app-2, info-apps-after-install,
/// info-files-verifier, info-files-crashlogs, copy-from-readings,
/// uninstall-app, uninstall-app-missing) and `verifier-readings.json` are
/// byte-exact captures of devicectl 642.16 (CoreDevice 642.16, JSON version 5,
/// Xcode 27.0) from the dedicated test iPhone (an iPhone 12 on iOS
/// 27.0), taken on 2026-09-28 with the same-length placeholders of the Phase
/// 9A fixtures (see `ApplePhysicalDeviceTests`) and nothing trimmed. The
/// verifier build they install is `ios/verifier/build.sh --device`. Screen
/// recording is the captured 1001 failure (this iPhone lacks the capability).
final class ApplePhysicalActionTests: XCTestCase {
    private static let id = ApplePhysicalDeviceTests.coreDeviceIdentifier
    private static let verifier = "com.devicehubpro.verifier"

    private func url(_ name: String) -> URL { ApplePhysicalDeviceTests.url(name) }
    private func data(_ name: String) throws -> Data { try ApplePhysicalDeviceTests.data(name) }

    private func makeClient(_ fake: FakeTool) throws -> DevicectlPhysicalClient {
        try DevicectlPhysicalClient(
            devicectlURL: fake.executableURL,
            device: try ApplePhysicalDeviceTests.device(),
            commandTimeout: .seconds(30)
        )
    }

    /// The whole argv of one call: its three words, `--device <id>
    /// --json-output <temporary file> -q -t <seconds>`, then the command's own
    /// options and operands.
    private func assertArgv(
        _ argv: [String],
        words: [String],
        timeout: Int = 30,
        tail: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(argv.count, 10, "\(argv)", file: file, line: line)
        guard argv.count >= 10 else { return }
        XCTAssertEqual(Array(argv.prefix(3)), words, file: file, line: line)
        XCTAssertEqual(Array(argv[3...5]), ["--device", Self.id, "--json-output"], file: file, line: line)
        XCTAssertTrue(argv[6].hasSuffix(".json"), file: file, line: line)
        XCTAssertEqual(Array(argv[7...9]), ["-q", "-t", String(timeout)], file: file, line: line)
        XCTAssertEqual(Array(argv.dropFirst(10)), tail, file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: argv[6]), "the temporary file is removed", file: file, line: line)
        ApplePhysicalDeviceTests.assertSafeArguments(argv, file: file, line: line)
    }

    // MARK: - Install and uninstall

    func testInstallAppArgvAndResult() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("install app", jsonOutputFile: url("devicectl-install-app.json")),
        ])
        let app = URL(fileURLWithPath: "/tmp/build/DeviceHubProVerifier.app")
        let result = try await makeClient(fake).installApp(at: app).value
        XCTAssertEqual(fake.invocations.count, 1)
        // The install runs under a longer timeout than the default 30 s.
        assertArgv(fake.invocations[0], words: ["device", "install", "app"], timeout: 120, tail: ["/tmp/build/DeviceHubProVerifier.app"])
        XCTAssertEqual(result.deviceIdentifier, Self.id)
        let installed = try XCTUnwrap(result.installedApplications.first)
        XCTAssertEqual(installed.bundleID, Self.verifier)
        XCTAssertEqual(installed.databaseSequenceNumber, 5932)
        XCTAssertEqual(installed.databaseUUID, "AD541610-B7FE-491F-8AEB-468AA26E6C80")
        XCTAssertTrue(installed.installationURL?.hasSuffix("/DeviceHubProVerifier.app/") == true)
        XCTAssertEqual(installed.launchServicesIdentifier, "unknown")
    }

    func testAReinstallKeepsTheBundleAndBumpsTheSequence() throws {
        let first = try DevicectlJSON.decode(DevicectlInstallResult.self, from: try data("devicectl-install-app.json")).value
        let second = try DevicectlJSON.decode(DevicectlInstallResult.self, from: try data("devicectl-install-app-2.json")).value
        XCTAssertEqual(first.installedApplications.first?.bundleID, second.installedApplications.first?.bundleID)
        XCTAssertEqual(first.installedApplications.first?.databaseUUID, second.installedApplications.first?.databaseUUID)
        XCTAssertEqual(second.installedApplications.first?.databaseSequenceNumber, 5940)
        XCTAssertNotEqual(first.installedApplications.first?.installationURL, second.installedApplications.first?.installationURL)
    }

    func testUninstallAppArgvAndResult() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("uninstall app", jsonOutputFile: url("devicectl-uninstall-app.json")),
        ])
        let result = try await makeClient(fake).uninstallApp(bundleID: Self.verifier).value
        assertArgv(fake.invocations[0], words: ["device", "uninstall", "app"], tail: [Self.verifier])
        XCTAssertEqual(result.uninstalledApplications.map(\.bundleID), [Self.verifier])
    }

    /// The captured uninstall of an app that is not installed is a success
    /// with the same body.
    func testUninstallingAMissingAppSucceeds() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("uninstall app", jsonOutputFile: url("devicectl-uninstall-app-missing.json")),
        ])
        let result = try await makeClient(fake).uninstallApp(bundleID: Self.verifier).value
        XCTAssertEqual(result.uninstalledApplications.map(\.bundleID), [Self.verifier])
    }

    // MARK: - Launch, terminate, open URL

    func testLaunchAppWithTerminateExistingArgvAndPid() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("process launch", jsonOutputFile: url("devicectl-process-launch.json")),
        ])
        let result = try await makeClient(fake).launchApp(bundleID: "com.apple.Preferences", terminateExisting: true).value
        assertArgv(
            fake.invocations[0],
            words: ["device", "process", "launch"],
            tail: ["--terminate-existing", "com.apple.Preferences"]
        )
        XCTAssertEqual(result.processIdentifier, 4924)
        XCTAssertEqual(result.process.executable, "file:///Applications/Preferences.app/Preferences")
        XCTAssertEqual(result.launchOptions?.terminateExistingInstances, true)
        XCTAssertEqual(result.launchOptions?.activatedWhenStarted, true)
        XCTAssertEqual(result.launchOptions?.arguments, [])
        XCTAssertEqual(result.launchOptions?.startStopped, false)
    }

    func testLaunchAppWithoutTerminateExistingAndWithArguments() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("process launch", jsonOutputFile: url("devicectl-process-launch-verifier.json")),
        ])
        let result = try await makeClient(fake).launchApp(bundleID: Self.verifier, arguments: ["one", "two words"]).value
        // Options first, then the bundle identifier, then the app's arguments.
        assertArgv(
            fake.invocations[0],
            words: ["device", "process", "launch"],
            tail: [Self.verifier, "one", "two words"]
        )
        XCTAssertEqual(result.processIdentifier, 4951)
        XCTAssertTrue(result.process.executable?.hasSuffix("/DeviceHubProVerifier.app/DeviceHubProVerifier") == true)
    }

    func testLaunchOfAnAppThatIsNotInstalledIsATypedError() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("process launch", jsonOutputFile: url("devicectl-process-launch-missing.json"), exitCode: 1),
        ])
        do {
            _ = try await makeClient(fake).launchApp(bundleID: "com.example.notinstalled")
            XCTFail("expected a launch failure")
        } catch let error as DevicectlPhysicalError {
            XCTAssertEqual(error, .applicationFailedToLaunch(
                message: "The application failed to launch.",
                reason: "The requested application com.example.notinstalled is not installed."
            ))
            XCTAssertTrue(error.description.contains("not installed"))
        }
    }

    func testTheLaunchFailureKeepsItsCodeAndUnderlyingError() throws {
        do {
            _ = try DevicectlJSON.decode(DevicectlLaunchResult.self, from: try data("devicectl-process-launch-missing.json"))
            XCTFail("expected an error")
        } catch let error as DevicectlError {
            XCTAssertEqual(error.code, DevicectlError.Code.applicationFailedToLaunch)
            XCTAssertEqual(error.domain, DevicectlError.coreDeviceDomain)
            XCTAssertTrue(error.contains(code: -10814, domain: "NSOSStatusErrorDomain"))
        }
    }

    func testTerminateArgvAndResult() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("process terminate", jsonOutputFile: url("devicectl-process-terminate.json")),
        ])
        let result = try await makeClient(fake).terminate(pid: 4924).value
        assertArgv(fake.invocations[0], words: ["device", "process", "terminate"], tail: ["--pid", "4924"])
        XCTAssertEqual(result.process.processIdentifier, 4924)
        XCTAssertEqual(result.signal?.name, "SIGTERM")
        XCTAssertEqual(result.signal?.value, 15)
        XCTAssertEqual(result.deviceTimestamp, "2026-09-28T21:45:37.805Z")
    }

    func testTerminatingAPidThatIsGoneIsATypedError() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("process terminate", jsonOutputFile: url("devicectl-process-terminate-nopid.json"), exitCode: 1),
        ])
        do {
            _ = try await makeClient(fake).terminate(pid: 999_999)
            XCTFail("expected a signal failure")
        } catch let error as DevicectlPhysicalError {
            XCTAssertEqual(error, .failedToSendSignal(
                message: "Failed to send signal 15 to process 999,999.",
                reason: "No such process; the process may have already terminated."
            ))
        }
    }

    func testOpenURLArgvAndResult() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("process openURL", jsonOutputFile: url("devicectl-process-openURL.json")),
        ])
        let result = try await makeClient(fake).openURL(try XCTUnwrap(URL(string: "https://example.com"))).value
        assertArgv(fake.invocations[0], words: ["device", "process", "openURL"], tail: ["https://example.com"])
        XCTAssertEqual(result.url, "https://example.com")
        XCTAssertEqual(result.process?.processIdentifier, 4925)
    }

    // MARK: - Screenshot and screen recording

    func testScreenshotArgvAndResult() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("capture screenshot", jsonOutputFile: url("devicectl-capture-screenshot.json")),
        ])
        let destination = URL(fileURLWithPath: "/tmp/shots/phone.png")
        let result = try await makeClient(fake).screenshot(to: destination).value
        assertArgv(
            fake.invocations[0],
            words: ["device", "capture", "screenshot"],
            tail: ["--destination", "/tmp/shots/phone.png"]
        )
        XCTAssertEqual(result.imageFormat, "png")
        XCTAssertEqual(result.width, 1170)
        XCTAssertEqual(result.height, 2532)
        XCTAssertTrue(result.destination?.hasPrefix("file:///") == true)
    }

    func testScreenshotNeedsAPNGDestination() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [])
        do {
            _ = try await makeClient(fake).screenshot(to: URL(fileURLWithPath: "/tmp/phone.jpg"))
            XCTFail("expected a refusal")
        } catch let error as DevicectlClientError {
            XCTAssertEqual(error, .refusedCommand("device capture screenshot --destination /tmp/phone.jpg"))
        }
        XCTAssertEqual(fake.calls, [])
    }

    /// The iPhone 12 on iOS 27 answers 1001 with the screen recording feature.
    func testScreenRecordArgvAndTheUnsupportedCapability() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("capture screen-record", jsonOutputFile: url("devicectl-capture-screen-record.json"), exitCode: 1),
        ])
        do {
            _ = try await makeClient(fake).screenRecord(to: URL(fileURLWithPath: "/tmp/rec.mp4"), duration: .seconds(3))
            XCTFail("expected an unsupported capability")
        } catch let error as DevicectlPhysicalError {
            XCTAssertEqual(error, .unsupportedCapability(
                featureIdentifier: "com.apple.coredevice.feature.screenrecording",
                name: "Screen Recording"
            ))
        }
        // The command timeout covers the recording: 30 s plus the 3 s.
        assertArgv(
            fake.invocations[0],
            words: ["device", "capture", "screen-record"],
            timeout: 33,
            tail: ["--destination", "/tmp/rec.mp4", "--duration", "3"]
        )
    }

    func testScreenRecordNeedsAnMP4DestinationAndADuration() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [])
        let client = try makeClient(fake)
        for destination in ["/tmp/rec.mov", "/tmp/rec"] {
            do {
                _ = try await client.screenRecord(to: URL(fileURLWithPath: destination), duration: .seconds(3))
                XCTFail("\(destination) must be refused")
            } catch is DevicectlClientError {}
        }
        // Less than a second rounds up to one.
        XCTAssertNoThrow(try DevicectlPhysicalClient.validate(
            ["device", "capture", "screen-record", "--destination", "/tmp/rec.mp4", "--duration", "1"]
        ))
        XCTAssertEqual(fake.calls, [])
    }

    // MARK: - Files

    func testListFilesOfTheVerifierContainer() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("info files", jsonOutputFile: url("devicectl-info-files-verifier.json")),
        ])
        let list = try await makeClient(fake).listFiles(domain: .appDataContainer(bundleID: Self.verifier)).value
        assertArgv(
            fake.invocations[0],
            words: ["device", "info", "files"],
            tail: ["--domain-type", "appDataContainer", "--domain-identifier", Self.verifier]
        )
        XCTAssertEqual(list.domain, "appDataContainer")
        XCTAssertEqual(list.domainIdentifier, Self.verifier)
        XCTAssertEqual(list.files.count, 22)
        let documents = try XCTUnwrap(list.files.first { $0.relativePath == "Documents" })
        XCTAssertTrue(documents.isDirectory)
        let readings = try XCTUnwrap(list.files.first { $0.relativePath == "Documents/readings.json" })
        XCTAssertFalse(readings.isDirectory)
        XCTAssertEqual(readings.metadata?.size, 4724)
        XCTAssertEqual(readings.metadata?.permissions, 420)
        XCTAssertEqual(readings.metadata?.lastModDate, "2026-09-28T21:47:12.000Z")
        XCTAssertEqual(readings.resources?.isReadable, true)
    }

    func testListFilesOfTheSystemCrashLogs() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("info files", jsonOutputFile: url("devicectl-info-files-crashlogs.json")),
        ])
        let list = try await makeClient(fake).listFiles(domain: .systemCrashLogs).value
        // No domain identifier for the system domain.
        assertArgv(
            fake.invocations[0],
            words: ["device", "info", "files"],
            tail: ["--domain-type", "systemCrashLogs"]
        )
        XCTAssertEqual(list.domain, "systemCrashLogs")
        XCTAssertNil(list.domainIdentifier)
        XCTAssertEqual(list.files.count, 417)
        XCTAssertTrue(list.files.contains { $0.relativePath.hasPrefix("Retired/JetsamEvent-") })
        XCTAssertTrue(list.files.allSatisfy { !$0.relativePath.isEmpty })
    }

    func testCopyFromTheVerifierContainerArgvAndResult() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("copy from", jsonOutputFile: url("devicectl-copy-from-readings.json")),
        ])
        let destination = URL(fileURLWithPath: "/tmp/out/readings.json")
        let result = try await makeClient(fake).copyFrom(
            domain: .appDataContainer(bundleID: Self.verifier),
            source: "Documents/readings.json",
            to: destination
        ).value
        assertArgv(
            fake.invocations[0],
            words: ["device", "copy", "from"],
            tail: [
                "--domain-type", "appDataContainer", "--domain-identifier", Self.verifier,
                "--source", "Documents/readings.json", "--destination", "/tmp/out/readings.json",
            ]
        )
        XCTAssertEqual(result.domain, "appDataContainer")
        XCTAssertEqual(result.domainIdentifier, Self.verifier)
        XCTAssertEqual(result.source, "Documents/readings.json")
    }

    /// Send Files: `copy to` into an app's data
    /// container, one fixed shape. HELP-DERIVED (Xcode 27.0 27A266a, `devicectl device
    /// copy to -h`); the reply is the `copy from` capture's shape (no capture of a `copy
    /// to` exists, none is ever taken against a real device by a test).
    func testCopyToAnAppContainerArgv() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("copy to", jsonOutputFile: url("devicectl-copy-from-readings.json")),
        ])
        _ = try await makeClient(fake).copyTo(
            source: URL(fileURLWithPath: "/tmp/out/test data.json"),
            bundleID: Self.verifier,
            destination: "Documents/test data.json"
        )
        assertArgv(
            fake.invocations[0],
            words: ["device", "copy", "to"],
            timeout: 120,
            tail: [
                "--domain-type", "appDataContainer", "--domain-identifier", Self.verifier,
                "--source", "/tmp/out/test data.json", "--destination", "Documents/test data.json",
            ]
        )
    }

    func testCopyToRefusesEveryOtherShape() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [])
        let client = try makeClient(fake)
        let id = Self.verifier
        let refused: [[String]] = [
            // Another domain, no domain, a crash-log domain.
            ["device", "copy", "to", "--domain-type", "systemCrashLogs", "--source", "/tmp/a", "--destination", "x"],
            ["device", "copy", "to", "--domain-type", "appGroupDataContainer", "--domain-identifier", id, "--source", "/tmp/a", "--destination", "x"],
            ["device", "copy", "to", "--domain-type", "temporary", "--domain-identifier", id, "--source", "/tmp/a", "--destination", "x"],
            ["device", "copy", "to", "--source", "/tmp/a", "--destination", "x"],
            // A destination that leaves the container, or is an option.
            ["device", "copy", "to", "--domain-type", "appDataContainer", "--domain-identifier", id, "--source", "/tmp/a", "--destination", "../x"],
            ["device", "copy", "to", "--domain-type", "appDataContainer", "--domain-identifier", id, "--source", "/tmp/a", "--destination", "/etc/x"],
            ["device", "copy", "to", "--domain-type", "appDataContainer", "--domain-identifier", id, "--source", "/tmp/a", "--destination", "--user"],
            // A source that is an option, an extra flag, a second source, the removal flag.
            ["device", "copy", "to", "--domain-type", "appDataContainer", "--domain-identifier", id, "--source", "-x", "--destination", "Documents/x"],
            ["device", "copy", "to", "--domain-type", "appDataContainer", "--domain-identifier", id, "--source", "/tmp/a", "--destination", "Documents/x", "--remove-existing-content", "true"],
            ["device", "copy", "to", "--domain-type", "appDataContainer", "--domain-identifier", id, "--source", "/tmp/a", "--source", "/tmp/b", "--destination", "Documents/x"],
            // A bad bundle identifier.
            ["device", "copy", "to", "--domain-type", "appDataContainer", "--domain-identifier", "bad id", "--source", "/tmp/a", "--destination", "Documents/x"],
        ]
        for command in refused {
            do {
                _ = try await client.run(command, as: DevicectlCopyResult.self)
                XCTFail("\(command) must be refused")
            } catch let error as DevicectlClientError {
                XCTAssertEqual(error, .refusedCommand(command.joined(separator: " ")))
            }
        }
        XCTAssertEqual(fake.calls, [], "devicectl never ran")
    }

    func testCopyFromTheCrashLogsHasNoDomainIdentifier() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("copy from", jsonOutputFile: url("devicectl-copy-from-readings.json")),
        ])
        _ = try await makeClient(fake).copyFrom(
            domain: .systemCrashLogs,
            source: "Retired/JetsamEvent-2026-09-24-091507.ips",
            to: URL(fileURLWithPath: "/tmp/out/crash.ips")
        )
        assertArgv(
            fake.invocations[0],
            words: ["device", "copy", "from"],
            tail: [
                "--domain-type", "systemCrashLogs",
                "--source", "Retired/JetsamEvent-2026-09-24-091507.ips", "--destination", "/tmp/out/crash.ips",
            ]
        )
    }

    // MARK: - Decoding the other captures

    func testTheAppListAfterTheInstallDecodesTheFirstRealApp() async throws {
        let apps = try DevicectlJSON.decode(DevicectlAppList.self, from: try data("devicectl-info-apps-after-install.json")).value
        XCTAssertEqual(apps.deviceIdentifier, Self.id)
        XCTAssertEqual(apps.apps.count, 1)
        XCTAssertEqual(apps.apps.first, DevicectlInstalledApp(
            bundleIdentifier: Self.verifier,
            name: "AQA Verifier",
            version: "1.0",
            bundleVersion: "1",
            url: "file:///private/var/containers/Bundle/Application/99A596BC-82D8-4C65-BBD0-944CE7560FDE/DeviceHubProVerifier.app/",
            appClip: false,
            builtByDeveloper: true,
            containerAccessible: true,
            defaultApp: false,
            hidden: false,
            internalApp: false,
            removable: true
        ))
        XCTAssertEqual(apps.defaultAppsIncluded, false)
        XCTAssertEqual(apps.removableAppsIncluded, true)

        // And through the client.
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("info apps", jsonOutputFile: url("devicectl-info-apps-after-install.json")),
        ])
        let viaClient = try await makeClient(fake).apps().value
        XCTAssertEqual(viaClient.apps.map(\.bundleIdentifier), [Self.verifier])
    }

    /// The verifier's readings, copied off the phone, decode with the same
    /// reader the simulator round trip uses.
    func testTheReadingsCopiedFromThePhoneDecode() throws {
        let document = try JSONDecoder().decode(VerifierReader.Document.self, from: try data("verifier-readings.json"))
        XCTAssertEqual(document.schema, 1)
        XCTAssertEqual(document.system, "iOS 27.0 · iPhone")
        XCTAssertEqual(document.rows.count, 23)
        XCTAssertEqual(document.rows["display.appearance"]?.raw, "light")
        XCTAssertEqual(document.rows["sensors.orientation"]?.raw, "portrait")
        XCTAssertEqual(document.rows["sensors.orientation"]?.changes, 1)
        // The file the container listing reports is this file's size.
        let list = try DevicectlJSON.decode(DevicectlFileList.self, from: try data("devicectl-info-files-verifier.json")).value
        let listed = try XCTUnwrap(list.files.first { $0.relativePath == "Documents/readings.json" })
        XCTAssertEqual(listed.metadata?.size, try data("verifier-readings.json").count)
    }

    // MARK: - The gate

    /// The exact allow-list: the nine reads, the ten actions (`info appIcon` among them), the nine
    /// Controls commands (`ApplePhysicalControlsTests`) and the five management
    /// commands (`ApplePhysicalManagementTests`), and no other command.
    func testTheAllowListIsExact() {
        XCTAssertEqual(DevicectlPhysicalClient.allowedCommandWords, [
            ["device", "info", "details"],
            ["device", "info", "apps"],
            ["device", "info", "processes"],
            ["device", "info", "displays"],
            ["device", "info", "lockState"],
            ["device", "info", "appearance"],
            ["device", "info", "voiceover"],
            ["device", "info", "ddiServices"],
            ["device", "info", "audio"],
            ["device", "info", "files"],
            ["device", "install", "app"],
            ["device", "uninstall", "app"],
            ["device", "process", "launch"],
            ["device", "process", "terminate"],
            ["device", "process", "openURL"],
            ["device", "capture", "screenshot"],
            ["device", "capture", "screen-record"],
            ["device", "copy", "from"],
            ["device", "copy", "to"],
            ["device", "info", "appIcon"],
            ["device", "settings", "appearance"],
            ["device", "settings", "voiceover"],
            ["device", "orientation", "get"],
            ["device", "orientation", "set"],
            ["device", "simulate", "location", "coordinate"],
            ["device", "simulate", "location", "clear"],
            ["device", "process", "sendMemoryWarning"],
            ["device", "pasteboard", "copy"],
            ["device", "pasteboard", "paste"],
            ["device", "reboot"],
            ["device", "rename"],
            ["device", "sysdiagnose"],
            ["manage", "unpair"],
            ["manage", "pair"],
            // The log pane's console launch: the
            // ordinary launch's words with `--console`, in one fixed shape
            // (`PhysicalConsoleLogTests`).
            ["device", "process", "launch", "--console"],
        ])
    }

    func testTheRefusalListNamesEveryStillRefusedSubcommand() {
        let expected: Set<String> = [
            "list", "manage", "pair", "pairings", "reset", "settings", "profile",
            "notification", "simulate", "orientation", "pasteboard", "motion", "appResize",
        ]
        XCTAssertEqual(DevicectlPhysicalClient.refusedCommands, expected)
    }

    /// Every shape outside the allow-list is refused before devicectl runs,
    /// including the writing subcommands the physical client still must not
    /// reach and every allowed action with a malformed operand.
    func testRefusalsNeverReachDevicectl() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [])
        let client = try makeClient(fake)
        let refused: [[String]] = [
            ["list", "devices"],
            ["device", "list", "devices"],
            ["manage", "pair", "--columns", "*"],
            ["manage", "ddis", "list"],
            ["device", "pair"],
            ["device", "unpair"],
            ["device", "pairings", "list"],
            ["device", "reset"],
            ["device", "settings", "biometrics"],
            ["device", "reboot", "--style", "userspace"],
            ["device", "rename", "x"],
            ["device", "profile", "install"],
            ["device", "sysdiagnose"],
            ["device", "copy", "to"],
            ["device", "notification", "post"],
            ["device", "simulate", "location"],
            ["device", "orientation", "set"],
            ["device", "pasteboard", "set"],
            ["device", "motion", "monitor"],
            ["device", "appResize", "start"],
            ["device", "info", "unknownThing"],
            ["device", "info", "details", "extra"],
            ["device", "info"],
            ["device", "process", "attach", "--pid", "1"],
            ["device", "process", "sendSignal", "--pid", "1"],
            ["device", "process", "suspend"],
            [],
            // Allowed subcommands, malformed operands.
            ["device", "install", "app"],
            ["device", "install", "app", "--help"],
            ["device", "install", "app", "/a.app", "/b.app"],
            ["device", "uninstall", "app"],
            ["device", "uninstall", "app", "-x"],
            ["device", "uninstall", "app", "com.a b"],
            ["device", "process", "launch"],
            ["device", "process", "launch", "--console", Self.verifier],
            ["device", "process", "launch", "--start-stopped", Self.verifier],
            ["device", "process", "launch", Self.verifier, "--console"],
            ["device", "process", "launch", "--terminate-existing"],
            ["device", "process", "terminate", "--pid", "0"],
            ["device", "process", "terminate", "--pid", "-3"],
            ["device", "process", "terminate", "--pid", "abc"],
            ["device", "process", "terminate", "--all"],
            ["device", "process", "openURL", "no-scheme"],
            ["device", "process", "openURL", "--help"],
            ["device", "capture", "screenshot", "--destination", "/tmp/a.tiff"],
            ["device", "capture", "screenshot", "--destination", "-.png"],
            ["device", "capture", "screen-record", "--destination", "/tmp/a.mp4"],
            ["device", "capture", "screen-record", "--destination", "/tmp/a.mp4", "--duration", "0"],
            ["device", "capture", "screen-record", "--destination", "/tmp/a.mp4", "--duration", "-1"],
            ["device", "info", "files"],
            ["device", "info", "files", "--domain-type", "appDataContainer"],
            ["device", "info", "files", "--domain-type", "systemCrashLogs", "--domain-identifier", Self.verifier],
            ["device", "info", "files", "--domain-type", "appGroupDataContainer", "--domain-identifier", Self.verifier],
            ["device", "info", "files", "--domain-type", "systemCrashLogs", "--recursive"],
            ["device", "copy", "from"],
            ["device", "copy", "from", "--domain-type", "systemCrashLogs", "--source", "../x", "--destination", "/tmp/x"],
            ["device", "copy", "from", "--domain-type", "systemCrashLogs", "--source", "/private/x", "--destination", "/tmp/x"],
            ["device", "copy", "from", "--domain-type", "systemCrashLogs", "--source", "a", "--destination", "-x"],
            ["device", "copy", "from", "--domain-type", "systemCrashLogs", "--domain-identifier", Self.verifier,
             "--source", "a", "--destination", "/tmp/x"],
        ]
        for command in refused {
            do {
                _ = try await client.run(command, as: DevicectlIgnoredResult.self)
                XCTFail("\(command) must be refused")
            } catch let error as DevicectlClientError {
                XCTAssertEqual(error, .refusedCommand(command.joined(separator: " ")), "\(command)")
            }
        }
        XCTAssertEqual(fake.calls, [], "devicectl never ran")
    }

    /// The typed API refuses malformed values before devicectl runs, too.
    func testTheTypedCallsRefuseMalformedValues() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [])
        let client = try makeClient(fake)
        func expectRefusal(_ label: String, _ call: () async throws -> Void) async {
            do {
                try await call()
                XCTFail("\(label) must be refused")
            } catch is DevicectlClientError {
            } catch {
                XCTFail("\(label): \(error)")
            }
        }
        await expectRefusal("bundle") { _ = try await client.uninstallApp(bundleID: "--all") }
        await expectRefusal("launch bundle") { _ = try await client.launchApp(bundleID: "") }
        await expectRefusal("launch argument") {
            _ = try await client.launchApp(bundleID: Self.verifier, arguments: ["--console"])
        }
        await expectRefusal("pid") { _ = try await client.terminate(pid: 0) }
        await expectRefusal("domain") { _ = try await client.listFiles(domain: .appDataContainer(bundleID: "-a")) }
        await expectRefusal("source") {
            _ = try await client.copyFrom(domain: .systemCrashLogs, source: "../../x", to: URL(fileURLWithPath: "/tmp/x"))
        }
        XCTAssertEqual(fake.calls, [])
    }

    /// A refused word inside the three subcommand words is refused, but the
    /// same word as an operand (an app argument, a file name) is not.
    func testRefusedWordsAreOnlyRefusedAsSubcommandWords() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("process launch", jsonOutputFile: url("devicectl-process-launch-verifier.json")),
        ])
        _ = try await makeClient(fake).launchApp(bundleID: Self.verifier, arguments: ["list", "reset", "settings"])
        assertArgv(
            fake.invocations[0],
            words: ["device", "process", "launch"],
            tail: [Self.verifier, "list", "reset", "settings"]
        )
    }

    /// A CoreDevice error the client does not type stays a `DevicectlError`.
    func testAnUntypedCoreDeviceErrorPassesThrough() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("process terminate", jsonOutputFile: url("devicectl-process-launch-missing.json"), exitCode: 1),
        ])
        // The launch failure decoded as a terminate answer is still typed by
        // code, whatever command produced it...
        do {
            _ = try await makeClient(fake).terminate(pid: 5)
            XCTFail("expected an error")
        } catch let error as DevicectlPhysicalError {
            guard case .applicationFailedToLaunch = error else { return XCTFail("\(error)") }
        }
        // ...while a code outside the typed set is passed through.
        let untyped = DevicectlError(info: nil, frames: [
            DevicectlErrorFrame(domain: DevicectlError.coreDeviceDomain, code: 1000, message: "not found"),
        ])
        XCTAssertNil(DevicectlPhysicalClient.typed(untyped))
        let otherDomain = DevicectlError(info: nil, frames: [
            DevicectlErrorFrame(domain: "NSPOSIXErrorDomain", code: 10014, message: "x"),
        ])
        XCTAssertNil(DevicectlPhysicalClient.typed(otherDomain))
    }
}
