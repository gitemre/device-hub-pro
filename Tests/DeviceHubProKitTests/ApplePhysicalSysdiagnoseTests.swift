import XCTest
@testable import DeviceHubProKit

/// `device sysdiagnose` runs with administrator privileges through macOS's
/// authorization dialog: devicectl asks for the
/// Mac's administrator password on a terminal for this one command and fails
/// without one (CoreDeviceCLISupport.DiagnoseError 0). The wrapper is
/// `osascript -e 'do shell script ... with administrator privileges'`; here
/// `osascript` is a fake that records its argv, and devicectl never runs, so
/// nothing reaches a device or asks for a password.
final class ApplePhysicalSysdiagnoseTests: XCTestCase {
    private static let id = ApplePhysicalDeviceTests.coreDeviceIdentifier

    private func makeClient(devicectl: FakeTool, osascript: FakeTool, developerDirectory: URL? = nil) throws -> DevicectlPhysicalClient {
        try DevicectlPhysicalClient(
            devicectlURL: devicectl.executableURL,
            device: try ApplePhysicalDeviceTests.device(),
            developerDirectory: developerDirectory,
            commandTimeout: .seconds(30),
            privilegedLauncher: osascript.executableURL
        )
    }

    // MARK: Quoting

    func testShellQuotingHandlesSpacesQuotesAndMetacharacters() {
        XCTAssertEqual(DevicectlPrivilegedRunner.shellQuoted("/tmp/a b"), "'/tmp/a b'")
        XCTAssertEqual(DevicectlPrivilegedRunner.shellQuoted("it's"), "'it'\\''s'")
        XCTAssertEqual(DevicectlPrivilegedRunner.shellQuoted("$(rm -rf ~); `x` \"y\" \\"), "'$(rm -rf ~); `x` \"y\" \\'")
    }

