import XCTest
@testable import DeviceHubProKit

/// Typing on a guest without the emulator's keyboard: the `adb shell input`
/// commands (`AdbTextInput`, `KeyboardSender.adb`) and the routed sender.
/// No device: the commands go to a recording fake.
///
/// SOURCE-DERIVED: `input text` turns `%s` into a space
/// (`InputShellCommand.sendText`, AOSP `platform/frameworks/base` main), the
/// key codes are `KeyEvent.java`'s (`KEYCODE_ENTER` 66, `KEYCODE_TAB` 61,
/// `KEYCODE_DEL` 67, `KEYCODE_CTRL_LEFT` 113, `KEYCODE_V` 50,
/// `KEYCODE_PASTE` 279), and the API levels whose `input keycombination`
/// holds Ctrl are `InputShellCommand.sendKeyCombination`'s
/// (android12-release, android12L-release, android13-release) and
/// `Input.java`'s (android11-release), as `AdbTextInput` cites them.
final class KeyboardAdbTests: XCTestCase {
    final class Commands: @unchecked Sendable {
        private let lock = NSLock()
        private var _log: [[String]] = []
        var log: [[String]] { lock.withLock { _log } }

        var run: @Sendable ([String]) async throws -> Void {
            { [self] command in
                lock.withLock { _log.append(command) }
            }
        }
    }

    /// The emulator side's clipboard and key sends, recorded.
    final class EmulatorSide: @unchecked Sendable {
        private let lock = NSLock()
        private var _log: [String] = []
        var log: [String] { lock.withLock { _log } }
        private func add(_ entry: String) { lock.withLock { _log.append(entry) } }

        var sender: KeyboardSender {
            KeyboardSender(
                text: { self.add("text \($0)") },
                specialKey: { self.add("key \($0)") },
                pasteShortcut: { self.add("paste") },
                clipboard: {
                    self.add("clipboard")
                    return "user clip"
                },
                setClipboard: { self.add("set \($0)") }
            )
        }
    }

    // MARK: - Typed text

    func testTypedTextIsInputTextWithSpacesAsPercentS() {
        XCTAssertEqual(AdbTextInput.commands(typing: "hello world"), [["input", "text", "hello%sworld"]])
        XCTAssertEqual(AdbTextInput.commands(typing: "a"), [["input", "text", "a"]])
        XCTAssertEqual(AdbTextInput.commands(typing: ""), [])
    }

