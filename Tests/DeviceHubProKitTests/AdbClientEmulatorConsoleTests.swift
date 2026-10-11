import XCTest
@testable import DeviceHubProKit

/// What an emulator console command of `AdbClient` runs: the console
/// directly when the client has a transport, `adb emu` otherwise or when the
/// console cannot be reached. The adb here is a fake that prints the real
/// adb's captured output (`Fixtures/emulator-console/`, `Fixtures/api37-emulator/`),
/// the console a fake transport that answers with the captured console bytes.
///
/// Scrubbed fixtures: the discovery path in `noauth-avd-discoverypath.bin`
/// carries same-length placeholders (user name `aqauser001`, session id all
/// zeros; see the folder's README), and the discovery test below swaps it for
/// a file of its own; nothing else in the fixtures was edited.
final class AdbClientEmulatorConsoleTests: XCTestCase {
    private let serial = "emulator-5580"

    private func fixture(_ name: String) -> URL {
        EmulatorConsoleFixture.directory.appendingPathComponent(name)
    }

    /// A fake adb answering the real adb's captured output, and a client of
    /// it with `console` (nil: none, as every other test's client has).
    private func makeClient(
        _ rules: [FakeAdb.Rule],
        console: FakeEmulatorConsole?
    ) throws -> (adb: FakeAdb, client: AdbClient) {
        let adb = try FakeAdb(rules)
        return (adb, AdbClient(adbURL: adb.tool.executableURL, emulatorConsole: console))
    }

    // MARK: - The empty answer

    /// The user's case end to end: the real adb prints nothing for `emu avd
    /// name` on a console that asks for no authentication (the capture is an
    /// empty file), and the console answers it. With the console the AVD is
    /// named and adb is not asked at all.
    func testTheConsoleNamesTheAvdWhereAdbPrintsNothing() async throws {
        let console = FakeEmulatorConsole { _, _ in try EmulatorConsoleFixture.text("noauth-avd-name.bin") }
        let (adb, client) = try makeClient(
            [.init("emu avd name", stdoutFile: fixture("adb-emu-avd-name-empty-token.stdout.txt"))],
            console: console
        )

        let name = try await client.avdName(serial: serial)

        XCTAssertEqual(name, "DHP_ConsoleCapture")
        XCTAssertEqual(console.calls, [.init(arguments: ["avd", "name"], port: 5580)])
        XCTAssertEqual(adb.calls, [])
    }

    /// An AVD whose name starts with `KO` is named (it is not a console
    /// error): through a fake transport, and through the real one against a
    /// stand-in console, whose answer is the captured `noauth-avd-name.bin`
    /// with another name. SOURCE-DERIVED (AVD names take letters, digits and
    /// `._-`, `AvdmanagerClient.sanitizedAvdName`; no such AVD was captured).
    func testAnAvdNamedLikeAKoLineIsStillTheAvdName() async throws {
        let fake = FakeEmulatorConsole { _, _ in "KOMPAKT_Phone\r\nOK\r\n" }
        let (adb, client) = try makeClient([], console: fake)
        let named = try await client.avdName(serial: serial)
        XCTAssertEqual(named, "KOMPAKT_Phone")
        XCTAssertEqual(adb.calls, [])

        let server = try startConsoleServer {
            try ScriptedConsoleServer(greeting: EmulatorConsoleFixture.data("noauth-greeting.bin")) { _, _ in
                .bytes(Data("KOMPAKT_Phone\r\nOK\r\n".utf8))
            }
        }
        let tokenFile = try makeTokenFile("")
        let fakeAdb = try FakeAdb([])
        let live = AdbClient(adbURL: fakeAdb.tool.executableURL, emulatorConsole: LiveEmulatorConsole(tokenFile: tokenFile))
        let viaSocket = try await live.avdName(serial: "emulator-\(server.port)")
        XCTAssertEqual(viaSocket, "KOMPAKT_Phone")
        XCTAssertEqual(fakeAdb.calls, [], "the name came from the console, no property read")
    }

