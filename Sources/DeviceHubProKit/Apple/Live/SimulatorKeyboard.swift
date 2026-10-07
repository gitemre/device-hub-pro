import Foundation

/// One key press on the simulator's HID keyboard: a USB HID usage (page 7)
/// with the modifier keys held around it.
public struct SimulatorKeyStroke: Sendable, Equatable, CustomStringConvertible {
    public var usage: UInt32
    /// Modifier usages, pressed in order before the key and released in
    /// reverse after it.
    public var modifiers: [UInt32]

    public init(usage: UInt32, modifiers: [UInt32] = []) {
        self.usage = usage
        self.modifiers = modifiers
    }

    public var description: String {
        (modifiers.map { String(format: "0x%02X+", $0) } + [String(format: "0x%02X", usage)]).joined()
    }

    /// The HID events of the press, in order.
    public var events: [SimulatorHIDEvent] {
        modifiers.map { .key(usage: $0, isDown: true) }
            + [.key(usage: usage, isDown: true), .key(usage: usage, isDown: false)]
            + modifiers.reversed().map { .key(usage: $0, isDown: false) }
    }
}

/// The simulator's hardware keyboard layout: which character each HID key
/// position types. A HID usage is a key position, not a character, so text
/// can only be typed with the table of the layout the simulator uses; the
/// same usage 0x0C types "i" on U.S. and "ı" on Turkish Q (measured).
public enum SimulatorKeyboardLayout: String, Sendable, CaseIterable {
    /// U.S. (the USB HID Usage Tables' own key names).
    case usQWERTY
    /// Turkish Q, what a simulator on a `tr_TR` Mac gets by default.
    case turkishQ

    /// The key that types `character`, or nil when this layout has none
    /// (dead keys are left out: they type nothing on their own).
    public func stroke(for character: Character) -> SimulatorKeyStroke? {
        switch self {
        case .usQWERTY: return SimulatorKeyboard.usTable[character]
        case .turkishQ: return SimulatorKeyboard.turkishQTable[character]
        }
    }
}

/// The keyboard half of `SimulatorMirrorSession`: special keys, the layout
/// tables, and how text becomes key presses.
public enum SimulatorKeyboard {
    public static let leftShift: UInt32 = 0xE1
    public static let leftOption: UInt32 = 0xE2
    public static let leftCommand: UInt32 = 0xE3
    /// The V key position; ⌘ plus this pastes.
    static let vKey: UInt32 = 0x19

    /// ⌘V.
    public static let pasteStroke = SimulatorKeyStroke(usage: vKey, modifiers: [leftCommand])

    /// The HID usage for a macOS virtual key code the mirror view forwards as
    /// a special key (`MirrorKeyRouting.specialKeyCodes`, plus space). Nil
    /// for any other code.
    public static func usage(forMacKeyCode keyCode: UInt16) -> UInt32? {
        switch keyCode {
        case 36: return 0x28   // return → Keyboard Return (ENTER)
        case 76: return 0x58   // keypad enter → Keypad ENTER
        case 48: return 0x2B   // tab → Keyboard Tab
        case 49: return 0x2C   // space → Keyboard Spacebar
        case 51: return 0x2A   // delete → Keyboard DELETE (Backspace)
        case 117: return 0x4C  // forward delete → Keyboard Delete Forward
        case 53: return 0x29   // escape → Keyboard ESCAPE
        case 123: return 0x50  // left arrow
        case 124: return 0x4F  // right arrow
        case 125: return 0x51  // down arrow
        case 126: return 0x52  // up arrow
        case 115: return 0x4A  // home
        case 119: return 0x4D  // end
        case 116: return 0x4B  // page up
        case 121: return 0x4E  // page down
        default: return nil
        }
    }

    /// One step of entering text.
    public enum Step: Sendable, Equatable {
        case stroke(SimulatorKeyStroke)
        /// Text the layout has no key for: put on the simulator pasteboard,
        /// then ⌘V. Experimental: on iOS 27.0 the ⌘V did not insert
        /// `simctl pbcopy` text in any field tried.
        case paste(String)
    }

    /// The steps that enter `text` on `layout`: a key press for every
    /// character the layout can type (newline is Return, tab is Tab), and
    /// runs of the rest as pastes. Characters a key press cannot produce and
    /// that are not text (control characters other than newline and tab, the
    /// U+F700–U+F8FF function-key characters AppKit reports) are dropped.
    public static func steps(for text: String, layout: SimulatorKeyboardLayout) -> [Step] {
        var steps: [Step] = []
        var pending = ""
        var kept = ""
        kept.unicodeScalars.append(contentsOf: text.unicodeScalars.filter { !isDropped($0) })
        for character in kept {
            if let stroke = layout.stroke(for: character) {
                if !pending.isEmpty {
                    steps.append(.paste(pending))
                    pending = ""
                }
                steps.append(.stroke(stroke))
            } else {
                pending.append(character)
            }
        }
        if !pending.isEmpty { steps.append(.paste(pending)) }
        return steps
    }

    private static func isDropped(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\n" || scalar == "\t" { return false }
        return scalar.properties.generalCategory == .control || (0xF700...0xF8FF).contains(scalar.value)
    }

    // MARK: - Which layout

