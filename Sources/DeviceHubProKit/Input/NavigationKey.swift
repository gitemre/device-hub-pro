import Foundation
import GRPCCore
import GRPCProtobuf

/// One of Android's three navigation keys, the ones the stage's navigation
/// bar presses under the device: Back, Home and Recents (overview).
public enum NavigationKey: Sendable, Hashable, CaseIterable {
    case back
    case home
    case recents

    /// Android's key code (SOURCE-DERIVED: `KEYCODE_BACK` 4, `KEYCODE_HOME` 3,
    /// `KEYCODE_APP_SWITCH` 187 in AOSP
    /// `frameworks/base/core/java/android/view/KeyEvent.java`).
    public var androidKeyCode: Int {
        switch self {
        case .back: return 4
        case .home: return 3
        case .recents: return 187
        }
    }

    /// The W3C key name the emulator's `sendKey` takes in `key`. Established
    /// live (2026-10-01, emulator API 35): the raw evdev codes `KEY_BACK`,
    /// `KEY_HOMEPAGE` and `KEY_APPSELECT` do not reach the guest, these
    /// names do.
    public var w3cKey: String {
        switch self {
        case .back: return "GoBack"
        case .home: return "GoHome"
        case .recents: return "AppSwitch"
        }
    }

    /// The `adb shell input keyevent` argv (the slow path every device has).
    public func adbArguments(serial: String) -> [String] {
        ["-s", serial, "shell", "input", "keyevent", "\(androidKeyCode)"]
    }

    /// The emulator's `sendKey` request: one press and release.
    static func keyboardEvent(for key: NavigationKey) -> Android_Emulation_Control_KeyboardEvent {
        .with {
            $0.eventType = .keypress
            $0.key = key.w3cKey
        }
    }
}

/// The stage navigation bar's key press on an emulator: one `sendKey` on the
/// emulator's shared gRPC connection (no adb process, no device-side JVM).
public enum EmulatorNavigationKeys {
    public static func press(_ key: NavigationKey, port: Int) async throws {
        let request = NavigationKey.keyboardEvent(for: key)
        _ = try await EmulatorControl.withSharedClient(port: port) { controller in
            try await controller.sendKey(request, options: .controls)
        }
    }
}

/// Which devices get the stage's navigation bar.
public enum NavigationBarRules {
    /// Handhelds (phones, tablets, foldables) only: Wear OS, TV, Automotive,
    /// desktop and XR images have their own navigation. An unclassified (not
    /// read yet) device is handheld, as everywhere else.
    public static func appliesTo(_ formFactor: SystemImage.FormFactor?) -> Bool {
        (formFactor ?? .handheld) == .handheld
    }
}
