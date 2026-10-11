import Darwin
import XCTest
@testable import DeviceHubProKit

/// The emulator console client against a stand-in that replays the real
/// console's bytes (`Fixtures/emulator-console/`, captured 2026-10-12 from an
/// emulator 36.6.11 on an android-36 google_apis image, with `HOME` pointing
/// at a private token file: empty for "no authentication", 16 characters for
/// "authentication required"). What the stand-in expects the client to send is
/// asserted from the lines it received; the real adb's behaviour on the same
/// consoles is in `AdbClientEmulatorConsoleTests`.
///
/// Scrubbed fixtures: the paths in the discovery-path and token-path lines
/// (`noauth-avd-discoverypath.bin`, `auth-greeting.bin`, `auth-stream-*.bin`,
/// `adb-emu-avd-discoverypath-auth.stdout.txt`) carry same-length placeholders
/// (user name `aqauser001`, session id all zeros; see the folder's README),
/// which is why the discovery path asserted below reads as it does; nothing
/// else in them was edited.
final class EmulatorConsoleTests: XCTestCase {
    private let tenSeconds: Duration = .seconds(10)

    // MARK: - The port

    /// adb derives the console port from the serial (`adb_get_emulator_console_port`
    /// scans `emulator-%d`); the emulator started with `-port 5580` is
    /// `emulator-5580` and its console listens on 5580 (`adb devices` and the
    /// capture's `-port 5580` agree).
    func testConsolePortOfAnEmulatorSerial() {
        XCTAssertEqual(EmulatorConsole.port(forSerial: "emulator-5554"), 5554)
        XCTAssertEqual(EmulatorConsole.port(forSerial: "emulator-5580"), 5580)
        XCTAssertEqual(EmulatorConsole.port(forSerial: "emulator-65535"), 65535)
    }

    func testNoConsolePortForAnythingButAnEmulatorSerial() {
        for serial in [
            "", "emulator-", "emulator-abc", "emulator-5554abc", "emulator--5", "emulator-0", "emulator-65536",
            "emulator-5554 ", "R58M12345AB", "192.168.1.20:5555", "adb-R58M12345AB-yXk7tu._adb-tls-connect._tcp",
            "Emulator-5554", "xemulator-5554",
        ] {
            XCTAssertNil(EmulatorConsole.port(forSerial: serial), serial)
        }
    }

    // MARK: - Authentication off (the empty token file)

    /// The user's case: an empty `~/.emulator_console_auth_token`, a console
    /// whose greeting asks for nothing. The client sends the command and no
    /// `auth` line, and the answer is the captured one, `\r\n` kept, through
    /// its `OK` line: what the real adb dropped (`adb-emu-avd-name-empty-token.stdout.txt`
    /// is empty).
    func testAnEmulatorThatAsksForNoAuthenticationAnswersTheAvdName() async throws {
        let server = try startConsoleServer { try .noAuthentication() }
        let console = LiveEmulatorConsole(tokenFile: try makeTokenFile(""))

        let answer = try await console.run(["avd", "name"], port: server.port, timeout: tenSeconds)

        XCTAssertEqual(answer, try EmulatorConsoleFixture.text("noauth-avd-name.bin"))
        XCTAssertEqual(answer, "DHP_ConsoleCapture\r\nOK\r\n")
        XCTAssertEqual(AdbParsing.avdName(from: answer), "DHP_ConsoleCapture")
        let lines = await server.waitForLines(2)
        XCTAssertEqual(lines, ["avd name", "quit"])
    }

    /// The Mac user's own case: a token in the file but a console that asks
    /// for none (the emulator was started with its own `HOME`, or the file
    /// changed). No `auth` line goes out (a console that wants none answers
    /// it `KO: unknown command`, `noauth-auth-wrong-token.bin`), and the token
    /// is not sent anywhere.
    func testAConsoleThatAsksForNoAuthenticationIsNeverSentTheToken() async throws {
        let server = try startConsoleServer { try .noAuthentication() }
        let console = LiveEmulatorConsole(tokenFile: try makeTokenFile("devicehubprofake\n"))

        let answer = try await console.run(["avd", "name"], port: server.port, timeout: tenSeconds)

        XCTAssertEqual(AdbParsing.avdName(from: answer), "DHP_ConsoleCapture")
        let lines = await server.waitForLines(2)
        XCTAssertEqual(lines, ["avd name", "quit"])
    }

