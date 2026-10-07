import Foundation

/// Finds a Java runtime the Android command-line tools can use (they need
/// Java 17 or newer), and knows where the app keeps a runtime it downloaded
/// itself. `/usr/bin/java` exists on every Mac even without a runtime, so a
/// candidate counts only when `java -version` runs and reports a new enough
/// version.
public enum JavaRuntimeLocator {
    /// The oldest Java the current command-line tools run on.
    public static let minimumMajorVersion = 17

    /// Where a runtime downloaded by Device Hub Pro lives.
    public static var managedDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DeviceHubPro/jdk", isDirectory: true)
    }

    /// `<directory>/<jdk folder>/Contents/Home/bin/java` of a runtime unpacked
    /// by the installer, the newest folder first; nil when there is none.
    public static func managedJava(in directory: URL = managedDirectory) -> URL? {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        for folder in folders.sorted(by: >) where !folder.hasPrefix(".") {
            let java = directory.appendingPathComponent("\(folder)/Contents/Home/bin/java")
            if manager.isExecutableFile(atPath: java.path) { return java }
        }
        return nil
    }

    /// `java` executables worth probing, best first: the runtime the app
    /// downloaded, `JAVA_HOME`, Android Studio's bundled JetBrains runtime
    /// (every `Android Studio*.app` in /Applications and ~/Applications),
    /// the one `/usr/libexec/java_home` names, Homebrew's OpenJDK.
    public static func candidates(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        managedDirectory: URL = JavaRuntimeLocator.managedDirectory,
        applicationDirectories: [URL] = defaultApplicationDirectories,
        javaHome: () -> String? = { systemJavaHome() }
    ) -> [URL] {
        var paths: [String] = []
        if let managed = managedJava(in: managedDirectory) { paths.append(managed.path) }
        if let home = environment["JAVA_HOME"], !home.isEmpty { paths.append(home + "/bin/java") }
        paths.append(contentsOf: studioRuntimes(in: applicationDirectories))
        if let home = javaHome() { paths.append(home + "/bin/java") }
        paths.append("/opt/homebrew/opt/openjdk/bin/java")
        paths.append("/usr/local/opt/openjdk/bin/java")
        var seen = Set<String>()
        return paths
            .filter { seen.insert($0).inserted }
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    public static var defaultApplicationDirectories: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    /// `<app>/Contents/jbr/Contents/Home/bin/java` of each Android Studio app
    /// (`Android Studio.app`, `Android Studio Preview.app`, ...).
    public static func studioRuntimes(in directories: [URL]) -> [String] {
        let manager = FileManager.default
        var result: [String] = []
        for directory in directories {
            let apps = ((try? manager.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
            for app in apps where app.hasPrefix("Android Studio") && app.hasSuffix(".app") {
                result.append(directory.appendingPathComponent(app)
                    .appendingPathComponent("Contents/jbr/Contents/Home/bin/java").path)
            }
        }
        return result
    }

    /// `/usr/libexec/java_home`'s answer, nil when it reports no runtime (it
    /// exits non-zero then; on a Mac without Java it never opens a dialog).
    public static func systemJavaHome() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
        process.arguments = ["-v", "\(minimumMajorVersion)+"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The first candidate that runs and is Java 17 or newer.
    public static func workingJava(
        candidates: [URL] = JavaRuntimeLocator.candidates()
    ) async -> URL? {
        for candidate in candidates where await isUsable(candidate, timeout: .seconds(20)) {
            return candidate
        }
        return nil
    }

    /// Whether `java` runs and reports Java 17 or newer (`java -version`
    /// prints to stderr). The one test both locators share, so an old JDK is
    /// never taken for a working runtime.
    public static func isUsable(_ java: URL, timeout: Duration) async -> Bool {
        guard let result = try? await ProcessRunner.run(
            executable: java,
            arguments: ["-version"],
            timeout: timeout
        ), result.exitCode == 0 else { return false }
        let text = result.standardErrorText + result.standardOutputText
        guard let major = majorVersion(fromVersionOutput: text) else { return false }
        return major >= minimumMajorVersion
    }

    /// The major version out of `java -version`'s first quoted version:
    /// `"21.0.12"` is 21, `"1.8.0_392"` is 8.
    public static func majorVersion(fromVersionOutput output: String) -> Int? {
        guard let open = output.firstIndex(of: "\"") else { return nil }
        let rest = output[output.index(after: open)...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        let parts = rest[..<close].split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" || $0 == "+" })
        guard let first = parts.first.flatMap({ Int($0) }) else { return nil }
        if first == 1, parts.count > 1, let second = Int(parts[1]) { return second }
        return first
    }
}

/// One Temurin runtime archive Adoptium's API lists.
public struct AdoptiumRelease: Equatable, Sendable {
    public let name: String
    public let downloadURL: URL
    public let sha256: String
    public let size: Int64
    public let version: String

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case unusable

        public var description: String { "Adoptium's download listing could not be read." }
    }

    /// The latest-release API for Temurin `major` on a Mac of `arch`
    /// (`aarch64` or `x64`): the runtime only (`jre`), which is all sdkmanager
    /// and avdmanager need.
    public static func listingURL(major: Int, arch: String) -> URL {
        URL(string: "https://api.adoptium.net/v3/assets/latest/\(major)/hotspot"
            + "?architecture=\(arch)&image_type=jre&os=mac&vendor=eclipse")!
    }

    /// The first release whose `binary.package` is a `.tar.gz` with a link and
    /// a sha256.
    public static func parse(_ data: Data) throws -> AdoptiumRelease {
        guard let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ParseError.unusable
        }
        for release in releases {
            guard let binary = release["binary"] as? [String: Any],
                  let package = binary["package"] as? [String: Any],
                  let name = package["name"] as? String, name.hasSuffix(".tar.gz"),
                  let link = (package["link"] as? String).flatMap(URL.init(string:)),
                  link.scheme == "https",
                  let checksum = package["checksum"] as? String, checksum.count == 64
            else { continue }
            let version = (release["version"] as? [String: Any])?["openjdk_version"] as? String ?? ""
            return AdoptiumRelease(
                name: name,
                downloadURL: link,
                sha256: checksum,
                size: (package["size"] as? NSNumber)?.int64Value ?? 0,
                version: version
            )
        }
        throw ParseError.unusable
    }
}
