import XCTest
@testable import DeviceHubProKit

/// The collection, against a Mac made of a temporary folder (see
/// `HermeticReportWorld`): the recorded `ps` of a Mac with an adb server and a
/// running emulator (`api37-emulator/adb-core`), the real answers of
/// `adb devices -l`, `adb emu avd name` and `getprop`, the SDK packages of this
/// Mac and the AVD an old avdmanager wrote (`emulator-start/old-cmdline-tools-api37`).
///
/// The recorded emulator is `Pixel_9_Pro_Fold` on emulator-5554, while the
/// `getprop` capture (`problem-report/`) was taken on another emulator: the tests
/// check what the collector keeps of each answer, not that they agree.
final class ProblemReportCollectorTests: XCTestCase {
    private func world(adbRules: [FakeTool.Rule]? = nil) throws -> HermeticReportWorld {
        try HermeticReportWorld(adbRules: adbRules)
    }

    // MARK: A whole collection

    func testTheRunningEmulatorIsReadFromTheProcessListAdbAndTheDiscoveryFile() async throws {
        let world = try world()
        let collected = await world.collect(try world.inputs())
        let android = collected.report.android

        XCTAssertEqual(android.runningEmulators.count, 1)
        let emulator = try XCTUnwrap(android.runningEmulators.first)
        XCTAssertEqual(emulator.avd, "Pixel_9_Pro_Fold")
        XCTAssertEqual(emulator.serial, "emulator-5554")
        XCTAssertEqual(emulator.consolePort, 5554)
        XCTAssertEqual(emulator.grpcPort, 8554)
        XCTAssertTrue(emulator.processAlive)
        XCTAssertEqual(emulator.adbState, "device")
        XCTAssertEqual(emulator.flags, ["-grpc", "-gpu host", "-qt-hide-window", "-no-boot-anim"])
        XCTAssertFalse(emulator.startedByDeviceHubPro, "the recorded VM has no -grpc-use-token")

        let discovery = try XCTUnwrap(emulator.discovery)
        XCTAssertTrue(discovery.found)
        XCTAssertEqual(discovery.emulatorVersion, "37.2.8.0")
        XCTAssertEqual(discovery.avdID, "Pixel_9_Pro_Fold")
        XCTAssertEqual(discovery.grpcPort, 8554)
        XCTAssertFalse(discovery.hasGrpcToken, "the recorded discovery file carries no token")

        XCTAssertEqual(emulator.console.outcome, .answered)
        XCTAssertEqual(emulator.console.name, "Pixel_9_Pro_Fold")
        XCTAssertEqual(emulator.console.stdoutBytes, 22, "\"Pixel_9_Pro_Fold\\r\\nOK\\r\\n\"")
        XCTAssertEqual(emulator.guestAvdName.outcome, .answered)
        XCTAssertEqual(emulator.guestAvdName.value, "DHP_ConsoleCapture", "the value of the getprop capture")
        XCTAssertEqual(emulator.bootCompleted.outcome, .answered)
        XCTAssertEqual(emulator.bootCompleted.value, "1")
    }

    func testPhonesAreAliasedAndNeverAsked() async throws {
        let world = try world()
        let collected = await world.collect(try world.inputs())
        let android = collected.report.android

        XCTAssertEqual(android.devicesSource, "adb devices -l")
        XCTAssertEqual(android.phones.count, 1)
        let phone = try XCTUnwrap(android.phones.first)
        XCTAssertEqual(phone.alias, "phone-1")
        XCTAssertEqual(phone.transports, ["usb"])
        XCTAssertEqual(phone.model, "2209116AG")
        XCTAssertEqual(phone.state, "device")
        XCTAssertNil(phone.androidVersion, "a phone is never asked its version")
        XCTAssertEqual(collected.privateIdentifiers["0a1b2c3d4e5f"], "phone-1")
        let json = try collected.report.jsonText()
        XCTAssertFalse(json.lowercased().contains("0a1b2c3d4e5f"), "the serial is in the identifier table, not the report")
    }

    func testTheAvdAnOldAvdmanagerWroteIsRecognised() async throws {
        let world = try world()
        let collected = await world.collect(try world.inputs())
        let avd = try XCTUnwrap(collected.report.android.avds.first { $0.name == "Pixel_8_Pro_old" })
        XCTAssertEqual(avd.target, "android-0")
        XCTAssertNil(avd.configTarget)
        XCTAssertEqual(avd.imageSysdir, "system-images/android-37.0/google_apis/arm64-v8a/")
        XCTAssertEqual(avd.imageAPI, "37.0")
        XCTAssertEqual(avd.abi, "arm64-v8a")
        XCTAssertEqual(avd.tag, "google_apis")
        XCTAssertEqual(avd.device, "pixel_8_pro")
        XCTAssertEqual(avd.image, .incomplete, "the fixture holds only the image's source.properties")
        XCTAssertEqual(avd.preflightProblem, EmulatorStartFailure.missingSystemImage)
        XCTAssertEqual(avd.contentFolder, .missing, "its registry entry names /Volumes/DevData/..., which is not here")
        XCTAssertFalse(avd.running)
        XCTAssertFalse(avd.quickBootSnapshot)
        XCTAssertEqual(collected.report.android.avdHome.avdCount, 1)
    }

