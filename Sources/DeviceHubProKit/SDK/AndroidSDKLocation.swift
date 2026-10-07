import Foundation

/// Where the Android SDK lives on this Mac, and the one app-wide way a user's
/// choice of folder reaches every locator.
///
/// The locators (`AdbBinaryLocator`, `EmulatorManager`, `AvdmanagerLocator`,
/// `SkinLocator`) all read `ANDROID_HOME` / `ANDROID_SDK_ROOT` from the
/// process environment at the moment they look. A folder the user picked in
/// the app ("Locate SDK…") or the one the guided setup installed into is
/// therefore applied by putting it into that variable for this process (and
/// so for the adb server, sdkmanager and emulator children), unless the
/// launch environment already named an SDK: an explicit
/// `ANDROID_HOME` / `ANDROID_SDK_ROOT` always wins.
public enum AndroidSDKLocation {
    /// Android Studio's default SDK folder, which the guided install uses so
    /// Studio shares the result.
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Android/sdk", isDirectory: true)
    }

    /// What a folder the user picked turned out to be.
    public enum Validation: Equatable, Sendable {
        /// An SDK root with `platform-tools/adb`.
        case valid(root: URL)
        /// Not a folder.
        case notAFolder
        /// A folder without `platform-tools/adb`.
        case missingPlatformTools(folder: URL)
    }

    /// Accepts the SDK root itself or its `platform-tools` folder (the two
    /// things people pick); the adb inside must be executable.
    public static func validate(_ url: URL) -> Validation {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .notAFolder
        }
        if hasPlatformTools(at: url) { return .valid(root: url) }
        if url.lastPathComponent == "platform-tools",
           manager.isExecutableFile(atPath: url.appendingPathComponent("adb").path) {
            return .valid(root: url.deletingLastPathComponent())
        }
        return .missingPlatformTools(folder: url)
    }

    public static func hasPlatformTools(at root: URL) -> Bool {
        FileManager.default.isExecutableFile(
            atPath: root.appendingPathComponent("platform-tools/adb").path
        )
    }

    public static func hasCommandLineTools(at root: URL) -> Bool {
        FileManager.default.isExecutableFile(
            atPath: root.appendingPathComponent("cmdline-tools/latest/bin/sdkmanager").path
        )
    }

    public static func hasEmulator(at root: URL) -> Bool {
        FileManager.default.isExecutableFile(
            atPath: root.appendingPathComponent("emulator/emulator").path
        )
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var appliedValue: String?

    /// Makes `preferredRoot` (the saved "Locate SDK…" folder) the SDK of this
    /// process, unless the process was started with its own `ANDROID_HOME` /
    /// `ANDROID_SDK_ROOT`. Passing nil or a path that is no longer an SDK
    /// withdraws what an earlier call applied. Returns the root now in effect
    /// from the preference, nil when none.
    @discardableResult
    public static func applyPreferredRoot(_ preferredRoot: String?) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        let environment = ProcessInfo.processInfo.environment
        let current = environment["ANDROID_HOME"]
        // A value that is not the one this function set came from the launch
        // environment: leave it alone.
        let launchValue = (current?.isEmpty == false && current != appliedValue)
            || (environment["ANDROID_SDK_ROOT"]?.isEmpty == false)
        if launchValue { return nil }
        if let applied = appliedValue, current == applied {
            unsetenv("ANDROID_HOME")
            appliedValue = nil
        }
        guard let preferredRoot, !preferredRoot.isEmpty,
              case .valid(let root) = validate(URL(fileURLWithPath: preferredRoot, isDirectory: true))
        else { return nil }
        setenv("ANDROID_HOME", root.path, 1)
        appliedValue = root.path
        return root
    }
}
