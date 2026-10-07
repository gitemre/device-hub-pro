import CryptoKit
import Foundation

/// The phone a runner is built and started for. Only the session and the
/// builder see the UDID; it is never logged or kept.
public struct PhysicalControlTarget: Sendable, Equatable {
    public let hardwareUDID: String
    /// "iPhone13,2": names the cache folder.
    public let productType: String?

    public init(hardwareUDID: String, productType: String?) {
        self.hardwareUDID = hardwareUDID
        self.productType = productType
    }
}

/// A signed runner build on disk.
public struct PhysicalControlBuild: Sendable, Equatable {
    /// The `.xctestrun` `xcodebuild test-without-building` is given.
    public let xctestrunURL: URL
    /// The build ran just now (the first start then also installs the runner
    /// and its host app on the phone, which takes about a minute).
    public let wasBuilt: Bool

    public init(xctestrunURL: URL, wasBuilt: Bool) {
        self.xctestrunURL = xctestrunURL
        self.wasBuilt = wasBuilt
    }
}

/// Makes sure a signed runner exists. The real one is
/// `PhysicalControlRunnerBuilder`; tests hand in a fake, so no test starts
/// `xcodebuild`.
public protocol PhysicalControlProvisioning: Sendable {
    /// The runner's `.xctestrun`, built when it is missing or stale.
    /// `progress` gets short human-readable steps.
    func ensureRunner(
        for target: PhysicalControlTarget,
        team: String,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> PhysicalControlBuild
}

/// Builds and caches the signed runner of `ios/agent`.
///
/// The steps are `ios/agent/build.sh`'s, done in a cache folder so the
/// sources (which may sit in a read-only app bundle) are never written to:
/// copy the sources, `gen_project.py`, `xcodebuild build-for-testing` with the
/// team on the command line and automatic signing. No
/// `-allowProvisioningUpdates`: it never contacts Apple and never asks for a
/// credential; a phone the development profile does not cover fails the build
/// with the build's own message.
///
/// The cache is `<cache>/<product type>/`, with a stamp naming a digest of the
/// runner's sources, the team, the phone and the Xcode build: any change
/// rebuilds, nothing else does. The stamp keeps digests only, never the
/// team or the UDID.
public struct PhysicalControlRunnerBuilder: PhysicalControlProvisioning {
    public let sourcesDirectory: URL
    public let cacheDirectory: URL
    public let developerDirectory: URL?
    public let xcodeBuild: String?
    public let buildTimeout: Duration

    public init(
        sourcesDirectory: URL,
        cacheDirectory: URL = PhysicalControlRunnerBuilder.defaultCacheDirectory,
        developerDirectory: URL?,
        xcodeBuild: String?,
        buildTimeout: Duration = .seconds(900)
    ) {
        self.sourcesDirectory = sourcesDirectory
        self.cacheDirectory = cacheDirectory
        self.developerDirectory = developerDirectory
        self.xcodeBuild = xcodeBuild
        self.buildTimeout = buildTimeout
    }

    /// `~/Library/Caches/DeviceHubPro/agent`.
    public static var defaultCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeviceHubPro/agent", isDirectory: true)
    }

    // MARK: Finding the sources