    func testTheSdkAndTheAdbServerAreDescribed() async throws {
        let world = try world()
        let collected = await world.collect(try world.inputs())
        let android = collected.report.android

        // The default root and the emulator's are one folder; the fake adb sits
        // in a folder of its own, which is a root of its own.
        XCTAssertEqual(android.sdkRoots.count, 2)
        let root = try XCTUnwrap(android.sdkRoots.first { $0.foundBy.contains("default") })
        XCTAssertEqual(root.foundBy, ["default", "emulator"])
        XCTAssertTrue(root.exists)
        XCTAssertEqual(root.platformTools, "37.0.0")
        XCTAssertEqual(root.emulator, "36.6.11")
        XCTAssertEqual(root.cmdlineTools, [ProblemReport.CmdlineTools(folder: "latest", version: "22.0")])
        XCTAssertEqual(root.systemImages, 1)
        XCTAssertTrue(root.foundBy.contains("default"))

        XCTAssertEqual(android.adb.version, "37.0.0")
        XCTAssertEqual(android.emulator?.version, "36.6.11")
        XCTAssertEqual(android.emulator?.build, "15507667")
        let server = android.adb.server
        XCTAssertTrue(server.running)
        XCTAssertEqual(server.port, "5037")
        XCTAssertEqual(server.sameAsApp, true)
        XCTAssertTrue(server.queried)
        XCTAssertNil(server.notQueriedBecause)
        XCTAssertEqual(server.version, "37.0.0")
    }

    func testOnlyTheFourAllowedAdbCallsAreMade() async throws {
        let world = try world()
        _ = await world.collect(try world.inputs())
        let calls = world.adb.invocations
        let allowed: Set<[String]> = [
            ["devices", "-l"],
            ["-s", "emulator-5554", "emu", "avd", "name"],
            ["-s", "emulator-5554", "shell", "getprop", "ro.boot.qemu.avd_name"],
            ["-s", "emulator-5554", "shell", "getprop", "sys.boot_completed"],
        ]
        XCTAssertEqual(Set(calls), allowed)
        XCTAssertEqual(calls.count, 4)
        let text = world.adb.calls.joined(separator: "\n").lowercased()
        XCTAssertFalse(text.contains("0a1b2c3d4e5f"), "no call names the phone")
        XCTAssertFalse(text.contains("kill-server"))
        XCTAssertFalse(text.contains("start-server"))
    }

    /// The collection writes nothing: not a file, not a folder (the app's log
    /// folder stays absent when the app never made it).
    func testNothingIsCreatedOrChanged() async throws {
        let world = try world()
        let before = world.listing()
        _ = await world.collect(try world.inputs())
        XCTAssertEqual(world.listing(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.home.appendingPathComponent("Library/Logs/DeviceHubPro").path))
    }

    // MARK: The adb server guard

    func testWithoutAnAdbServerNothingIsAsked() async throws {
        let world = try world()
        let withoutServer = try HermeticReportWorld.recordedProcessList()
            .split(separator: "\n").filter { !$0.contains("fork-server") }.joined(separator: "\n")
        let collected = await world.collect(try world.inputs(processList: withoutServer))
        XCTAssertEqual(world.adb.invocations, [])
        let server = collected.report.android.adb.server
        XCTAssertFalse(server.running)
        XCTAssertFalse(server.queried)
        XCTAssertEqual(server.notQueriedBecause, "No adb server is running; the report doesn\u{2019}t start one.")
        XCTAssertTrue(collected.report.android.devicesSource.hasPrefix("not read: No adb server is running"))
        let emulator = try XCTUnwrap(collected.report.android.runningEmulators.first)
        XCTAssertEqual(emulator.console.outcome, .skipped)
        XCTAssertNil(emulator.adbState)
    }

