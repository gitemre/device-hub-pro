import Foundation

/// Locates the SDK's device-skin directory (`$SDK/skins`) the same way other
/// Android tooling resolves the SDK: explicit env roots first, then the
/// default install location, then the SDK implied by the resolved adb and
/// emulator binaries.
public enum SkinLocator {
    public static func skinsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        var candidates: [String] = []

        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = environment[key], !root.isEmpty {
                candidates.append(root + "/skins")
            }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates.append(home + "/Library/Android/sdk/skins")

        if let adb = AdbBinaryLocator.locate(environment: environment) {
            let sdkRoot = adb.deletingLastPathComponent().deletingLastPathComponent()
            candidates.append(sdkRoot.appendingPathComponent("skins").path)
        }

        if let emulator = EmulatorManager.locateBinary(environment: environment) {
            let sdkRoot = emulator.deletingLastPathComponent().deletingLastPathComponent()
            candidates.append(sdkRoot.appendingPathComponent("skins").path)
        }

        let fileManager = FileManager.default
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            guard
                fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                continue
            }
            return URL(fileURLWithPath: candidate, isDirectory: true)
        }
        return nil
    }
}
