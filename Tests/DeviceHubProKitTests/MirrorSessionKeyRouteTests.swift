import XCTest
@testable import DeviceHubProKit

/// An emulator session with the adb fallback: each run asks the guest once
/// (the real `getevent -lp` captures, `InputFixtures`) and sends the frame's
/// buttons and the typing to the emulator or through `adb shell input`. No
/// emulator: the emulator's sends and the adb commands go to recording
/// fakes; the video task dials port 1, which is closed.
final class MirrorSessionKeyRouteTests: XCTestCase {
    /// What reached the emulator (hardware keys and keyboard) and adb.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _emulator: [String] = []
        private var _adb: [[String]] = []
        private var _reads = 0

        var emulator: [String] { lock.withLock { _emulator } }
        var adb: [[String]] { lock.withLock { _adb } }
        var reads: Int { lock.withLock { _reads } }

        private func emulatorSent(_ entry: String) { lock.withLock { _emulator.append(entry) } }

        var hardwareKeySender: HardwareKeySender {
            HardwareKeySender { event in
                self.emulatorSent("\(event.key) \(event.isDown ? "down" : "up")")
            }
        }

        var keyboardSender: KeyboardSender {
            KeyboardSender(
                text: { self.emulatorSent("text \($0)") },
                specialKey: { self.emulatorSent("key \($0)") },
                pasteShortcut: { self.emulatorSent("paste") },
                clipboard: { "" },
                setClipboard: { _ in }
            )
        }

