import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// macOS asks "Allow Device Hub Pro to find devices on local networks?" the first
/// time the app browses Bonjour (or the adb server it started joins the mDNS
/// group). Neither may happen at launch: the browse starts when a wireless
/// need arrives, and the need is remembered.
@MainActor
final class LocalNetworkDeferralTests: XCTestCase {
    private final class CountingBrowser: AdbServiceBrowsing, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var started: Int { lock.withLock { count } }
        func events() -> AsyncStream<AdbBrowseEvent> {
            lock.withLock { count += 1 }
            return AsyncStream { _ in }
        }
    }

    private func recovery(
        browser: CountingBrowser, wanted: Bool = false
    ) -> AdbServerRecovery {
        let probes = AdbServerRecovery.Probes(
            mdnsRunning: { true }, services: { [] }, restart: {}, canReach: { _, _ in true }
        )
        return AdbServerRecovery(probes: probes, browser: browser, status: StatusCenter(), localNetworkWanted: wanted)
    }

    func testTheAppBecomingActiveAtLaunchDoesNotStartTheBonjourBrowse() async {
        let browser = CountingBrowser()
        let recovery = recovery(browser: browser)
        recovery.setActive(true)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(browser.started, 0, "no browse, so no permission prompt")
        recovery.setActive(false)
        recovery.setActive(true)
        XCTAssertEqual(browser.started, 0, "activating again changes nothing")
    }

    func testTheFirstWirelessNeedStartsTheBrowseOnceEvenWhenTheAppWasAlreadyActive() async {
        let browser = CountingBrowser()
        let recovery = recovery(browser: browser)
        recovery.setActive(true)
        recovery.wantLocalNetwork()
        recovery.wantLocalNetwork()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(browser.started, 1)
        XCTAssertTrue(recovery.isLocalNetworkWanted)
        recovery.stop()
    }

    func testAMacThatNeededItBeforeStartsTheBrowseAtLaunchAsItAlwaysDid() async {
        let browser = CountingBrowser()
        let recovery = recovery(browser: browser, wanted: true)
        recovery.setActive(true)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(browser.started, 1)
        recovery.stop()
    }

    func testAModelBuiltForALaunchNeverBrowsesUntilTheLocalNetworkIsWanted() async throws {
        let stub = try makeStubAdb(arms: "devices*) printf 'List of devices attached\\n\\n' ;;\n  *mdns*) echo 'mdns daemon version [adb discovery 0.0.0]' ;;")
        let browser = CountingBrowser()
        let defaults = UserDefaults.scratch()
        let model = AppModel(environment: AppEnvironment(
            adbClient: stub.client,
            emulatorManager: EmulatorManager.inert,
            emulatorProcesses: .ownProcesses,
            defaults: defaults,
            launch: .none,
            pasteboard: TestPasteboard(),
            picker: TestPicker(),
            adbServiceBrowser: browser
        ))
        await model.refresh()
        model.adbRecovery.setActive(true)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(browser.started, 0, "launch, refresh and activation never browse")
        XCTAssertFalse(model.preferences.localNetworkInUse)

        model.wantLocalNetwork()
        await model.waitForLocalNetwork()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(browser.started, 1)
        XCTAssertTrue(model.preferences.localNetworkInUse, "remembered for the next launch")
        XCTAssertTrue(AppPreferences(defaults: defaults).localNetworkInUse)
        model.adbRecovery.stop()
        model.inventory.stopDeviceLifecycle()
    }

    func testAWirelessDeviceThatIsAlreadyConnectedCountsAsTheNeed() async throws {
        let stub = try makeStubAdb(arms: """
        devices*) printf 'List of devices attached\\n192.168.1.20:5555\\tdevice product:p model:Phone device:d transport_id:1\\n\\n' ;;
        """)
        let browser = CountingBrowser()
        let model = AppModel(environment: AppEnvironment(
            adbClient: stub.client,
            emulatorManager: EmulatorManager.inert,
            emulatorProcesses: .ownProcesses,
            defaults: .scratch(),
            launch: .none,
            pasteboard: TestPasteboard(),
            picker: TestPicker(),
            adbServiceBrowser: browser
        ))
        model.adbRecovery.setActive(true)
        await model.refresh()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(browser.started, 1)
        XCTAssertTrue(model.preferences.localNetworkInUse)
        model.adbRecovery.stop()
        model.inventory.stopDeviceLifecycle()
    }
}
