import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// First run on a fresh Mac: adb's server fails to start ("ADB server didn't
/// ACK", messages SOURCE-DERIVED, see the kit suite `AdbServerStartFailureTests`). That is
/// never a modal alert; a device error still is.
@MainActor
final class AdbServerStartAlertTests: XCTestCase {
    /// A fake adb: `devices` fails `failures` times (always when nil) with the
    /// real didn't-ACK text, or with `deviceError` every time, then lists one
    /// emulator.
    private static func makeFake(failures: Int?, deviceError: String? = nil) throws -> (url: URL, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let count = dir.appendingPathComponent("count")
        let limit = failures.map(String.init) ?? "-1"
        let deviceErrorLine = deviceError.map { "echo '\($0)' >&2; exit 1" } ?? ""
        let script = """
        #!/bin/sh
        case "$1" in
          kill-server|start-server) exit 0 ;;
          track-devices) exec sleep 30 ;;
          devices)
            n=$(cat '\(count.path)' 2>/dev/null || echo 0)
            n=$((n+1)); echo $n > '\(count.path)'
            \(deviceErrorLine)
            if [ '\(limit)' -lt 0 ] || [ $n -le '\(limit)' ]; then
              printf '* daemon not running; starting now at tcp:5037\\nADB server didn'"'"'t ACK\\n* failed to start daemon\\n' >&2
              exit 1
            fi
            printf 'List of devices attached\\nemulator-5554\\tdevice product:sdk model:Pixel device:emu transport_id:1\\n\\n'
            ;;
        esac
        """
        let url = dir.appendingPathComponent("adb")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return (url, dir)
    }

    private func model(_ fake: URL) -> AppModel {
        AppModel(environment: AppEnvironment(
            adbClient: AdbClient(adbURL: fake, serverRestartBackoff: .milliseconds(10)),
            emulatorManager: EmulatorManager.inert,
            emulatorProcesses: .ownProcesses,
            defaults: .scratch(),
            launch: .none,
            pasteboard: TestPasteboard(),
            picker: TestPicker(),
            adbServiceBrowser: nil
        ))
    }

    func testAFirstDidntAckRecoversWithoutAnAlert() async throws {
        let fake = try Self.makeFake(failures: 1)
        defer { try? FileManager.default.removeItem(at: fake.dir) }
        let model = model(fake.url)
        await model.refresh()
        XCTAssertNil(model.status.errorMessage)
        XCTAssertFalse(model.adbServerProblem)
        XCTAssertEqual(model.inventory.devices.map(\.serial), ["emulator-5554"])
        model.inventory.stopDeviceLifecycle()
    }

    func testAPersistentServerFailureIsInlineNotAnAlert() async throws {
        let fake = try Self.makeFake(failures: nil)
        defer { try? FileManager.default.removeItem(at: fake.dir) }
        let model = model(fake.url)
        await model.refresh()
        XCTAssertNil(model.status.errorMessage, "no modal alert")
        XCTAssertTrue(model.adbServerProblem, "the sidebar shows Try Again")
        model.inventory.stopDeviceLifecycle()
    }

    func testADeviceErrorStillAlerts() async throws {
        let fake = try Self.makeFake(failures: 0, deviceError: "error: device offline")
        defer { try? FileManager.default.removeItem(at: fake.dir) }
        let model = model(fake.url)
        await model.refresh()
        XCTAssertFalse(model.adbServerProblem)
        XCTAssertEqual(
            UserFacingText.plain(model.status.errorMessage ?? ""),
            "The device returned an error: error: device offline"
        )
        model.inventory.stopDeviceLifecycle()
    }

    func testAServerFailureNeverReadsAsADeviceError() {
        let text = "adb devices -l failed (1): ADB server didn't ACK\n* failed to start daemon\n"
        XCTAssertFalse(UserFacingText.plain(text).contains("The device"))
    }
}