    /// The discovery path, the answer `EmulatorDiscovery.grpcInfo` needs
    /// (`adb-emu-avd-discoverypath-empty-token.stdout.txt` is empty).
    func testAnEmulatorThatAsksForNoAuthenticationAnswersItsDiscoveryPath() async throws {
        let server = try startConsoleServer { try .noAuthentication() }
        let console = LiveEmulatorConsole(tokenFile: try makeTokenFile(""))

        let answer = try await console.run(["avd", "discoverypath"], port: server.port, timeout: tenSeconds)

        XCTAssertEqual(answer, try EmulatorConsoleFixture.text("noauth-avd-discoverypath.bin"))
        XCTAssertEqual(
            AdbParsing.discoveryPath(from: answer),
            "/private/tmp/claude-501/-Users-aqauser001-device-hub-pro/00000000-0000-0000-0000-000000000000"
                + "/scratchpad/console-capture/home-noauth/Library/Caches/TemporaryItems/avd/running/pid_7500.ini"
        )
    }

    // MARK: - Authentication on

    /// A console that wants `auth <token>`: the client reads the token from
    /// the file it was given (trailing line ending dropped), sends `auth
    /// <token>`, waits for the console's `OK`, and only then sends the
    /// command. The answer holds nothing of the greeting or the
    /// authentication. The stand-in answers `avd discoverypath` with the
    /// `avd` help and a `KO` before authentication (`auth-avd-discoverypath-before-auth.bin`),
    /// so only an authenticated client gets the path.
    func testAnEmulatorThatRequiresAuthenticationGetsTheTokenFromTheFile() async throws {
        let token = "devicehubprofake"
        let server = try startConsoleServer { try .authenticating(token: token) }
        let console = LiveEmulatorConsole(tokenFile: try makeTokenFile(token + "\n"))

        let answer = try await console.run(["avd", "discoverypath"], port: server.port, timeout: tenSeconds)

        XCTAssertEqual(answer, try EmulatorConsoleFixture.text("adb-emu-avd-discoverypath-auth.stdout.txt"))
        XCTAssertTrue(answer.hasSuffix("\r\nOK\r\n"))
        let lines = await server.waitForLines(3)
        XCTAssertEqual(lines, ["auth \(token)", "avd discoverypath", "quit"])
    }

    /// A refused token is a typed error carrying the console's own `KO` line
    /// and nothing of the token, and the command is never sent.
    func testARefusedTokenIsAnAuthenticationError() async throws {
        let server = try startConsoleServer { try .authenticating(token: "devicehubprofake") }
        let console = LiveEmulatorConsole(tokenFile: try makeTokenFile("devicehubprofalse"))

        do {
            _ = try await console.run(["avd", "name"], port: server.port, timeout: tenSeconds)
            XCTFail("a refused token must throw")
        } catch let error as EmulatorConsoleError {
            XCTAssertEqual(
                error,
                .authenticationRejected("KO: authentication token does not match ~/.emulator_console_auth_token")
            )
            XCTAssertFalse(error.isConnectionFailure)
            XCTAssertFalse(error.description.contains("devicehubprofalse"))
        }
        XCTAssertEqual(server.lines.prefix(1), ["auth devicehubprofalse"])
        XCTAssertFalse(server.lines.contains("avd name"))
    }

    /// Without a token to send the command still goes out, since `avd name`
    /// is answered before authentication (`auth-avd-name-before-auth.bin`);
    /// a command that is not gets the console's own KO as its answer.
    func testWithoutATokenTheCommandIsSentAnyway() async throws {
        let server = try startConsoleServer { try .authenticating(token: "devicehubprofake") }
        let console = LiveEmulatorConsole(tokenFile: try makeTokenFile(nil))

        let name = try await console.run(["avd", "name"], port: server.port, timeout: tenSeconds)
        // The first connection's `quit` follows its call's return.
        _ = await server.waitForLines(2)
        let path = try await console.run(["avd", "discoverypath"], port: server.port, timeout: tenSeconds)

        XCTAssertEqual(AdbParsing.avdName(from: name), "DHP_ConsoleCapture")
        XCTAssertEqual(path, try EmulatorConsoleFixture.text("auth-avd-discoverypath-before-auth.bin"))
        XCTAssertTrue(path.hasSuffix("KO:  bad sub-command\r\n"))
        let lines = await server.waitForLines(4)
        XCTAssertEqual(lines, ["avd name", "quit", "avd discoverypath", "quit"])
    }

