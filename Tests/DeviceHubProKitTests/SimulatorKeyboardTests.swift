import XCTest
@testable import DeviceHubProKit

/// The simulator keyboard: special keys, the layout tables, how text becomes
/// key presses or pastes, and which layout a simulator uses.
///
/// PRIVATE-API CoreSimulator 1171.7: the layout tables were typed through the
/// private dtuhidd bridge, and the preferences are read from the simulator's
/// own data folder by undocumented keys (`AppleKeyboards` with its `hw=`
/// part, `ApplePasscodeKeyboards`). The live canary is
/// `SimulatorMirrorSessionLiveTests`: the layout it reads from its fresh
/// simulator's preferences must match that simulator's `AppleLocale`, and
/// text typed with that layout's table must read back exactly.
///
/// Captures under `Fixtures/ios27-simulator/bridge/`, all from one iPhone 17
/// Pro (iOS 27.0, 24A434) in a private device set on CoreSimulator 1171.7,
/// created fresh on a `tr_TR` Mac and deleted afterwards:
///
/// - `hid-keyboard-layout-tr_TR.tsv`: with Safari's address field focused,
///   for every usage 0x04–0x27, 0x2C, 0x2D–0x38 and 0x64, in four modifier
///   layers (none, Left Shift, Left Option, both), the capture tool cleared
///   the field (⌘A, Delete), typed usage 0x27 ("0") and then the key through
///   dtuhidd, selected all, copied (⌘C) and read the pasteboard back with
///   `simctl pbpaste` (LANG=en_US.UTF-8). `read_back` is what came back,
///   "0" included. A dead key types nothing and leaves the field in a
///   composing state, so the Delete after it fails and the next rows pile up
///   zeros (shift 0x20–0x21, option 0x2F–0x34); the table uses no such row.
///   Byte-exact.
/// - `hid-keyboard-layout-tr_TR.flushed.tsv`: the same tool re-run for
///   shift 0x20 and 0x21 with a space typed after the key, which makes a
///   dead key show its accent. Trimmed to those two rows: the rows after them
///   read the sentinel the tool put on the pasteboard, because Safari had
///   left the screen.
/// - `GlobalPreferences.tr_TR.plist`: the device's
///   `data/Library/Preferences/.GlobalPreferences.plist` as it was then
///   (binary, byte-exact; no `AppleKeyboards`, so the layout is automatic).
/// - `hid-keyboard-layout-en_US.tsv` and `GlobalPreferences.en_US.plist`:
///   the same device after `simctl spawn <UDID> defaults write -g` set
///   `AppleLanguages` (en-US), `AppleLocale` (en_US) and
///   `ApplePasscodeKeyboards` (en_US, emoji) and it rebooted; the same tool,
///   byte-exact. Its Option layers hold dead keys too; the U.S. table uses
///   none and shift only.
final class SimulatorKeyboardTests: XCTestCase {
    private struct CapturedKey: Hashable {
        let usage: UInt32
        let layer: String
    }

    private static func layer(of modifiers: [UInt32]) -> String {
        switch modifiers {
        case []: return "none"
        case [SimulatorKeyboard.leftShift]: return "shift"
        case [SimulatorKeyboard.leftOption]: return "option"
        case [SimulatorKeyboard.leftShift, SimulatorKeyboard.leftOption]: return "shift+option"
        default: return "?"
        }
    }