    /// A client with no console transport asks adb, which prints nothing, and
    /// then reads the name the emulator booted Android with (`getprop
    /// ro.boot.qemu.avd_name`, captured on the same VM).
    func testWithoutAConsoleTheNameComesFromTheBootProperty() async throws {
        let (adb, client) = try makeClient([
            .init("emu avd name", stdoutFile: fixture("adb-emu-avd-name-empty-token.stdout.txt")),
            .init(
                "shell getprop ro.boot.qemu.avd_name",
                stdoutFile: fixture("adb-shell-getprop-ro.boot.qemu.avd_name.stdout.txt")
            ),
        ], console: nil)

        let name = try await client.avdName(serial: serial)

        XCTAssertEqual(name, "DHP_ConsoleCapture")
        XCTAssertEqual(adb.calls, [
            "-s emulator-5580 emu avd name",
            "-s emulator-5580 shell getprop ro.boot.qemu.avd_name",
        ])
    }

    /// A console that answers with a `KO` has no name in it (`AdbParsing.avdName`
    /// would read the KO line as one): the boot property is read instead.
    func testAKoAnswerIsNotAnAvdName() async throws {
        let console = FakeEmulatorConsole { _, _ in try EmulatorConsoleFixture.text("noauth-unknown-command.bin") }
        let (adb, client) = try makeClient([
            .init(
                "shell getprop ro.boot.qemu.avd_name",
                stdoutFile: fixture("adb-shell-getprop-ro.boot.qemu.avd_name.stdout.txt")
            ),
        ], console: console)

        let name = try await client.avdName(serial: serial)

        XCTAssertEqual(name, "DHP_ConsoleCapture")
        XCTAssertEqual(adb.calls, ["-s emulator-5580 shell getprop ro.boot.qemu.avd_name"])
    }

    /// The boot property is trusted only when it is one line: the full
    /// `getprop` dump (a fake that answers every getprop alike) and an empty
    /// answer name nothing, and neither does a failing adb.
    func testOnlyASingleLineIsTakenForTheAvdName() async throws {
        let dump = AdbCoreFixtureTests.url("shell-getprop.txt")
        for (label, rule) in [
            ("the whole dump", FakeAdb.Rule("getprop", stdoutFile: dump)),
            ("nothing", FakeAdb.Rule("getprop", output: "\n")),
            ("two lines", FakeAdb.Rule("getprop", output: "Pixel_9\nPixel_10\n")),
            ("a failure", FakeAdb.Rule("getprop", output: "Pixel_9\n", exitCode: 1)),
        ] {
            let (adb, client) = try makeClient([rule], console: nil)
            let name = try await client.avdName(serial: serial)
            XCTAssertNil(name, label)
            withExtendedLifetime(adb) {}
        }
    }

    /// The property read is for emulators only: a phone's serial has no
    /// console, and `getprop` there would name nothing of ours.
    func testAPhoneIsNeverAskedForAnAvdName() async throws {
        let console = FakeEmulatorConsole { _, _ in XCTFail("a phone has no console"); return "" }
        let (adb, client) = try makeClient([], console: console)

        let name = try await client.avdName(serial: "R58M12345AB")

        XCTAssertNil(name)
        XCTAssertEqual(adb.calls, ["-s R58M12345AB emu avd name"])
        XCTAssertEqual(console.calls, [])
    }

    // MARK: - A console that cannot be reached

    /// Nothing on the console port: adb is asked, the way it always was, and
    /// its output (the captured one for a console that does ask for the token
    /// the client's HOME holds) is the answer.
    func testAnUnreachableConsoleFallsBackToAdb() async throws {
        let console = FakeEmulatorConsole { _, port in
            throw EmulatorConsoleError.couldNotConnect(port: port, reason: "Connection refused")
        }
        let (adb, client) = try makeClient(
            [.init("emu avd name", stdoutFile: fixture("adb-emu-avd-name-auth.stdout.txt"))],
            console: console
        )

        let name = try await client.avdName(serial: serial)
        let output = try await client.emuCommand(serial: serial, ["avd", "name"])

        XCTAssertEqual(name, "DHP_ConsoleCapture")
        XCTAssertEqual(output, "DHP_ConsoleCapture\r\nOK\r\n")
        XCTAssertEqual(adb.calls, ["-s emulator-5580 emu avd name", "-s emulator-5580 emu avd name"])
        XCTAssertEqual(console.calls.count, 2)
    }