    /// An empty token file (adb's own rule: nothing to send) counts as no
    /// token even when the console asks for one.
    func testAnEmptyTokenFileIsNoToken() async throws {
        let server = try startConsoleServer { try .authenticating(token: "devicehubprofake") }
        let console = LiveEmulatorConsole(tokenFile: try makeTokenFile(""))

        let answer = try await console.run(["avd", "name"], port: server.port, timeout: tenSeconds)

        XCTAssertEqual(AdbParsing.avdName(from: answer), "DHP_ConsoleCapture")
        let lines = await server.waitForLines(2)
        XCTAssertEqual(lines, ["avd name", "quit"])
    }

    // MARK: - Answers

    /// A `KO` line ends an answer too (no `OK` follows it, `noauth-unknown-command.bin`):
    /// the client returns it as text, and does not wait for more. A bound of
    /// a few seconds fails the test if it did.
    func testAKoAnswerEndsTheExchangeAndIsReturnedAsText() async throws {
        let server = try startConsoleServer { try .noAuthentication() }
        let console = LiveEmulatorConsole(tokenFile: try makeTokenFile(""))

        let answer = try await console.run(["devicehubpro-unknown"], port: server.port, timeout: .seconds(3))

        XCTAssertEqual(answer, "KO: unknown command, try 'help'\r\n")
        XCTAssertEqual(answer, try EmulatorConsoleFixture.text("noauth-unknown-command.bin"))
    }

    /// `resize-display` with no index: the console's usage line, a `KO`, which
    /// `AdbParsing.resizePresets(fromUsage:)` reads.
    func testTheResizeDisplayUsageAnswerListsThePresets() async throws {
        let server = try startConsoleServer { try .noAuthentication() }
        let console = LiveEmulatorConsole(tokenFile: try makeTokenFile(""))

        let answer = try await console.run(["resize-display"], port: server.port, timeout: .seconds(3))

        XCTAssertEqual(answer, try EmulatorConsoleFixture.text("noauth-resize-display-no-index.bin"))
        XCTAssertEqual(AdbParsing.resizePresets(fromUsage: answer), [
            ResizePreset(index: 0, name: "phone"),
            ResizePreset(index: 1, name: "unfolded"),
            ResizePreset(index: 2, name: "tablet"),
        ])
    }

    /// `kill` ends the VM: the console says `OK: killing emulator, bye bye`,
    /// then `OK`, then closes (`noauth-kill.bin`). The `OK:` line is not the
    /// terminator, the bare `OK` is; the `quit` that follows may meet a closed
    /// connection and must not matter.
    func testKillIsAnsweredThroughItsClosingOk() async throws {
        let server = try startConsoleServer { try .noAuthentication() }
        let console = LiveEmulatorConsole(tokenFile: try makeTokenFile(""))

        let answer = try await console.run(["kill"], port: server.port, timeout: .seconds(3))

        XCTAssertEqual(answer, "OK: killing emulator, bye bye\r\nOK\r\n")
        XCTAssertEqual(answer, try EmulatorConsoleFixture.text("noauth-kill.bin"))
    }

    /// A console that closes before the terminator gives what it had sent.
    /// SOURCE-DERIVED (adb `client/console.cpp`, `adb_send_emulator_command`:
    /// it reads to the end of the connection and prints what it read): the
    /// first line of the `avd name` capture, `noauth-avd-name.bin` cut before
    /// its `OK` line; no console was captured dying mid-answer.
    func testAConnectionThatClosesBeforeTheTerminatorGivesWhatWasSent() async throws {
        let full = try EmulatorConsoleFixture.data("noauth-avd-name.bin")
        let firstLine = full.prefix(through: try XCTUnwrap(full.firstIndex(of: UInt8(ascii: "\n"))))
        let server = try startConsoleServer {
            try ScriptedConsoleServer(greeting: EmulatorConsoleFixture.data("noauth-greeting.bin")) { _, _ in
                .closing(Data(firstLine))
            }
        }
        let console = LiveEmulatorConsole(tokenFile: try makeTokenFile(""))

        let answer = try await console.run(["avd", "name"], port: server.port, timeout: .seconds(3))

        XCTAssertEqual(answer, "DHP_ConsoleCapture\r\n")
    }

