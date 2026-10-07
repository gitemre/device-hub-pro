import XCTest
@testable import DeviceHubProKit

/// Wireless pairing (spec §11.3): the pure request parsing/validation, and the
/// `AdbClient` pair/connect helpers exercised against a fake `adb` executable
/// that logs its argv and replays scripted output.
final class WirelessPairingTests: XCTestCase {
    // MARK: - Request parsing

    func testRequestParsesThePairingAddressAndCode() throws {
        let request = try WirelessPairing.request(
            address: "192.168.1.42:37000",
            code: "123456",
            connectPort: "5555"
        )

        XCTAssertEqual(request.host, "192.168.1.42")
        XCTAssertEqual(request.pairingPort, 37000)
        XCTAssertEqual(request.connectPort, 5555)
        XCTAssertEqual(request.code, "123456")
        XCTAssertEqual(request.pairingAddress, "192.168.1.42:37000")
        XCTAssertEqual(request.connectAddress, "192.168.1.42:5555")
    }

    func testRequestTrimsWhitespaceAroundEveryField() throws {
        let request = try WirelessPairing.request(
            address: "  192.168.1.42:37000  ",
            code: " 123456 ",
            connectPort: " 5555 "
        )

        XCTAssertEqual(request.host, "192.168.1.42")
        XCTAssertEqual(request.pairingPort, 37000)
        XCTAssertEqual(request.connectPort, 5555)
        XCTAssertEqual(request.code, "123456")
    }

    /// Android 11+'s pairing-code flow uses a random connect port, never the
    /// legacy 5555, so an empty field means "discover it" (F11) — not 5555.
    func testRequestLeavesTheConnectPortUnsetWhenEmpty() throws {
        let request = try WirelessPairing.request(
            address: "192.168.1.42:37000",
            code: "123456",
            connectPort: "  "
        )

        XCTAssertNil(request.connectPort)
        XCTAssertNil(request.connectAddress)
        XCTAssertEqual(request.pairingAddress, "192.168.1.42:37000")
    }

    /// The pairing address is split at its *last* colon, so a bracketed IPv6
    /// host survives (`adb connect` accepts bracket notation).
    func testRequestKeepsABracketedIPv6Host() throws {
        let request = try WirelessPairing.request(
            address: "[fe80::1]:37000",
            code: "123456",
            connectPort: "5555"
        )

        XCTAssertEqual(request.host, "[fe80::1]")
        XCTAssertEqual(request.pairingAddress, "[fe80::1]:37000")
        XCTAssertEqual(request.connectAddress, "[fe80::1]:5555")
    }

    func testRequestRejectsAMissingPairingPort() {
        XCTAssertThrowsError(
            try WirelessPairing.request(
                address: "192.168.1.42",
                code: "123456",
                connectPort: "5555"
            )
        ) { error in
            XCTAssertEqual(error as? WirelessPairing.ValidationError, .missingPort)
        }
    }

    func testRequestRejectsAnEmptyAddress() {
        XCTAssertThrowsError(
            try WirelessPairing.request(address: "  ", code: "123456", connectPort: "5555")
        ) { error in
            XCTAssertEqual(error as? WirelessPairing.ValidationError, .emptyAddress)
        }
        XCTAssertThrowsError(
            try WirelessPairing.request(address: ":37000", code: "123456", connectPort: "5555")
        ) { error in
            XCTAssertEqual(error as? WirelessPairing.ValidationError, .emptyAddress)
        }
    }

    func testRequestRejectsNonNumericOrOutOfRangePairingPorts() {
        for address in ["192.168.1.42:abc", "192.168.1.42:0", "192.168.1.42:70000", "192.168.1.42:"] {
            XCTAssertThrowsError(
                try WirelessPairing.request(address: address, code: "123456", connectPort: "5555"),
                "expected \(address) to be rejected"
            ) { error in
                XCTAssertEqual(error as? WirelessPairing.ValidationError, .invalidPairingPort)
            }
        }
    }