    func testAppleScriptEscapingDoublesBackslashesAndEscapesQuotes() {
        XCTAssertEqual(DevicectlPrivilegedRunner.appleScriptEscaped(#"a"b\c"#), #"a\"b\\c"#)
    }

    /// The script a path with spaces and quotes ends up in, and what
    /// `/bin/sh` reads back from it: the same one word.
    func testAPathWithSpacesAndQuotesSurvivesBothQuotingLayers() throws {
        let nasty = "/tmp/My \"Phone\" it's $HOME `x`/files"
        let script = DevicectlPrivilegedRunner.shellScript(
            devicectl: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s\\n", nasty],
            developerDirectory: nil,
            workFolder: URL(fileURLWithPath: "/tmp/work folder"),
            userID: 501,
            groupID: 20
        )
        XCTAssertTrue(script.hasPrefix("'/usr/bin/printf' '%s\\n' '/tmp/My \"Phone\" it'\\''s $HOME `x`/files'; s=$?; "), script)
        XCTAssertTrue(script.hasSuffix("/usr/sbin/chown -R 501:20 '/tmp/work folder'; exit $s"), script)

        let argv = DevicectlPrivilegedRunner.osascriptArguments(shellScript: script, prompt: "Collect \"it\"")
        XCTAssertEqual(argv.count, 2)
        XCTAssertEqual(argv[0], "-e")
        XCTAssertTrue(argv[1].hasPrefix("do shell script \""))
        XCTAssertTrue(argv[1].contains("\" with administrator privileges with prompt \"Collect \\\"it\\\"\""), argv[1])

        // Run the shell part (not the privileged chown) and read it back.
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/bin/sh")
        let command = script.components(separatedBy: "; s=$?;").first ?? ""
        run.arguments = ["-c", command]
        let pipe = Pipe()
        run.standardOutput = pipe
        try run.run()
        run.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(out, nasty + "\n")
    }

    func testTheScriptSetsDeveloperDirectoryOnlyWhenOneIsGiven() {
        let with = DevicectlPrivilegedRunner.shellScript(
            devicectl: URL(fileURLWithPath: "/x/devicectl"), arguments: ["a"],
            developerDirectory: URL(fileURLWithPath: "/Apps/Xcode beta.app/Contents/Developer"),
            workFolder: URL(fileURLWithPath: "/w"), userID: 1, groupID: 2
        )
        XCTAssertTrue(with.hasPrefix("DEVELOPER_DIR='/Apps/Xcode beta.app/Contents/Developer' '/x/devicectl' 'a'; "), with)
    }

    // MARK: The command

    /// The client runs the one fixed shape, with the work folder as its
    /// destination, only through `osascript`; devicectl is not run directly.
    func testSysdiagnoseRunsTheValidatedArgvThroughOsascript() async throws {
        let devicectl = try FakeTool(name: "devicectl", rules: [])
        let osascript = try FakeTool(name: "osascript", rules: [])
        let client = try makeClient(devicectl: devicectl, osascript: osascript)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aqa sysdiag \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let files = try await client.sysdiagnose(into: folder)

        XCTAssertEqual(files, [])
        XCTAssertEqual(devicectl.invocations, [], "devicectl is run by the privileged script, never directly")
        let calls = osascript.invocations
        XCTAssertEqual(calls.count, 1)
        let argv = try XCTUnwrap(calls.first)
        XCTAssertEqual(argv.count, 2)
        XCTAssertEqual(argv[0], "-e")
        let source = argv[1]
        XCTAssertTrue(source.hasPrefix("do shell script \""), source)
        XCTAssertTrue(source.contains("with administrator privileges"), source)
        XCTAssertTrue(source.contains("'\(devicectl.executableURL.path)' 'device' 'sysdiagnose' '--device' '\(Self.id)' '--json-output' "), source)
        XCTAssertTrue(source.contains("'-q' '-t' '600' '--destination' "), source)
        XCTAssertTrue(source.contains("/usr/sbin/chown -R \(getuid()):\(getgid()) "), source)
        XCTAssertFalse(source.contains(folder.path), "the privileged script never touches the user's folder")
    }

    func testCancellingThePasswordDialogIsNotAnErrorWithTextButATypedOne() async throws {
        let devicectl = try FakeTool(name: "devicectl", rules: [])
        let osascript = try FakeTool(name: "osascript", rules: [
            .init("do shell script", stderr: "0:72: execution error: User canceled. (-128)\n", exitCode: 1),
        ])
        let client = try makeClient(devicectl: devicectl, osascript: osascript)
        do {
            try await client.sysdiagnose(into: FileManager.default.temporaryDirectory)
            XCTFail("a cancelled dialog must throw")
        } catch let error as DevicectlPrivilegedError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testAWrongPasswordAndAFailedCommandAreTypedToo() async throws {
        XCTAssertEqual(DevicectlPrivilegedRunner.error(fromStandardError: "execution error: The administrator user name or password was incorrect. (-60007)"), .authorizationFailed)
        XCTAssertEqual(DevicectlPrivilegedRunner.error(fromStandardError: "execution error: Authentication failed. (-60005)\n"), .authorizationFailed)
        XCTAssertEqual(
            DevicectlPrivilegedRunner.error(fromStandardError: "0:30: execution error: Error: x (1)\nmore\n"),
            .failed("0:30: execution error: Error: x (1)")
        )
        XCTAssertEqual(DevicectlPrivilegedRunner.error(fromStandardError: ""), .failed(""))

        let devicectl = try FakeTool(name: "devicectl", rules: [])
        let osascript = try FakeTool(name: "osascript", rules: [
            .init("do shell script", stderr: "execution error: nope (-60007)\n", exitCode: 1),
        ])
        let client = try makeClient(devicectl: devicectl, osascript: osascript)
        do {
            try await client.sysdiagnose(into: FileManager.default.temporaryDirectory)
            XCTFail("a wrong password must throw")
        } catch let error as DevicectlPrivilegedError {
            XCTAssertEqual(error, .authorizationFailed)
        }
    }

    /// The timeout is ten minutes (devicectl's `-t`), plus the dialog's allowance
    /// for the outer process.
    func testTheTimeoutIsSixHundredSeconds() {
        XCTAssertEqual(DevicectlPhysicalClient.sysdiagnoseTimeout, .seconds(600))
        XCTAssertEqual(DevicectlPrivilegedRunner.dialogAllowance, .seconds(120))
    }

    /// What devicectl collected (as the user, after the script's `chown`) goes
    /// into the chosen folder, a taken name gets a number, and nothing is
    /// overwritten.
    func testTheCollectedFilesMoveIntoTheChosenFolder() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("aqa-move-\(UUID().uuidString)")
        let source = base.appendingPathComponent("collected")
        let target = base.appendingPathComponent("My Folder")
        try manager.createDirectory(at: source, withIntermediateDirectories: true)
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        try Data("new".utf8).write(to: source.appendingPathComponent("sysdiagnose.tar.gz"))
        try Data("old".utf8).write(to: target.appendingPathComponent("sysdiagnose.tar.gz"))

        let moved = try DevicectlPrivilegedRunner.moveContents(of: source, into: target)

        XCTAssertEqual(moved.map(\.lastPathComponent), ["sysdiagnose 2.tar.gz"])
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("sysdiagnose.tar.gz"), encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: moved[0], encoding: .utf8), "new")
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: source.path), [])
    }

    func testEveryOtherSysdiagnoseShapeIsStillRefused() async throws {
        let devicectl = try FakeTool(name: "devicectl", rules: [])
        let osascript = try FakeTool(name: "osascript", rules: [])
        let client = try makeClient(devicectl: devicectl, osascript: osascript)
        for command in [
            ["device", "sysdiagnose"],
            ["device", "sysdiagnose", "--dry-run-only"],
            ["device", "sysdiagnose", "--destination", "-x"],
        ] {
            do {
                _ = try await client.run(command, as: DevicectlManagementResult.self)
                XCTFail("\(command) must be refused")
            } catch let error as DevicectlClientError {
                XCTAssertEqual(error, .refusedCommand(command.joined(separator: " ")))
            }
        }
        XCTAssertEqual(osascript.invocations, [])
    }
}