    // MARK: - emuCommand

    /// The console's answer is returned as adb's would be, `\r\n` and `OK`
    /// kept.
    func testEmuCommandReturnsTheConsolesAnswer() async throws {
        let console = FakeEmulatorConsole { _, _ in try EmulatorConsoleFixture.text("noauth-avd-grpc.bin") }
        let (adb, client) = try makeClient([], console: console)

        let output = try await client.emuCommand(serial: serial, ["avd", "grpc"])

        XCTAssertEqual(output, "8690\r\nOK\r\n")
        XCTAssertEqual(adb.calls, [])
    }

    /// A `KO` answer throws as it did through adb: `commandFailed` with the
    /// `adb emu` argv, exit status 0 and the console's line.
    func testAKoAnswerThrowsCommandFailed() async throws {
        let console = FakeEmulatorConsole { _, _ in try EmulatorConsoleFixture.text("noauth-unknown-command.bin") }
        let (adb, client) = try makeClient([], console: console)
        defer { withExtendedLifetime(adb) {} }

        do {
            try await client.emuCommand(serial: serial, ["devicehubpro-unknown"])
            XCTFail("a KO answer must throw")
        } catch AdbError.commandFailed(let arguments, let exitCode, let message) {
            XCTAssertEqual(arguments, ["-s", "emulator-5580", "emu", "devicehubpro-unknown"])
            XCTAssertEqual(exitCode, 0)
            XCTAssertEqual(message, "KO: unknown command, try 'help'\r\n")
        }
    }

    /// A refused token or a console that does not talk like one is an error
    /// naming the `adb emu` command, and adb is not asked: it would send the
    /// same token and fail the same way. A name still comes from the boot
    /// property.
    func testAProtocolFailureIsReportedNotRetriedThroughAdb() async throws {
        let console = FakeEmulatorConsole { _, _ in
            throw EmulatorConsoleError.authenticationRejected(
                "KO: authentication token does not match ~/.emulator_console_auth_token"
            )
        }
        let (adb, client) = try makeClient([
            .init(
                "shell getprop ro.boot.qemu.avd_name",
                stdoutFile: fixture("adb-shell-getprop-ro.boot.qemu.avd_name.stdout.txt")
            ),
        ], console: console)

        do {
            try await client.emuCommand(serial: serial, ["avd", "discoverypath"])
            XCTFail("a refused token must throw")
        } catch AdbError.commandFailed(let arguments, _, let message) {
            XCTAssertEqual(arguments, ["-s", "emulator-5580", "emu", "avd", "discoverypath"])
            XCTAssertTrue(message.contains("authentication token does not match"), message)
        }
        XCTAssertEqual(adb.calls, [])

        let name = try await client.avdName(serial: serial)
        XCTAssertEqual(name, "DHP_ConsoleCapture")
        XCTAssertEqual(adb.calls, ["-s emulator-5580 shell getprop ro.boot.qemu.avd_name"])
    }

    /// A console that does not answer in time is a timeout naming the
    /// command, like any bounded call; adb is not asked.
    func testAConsoleThatDoesNotAnswerIsATimeout() async throws {
        let console = FakeEmulatorConsole { _, _ in throw EmulatorConsoleError.timedOut(.milliseconds(250)) }
        let adb = try FakeAdb([])
        let client = AdbClient(
            adbURL: adb.tool.executableURL,
            commandTimeout: .milliseconds(250),
            emulatorConsole: console
        )

        do {
            try await client.emuCommand(serial: serial, ["avd", "name"])
            XCTFail("expected a timeout")
        } catch ProcessRunnerError.timedOut(let command, let seconds) {
            XCTAssertTrue(command.contains("emulator-5580"), command)
            XCTAssertTrue(command.contains("avd name"), command)
            XCTAssertEqual(seconds, .milliseconds(250))
        }
        XCTAssertEqual(adb.calls, [])
    }

