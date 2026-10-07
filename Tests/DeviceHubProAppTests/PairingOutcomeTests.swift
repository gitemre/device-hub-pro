import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// Wireless pairing reports pairing and connecting separately (F5): once
/// `adb pair` succeeded the code is spent, so a failed connect must read as
/// "paired — now connect", and the next press only connects.
@MainActor
final class PairingOutcomeTests: XCTestCase {
    // MARK: - Outcome mapping

    func testConnectedClosesTheSheet() {
        XCTAssertEqual(
            PairingAttemptResult(.connected(address: "192.168.1.42:41234"), host: "192.168.1.42"),
            .connected
        )
    }

    func testPairedWithoutAnEndpointIsNotAFailure() {
        guard case .paired(let host, let message) = PairingAttemptResult(
            .pairedAwaitingConnection,
            host: "192.168.1.42"
        ) else {
            return XCTFail("a successful pair must not be reported as a failure")
        }
        XCTAssertEqual(host, "192.168.1.42")
        XCTAssertTrue(message.hasPrefix("Paired."))
        XCTAssertTrue(message.contains("IP address & Port"))
    }

    func testPairedButConnectFailedNamesTheAddressAndTheNextStep() {
        guard case .paired(_, let message) = PairingAttemptResult(
            .pairedConnectFailed(address: "192.168.1.42:5555", message: "Connection refused"),
            host: "192.168.1.42"
        ) else {
            return XCTFail("a successful pair must not be reported as a failure")
        }
        XCTAssertTrue(message.contains("192.168.1.42:5555"))
        XCTAssertTrue(message.contains("Connection refused"))
        XCTAssertTrue(message.contains("press Connect"))
    }

    func testPairingFailureIsAnError() {
        XCTAssertEqual(
            PairingAttemptResult(.pairingFailed(message: "wrong code"), host: "192.168.1.42"),
            .failed("wrong code")
        )
    }

    // MARK: - Through a fake adb

    func testRefusedConnectAfterASuccessfulPairIsReportedAsPaired() async throws {
        let stub = try makeStubAdb(pair: .succeed, connect: .fail)
        let model = AppModel.testing(adb: stub.client)

        let result = await model.pairing.pairWirelessDevice(
            address: "192.168.1.42:37000",
            code: "123456",
            connectPort: "5555"
        )

        guard case .paired(let host, _) = result else {
            return XCTFail("expected a paired result, got \(result)")
        }
        XCTAssertEqual(host, "192.168.1.42")
        XCTAssertFalse(model.pairing.isPairingDevice)
        XCTAssertNil(model.status.errorMessage)
    }

    func testFailedPairIsAnErrorAndConnectsNothing() async throws {
        let stub = try makeStubAdb(pair: .fail, connect: .succeed)
        let model = AppModel.testing(adb: stub.client)

        let result = await model.pairing.pairWirelessDevice(
            address: "192.168.1.42:37000",
            code: "123456",
            connectPort: "5555"
        )

        guard case .failed = result else { return XCTFail("expected a failure, got \(result)") }
        XCTAssertFalse(calls(stub.callsURL).contains { $0.hasPrefix("connect") })
    }

    func testConnectAfterAPairDoesNotPairAgain() async throws {
        let stub = try makeStubAdb(pair: .succeed, connect: .succeed)
        let model = AppModel.testing(adb: stub.client)

        let result = await model.pairing.pairWirelessDevice(
            address: "192.168.1.42:37000",
            code: "123456",
            connectPort: "41234",
            alreadyPaired: true
        )

        XCTAssertEqual(result, .connected)
        let log = calls(stub.callsURL)
        XCTAssertFalse(log.contains { $0.hasPrefix("pair") }, "the spent code must not be re-used: \(log)")
        XCTAssertTrue(log.contains("connect 192.168.1.42:41234"))
    }

    func testEmptyConnectPortConnectsToTheAnnouncedEndpoint() async throws {
        let stub = try makeStubAdb(pair: .succeed, connect: .succeed)
        let model = AppModel.testing(adb: stub.client)

        let result = await model.pairing.pairWirelessDevice(
            address: "192.168.1.42:37000",
            code: "123456",
            connectPort: ""
        )

        XCTAssertEqual(result, .connected)
        XCTAssertTrue(calls(stub.callsURL).contains("connect 192.168.1.42:41234"))
    }

    // MARK: - Fake adb

    private enum Step { case succeed, fail }

    private struct StubAdb {
        let client: AdbClient
        let callsURL: URL
    }

    /// A fake `adb` logging its argv. `mdns services` announces the phone's
    /// connect endpoint on port 41234; `devices` lists nothing.
    private func makeStubAdb(pair: Step, connect: Step) throws -> StubAdb {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PairingOutcomeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let logURL = directory.appendingPathComponent("calls.log")
        let adbURL = directory.appendingPathComponent("adb")
        let pairOutput = pair == .succeed
            ? "printf 'Successfully paired to 192.168.1.42:37000 [guid=adb-test]\\n'"
            : "printf 'error: protocol fault (couldn'\\''t read status message): Success\\n' >&2; exit 1"
        let connectOutput = connect == .succeed
            ? "printf 'connected to %s\\n' \"$2\""
            : "printf 'failed to connect to %s: Connection refused\\n' \"$2\""
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(logURL.path)"
        case "$1" in
          pair)
            \(pairOutput)
            ;;
          connect)
            \(connectOutput)
            ;;
          mdns)
            printf 'List of discovered mdns services\\n'
            printf 'adb-R58M12345AB-yXk7tu\\t_adb-tls-connect._tcp\\t192.168.1.42:41234\\n'
            ;;
          devices)
            printf 'List of devices attached\\n\\n'
            ;;
          *)
            ;;
        esac
        exit 0
        """
        try Data(script.utf8).write(to: adbURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: adbURL.path
        )
        return StubAdb(client: AdbClient(adbURL: adbURL), callsURL: logURL)
    }

    private func calls(_ logURL: URL) -> [String] {
        ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .map(String.init)
    }
}