    func testAnotherAdbsServerIsNotAskedWhenTheVersionsDiffer() async throws {
        let world = try world()
        let other = try FakeTool(name: "adb", rules: [])
        try "Pkg.Revision=36.0.0\n".write(
            to: other.directory.appendingPathComponent("source.properties"), atomically: true, encoding: .utf8
        )
        let collected = await world.collect(try world.inputs(serverPath: other.executableURL.path))
        XCTAssertEqual(world.adb.invocations, [])
        XCTAssertEqual(other.invocations, [])
        let server = collected.report.android.adb.server
        XCTAssertTrue(server.running)
        XCTAssertEqual(server.sameAsApp, false)
        XCTAssertEqual(server.version, "36.0.0")
        XCTAssertFalse(server.queried)
        XCTAssertEqual(
            server.notQueriedBecause,
            "The running adb server is another adb (36.0.0); asking it from this adb (37.0.0) could restart it."
        )
    }

    func testAnotherAdbOfTheSameVersionMayBeAsked() async throws {
        let world = try world()
        let other = try FakeTool(name: "adb", rules: [])
        try "Pkg.Revision=37.0.0\n".write(
            to: other.directory.appendingPathComponent("source.properties"), atomically: true, encoding: .utf8
        )
        let collected = await world.collect(try world.inputs(serverPath: other.executableURL.path))
        let server = collected.report.android.adb.server
        XCTAssertEqual(server.sameAsApp, false)
        XCTAssertTrue(server.queried, "the same version does not restart a server")
        XCTAssertFalse(world.adb.invocations.isEmpty)
    }

    func testAnUnreadableServerExecutableIsNotAsked() async throws {
        let world = try world()
        var inputs = try world.inputs()
        inputs.processPath = { _ in nil }
        let collected = await world.collect(inputs)
        XCTAssertEqual(world.adb.invocations, [])
        XCTAssertEqual(collected.report.android.adb.server.notQueriedBecause, "Couldn\u{2019}t read which adb runs the server.")
    }

    func testNoAdbMeansNoCalls() async throws {
        let world = try world()
        var inputs = try world.inputs()
        inputs.runsAdb = false
        let collected = await world.collect(inputs)
        XCTAssertEqual(world.adb.invocations, [])
        XCTAssertFalse(collected.report.android.adb.server.queried)
    }

    /// The recorded `ps` with its server (`adb -L tcp:5037 fork-server`) moved to another port: the
    /// adb that would be asked talks to 5037, finds none and would start one.
    func testAServerOnAnotherPortThanTheOneAdbUsesIsNotAsked() async throws {
        let world = try world()
        let moved = try HermeticReportWorld.recordedProcessList().replacingOccurrences(of: "-L tcp:5037", with: "-L tcp:5038")
        XCTAssertTrue(moved.contains("-L tcp:5038"))
        let collected = await world.collect(try world.inputs(processList: moved))
        XCTAssertEqual(world.adb.invocations, [], "nothing is asked, so no adb client starts a server on 5037")
        let server = collected.report.android.adb.server
        XCTAssertTrue(server.running, "the server that runs is still reported")
        XCTAssertEqual(server.port, "5038")
        XCTAssertFalse(server.queried)
        XCTAssertEqual(server.notQueriedBecause, "No adb server is running on port 5037; the report doesn\u{2019}t start one.")
        XCTAssertTrue(collected.report.android.devicesSource.hasPrefix("not read: No adb server is running on port 5037"))
        XCTAssertEqual(collected.report.android.runningEmulators.first?.console.outcome, .skipped)

        // The port the environment names is the one that counts.
        var inputs = try world.inputs(processList: moved)
        let environment = ["PATH": "/x", "ANDROID_ADB_SERVER_PORT": "5038"]
        inputs.environment = { environment }
        let named = await world.collect(inputs)
        XCTAssertTrue(named.report.android.adb.server.queried)
        XCTAssertFalse(world.adb.invocations.isEmpty)
    }

    func testARedirectedAdbIsNotAsked() async throws {
        let world = try world()
        var inputs = try world.inputs()
        let environment = ["PATH": "/x", "ADB_SERVER_SOCKET": "tcp:build-host:5037"]
        inputs.environment = { environment }
        let collected = await world.collect(inputs)
        XCTAssertEqual(world.adb.invocations, [])
        XCTAssertEqual(
            collected.report.android.adb.server.notQueriedBecause,
            "ADB_SERVER_SOCKET sends adb to another server; the report doesn\u{2019}t ask it."
        )
        var empty = try world.inputs()
        let blank = ["PATH": "/x", "ADB_SERVER_SOCKET": ""]
        empty.environment = { blank }
        let unset = await world.collect(empty)
        XCTAssertTrue(unset.report.android.adb.server.queried, "an empty value redirects nothing")
    }

    // MARK: With the app's snapshot