    /// The call's bound reaches the console: the client's, or the scope's
    /// `AdbCallTimeout`, as for adb.
    func testTheConsoleGetsTheCallsTimeout() async throws {
        let console = FakeEmulatorConsole { _, _ in "OK\r\n" }
        let adb = try FakeAdb([])
        let client = AdbClient(
            adbURL: adb.tool.executableURL,
            commandTimeout: .seconds(7),
            emulatorConsole: console
        )

        try await client.emuCommand(serial: serial, ["gsm", "meter", "on"])
        try await AdbCallTimeout.$override.withValue(.seconds(2)) {
            try await client.emuCommand(serial: serial, ["gsm", "meter", "off"])
        }

        XCTAssertEqual(console.timeouts, [.seconds(7), .seconds(2)])
    }

    /// Not an emulator serial: adb, never the console.
    func testAnotherSerialAsksAdb() async throws {
        let console = FakeEmulatorConsole { _, _ in XCTFail("no console for this serial"); return "" }
        let (adb, client) = try makeClient(
            [.init("emu avd name", output: "Pixel\r\nOK\r\n")],
            console: console
        )

        let output = try await client.emuCommand(serial: "192.168.1.20:5555", ["avd", "name"])

        XCTAssertEqual(output, "Pixel\r\nOK\r\n")
        XCTAssertEqual(adb.calls, ["-s 192.168.1.20:5555 emu avd name"])
        XCTAssertEqual(console.calls, [])
    }

    /// A client whose adb is not found yet answers `adbNotFound` before any
    /// console is dialled (port 1 has nothing behind it either way), even
    /// the app's, which has a console transport.
    func testAnUnresolvedClientDoesNotDialTheConsole() async {
        let client = AdbClient.unresolvedForApp()
        XCTAssertTrue(client.talksToEmulatorConsoles)

        do {
            try await client.emuCommand(serial: "emulator-1", ["avd", "name"])
            XCTFail("expected adbNotFound")
        } catch AdbError.adbNotFound {
            // expected
        } catch {
            XCTFail("expected adbNotFound, got \(error)")
        }
    }

    // MARK: - resize-display

    /// `resize-display` without an index answers its usage as a `KO`; the
    /// presets come from it through the console too.
    func testResizePresetsComeFromTheConsole() async throws {
        let console = FakeEmulatorConsole { _, _ in
            try EmulatorConsoleFixture.text("noauth-resize-display-no-index.bin")
        }
        let (adb, client) = try makeClient([], console: console)

        let presets = try await client.resizeDisplayPresets(serial: serial)

        XCTAssertEqual(presets, [
            ResizePreset(index: 0, name: "phone"),
            ResizePreset(index: 1, name: "unfolded"),
            ResizePreset(index: 2, name: "tablet"),
        ])
        XCTAssertEqual(console.calls, [.init(arguments: ["resize-display"], port: 5580)])
        XCTAssertEqual(adb.calls, [])
    }

    // MARK: - The gRPC endpoint

