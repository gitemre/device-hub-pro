import XCTest
@testable import DeviceHubProKit

/// An install that prints nothing for the idle timeout is given up on, with
/// the sentence the user reads; one that keeps printing is not.
final class SdkInstallWatchdogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SdkInstallWatchdogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func script(_ name: String, _ body: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func client(sdkmanager: URL, idle: Duration) throws -> SdkmanagerClient {
        let java = try script("java", "#!/bin/sh\necho 'openjdk version \"21\"' >&2\n")
        return SdkmanagerClient(
            sdkmanagerURL: sdkmanager,
            javaURL: java,
            environment: ["JAVA_HOME": "/nonexistent-but-set"],
            installIdleTimeout: idle
        )
    }

    func testASilentInstallFailsWithTheNoProgressMessage() async throws {
        let tool = try script("quiet", "#!/bin/sh\necho 'Downloading...'\nexec sleep 30\n")
        let started = Date()
        do {
            try await client(sdkmanager: tool, idle: .milliseconds(600)).install(
                package: "emulator", onProgress: { _ in }, onLicense: { _ in true }
            )
            XCTFail("expected the watchdog")
        } catch SdkmanagerError.commandFailed(let message) {
            XCTAssertEqual(message, SdkmanagerClient.stalledMessage)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    }

    func testAnInstallThatKeepsPrintingIsNotStopped() async throws {
        let tool = try script(
            "chatty",
            "#!/bin/sh\nfor i in 1 2 3 4 5 6; do printf '[===] %d%% Downloading\\r' $((i*15)); sleep 0.3; done\nexit 0\n"
        )
        try await client(sdkmanager: tool, idle: .milliseconds(1000)).install(
            package: "emulator", onProgress: { _ in }, onLicense: { _ in true }
        )
    }

    func testAUserCancelIsStillACancelNotAStall() async throws {
        let tool = try script("quiet2", "#!/bin/sh\necho hi\nexec sleep 30\n")
        let client = try client(sdkmanager: tool, idle: .seconds(60))
        let task = Task {
            try await client.install(package: "emulator", onProgress: { _ in }, onLicense: { _ in true })
        }
        try await Task.sleep(for: .milliseconds(500))
        client.cancel()
        do {
            try await task.value
            XCTFail("expected a cancel")
        } catch SdkmanagerError.cancelled {
        }
    }
}
