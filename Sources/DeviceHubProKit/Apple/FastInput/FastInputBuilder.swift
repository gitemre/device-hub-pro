import CryptoKit
import Foundation

/// A built helper on disk.
public struct FastInputBuild: Sendable, Equatable {
    public let helperURL: URL
    /// The build ran just now.
    public let wasBuilt: Bool

    public init(helperURL: URL, wasBuilt: Bool) {
        self.helperURL = helperURL
        self.wasBuilt = wasBuilt
    }
}

/// Builds and caches `fastinput-helper` from the `fastinput/` sources.
///
/// The steps are `fastinput/build.sh`'s, done in a cache folder so the
/// sources (which may sit in a read-only app bundle) are never written to:
/// copy the sources, run the script with an output folder. The cache is
/// `<cache>/`, with a stamp naming a digest of the sources and the Xcode build:
/// any change rebuilds, nothing else does. No signing is involved (the helper
/// is ad-hoc signed by the linker and runs on the Mac only).
public struct FastInputBuilder: Sendable {
    public static let helperName = "fastinput-helper"

    public let sourcesDirectory: URL
    public let cacheDirectory: URL
    public let developerDirectory: URL?
    public let xcodeBuild: String?
    public let buildTimeout: Duration
    /// Runs `bash <script> <output>`; tests hand in a fake.
    let runScript: @Sendable (_ script: URL, _ output: URL, _ environment: [String: String]) async throws -> ProcessResult

    public init(
        sourcesDirectory: URL,
        cacheDirectory: URL = FastInputBuilder.defaultCacheDirectory,
        developerDirectory: URL?,
        xcodeBuild: String?,
        buildTimeout: Duration = .seconds(600)
    ) {
        self.init(
            sourcesDirectory: sourcesDirectory,
            cacheDirectory: cacheDirectory,
            developerDirectory: developerDirectory,
            xcodeBuild: xcodeBuild,
            buildTimeout: buildTimeout,
            runScript: { script, output, environment in
                try await ProcessRunner.run(
                    executable: URL(fileURLWithPath: "/bin/bash"),
                    arguments: [script.path, output.path],
                    environment: environment,
                    timeout: buildTimeout
                )
            }
        )
    }

    init(
        sourcesDirectory: URL,
        cacheDirectory: URL,
        developerDirectory: URL?,
        xcodeBuild: String?,
        buildTimeout: Duration,
        runScript: @escaping @Sendable (URL, URL, [String: String]) async throws -> ProcessResult
    ) {
        self.sourcesDirectory = sourcesDirectory
        self.cacheDirectory = cacheDirectory
        self.developerDirectory = developerDirectory
        self.xcodeBuild = xcodeBuild
        self.buildTimeout = buildTimeout
        self.runScript = runScript
    }