        func adbInput(listing: String, sdkLevel: Int? = 37) -> AdbKeyInput {
            AdbKeyInput(
                readInputDevices: {
                    self.lock.withLock { self._reads += 1 }
                    return listing
                },
                readSdkLevel: { sdkLevel },
                run: { command in
                    self.lock.withLock { self._adb.append(command) }
                }
            )
        }
    }

    private func session(_ recorder: Recorder, listing: String, sdkLevel: Int? = 37) -> MirrorSession {
        MirrorSession(
            port: 1,
            touchSender: { _, _, _ in },
            hardwareKeySender: recorder.hardwareKeySender,
            keyboardSender: recorder.keyboardSender,
            adbKeyInput: recorder.adbInput(listing: listing, sdkLevel: sdkLevel),
            // No repeat or long press within a test's time.
            adbKeyTiming: .init(repeatTimeout: .seconds(60), repeatInterval: .seconds(60), powerLongPress: .seconds(60))
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    /// avdmanager's AVD (no "qwerty2"): power, volume and typing all go
    /// through `adb shell input`, nothing to the emulator, and the guest is
    /// asked once for the whole run.
    func testAKeyboardlessGuestGetsItsKeysThroughAdb() async throws {
        let recorder = Recorder()
        let session = session(recorder, listing: try InputFixtures.text(InputFixtures.keyboardless))
        XCTAssertTrue(session.supportsHardwareKeys)
        session.start()
        defer { session.stop() }

        session.send(HardwareKeyEvent(key: .power, isDown: true))
        session.send(HardwareKeyEvent(key: .power, isDown: false))
        session.send(HardwareKeyEvent(key: .volumeDown, isDown: true))
        session.send(HardwareKeyEvent(key: .volumeDown, isDown: false))
        session.send(KeyboardCommand.text("ab c"))
        session.send(KeyboardCommand.specialKey(51))

        await waitUntil { recorder.adb.count == 4 }
        XCTAssertEqual(Set(recorder.adb), [
            ["input", "keyevent", "26"],
            ["input", "keyevent", "25"],
            ["input", "text", "ab%sc"],
            ["input", "keyevent", "67"],
        ])
        XCTAssertEqual(recorder.adb.filter { $0[1] == "keyevent" && $0[2] != "67" }, [
            ["input", "keyevent", "26"],
            ["input", "keyevent", "25"],
        ], "the buttons in the order they were pressed")
        XCTAssertEqual(recorder.emulator, [])
        XCTAssertEqual(recorder.reads, 1)
    }

    /// A guest with the emulator's keyboard keeps today's route: real key
    /// edges to the emulator, typing too, and adb runs nothing but the one
    /// probe.
    func testAGuestWithTheKeyboardKeepsTheEmulatorRoute() async throws {
        let recorder = Recorder()
        let session = session(recorder, listing: try InputFixtures.text(InputFixtures.withKeyboard))
        session.start()
        defer { session.stop() }

        session.send(HardwareKeyEvent(key: .power, isDown: true))
        session.send(HardwareKeyEvent(key: .power, isDown: false))
        session.send(KeyboardCommand.text("ab"))

        await waitUntil { recorder.emulator.count == 3 }
        XCTAssertEqual(recorder.emulator.filter { $0.hasPrefix("power") }, ["power down", "power up"])
        XCTAssertTrue(recorder.emulator.contains("text ab"))
        XCTAssertEqual(recorder.adb, [])
        XCTAssertEqual(recorder.reads, 1)
    }

    /// A restarted session asks again: a new run may be a new VM.
    func testEachRunAsksTheGuestAgain() async throws {
        let recorder = Recorder()
        let session = session(recorder, listing: try InputFixtures.text(InputFixtures.keyboardless))
        session.start()
        session.send(KeyboardCommand.text("a"))
        await waitUntil { recorder.adb.count == 1 }
        session.stop()

        session.start()
        defer { session.stop() }
        session.send(KeyboardCommand.text("b"))
        await waitUntil { recorder.adb.count == 2 }
        XCTAssertEqual(recorder.reads, 2)
    }

    /// The stream ending with a button still held on the adb route (a stop
    /// no key-up came before, `HardwareKeySender.releaseAtEnd`): a power
    /// press not yet sent is dropped, and a held volume key does not repeat
    /// past the stop. The app releases its held keys first
    /// (`testReleasingTheKeysBeforeTheStopCompletesTheirPresses`).
    func testStoppingWithAButtonHeldSendsNothingNew() async throws {
        let recorder = Recorder()
        let session = session(recorder, listing: try InputFixtures.text(InputFixtures.keyboardless))
        session.start()

        session.send(HardwareKeyEvent(key: .volumeUp, isDown: true))
        await waitUntil { recorder.adb == [["input", "keyevent", "24"]] }
        session.send(HardwareKeyEvent(key: .power, isDown: true))
        try await Task.sleep(for: .milliseconds(100))
        session.stop()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(recorder.adb, [["input", "keyevent", "24"]])
        XCTAssertEqual(recorder.emulator, [])
    }

    /// The app's own stop: `MirrorController.stopSession` (and a window
    /// that resigns) releases every held key before the session stops, so
    /// on the adb route a power hold cut short becomes its short press, as
    /// the key-down the emulator route already sent is completed by its
    /// key-up; a volume hold stops repeating. Nothing goes out after that.
    func testReleasingTheKeysBeforeTheStopCompletesTheirPresses() async throws {
        let recorder = Recorder()
        let session = session(recorder, listing: try InputFixtures.text(InputFixtures.keyboardless))
        session.start()

        session.send(HardwareKeyEvent(key: .volumeUp, isDown: true))
        await waitUntil { recorder.adb == [["input", "keyevent", "24"]] }
        session.send(HardwareKeyEvent(key: .power, isDown: true))
        try await Task.sleep(for: .milliseconds(100))
        // `releaseAllHardwareKeys`, in `HardwareKey.allCases` order, then
        // the stop.
        for key in HardwareKey.allCases where key != .volumeDown {
            session.send(HardwareKeyEvent(key: key, isDown: false))
        }
        session.stop()

        await waitUntil { recorder.adb.count == 2 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(recorder.adb, [["input", "keyevent", "24"], ["input", "keyevent", "26"]])
        XCTAssertEqual(recorder.emulator, [])
    }

    /// The paste of non-ASCII text on the adb route goes by the guest's API
    /// level (`AdbTextInput.pasteCommand(sdkLevel:)`): Ctrl+V from API 33,
    /// the paste key below.
    func testAKeyboardlessGuestPastesAsItsAPILevelAllows() async throws {
        for (level, paste) in [(37, ["input", "keycombination", "113", "50"]), (32, ["input", "keyevent", "279"])] {
            let recorder = Recorder()
            let session = session(recorder, listing: try InputFixtures.text(InputFixtures.keyboardless), sdkLevel: level)
            session.start()

            session.send(KeyboardCommand.text("aş"))

            await waitUntil { recorder.adb.count == 2 }
            XCTAssertEqual(recorder.adb, [["input", "text", "a"], paste], "API \(level)")
            XCTAssertEqual(recorder.emulator, [])
            session.stop()
            // The stopped run gives the borrowed clipboard back.
            await waitUntil { BorrowedClipboards.shared.original(port: 1) == nil }
        }
    }

    /// The buttons and the typing are routed apart. The listing is the real
    /// `hw.keyboard=yes` capture with the two KEY lines that hold
    /// KEY_LEFTCTRL, KEY_A and KEY_V trimmed (here, in memory), so its
    /// "qwerty2" reports power and volume but not the typing keys, as the
    /// older machine's `goldfish-events` does without a keyboard
    /// (SOURCE-DERIVED, `EmulatorKeyRouteTests`): the buttons stay on the
    /// emulator, the typing goes through adb.
    func testTheButtonsAndTheTypingAreRoutedApart() async throws {
        let typingKeys: Set<Substring> = ["KEY_LEFTCTRL", "KEY_A", "KEY_V"]
        let lines = try InputFixtures.text(InputFixtures.withKeyboard).split(separator: "\n", omittingEmptySubsequences: false)
        let trimmed = lines.filter { line in !line.split(separator: " ").contains(where: typingKeys.contains) }
        XCTAssertEqual(lines.count - trimmed.count, 2)
        let listing = trimmed.joined(separator: "\n")
        XCTAssertEqual(
            GuestInputDevices.routes(fromGeteventLp: listing),
            EmulatorKeyRoutes(sideButtons: .emulatorKeyboard, typing: .adbInput)
        )

        let recorder = Recorder()
        let session = session(recorder, listing: listing)
        session.start()
        defer { session.stop() }

        session.send(HardwareKeyEvent(key: .power, isDown: true))
        session.send(HardwareKeyEvent(key: .power, isDown: false))
        session.send(KeyboardCommand.text("ab"))

        await waitUntil { recorder.emulator.count == 2 && recorder.adb.count == 1 }
        XCTAssertEqual(recorder.emulator, ["power down", "power up"])
        XCTAssertEqual(recorder.adb, [["input", "text", "ab"]])
        XCTAssertEqual(recorder.reads, 1)
    }

    /// Without the fallback (the plain initializer, or a test session
    /// without `adbKeyInput`) every key goes to the emulator, as before.
    func testWithoutTheFallbackEveryKeyGoesToTheEmulator() async {
        let recorder = Recorder()
        let session = MirrorSession(
            port: 1,
            touchSender: { _, _, _ in },
            hardwareKeySender: recorder.hardwareKeySender,
            keyboardSender: recorder.keyboardSender
        )
        XCTAssertNil(session.adbFallback)
        session.start()
        defer { session.stop() }

        session.send(HardwareKeyEvent(key: .volumeUp, isDown: true))
        session.send(HardwareKeyEvent(key: .volumeUp, isDown: false))
        await waitUntil { recorder.emulator == ["volumeUp down", "volumeUp up"] }
        XCTAssertEqual(recorder.reads, 0)
        XCTAssertNil(MirrorSession(port: 1).adbFallback)
    }
}