    /// The layout a simulator's hardware keyboard uses, read from its global
    /// preferences (`data/Library/Preferences/.GlobalPreferences.plist`).
    /// An explicit `hw=U.S.` keyboard wins; otherwise the layout is
    /// "Automatic" and follows the first keyboard's (or language's)
    /// language: Turkish types Turkish Q, U.S. English types U.S. Nil for
    /// anything else (unknown to these tables).
    public static func layout(globalPreferences preferences: [String: Any]) -> SimulatorKeyboardLayout? {
        let keyboards = preferences["AppleKeyboards"] as? [String] ?? []
        if keyboards.contains(where: { $0.contains("hw=U.S.") }) { return .usQWERTY }
        let first = keyboards.first
            ?? (preferences["ApplePasscodeKeyboards"] as? [String])?.first
            ?? (preferences["AppleLanguages"] as? [String])?.first
        guard let first else { return nil }
        if let explicit = first.range(of: "hw="), !first[explicit.upperBound...].hasPrefix("Automatic") {
            return nil
        }
        let identifier = first.split(separator: "@").first.map(String.init) ?? first
        let parts = identifier.split(whereSeparator: { $0 == "_" || $0 == "-" }).map(String.init)
        switch parts.first {
        case "tr": return .turkishQ
        case "en" where parts.count == 1 || parts[1] == "US": return .usQWERTY
        default: return nil
        }
    }

    /// Where a simulator keeps its global preferences on the Mac.
    public static func globalPreferencesURL(udid: String, deviceSet: URL?) -> URL {
        let set = deviceSet ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
        return set.appendingPathComponent(udid, isDirectory: true)
            .appendingPathComponent("data/Library/Preferences/.GlobalPreferences.plist")
    }

    /// Reads the layout from the simulator's preferences file; nil when the
    /// file cannot be read or names a layout without a table.
    public static func layout(udid: String, deviceSet: URL?) -> SimulatorKeyboardLayout? {
        let url = globalPreferencesURL(udid: udid, deviceSet: deviceSet)
        guard let data = try? Data(contentsOf: url),
              let preferences = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return layout(globalPreferences: preferences)
    }

    // MARK: - Tables

    private static func table(_ layers: [(modifiers: [UInt32], keys: [(UInt32, Character)])]) -> [Character: SimulatorKeyStroke] {
        var table: [Character: SimulatorKeyStroke] = [:]
        // Earlier layers win: a character on two keys gets the one with
        // fewer modifiers.
        for layer in layers {
            for (usage, character) in layer.keys where table[character] == nil {
                table[character] = SimulatorKeyStroke(usage: usage, modifiers: layer.modifiers)
            }
        }
        return table
    }

    private static func letters(_ characters: String, from usage: UInt32 = 0x04) -> [(UInt32, Character)] {
        characters.enumerated().map { (usage + UInt32($0.offset), $0.element) }
    }

    /// Keys every layout here shares: Return, Tab and the space bar.
    private static let controlKeys: [(UInt32, Character)] = [(0x28, "\n"), (0x2B, "\t"), (0x2C, " ")]

    /// U.S.: the key names of the USB HID Usage Tables 1.4, Keyboard/Keypad
    /// page 0x07 (public), which an iOS 27.0 simulator set to U.S. English
    /// typed key for key (`Fixtures/ios27-simulator/bridge/hid-keyboard-layout-en_US.tsv`).
    static let usTable = table([
        ([], controlKeys + letters("abcdefghijklmnopqrstuvwxyz") + letters("1234567890", from: 0x1E) + [
            (0x2D, "-"), (0x2E, "="), (0x2F, "["), (0x30, "]"), (0x31, "\\"), (0x33, ";"),
            (0x34, "'"), (0x35, "`"), (0x36, ","), (0x37, "."), (0x38, "/"),
        ]),
        ([leftShift], letters("ABCDEFGHIJKLMNOPQRSTUVWXYZ") + letters("!@#$%^&*()", from: 0x1E) + [
            (0x2D, "_"), (0x2E, "+"), (0x2F, "{"), (0x30, "}"), (0x31, "|"), (0x33, ":"),
            (0x34, "\""), (0x35, "~"), (0x36, "<"), (0x37, ">"), (0x38, "?"),
        ]),
    ])

    /// Turkish Q, captured from an iOS 27.0 simulator
    /// (`Fixtures/ios27-simulator/bridge/hid-keyboard-layout-tr_TR*.tsv`,
    /// which `SimulatorKeyboardTests` checks every entry against). Shift+3
    /// (^) and the Option keys for ¨ ~ ` ´ are dead keys and left out; ^ and
    /// ~ come from Option+H and Option+N instead. No key types a backtick
    /// on its own.
    static let turkishQTable = table([
        ([], controlKeys + letters("abcdefghıjklmnopqrstuvwxyz") + letters("1234567890", from: 0x1E) + [
            (0x2D, "*"), (0x2E, "-"), (0x2F, "ğ"), (0x30, "ü"), (0x31, ","), (0x33, "ş"),
            (0x34, "i"), (0x35, "<"), (0x36, "ö"), (0x37, "ç"), (0x38, "."), (0x64, "\""),
        ]),
        ([leftShift], letters("ABCDEFGHIJKLMNOPQRSTUVWXYZ") + [
            (0x1E, "!"), (0x1F, "'"), (0x21, "+"), (0x22, "%"), (0x23, "&"), (0x24, "/"),
            (0x25, "("), (0x26, ")"), (0x27, "="), (0x2D, "?"), (0x2E, "_"), (0x2F, "Ğ"),
            (0x30, "Ü"), (0x31, ";"), (0x33, "Ş"), (0x34, "İ"), (0x35, ">"), (0x36, "Ö"),
            (0x37, "Ç"), (0x38, ":"), (0x64, "é"),
        ]),
        ([leftOption], [
            (0x14, "@"), (0x20, "#"), (0x21, "$"), (0x24, "{"), (0x25, "["), (0x26, "]"),
            (0x27, "}"), (0x2D, "\\"), (0x2E, "|"), (0x0B, "^"), (0x11, "~"), (0x08, "€"),
            (0x17, "₺"), (0x1F, "£"),
        ]),
    ])
}