    func testAnAppSnapshotSuppliesTheDevicesAndAdbIsNotAskedForThem() async throws {
        let world = try world()
        let state = ProblemReportAppState(
            devices: [
                AndroidDevice(serial: "emulator-5554", state: "device"),
                AndroidDevice(serial: "0a1b2c3d4e5f", state: "device", model: "2209116AG", device: "sweet",
                              hardwareSerial: "0A1B2C3D4E5F60718", alternateSerials: ["192.168.1.5:5555"]),
            ],
            androidVersions: ["0a1b2c3d4e5f": "14"],
            consoleNames: ["emulator-5554": "Pixel_9_Pro_Fold"],
            emulatorListAvds: ["Pixel_8_Pro_old"],
            preferences: .sample
        )
        let collected = await world.collect(try world.inputs(producer: .app), appState: state)
        let android = collected.report.android
        XCTAssertEqual(android.devicesSource, "app inventory")
        XCTAssertFalse(world.adb.invocations.contains(["devices", "-l"]))
        XCTAssertEqual(world.adb.invocations.count, 3, "the console and the two getprops of the one emulator")

        let phone = try XCTUnwrap(android.phones.first)
        XCTAssertEqual(phone.androidVersion, "14")
        XCTAssertEqual(phone.transports, ["usb", "wifi"])
        XCTAssertEqual(collected.privateIdentifiers["0A1B2C3D4E5F60718"], "phone-1")
        XCTAssertEqual(collected.privateIdentifiers["192.168.1.5:5555"], "phone-1")

        XCTAssertEqual(android.emulatorListsAvds, ["Pixel_8_Pro_old"])
        XCTAssertEqual(android.avds.first?.listedByEmulator, true)
        XCTAssertEqual(android.appAdb?.consoleNames, ["emulator-5554 \u{2192} Pixel_9_Pro_Fold"])
        XCTAssertEqual(collected.report.app.preferences, .sample)
    }

    // MARK: The pure parts

    func testConsoleAnswersAreClassified() throws {
        let core = "api37-emulator/adb-core"
        let answered = ProblemReportCollector.classifyConsole(
            exitCode: 0, stdout: try ProblemReportFixtures.data("\(core)/emu-avd-name.txt"), stderr: ""
        )
        XCTAssertEqual(answered.outcome, .answered)
        XCTAssertEqual(answered.name, "Pixel_9_Pro_Fold")
        XCTAssertEqual(answered.sawOK, true)

        // The usage error of another console command: one line that
        // AdbParsing.avdName would read as a name.
        let usage = ProblemReportCollector.classifyConsole(
            exitCode: 0, stdout: try ProblemReportFixtures.data("\(core)/emu-resize-display.txt"), stderr: ""
        )
        XCTAssertEqual(usage.outcome, .ko)
        XCTAssertNil(usage.name)

        // An emulator whose console printed nothing: a real capture (zero
        // bytes, exit status 0, nothing on stderr).
        let silent = ProblemReportCollector.classifyConsole(
            exitCode: 0,
            stdout: try ProblemReportFixtures.data("problem-report/emulator-emu-avd-name-silent.txt"),
            stderr: try ProblemReportFixtures.text("problem-report/emulator-emu-avd-name-silent.stderr.txt")
        )
        XCTAssertEqual(silent.outcome, .emptyAnswer)
        XCTAssertEqual(silent.stdoutBytes, 0)
        XCTAssertEqual(silent.sawOK, false)
        XCTAssertNil(silent.name)
        XCTAssertNil(silent.stderr)

        let onlyOK = ProblemReportCollector.classifyConsole(exitCode: 0, stdout: Data("OK\r\n".utf8), stderr: "")
        XCTAssertEqual(onlyOK.outcome, .emptyAnswer)
        XCTAssertEqual(onlyOK.sawOK, true)

        let failed = ProblemReportCollector.classifyConsole(
            exitCode: 1, stdout: Data(), stderr: "error: device 'emulator-5554' not found\n"
        )
        XCTAssertEqual(failed.outcome, .failed)
        XCTAssertEqual(failed.exitCode, 1)
        XCTAssertEqual(failed.stderr, "error: device 'emulator-5554' not found")
    }

    func testPropertyAnswersAreClassified() {
        XCTAssertEqual(
            ProblemReportCollector.classifyProperty(exitCode: 0, stdout: Data("1\n".utf8), stderr: ""),
            ProblemReport.PropertyProbe(outcome: .answered, value: "1")
        )
        XCTAssertEqual(ProblemReportCollector.classifyProperty(exitCode: 0, stdout: Data("\n".utf8), stderr: "").outcome, .empty)
        XCTAssertEqual(ProblemReportCollector.classifyProperty(exitCode: 1, stdout: Data(), stderr: "error: closed").outcome, .failed)
    }

