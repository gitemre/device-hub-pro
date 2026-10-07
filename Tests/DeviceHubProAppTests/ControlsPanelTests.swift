import XCTest
@testable import DeviceHubProApp

/// The Controls panel's lifecycle: what it shows with and without a mirrored
/// device, and the poll that keeps it live.
@MainActor
final class ControlsPanelTests: XCTestCase {
    // MARK: - Content

    func testWithoutAMirroredDeviceThePanelShowsTheEmptyState() {
        // controlsLoaded is reset when a mirror stops and only set by a
        // refresh, which returns at once without a device: keying the
        // spinner on it alone spun forever.
        XCTAssertEqual(controlsPanelContent(activeSerial: nil, controlsLoaded: false), .noDevice)
        XCTAssertEqual(controlsPanelContent(activeSerial: nil, controlsLoaded: true), .noDevice)
    }

    func testAMirroredDeviceLoadsThenIsReady() {
        XCTAssertEqual(controlsPanelContent(activeSerial: "emulator-5554", controlsLoaded: false), .loading)
        XCTAssertEqual(controlsPanelContent(activeSerial: "emulator-5554", controlsLoaded: true), .ready)
    }

    // MARK: - Groups

    /// Clean status bar is a plain row after the groups (no disclosure group),
    /// and shows on a phone too (no emulator gate).
    func testCleanStatusBarIsAPlainRowAfterTheGroups() {
        var available = ControlsGroupAvailability()
        available.deviceLanguage = true
        available.statusBar = true
        available.showTaps = true
        available.appearance = true
        XCTAssertEqual(
            controlsGroups(available).map(\.id),
            [.network, .power, .languageAndTime, .displayAndSound, .debugAndInput]
        )
        XCTAssertEqual(controlsTrailingRows(available), [.cleanStatusBar])
        available.statusBar = false
        XCTAssertEqual(controlsTrailingRows(available), [])
        XCTAssertEqual(ControlsRow.allCases.filter { "\($0)".lowercased().contains("statusbar") }, [.cleanStatusBar])
    }

    // MARK: - Poll

    func testCancellingDuringTheWaitRunsNoFurtherRefresh() async throws {
        var refreshes = 0
        let poll = Task { @MainActor in
            await ControlsPoll.run(every: .milliseconds(40)) { refreshes += 1 }
        }
        try await wait { refreshes >= 1 }

        poll.cancel()
        let atCancel = refreshes
        await poll.value
        try await Task.sleep(for: .milliseconds(150))

        // `try? await Task.sleep` swallowed the cancellation and ran one more
        // refresh inside the cancelled task (every adb read killed at launch,
        // the panel blanked).
        XCTAssertEqual(refreshes, atCancel, "no refresh may run after the poll is cancelled")
    }

    func testAPollCancelledBeforeItsFirstBeatNeverRefreshes() async {
        var refreshes = 0
        let poll = Task { @MainActor in
            await ControlsPoll.run(every: .seconds(30)) { refreshes += 1 }
        }
        poll.cancel()
        await poll.value
        XCTAssertEqual(refreshes, 0)
    }

    private func wait(timeout: TimeInterval = 5, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition not met within \(timeout) s")
    }
}
