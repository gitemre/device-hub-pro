import XCTest
@testable import DeviceHubProKit

/// `AndroidPhoneRotation` against a fake adb. The `settings get` outputs are the
/// a Xiaomi phone's (`Fixtures/physical-xiaomi`, see its README).
final class AndroidPhoneRotationTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/physical-xiaomi", isDirectory: true)

    private static func file(_ name: String) -> URL { fixtures.appendingPathComponent(name) }

    private func fake() throws -> FakeAdb {
        try FakeAdb([
            .init("settings get system accelerometer_rotation", stdoutFile: Self.file("settings-get-accelerometer_rotation.txt")),
            .init("settings get system user_rotation", stdoutFile: Self.file("settings-get-user_rotation.txt")),
        ])
    }

    func testReadsBothSettings() async throws {
        let adb = try fake()
        let saved = await AndroidPhoneRotation.read(adb: adb.client, serial: "S1")
        XCTAssertEqual(saved, .init(accelerometer: "1", user: "0"))
        XCTAssertEqual(adb.calls, [
            "-s S1 shell settings get system accelerometer_rotation",
            "-s S1 shell settings get system user_rotation",
        ])
    }

    func testAnUnsetSettingReadsAsNil() async throws {
        let adb = try FakeAdb([.init("settings get", stdoutFile: Self.file("settings-get-unset.txt"))])
        let saved = await AndroidPhoneRotation.read(adb: adb.client, serial: "S1")
        XCTAssertEqual(saved, .init(accelerometer: nil, user: nil))
    }

    func testAPhoneThatDoesNotAnswerIsNotChanged() async throws {
        let adb = try FakeAdb([.init("settings get", stderr: "error: device offline", exitCode: 1)])
        let saved = await AndroidPhoneRotation.read(adb: adb.client, serial: "S1")
        XCTAssertNil(saved)
    }

    func testLockPinsThePoseInOneNativeCall() async throws {
        let adb = try fake()
        try await AndroidPhoneRotation.lock(adb: adb.client, serial: "S1", turns: 3)
        try await AndroidPhoneRotation.lock(adb: adb.client, serial: "S1", turns: -1)
        XCTAssertEqual(adb.calls, [
            "-s S1 shell cmd window user-rotation lock 3",
            "-s S1 shell cmd window user-rotation lock 3",
        ])
    }

    /// A phone without `cmd window user-rotation` gets the two settings.
    func testLockFallsBackToTheSettingsWithoutTheCommand() async throws {
        let adb = try FakeAdb([
            .init("cmd window", output: "Unknown command: user-rotation\n"),
            .init("settings put", output: ""),
        ])
        try await AndroidPhoneRotation.lock(adb: adb.client, serial: "S1", turns: 1)
        XCTAssertEqual(adb.calls, [
            "-s S1 shell cmd window user-rotation lock 1",
            "-s S1 shell settings put system accelerometer_rotation 0",
            "-s S1 shell settings put system user_rotation 1",
        ])
    }

    func testLockThrowsWhenTheWriteIsRefused() async throws {
        let adb = try FakeAdb([
            .init("cmd window", stderr: "Permission denied", exitCode: 1),
            .init("settings put", stderr: "Permission denied", exitCode: 1),
        ])
        do {
            try await AndroidPhoneRotation.lock(adb: adb.client, serial: "S1", turns: 1)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(adb.calls.count, 2, "the command, then the first refused setting")
        }
    }

    /// The phone had auto-rotate on and user rotation 0: both come back, the
    /// user rotation first.
    func testRestoreWithAutoRotateOnPutsBothValuesBack() async throws {
        let adb = try fake()
        let read = await AndroidPhoneRotation.read(adb: adb.client, serial: "S1")
        let saved = try XCTUnwrap(read)
        try await AndroidPhoneRotation.lock(adb: adb.client, serial: "S1", turns: 2)
        let ok = await AndroidPhoneRotation.restore(adb: adb.client, serial: "S1", saved: saved)
        XCTAssertTrue(ok)
        XCTAssertEqual(Array(adb.calls.suffix(2)), [
            "-s S1 shell settings put system user_rotation 0",
            "-s S1 shell settings put system accelerometer_rotation 1",
        ])
    }

    func testRestoreWithAutoRotateOffKeepsItOff() async throws {
        let adb = try fake()
        let ok = await AndroidPhoneRotation.restore(
            adb: adb.client, serial: "S1", saved: .init(accelerometer: "0", user: "1"))
        XCTAssertTrue(ok)
        XCTAssertEqual(adb.calls, [
            "-s S1 shell settings put system user_rotation 1",
            "-s S1 shell settings put system accelerometer_rotation 0",
        ])
    }

    func testRestoreDeletesASettingThePhoneDidNotHave() async throws {
        let adb = try fake()
        let ok = await AndroidPhoneRotation.restore(
            adb: adb.client, serial: "S1", saved: .init(accelerometer: "1", user: nil))
        XCTAssertTrue(ok)
        XCTAssertEqual(adb.calls, [
            "-s S1 shell settings delete system user_rotation",
            "-s S1 shell settings put system accelerometer_rotation 1",
        ])
    }

    func testARefusedRestoreReportsFailureAfterTryingBoth() async throws {
        let adb = try FakeAdb([.init("settings put", stderr: "device offline", exitCode: 1)])
        let ok = await AndroidPhoneRotation.restore(
            adb: adb.client, serial: "S1", saved: .init(accelerometer: "1", user: "0"))
        XCTAssertFalse(ok)
        XCTAssertEqual(adb.calls.count, 2)
    }
}
