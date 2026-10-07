import XCTest
@testable import DeviceHubProKit

/// Android Studio-style QR pairing: the QR text,
/// the credential shape, matching the phone's `_adb-tls-pairing._tcp`
/// announcement, and the pair-then-connect flow against a fake `adb`. The mDNS
/// rows are SOURCE-DERIVED from `adb mdns services`' row format (captured in
/// `api37-emulator/adb-core/adb-mdns-services.txt`) with the service types
/// taken from adb's source; no phone was scanned.
final class WirelessQRPairingTests: XCTestCase {
    private static let credentials = WirelessPairing.QRCredentials(serviceName: "studio-AbCd123456", password: "Zq9xW2mK7vLp")

    func testThePayloadIsTheAdbWifiQRText() {
        XCTAssertEqual(
            Self.credentials.payload,
            "WIFI:T:ADB;S:studio-AbCd123456;P:Zq9xW2mK7vLp;;"
        )
    }

    func testThePayloadEscapesSeparators() {
        let odd = WirelessPairing.QRCredentials(serviceName: "a;b", password: "c:d\\e")
        XCTAssertEqual(odd.payload, "WIFI:T:ADB;S:a\\;b;P:c\\:d\\\\e;;")
    }

    func testGeneratedCredentialsHaveStudioShapeAndAreFresh() {
        let first = WirelessPairing.makeQRCredentials()
        let second = WirelessPairing.makeQRCredentials()
        XCTAssertTrue(first.serviceName.hasPrefix("studio-"))
        XCTAssertEqual(first.serviceName.count, "studio-".count + 10)
        XCTAssertEqual(first.password.count, 12)
        XCTAssertTrue(first.password.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
        XCTAssertNotEqual(first, second)
    }

    func testOnlyThePairingServiceWithTheExactNameMatches() {
        let services: [WirelessPairing.MdnsService] = [
            .init(instance: "studio-AbCd123456", type: "_adb-tls-connect._tcp", host: "192.168.1.42", port: 37215),
            .init(instance: "studio-OTHER00000", type: "_adb-tls-pairing._tcp", host: "192.168.1.77", port: 41000),
            .init(instance: "studio-AbCd123456", type: "_adb-tls-pairing._tcp", host: "192.168.1.42", port: 41117),
        ]
        XCTAssertEqual(
            WirelessPairing.pairingEndpoint(serviceName: "studio-AbCd123456", in: services)?.address,
            "192.168.1.42:41117"
        )
        XCTAssertNil(WirelessPairing.pairingEndpoint(serviceName: "studio-missing", in: services))
    }

    // MARK: - The flow (fake adb)

    private struct StubAdb {
        let client: AdbClient
        let calls: () -> [String]
    }

    private func makeStub(
        mdns: String,
        pair: String = "printf 'Successfully paired to x [guid=adb-test]\\n'",
        devices: String = "exit 1"
    ) throws -> StubAdb {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WirelessQRPairingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("calls.log")
        let adb = directory.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(log.path)"
        case "$1" in
          pair) \(pair) ;;
          mdns) \(mdns) ;;
          connect) printf 'connected to %s\\n' "$2" ;;
          devices) \(devices) ;;
          *) exit 1 ;;
        esac
        """
        try Data(script.utf8).write(to: adb)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        return StubAdb(client: AdbClient(adbURL: adb), calls: {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        })
    }

    private static let bothServices = """
    printf 'List of discovered mdns services\\nstudio-AbCd123456\\t_adb-tls-pairing._tcp\\t192.168.1.42:41117\\nadb-R58M12345AB-yXk7tu\\t_adb-tls-connect._tcp\\t192.168.1.42:37215\\n'
    """

    func testAScannedCodePairsWithThePasswordThenConnectsToTheSameHost() async throws {
        let stub = try makeStub(mdns: Self.bothServices)
        let outcome = try await stub.client.pairWithQR(Self.credentials, scanTimeout: .seconds(2), discoveryTimeout: .seconds(2), attachGrace: .zero)
        XCTAssertEqual(outcome, .scanned(host: "192.168.1.42", outcome: .connected(address: "192.168.1.42:37215")))
        XCTAssertEqual(stub.calls(), [
            "mdns services",
            "pair 192.168.1.42:41117 Zq9xW2mK7vLp",
            "mdns services",
            "devices -l",
            "mdns services",
            "connect 192.168.1.42:37215",
        ])
    }

    /// adb's own mDNS auto-connect already attached the phone (the entry
    /// `adb-<ro.serialno>-<suffix>._adb-tls-connect._tcp`): no second,
    /// explicit `adb connect`, so the phone is not listed twice.
    func testAPhoneAdbAutoConnectedIsNotConnectedASecondTime() async throws {
        let stub = try makeStub(
            mdns: Self.bothServices,
            devices: "printf 'List of devices attached\\nadb-R58M12345AB-yXk7tu._adb-tls-connect._tcp device product:p model:m device:d transport_id:5\\n'"
        )
        let outcome = try await stub.client.pairWithQR(Self.credentials, scanTimeout: .seconds(2), discoveryTimeout: .seconds(2), attachGrace: .zero)
        XCTAssertEqual(outcome, .scanned(
            host: "192.168.1.42",
            outcome: .connected(address: "adb-R58M12345AB-yXk7tu._adb-tls-connect._tcp")
        ))
        XCTAssertFalse(stub.calls().contains { $0.hasPrefix("connect") })
    }

    func testACodeThatIsNeverScannedPairsNothing() async throws {
        let stub = try makeStub(mdns: "printf 'List of discovered mdns services\\n'")
        let outcome = try await stub.client.pairWithQR(Self.credentials, scanTimeout: .milliseconds(300))
        XCTAssertEqual(outcome, .notScanned)
        XCTAssertFalse(stub.calls().contains { $0.hasPrefix("pair") || $0.hasPrefix("connect") })
    }

    func testAPairFailureIsReportedAndNothingConnects() async throws {
        let stub = try makeStub(mdns: Self.bothServices, pair: "printf 'Failed: wrong password\\n' >&2; exit 1")
        let outcome = try await stub.client.pairWithQR(Self.credentials, scanTimeout: .seconds(2))
        guard case .scanned(_, .pairingFailed) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(stub.calls().contains { $0.hasPrefix("connect") })
    }

    func testPairedWithoutAConnectServiceWaitsThenReportsPaired() async throws {
        let stub = try makeStub(mdns: "printf 'List of discovered mdns services\\nstudio-AbCd123456\\t_adb-tls-pairing._tcp\\t192.168.1.42:41117\\n'")
        let outcome = try await stub.client.pairWithQR(Self.credentials, scanTimeout: .seconds(2), discoveryTimeout: .milliseconds(300))
        XCTAssertEqual(outcome, .scanned(host: "192.168.1.42", outcome: .pairedAwaitingConnection))
    }
}
