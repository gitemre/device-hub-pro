import Foundation

/// A Mac key event forwarded as the same physical key: the phone's own hardware keyboard layout turns the key into a
/// character, so it has to equal the Mac's. Used only for a physical iPhone
/// with fast input active.
public enum PhysicalKeyEvent: Sendable, Equatable {
    /// A key went down or up. `modifiers` is the Mac's modifier set right
    /// now (`PhysicalKeyModifiers` bits).
    case key(code: UInt16, isDown: Bool, modifiers: UInt8)
    /// A modifier key changed (`flagsChanged`).
    case modifiers(UInt8)
    /// Every key is up (the stage lost the keyboard focus).
    case releaseAll
}

/// The Mac's modifier flags as a bitmask: bit n is the HID usage 0xE0 + n
/// (Control, Shift, Alt, GUI; left 0...3, right 4...7).
public enum PhysicalKeyModifiers {
    public static let leftCommand: UInt8 = 1 << 3
    public static let rightCommand: UInt8 = 1 << 7
    public static let command: UInt8 = leftCommand | rightCommand

    /// From `NSEvent.ModifierFlags.rawValue`: the device-dependent side bits
    /// tell left from right; a generic flag with no side bit counts as left.
    public static func mask(rawFlags raw: UInt) -> UInt8 {
        var mask: UInt8 = 0
        func add(generic: UInt, left: UInt, right: UInt, leftBit: UInt8, rightBit: UInt8) {
            guard raw & generic != 0 else { return }
            if raw & left != 0 { mask |= leftBit }
            if raw & right != 0 { mask |= rightBit }
            if raw & (left | right) == 0 { mask |= leftBit }
        }
        add(generic: 1 << 18, left: 0x1, right: 0x2000, leftBit: 1 << 0, rightBit: 1 << 4)   // Control
        add(generic: 1 << 17, left: 0x2, right: 0x4, leftBit: 1 << 1, rightBit: 1 << 5)      // Shift
        add(generic: 1 << 19, left: 0x20, right: 0x40, leftBit: 1 << 2, rightBit: 1 << 6)    // Option (Alt)
        add(generic: 1 << 20, left: 0x8, right: 0x10, leftBit: 1 << 3, rightBit: 1 << 7)     // Command (GUI)
        return mask
    }
}

/// Mac virtual key codes (kVK_*) to USB HID keyboard usages (page 0x07). The
/// position decides, not the character: ANSI, ISO (`kVK_ISO_Section` is the
/// Non-US backslash) and the JIS keys.
public enum MacKeyUsage {
    public static func usage(forKeyCode code: UInt16) -> Int? { table[code] }

    public static let capsLock: UInt16 = 57

    private static let table: [UInt16: Int] = [
        // Letters and digits by position (the US names).
        0: 0x04, 11: 0x05, 8: 0x06, 2: 0x07, 14: 0x08, 3: 0x09, 5: 0x0A, 4: 0x0B, 34: 0x0C, 38: 0x0D,
        40: 0x0E, 37: 0x0F, 46: 0x10, 45: 0x11, 31: 0x12, 35: 0x13, 12: 0x14, 15: 0x15, 1: 0x16, 17: 0x17,
        32: 0x18, 9: 0x19, 13: 0x1A, 7: 0x1B, 16: 0x1C, 6: 0x1D,
        18: 0x1E, 19: 0x1F, 20: 0x20, 21: 0x21, 23: 0x22, 22: 0x23, 26: 0x24, 28: 0x25, 25: 0x26, 29: 0x27,
        // Control keys and punctuation.
        36: 0x28, 53: 0x29, 51: 0x2A, 48: 0x2B, 49: 0x2C, 27: 0x2D, 24: 0x2E, 33: 0x2F, 30: 0x30, 42: 0x31,
        41: 0x33, 39: 0x34, 50: 0x35, 43: 0x36, 47: 0x37, 44: 0x38, 57: 0x39,
        10: 0x64,   // ISO section: Non-US backslash
        // Function keys.
        122: 0x3A, 120: 0x3B, 99: 0x3C, 118: 0x3D, 96: 0x3E, 97: 0x3F, 98: 0x40, 100: 0x41, 101: 0x42,
        109: 0x43, 103: 0x44, 111: 0x45, 105: 0x68, 107: 0x69, 113: 0x6A, 106: 0x6B, 64: 0x6C, 79: 0x6D,
        80: 0x6E, 90: 0x6F,
        // Navigation.
        114: 0x49, 115: 0x4A, 116: 0x4B, 117: 0x4C, 119: 0x4D, 121: 0x4E, 124: 0x4F, 123: 0x50, 125: 0x51, 126: 0x52,
        // Keypad.
        71: 0x53, 75: 0x54, 67: 0x55, 78: 0x56, 69: 0x57, 76: 0x58, 83: 0x59, 84: 0x5A, 85: 0x5B, 86: 0x5C,
        87: 0x5D, 88: 0x5E, 89: 0x5F, 91: 0x60, 92: 0x61, 82: 0x62, 65: 0x63, 81: 0x67, 95: 0x85,
        // JIS: Yen (International3), Underscore (International1), Eisu and Kana (Lang2, Lang1).
        93: 0x89, 94: 0x87, 102: 0x91, 104: 0x90,
        // Modifier keys (they arrive as flagsChanged; usable as a key too).
        59: 0xE0, 56: 0xE1, 58: 0xE2, 55: 0xE3, 62: 0xE4, 60: 0xE5, 61: 0xE6, 54: 0xE7,
    ]
}

/// What a real keyboard's reports say: the set of keys held now. Each report
/// is the usages held, modifiers (0xE0...0xE7) included.
public struct PhysicalKeyboardState: Sendable, Equatable {
    private(set) var modifiers: UInt8 = 0
    private(set) var held: [Int] = []
    /// Keys sent as a press and release at once (Command held: the Mac sends no
    /// key-up for them); their real key-up is ignored.
    private var tapped: Set<Int> = []

    public init() {}

    private var report: [Int] {
        (0..<8).filter { modifiers & (1 << $0) != 0 }.map { 0xE0 + $0 } + held
    }

    /// The reports, in order, that `event` makes; empty when nothing changes
    /// (an AppKit repeat, a key with no usage, an up for a key not held).
    public mutating func apply(_ event: PhysicalKeyEvent) -> [[Int]] {
        switch event {
        case .modifiers(let mask):
            guard mask != modifiers else { return [] }
            modifiers = mask
            return [report]
        case .releaseAll:
            guard !held.isEmpty || modifiers != 0 else { return [] }
            held = []
            modifiers = 0
            tapped = []
            return [[]]
        case .key(let code, let isDown, let mask):
            guard let usage = MacKeyUsage.usage(forKeyCode: code), !(0xE0...0xE7).contains(usage) else { return [] }
            var reports: [[Int]] = []
            if mask != modifiers {
                modifiers = mask
                if !held.isEmpty { reports.append(report) }
            }
            if !isDown {
                if tapped.remove(usage) != nil { return reports }
                guard let index = held.firstIndex(of: usage) else { return reports }
                held.remove(at: index)
                return reports + [report]
            }
            if held.contains(usage) { return reports }   // AppKit repeat: the phone repeats itself
            if mask & PhysicalKeyModifiers.command != 0 {
                tapped.insert(usage)
                return reports + [report + [usage], report]
            }
            held.append(usage)
            return reports + [report]
        }
    }
}
