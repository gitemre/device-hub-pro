import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// Device ▸ Shell…'s model over a stub adb: closing the sheet cancels the
/// running command (`DeviceShellContent.onDisappear` calls `cancel()`).
@MainActor
final class DeviceShellModelTests: XCTestCase {
    func testCancelEndsARunningCommandAndItsFlusher() async throws {
        let adb = try makeStubAdb(arms: """
          "-s emulator-5600 shell sleep 30")
            exec sleep 30 ;;
        """)
        let model = DeviceShellModel(adb: adb.client, serial: "emulator-5600")
        model.command = "sleep 30"
        model.run()
        XCTAssertTrue(model.isRunning)
        await waitUntil("the command never started") { !adb.calls(containing: "sleep 30").isEmpty }

        model.cancel()
        await waitUntil("the command kept running after cancel") { !model.isRunning }
        XCTAssertEqual(model.transcript.lines.last?.text, "cancelled")
    }
}
