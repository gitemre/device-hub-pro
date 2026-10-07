import XCTest
@testable import DeviceHubProKit

/// `AdbMdnsPolicy`: adb starts without mDNS discovery until a wireless need
/// arrives, so macOS does not ask for Local Network access at launch.
final class AdbMdnsPolicyTests: XCTestCase {
    private var saved: String?

    override func setUp() {
        saved = ProcessInfo.processInfo.environment["ADB_MDNS"]
        unsetenv("ADB_MDNS")
        AdbMdnsPolicy.enable()
    }

    override func tearDown() {
        AdbMdnsPolicy.enable()
        if let saved { setenv("ADB_MDNS", saved, 1) } else { unsetenv("ADB_MDNS") }
    }

    func testWithoutAWirelessNeedEveryAdbIsStartedWithoutMdns() {
        XCTAssertTrue(AdbMdnsPolicy.applyLaunchPolicy(localNetworkWanted: false, launchEnvironment: [:]))
        XCTAssertEqual(ProcessInfo.processInfo.environment["ADB_MDNS"], "0", "children inherit it")
        XCTAssertTrue(AdbMdnsPolicy.isDisabledByApp)
    }

    func testAMacThatUsedWirelessDebuggingStartsWithMdnsAtOnce() {
        XCTAssertFalse(AdbMdnsPolicy.applyLaunchPolicy(localNetworkWanted: true, launchEnvironment: [:]))
        XCTAssertNil(ProcessInfo.processInfo.environment["ADB_MDNS"])
    }

    func testALaunchEnvironmentThatSetsItIsLeftAlone() {
        XCTAssertFalse(AdbMdnsPolicy.applyLaunchPolicy(localNetworkWanted: false, launchEnvironment: ["ADB_MDNS": "1"]))
        XCTAssertNil(ProcessInfo.processInfo.environment["ADB_MDNS"])
        XCTAssertFalse(AdbMdnsPolicy.enable(), "nothing of the app's to undo")
    }

    func testTheFirstNeedEnablesItOnceAndSaysAServerMayNeedARestart() {
        AdbMdnsPolicy.applyLaunchPolicy(localNetworkWanted: false, launchEnvironment: [:])
        XCTAssertTrue(AdbMdnsPolicy.enable())
        XCTAssertNil(ProcessInfo.processInfo.environment["ADB_MDNS"])
        XCTAssertFalse(AdbMdnsPolicy.isDisabledByApp)
        XCTAssertFalse(AdbMdnsPolicy.enable(), "the second need changes nothing")
    }

    /// `Fixtures/adb-mdns/check-*.stdout`: `adb -P 5599 mdns check` against a
    /// private server started with and without `ADB_MDNS=0`, platform-tools
    /// 37.0.1, 2026-10-02, byte-exact (exit 0, nothing on stderr).
    func testAdbsOwnAnswerTellsADisabledServerFromARunningOne() throws {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/adb-mdns")
        let disabled = try String(contentsOf: fixtures.appendingPathComponent("check-disabled.stdout"), encoding: .utf8)
        let enabled = try String(contentsOf: fixtures.appendingPathComponent("check-enabled.stdout"), encoding: .utf8)
        XCTAssertTrue(AdbMdnsPolicy.reportsDisabled(disabled))
        XCTAssertFalse(AdbMdnsPolicy.reportsDisabled(enabled))
        XCTAssertTrue(AdbBlockedDetector.mdnsCheckReportsRunning(enabled))
        XCTAssertFalse(AdbBlockedDetector.mdnsCheckReportsRunning(disabled))
    }

    func testAClientReadsADisabledServerFromItsAnswer() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mdns-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let adb = dir.appendingPathComponent("adb")
        try "#!/bin/sh\necho 'ERROR: mdns discovery disabled'\n".write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        let disabled = await AdbClient(adbURL: adb).mdnsDiscoveryDisabled()
        XCTAssertTrue(disabled)

        try "#!/bin/sh\necho 'mdns daemon version [adb discovery 0.0.0]'\n".write(to: adb, atomically: true, encoding: .utf8)
        let enabled = await AdbClient(adbURL: adb).mdnsDiscoveryDisabled()
        XCTAssertFalse(enabled)
        let none = await AdbClient.unresolved().mdnsDiscoveryDisabled()
        XCTAssertFalse(none)
    }
}
