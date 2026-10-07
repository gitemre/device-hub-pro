import Foundation

/// Finds the `avdmanager` and `sdkmanager` executables and a usable `java`
/// the same way other Android tooling resolves the SDK. Note that
/// `/usr/bin/java` exists on macOS even without a runtime installed, so
/// callers must probe Java by running it, not by checking for the file.
public enum AvdmanagerLocator {
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        locate(tool: "avdmanager", environment: environment)
    }

    /// Finds `sdkmanager` the same way `locate` finds `avdmanager`: an
    /// explicit `DHP_SDKMANAGER`, the SDK roots' cmdline-tools, then
    /// the PATH.
    public static func locateSdkmanager(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        locate(tool: "sdkmanager", environment: environment)
    }

    private static func locate(tool: String, environment: [String: String]) -> URL? {
        var candidates: [String] = []

        if let explicit = environment["DHP_\(tool.uppercased())"], !explicit.isEmpty {
            candidates.append(explicit)
        }

        for root in sdkRoots(environment: environment) {
            candidates.append(root + "/cmdline-tools/latest/bin/" + tool)
            candidates.append(contentsOf: revisionedCandidates(sdkRoot: root, tool: tool))
        }

        if let path = environment["PATH"] {
            for component in path.split(separator: ":") {
                candidates.append(String(component) + "/" + tool)
            }
        }

        let fileManager = FileManager.default
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    /// Candidate `java` executables, best first. Existence alone does not mean
    /// Java runs: probe with `java -version`.
    public static func javaCandidates(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var candidates: [String] = []

        if let home = environment["JAVA_HOME"], !home.isEmpty {
            candidates.append(home + "/bin/java")
        }
        // The runtime Device Hub Pro downloaded and Android Studio's bundled one come
        // before the `/usr/bin/java` stub (see `JavaRuntimeLocator`).
        candidates.append(contentsOf: JavaRuntimeLocator.candidates(environment: environment).map(\.path))
        candidates.append("/usr/bin/java")
        candidates.append("/opt/homebrew/opt/openjdk/bin/java")

        if let path = environment["PATH"] {
            for component in path.split(separator: ":") {
                candidates.append(String(component) + "/java")
            }
        }

        let fileManager = FileManager.default
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
            .filter { fileManager.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// The first Java that actually runs and is 17 or newer (what the Android
    /// command-line tools need), or nil when there is no such runtime.
    public static func workingJava(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        preferred: URL? = nil,
        probeTimeout: Duration = .seconds(30)
    ) async -> URL? {
        var candidates = javaCandidates(environment: environment)
        if let preferred {
            candidates.insert(preferred, at: 0)
        }
        for candidate in candidates {
            // A cancelled probe says nothing about the runtimes: callers check
            // `Task.isCancelled` before reading nil as "no Java".
            if Task.isCancelled { return nil }
            if await JavaRuntimeLocator.isUsable(candidate, timeout: probeTimeout) {
                return candidate
            }
        }
        return nil
    }

    /// The environment an SDK command-line tool needs to find Java: an
    /// existing `JAVA_HOME` is left alone (`[:]` means "inherit unchanged"),
    /// otherwise the working runtime's home is used. Nil when no runtime
    /// works.
    public static func javaHomeEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        preferred: URL? = nil
    ) async -> [String: String]? {
        if let home = environment["JAVA_HOME"], !home.isEmpty {
            return [:]
        }
        guard let java = await workingJava(environment: environment, preferred: preferred) else {
            return nil
        }
        return ["JAVA_HOME": java.deletingLastPathComponent().deletingLastPathComponent().path]
    }

    static func sdkRoots(environment: [String: String]) -> [String] {
        var roots: [String] = []
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = environment[key], !root.isEmpty {
                roots.append(root)
            }
        }
        roots.append(FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Android/sdk")

        if let adb = AdbBinaryLocator.locate(environment: environment) {
            roots.append(adb.deletingLastPathComponent().deletingLastPathComponent().path)
        }
        if let emulator = EmulatorManager.locateBinary(environment: environment) {
            roots.append(
                emulator.deletingLastPathComponent().deletingLastPathComponent().path
            )
        }

        var seen = Set<String>()
        return roots.filter { seen.insert($0).inserted }
    }

    /// `cmdline-tools/<revision>/bin/<tool>` for every installed revision.
    private static func revisionedCandidates(sdkRoot: String, tool: String) -> [String] {
        let tools = URL(fileURLWithPath: sdkRoot).appendingPathComponent(
            "cmdline-tools",
            isDirectory: true
        )
        let revisions = (try? FileManager.default.contentsOfDirectory(atPath: tools.path)) ?? []
        return revisions.sorted().map {
            tools.appendingPathComponent("\($0)/bin/\(tool)").path
        }
    }
}
