import XCTest
@testable import DeviceHubProKit

/// The pieces the guided Android setup reads: Google's repository listing,
/// Adoptium's release listing, the checksums, the SDK folder check and the
/// Java version parse.
final class AndroidSetupParsingTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)

    private func fixture(_ path: String) throws -> Data {
        try Data(contentsOf: Self.fixtures.appendingPathComponent(path))
    }

    // MARK: - repository2-3.xml

    /// `Fixtures/android-repository/repository2-3-trimmed.xml` is
    /// https://dl.google.com/android/repository/repository2-3.xml fetched on
    /// 2026-10-02, byte-exact except that every package other than
    /// `cmdline-tools;latest` and `platform-tools` and the preview license
    /// were removed (the test reads nothing else).
    func testTheRepositoryListingYieldsTheCommandLineToolsArchiveForThisMac() throws {
        let manifest = try AndroidRepositoryManifest.parse(try fixture("android-repository/repository2-3-trimmed.xml"))

        let package = try XCTUnwrap(manifest.package(path: "cmdline-tools;latest"))
        XCTAssertEqual(package.revision, "23.0.0")
        XCTAssertEqual(package.channel, "stable")

        let arm = try XCTUnwrap(AndroidRepositoryManifest.macArchive(of: package, arch: "aarch64"))
        XCTAssertEqual(arm.url, "commandlinetools-mac_arm64-16111833_latest.zip")
        XCTAssertEqual(arm.checksumType, "sha1")
        XCTAssertEqual(arm.checksum, "ad03dc49bfacfd52c110b14104ea548b8a07e830")
        XCTAssertEqual(arm.size, 155_384_151)
        XCTAssertEqual(
            AndroidRepositoryManifest.resolvedURL(of: arm)?.absoluteString,
            "https://dl.google.com/android/repository/commandlinetools-mac_arm64-16111833_latest.zip"
        )

        let intel = try XCTUnwrap(AndroidRepositoryManifest.macArchive(of: package, arch: "x64"))
        XCTAssertEqual(intel.url, "commandlinetools-mac_x86_64-16111833_latest.zip")
        XCTAssertEqual(intel.checksum, "112cf9618794a997ff273537d55bee02c22abffe")
    }

    func testAnArchiveWithoutAnArchitectureServesEveryMac() throws {
        let manifest = try AndroidRepositoryManifest.parse(try fixture("android-repository/repository2-3-trimmed.xml"))
        let tools = try XCTUnwrap(manifest.package(path: "platform-tools"))
        XCTAssertEqual(tools.revision, "37.0.1")
        for arch in ["aarch64", "x64"] {
            XCTAssertEqual(
                AndroidRepositoryManifest.macArchive(of: tools, arch: arch)?.url,
                "platform-tools_r37.0.1-darwin.zip"
            )
        }
        XCTAssertNil(manifest.package(path: "emulator"), "trimmed away")
    }

    func testObsoleteAndUnstablePackagesAreNotOffered() throws {
        let xml = """
        <?xml version='1.0'?>
        <sdk:sdk-repository xmlns:sdk="x">
          <channel id="channel-0">stable</channel>
          <channel id="channel-2">dev</channel>
          <remotePackage obsolete="true" path="a"><channelRef ref="channel-0"/></remotePackage>
          <remotePackage path="b"><channelRef ref="channel-2"/></remotePackage>
          <remotePackage path="c"><channelRef ref="channel-0"/></remotePackage>
        </sdk:sdk-repository>
        """
        let manifest = try AndroidRepositoryManifest.parse(Data(xml.utf8))
        XCTAssertNil(manifest.package(path: "a"))
        XCTAssertNil(manifest.package(path: "b"))
        XCTAssertNotNil(manifest.package(path: "c"))
    }

    func testGarbageIsACatalogError() {
        XCTAssertThrowsError(try AndroidRepositoryManifest.parse(Data("not xml".utf8)))
        XCTAssertThrowsError(try AndroidRepositoryManifest.parse(Data("<a></a>".utf8)))
    }

    // MARK: - Adoptium

    /// `Fixtures/adoptium/latest-21-jre-mac-*.json` are the answers of
    /// `api.adoptium.net/v3/assets/latest/21/hotspot?...&image_type=jre&os=mac`
    /// captured on 2026-10-02, byte-exact.
    func testAdoptiumsListingYieldsTheTarballWithItsSha256() throws {
        let arm = try AdoptiumRelease.parse(try fixture("adoptium/latest-21-jre-mac-aarch64.json"))
        XCTAssertEqual(arm.name, "OpenJDK21U-jre_aarch64_mac_hotspot_21.0.12.1_1.tar.gz")
        XCTAssertEqual(arm.sha256, "dec50fc6f9fcd4fe3ae8cabf5a5fa68f6afc48841f7698e468e9aa5d54beed84")
        XCTAssertEqual(arm.size, 48_144_965)
        XCTAssertEqual(arm.downloadURL.scheme, "https")
        XCTAssertTrue(arm.version.hasPrefix("21."))

        let intel = try AdoptiumRelease.parse(try fixture("adoptium/latest-21-jre-mac-x64.json"))
        XCTAssertTrue(intel.name.contains("x64"), intel.name)
        XCTAssertEqual(intel.sha256.count, 64)
    }

    func testAdoptiumsListingURLNamesTheRuntimeForThisMac() {
        let url = AdoptiumRelease.listingURL(major: 21, arch: "aarch64").absoluteString
        XCTAssertTrue(url.contains("/latest/21/hotspot"))
        XCTAssertTrue(url.contains("architecture=aarch64"))
        XCTAssertTrue(url.contains("image_type=jre"))
        XCTAssertTrue(url.contains("os=mac"))
    }

    func testAnUnusableListingIsRefused() {
        XCTAssertThrowsError(try AdoptiumRelease.parse(Data("[]".utf8)))
        XCTAssertThrowsError(try AdoptiumRelease.parse(Data("{}".utf8)))
    }

    // MARK: - Checksums

    func testChecksumsMatchTheKnownDigestsOfAbc() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sum-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(
            try FileChecksum.hexDigest(of: file, algorithm: .sha1),
            "a9993e364706816aba3e25717850c26c9cd0d89d"
        )
        XCTAssertEqual(
            try FileChecksum.hexDigest(of: file, algorithm: .sha256),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertTrue(FileChecksum.matches(file, algorithm: .sha1, expected: "A9993E364706816ABA3E25717850C26C9CD0D89D\n"))
        XCTAssertFalse(FileChecksum.matches(file, algorithm: .sha1, expected: "0000"))
        XCTAssertFalse(FileChecksum.matches(file.appendingPathExtension("missing"), algorithm: .sha1, expected: "a"))
        XCTAssertEqual(FileChecksum.Algorithm(name: "SHA-256"), .sha256)
        XCTAssertNil(FileChecksum.Algorithm(name: "md5"))
    }

    // MARK: - Java

    func testTheJavaMajorVersionIsReadFromVersionOutput() {
        XCTAssertEqual(JavaRuntimeLocator.majorVersion(fromVersionOutput: "openjdk version \"21.0.12\" 2026-07-21 LTS"), 21)
        XCTAssertEqual(JavaRuntimeLocator.majorVersion(fromVersionOutput: "java version \"1.8.0_392\""), 8)
        XCTAssertEqual(JavaRuntimeLocator.majorVersion(fromVersionOutput: "openjdk version \"17\" 2021-09-14"), 17)
        XCTAssertNil(JavaRuntimeLocator.majorVersion(fromVersionOutput: "The operation couldn't be completed."))
    }

    func testStudiosBundledRuntimeAndTheManagedOneAreCandidates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("java-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = root.appendingPathComponent("Applications")
        let studioJava = apps.appendingPathComponent("Android Studio.app/Contents/jbr/Contents/Home/bin/java")
        let managed = root.appendingPathComponent("jdk")
        let managedJava = managed.appendingPathComponent("jdk-21.0.12+1-jre/Contents/Home/bin/java")
        for java in [studioJava, managedJava] {
            try FileManager.default.createDirectory(at: java.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: java.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }
        let found = JavaRuntimeLocator.candidates(
            environment: [:],
            managedDirectory: managed,
            applicationDirectories: [apps],
            javaHome: { nil }
        )
        XCTAssertEqual(
            found.map(\.path).filter { $0.hasPrefix(root.path) },
            [managedJava.path, studioJava.path],
            "the app's own runtime first"
        )
        XCTAssertEqual(JavaRuntimeLocator.managedJava(in: managed)?.path, managedJava.path)
    }

    func testAJavaThatReportsAnOldVersionIsNotUsed() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oldjava-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func script(_ name: String, _ version: String) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try "#!/bin/sh\necho 'openjdk version \"\(version)\"' >&2\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }
        let old = try script("old", "1.8.0_392")
        let new = try script("new", "21.0.1")
        let found = await JavaRuntimeLocator.workingJava(candidates: [old, new])
        XCTAssertEqual(found?.path, new.path)
        let none = await JavaRuntimeLocator.workingJava(candidates: [old])
        XCTAssertNil(none)
    }

    // MARK: - SDK folder

    func testAnSDKFolderNeedsAnExecutableAdb() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sdk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let tools = base.appendingPathComponent("platform-tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)

        XCTAssertEqual(AndroidSDKLocation.validate(base), .missingPlatformTools(folder: base))
        func root(_ validation: AndroidSDKLocation.Validation) -> String? {
            if case .valid(let root) = validation { return root.standardizedFileURL.path }
            return nil
        }
        XCTAssertEqual(AndroidSDKLocation.validate(base.appendingPathComponent("nope")), .notAFolder)

        FileManager.default.createFile(atPath: tools.appendingPathComponent("adb").path, contents: Data(), attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(root(AndroidSDKLocation.validate(base)), base.standardizedFileURL.path)
        XCTAssertEqual(root(AndroidSDKLocation.validate(tools)), base.standardizedFileURL.path, "the platform-tools folder itself also names the SDK")
        XCTAssertTrue(AndroidSDKLocation.hasPlatformTools(at: base))
        XCTAssertFalse(AndroidSDKLocation.hasCommandLineTools(at: base))
    }

    func testAChosenSDKFolderReachesTheLocatorsUnlessTheLaunchEnvironmentNamesOne() throws {
        let launch = ProcessInfo.processInfo.environment
        try XCTSkipIf(
            launch["ANDROID_HOME"]?.isEmpty == false || launch["ANDROID_SDK_ROOT"]?.isEmpty == false,
            "the launch environment names an SDK, which always wins"
        )
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("chosen-\(UUID().uuidString)")
        defer {
            AndroidSDKLocation.applyPreferredRoot(nil)
            try? FileManager.default.removeItem(at: base)
        }
        let tools = base.appendingPathComponent("platform-tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tools.appendingPathComponent("adb").path, contents: Data(), attributes: [.posixPermissions: 0o755])

        XCTAssertEqual(AndroidSDKLocation.applyPreferredRoot(base.path)?.path, base.path)
        XCTAssertEqual(AdbBinaryLocator.locate()?.path, base.path + "/platform-tools/adb")

        AndroidSDKLocation.applyPreferredRoot(nil)
        XCTAssertNotEqual(AdbBinaryLocator.locate()?.path, base.path + "/platform-tools/adb", "withdrawn")
        XCTAssertNil(AndroidSDKLocation.applyPreferredRoot(base.path + "/missing"), "a path that is no SDK is not applied")
    }
}