    func testRequestRejectsNonNumericOrOutOfRangeConnectPorts() {
        for connectPort in ["abc", "0", "70000"] {
            XCTAssertThrowsError(
                try WirelessPairing.request(
                    address: "192.168.1.42:37000",
                    code: "123456",
                    connectPort: connectPort
                ),
                "expected \(connectPort) to be rejected"
            ) { error in
                XCTAssertEqual(error as? WirelessPairing.ValidationError, .invalidConnectPort)
            }
        }
    }

    func testRequestRejectsAnythingThatIsNotASixDigitCode() {
        for code in ["", "12345", "1234567", "12345a", "12 3456"] {
            XCTAssertThrowsError(
                try WirelessPairing.request(
                    address: "192.168.1.42:37000",
                    code: code,
                    connectPort: "5555"
                ),
                "expected \(code.debugDescription) to be rejected"
            ) { error in
                XCTAssertEqual(error as? WirelessPairing.ValidationError, .invalidCode)
            }
        }
    }

    // MARK: - AdbClient.pair / AdbClient.connect (fake adb)

    func testPairRunsAdbPairWithTheAddressAndCode() async throws {
        let stub = try makeStubAdb(
            stdout: "Successfully paired to 192.168.1.42:37000 [guid=adb-test]\n"
        )

        let output = try await stub.client.pair(address: "192.168.1.42:37000", code: "123456")

        XCTAssertEqual(output, "Successfully paired to 192.168.1.42:37000 [guid=adb-test]\n")
        XCTAssertEqual(stub.calls(), ["pair 192.168.1.42:37000 123456"])
    }

    func testPairFailureThrowsWithAdbStderr() async throws {
        let stub = try makeStubAdb(
            stderr: "Failed to pair to 192.168.1.42:37000: wrong password\n",
            exitCode: 1
        )

        do {
            _ = try await stub.client.pair(address: "192.168.1.42:37000", code: "000000")
            XCTFail("expected the failed pairing to throw")
        } catch let error as AdbError {
            XCTAssertTrue(
                error.description.contains("wrong password"),
                "the failure must carry adb's stderr: \(error.description)"
            )
            XCTAssertTrue(error.description.contains("pair 192.168.1.42:37000 000000"))
        }
    }

    /// Platform-tools builds that print the failure on stdout with a zero
    /// exit must not read as success.
    func testPairFailureOnStdoutWithAZeroExitStillThrows() async throws {
        let stub = try makeStubAdb(
            stdout: "Failed to pair to 192.168.1.42:37000: wrong password\n"
        )

        do {
            _ = try await stub.client.pair(address: "192.168.1.42:37000", code: "000000")
            XCTFail("expected the failed pairing to throw")
        } catch let error as AdbError {
            XCTAssertTrue(error.description.contains("wrong password"))
        }
    }

    func testConnectRunsAdbConnect() async throws {
        let stub = try makeStubAdb(stdout: "connected to 192.168.1.42:5555\n")

        let output = try await stub.client.connect(address: "192.168.1.42:5555")

        XCTAssertEqual(output, "connected to 192.168.1.42:5555\n")
        XCTAssertEqual(stub.calls(), ["connect 192.168.1.42:5555"])
    }

    /// `adb connect` exits 0 even when the connection fails — the failure is
    /// the stdout text, so the helper must inspect it.
    func testConnectFailureThrowsDespiteTheZeroExit() async throws {
        let stub = try makeStubAdb(
            stdout: "failed to connect to '192.168.1.42:5555': Connection refused\n"
        )

        do {
            _ = try await stub.client.connect(address: "192.168.1.42:5555")
            XCTFail("expected the failed connection to throw")
        } catch let error as AdbError {
            XCTAssertTrue(
                error.description.contains("Connection refused"),
                "the failure must carry adb's stdout: \(error.description)"
            )
        }
    }

    func testConnectTreatsAlreadyConnectedAsSuccess() async throws {
        let stub = try makeStubAdb(stdout: "already connected to 192.168.1.42:5555\n")

        let output = try await stub.client.connect(address: "192.168.1.42:5555")

        XCTAssertEqual(output, "already connected to 192.168.1.42:5555\n")
    }

