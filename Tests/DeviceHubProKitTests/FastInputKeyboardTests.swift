import Foundation
import Synchronization
import XCTest
@testable import DeviceHubProKit

/// Typing and keys through the helper: the lines
/// written for text, keys and the App Switcher, what is refused before it is
/// sent and how the helper's own refusal leaves the session up. The helper is
/// a fake that speaks the protocol; nothing here reaches a device.
final class FastInputKeyboardTests: XCTestCase {
    private func started(respond: (@Sendable (String) -> [String])? = { _ in ["ok"] }) async throws -> (FastInputSession, FakeFastChild) {
        let child = FakeFastChild(startup: ["ready 0x101"], respond: respond)
        let launcher = FakeFastLauncher(children: [child])
        let session = FastInputSession(
            coreDeviceIdentifier: "00000000-1111-2222-3333-444444444444",
            helperURL: URL(fileURLWithPath: "/tmp/fake-helper"),
            launcher: launcher, lease: FakeLease(), environment: [:]
        )
        try await session.start()
        return (session, child)
    }

    func testKeyboardCommandsEncodeToTheHelpersLines() {
        XCTAssertEqual(FastInputCommand.appSwitcher.line, "button appSwitcher")
        XCTAssertEqual(FastInputCommand.key(usage: 0x2a, action: .tap).line, "key 42 tap")
        XCTAssertEqual(FastInputCommand.key(usage: 0xe1, action: .down).line, "key 225 down")
        XCTAssertEqual(FastInputCommand.key(usage: 0, action: .up).line, "key 1 up", "clamped into 1...0xE7")
        XCTAssertEqual(FastInputCommand.key(usage: 999, action: .up).line, "key 231 up")
        XCTAssertEqual(FastInputCommand.text("Hi there!").line, "text Hi there!")
        XCTAssertEqual(FastInputCommand.text(" a  ").line, "text  a  ", "spaces are text")
        XCTAssertGreaterThan(FastInputCommand.text(String(repeating: "a", count: 100)).answerTimeout, .seconds(6))
    }

    func testKeysEncodeToOneLineWithTheHeldSet() {
        XCTAssertEqual(FastInputCommand.keys([0xE1, 0x0C]).line, "keys 225 12")
        XCTAssertEqual(FastInputCommand.keys([]).line, "keys", "no usage: all up")
        XCTAssertEqual(FastInputCommand.keys([0, 999]).line, "keys 1 231", "clamped into 1...0xE7")
    }

    func testKeysSendTheHeldSetAndKeepTheOtherVerbs() async throws {
        let (session, child) = try await started()
        try await session.keys([0xE1, 0x34])
        try await session.keys([])
        try await session.key(usage: 0x28)
        try await session.appSwitcher()
        XCTAssertEqual(child.written, ["keys 225 52", "keys", "key 40 tap", "button appSwitcher"])
        await session.stop()
    }

    func testAKeyErrorEndsTheSessionLikeAnyOther() async throws {
        let (session, _) = try await started { line in line.hasPrefix("key") ? ["err 7 keyboard service unavailable"] : ["ok"] }
        do {
            try await session.key(usage: 0x28)
            XCTFail("should have thrown")
        } catch {
            XCTAssertEqual(error as? FastInputError, .commandFailed(code: 7, message: "keyboard service unavailable"))
        }
        do {
            try await session.appSwitcher()
            XCTFail("should have thrown")
        } catch {}
    }

    func testTheHelperSourcesHaveTheKeyboardVerbsAndTheAppSwitcherUsage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("fastinput/Sources/fastinput_main.m"), encoding: .utf8)
        for word in ["\"key \"", "\"keys\"", "uhid_make_keyboard_set_hid_report", "\"text \"", "err 8 unsupported character", "appSwitcher", "0xff01", "CoreDevice keyboard"] {
            XCTAssertTrue(source.contains(word), word)
        }
    }
}
