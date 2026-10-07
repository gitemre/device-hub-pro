import Foundation
import XCTest
@testable import DeviceHubProKit

/// Hung SDK tools end with an error instead of leaving the UI waiting, and a
/// cancelled call reports cancellation (never "no Java" or a failed load).
/// Stub tools only: a fake `java`, `avdmanager` and `sdkmanager`.
final class SdkToolTimeoutTests: XCTestCase {
    private var directory: URL!
    private var java: URL!
    private var hang: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SdkToolTimeout-\(UUID().uuidString)", isDirectory: true)
        let bin = directory.appendingPathComponent("jdk/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        java = bin.appendingPathComponent("java")
        try script("#!/bin/sh\necho 'openjdk version \"21\"' >&2\n", at: java)
        hang = directory.appendingPathComponent("tool")
        try script("#!/bin/sh\nexec sleep 60\n", at: hang)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func script(_ body: String, at url: URL) throws {
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func testAHangingJavaProbeGivesUpWithinItsBound() async throws {
        let slowJava = directory.appendingPathComponent("slowjava")
        try script("#!/bin/sh\nexec sleep 60\n", at: slowJava)
        let started = Date()
        let found = await AvdmanagerLocator.workingJava(
            environment: ["PATH": "/nonexistent", "HOME": directory.path],
            preferred: slowJava,
            probeTimeout: .milliseconds(300)
        )
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
        XCTAssertNotEqual(found, slowJava)
    }

    func testAHangingAvdmanagerListEndsWithACommandFailure() async throws {
        let client = AvdmanagerClient(
            avdmanagerURL: hang, javaURL: java,
            listTimeout: .milliseconds(300), createTimeout: .milliseconds(300)
        )
        do {
            _ = try await client.listDevices()
            XCTFail("expected a timeout")
        } catch AvdmanagerError.commandFailed(let message) {
            XCTAssertTrue(message.contains("did not finish"), message)
        }
    }

    func testAHangingAvdmanagerCreateEndsWithACommandFailure() async throws {
        let client = AvdmanagerClient(
            avdmanagerURL: hang, javaURL: java,
            listTimeout: .milliseconds(300), createTimeout: .milliseconds(300)
        )
        let avdHome = directory.appendingPathComponent("avd", isDirectory: true)
        try FileManager.default.createDirectory(at: avdHome, withIntermediateDirectories: true)
        do {
            try await client.createAvd(name: "aqa_hang", deviceId: "d", systemImage: "s", avdHome: avdHome)
            XCTFail("expected a timeout")
        } catch AvdmanagerError.commandFailed(let message) {
            XCTAssertTrue(message.contains("did not finish"), message)
        }
    }

    func testAHangingSdkmanagerListEndsWithACommandFailure() async throws {
        let client = SdkmanagerClient(
            sdkmanagerURL: hang, javaURL: java, listTimeout: .milliseconds(300)
        )
        do {
            _ = try await client.listAvailableImages()
            XCTFail("expected a timeout")
        } catch SdkmanagerError.commandFailed(let message) {
            XCTAssertTrue(message.contains("did not finish"), message)
        }
    }

    func testACancelledSdkmanagerListThrowsCancelledNotAFailure() async throws {
        let client = SdkmanagerClient(sdkmanagerURL: hang, javaURL: java, listTimeout: .seconds(60))
        let task = Task { try await client.listAvailableImages() }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch SdkmanagerError.cancelled {
            // Expected.
        }
    }
}