    func testOnlyEmulatorSerialsAndTheFourShapesExist() {
        for refused in ["0a1b2c3d4e5f", "192.168.1.5:5555", "adb-0A1B2C3D4E5F60718-aB3dE5._adb-tls-connect._tcp",
                        "emulator-", "emulator-55x4", "emulator-5554 ; rm", ""] {
            XCTAssertNil(EmulatorSerial(refused), refused)
        }
        let serial = EmulatorSerial("emulator-5554")!
        XCTAssertEqual(ProblemReportAdbCall.devices.arguments, ["devices", "-l"])
        XCTAssertEqual(ProblemReportAdbCall.consoleAvdName(serial).arguments, ["-s", "emulator-5554", "emu", "avd", "name"])
        XCTAssertEqual(ProblemReportAdbCall.guestAvdName(serial).arguments, ["-s", "emulator-5554", "shell", "getprop", "ro.boot.qemu.avd_name"])
        XCTAssertEqual(ProblemReportAdbCall.bootCompleted(serial).arguments, ["-s", "emulator-5554", "shell", "getprop", "sys.boot_completed"])
    }

    func testProcessFlagsAreAllowListed() {
        // The recorded VM's line, and one with flags that carry values: the
        // proxy's credentials, a path and a snapshot name must not survive.
        let line = "71988 /Users/someone/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64-headless -avd Pixel_9 -port 5580 "
            + "-grpc 8554 -http-proxy user:pass@10.0.0.1:3128 -feature -Vulkan -gpu swiftshader_indirect "
            + "-sysdir /Users/someone/sdk/system-images/x/ -snapshot secret_name -no-window -accel off"
        let found = ProblemReportCollector.parseEmulatorProcesses(psOutput: line)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].avd, "Pixel_9")
        XCTAssertEqual(found[0].consolePort, 5580)
        XCTAssertEqual(found[0].grpcPort, 8554)
        XCTAssertEqual(
            found[0].flags,
            ["-port 5580", "-grpc", "-http-proxy", "-feature -Vulkan", "-gpu swiftshader_indirect",
             "-sysdir", "-snapshot", "-no-window", "-accel off"]
        )
        let all = found[0].flags.joined(separator: " ")
        for secret in ["pass", "someone", "secret_name", "3128"] { XCTAssertFalse(all.contains(secret), secret) }
    }

    func testTheExecutablePathMayHoldSpaces() {
        let line = "512 /Users/some one/My SDK/emulator/qemu/darwin-aarch64/qemu-system-aarch64 -avd Pixel_9 -no-window"
        XCTAssertEqual(ProblemReportCollector.parseEmulatorProcesses(psOutput: line).first?.avd, "Pixel_9")
    }

    func testTheAdbServerIsFoundInTheRecordedProcessList() throws {
        let servers = ProblemReportCollector.parseAdbServers(psOutput: try HermeticReportWorld.recordedProcessList())
        XCTAssertEqual(servers, [ProblemReportCollector.ParsedAdbServer(pid: 6272, port: "5037")])
        // `adb track-devices` is a client, not the server.
        XCTAssertEqual(ProblemReportCollector.parseAdbServers(psOutput: "71617 /x/platform-tools/adb track-devices -l"), [])
    }

    /// `discovery-token.ini` is a real discovery file of an emulator Device Hub
    /// Pro launched; its token became a run of `x` and the user name
    /// `aqauser001` (Fixtures/problem-report/README.md).
    func testDiscoveryFilesAreReadAsYesOrNoForTheirTokens() throws {
        let withToken = ProblemReportCollector.parseDiscovery(try ProblemReportFixtures.text("problem-report/discovery-token.ini"))
        XCTAssertTrue(withToken.found)
        XCTAssertTrue(withToken.hasGrpcToken)
        XCTAssertFalse(withToken.hasJwks)
        XCTAssertEqual(withToken.avdID, "Pixel_10_Pro_Fold_API_36")
        XCTAssertEqual(withToken.consolePort, 5554)
        XCTAssertEqual(withToken.adbPort, 5555)
        XCTAssertEqual(withToken.grpcPort, 8554)
        XCTAssertEqual(withToken.emulatorVersion, "36.6.11.0")
        // The value never reaches the report.
        let encoded = try JSONEncoder().encode(withToken)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("xxxxxxxx"))
    }

    // MARK: The token file

    func testTheConsoleTokenFileStateIsReadWithoutKeepingItsContent() async throws {
        let world = try world()
        let file = world.home.appendingPathComponent(".emulator_console_auth_token")

        var report = await world.collect(try world.inputs()).report
        XCTAssertEqual(report.android.consoleTokenFile.state, .missing)
        XCTAssertNil(report.android.consoleTokenFile.bytes)

        try Data().write(to: file)
        report = await world.collect(try world.inputs()).report
        XCTAssertEqual(report.android.consoleTokenFile.state, .empty)
        XCTAssertEqual(report.android.consoleTokenFile.bytes, 0)

        try Data(" \n\t".utf8).write(to: file)
        report = await world.collect(try world.inputs()).report
        XCTAssertEqual(report.android.consoleTokenFile.state, .blank)

        let secret = "SUPERSECRETTOKENVALUE1234"
        try Data(secret.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let collected = await world.collect(try world.inputs())
        let info = collected.report.android.consoleTokenFile
        XCTAssertEqual(info.state, .present)
        XCTAssertEqual(info.bytes, secret.count)
        XCTAssertEqual(info.mode, "600")
        XCTAssertEqual(info.ownedByUser, true)
        XCTAssertFalse(try collected.report.jsonText().contains(secret))

        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        report = await world.collect(try world.inputs()).report
        XCTAssertEqual(report.android.consoleTokenFile.state, .notAFile)
    }

    func testAnEmulatorHomeNamesAnotherTokenFile() async throws {
        let world = try world()
        let emulatorHome = world.root.appendingPathComponent("emu-home", isDirectory: true)
        try FileManager.default.createDirectory(at: emulatorHome, withIntermediateDirectories: true)
        try Data().write(to: emulatorHome.appendingPathComponent(".emulator_console_auth_token"))
        var inputs = try world.inputs()
        let environment = ["PATH": "/nonexistent", "ANDROID_EMULATOR_HOME": emulatorHome.path]
        inputs.environment = { environment }
        let report = await world.collect(inputs).report
        XCTAssertEqual(report.android.emulatorHomeTokenFile?.state, .empty)
        XCTAssertEqual(report.android.consoleTokenFile.state, .missing)
        let variable = try XCTUnwrap(report.android.variables.first { $0.name == "ANDROID_EMULATOR_HOME" })
        XCTAssertNil(variable.value, "a path variable's value is never kept")
        XCTAssertEqual(variable.pathExists, true)
    }

    // MARK: The environment

    func testOnlyTwoVariablesKeepTheirValue() async throws {
        let world = try world()
        var inputs = try world.inputs()
        let environment = [
            "PATH": "/x", "ADB_MDNS": "0", "ANDROID_ADB_SERVER_PORT": "5038", "ANDROID_HOME": "/nonexistent/sdk",
            "DHP_ADB": "/secret/adb", "DHP_DISABLE_SIMBRIDGE": "1", "DHP_EMPTY": "", "ADB_SERVER_SOCKET": "tcp:host:5037",
        ]
        inputs.environment = { environment }
        let report = await world.collect(inputs).report
        let variables = Dictionary(uniqueKeysWithValues: report.android.variables.map { ($0.name, $0) })
        XCTAssertEqual(variables["ADB_MDNS"]?.value, "0")
        XCTAssertEqual(variables["ANDROID_ADB_SERVER_PORT"]?.value, "5038")
        XCTAssertNil(variables["ANDROID_HOME"]?.value)
        XCTAssertEqual(variables["ANDROID_HOME"]?.pathExists, false)
        XCTAssertNil(variables["ADB_SERVER_SOCKET"]?.value)
        XCTAssertEqual(report.app.environmentFlags, ["DHP_ADB", "DHP_DISABLE_SIMBRIDGE"], "names only, and only the non-empty ones")
        XCTAssertFalse(try report.jsonText().contains("/secret/adb"))
    }

    // MARK: Logs and crash reports

    /// `emulator-app-log.log` is a real log of the app's emulator; its scrubs
    /// (user name, adb key) and its cut after "Boot completed" are listed in
    /// Fixtures/problem-report/README.md.
    func testTheNewestThreeLogsAreReadFromTheirEndOnly() async throws {
        let world = try world()
        let logs = world.home.appendingPathComponent("Library/Logs/DeviceHubPro", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let healthy = try ProblemReportFixtures.text("problem-report/emulator-app-log.log")
        for (index, name) in ["A", "B", "C", "D"].enumerated() {
            let file = logs.appendingPathComponent("devicehubpro-emulator-\(name).log")
            try healthy.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 100)], ofItemAtPath: file.path)
        }
        try "not a log".write(to: logs.appendingPathComponent("footprint.log"), atomically: true, encoding: .utf8)

        let report = await world.collect(try world.inputs()).report
        XCTAssertEqual(report.emulatorLogs.map(\.avd), ["D", "C", "B"], "newest first, at most three")
        let tail = report.emulatorLogs[0]
        XCTAssertEqual(tail.lines.count, 60)
        XCTAssertTrue(tail.omittedLines)
        XCTAssertEqual(tail.bytes, healthy.utf8.count)
        XCTAssertTrue(tail.lines.last?.contains("Netsim") == false, "the app's log ends at Boot completed")
        XCTAssertTrue(tail.lines.contains { $0.contains("Boot completed") })
        XCTAssertEqual(tail.modified, Date(timeIntervalSince1970: 1_700_000_300))
    }

    /// The collector keeps long lines whole (a key cut in two would escape the
    /// scrubber); the builder cuts them after it scrubbed.
    func testLongLinesAreKeptWholeAndCutAfterwardsToTheirBeginningAndEnd() throws {
        let long = String(repeating: "a", count: 150) + String(repeating: "m", count: 400) + String(repeating: "z", count: 200)
        let kept = CollectionRun.tailLines(from: Data((long + "\nshort\n").utf8), startedMidFile: false)
        XCTAssertEqual(kept.lines, [long, "short"])
        XCTAssertFalse(kept.omitted)

        let cut = CollectionRun.cutLongLines(kept.lines)
        XCTAssertEqual(cut[0], String(repeating: "a", count: 150) + " \u{2026} " + String(repeating: "z", count: 200))
        XCTAssertEqual(cut[1], "short")
        XCTAssertEqual(CollectionRun.cutLongLines([String(repeating: "q", count: 400)]), [String(repeating: "q", count: 400)], "400 is not over 400")

        let partial = CollectionRun.tailLines(from: Data("tial line\nwhole\n".utf8), startedMidFile: true)
        XCTAssertEqual(partial.lines, ["whole"])
        XCTAssertTrue(partial.omitted)
    }

    func testCrashReportsAreNamedNotRead() async throws {
        let world = try world()
        let folder = world.home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func make(_ name: String, daysAgo: Double) throws {
            let url = folder.appendingPathComponent(name)
            try "crash contents that must stay unread".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: url.path)
        }
        try make("qemu-system-aarch64-2026-10-09-123456.ips", daysAgo: 1)
        try make("adb-2026-10-01-010101.ips", daysAgo: 20)
        try make("Safari-2026-10-09-123456.ips", daysAgo: 1)
        try make("DeviceHubPro-2026-10-10-090909.ips", daysAgo: 0.5)
        // A simulator's Safari and wallpaper (the Mac's Safari above is not one).
        try make("MobileSafari-2026-10-14-193840.ips", daysAgo: 0.25)
        try make("PosterBoard-2026-10-14-210952.ips", daysAgo: 0.75)
        let report = await world.collect(try world.inputs()).report
        XCTAssertEqual(
            report.crashReports.map(\.process),
            ["MobileSafari", "DeviceHubPro", "PosterBoard", "qemu-system-aarch64"]
        )
        XCTAssertFalse(try report.jsonText().contains("must stay unread"))
        XCTAssertEqual(CollectionRun.crashProcessName("qemu-system-aarch64-2026-10-09-123456.ips"), "qemu-system-aarch64")
    }

    // MARK: Subject, problems and app facts

    func testTheSubjectAndRecentProblemsAreKeptWithWholeSeconds() async throws {
        let world = try world()
        let at = Date(timeIntervalSince1970: 1_799_999_000.75)
        let collected = await world.collect(
            try world.inputs(),
            subject: ProblemReport.Subject(message: "Pixel_8_Pro did not come online in time.", details: ["line 1"], occurredAt: at),
            recentProblems: [ProblemReport.RecentProblem(at: at, message: "Emulator not responding", count: 2)]
        )
        XCTAssertEqual(collected.report.subject?.occurredAt, Date(timeIntervalSince1970: 1_799_999_000))
        XCTAssertEqual(collected.report.recentProblems.first?.at, Date(timeIntervalSince1970: 1_799_999_000))
        XCTAssertEqual(collected.report.id, "abcd1234")
        XCTAssertEqual(collected.report.createdAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(collected.report.producer, .cli)
        XCTAssertEqual(collected.report.app.kind, .cli)
    }

    func testTheMacAndAppAreDescribed() async throws {
        let world = try world()
        var inputs = try world.inputs(producer: .app)
        inputs.bundle = BundleFacts(version: "1.1.1", build: "412", bundlePath: "/Applications/Device Hub Pro.app", quarantined: false)
        let report = await world.collect(inputs).report
        XCTAssertEqual(report.app.kind, .packaged)
        XCTAssertEqual(report.app.location, .applications)
        XCTAssertEqual(report.app.version, "1.1.1")
        XCTAssertEqual(report.mac.macOS, "27.0")
        XCTAssertEqual(report.mac.chip, "Apple M4 Pro")
        XCTAssertEqual(report.mac.memoryGB, 24)
        XCTAssertEqual(report.mac.hypervisorSupported, true)
        XCTAssertEqual(Set(report.mac.freeSpace.map(\.role)), ["home", "avdHome", "sdk"])
        XCTAssertEqual(report.mac.freeSpace.first?.freeGB, 182)

        for (path, expected) in [
            ("/Users/someone/Applications/Device Hub Pro.app", ProblemReport.AppInfo.Location.userApplications),
            ("/private/var/folders/ab/cd/T/AppTranslocation/UUID/d/Device Hub Pro.app", .translocated),
            ("/Volumes/Device Hub Pro/Device Hub Pro.app", .diskImage),
            ("/tmp/Device Hub Pro.app", .other),
        ] {
            var other = try world.inputs(producer: .app)
            other.homeDirectory = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
            other.bundle = BundleFacts(bundlePath: path)
            XCTAssertEqual(CollectionRun(inputs: other, appState: nil).appInfo().location, expected, path)
        }
        var development = try world.inputs(producer: .app)
        development.bundle = BundleFacts(version: nil, build: nil, bundlePath: nil)
        XCTAssertEqual(CollectionRun(inputs: development, appState: nil).appInfo().kind, .development)
    }

    func testTheAppleToolchainComesFromTheSnapshotElseTheInputs() async throws {
        let world = try world()
        let layout = AppleToolchain(
            developerDirectory: URL(fileURLWithPath: "/Applications/Xcode-beta.app/Contents/Developer"),
            xcodeVersion: "27.1", xcodeBuild: "27B1a", firstLaunchComplete: true,
            simctl: AppleToolchain.BundledTool(binary: URL(fileURLWithPath: "/x/simctl"), installedVersion: "1171.7", expectedVersion: "1171.7", needsFirstLaunch: false),
            devicectl: .missing,
            installedXcodes: [URL(fileURLWithPath: "/Applications/Xcode-beta.app")]
        )
        var inputs = try world.inputs()
        inputs.appleToolchain = { layout }
        let fromInputs = await world.collect(inputs).report.apple
        XCTAssertEqual(fromInputs.xcodeVersion, "27.1")
        XCTAssertEqual(fromInputs.developerDirectory, "Xcode app")
        XCTAssertEqual(fromInputs.xcodeAppName, "Xcode-beta.app")
        XCTAssertEqual(fromInputs.installedXcodes, 1)
        XCTAssertEqual(fromInputs.simctl, ProblemReport.AppleTool(found: true, version: "1171.7", expectedVersion: "1171.7"))
        XCTAssertEqual(fromInputs.devicectl?.found, false)
        XCTAssertNil(fromInputs.tier, "the tier is the app's to say")

        var inputsThatMustNotRun = try world.inputs(producer: .app)
        inputsThatMustNotRun.appleToolchain = {
            XCTFail("the app's snapshot already holds the probed toolchain")
            return nil
        }
        let state = ProblemReportAppState(
            preferences: .sample,
            apple: ProblemReportAppState.AppleState(
                tier: "T3", isProbed: true, setupAdvice: nil, toolchain: layout,
                simulatorsListed: true, simulatorCount: 4, bootedCount: 1, runtimeCount: 2,
                watcherHealth: "ok", bridge: "ready", canvasReadyCount: 1
            ),
            simulatorUDIDs: ["E3B0C442-98FC-1C14-9AFB-F4C8996FB924"]
        )
        let collected = await world.collect(inputsThatMustNotRun, appState: state)
        XCTAssertEqual(collected.report.apple.tier, "T3")
        XCTAssertEqual(collected.report.apple.simulators, ProblemReport.SimulatorCounts(listed: true, total: 4, booted: 1, runtimes: 2, watcher: "ok", canvasReady: 1))
        XCTAssertEqual(collected.report.apple.bridge, "ready")
        XCTAssertEqual(collected.privateIdentifiers["E3B0C442-98FC-1C14-9AFB-F4C8996FB924"], "sim-1")
    }

    func testAnImpatientBudgetSkipsTheProbes() async throws {
        let world = try world()
        var inputs = try world.inputs()
        inputs.budget = .zero
        let report = await world.collect(inputs).report
        let emulator = try XCTUnwrap(report.android.runningEmulators.first)
        XCTAssertEqual(emulator.console.outcome, .skipped)
        XCTAssertEqual(emulator.console.note, "time budget")
        XCTAssertEqual(world.adb.invocations.filter { $0.contains("emu") }, [])
    }
}