    /// A connection that closes right after the command, with nothing sent,
    /// is an empty answer. SOURCE-DERIVED (adb `client/console.cpp`,
    /// `adb_send_emulator_command`: nothing read, nothing printed, exit status
    /// 0): a stand-in that closes after the captured greeting and the command;
    /// no console was captured doing it.
    func testAConnectionThatClosesWithoutAnAnswerGivesNothing() async throws {
        let server = try startConsoleServer {
            try ScriptedConsoleServer(greeting: EmulatorConsoleFixture.data("noauth-greeting.bin")) { _, _ in
                .closing(Data())
            }
        }
        let console = LiveEmulatorConsole(tokenFile: try makeTokenFile(""))

        let answer = try await console.run(["avd", "name"], port: server.port, timeout: .seconds(3))

        XCTAssertEqual(answer, "")
    }

    /// An AVD whose name starts with the letters `KO` is named by the console
    /// like any other: its line is not an error line, so the read goes on to
    /// the `OK` after it. SOURCE-DERIVED (the captured `noauth-avd-name.bin`
    /// with another name; AVD names take letters, digits and `._-`,
    /// `AvdmanagerClient.sanitizedAvdName`): `avd name` answered
    /// `KOMPAKT_Phone`, which a working `adb emu` prints whole.
    func testAnAvdNameThatStartsWithKoIsNotAKoAnswer() async throws {
        for name in ["KOMPAKT_Phone", "KO-Phone", "KO.1"] {
            let answer = Data("\(name)\r\nOK\r\n".utf8)
            let unknown = try EmulatorConsoleFixture.data("noauth-unknown-command.bin")
            let server = try startConsoleServer {
                try ScriptedConsoleServer(greeting: EmulatorConsoleFixture.data("noauth-greeting.bin")) { line, _ in
                    .bytes(line == "avd name" ? answer : unknown)
                }
            }
            let console = LiveEmulatorConsole(tokenFile: try makeTokenFile(""))

            let read = try await console.run(["avd", "name"], port: server.port, timeout: .seconds(3))

            XCTAssertEqual(read, "\(name)\r\nOK\r\n")
            XCTAssertEqual(AdbParsing.avdName(from: read), name)
        }
    }

    /// What is an error line: `KO` alone, `KO:` and `KO ` with a message (the
    /// captured `KO: unknown command`, `KO usage: …`, `KO:  bad
    /// sub-command`), not a name that starts with the letters.
    func testErrorLinesAreKoAloneOrKoWithAColonOrABlank() {
        for line in [
            "KO", "KO\r\n", "KO: unknown command, try 'help'\r\n", "KO usage: \"resize-display <index>\" 0: phone\r\n",
            "KO:  bad sub-command\r\n", " KO: padded",
        ] {
            XCTAssertTrue(EmulatorConsole.isErrorLine(line), line)
            XCTAssertTrue(EmulatorConsole.isTerminator(line), line)
        }
        for line in ["KOMPAKT_Phone", "KO-Phone\r\n", "KO.1", "Ko: no", "OK: killing emulator, bye bye\r\n", "", "ok"] {
            XCTAssertFalse(EmulatorConsole.isErrorLine(line), line)
        }
        XCTAssertTrue(EmulatorConsole.isTerminator("OK\r\n"))
        XCTAssertFalse(EmulatorConsole.isTerminator("KOMPAKT_Phone\r\n"))
        XCTAssertFalse(EmulatorConsole.isTerminator("OK: killing emulator, bye bye\r\n"))
    }

