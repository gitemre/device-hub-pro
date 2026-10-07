import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// A refresh that is cancelled while adb is still answering is not an error:
/// the superseded task ends quietly and the status line stays empty.
@MainActor
final class RefreshCancellationTests: XCTestCase {
    func testARefreshCancelledMidFlightNeverSetsAnErrorMessage() async throws {
        let adb = try makeStubAdb(arms: """
          "devices -l")
            exec sleep 30 ;;
        """)
        let model = AppModel.testing(adb: adb.client)
        XCTAssertTrue(model.adbIsAvailable)

        let refresh = Task { await model.refreshAndroid() }
        await waitUntil("the refresh never reached adb") { !adb.calls(containing: "devices -l").isEmpty }
        refresh.cancel()
        await refresh.value

        XCTAssertNil(model.status.errorMessage)
    }
}
