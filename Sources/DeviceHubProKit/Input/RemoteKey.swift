import Foundation
import GRPCCore
import GRPCProtobuf

/// A button of a TV remote: the D-pad, Select, Back, Home, Play/Pause and
/// Menu. An Android TV is driven by these keys, not by touch (its profile is
/// `screen-type` notouch), so the stage offers them on a remote and maps
/// the Mac's arrows, Return and Escape to them.
public enum RemoteKey: Sendable, Hashable, CaseIterable {
    case up, down, left, right
    case select
    case back
    case home
    case playPause
    case menu

    /// Android's key code (SOURCE-DERIVED: AOSP
    /// `frameworks/base/core/java/android/view/KeyEvent.java`:
    /// `KEYCODE_DPAD_UP` 19, `_DOWN` 20, `_LEFT` 21, `_RIGHT` 22,
    /// `_CENTER` 23, `KEYCODE_BACK` 4, `KEYCODE_HOME` 3,
    /// `KEYCODE_MEDIA_PLAY_PAUSE` 85, `KEYCODE_MENU` 82).
    public var androidKeyCode: Int {
        switch self {
        case .up: return 19
        case .down: return 20
        case .left: return 21
        case .right: return 22
        case .select: return 23
        case .back: return 4
        case .home: return 3
        case .playPause: return 85
        case .menu: return 82
        }
    }

    /// The Linux input code the emulator's `KeyCodeType.Evdev` takes: `KEY_UP`
    /// 103, `KEY_LEFT` 105, `KEY_RIGHT` 106, `KEY_DOWN` 108, `KEY_ENTER` 28,
    /// `KEY_BACK` 158, `KEY_PLAYPAUSE` 164, `KEY_MENU` 139. Measured on the
    /// Google TV API 36 image (`Fixtures/api36-tv`, 2026-10-01): the emulator's
    /// keyboard device ("qwerty2") reports all of these and no `KEY_SELECT` /
    /// `KEY_OK`, the keys `Generic.kl` maps to `DPAD_CENTER` (353, 352), so
    /// Select is Enter here, which every TV view takes as a confirm. Home has
    /// none: `KEY_HOME` (102) is `MOVE_HOME` in `Generic.kl`, and
    /// `KEY_HOMEPAGE` (172, `HOME`) was sent over gRPC with Settings open and
    /// did not leave it, so Home goes through adb only (nil here). The adb
    /// path sends the real `DPAD_CENTER` for Select.
    public var evdevCode: Int32? {
        switch self {
        case .up: return 103
        case .down: return 108
        case .left: return 105
        case .right: return 106
        case .select: return 28
        case .back: return 158
        case .home: return nil
        case .playPause: return 164
        case .menu: return 139
        }
    }

    /// What a Mac key means on a TV: the arrows are the D-pad, Return and
    /// keypad Enter select, Escape and Delete go back. Every other key is
    /// left to the keyboard path (text, Tab).
    public init?(macKeyCode: UInt16) {
        switch macKeyCode {
        case 126: self = .up
        case 125: self = .down
        case 123: self = .left
        case 124: self = .right
        case 36, 76: self = .select
        case 53, 51: self = .back
        default: return nil
        }
    }

    /// The Apple TV remote's buttons, in the order the stage draws them:
    /// the D-pad, Select and Back (the remote's Menu button). Home and
    /// Play/Pause are not offered: no HID usage for them was seen to act on
    /// tvOS 27.0 (`AppleTVRemoteTests`).
    public static let appleTVKeys: [RemoteKey] = [.up, .down, .left, .right, .select, .back]

    /// The USB HID keyboard usage (page 7) a tvOS 27.0 simulator takes for
    /// the button, nil for one it is not offered. Measured 2026-10-01 on a
    /// private-set `Apple TV 4K (3rd generation)` running tvOS 27.0, through
    /// `SimulatorInputBridging`: Up / Down moved the focus, Return opened the
    /// focused item and Escape went back (the screen changed with each,
    /// compared by `simctl io screenshot`).
    public var appleTVKeyUsage: UInt32? {
        switch self {
        case .up: return 0x52
        case .down: return 0x51
        case .left: return 0x50
        case .right: return 0x4F
        case .select: return 0x28
        case .back: return 0x29
        case .home, .playPause, .menu: return nil
        }
    }

    /// A short name for the remote's accessibility labels and tooltips.
    public var title: String {
        switch self {
        case .up: return "Up"
        case .down: return "Down"
        case .left: return "Left"
        case .right: return "Right"
        case .select: return "Select"
        case .back: return "Back"
        case .home: return "Home"
        case .playPause: return "Play/Pause"
        case .menu: return "Menu"
        }
    }
}

/// Delivers a remote key to an Android device: the emulator's own key queue
/// when it has a keyboard device (the fastest path, one gRPC call per edge),
/// else `adb shell input keyevent`.
public enum RemoteKeys {
    /// One press (down, then up) through the emulator's gRPC `sendKey`
    /// (`KeyCodeType.Evdev`). Never retried on a stale connection: a rerun
    /// could press twice.
    public static func press(_ key: RemoteKey, port: Int) async throws {
        guard let code = key.evdevCode else { throw RemoteKeyError.needsAdb(key) }
        try await EmulatorControl.withSharedClient(port: port) { controller in
            for eventType in [
                Android_Emulation_Control_KeyboardEvent.KeyEventType.keydown,
                Android_Emulation_Control_KeyboardEvent.KeyEventType.keyup,
            ] {
                _ = try await controller.sendKey(
                    .with {
                        $0.codeType = .evdev
                        $0.eventType = eventType
                        $0.keyCode = code
                    },
                    options: .controls
                )
            }
        }
    }

    /// The adb arguments (after `shell`) of one press.
    public static func adbArguments(for key: RemoteKey) -> [String] {
        ["input", "keyevent", "\(key.androidKeyCode)"]
    }

    /// One press through `adb shell input keyevent` (a device without the
    /// emulator's keyboard, or a physical TV).
    public static func press(_ key: RemoteKey, adb: AdbClient, serial: String) async throws {
        _ = try await adb.shell(serial: serial, adbArguments(for: key))
    }
}

/// Why a remote key did not go through the emulator's keyboard.
public enum RemoteKeyError: Error, Equatable {
    /// The key has no evdev code on the emulator's keyboard (Home): send it
    /// through adb.
    case needsAdb(RemoteKey)
}
