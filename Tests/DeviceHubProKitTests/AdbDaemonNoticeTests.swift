import XCTest
@testable import DeviceHubProKit

/// `Fixtures/adb-daemon/devices-daemon-start.stderr` is a real capture (adb
/// 37.0.1, macOS, 2026-10-02) of the stderr of `adb -P <free port> devices`
/// when no server ran on that port: the notices go to stderr, the device list
/// to stdout, exit 0. Byte-exact.
final class AdbDaemonNoticeTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures/adb-daemon", isDirectory: true)

    func testDaemonStartNoticesAreDropped() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("devices-daemon-start.stderr"))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("* daemon not running; starting now at tcp:"))
        XCTAssertTrue(ProcessResult.droppingAdbDaemonNotices(from: data).isEmpty)
    }

    func testOtherStderrLinesStay() throws {
        var data = try Data(contentsOf: Self.fixtures.appendingPathComponent("devices-daemon-start.stderr"))
        data.append(Data("adb: device offline\n".utf8))
        let kept = String(decoding: ProcessResult.droppingAdbDaemonNotices(from: data), as: UTF8.self)
        XCTAssertEqual(kept.trimmingCharacters(in: .whitespacesAndNewlines), "adb: device offline")
    }

    func testAdbRunnerStderrHasNoNotices() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let adb = dir.appendingPathComponent("adb")
        let fixture = Self.fixtures.appendingPathComponent("devices-daemon-start.stderr").path
        try "#!/bin/sh\ncat '\(fixture)' >&2\necho 'List of devices attached'\n"
            .write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)

        let result = try await ProcessRunner.run(executable: adb, arguments: ["devices"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardErrorText, "")
        XCTAssertEqual(result.standardOutputText, "List of devices attached\n")
    }
}