    /// Shell metacharacters are escaped for the device shell
    /// (`PhysicalInput.escapedText`).
    func testShellCharactersAreEscaped() {
        XCTAssertEqual(AdbTextInput.commands(typing: "it's $5 & (x)"), [["input", "text", #"it\'s%s\$5%s\&%s\(x\)"#]])
    }

    /// Newline and tab are key presses, between the text around them.
    func testNewlineAndTabAreKeyPresses() {
        XCTAssertEqual(AdbTextInput.commands(typing: "a\nb\tc"), [
            ["input", "text", "a"],
            ["input", "keyevent", "66"],
            ["input", "text", "b"],
            ["input", "keyevent", "61"],
            ["input", "text", "c"],
        ])
        XCTAssertEqual(AdbTextInput.commands(typing: "\n"), [["input", "keyevent", "66"]])
    }

    /// A literal `%s` would type a space: the `%` and the `s` go in separate
    /// calls. `%` before anything else stays in one.
    func testALiteralPercentSIsCutInTwo() {
        XCTAssertEqual(AdbTextInput.commands(typing: "50%sale"), [
            ["input", "text", "50%"],
            ["input", "text", "sale"],
        ])
        XCTAssertEqual(AdbTextInput.commands(typing: "100% ok"), [["input", "text", "100%%sok"]])
    }

    /// A long run goes in pieces of `chunkLimit` characters.
    func testALongRunIsSplit() {
        let text = String(repeating: "x", count: 450)
        let commands = AdbTextInput.commands(typing: text)
        XCTAssertEqual(commands.map { $0[2].count }, [200, 200, 50])
        XCTAssertTrue(commands.allSatisfy { $0.prefix(2) == ["input", "text"] })
    }

    // MARK: - The adb sender

    /// Counts the API level reads and answers them in turn (nil for a read
    /// that throws).
    final class SdkLevels: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [Int?]
        private var _reads = 0
        var reads: Int { lock.withLock { _reads } }

        struct Offline: Error {}

        init(_ answers: [Int?]) {
            self.answers = answers
        }

        var read: @Sendable () async throws -> Int? {
            { [self] in
                let answer: Int? = lock.withLock {
                    _reads += 1
                    return answers.count > 1 ? answers.removeFirst() : answers.first ?? nil
                }
                guard let answer else { throw Offline() }
                return answer
            }
        }
    }

    func testTheAdbSenderTypesPressesAndPastesThroughInput() async throws {
        let commands = Commands()
        let emulator = EmulatorSide()
        let sender = KeyboardSender.adb(run: commands.run, readSdkLevel: { 37 }, clipboard: emulator.sender)

        try await sender.text("hi there")
        try await sender.specialKey(51)      // delete → KEYCODE_DEL
        try await sender.specialKey(36)      // return → KEYCODE_ENTER
        try await sender.specialKey(999)     // not forwarded by the mirror: nothing
        try await sender.pasteShortcut()

        XCTAssertEqual(commands.log, [
            ["input", "text", "hi%sthere"],
            ["input", "keyevent", "67"],
            ["input", "keyevent", "66"],
            ["input", "keycombination", "113", "50"],
        ])

        // The clipboard stays on the emulator's service.
        let clip = try await sender.clipboard()
        try await sender.setClipboard("ş")
        XCTAssertEqual(clip, "user clip")
        XCTAssertEqual(emulator.log, ["clipboard", "set ş"])
    }

    /// Ctrl+V only where `keycombination` holds Ctrl for the V (API 33 and
    /// up): API 31 and 32 would type a "v", API 30 and older have no such
    /// command and exit 0 all the same. Below that, and for an unknown
    /// level, the paste key.
    func testThePasteFollowsTheGuestsAPILevel() {
        XCTAssertEqual(AdbTextInput.keyCombinationMinimumAPI, 33)
        for level in [24, 29, 30, 31, 32] {
            XCTAssertEqual(AdbTextInput.pasteCommand(sdkLevel: level), ["input", "keyevent", "279"], "API \(level)")
        }
        for level in [33, 34, 36, 37] {
            XCTAssertEqual(AdbTextInput.pasteCommand(sdkLevel: level), ["input", "keycombination", "113", "50"], "API \(level)")
        }
        XCTAssertEqual(AdbTextInput.pasteCommand(sdkLevel: nil), ["input", "keyevent", "279"])
    }

    /// The level is read on the first paste, not before, and kept for the
    /// pastes after it.
    func testTheAdbSenderReadsTheAPILevelOnceForItsPastes() async throws {
        let commands = Commands()
        let levels = SdkLevels([32])
        let sender = KeyboardSender.adb(run: commands.run, readSdkLevel: levels.read, clipboard: EmulatorSide().sender)

        try await sender.text("a")
        XCTAssertEqual(levels.reads, 0)
        try await sender.pasteShortcut()
        try await sender.pasteShortcut()

        XCTAssertEqual(levels.reads, 1)
        XCTAssertEqual(commands.log, [
            ["input", "text", "a"],
            ["input", "keyevent", "279"],
            ["input", "keyevent", "279"],
        ])
    }

    /// A failed read pastes with the paste key, and the next paste reads
    /// again; its answer is kept.
    func testAFailedAPILevelReadIsTriedAgainOnTheNextPaste() async throws {
        let commands = Commands()
        let levels = SdkLevels([nil, 37])
        let sender = KeyboardSender.adb(run: commands.run, readSdkLevel: levels.read, clipboard: EmulatorSide().sender)

        try await sender.pasteShortcut()
        try await sender.pasteShortcut()
        try await sender.pasteShortcut()

        XCTAssertEqual(levels.reads, 2)
        XCTAssertEqual(commands.log, [
            ["input", "keyevent", "279"],
            ["input", "keycombination", "113", "50"],
            ["input", "keycombination", "113", "50"],
        ])
    }

    /// Every key the mirror forwards as a special key has an Android code,
    /// so none is dropped on the adb route.
    func testEveryForwardedSpecialKeyHasAnAndroidCode() {
        for keyCode: UInt16 in [51, 117, 53, 36, 76, 48, 123, 124, 125, 126, 115, 119, 116, 121] {
            XCTAssertNotNil(PhysicalInput.androidKeyCode(forMacKeyCode: keyCode), "\(keyCode)")
        }
    }

    // MARK: - The routed sender

    /// Key sends follow the route; the clipboard never asks for it (a read
    /// of the clipboard must not probe the guest).
    func testTheRoutedSenderFollowsTheRouteButNotForTheClipboard() async throws {
        final class Asked: @unchecked Sendable {
            private let lock = NSLock()
            private var _count = 0
            var count: Int { lock.withLock { _count } }
            func add() { lock.withLock { _count += 1 } }
        }
        for route in [EmulatorKeyRoute.emulatorKeyboard, .adbInput] {
            let asked = Asked()
            let commands = Commands()
            let emulator = EmulatorSide()
            let sender = KeyboardSender.routed(
                emulatorKeyboard: emulator.sender,
                adb: .adb(run: commands.run, readSdkLevel: { 37 }, clipboard: emulator.sender),
                route: {
                    asked.add()
                    return route
                }
            )

            _ = try await sender.clipboard()
            try await sender.setClipboard("x")
            XCTAssertEqual(asked.count, 0)

            try await sender.text("a")
            try await sender.specialKey(48)
            try await sender.pasteShortcut()
            XCTAssertEqual(asked.count, 3)

            switch route {
            case .emulatorKeyboard:
                XCTAssertEqual(emulator.log, ["clipboard", "set x", "text a", "key 48", "paste"])
                XCTAssertEqual(commands.log, [])
            case .adbInput:
                XCTAssertEqual(emulator.log, ["clipboard", "set x"])
                XCTAssertEqual(commands.log, [
                    ["input", "text", "a"],
                    ["input", "keyevent", "61"],
                    ["input", "keycombination", "113", "50"],
                ])
            }
        }
    }
}
