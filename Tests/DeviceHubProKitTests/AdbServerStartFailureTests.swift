import XCTest
@testable import DeviceHubProKit

/// adb prints server-start failures on stderr and exits 1; the client must
/// treat them as a server problem: restart the server once and ask again.
///
/// The messages are SOURCE-DERIVED from platform/packages/modules/adb
/// (android.googlesource.com, main, 2026-10-05): `adb.cpp` line 790
/// (`ADB server didn't ACK`), `client/adb_client.cpp` lines 140 (`protocol
/// fault (couldn't read status): ...`), 169/203 (`cannot connect to daemon at
/// tcp:5037: ...`), 263 (`* daemon not running; starting now at ...`), 273
/// (`* failed to start daemon`) and 277.
final class AdbServerStartFailureTests: XCTestCase {
    static let didntAck = "* daemon not running; starting now at tcp:5037\nADB server didn't ACK\n* failed to start daemon\n"

    /// A fake adb: `devices` fails `failures` times (always when nil) with the
    /// didn't-ACK text, or with `deviceError` every time, then lists one
    /// emulator. Every call is appended to `calls`.
    static func makeFake(failures: Int?, deviceError: String? = nil) throws -> (url: URL, calls: URL, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let calls = dir.appendingPathComponent("calls")
        let count = dir.appendingPathComponent("count")
        let errorFile = dir.appendingPathComponent("err")
        try didntAck.write(to: errorFile, atomically: true, encoding: .utf8)
        let limit = failures.map(String.init) ?? "-1"
        let deviceErrorLine = deviceError.map { "echo '\($0)' >&2; exit 1" } ?? ""
        let script = """
        #!/bin/sh
        echo "$*" >> '\(calls.path)'
        case "$1" in
          kill-server|start-server) exit 0 ;;
          track-devices) exec sleep 30 ;;
          devices)
            n=$(cat '\(count.path)' 2>/dev/null || echo 0)
            n=$((n+1)); echo $n > '\(count.path)'
            \(deviceErrorLine)
            if [ '\(limit)' -lt 0 ] || [ $n -le '\(limit)' ]; then cat '\(errorFile.path)' >&2; exit 1; fi
            printf 'List of devices attached\\nemulator-5554\\tdevice product:sdk model:Pixel device:emu transport_id:1\\n\\n'
            ;;
        esac
        """
        let url = dir.appendingPathComponent("adb")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return (url, calls, dir)
    }

    private func callLines(_ fake: (url: URL, calls: URL, dir: URL)) throws -> [String] {
        try String(contentsOf: fake.calls, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func testRealMessagesAreRecognised() {
        for text in [
            Self.didntAck,
            "* daemon not running; starting now at tcp:5037\n* failed to start daemon\n",
            "cannot connect to daemon at tcp:5037: Connection refused\n",
            "error: cannot connect to daemon\n",
            "adb: protocol fault (couldn't read status): Connection reset by peer\n",
        ] {
            XCTAssertTrue(AdbServerStartFailure.matches(text), text)
        }
        XCTAssertFalse(AdbServerStartFailure.matches("adb: device 'emulator-5554' not found\n"))
        XCTAssertFalse(AdbServerStartFailure.matches("error: device offline\n"))
    }

    func testFirstDidntAckIsRestartedAndTheListSucceeds() async throws {
        let fake = try Self.makeFake(failures: 1)
        defer { try? FileManager.default.removeItem(at: fake.dir) }
        let client = AdbClient(adbURL: fake.url, serverRestartBackoff: .milliseconds(10))
        let devices = try await client.listDevices()
        XCTAssertEqual(devices.map(\.serial), ["emulator-5554"])
        XCTAssertEqual(try callLines(fake), ["devices -l", "kill-server", "start-server", "devices -l"])
    }

    func testPersistentFailureThrowsAServerStartFailureAfterOneRestart() async throws {
        let fake = try Self.makeFake(failures: nil)
        defer { try? FileManager.default.removeItem(at: fake.dir) }
        let client = AdbClient(adbURL: fake.url, serverRestartBackoff: .milliseconds(10))
        do {
            _ = try await client.listDevices()
            XCTFail("expected a failure")
        } catch let error as AdbError {
            XCTAssertTrue(error.isServerStartFailure)
        }
        let calls = try callLines(fake)
        XCTAssertEqual(calls.filter { $0 == "kill-server" }.count, 1, "restarts once, never loops")
        XCTAssertEqual(calls.filter { $0 == "devices -l" }.count, 2)
    }

    func testADeviceErrorIsNotRetriedAndIsNotAServerFailure() async throws {
        let fake = try Self.makeFake(failures: 0, deviceError: "error: device offline")
        defer { try? FileManager.default.removeItem(at: fake.dir) }
        let client = AdbClient(adbURL: fake.url, serverRestartBackoff: .milliseconds(10))
        do {
            _ = try await client.listDevices()
            XCTFail("expected a failure")
        } catch let error as AdbError {
            XCTAssertFalse(error.isServerStartFailure)
            XCTAssertTrue("\(error)".contains("device offline"))
        }
        XCTAssertEqual(try callLines(fake), ["devices -l"])
    }
}
