import Foundation

/// The `adb shell input` commands that type for a guest without the
/// emulator's keyboard (`EmulatorKeyRoute.adbInput`), where the emulator's
/// own key sends are dropped.
enum AdbTextInput {
    /// `KEYCODE_ENTER` and `KEYCODE_TAB` (SOURCE-DERIVED: AOSP
    /// `frameworks/base/core/java/android/view/KeyEvent.java`), for the
    /// newline and tab a typed run can hold: `input text` cannot type
    /// control characters.
    static let enterKeyCode = 66
    static let tabKeyCode = 61

    /// `KEYCODE_CTRL_LEFT` and `KEYCODE_V` (Ctrl+V, the shortcut the
    /// emulator route pastes with) and `KEYCODE_PASTE` (SOURCE-DERIVED:
    /// `KeyEvent.java`).
    static let pasteCombination = ["input", "keycombination", "113", "50"]
    static let pasteKey = ["input", "keyevent", "279"]

    /// The first API level whose `input keycombination` holds Ctrl while it
    /// presses V. SOURCE-DERIVED from AOSP `platform/frameworks/base`:
    /// - android13-release `InputShellCommand.sendKeyCombination` carries
    ///   each modifier's meta state (`MODIFIER`, `KEYCODE_CTRL_LEFT` →
    ///   `META_CTRL_LEFT_ON | META_CTRL_ON`) into the keys after it;
    /// - android12-release and android12L-release (API 31, 32) have the
    ///   command but send every key with meta state 0, so the app gets a
    ///   plain V and types "v";
    /// - android11-release (API 30) and older have no `keycombination`
    ///   (`Input.onRun` throws "Unknown command"), and `input` still exits 0
    ///   (`BaseCommand.run` prints the usage to stderr and returns), so its
    ///   failure cannot be told from a paste.
    static let keyCombinationMinimumAPI = 33

    /// The paste for a guest at `sdkLevel`: Ctrl+V where `keycombination`
    /// holds Ctrl, else the paste key, which a `TextView` handles from API
    /// 24 (`TextView.onKeyDown` `KEYCODE_PASTE`, SOURCE-DERIVED:
    /// android11-release) and which pasted in the Settings search field on
    /// API 37. An unknown level takes the paste key: it may not paste
    /// everywhere, but it never types a wrong character.
    static func pasteCommand(sdkLevel: Int?) -> [String] {
        guard let sdkLevel, sdkLevel >= keyCombinationMinimumAPI else { return pasteKey }
        return pasteCombination
    }

    /// The longest text one `input text` carries; a longer run is split.
    static let chunkLimit = 200

    /// The commands that type `text`, a typed run (`TextRun.typed`: printable
    /// ASCII, newline and tab), in order.
    ///
    /// Text goes through `input text`, escaped for the device shell
    /// (`PhysicalInput.escapedText`, where a space becomes `input`'s own
    /// `%s`). `input` turns every `%s` into a space (SOURCE-DERIVED:
    /// `InputShellCommand.sendText`), so a literal `%` followed by `s` is
    /// cut between the two into separate calls. Newline and tab are key
    /// presses.
    static func commands(typing text: String) -> [[String]] {
        var commands: [[String]] = []
        var chunk = ""
        func flush() {
            let escaped = PhysicalInput.escapedText(chunk)
            if !escaped.isEmpty {
                commands.append(["input", "text", escaped])
            }
            chunk = ""
        }
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n":
                flush()
                commands.append(["input", "keyevent", "\(enterKeyCode)"])
            case "\t":
                flush()
                commands.append(["input", "keyevent", "\(tabKeyCode)"])
            default:
                if scalar == "s", chunk.unicodeScalars.last == "%" {
                    flush()
                }
                chunk.unicodeScalars.append(scalar)
                if chunk.unicodeScalars.count >= chunkLimit {
                    flush()
                }
            }
        }
        flush()
        return commands
    }
}

extension KeyboardSender {
    /// Types through `adb shell input` (`run` takes the arguments after
    /// `shell`). The clipboard stays on `clipboard`'s calls, the emulator's
    /// clipboard service, which does not go through the key queue.
    ///
    /// - text: `AdbTextInput.commands(typing:)`;
    /// - a special key: `input keyevent` with its Android key code
    ///   (`PhysicalInput.androidKeyCode(forMacKeyCode:)`, which maps every
    ///   key the mirror forwards); an unmapped one sends nothing;
    /// - the paste shortcut: `AdbTextInput.pasteCommand(sdkLevel:)`, the
    ///   guest's API level read on the first paste and kept (a failed read
    ///   is tried again on the next one).
    static func adb(
        run: @escaping @Sendable (_ arguments: [String]) async throws -> Void,
        readSdkLevel: @escaping @Sendable () async throws -> Int?,
        clipboard: KeyboardSender
    ) -> KeyboardSender {
        let sdkLevel = GuestSdkLevel(read: readSdkLevel)
        return KeyboardSender(
            text: { text in
                for command in AdbTextInput.commands(typing: text) {
                    try await run(command)
                }
            },
            specialKey: { macKeyCode in
                guard let keyCode = PhysicalInput.androidKeyCode(forMacKeyCode: macKeyCode) else { return }
                try await run(["input", "keyevent", "\(keyCode)"])
            },
            pasteShortcut: {
                try await run(AdbTextInput.pasteCommand(sdkLevel: await sdkLevel.value()))
            },
            clipboard: clipboard.clipboard,
            setClipboard: clipboard.setClipboard
        )
    }

    /// Key sends through `emulatorKeyboard` or `adb`, as `route` decides
    /// (once per run); the clipboard calls always through
    /// `emulatorKeyboard`'s, which work with or without a keyboard device.
    static func routed(
        emulatorKeyboard: KeyboardSender,
        adb: KeyboardSender,
        route: @escaping @Sendable () async -> EmulatorKeyRoute
    ) -> KeyboardSender {
        let pick: @Sendable () async -> KeyboardSender = {
            await route() == .adbInput ? adb : emulatorKeyboard
        }
        return KeyboardSender(
            text: { text in try await pick().text(text) },
            specialKey: { keyCode in try await pick().specialKey(keyCode) },
            pasteShortcut: { try await pick().pasteShortcut() },
            clipboard: emulatorKeyboard.clipboard,
            setClipboard: emulatorKeyboard.setClipboard
        )
    }
}

/// A guest's API level, read when first asked and kept; a read that fails
/// or answers no number is tried again next time.
actor GuestSdkLevel {
    private let read: @Sendable () async throws -> Int?
    private var level: Int?

    init(read: @escaping @Sendable () async throws -> Int?) {
        self.read = read
    }

    func value() async -> Int? {
        if let level { return level }
        let answer = try? await read()
        if level == nil {
            level = answer
        }
        return level
    }
}