    /// `~/Library/Caches/DeviceHubPro/fastinput`.
    public static var defaultCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeviceHubPro/fastinput", isDirectory: true)
    }

    // MARK: Finding the sources

    /// `fastinput/`: `DHP_FAST_INPUT_DIR`, else a bundled `fastinput`
    /// resource folder, else the checkout the running executable was built in
    /// (the nearest ancestor with `fastinput/build.sh`). nil when none exists.
    public static func locateSources(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resourceURL: URL? = Bundle.main.resourceURL,
        executableURL: URL? = Bundle.main.executableURL
    ) -> URL? {
        let fileManager = FileManager.default
        func valid(_ url: URL) -> Bool {
            fileManager.fileExists(atPath: url.appendingPathComponent("build.sh").path)
        }
        if let override = environment["DHP_FAST_INPUT_DIR"], !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            return valid(url) ? url : nil
        }
        if let resourceURL {
            let bundled = resourceURL.appendingPathComponent("fastinput", isDirectory: true)
            if valid(bundled) { return bundled }
        }
        var directory = executableURL?.deletingLastPathComponent()
        for _ in 0..<8 {
            guard let current = directory else { break }
            let candidate = current.appendingPathComponent("fastinput", isDirectory: true)
            if valid(candidate) { return candidate }
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            directory = parent
        }
        return nil
    }

    // MARK: Digests

    /// A digest of the files the helper is built from: `build.sh` and
    /// everything under `Sources` (paths and bytes, in path order).
    static func sourcesDigest(of directory: URL) throws -> String {
        let fileManager = FileManager.default
        let root = directory.standardizedFileURL.path
        var files: [(relative: String, url: URL)] = []
        if let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in enumerator {
                let relative = String(url.standardizedFileURL.path.dropFirst(root.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard relative == "build.sh" || relative.hasPrefix("Sources/") else { continue }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                if relative.hasSuffix(".DS_Store") { continue }
                files.append((relative, url))
            }
        }
        guard files.contains(where: { $0.relative == "build.sh" }) else { throw FastInputError.sourcesMissing }
        var hasher = SHA256()
        for file in files.sorted(by: { $0.relative < $1.relative }) {
            hasher.update(data: Data(file.relative.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: try Data(contentsOf: file.url))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The stamp's value: digests only.
    static func stamp(sourcesDigest: String, xcodeBuild: String?) -> String {
        var hasher = SHA256()
        for part in [sourcesDigest, xcodeBuild ?? "-"] {
            hasher.update(data: Data(part.utf8))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Build

    public func ensureHelper(progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> FastInputBuild {
        let fileManager = FileManager.default
        let digest = try Self.sourcesDigest(of: sourcesDirectory)
        let stamp = Self.stamp(sourcesDigest: digest, xcodeBuild: xcodeBuild)
        let stampURL = cacheDirectory.appendingPathComponent("stamp")
        let outputDirectory = cacheDirectory.appendingPathComponent("bin", isDirectory: true)
        let helper = outputDirectory.appendingPathComponent(Self.helperName)

        if let recorded = try? String(contentsOf: stampURL, encoding: .utf8), recorded == stamp,
           fileManager.isExecutableFile(atPath: helper.path) {
            return FastInputBuild(helperURL: helper, wasBuilt: false)
        }

        progress("Building the fast input helper (first time only)…")
        try? fileManager.removeItem(at: cacheDirectory)
        let sources = cacheDirectory.appendingPathComponent("src", isDirectory: true)
        do {
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: sources, withIntermediateDirectories: true)
            try fileManager.copyItem(at: sourcesDirectory.appendingPathComponent("build.sh"), to: sources.appendingPathComponent("build.sh"))
            try fileManager.copyItem(at: sourcesDirectory.appendingPathComponent("Sources"), to: sources.appendingPathComponent("Sources"))
        } catch {
            throw FastInputError.buildFailed("the helper's sources could not be copied")
        }
        let environment = developerDirectory.map { ["DEVELOPER_DIR": $0.path] } ?? [:]
        let result: ProcessResult
        do {
            result = try await runScript(sources.appendingPathComponent("build.sh"), outputDirectory, environment)
        } catch {
            throw FastInputError.buildFailed("the build did not finish")
        }
        guard result.exitCode == 0, fileManager.isExecutableFile(atPath: helper.path) else {
            throw FastInputError.buildFailed(Self.summary(ofBuildOutput: result.standardOutputText + result.standardErrorText))
        }
        try? stamp.write(to: stampURL, atomically: true, encoding: .utf8)
        return FastInputBuild(helperURL: helper, wasBuilt: true)
    }

    /// The build's `error:` lines (at most three), else its tail.
    static func summary(ofBuildOutput output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        let errors = lines.filter { $0.contains("error:") }.prefix(3)
        let picked = errors.isEmpty ? lines.suffix(6).joined(separator: "\n") : errors.joined(separator: "\n")
        return picked.count > 500 ? "…" + picked.suffix(500) : picked
    }
}
