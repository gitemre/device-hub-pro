import XCTest
@testable import DeviceHubProKit

/// Mac keys as physical keys: the key-code to HID
/// usage table, the modifier mask and the held-set reports.
final class PhysicalKeyboardTests: XCTestCase {
    func testTheTableMapsKeysByPosition() {
        let expected: [(UInt16, Int)] = [
            (0, 0x04), (11, 0x05), (6, 0x1D),            // A B Z
            (18, 0x1E), (29, 0x27),                      // 1 0
            (36, 0x28), (53, 0x29), (51, 0x2A), (48, 0x2B), (49, 0x2C),
            (27, 0x2D), (24, 0x2E), (33, 0x2F), (30, 0x30), (42, 0x31), (41, 0x33), (39, 0x34), (50, 0x35),
            (43, 0x36), (47, 0x37), (44, 0x38),
            (10, 0x64),                                  // ISO section: Non-US backslash
            (122, 0x3A), (111, 0x45), (105, 0x68),       // F1 F12 F13
            (123, 0x50), (124, 0x4F), (125, 0x51), (126, 0x52),
            (117, 0x4C), (115, 0x4A), (119, 0x4D), (116, 0x4B), (121, 0x4E),
            (82, 0x62), (83, 0x59), (76, 0x58),          // keypad 0 1 Enter
            (93, 0x89), (102, 0x91), (104, 0x90),        // JIS Yen, Eisu, Kana
            (59, 0xE0), (56, 0xE1), (58, 0xE2), (55, 0xE3), (62, 0xE4), (60, 0xE5), (61, 0xE6), (54, 0xE7),
        ]
        for (code, usage) in expected {
            XCTAssertEqual(MacKeyUsage.usage(forKeyCode: code), usage, "key code \(code)")
        }
        XCTAssertNil(MacKeyUsage.usage(forKeyCode: 63), "Fn has no usage")
        XCTAssertNil(MacKeyUsage.usage(forKeyCode: 200))
    }

    func testEveryUsageIsAValidKeyboardUsageAndNoneIsUsedTwice() {
        var seen: [Int: UInt16] = [:]
        for code in UInt16(0)...200 {
            guard let usage = MacKeyUsage.usage(forKeyCode: code) else { continue }
            XCTAssertTrue((1...0xE7).contains(usage), "key code \(code)")
            XCTAssertNil(seen[usage], "usage \(usage) for \(code) and \(seen[usage] ?? 0)")
            seen[usage] = code
        }
    }

    func testTheModifierMaskReadsTheSideBitsAndDefaultsToLeft() {
        let shift: UInt = 1 << 17, control: UInt = 1 << 18, option: UInt = 1 << 19, command: UInt = 1 << 20
        XCTAssertEqual(PhysicalKeyModifiers.mask(rawFlags: 0), 0)
        XCTAssertEqual(PhysicalKeyModifiers.mask(rawFlags: shift | 0x2), 1 << 1)
        XCTAssertEqual(PhysicalKeyModifiers.mask(rawFlags: shift | 0x4), 1 << 5)
        XCTAssertEqual(PhysicalKeyModifiers.mask(rawFlags: control | 0x2000), 1 << 4)
        XCTAssertEqual(PhysicalKeyModifiers.mask(rawFlags: option | 0x40), 1 << 6)
        XCTAssertEqual(PhysicalKeyModifiers.mask(rawFlags: command | 0x10), 1 << 7)
        XCTAssertEqual(PhysicalKeyModifiers.mask(rawFlags: command), 1 << 3, "a generic flag without a side bit is the left key")
        XCTAssertEqual(PhysicalKeyModifiers.mask(rawFlags: shift | 0x2 | 0x4), (1 << 1) | (1 << 5), "both sides")
    }

    func testAKeyIsDownThenUpAsTheHeldSet() {
        var state = PhysicalKeyboardState()
        XCTAssertEqual(state.apply(.key(code: 34, isDown: true, modifiers: 0)), [[0x0C]])
        XCTAssertEqual(state.apply(.key(code: 0, isDown: true, modifiers: 0)), [[0x0C, 0x04]], "rollover: both held")
        XCTAssertEqual(state.apply(.key(code: 34, isDown: false, modifiers: 0)), [[0x04]])
        XCTAssertEqual(state.apply(.key(code: 0, isDown: false, modifiers: 0)), [[]])
    }

    func testModifiersAreInEveryReport() {
        var state = PhysicalKeyboardState()
        XCTAssertEqual(state.apply(.modifiers(1 << 1)), [[0xE1]])
        XCTAssertEqual(state.apply(.key(code: 34, isDown: true, modifiers: 1 << 1)), [[0xE1, 0x0C]])
        XCTAssertEqual(state.apply(.modifiers(1 << 1 | 1 << 6)), [[0xE1, 0xE6, 0x0C]], "Option (right) joins")
        XCTAssertEqual(state.apply(.modifiers(0)), [[0x0C]], "modifiers up, the key still held")
        XCTAssertEqual(state.apply(.modifiers(0)), [], "nothing changed")
    }

    func testAnAppKitRepeatAndUnknownKeysAreIgnored() {
        var state = PhysicalKeyboardState()
        _ = state.apply(.key(code: 0, isDown: true, modifiers: 0))
        XCTAssertEqual(state.apply(.key(code: 0, isDown: true, modifiers: 0)), [], "the phone repeats itself")
        XCTAssertEqual(state.apply(.key(code: 63, isDown: true, modifiers: 0)), [], "Fn has no usage")
        XCTAssertEqual(state.apply(.key(code: 11, isDown: false, modifiers: 0)), [], "an up for a key not held")
    }

    func testACommandKeyIsPressedAndReleasedAtOnceBecauseTheMacSendsNoKeyUp() {
        var state = PhysicalKeyboardState()
        let command = PhysicalKeyModifiers.leftCommand
        XCTAssertEqual(state.apply(.modifiers(command)), [[0xE3]])
        XCTAssertEqual(state.apply(.key(code: 0, isDown: true, modifiers: command)), [[0xE3, 0x04], [0xE3]], "Command+A")
        XCTAssertEqual(state.apply(.key(code: 0, isDown: false, modifiers: command)), [], "a key-up that does arrive is ignored")
        XCTAssertEqual(state.apply(.modifiers(0)), [[]])
    }

    func testReleaseAllLetsGoOfEverythingOnce() {
        var state = PhysicalKeyboardState()
        _ = state.apply(.modifiers(1))
        _ = state.apply(.key(code: 0, isDown: true, modifiers: 1))
        XCTAssertEqual(state.apply(.releaseAll), [[]])
        XCTAssertEqual(state.apply(.releaseAll), [])
    }
}
