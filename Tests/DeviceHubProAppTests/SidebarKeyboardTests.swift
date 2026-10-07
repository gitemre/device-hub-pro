import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// The sidebar's keyboard: the arrow-key walk and what Return starts.
@MainActor
final class SidebarKeyboardTests: XCTestCase {
    private let order: [DeviceSelection] = [
        .avd("Pixel_9"),
        .device("R58M123"),
        .pixel("pixel_9_pro"),
    ]

    // MARK: - Arrow keys

    func testDownAndUpWalkTheVisibleRows() {
        XCTAssertEqual(SidebarNavigation.neighbor(of: .avd("Pixel_9"), in: order, forward: true), .device("R58M123"))
        XCTAssertEqual(SidebarNavigation.neighbor(of: .device("R58M123"), in: order, forward: true), .pixel("pixel_9_pro"))
        XCTAssertEqual(SidebarNavigation.neighbor(of: .pixel("pixel_9_pro"), in: order, forward: false), .device("R58M123"))
    }

    func testTheEndsStayPut() {
        XCTAssertEqual(SidebarNavigation.neighbor(of: .pixel("pixel_9_pro"), in: order, forward: true), .pixel("pixel_9_pro"))
        XCTAssertEqual(SidebarNavigation.neighbor(of: .avd("Pixel_9"), in: order, forward: false), .avd("Pixel_9"))
    }

    func testWithoutAVisibleSelectionTheWalkStartsAtAnEnd() {
        XCTAssertEqual(SidebarNavigation.neighbor(of: nil, in: order, forward: true), .avd("Pixel_9"))
        XCTAssertEqual(SidebarNavigation.neighbor(of: nil, in: order, forward: false), .pixel("pixel_9_pro"))
        // A selection the search filter hides.
        XCTAssertEqual(SidebarNavigation.neighbor(of: .avd("Hidden"), in: order, forward: true), .avd("Pixel_9"))
    }

    func testAnEmptyListHasNoNeighbor() {
        XCTAssertNil(SidebarNavigation.neighbor(of: nil, in: [], forward: true))
    }

    // MARK: - Return

    private func card(_ name: String, running: Bool = false, serial: String? = nil) -> AvdCard {
        AvdCard(
            name: name,
            displayName: name,
            target: "android-35",
            skin: nil,
            isRunning: running,
            serial: serial
        )
    }

    func testReturnStartsAStoppedAvd() {
        let model = AppModel.testing()
        model.catalog.avdCards = [card("Pixel_9")]
        XCTAssertEqual(model.sidebarStartTarget(for: .avd("Pixel_9")), "Pixel_9")
    }

    func testReturnLeavesRunningAndBootingAvdsAlone() {
        let model = AppModel.testing()
        model.catalog.avdCards = [
            card("Running", running: true, serial: "emulator-5554"),
            card("Booting", running: true, serial: nil),
        ]
        model.inventory.devices = [AndroidDevice(serial: "emulator-5554", state: "device")]
        XCTAssertNil(model.sidebarStartTarget(for: .avd("Running")))
        XCTAssertNil(model.sidebarStartTarget(for: .avd("Booting")))
    }

    func testReturnStartsNothingWhileTheAppIsBusy() async throws {
        // startAndMirror marks the app busy before its first await, but the
        // AVD as starting only after one: a second Return (or one on another
        // stopped AVD) in between must not launch a second boot. Any busy
        // operation holds it off, like the Start buttons; an app launch
        // parked in a stub adb stands in for the boot here.
        let adb = try makeParkingAdb()
        let model = AppModel.testing(adb: adb.client)
        model.catalog.avdCards = [card("Pixel_9"), card("Pixel_8")]
        model.deviceSelection = .device("R58M123")
        let launch = Task { await model.workspace.apps.launchApp(package: "com.example.app") }
        try await wait { model.isBusy }

        XCTAssertNil(model.sidebarStartTarget(for: .avd("Pixel_9")))
        XCTAssertNil(model.sidebarStartTarget(for: .avd("Pixel_8")))

        try Data().write(to: adb.releaseURL)
        await launch.value
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.sidebarStartTarget(for: .avd("Pixel_8")), "Pixel_8")
    }

    func testReturnDoesNothingForDevicesUnknownAvdsOrNoSelection() {
        let model = AppModel.testing()
        model.catalog.avdCards = [card("Pixel_9")]
        XCTAssertNil(model.sidebarStartTarget(for: .device("R58M123")))
        XCTAssertNil(model.sidebarStartTarget(for: .avd("Gone")))
        XCTAssertNil(model.sidebarStartTarget(for: .pixel("pixel_9_pro")), "no AVD uses this skin")
        XCTAssertNil(model.sidebarStartTarget(for: nil))
    }

    // MARK: - Fake adb

    private struct ParkingAdb {
        let client: AdbClient
        /// Created by the test to let the parked command finish.
        let releaseURL: URL
    }

    /// A fake `adb` whose app launch (`monkey`) waits until `releaseURL`
    /// exists (10 s at most); everything else succeeds at once.
    private func makeParkingAdb() throws -> ParkingAdb {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarKeyboardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let releaseURL = directory.appendingPathComponent("release")
        let adbURL = directory.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        case "$*" in
          *monkey*)
            i=0
            while [ ! -f "\(releaseURL.path)" ] && [ $i -lt 200 ]; do
              sleep 0.05
              i=$((i + 1))
            done
            printf 'Events injected: 1\\n'
            ;;
        esac
        exit 0
        """
        try Data(script.utf8).write(to: adbURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adbURL.path)
        return ParkingAdb(client: AdbClient(adbURL: adbURL), releaseURL: releaseURL)
    }

    private func wait(timeout: TimeInterval = 5, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("condition not met within \(timeout) s")
    }
}