    /// An answer is the console's error when it starts or ends with an error
    /// line; a name starting with `KO` and a successful answer are not.
    func testAnErrorAnswerStartsOrEndsWithAnErrorLine() throws {
        XCTAssertTrue(EmulatorConsole.isErrorAnswer(try EmulatorConsoleFixture.text("noauth-unknown-command.bin")))
        XCTAssertTrue(EmulatorConsole.isErrorAnswer(try EmulatorConsoleFixture.text("noauth-resize-display-no-index.bin")))
        // The help text first, the KO last.
        XCTAssertTrue(EmulatorConsole.isErrorAnswer(try EmulatorConsoleFixture.text("auth-avd-discoverypath-before-auth.bin")))
        XCTAssertFalse(EmulatorConsole.isErrorAnswer(try EmulatorConsoleFixture.text("noauth-avd-name.bin")))
        XCTAssertFalse(EmulatorConsole.isErrorAnswer(try EmulatorConsoleFixture.text("noauth-kill.bin")))
        XCTAssertFalse(EmulatorConsole.isErrorAnswer("KOMPAKT_Phone\r\nOK\r\n"))
        XCTAssertFalse(EmulatorConsole.isErrorAnswer(""))
    }

    // MARK: - Failures

    /// Nothing listens: a connection error, which is the one `AdbClient`
    /// answers by asking adb. Port 0 is one nothing can listen on (the suite's
    /// rule for a port that reaches nothing), so both loopback addresses fail
    /// at once.
    func testNothingListeningIsAConnectionError() async throws {
        let console = LiveEmulatorConsole(tokenFile: try makeTokenFile(""))

        do {
            _ = try await console.run(["avd", "name"], port: 0, timeout: .seconds(3))
            XCTFail("a connection to port 0 must fail")
        } catch let error as EmulatorConsoleError {
            guard case .couldNotConnect(let failedPort, let reason) = error else {
                return XCTFail("expected a connection error, got \(error)")
            }
            XCTAssertEqual(failedPort, 0)
            XCTAssertFalse(reason.isEmpty)
            XCTAssertTrue(error.isConnectionFailure)
        }
    }

    /// Something that closes at once, saying nothing, is not a console: a
    /// protocol error, not a connection error (adb would be asked in the
    /// second case only). SOURCE-DERIVED (this client's own rule, no adb
    /// parity claimed): a stand-in with an empty greeting; no emulator was
    /// captured doing it.
    func testAPortThatClosesWithoutAGreetingIsAProtocolError() async throws {
        let server = try startConsoleServer {
            try ScriptedConsoleServer(greeting: Data(), closesAfterGreeting: true) { _, _ in .silence }
        }
        let console = LiveEmulatorConsole(tokenFile: try makeTokenFile(""))

        do {
            _ = try await console.run(["avd", "name"], port: server.port, timeout: .seconds(3))
            XCTFail("a missing greeting must throw")
        } catch let error as EmulatorConsoleError {
            guard case .protocolError = error else { return XCTFail("expected a protocol error, got \(error)") }
            XCTAssertFalse(error.isConnectionFailure)
        }
    }