    /// `ios/agent`: `DHP_IOS_AGENT_DIR`, else a bundled `ios-agent`
    /// resource folder, else the checkout the running executable was built
    /// in (the nearest ancestor with `ios/agent/gen_project.py`). nil when
    /// none exists.
    public static func locateSources(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resourceURL: URL? = Bundle.main.resourceURL,
        executableURL: URL? = Bundle.main.executableURL
    ) -> URL? {
        let fileManager = FileManager.default
        func valid(_ url: URL) -> Bool {
            fileManager.fileExists(atPath: url.appendingPathComponent("gen_project.py").path)
        }
        if let override = environment["DHP_IOS_AGENT_DIR"], !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            return valid(url) ? url : nil
        }
        if let resourceURL {
            let bundled = resourceURL.appendingPathComponent("ios-agent", isDirectory: true)
            if valid(bundled) { return bundled }
        }
        var directory = executableURL?.deletingLastPathComponent()
        for _ in 0..<8 {
            guard let current = directory else { break }
            let candidate = current.appendingPathComponent("ios/agent", isDirectory: true)
            if valid(candidate) { return candidate }
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            directory = parent
        }
        return nil
    }

    // MARK: Digests

    /// A digest of the files the runner is built from: `gen_project.py`, the
    /// host app and the tests (paths and bytes, in path order). The
    /// generated project, the Python client and the notes are not inputs.
    static func sourcesDigest(of directory: URL) throws -> String {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw PhysicalControlError.runnerSourcesMissing
        }
        var files: [(relative: String, url: URL)] = []
        let root = directory.standardizedFileURL.path
        for case let url as URL in enumerator {
            let standard = url.standardizedFileURL.path
            let relative = String(standard.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if relative.hasPrefix("DeviceHubProAgent.xcodeproj") || relative.hasPrefix("client") { continue }
            if relative.hasSuffix(".md") || relative.hasSuffix(".DS_Store") { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            files.append((relative, url))
        }
        guard files.contains(where: { $0.relative == "gen_project.py" }) else {
            throw PhysicalControlError.runnerSourcesMissing
        }
        var hasher = SHA256()
        for file in files.sorted(by: { $0.relative < $1.relative }) {
            hasher.update(data: Data(file.relative.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: try Data(contentsOf: file.url))
            hasher.update(data: Data([0]))
        }
        return hex(hasher.finalize())
    }

    /// The stamp's value: digests only.
    static func stamp(sourcesDigest: String, team: String, hardwareUDID: String, xcodeBuild: String?) -> String {
        var hasher = SHA256()
        for part in [sourcesDigest, team, hardwareUDID.uppercased(), xcodeBuild ?? "-"] {
            hasher.update(data: Data(part.utf8))
            hasher.update(data: Data([0]))
        }
        return hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// A folder name for a product type: letters, digits and commas only.
    static func folderName(productType: String?) -> String {
        let cleaned = (productType ?? "device").filter { $0.isLetter || $0.isNumber || $0 == "," }
        return cleaned.isEmpty ? "device" : cleaned
    }

    // MARK: Build

    public func ensureRunner(
        for target: PhysicalControlTarget,
        team: String,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> PhysicalControlBuild {
        let team = team.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !team.isEmpty else { throw PhysicalControlError.noTeam }
        let fileManager = FileManager.default
        let digest = try Self.sourcesDigest(of: sourcesDirectory)
        let stamp = Self.stamp(sourcesDigest: digest, team: team, hardwareUDID: target.hardwareUDID, xcodeBuild: xcodeBuild)
        let folder = cacheDirectory.appendingPathComponent(Self.folderName(productType: target.productType), isDirectory: true)
        let stampURL = folder.appendingPathComponent("stamp")
        let derivedData = folder.appendingPathComponent("dd", isDirectory: true)

        if let recorded = try? String(contentsOf: stampURL, encoding: .utf8), recorded == stamp,
           let xctestrun = Self.xctestrun(in: derivedData) {
            return PhysicalControlBuild(xctestrunURL: xctestrun, wasBuilt: false)
        }

        progress("Building the iPhone input runner (first time only, about a minute)…")
        let secrets = [team, target.hardwareUDID]
        try? fileManager.removeItem(at: folder)
        let sources = folder.appendingPathComponent("src", isDirectory: true)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.copySources(from: sourcesDirectory, to: sources)
        } catch {
            throw PhysicalControlError.buildFailed("the runner's sources could not be copied")
        }

        let developerEnvironment = developerDirectory.map { ["DEVELOPER_DIR": $0.path] } ?? [:]
        let generate = try await ProcessRunner.run(
            executable: pythonURL,
            arguments: [sources.appendingPathComponent("gen_project.py").path],
            environment: developerEnvironment,
            timeout: .seconds(60)
        )
        guard generate.exitCode == 0 else {
            throw PhysicalControlError.buildFailed(
                PhysicalControlRedactor.redact(generate.standardErrorText, secrets: secrets)
            )
        }

        progress("Signing and building the input runner…")
        let build = try await ProcessRunner.run(
            executable: xcodebuildURL,
            arguments: [
                "build-for-testing",
                "-project", sources.appendingPathComponent("DeviceHubProAgent.xcodeproj").path,
                "-scheme", "DeviceHubProAgent",
                "-destination", "id=\(target.hardwareUDID)",
                "-derivedDataPath", derivedData.path,
                "DEVELOPMENT_TEAM=\(team)",
                "CODE_SIGN_STYLE=Automatic",
            ],
            environment: developerEnvironment,
            timeout: buildTimeout
        )
        guard build.exitCode == 0 else {
            throw PhysicalControlError.buildFailed(Self.summary(ofBuildOutput: build.standardOutputText + build.standardErrorText, secrets: secrets))
        }
        guard let xctestrun = Self.xctestrun(in: derivedData) else {
            throw PhysicalControlError.buildFailed("the build produced no .xctestrun")
        }
        try? stamp.write(to: stampURL, atomically: true, encoding: .utf8)
        return PhysicalControlBuild(xctestrunURL: xctestrun, wasBuilt: true)
    }

    private var pythonURL: URL {
        if let developerDirectory {
            let bundled = developerDirectory.appendingPathComponent("usr/bin/python3")
            if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        }
        return URL(fileURLWithPath: "/usr/bin/python3")
    }

    private var xcodebuildURL: URL {
        if let developerDirectory {
            return developerDirectory.appendingPathComponent("usr/bin/xcodebuild")
        }
        return URL(fileURLWithPath: "/usr/bin/xcodebuild")
    }

    static func xctestrun(in derivedData: URL) -> URL? {
        let products = derivedData.appendingPathComponent("Build/Products", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: products.path)) ?? []
        return names.sorted().first { $0.hasSuffix(".xctestrun") }.map { products.appendingPathComponent($0) }
    }

    /// Copies the runner's sources (not the generated project, the client or
    /// the notes) into `destination`.
    static func copySources(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in try fileManager.contentsOfDirectory(atPath: source.path) {
            if name == "DeviceHubProAgent.xcodeproj" || name == "client" || name.hasSuffix(".md") || name == ".DS_Store" { continue }
            try fileManager.copyItem(at: source.appendingPathComponent(name), to: destination.appendingPathComponent(name))
        }
    }

    /// The build's `error:` lines (at most three), else its tail, with the
    /// team and the UDID left out.
    static func summary(ofBuildOutput output: String, secrets: [String]) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        let errors = lines.filter { $0.contains("error:") }.prefix(3)
        let picked = errors.isEmpty ? lines.suffix(6).joined(separator: "\n") : errors.joined(separator: "\n")
        return PhysicalControlRedactor.redact(picked, secrets: secrets, limit: 500)
    }
}