    /// usage/layer → the characters the key typed after the "0" (hex column
    /// decoded, so trailing spaces survive).
    private func capturedLayout(_ name: String) throws -> [CapturedKey: String] {
        let text = try String(contentsOf: SimctlFixtureTests.url("bridge", name), encoding: .utf8)
        var captured: [CapturedKey: String] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            XCTAssertGreaterThanOrEqual(columns.count, 3, String(line))
            let usage = try XCTUnwrap(UInt32(columns[0].dropFirst(2), radix: 16))
            var typed = ""
            for scalar in columns[2].split(separator: " ") {
                typed.unicodeScalars.append(try XCTUnwrap(Unicode.Scalar(try XCTUnwrap(UInt32(scalar.dropFirst(2), radix: 16)))))
            }
            XCTAssertTrue(typed.hasPrefix("0"), String(line))
            captured[CapturedKey(usage: usage, layer: String(columns[1]))] = String(typed.dropFirst())
        }
        return captured
    }

    // MARK: - Tables

    /// Every Turkish Q entry is what that key typed on the simulator, alone.
    func testTheTurkishTableIsTheCapturedLayout() throws {
        let captured = try capturedLayout("hid-keyboard-layout-tr_TR.tsv")
        let flushed = try capturedLayout("hid-keyboard-layout-tr_TR.flushed.tsv")
        XCTAssertEqual(captured.count, 50 * 4, "50 keys in 4 layers")
        var checked = 0
        for (character, stroke) in SimulatorKeyboard.turkishQTable where character != "\n" && character != "\t" {
            let key = CapturedKey(usage: stroke.usage, layer: Self.layer(of: stroke.modifiers))
            if let clean = flushed[key] {
                // Typed with a trailing space: a plain key shows it, a dead
                // key swallows it.
                XCTAssertEqual(clean, "\(character) ", "\(character) \(stroke)")
            } else {
                XCTAssertEqual(captured[key], String(character), "\(character) \(stroke)")
            }
            checked += 1
        }
        XCTAssertEqual(checked, SimulatorKeyboard.turkishQTable.count - 2)
        // The dead key the table avoids: Shift+3 alone typed nothing, and
        // with a space it typed "^" (the table's ^ is Option+H).
        XCTAssertEqual(flushed[CapturedKey(usage: 0x20, layer: "shift")], "^")
        XCTAssertEqual(SimulatorKeyboardLayout.turkishQ.stroke(for: "^"), SimulatorKeyStroke(usage: 0x0B, modifiers: [SimulatorKeyboard.leftOption]))
    }

    /// The Turkish Q table covers printable ASCII except the backtick, and
    /// the Turkish letters.
    func testTheTurkishTableTypesASCIIAndTurkish() {
        for scalar in (0x20...0x7E).compactMap(Unicode.Scalar.init) where scalar != "`" {
            XCTAssertNotNil(SimulatorKeyboardLayout.turkishQ.stroke(for: Character(scalar)), "\(scalar)")
        }
        XCTAssertNil(SimulatorKeyboardLayout.turkishQ.stroke(for: "`"))
        for character in "çğıöşüÇĞİÖŞÜ" {
            XCTAssertNotNil(SimulatorKeyboardLayout.turkishQ.stroke(for: character), "\(character)")
        }
        // The dotted and dotless i sit on different keys than on U.S.
        XCTAssertEqual(SimulatorKeyboardLayout.turkishQ.stroke(for: "i"), SimulatorKeyStroke(usage: 0x34))
        XCTAssertEqual(SimulatorKeyboardLayout.turkishQ.stroke(for: "ı"), SimulatorKeyStroke(usage: 0x0C))
        XCTAssertEqual(SimulatorKeyboardLayout.turkishQ.stroke(for: "I"), SimulatorKeyStroke(usage: 0x0C, modifiers: [SimulatorKeyboard.leftShift]))
        XCTAssertEqual(SimulatorKeyboardLayout.turkishQ.stroke(for: "İ"), SimulatorKeyStroke(usage: 0x34, modifiers: [SimulatorKeyboard.leftShift]))
        XCTAssertEqual(SimulatorKeyboardLayout.turkishQ.stroke(for: "@"), SimulatorKeyStroke(usage: 0x14, modifiers: [SimulatorKeyboard.leftOption]))
    }

    /// Every U.S. entry is what that key typed on the simulator.
    func testTheUSTableIsTheCapturedLayout() throws {
        let captured = try capturedLayout("hid-keyboard-layout-en_US.tsv")
        XCTAssertEqual(captured.count, 50 * 4)
        for (character, stroke) in SimulatorKeyboard.usTable where character != "\n" && character != "\t" {
            let key = CapturedKey(usage: stroke.usage, layer: Self.layer(of: stroke.modifiers))
            XCTAssertEqual(captured[key], String(character), "\(character) \(stroke)")
        }
    }

    /// U.S.: printable ASCII, from the HID Usage Tables' key names.
    func testTheUSTableTypesPrintableASCII() {
        for scalar in (0x20...0x7E).compactMap(Unicode.Scalar.init) {
            XCTAssertNotNil(SimulatorKeyboardLayout.usQWERTY.stroke(for: Character(scalar)), "\(scalar)")
        }
        XCTAssertEqual(SimulatorKeyboard.usTable.count, 95 + 2, "printable ASCII, newline and tab")
        XCTAssertEqual(SimulatorKeyboardLayout.usQWERTY.stroke(for: "a"), SimulatorKeyStroke(usage: 0x04))
        XCTAssertEqual(SimulatorKeyboardLayout.usQWERTY.stroke(for: "Z"), SimulatorKeyStroke(usage: 0x1D, modifiers: [0xE1]))
        XCTAssertEqual(SimulatorKeyboardLayout.usQWERTY.stroke(for: "1"), SimulatorKeyStroke(usage: 0x1E))
        XCTAssertEqual(SimulatorKeyboardLayout.usQWERTY.stroke(for: "0"), SimulatorKeyStroke(usage: 0x27))
        XCTAssertEqual(SimulatorKeyboardLayout.usQWERTY.stroke(for: "!"), SimulatorKeyStroke(usage: 0x1E, modifiers: [0xE1]))
        XCTAssertEqual(SimulatorKeyboardLayout.usQWERTY.stroke(for: "\""), SimulatorKeyStroke(usage: 0x34, modifiers: [0xE1]))
        XCTAssertEqual(SimulatorKeyboardLayout.usQWERTY.stroke(for: "\n"), SimulatorKeyStroke(usage: 0x28))
        XCTAssertEqual(SimulatorKeyboardLayout.usQWERTY.stroke(for: " "), SimulatorKeyStroke(usage: 0x2C))
        XCTAssertNil(SimulatorKeyboardLayout.usQWERTY.stroke(for: "ş"))
    }

    func testAStrokeHoldsItsModifiersAroundTheKey() {
        let stroke = SimulatorKeyStroke(usage: 0x19, modifiers: [0xE3, 0xE1])
        XCTAssertEqual(stroke.events, [
            .key(usage: 0xE3, isDown: true),
            .key(usage: 0xE1, isDown: true),
            .key(usage: 0x19, isDown: true),
            .key(usage: 0x19, isDown: false),
            .key(usage: 0xE1, isDown: false),
            .key(usage: 0xE3, isDown: false),
        ])
        XCTAssertEqual(SimulatorKeyboard.pasteStroke, SimulatorKeyStroke(usage: 0x19, modifiers: [0xE3]))
    }

    func testSpecialKeys() {
        let expected: [UInt16: UInt32] = [
            36: 0x28, 76: 0x58, 48: 0x2B, 49: 0x2C, 51: 0x2A, 117: 0x4C, 53: 0x29,
            123: 0x50, 124: 0x4F, 125: 0x51, 126: 0x52, 115: 0x4A, 119: 0x4D, 116: 0x4B, 121: 0x4E,
        ]
        for (keyCode, usage) in expected {
            XCTAssertEqual(SimulatorKeyboard.usage(forMacKeyCode: keyCode), usage, "\(keyCode)")
        }
        XCTAssertNil(SimulatorKeyboard.usage(forMacKeyCode: 122), "F1 is not forwarded")
        XCTAssertNil(SimulatorKeyboard.usage(forMacKeyCode: 0), "letters come as text")
    }

    // MARK: - Text

    func testTextBecomesStrokesAndPastesInOrder() {
        let us = SimulatorKeyboard.steps(for: "Aş😀b\n", layout: .usQWERTY)
        XCTAssertEqual(us, [
            .stroke(SimulatorKeyStroke(usage: 0x04, modifiers: [0xE1])),
            .paste("ş😀"),
            .stroke(SimulatorKeyStroke(usage: 0x05)),
            .stroke(SimulatorKeyStroke(usage: 0x28)),
        ])
        let turkish = SimulatorKeyboard.steps(for: "ış 😀", layout: .turkishQ)
        XCTAssertEqual(turkish, [
            .stroke(SimulatorKeyStroke(usage: 0x0C)),
            .stroke(SimulatorKeyStroke(usage: 0x33)),
            .stroke(SimulatorKeyStroke(usage: 0x2C)),
            .paste("😀"),
        ])
    }

    /// Control characters other than newline and tab, and AppKit's
    /// function-key characters, are not text.
    func testNonTextCharactersAreDropped() {
        XCTAssertEqual(SimulatorKeyboard.steps(for: "\u{01}a\u{F704}\r\n", layout: .usQWERTY), [
            .stroke(SimulatorKeyStroke(usage: 0x04)),
            .stroke(SimulatorKeyStroke(usage: 0x28)),
        ])
        XCTAssertEqual(SimulatorKeyboard.steps(for: "\u{7F}", layout: .usQWERTY), [])
    }

    // MARK: - Which layout

    /// The captured preferences of a simulator on a `tr_TR` Mac: no
    /// `AppleKeyboards`, Turkish first, so Turkish Q (which typing proved).
    func testATurkishSimulatorTypesTurkishQ() throws {
        let data = try SimctlFixtureTests.data("bridge", "GlobalPreferences.tr_TR.plist")
        let preferences = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertNil(preferences["AppleKeyboards"])
        XCTAssertEqual(preferences["AppleLocale"] as? String, "tr_TR")
        XCTAssertEqual(SimulatorKeyboard.layout(globalPreferences: preferences), .turkishQ)
    }

    /// The same device switched to U.S. English types U.S.
    func testAUSEnglishSimulatorTypesUS() throws {
        let data = try SimctlFixtureTests.data("bridge", "GlobalPreferences.en_US.plist")
        let preferences = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertNil(preferences["AppleKeyboards"])
        XCTAssertEqual(preferences["AppleLanguages"] as? [String], ["en-US"])
        XCTAssertEqual(SimulatorKeyboard.layout(globalPreferences: preferences), .usQWERTY)
    }

    /// The decision rules on their own (inputs, not device output).
    func testLayoutRules() {
        XCTAssertEqual(SimulatorKeyboard.layout(globalPreferences: ["AppleLanguages": ["en-US"]]), .usQWERTY)
        XCTAssertEqual(SimulatorKeyboard.layout(globalPreferences: ["AppleLanguages": ["en"]]), .usQWERTY)
        XCTAssertNil(SimulatorKeyboard.layout(globalPreferences: ["AppleLanguages": ["en-GB"]]), "British has no table")
        XCTAssertNil(SimulatorKeyboard.layout(globalPreferences: ["AppleLanguages": ["de-DE"]]))
        XCTAssertNil(SimulatorKeyboard.layout(globalPreferences: [:]))
        XCTAssertEqual(SimulatorKeyboard.layout(globalPreferences: [
            "AppleKeyboards": ["tr_TR@sw=Turkish;hw=Automatic"], "AppleLanguages": ["en-US"],
        ]), .turkishQ, "the first keyboard beats the language")
        XCTAssertEqual(SimulatorKeyboard.layout(globalPreferences: [
            "AppleKeyboards": ["tr_TR@sw=Turkish;hw=Automatic", "en_US@sw=QWERTY;hw=U.S."],
        ]), .usQWERTY, "an explicit U.S. hardware layout wins")
        XCTAssertNil(SimulatorKeyboard.layout(globalPreferences: ["AppleKeyboards": ["tr_TR@sw=Turkish;hw=Turkish-F"]]),
                     "an explicit layout without a table")
    }

    func testThePreferencesLiveInTheDeviceDataFolder() {
        let set = URL(fileURLWithPath: "/tmp/set", isDirectory: true)
        XCTAssertEqual(
            SimulatorKeyboard.globalPreferencesURL(udid: "U", deviceSet: set).path,
            "/tmp/set/U/data/Library/Preferences/.GlobalPreferences.plist"
        )
        XCTAssertTrue(SimulatorKeyboard.globalPreferencesURL(udid: "U", deviceSet: nil).path
            .hasSuffix("Library/Developer/CoreSimulator/Devices/U/data/Library/Preferences/.GlobalPreferences.plist"))
    }
}
