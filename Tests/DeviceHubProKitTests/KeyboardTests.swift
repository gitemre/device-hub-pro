import XCTest
@testable import DeviceHubProKit

final class KeyboardTests: XCTestCase {
    func testPlainASCIIIsTyped() {
        XCTAssertEqual(TextRun.split("hello, world!"), [.typed("hello, world!")])
        XCTAssertEqual(TextRun.split("line\nnext\tcell"), [.typed("line\nnext\tcell")])
    }

    func testCharactersWithoutAnEnUSKeyArePasted() {
        // The emulator drops these when they are sent as key presses.
        XCTAssertEqual(TextRun.split("şğüöçı"), [.pasted("şğüöçı")])
        XCTAssertEqual(TextRun.split("İstanbul"), [.pasted("İ"), .typed("stanbul")])
        XCTAssertEqual(
            TextRun.split("a ş b"),
            [.typed("a "), .pasted("ş"), .typed(" b")]
        )
    }

    func testComposedCharactersStayWhole() {
        XCTAssertEqual(TextRun.split("e\u{301}"), [.pasted("e\u{301}")], "é as e + combining accent")
        XCTAssertEqual(TextRun.split("hi 👋🏽"), [.typed("hi "), .pasted("👋🏽")])
    }

    func testEmptyTextHasNoRuns() {
        XCTAssertEqual(TextRun.split(""), [])
    }

    func testKeysThatAreNotTextAreDropped() {
        // Ctrl+A, DEL, a C1 control, F1 and Help as AppKit reports them: the
        // emulator dropped them as key text, and a paste would put invisible
        // characters or tofu into the field.
        for character in ["\u{01}", "\u{1A}", "\u{7F}", "\u{85}", "\u{F704}", "\u{F746}", "\r"] {
            XCTAssertEqual(TextRun.split(character), [], "U+\(String(character.unicodeScalars.first!.value, radix: 16))")
        }
        XCTAssertEqual(TextRun.split("a\u{01}b\u{F704}ş"), [.typed("ab"), .pasted("ş")])
        XCTAssertEqual(TextRun.split("line\r\nnext"), [.typed("line\nnext")], "CR LF is one character")
    }

    // MARK: - Pasting through the clipboard

    /// An emulator's keyboard and clipboard, recording every call.
    private final class FakeEmulator: @unchecked Sendable {
        enum Call: Equatable {
            case text(String)
            case key(UInt16)
            case readClipboard
            case setClipboard(String)
            case paste
        }

        private let lock = NSLock()
        private var _clipboard: String
        private var _calls: [(call: Call, at: ContinuousClock.Instant)] = []

        init(clipboard: String) {
            _clipboard = clipboard
        }

        var clipboard: String { lock.withLock { _clipboard } }
        var calls: [Call] { lock.withLock { _calls.map(\.call) } }

        func time(of call: Call, occurrence: Int = 0) -> ContinuousClock.Instant? {
            lock.withLock { _calls.filter { $0.call == call }.dropFirst(occurrence).first?.at }
        }

        private func record(_ call: Call) {
            lock.withLock { _calls.append((call, .now)) }
        }

        var sender: KeyboardSender {
            KeyboardSender(
                text: { self.record(.text($0)) },
                specialKey: { self.record(.key($0)) },
                pasteShortcut: { self.record(.paste) },
                clipboard: {
                    self.record(.readClipboard)
                    return self.clipboard
                },
                setClipboard: { text in
                    self.lock.withLock { self._clipboard = text }
                    self.record(.setClipboard(text))
                }
            )
        }
    }

