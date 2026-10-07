import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// The pairing sheet's cancel contract: cancelling clears the busy state
/// immediately, and a result that arrives after the cancel is ignored
/// (no paired flash, no device refresh, no re-drawn error).
@MainActor
final class PairingCancellationTests: XCTestCase {
    func testCancelClearsTheBusyStateImmediately() async throws {
        let stub = try makeStubAdb()
        let model = AppModel.testing(adb: stub.client)

        let task = Task {
            await model.pairing.pairWirelessDevice(
                address: "192.168.1.42:37000",
                code: "123456",
                connectPort: "5555"
            )
        }
        try await wait { model.pairing.isPairingDevice }

        model.pairing.cancelPairing()

        XCTAssertFalse(
            model.pairing.isPairingDevice,
            "cancel must clear the busy state before the adb processes finish"
        )
        task.cancel()
        _ = await task.value
    }

    func testLatePairingResultAfterCancelIsIgnored() async throws {
        let stub = try makeStubAdb()
        let model = AppModel.testing(adb: stub.client)

        let task = Task {
            await model.pairing.pairWirelessDevice(
                address: "192.168.1.42:37000",
                code: "123456",
                connectPort: "5555"
            )
        }
        // The slow leg is connect; cancel while it is in flight so the late
        // success lands after the sheet (and the attempt) is gone.
        try await wait { self.calls(stub.callsURL).contains("connect 192.168.1.42:5555") }

        model.pairing.cancelPairing()
        let result = await task.value

        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(model.pairing.isPairingDevice)
        XCTAssertNil(model.status.statusMessage, "a cancelled attempt must not flash \"Paired …\"")
        XCTAssertNil(model.status.errorMessage)
        XCTAssertTrue(model.inventory.devices.isEmpty)
        let log = calls(stub.callsURL)
        // The connect step itself checks `devices -l` first (no second connect
        // to an attached phone); only a refresh after it would be a leak.
        let afterConnect = log.drop { !$0.hasPrefix("connect") }
        XCTAssertFalse(
            afterConnect.contains { $0.hasPrefix("devices") },
            "a cancelled attempt must not refresh the device list: \(log)"
        )
    }

    // MARK: - Fake adb

    private struct StubAdb {
        let client: AdbClient
        let callsURL: URL
    }

    /// A fake `adb` logging its argv: `pair` succeeds immediately, `connect`
    /// takes a second so the test can cancel while it runs.
    private func makeStubAdb() throws -> StubAdb {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PairingCancellationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let logURL = directory.appendingPathComponent("calls.log")
        let adbURL = directory.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(logURL.path)"
        case "$1" in
          pair)
            printf 'Successfully paired to 192.168.1.42:37000 [guid=adb-test]\\n'
            ;;
          connect)
            sleep 1
            printf 'connected to 192.168.1.42:5555\\n'
            ;;
          *)
            printf 'unexpected: %s\\n' "$*" >&2
            exit 1
            ;;
        esac
        exit 0
        """
        try Data(script.utf8).write(to: adbURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: adbURL.path
        )
        return StubAdb(client: AdbClient(adbURL: adbURL), callsURL: logURL)
    }

    private func calls(_ logURL: URL) -> [String] {
        ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .map(String.init)
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
