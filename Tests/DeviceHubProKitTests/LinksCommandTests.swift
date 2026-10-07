import XCTest
@testable import DeviceHubProKit

/// The Links adb calls against a fake adb (not a device): one round trip
/// each, the exact argv, and package validation before anything runs.
final class LinksCommandTests: XCTestCase {
    private let serial = "emulator-5554"

    func testOpenLinkIsOneShellCall() async throws {
        let adb = try FakeAdb([
            .init("am start -W", stdoutFile: LinksAPI37Fixture.url("open-maps-cold.txt")),
        ])
        let request = try LinkRequest("geo:41.0082,28.9784?q=Istanbul", apiLevel: 37)
        let result = try await adb.client.openLink(serial: serial, request)
        XCTAssertEqual(result.launchState, .cold)
        XCTAssertEqual(adb.tool.invocations, [["-s", serial, "shell", LinkCommands.openScript(request)]])
    }

    /// A non-ASCII link reaches adb as the ASCII octal word, whatever
    /// Foundation.Process does to non-ASCII argv.
    func testANonASCIILinkReachesAdbAsASCII() async throws {
        let adb = try FakeAdb([.init("am start -W", stdoutFile: LinksAPI37Fixture.url("open-maps-cold.txt"))])
        let request = try LinkRequest("myapp://ü/ş", apiLevel: 37)
        _ = try await adb.client.openLink(serial: serial, request)
        let script = try XCTUnwrap(adb.tool.invocations.first?.last)
        XCTAssertTrue(script.contains(#"-d $'myapp://\303\274/\305\237'"#), script)
        XCTAssertTrue(script.utf8.allSatisfy { $0 < 0x80 })
    }

    /// adb's own failure (the device went away) throws; nothing is parsed.
    func testAnAdbFailureThrows() async throws {
        let adb = try FakeAdb([.init("am start -W", stderr: "error: device 'emulator-5554' not found", exitCode: 1)])
        let request = try LinkRequest("https://example.com/", apiLevel: 37)
        do {
            _ = try await adb.client.openLink(serial: serial, request)
            XCTFail("expected an AdbError")
        } catch AdbError.commandFailed(_, let exitCode, let message) {
            XCTAssertEqual(exitCode, 1)
            XCTAssertTrue(message.contains("not found"))
        }
    }

    func testPreviewIsOneShellCall() async throws {
        let adb = try FakeAdb([
            .init("@@devicehubpro:link:api", stdoutFile: LinksAPI37Fixture.url("preview-video-verified.txt")),
        ])
        let request = try LinkRequest("https://video.example.com/watch?v=dQw4w9WgXcQ", apiLevel: 37)
        let preview = try await adb.client.linkPreview(serial: serial, request)
        XCTAssertEqual(preview.resolvedPackage, "com.example.video")
        XCTAssertEqual(adb.tool.invocations, [["-s", serial, "shell", LinkCommands.previewScript(request)]])
    }
}