    /// Runs an injector against `emulator` until `body` returns, then stops
    /// it the way `MirrorSession.stop()` does and waits for it to end.
    private func withInjector(
        port: Int,
        emulator: FakeEmulator,
        timing: KeyboardInjector.Timing,
        _ body: (AsyncStream<KeyboardInjector.Step>.Continuation) async throws -> Void
    ) async rethrows {
        let (steps, continuation) = AsyncStream<KeyboardInjector.Step>.makeStream()
        let stopSignal = KeyboardInjector.StopSignal()
        let sender = emulator.sender
        let injector = Task {
            await KeyboardInjector.run(
                port: port,
                steps: steps,
                schedule: { continuation.yield($0) },
                reportError: { XCTFail("unexpected send failure: \($0)") },
                stopSignal: stopSignal,
                sender: sender,
                timing: timing
            )
        }
        try await body(continuation)
        stopSignal.stop()
        continuation.finish()
        await injector.value
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func testClipboardReadsAndWritesDoNotSeeAPasteInProgress() async throws {
        // The app's clipboard sync must neither copy the typed characters to
        // the Mac nor have a newer Mac clipboard undone by the restore. The
        // reads and writes below reach no emulator while the paste holds
        // the clipboard; should one ever dial, it reaches only this test.
        let port = try makeOwnedGrpcPort()
        let emulator = FakeEmulator(clipboard: "user copy")
        await withInjector(
            port: port,
            emulator: emulator,
            timing: .init(clipboardDelivery: .zero, pasteSettle: .zero, restoreDelay: .seconds(1))
        ) { keys in
            keys.yield(.command(.text("ş")))
            let pasted = await waitUntil { emulator.calls.contains(.paste) }
            XCTAssertTrue(pasted)
            XCTAssertEqual(emulator.clipboard, "ş", "the emulator holds the pasted text")

            let seen = await EmulatorControls.clipboard(port: port)
            XCTAssertEqual(seen, "user copy", "a read during the paste reports the user's clipboard")

            let wrote = await EmulatorControls.setClipboard(port: port, text: "newer mac copy")
            XCTAssertTrue(wrote)
            XCTAssertEqual(emulator.clipboard, "ş", "a write must not replace the text being pasted")

            let restored = await waitUntil { BorrowedClipboards.shared.original(port: port) == nil }
            XCTAssertTrue(restored)
        }
        XCTAssertEqual(emulator.clipboard, "newer mac copy", "the restore puts back the newer clipboard")
        XCTAssertEqual(
            emulator.calls,
            [.readClipboard, .setClipboard("ş"), .paste, .setClipboard("newer mac copy")]
        )
    }

    func testAPasteWaitsForThePreviousOneBeforeReplacingTheClipboard() async throws {
        // Adjacent Turkish letters typed as separate keystrokes: the app
        // reads the clipboard only when it handles Ctrl+V.
        let port = 60_002
        let emulator = FakeEmulator(clipboard: "user copy")
        let timing = KeyboardInjector.Timing(
            clipboardDelivery: .milliseconds(20),
            pasteSettle: .milliseconds(120),
            restoreDelay: .milliseconds(200)
        )
        await withInjector(port: port, emulator: emulator, timing: timing) { keys in
            keys.yield(.command(.text("ç")))
            keys.yield(.command(.text("a")))
            keys.yield(.command(.text("ı")))
            let restored = await waitUntil { emulator.calls.last == .setClipboard("user copy") }
            XCTAssertTrue(restored)
        }

        XCTAssertEqual(emulator.calls, [
            .readClipboard,
            .setClipboard("ç"), .paste,
            .text("a"),
            .setClipboard("ı"), .paste,
            .setClipboard("user copy"),
        ], "one read and one restore for the burst")

        let firstSet = try XCTUnwrap(emulator.time(of: .setClipboard("ç")))
        let firstPaste = try XCTUnwrap(emulator.time(of: .paste))
        let secondSet = try XCTUnwrap(emulator.time(of: .setClipboard("ı")))
        XCTAssertGreaterThanOrEqual(firstPaste - firstSet, timing.clipboardDelivery)
        XCTAssertGreaterThanOrEqual(secondSet - firstPaste, timing.pasteSettle)
        XCTAssertNil(BorrowedClipboards.shared.original(port: port))
    }

    func testStoppingTheSessionStillRestoresTheClipboard() async {
        let port = 60_003
        let emulator = FakeEmulator(clipboard: "user copy")
        await withInjector(
            port: port,
            emulator: emulator,
            timing: .init(clipboardDelivery: .zero, pasteSettle: .zero, restoreDelay: .milliseconds(50))
        ) { keys in
            keys.yield(.command(.text("ğ")))
            let pasted = await waitUntil { emulator.calls.contains(.paste) }
            XCTAssertTrue(pasted)
        }
        XCTAssertEqual(emulator.clipboard, "user copy")
        XCTAssertEqual(emulator.calls.last, .setClipboard("user copy"))
        XCTAssertNil(BorrowedClipboards.shared.original(port: port))
    }

    func testStoppingTheSessionDropsQueuedKeysButRestoresTheClipboard() async {
        // A typing backlog against a hung emulator: after stop() nothing
        // queued may reach the old emulator, only the clipboard goes back.
        let port = 60_004
        let emulator = FakeEmulator(clipboard: "user copy")
        let hung = Gate()
        var sender = emulator.sender
        let recordText = sender.text
        sender.text = { text in
            try await recordText(text)
            await hung.wait()
        }
        let (steps, keys) = AsyncStream<KeyboardInjector.Step>.makeStream()
        let stopSignal = KeyboardInjector.StopSignal()
        let injector = Task { [sender] in
            await KeyboardInjector.run(
                port: port,
                steps: steps,
                schedule: { keys.yield($0) },
                reportError: { XCTFail("unexpected send failure: \($0)") },
                stopSignal: stopSignal,
                sender: sender,
                timing: .init(clipboardDelivery: .zero, pasteSettle: .zero, restoreDelay: .milliseconds(50))
            )
        }

        keys.yield(.command(.text("ş")))
        keys.yield(.command(.text("a")))
        let stuck = await waitUntil { emulator.calls.contains(.text("a")) }
        XCTAssertTrue(stuck)
        keys.yield(.command(.text("b")))
        keys.yield(.command(.text("ğ")))
        keys.yield(.command(.specialKey(51)))

        stopSignal.stop()
        keys.finish()
        await hung.open()
        await injector.value

        XCTAssertEqual(emulator.calls, [
            .readClipboard, .setClipboard("ş"), .paste,
            .text("a"),
            .setClipboard("user copy"),
        ])
        XCTAssertNil(BorrowedClipboards.shared.original(port: port))
    }

    /// Blocks callers until opened.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    func testABorrowKeepsTheFirstOriginalAndRestoresTheLatest() {
        let clipboards = BorrowedClipboards()
        XCTAssertFalse(clipboards.replaceOriginal(port: 1, with: "x"), "nothing is borrowed")

        clipboards.borrow(port: 1, original: "user copy")
        clipboards.borrow(port: 1, original: "ş")
        XCTAssertEqual(clipboards.original(port: 1), "user copy", "the emulator already holds pasted text")
        XCTAssertNil(clipboards.original(port: 2))

        XCTAssertTrue(clipboards.replaceOriginal(port: 1, with: "newer"))
        XCTAssertFalse(clipboards.finish(port: 1, restored: "user copy"), "the newer text must be written too")
        XCTAssertTrue(clipboards.finish(port: 1, restored: "newer"))
        XCTAssertNil(clipboards.original(port: 1))
    }
}