    /// A console whose greeting never ends is waited on for the bound and then
    /// reported as timed out. SOURCE-DERIVED (a fault injected into the
    /// captured greeting, no adb parity claimed): the first line of
    /// `noauth-greeting.bin` without its `OK`.
    func testAConsoleThatNeverFinishesItsGreetingTimesOut() async throws {
        let full = try EmulatorConsoleFixture.data("noauth-greeting.bin")
        let firstLine = Data(full.prefix(through: try XCTUnwrap(full.firstIndex(of: UInt8(ascii: "\n")))))
        let server = try startConsoleServer {
            try ScriptedConsoleServer(greeting: firstLine) { _, _ in .silence }
        }
        let console = LiveEmulatorConsole(tokenFile: try makeTokenFile(""))
        let started = Date()

        do {
            _ = try await console.run(["avd", "name"], port: server.port, timeout: .milliseconds(400))
            XCTFail("a silent console must time out")
        } catch let error as EmulatorConsoleError {
            XCTAssertEqual(error, .timedOut(.milliseconds(400)))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    /// A cancelled task ends the wait on a silent console within a moment,
    /// not at the bound. SOURCE-DERIVED (a fault injected into the captured
    /// greeting, no adb parity claimed): the same greeting cut before its
    /// `OK`.
    func testCancellingTheTaskEndsTheWait() async throws {
        let full = try EmulatorConsoleFixture.data("noauth-greeting.bin")
        let firstLine = Data(full.prefix(through: try XCTUnwrap(full.firstIndex(of: UInt8(ascii: "\n")))))
        let server = try startConsoleServer {
            try ScriptedConsoleServer(greeting: firstLine) { _, _ in .silence }
        }
        let console = LiveEmulatorConsole(tokenFile: try makeTokenFile(""))
        let started = Date()

        let task = Task { try await console.run(["avd", "name"], port: server.port, timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("a cancelled call must throw")
        } catch is CancellationError {
            // expected
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// A command is one line: an argument with a line break would send a
    /// second command, so nothing is sent.
    func testACommandWithALineBreakIsRefusedBeforeConnecting() async throws {
        let server = try startConsoleServer { try .noAuthentication() }
        let console = LiveEmulatorConsole(tokenFile: try makeTokenFile(""))

        for arguments in [["avd", "name\nkill"], ["avd\r", "name"], []] {
            do {
                _ = try await console.run(arguments, port: server.port, timeout: .seconds(3))
                XCTFail("\(arguments) must be refused")
            } catch let error as EmulatorConsoleError {
                XCTAssertEqual(error, .invalidCommand)
            }
        }
        XCTAssertEqual(server.connectionCount, 0)
    }

    // MARK: - The token

    func testTheTokenIsTheFilesContentWithoutItsLineEnding() throws {
        XCTAssertEqual(EmulatorConsole.token(in: try makeTokenFile("abc123\n")), "abc123")
        XCTAssertEqual(EmulatorConsole.token(in: try makeTokenFile("abc123\r\n")), "abc123")
        XCTAssertEqual(EmulatorConsole.token(in: try makeTokenFile("abc123")), "abc123")
        XCTAssertNil(EmulatorConsole.token(in: try makeTokenFile("")))
        XCTAssertNil(EmulatorConsole.token(in: try makeTokenFile("\n")))
        XCTAssertNil(EmulatorConsole.token(in: try makeTokenFile(nil)))
    }

    /// Where adb and the emulator read it: `$HOME/.emulator_console_auth_token`.
    func testTheDefaultTokenFileIsInTheHomeFolder() {
        let file = EmulatorConsole.defaultTokenFile()
        XCTAssertEqual(file.lastPathComponent, ".emulator_console_auth_token")
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        XCTAssertEqual(file.deletingLastPathComponent().path, URL(fileURLWithPath: home).path)
    }

    // MARK: - The captures, as adb reads them

    /// Why adb prints nothing, from the captured streams (what adb reads,
    /// `*-stream-*.bin`): with no authentication there is one `OK` before the
    /// answer, adb drops two, and the answer goes with the second.
    func testTheCapturedStreamsShowWhereAdbLosesTheAnswer() throws {
        func printedByAdb(_ stream: String) throws -> String {
            let output = try EmulatorConsoleFixture.text(stream)
            var rest = Substring(output)
            for _ in 0..<2 {
                guard let ok = rest.range(of: "OK\r\n") else { break }
                rest = rest[ok.upperBound...]
            }
            return String(rest)
        }
        XCTAssertEqual(try printedByAdb("noauth-stream-avd-name.bin"), "")
        XCTAssertEqual(try printedByAdb("noauth-stream-auth-wrong-token-avd-name.bin"), "")
        XCTAssertEqual(try printedByAdb("auth-stream-auth-avd-name.bin"), "DHP_ConsoleCapture\r\nOK\r\n")
        XCTAssertEqual(try printedByAdb("auth-stream-avd-name-no-auth.bin"), "")
        // The same captures' real adb output, for the commands the app runs.
        XCTAssertEqual(try EmulatorConsoleFixture.data("adb-emu-avd-name-empty-token.stdout.txt").count, 0)
        XCTAssertEqual(try EmulatorConsoleFixture.data("adb-emu-avd-discoverypath-empty-token.stdout.txt").count, 0)
        XCTAssertEqual(try EmulatorConsoleFixture.data("adb-emu-avd-name-token-console-noauth.stdout.txt").count, 0)
    }
}
