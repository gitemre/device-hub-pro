import Foundation
import XCTest
@testable import DeviceHubProKit

/// The helper's build cache and where its sources are found: the stamp names a
/// digest of the sources and the Xcode build, so a change rebuilds and nothing
/// else does. No test runs a compiler: the script runner is a fake.
final class FastInputBuilderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fastinput-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSources(_ name: String = "fastinput") throws -> URL {
        let sources = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: sources.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try "#!/bin/bash\n".write(to: sources.appendingPathComponent("build.sh"), atomically: true, encoding: .utf8)
        try "int main(void){return 0;}\n".write(to: sources.appendingPathComponent("Sources/main.m"), atomically: true, encoding: .utf8)
        try "notes".write(to: sources.appendingPathComponent("PROVENANCE.md"), atomically: true, encoding: .utf8)
        return sources
    }

    private final class Runs: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        private var _environments: [[String: String]] = []
        var count: Int { lock.withLock { _count } }
        var environments: [[String: String]] { lock.withLock { _environments } }
        func note(_ environment: [String: String]) { lock.withLock { _count += 1; _environments.append(environment) } }
    }

    private func builder(
        sources: URL,
        xcode: String? = "27A266a",
        runs: Runs,
        exitCode: Int32 = 0,
        output: String = ""
    ) -> FastInputBuilder {
        FastInputBuilder(
            sourcesDirectory: sources,
            cacheDirectory: root.appendingPathComponent("cache", isDirectory: true),
            developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"),
            xcodeBuild: xcode,
            buildTimeout: .seconds(5),
            runScript: { script, outputDirectory, environment in
                runs.note(environment)
                XCTAssertEqual(script.lastPathComponent, "build.sh")
                if exitCode == 0 {
                    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                    let helper = outputDirectory.appendingPathComponent(FastInputBuilder.helperName)
                    try "#!/bin/sh\n".write(to: helper, atomically: true, encoding: .utf8)
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
                }
                return ProcessResult(exitCode: exitCode, standardOutput: Data(), standardError: Data(output.utf8))
            }
        )
    }

    func testFirstUseBuildsThenTheCacheIsUsed() async throws {
        let sources = try makeSources()
        let runs = Runs()
        let builder = builder(sources: sources, runs: runs)
        let first = try await builder.ensureHelper()
        XCTAssertTrue(first.wasBuilt)
        XCTAssertEqual(first.helperURL.lastPathComponent, "fastinput-helper")
        XCTAssertEqual(runs.environments.first, ["DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"])
        let second = try await builder.ensureHelper()
        XCTAssertFalse(second.wasBuilt)
        XCTAssertEqual(second.helperURL, first.helperURL)
        XCTAssertEqual(runs.count, 1)
    }

    func testAChangedSourceOrXcodeBuildRebuilds() async throws {
        let sources = try makeSources()
        let runs = Runs()
        _ = try await builder(sources: sources, runs: runs).ensureHelper()
        XCTAssertEqual(runs.count, 1)

        _ = try await builder(sources: sources, xcode: "27B1", runs: runs).ensureHelper()
        XCTAssertEqual(runs.count, 2, "a new Xcode rebuilds: the helper calls private ABI")

        try "int main(void){return 1;}\n".write(to: sources.appendingPathComponent("Sources/main.m"), atomically: true, encoding: .utf8)
        _ = try await builder(sources: sources, xcode: "27B1", runs: runs).ensureHelper()
        XCTAssertEqual(runs.count, 3)

        // The notes are not an input.
        try "other notes".write(to: sources.appendingPathComponent("PROVENANCE.md"), atomically: true, encoding: .utf8)
        _ = try await builder(sources: sources, xcode: "27B1", runs: runs).ensureHelper()
        XCTAssertEqual(runs.count, 3)
    }

    func testTheStampNamesDigestsOnly() throws {
        let sources = try makeSources()
        let digest = try FastInputBuilder.sourcesDigest(of: sources)
        let stamp = FastInputBuilder.stamp(sourcesDigest: digest, xcodeBuild: "27A266a")
        XCTAssertEqual(stamp.count, 64)
        XCTAssertNotEqual(stamp, FastInputBuilder.stamp(sourcesDigest: digest, xcodeBuild: "other"))
        XCTAssertNotEqual(stamp, FastInputBuilder.stamp(sourcesDigest: digest, xcodeBuild: nil))
    }

    func testAFailedBuildSaysWhyAndCachesNothing() async throws {
        let sources = try makeSources()
        let runs = Runs()
        let failing = builder(sources: sources, runs: runs, exitCode: 1, output: "x.m:3: error: unknown type name 'foo'\nnoise")
        do {
            _ = try await failing.ensureHelper()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? FastInputError, .buildFailed("x.m:3: error: unknown type name 'foo'"))
        }
        _ = try await builder(sources: sources, runs: runs).ensureHelper()
        XCTAssertEqual(runs.count, 2, "a failed build leaves no stamp")
    }

    func testMissingSourcesAreReported() async throws {
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        do {
            _ = try await builder(sources: empty, runs: Runs()).ensureHelper()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? FastInputError, .sourcesMissing)
        }
    }

    // MARK: Finding the sources

    func testLocateSourcesPrefersTheOverrideThenTheBundleThenTheCheckout() throws {
        let override = try makeSources("override")
        XCTAssertEqual(
            FastInputBuilder.locateSources(environment: ["DHP_FAST_INPUT_DIR": override.path], resourceURL: nil, executableURL: nil)?.standardizedFileURL,
            override.standardizedFileURL
        )
        // An override that is not valid is not silently replaced.
        XCTAssertNil(FastInputBuilder.locateSources(environment: ["DHP_FAST_INPUT_DIR": root.path], resourceURL: nil, executableURL: nil))

        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let bundled = try makeSources("Resources/fastinput")
        XCTAssertEqual(
            FastInputBuilder.locateSources(environment: [:], resourceURL: resources, executableURL: nil)?.standardizedFileURL,
            bundled.standardizedFileURL
        )

        let checkout = root.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout.appendingPathComponent(".build/debug"), withIntermediateDirectories: true)
        let inCheckout = try makeSources("checkout/fastinput")
        let executable = checkout.appendingPathComponent(".build/debug/DeviceHubPro")
        XCTAssertEqual(
            FastInputBuilder.locateSources(environment: [:], resourceURL: nil, executableURL: executable)?.standardizedFileURL,
            inCheckout.standardizedFileURL
        )
        XCTAssertNil(FastInputBuilder.locateSources(environment: [:], resourceURL: nil, executableURL: root.appendingPathComponent("nowhere/DeviceHubPro")))
    }

    /// The repository's own `fastinput/` is a valid source folder with the files the build script names.
    func testTheRepositorysSourcesAreComplete() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = repo.appendingPathComponent("fastinput", isDirectory: true)
        let script = try String(contentsOf: directory.appendingPathComponent("build.sh"), encoding: .utf8)
        for name in ["fastinput_main.m", "mercury_abi", "universalhid_abi", "uhid_request_abi", "mercury_glue", "universalhid_glue"] {
            XCTAssertTrue(script.contains(name), name)
        }
        for file in ["Sources/fastinput_main.m", "Sources/mercury_abi.S", "Sources/universalhid_abi.S", "Sources/uhid_request_abi.S",
                     "Sources/mercury_glue.swift", "Sources/universalhid_glue.swift", "LICENSE", "PROVENANCE.md"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path), file)
        }
        XCTAssertNoThrow(try FastInputBuilder.sourcesDigest(of: directory))
    }
}
