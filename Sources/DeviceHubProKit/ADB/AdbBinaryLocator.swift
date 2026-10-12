import Foundation

/// Finds the `adb` executable the same way most Android tooling does.
public enum AdbBinaryLocator {
    /// Where Homebrew puts adb (Apple silicon, then Intel).
    static let fixedCandidates = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]

    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let candidates = candidates(
            environment: environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            fixed: fixedCandidates
        )
        let fileManager = FileManager.default
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    /// Where adb is looked for, best first: `DHP_ADB`, the SDK roots the
    /// environment names, the default SDK of `homeDirectory`, the PATH, then
    /// `fixed`. `locate` takes the first executable one; the problem report
    /// lists the others as the copies that could also run the adb server.
    static func candidates(
        environment: [String: String],
        homeDirectory: URL,
        fixed: [String]
    ) -> [String] {
        var candidates: [String] = []

        if let explicit = environment["DHP_ADB"], !explicit.isEmpty {
            candidates.append(explicit)
        }

        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = environment[key], !root.isEmpty {
                candidates.append(root + "/platform-tools/adb")
            }
        }

        candidates.append(homeDirectory.path + "/Library/Android/sdk/platform-tools/adb")

        if let path = environment["PATH"] {
            for component in path.split(separator: ":") {
                candidates.append(String(component) + "/adb")
            }
        }

        candidates.append(contentsOf: fixed)
        return candidates
    }
}
