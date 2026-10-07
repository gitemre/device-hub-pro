import XCTest
@testable import DeviceHubProKit

final class DeviceWatcherIntegrationTests: XCTestCase {
    /// Against the real adb: the first `track-devices -l` frame must become a
    /// snapshot matching `adb devices -l`. The wait is raced against a
    /// deadline, so a watcher that never emits fails the test instead of
    /// hanging it (`for await` alone only re-checks a deadline after an event).
    func testWatcherEmitsSnapshotsMatchingAdbDevices() async throws {
        guard ProcessInfo.processInfo.environment["DHP_RUN_INTEGRATION"] == "1" else {
            throw XCTSkip("set DHP_RUN_INTEGRATION=1 to run integration tests")
        }
        let adbPath = ProcessInfo.processInfo.environment["DHP_ADB"]
            ?? "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb"
        guard FileManager.default.isExecutableFile(atPath: adbPath) else {
            throw XCTSkip("adb is not installed at \(adbPath)")
        }
        let adbURL = URL(fileURLWithPath: adbPath)
        let watcher = DeviceWatcher(adbURL: adbURL)
        let stream = watcher.events()
        watcher.start()
        defer { watcher.stop() }

        let snapshot = await withTaskGroup(of: [AndroidDevice]?.self) { group in
            group.addTask {
                for await event in stream {
                    if case .snapshot(let devices, let degraded) = event, !degraded {
                        return devices
                    }
                }
                return nil
            }
            group.addTask {
                // Best effort: sleep only fails on cancellation (the snapshot won).
                try? await Task.sleep(for: .seconds(10))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let snapshot else {
            return XCTFail("no track-devices snapshot within 10 s")
        }

        let result = try await ProcessRunner.run(
            executable: adbURL,
            arguments: ["devices", "-l"],
            timeout: .seconds(5)
        )
        let expected = AdbParsing.devices(from: result.standardOutputText)
        XCTAssertEqual(snapshot.map(\.serial).sorted(), expected.map(\.serial).sorted())
        XCTAssertEqual(
            snapshot.map(\.model).sorted { ($0 ?? "") < ($1 ?? "") },
            expected.map(\.model).sorted { ($0 ?? "") < ($1 ?? "") },
            "the -l frames carry the same details as devices -l"
        )
    }
}
