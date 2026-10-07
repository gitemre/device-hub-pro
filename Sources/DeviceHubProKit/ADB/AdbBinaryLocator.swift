import Foundation

/// Finds the `adb` executable the same way most Android tooling does.
public enum AdbBinaryLocator {
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        var candidates: [String] = []

        if let explicit = environment["DHP_ADB"], !explicit.isEmpty {
            candidates.append(explicit)
        }

        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = environment[key], !root.isEmpty {
                candidates.append(root + "/platform-tools/adb")
            }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates.append(home + "/Library/Android/sdk/platform-tools/adb")

        if let path = environment["PATH"] {
            for component in path.split(separator: ":") {
                candidates.append(String(component) + "/adb")
            }
        }

        candidates.append("/opt/homebrew/bin/adb")
        candidates.append("/usr/local/bin/adb")

        let fileManager = FileManager.default
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }
}