    /// `EmulatorDiscovery.grpcInfo` through the console, on the empty-token
    /// Mac: adb prints nothing for `avd discoverypath` (so, with adb alone,
    /// no endpoint and no token is registered: the emulator "isn't sending
    /// its screen"); the console names the discovery file, and the port comes
    /// from it. The file is the API 37 capture (`emulator-discovery-pid.ini`)
    /// with its `grpc.port` line pointing at a port this test owns, so no
    /// default port is touched; the console's answer is the captured
    /// `noauth-avd-discoverypath.bin` with its path replaced by the file's.
    func testTheGrpcEndpointIsFoundThroughTheConsole() async throws {
        let grpcPort = try makeOwnedGrpcPort()
        addTeardownBlock { EmulatorControl.registerToken(nil, forPort: grpcPort) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConsoleDiscovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let ini = directory.appendingPathComponent("pid_7500.ini")
        let captured = try AdbCoreFixtureTests.text("emulator-discovery-pid.ini")
        XCTAssertTrue(captured.contains("grpc.port=8554"))
        try captured.replacingOccurrences(of: "grpc.port=8554", with: "grpc.port=\(grpcPort)")
            .write(to: ini, atomically: true, encoding: .utf8)
        let capturedAnswer = try EmulatorConsoleFixture.text("noauth-avd-discoverypath.bin")
        let capturedPath = try XCTUnwrap(AdbParsing.discoveryPath(from: capturedAnswer))
        let answer = capturedAnswer.replacingOccurrences(of: capturedPath, with: ini.path)
        let console = FakeEmulatorConsole { _, _ in answer }

        let (adbForConsole, viaConsole) = try makeClient([], console: console)
        defer { withExtendedLifetime(adbForConsole) {} }
        let found = await EmulatorDiscovery.grpcInfo(serial: serial, adbClient: viaConsole)

        XCTAssertEqual(found?.port, grpcPort)
        XCTAssertNil(found?.token)

        let (adb, viaAdb) = try makeClient(
            [.init("emu avd discoverypath", stdoutFile: fixture("adb-emu-avd-discoverypath-empty-token.stdout.txt"))],
            console: nil
        )
        let lost = await EmulatorDiscovery.grpcInfo(serial: serial, adbClient: viaAdb)
        XCTAssertNil(lost)
        XCTAssertEqual(adb.calls, ["-s emulator-5580 emu avd discoverypath"])
    }

    // MARK: - Which clients have a console

    /// Only the production constructors give a client a console transport:
    /// every client a test builds with `init(adbURL:)` (the fake adb's, the
    /// stub adbs' of the app suite) or `unresolved()` (the setup tests', which
    /// resolve it to a stub adb) asks its adb alone and never opens a
    /// connection to an emulator running on this Mac. `unresolvedForApp()`,
    /// `AppEnvironment.live()`'s, is the one unresolved client with a console.
    func testOnlyTheProductionConstructorsTalkToConsoles() throws {
        XCTAssertFalse(AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")).talksToEmulatorConsoles)
        XCTAssertFalse(try FakeAdb([]).client.talksToEmulatorConsoles)
        XCTAssertFalse(AdbClient.unresolved().talksToEmulatorConsoles)
        XCTAssertTrue(AdbClient.unresolvedForApp().talksToEmulatorConsoles)
    }

    /// The live transport is built in the two production constructors of
    /// `AdbClient` (`locate`, `unresolvedForApp`) and nowhere else in the
    /// sources: a source scan, since a second place that made one could hand
    /// a test a client that dials the Mac's emulators.
    func testOnlyAdbClientBuildsTheLiveTransport() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        var hits: [String] = []
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: root.appendingPathComponent("Sources", isDirectory: true),
            includingPropertiesForKeys: nil
        ))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated()
            where line.contains("LiveEmulatorConsole(") {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { continue }
                hits.append("\(url.lastPathComponent):\(index + 1)")
            }
        }
        XCTAssertEqual(hits.count, 2, "\(hits)")
        XCTAssertTrue(hits.allSatisfy { $0.hasPrefix("AdbClient.swift:") }, "\(hits)")
    }
}

/// A console transport for tests: it records each call and answers (or
/// throws) as its closure says, without opening a socket.
final class FakeEmulatorConsole: EmulatorConsoleTransport, @unchecked Sendable {
    struct Call: Equatable {
        let arguments: [String]
        let port: Int
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var recordedTimeouts: [Duration] = []
    private let answer: @Sendable ([String], Int) throws -> String

    init(answer: @escaping @Sendable ([String], Int) throws -> String) {
        self.answer = answer
    }

    var calls: [Call] { lock.withLock { recorded } }
    var timeouts: [Duration] { lock.withLock { recordedTimeouts } }

    func run(_ arguments: [String], port: Int, timeout: Duration) async throws -> String {
        lock.withLock {
            recorded.append(Call(arguments: arguments, port: port))
            recordedTimeouts.append(timeout)
        }
        return try answer(arguments, port)
    }
}
