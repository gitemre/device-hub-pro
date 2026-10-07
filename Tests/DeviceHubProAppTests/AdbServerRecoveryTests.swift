import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// `AdbServerRecovery` over fake probes: it never starts an adb server.
@MainActor
final class AdbServerRecoveryTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var date = Date(timeIntervalSince1970: 2_000_000)
        func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
    }

    private final class Counter: @unchecked Sendable {
        var restarts = 0
        var mdnsChecks = 0
        var services: [WirelessPairing.MdnsService] = []
        var running = true
    }

    private struct EmptyBrowser: AdbServiceBrowsing {
        func events() -> AsyncStream<AdbBrowseEvent> { AsyncStream { _ in } }
    }

    private func makeRecovery(
        counter: Counter, clock: Clock, status: StatusCenter = StatusCenter()
    ) -> AdbServerRecovery {
        let probes = AdbServerRecovery.Probes(
            mdnsRunning: { counter.mdnsChecks += 1; return counter.running },
            services: { counter.services },
            restart: { counter.restarts += 1 },
            canReach: { _, _ in true }
        )
        return AdbServerRecovery(probes: probes, browser: EmptyBrowser(), status: status, now: { clock.date })
    }

    private let phone = BonjourServiceName(name: "adb-AAA-bbb", type: "_adb-tls-connect._tcp.local.")

    func testABlockedServerIsRestartedOnceAfterTwoChecksAndTheUserIsTold() async {
        let counter = Counter(), clock = Clock(), status = StatusCenter()
        let recovery = makeRecovery(counter: counter, clock: clock, status: status)
        var refreshes = 0
        recovery.refresh = { refreshes += 1 }
        recovery.apply(.services([phone]))
        clock.advance(10)
        await recovery.check()
        XCTAssertEqual(counter.restarts, 0)
        clock.advance(4)
        await recovery.check()
        XCTAssertEqual(counter.restarts, 1)
        XCTAssertEqual(refreshes, 1, "the device list is refreshed after the restart")
        XCTAssertEqual(status.statusMessage, LocalNetworkPolicy.restartedBanner)
        XCTAssertEqual(status.statusKind, .outcome, "a banner, not a blocking alert")
        XCTAssertNil(status.errorMessage)
    }

    func testNothingRunsAdbWhileTheAppSeesNothingOldEnough() async {
        let counter = Counter(), clock = Clock()
        let recovery = makeRecovery(counter: counter, clock: clock)
        recovery.apply(.services([phone]))
        clock.advance(3)
        await recovery.check()
        XCTAssertEqual(counter.mdnsChecks, 0, "lightweight: no adb call for a young service")
    }

    func testARunningRecordingOrInstallDefersTheRestartUntilItEnds() async {
        let counter = Counter(), clock = Clock()
        let recovery = makeRecovery(counter: counter, clock: clock)
        var busy = true
        recovery.isBusy = { busy }
        recovery.apply(.services([phone]))
        for _ in 0..<4 {
            clock.advance(10)
            await recovery.check()
        }
        XCTAssertEqual(counter.restarts, 0, "never while busy")
        busy = false
        clock.advance(4)
        await recovery.check()
        XCTAssertEqual(counter.restarts, 1)
    }

    func testRestartsAreAtMostOncePerTwoMinutes() async {
        let counter = Counter(), clock = Clock()
        let recovery = makeRecovery(counter: counter, clock: clock)
        recovery.apply(.services([phone]))
        clock.advance(10)
        await recovery.check()
        clock.advance(4)
        await recovery.check()
        XCTAssertEqual(counter.restarts, 1)
        // adb stays blind (the permission is the problem): still one restart.
        for _ in 0..<10 {
            clock.advance(4)
            await recovery.check()
        }
        XCTAssertEqual(counter.restarts, 1)
        clock.advance(120)
        await recovery.check()
        await recovery.check()
        XCTAssertEqual(counter.restarts, 2)
    }

    func testAServiceAdbListsNeverRestarts() async {
        let counter = Counter(), clock = Clock()
        counter.services = [.init(instance: phone.name, type: "_adb-tls-connect._tcp", host: "192.0.2.10", port: 1)]
        let recovery = makeRecovery(counter: counter, clock: clock)
        recovery.apply(.services([phone]))
        for _ in 0..<5 {
            clock.advance(10)
            await recovery.check()
        }
        XCTAssertEqual(counter.restarts, 0)
    }

    func testADeniedPermissionNeverRestartsAndRaisesTheHint() async {
        let counter = Counter(), clock = Clock()
        let recovery = makeRecovery(counter: counter, clock: clock)
        recovery.apply(.access(.denied))
        recovery.apply(.services([phone]))
        for _ in 0..<5 {
            clock.advance(10)
            await recovery.check()
        }
        XCTAssertTrue(recovery.isLocalNetworkDenied)
        XCTAssertEqual(counter.restarts, 0, "a restart cannot help without the permission")
        recovery.apply(.access(.allowed))
        XCTAssertFalse(recovery.isLocalNetworkDenied)
    }

    func testNoRouteToAReachableAddressCountsAsTheSecondSignal() async {
        let counter = Counter(), clock = Clock()
        let recovery = makeRecovery(counter: counter, clock: clock)
        recovery.noteConnectFailure(address: "192.0.2.10:40000", message: "failed to connect to '192.0.2.10:40000': No route to host")
        await waitUntil("the first confirming check never ran") { counter.mdnsChecks >= 1 }
        clock.advance(4)
        await recovery.check()
        XCTAssertEqual(counter.restarts, 1)
    }

    func testNoRouteMessagesOfOtherFailuresAreIgnored() async {
        let counter = Counter(), clock = Clock()
        let recovery = makeRecovery(counter: counter, clock: clock)
        recovery.noteConnectFailure(address: "192.0.2.10:40000", message: "Connection refused")
        try? await Task.sleep(for: .milliseconds(100))
        await recovery.check()
        XCTAssertEqual(counter.mdnsChecks, 0)
    }

    func testWithoutAdbOrABrowserNothingStarts() {
        let recovery = AdbServerRecovery(probes: nil, browser: nil, status: StatusCenter())
        recovery.start()
        recovery.setActive(true)
        recovery.stop()
        XCTAssertEqual(recovery.restartCount, 0)
    }
}
