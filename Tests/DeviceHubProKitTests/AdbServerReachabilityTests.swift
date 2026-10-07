import XCTest
@testable import DeviceHubProKit

/// `AdbBlockedDetector`: a pure function of (services the app sees, services
/// adb lists, timestamps). No adb server is started by these tests.
final class AdbServerReachabilityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let connect = "_adb-tls-connect._tcp"

    private func seen(_ name: String = "adb-AAA-bbb", type: String? = nil, since: TimeInterval = 0) -> ObservedBonjourService {
        ObservedBonjourService(name: name, type: type ?? connect, firstSeen: t0.addingTimeInterval(since))
    }

    private func listed(_ name: String = "adb-AAA-bbb", type: String? = nil) -> WirelessPairing.MdnsService {
        .init(instance: name, type: type ?? connect, host: "192.0.2.10", port: 40000)
    }

    private func input(
        inApp: [ObservedBonjourService],
        adb: [WirelessPairing.MdnsService] = [],
        running: Bool = true,
        noRoute: Bool = false,
        busy: Bool = false,
        at seconds: TimeInterval
    ) -> AdbBlockedInput {
        AdbBlockedInput(
            inApp: inApp, adbServices: adb, adbMdnsRunning: running,
            noRouteToReachableHost: noRoute, busy: busy, now: t0.addingTimeInterval(seconds))
    }

    func testAServiceAdbListsIsNotBlocked() {
        let r = AdbBlockedDetector.evaluate(state: .init(), input: input(inApp: [seen()], adb: [listed()], at: 20))
        XCTAssertEqual(r.decision, .none)
        XCTAssertEqual(r.state.consecutiveBlockedChecks, 0)
    }

    func testAYoungServiceIsNotCounted() {
        let r = AdbBlockedDetector.evaluate(state: .init(), input: input(inApp: [seen()], at: 5))
        XCTAssertEqual(r.decision, .none)
        XCTAssertEqual(r.state.consecutiveBlockedChecks, 0, "6 seconds or younger never counts")
    }

    func testTwoConfirmingChecksRestart() {
        var state = AdbBlockedState()
        var r = AdbBlockedDetector.evaluate(state: state, input: input(inApp: [seen()], at: 10))
        XCTAssertEqual(r.decision, .none, "one check is not enough")
        state = r.state
        r = AdbBlockedDetector.evaluate(state: state, input: input(inApp: [seen()], at: 14))
        XCTAssertEqual(r.decision, .restart)
        XCTAssertEqual(r.state.lastRestart, t0.addingTimeInterval(14))
        XCTAssertEqual(r.state.consecutiveBlockedChecks, 0)
    }

    func testAHealthyCheckBetweenResetsTheCount() {
        var r = AdbBlockedDetector.evaluate(state: .init(), input: input(inApp: [seen()], at: 10))
        r = AdbBlockedDetector.evaluate(state: r.state, input: input(inApp: [seen()], adb: [listed()], at: 14))
        XCTAssertEqual(r.state.consecutiveBlockedChecks, 0)
        r = AdbBlockedDetector.evaluate(state: r.state, input: input(inApp: [seen()], at: 18))
        XCTAssertEqual(r.decision, .none)
    }

    func testNothingHappensUnlessTheMdnsDaemonRuns() {
        var state = AdbBlockedState(consecutiveBlockedChecks: 5)
        let r = AdbBlockedDetector.evaluate(state: state, input: input(inApp: [seen()], running: false, at: 30))
        state = r.state
        XCTAssertEqual(r.decision, .none)
        XCTAssertEqual(state.consecutiveBlockedChecks, 0)
    }

    func testTypeMatchingIgnoresTheTrailingDomain() {
        let r = AdbBlockedDetector.evaluate(
            state: .init(consecutiveBlockedChecks: 1),
            input: input(inApp: [seen(type: "_adb-tls-connect._tcp.local.")], adb: [listed(type: "_adb-tls-connect._tcp.")], at: 30))
        XCTAssertEqual(r.decision, .none)
    }

    func testAPairingServiceAdbMissesCounts() {
        let r = AdbBlockedDetector.evaluate(
            state: .init(consecutiveBlockedChecks: 1),
            input: input(inApp: [seen("studio-xyz", type: "_adb-tls-pairing._tcp")], adb: [listed("studio-xyz")], at: 30))
        XCTAssertEqual(r.decision, .restart, "the same instance name under another type is not the listed service")
    }

    func testNoRouteToAReachableHostIsTheSecondSignal() {
        var r = AdbBlockedDetector.evaluate(state: .init(), input: input(inApp: [], noRoute: true, at: 1))
        XCTAssertEqual(r.decision, .none)
        r = AdbBlockedDetector.evaluate(state: r.state, input: input(inApp: [], noRoute: true, at: 5))
        XCTAssertEqual(r.decision, .restart)
    }

    func testARecordingOrInstallDefersTheRestartUntilItEnds() {
        var state = AdbBlockedState(consecutiveBlockedChecks: 1)
        var r = AdbBlockedDetector.evaluate(state: state, input: input(inApp: [seen()], busy: true, at: 30))
        XCTAssertEqual(r.decision, .deferredWhileBusy)
        XCTAssertNil(r.state.lastRestart)
        state = r.state
        r = AdbBlockedDetector.evaluate(state: state, input: input(inApp: [seen()], busy: true, at: 34))
        XCTAssertEqual(r.decision, .deferredWhileBusy, "still deferred while it runs")
        state = r.state
        r = AdbBlockedDetector.evaluate(state: state, input: input(inApp: [seen()], busy: false, at: 38))
        XCTAssertEqual(r.decision, .restart, "restarts at the first check after it finished")
    }

    func testRestartsAreRateLimitedToOnePerTwoMinutes() {
        let state = AdbBlockedState(consecutiveBlockedChecks: 1, lastRestart: t0.addingTimeInterval(100))
        var r = AdbBlockedDetector.evaluate(state: state, input: input(inApp: [seen()], at: 150))
        XCTAssertEqual(r.decision, .rateLimited)
        r = AdbBlockedDetector.evaluate(state: r.state, input: input(inApp: [seen()], at: 219))
        XCTAssertEqual(r.decision, .rateLimited)
        r = AdbBlockedDetector.evaluate(state: r.state, input: input(inApp: [seen()], at: 221))
        XCTAssertEqual(r.decision, .restart)
    }

    func testTheTrackerKeepsFirstSeenAndForgetsGoneServices() {
        var tracker = ObservedServiceTracker()
        let a = BonjourServiceName(name: "a", type: "_adb-tls-connect._tcp.local.")
        var out = tracker.update(names: [a], now: t0)
        XCTAssertEqual(out.first?.firstSeen, t0)
        XCTAssertEqual(out.first?.type, connect)
        out = tracker.update(names: [a], now: t0.addingTimeInterval(9))
        XCTAssertEqual(out.first?.firstSeen, t0)
        _ = tracker.update(names: [], now: t0.addingTimeInterval(10))
        out = tracker.update(names: [a], now: t0.addingTimeInterval(20))
        XCTAssertEqual(out.first?.firstSeen, t0.addingTimeInterval(20), "a service that went away starts over")
    }

    func testNoRouteAndMdnsCheckParsing() {
        XCTAssertTrue(AdbBlockedDetector.isNoRouteToHost("failed to connect to '192.0.2.10:5555': No route to host"))
        XCTAssertFalse(AdbBlockedDetector.isNoRouteToHost("failed to connect: Connection refused"))
        XCTAssertTrue(AdbBlockedDetector.mdnsCheckReportsRunning("mdns daemon version [Openscreen discovery 0.0.0]\n"))
        XCTAssertFalse(AdbBlockedDetector.mdnsCheckReportsRunning("ERROR: mdns discovery unavailable\n"))
    }

    func testPolicyDeniedIsRecognised() {
        XCTAssertEqual(LocalNetworkPolicy.access(forDNSServiceError: -65570), .denied)
        XCTAssertEqual(LocalNetworkPolicy.access(forDNSServiceError: -65563), .unknown)
        XCTAssertEqual(
            LocalNetworkPolicy.settingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
    }

    /// packaging/Info.plist lists the Bonjour services the app browses, which
    /// macOS needs before it asks for Local Network access.
    func testInfoPlistDeclaresTheAdbBonjourServices() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("packaging/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertNotNil(plist["NSLocalNetworkUsageDescription"] as? String)
        let services = try XCTUnwrap(plist["NSBonjourServices"] as? [String])
        XCTAssertEqual(Set(services), ["_adb-tls-connect._tcp", "_adb-tls-pairing._tcp", "_adb._tcp"])
        for type in NWAdbServiceBrowser.serviceTypes {
            XCTAssertTrue(services.contains(type), "the browse needs \(type) declared")
        }
    }
}