    /// The flow the app performs: pair on the pairing address, then connect on
    /// the (usually different) connect port, in that order.
    func testPairThenConnectUsesThePairingAddressThenTheConnectAddress() async throws {
        let stub = try makeFlowStubAdb()

        let request = try WirelessPairing.request(
            address: "192.168.1.42:37000",
            code: "123456",
            connectPort: "5555"
        )
        _ = try await stub.client.pair(address: request.pairingAddress, code: request.code)
        _ = try await stub.client.connect(address: try XCTUnwrap(request.connectAddress))

        XCTAssertEqual(stub.calls(), [
            "pair 192.168.1.42:37000 123456",
            "connect 192.168.1.42:5555",
        ])
    }

    // MARK: - mDNS discovery

    private static let mdnsOutput = """
    List of discovered mdns services
    adb-R58M12345AB-yXk7tu\t_adb-tls-connect._tcp.\t192.168.1.42:37215
    adb-R58M12345AB-yXk7tu\t_adb-tls-pairing._tcp.\t192.168.1.42:41117
    adb-OTHERPHONE-a1b2c3\t_adb-tls-connect._tcp\t192.168.1.77:40001
    adb-legacy\t_adb._tcp\t192.168.1.90:5555

    """

    func testParsesMdnsServicesWithAndWithoutTheTrailingDot() {
        let services = WirelessPairing.mdnsServices(from: Self.mdnsOutput)
        XCTAssertEqual(services, [
            .init(instance: "adb-R58M12345AB-yXk7tu", type: "_adb-tls-connect._tcp", host: "192.168.1.42", port: 37215),
            .init(instance: "adb-R58M12345AB-yXk7tu", type: "_adb-tls-pairing._tcp", host: "192.168.1.42", port: 41117),
            .init(instance: "adb-OTHERPHONE-a1b2c3", type: "_adb-tls-connect._tcp", host: "192.168.1.77", port: 40001),
            .init(instance: "adb-legacy", type: "_adb._tcp", host: "192.168.1.90", port: 5555),
        ])
        XCTAssertEqual(services[0].address, "192.168.1.42:37215")
    }

    func testMdnsParsingSkipsTheHeaderNoiseAndMalformedRows() {
        let output = """
        * daemon not running; starting now at tcp:5037
        List of discovered mdns services
        garbage
        adb-x\t_adb-tls-connect._tcp\t192.168.1.5:notaport
        adb-y  _adb-tls-connect._tcp  192.168.1.6:40000
        """
        XCTAssertEqual(
            WirelessPairing.mdnsServices(from: output),
            [.init(instance: "adb-y", type: "_adb-tls-connect._tcp", host: "192.168.1.6", port: 40000)]
        )
        XCTAssertTrue(WirelessPairing.mdnsServices(from: "List of discovered mdns services\n").isEmpty)
    }

    /// The connect endpoint is the paired host's own `_adb-tls-connect`
    /// service — never its pairing service, never another phone's.
    func testConnectEndpointMatchesTheHostAndServiceType() {
        let services = WirelessPairing.mdnsServices(from: Self.mdnsOutput)
        XCTAssertEqual(
            WirelessPairing.connectEndpoint(forHost: "192.168.1.42", in: services),
            "192.168.1.42:37215"
        )
        XCTAssertEqual(
            WirelessPairing.connectEndpoint(forHost: "192.168.1.77", in: services),
            "192.168.1.77:40001"
        )
        XCTAssertNil(WirelessPairing.connectEndpoint(forHost: "192.168.1.90", in: services))
        XCTAssertNil(WirelessPairing.connectEndpoint(forHost: "192.168.1.200", in: services))
    }

    /// An IPv6 host matches whether either side carries brackets.
    func testConnectEndpointMatchesABracketedIPv6Host() {
        let services = [WirelessPairing.MdnsService(
            instance: "adb-x", type: "_adb-tls-connect._tcp", host: "[fe80::1]", port: 40000
        )]
        XCTAssertNotNil(WirelessPairing.connectEndpoint(forHost: "fe80::1", in: services))
        XCTAssertNotNil(WirelessPairing.connectEndpoint(forHost: "[fe80::1]", in: services))
    }

