import Foundation

/// Finds `aapt2` the same way `AvdmanagerLocator` finds `avdmanager`: an
/// explicit `DHP_AAPT2`, then the newest `build-tools/<revision>/aapt2`
/// under the SDK roots, then the PATH.
public enum ApkToolLocator {
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        var candidates: [String] = []

        if let explicit = environment["DHP_AAPT2"], !explicit.isEmpty {
            candidates.append(explicit)
        }

        candidates.append(
            contentsOf: buildToolCandidates(environment: environment)
                .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
                .map(\.path)
        )

        if let path = environment["PATH"] {
            for component in path.split(separator: ":") {
                candidates.append(String(component) + "/aapt2")
            }
        }

        let fileManager = FileManager.default
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    /// Every `<sdk root>/build-tools/<revision>/aapt2` across the SDK roots,
    /// keeping the revision for version ordering.
    private static func buildToolCandidates(
        environment: [String: String]
    ) -> [(version: String, path: String)] {
        var candidates: [(version: String, path: String)] = []
        for root in AvdmanagerLocator.sdkRoots(environment: environment) {
            let tools = URL(fileURLWithPath: root)
                .appendingPathComponent("build-tools", isDirectory: true)
            let revisions = (try? FileManager.default.contentsOfDirectory(atPath: tools.path)) ?? []
            for revision in revisions {
                candidates.append((
                    version: revision,
                    path: tools.appendingPathComponent("\(revision)/aapt2").path
                ))
            }
        }
        return candidates
    }
}