    // MARK: - pairAndConnect (fake adb)

    /// A fake adb whose `pair`, `mdns services` and `connect` answers are
    /// scripted per test.
    private func makeFlowStub(
        pair: String = "printf 'Successfully paired to 192.168.1.42:37000 [guid=adb-test]\\n'",
        mdns: String = "printf 'List of discovered mdns services\\n'",
        connect: String = "printf 'connected to %s\\n' \"$2\"",
        devices: String = "exit 1"
    ) throws -> StubAdb {
        let directory = try makeStubDirectory()
        let logURL = directory.appendingPathComponent("calls.log")
        let adbURL = directory.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(logURL.path)"
        case "$1" in
          pair) \(pair) ;;
          mdns) \(mdns) ;;
          connect) \(connect) ;;
          devices) \(devices) ;;
          *) exit 1 ;;
        esac
        """
        try writeExecutable(script, to: adbURL)
        return StubAdb(client: AdbClient(adbURL: adbURL), calls: { Self.readCalls(logURL) })
    }

    private func mdnsPrintf(_ output: String) -> String {
        "printf '%s' '\(output)'"
    }

    /// No connect port given: after pairing, the phone's announced endpoint
    /// is discovered and connected — no 5555 guess.
    func testPairAndConnectDiscoversTheEndpointWhenNoPortIsGiven() async throws {
        let stub = try makeFlowStub(mdns: mdnsPrintf(Self.mdnsOutput))
        let request = try WirelessPairing.request(
            address: "192.168.1.42:37000",
            code: "123456",
            connectPort: ""
        )

        let outcome = try await stub.client.pairAndConnect(request, discoveryTimeout: .seconds(2), attachGrace: .zero)

        XCTAssertEqual(outcome, .connected(address: "192.168.1.42:37215"))
        XCTAssertEqual(stub.calls(), [
            "pair 192.168.1.42:37000 123456",
            "mdns services",
            "devices -l",
            "mdns services",
            "connect 192.168.1.42:37215",
        ])
    }

    /// An explicit connect port is used as given, without discovery.
    func testPairAndConnectUsesAGivenPortWithoutDiscovery() async throws {
        let stub = try makeFlowStub(mdns: mdnsPrintf(Self.mdnsOutput))
        let request = try WirelessPairing.request(
            address: "192.168.1.42:37000",
            code: "123456",
            connectPort: "40123"
        )

        let outcome = try await stub.client.pairAndConnect(request, discoveryTimeout: .seconds(2), attachGrace: .zero)

        XCTAssertEqual(outcome, .connected(address: "192.168.1.42:40123"))
        XCTAssertEqual(stub.calls(), [
            "pair 192.168.1.42:37000 123456",
            "devices -l",
            "mdns services",
            "connect 192.168.1.42:40123",
        ])
    }

    /// The phone is already online under an `ip:port` of its host (adb's
    /// auto-connect or an earlier connect): the given port is not connected
    /// to a second time.
    func testPairAndConnectSkipsTheConnectWhenTheHostIsAlreadyOnline() async throws {
        let stub = try makeFlowStub(
            devices: "printf 'List of devices attached\\n192.168.1.42:41473\\tdevice product:p model:m device:d transport_id:6\\n'"
        )
        let request = try WirelessPairing.request(
            address: "192.168.1.42:37000",
            code: "123456",
            connectPort: "40123"
        )

        let outcome = try await stub.client.pairAndConnect(request, discoveryTimeout: .seconds(2), attachGrace: .zero)

        XCTAssertEqual(outcome, .connected(address: "192.168.1.42:41473"))
        XCTAssertFalse(stub.calls().contains { $0.hasPrefix("connect") })
    }

    /// A successful pair whose connect fails is reported as paired, not as a
    /// failed flow: the keys are stored and the phone may still attach.
    func testPairAndConnectReportsAConnectFailureAfterASuccessfulPair() async throws {
        let stub = try makeFlowStub(
            connect: "printf \"failed to connect to '%s': Connection refused\\n\" \"$2\""
        )
        let request = try WirelessPairing.request(
            address: "192.168.1.42:37000",
            code: "123456",
            connectPort: "5555"
        )

        let outcome = try await stub.client.pairAndConnect(request, discoveryTimeout: .seconds(2))

        guard case .pairedConnectFailed(let address, let message) = outcome else {
            return XCTFail("expected pairedConnectFailed, got \(outcome)")
        }
        XCTAssertEqual(address, "192.168.1.42:5555")
        XCTAssertTrue(message.contains("Connection refused"), message)
        XCTAssertTrue(outcome.isPaired)
    }

    func testPairAndConnectWaitsForTheEndpointThenReportsPaired() async throws {
        let stub = try makeFlowStub()
        let request = try WirelessPairing.request(
            address: "192.168.1.42:37000",
            code: "123456",
            connectPort: ""
        )

        let outcome = try await stub.client.pairAndConnect(request, discoveryTimeout: .milliseconds(300))

        XCTAssertEqual(outcome, .pairedAwaitingConnection)
        XCTAssertTrue(outcome.isPaired)
        XCTAssertFalse(stub.calls().contains { $0.hasPrefix("connect") }, "nothing to connect to yet")
    }

    func testPairAndConnectStopsWhenPairingFails() async throws {
        let stub = try makeFlowStub(
            pair: "printf 'Failed to pair to 192.168.1.42:37000: wrong password\\n' >&2; exit 1"
        )
        let request = try WirelessPairing.request(
            address: "192.168.1.42:37000",
            code: "000000",
            connectPort: ""
        )

        let outcome = try await stub.client.pairAndConnect(request, discoveryTimeout: .seconds(2))

        guard case .pairingFailed(let message) = outcome else {
            return XCTFail("expected pairingFailed, got \(outcome)")
        }
        XCTAssertTrue(message.contains("wrong password"), message)
        XCTAssertFalse(outcome.isPaired)
        XCTAssertEqual(stub.calls(), ["pair 192.168.1.42:37000 000000"])
    }

    // MARK: - Fake adb harness

    private struct StubAdb {
        let client: AdbClient
        let calls: () -> [String]
    }

    /// A fake `adb` that logs its argv and replays fixed stdout/stderr/exit.
    private func makeStubAdb(
        stdout: String = "",
        stderr: String = "",
        exitCode: Int32 = 0
    ) throws -> StubAdb {
        let directory = try makeStubDirectory()
        let logURL = directory.appendingPathComponent("calls.log")
        let adbURL = directory.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(logURL.path)"
        if [ -n "\(stdout)" ]; then printf '%s' "\(stdout)"; fi
        if [ -n "\(stderr)" ]; then printf '%s' "\(stderr)" >&2; fi
        exit \(exitCode)
        """
        try writeExecutable(script, to: adbURL)
        return StubAdb(
            client: AdbClient(adbURL: adbURL),
            calls: { Self.readCalls(logURL) }
        )
    }

    /// A fake `adb` whose `pair` and `connect` both succeed, so the flow's
    /// command construction and ordering can be asserted.
    private func makeFlowStubAdb() throws -> StubAdb {
        let directory = try makeStubDirectory()
        let logURL = directory.appendingPathComponent("calls.log")
        let adbURL = directory.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(logURL.path)"
        case "$1" in
          pair)
            printf 'Successfully paired to 192.168.1.42:37000 [guid=adb-test]\\n'
            ;;
          connect)
            printf 'connected to 192.168.1.42:5555\\n'
            ;;
          *)
            printf 'unexpected: %s\\n' "$*" >&2
            exit 1
            ;;
        esac
        exit 0
        """
        try writeExecutable(script, to: adbURL)
        return StubAdb(
            client: AdbClient(adbURL: adbURL),
            calls: { Self.readCalls(logURL) }
        )
    }

    private func makeStubDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WirelessPairingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func writeExecutable(_ script: String, to url: URL) throws {
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private static func readCalls(_ logURL: URL) -> [String] {
        ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .map(String.init)
    }
}
