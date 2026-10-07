import CryptoKit
import XCTest
@testable import DeviceHubProKit

/// The installer's state machine over a fake downloader, a fake archive
/// extractor and a fake sdkmanager: it never touches the network or runs a
/// Google tool. The real download and install is the live test below.
final class AndroidToolsInstallerTests: XCTestCase {
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: work)
    }

    // MARK: - Fakes

    private static let archiveBytes = Data("fake command-line tools archive".utf8)
    private static let jreBytes = Data("fake jre archive".utf8)

    private static func sha1(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func repositoryXML(sha1: String) -> Data {
        Data("""
        <?xml version='1.0'?>
        <sdk:sdk-repository xmlns:sdk="x">
          <license id="android-sdk-license" type="text">Terms and Conditions\n\nFake license text.</license>
          <channel id="channel-0">stable</channel>
          <remotePackage path="cmdline-tools;latest">
            <uses-license ref="android-sdk-license"/>
            <channelRef ref="channel-0"/>
            <archives>
              <archive><complete><size>31</size><checksum type="sha1">\(sha1)</checksum><url>cmdline-fake.zip</url></complete>
                <host-os>macosx</host-os><host-arch>aarch64</host-arch></archive>
              <archive><complete><size>31</size><checksum type="sha1">\(sha1)</checksum><url>cmdline-fake.zip</url></complete>
                <host-os>macosx</host-os><host-arch>x64</host-arch></archive>
            </archives>
          </remotePackage>
        </sdk:sdk-repository>
        """.utf8)
    }

    private static func adoptiumJSON(sha256: String) -> Data {
        Data("""
        [{"binary":{"package":{"name":"jre-fake.tar.gz","link":"https://example.test/jre-fake.tar.gz",
          "checksum":"\(sha256)","size":16}},"version":{"openjdk_version":"21.0.1+1"}}]
        """.utf8)
    }

    private final class FakeDownloader: FileDownloading, @unchecked Sendable {
        let lock = NSLock()
        var catalog: Data
        var adoptium: Data
        var archive: Data
        var jre: Data
        var failDownload: Error?
        var downloads: [String] = []
        var dataRequests: [String] = []
        var onDownload: (@Sendable () async -> Void)?

        init(catalog: Data, adoptium: Data, archive: Data, jre: Data) {
            self.catalog = catalog
            self.adoptium = adoptium
            self.archive = archive
            self.jre = jre
        }

        func data(from url: URL) async throws -> Data {
            lock.withLock { dataRequests.append(url.lastPathComponent) }
            return url.host == "api.adoptium.net" ? adoptium : catalog
        }

        func download(
            _ url: URL, to partial: URL,
            onProgress: @Sendable @escaping (Int64, Int64?) -> Void
        ) async throws {
            lock.withLock { downloads.append(url.lastPathComponent) }
            if let onDownload { await onDownload() }
            try Task.checkCancellation()
            if let failDownload { throw failDownload }
            let body = url.lastPathComponent.hasPrefix("jre") ? jre : archive
            try body.write(to: partial)
            onProgress(Int64(body.count), Int64(body.count))
        }
    }

    private struct FakeExtractor: ArchiveExtracting {
        func extractZip(_ archive: URL, to directory: URL) async throws {
            let sdkmanager = directory.appendingPathComponent("cmdline-tools/bin/sdkmanager")
            try FileManager.default.createDirectory(at: sdkmanager.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: sdkmanager.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }

        func extractTarGz(_ archive: URL, to directory: URL) async throws {
            let java = directory.appendingPathComponent("jdk-21.0.1+1-jre/Contents/Home/bin/java")
            try FileManager.default.createDirectory(at: java.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: java.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }
    }

    private final class FakeSdk: SdkPackageInstalling, @unchecked Sendable {
        let root: URL
        let lock = NSLock()
        var installed: [String] = []
        var javaUsed: URL?
        var licenseText: String?
        var licenseAnswer: Bool?
        var legacyPrompt: String?
        var failPackage: String?
        var cancelled = false

        init(root: URL) { self.root = root }

        func install(
            package: String,
            onProgress: @Sendable @escaping (Double?) -> Void,
            onLicense: @Sendable @escaping (String) -> Bool
        ) async throws {
            if package == "platform-tools", let legacyPrompt {
                // An older sdkmanager asks again; the user already said yes.
                licenseAnswer = onLicense(legacyPrompt)
            }
            if failPackage == package { throw SdkmanagerError.commandFailed("boom") }
            onProgress(0.5)
            lock.withLock { installed.append(package) }
            let target = package == "platform-tools" ? "platform-tools/adb" : "emulator/emulator"
            let url = root.appendingPathComponent(target)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        }

        func cancel() { cancelled = true }
    }

    private final class Texts: @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String] = []
        func add(_ text: String) { lock.withLock { texts.append(text) } }
        var all: [String] { lock.withLock { texts } }
    }

    private final class Progress: @unchecked Sendable {
        let lock = NSLock()
        var steps: [AndroidToolsInstallStep] = []
        func record(_ step: AndroidToolsInstallStep) {
            lock.lock(); defer { lock.unlock() }
            if steps.last != step { steps.append(step) }
        }
    }

    private struct Rig {
        let installer: AndroidToolsInstaller
        let downloader: FakeDownloader
        let sdk: FakeSdk
        let root: URL
        let managedJava: URL
    }

    private func rig(
        archiveSha: String? = nil,
        java: URL? = URL(fileURLWithPath: "/fake/java"),
        findJava: (@Sendable () async -> URL?)? = nil
    ) -> Rig {
        let root = work.appendingPathComponent("sdk")
        let managed = work.appendingPathComponent("jdk")
        let downloader = FakeDownloader(
            catalog: Self.repositoryXML(sha1: archiveSha ?? Self.sha1(Self.archiveBytes)),
            adoptium: Self.adoptiumJSON(sha256: Self.sha256(Self.jreBytes)),
            archive: Self.archiveBytes,
            jre: Self.jreBytes
        )
        let sdk = FakeSdk(root: root)
        let installer = AndroidToolsInstaller(
            root: root,
            arch: "aarch64",
            managedJavaDirectory: managed,
            repositoryURL: URL(string: "https://example.test/repository2-3.xml")!,
            adoptiumListing: URL(string: "https://api.adoptium.net/list")!,
            downloader: downloader,
            extractor: FakeExtractor(),
            findJava: findJava ?? { java },
            makeSdkmanager: { _, javaURL, _ in
                sdk.javaUsed = javaURL
                return sdk
            }
        )
        return Rig(installer: installer, downloader: downloader, sdk: sdk, root: root, managedJava: managed)
    }

    // MARK: - Tests

    func testAFreshInstallRunsEveryStepInOrderAndLeavesAWorkingSDK() async throws {
        let rig = rig()
        let progress = Progress()
        XCTAssertEqual(rig.installer.missingSteps(), [.downloadingCommandLineTools, .installingPlatformTools, .installingEmulator])

        try await rig.installer.install(
            allowJavaDownload: false,
            onProgress: { progress.record($0.step) },
            onLicense: { _ in true }
        )

        XCTAssertEqual(progress.steps, [
            .checkingJava, .readingCatalog, .downloadingCommandLineTools,
            .installingPlatformTools, .installingEmulator, .finishing,
        ])
        XCTAssertEqual(rig.sdk.installed, ["platform-tools", "emulator"])
        XCTAssertEqual(rig.sdk.javaUsed?.path, "/fake/java")
        XCTAssertTrue(AndroidSDKLocation.hasCommandLineTools(at: rig.root))
        XCTAssertTrue(AndroidSDKLocation.hasPlatformTools(at: rig.root))
        XCTAssertTrue(AndroidSDKLocation.hasEmulator(at: rig.root))
        XCTAssertTrue(rig.installer.missingSteps().isEmpty)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: rig.root.path)
        XCTAssertFalse(leftovers.contains(AndroidToolsInstaller.downloadsFolderName), "the archive is cleaned up")
        XCTAssertFalse(leftovers.contains(AndroidToolsInstaller.stagingFolderName))
    }

    func testTheLicenseIsShownBeforeAnythingIsDownloadedAndDeclineStopsEverything() async throws {
        let rig = rig()
        let seen = Texts()
        do {
            try await rig.installer.install(
                allowJavaDownload: false, onProgress: { _ in },
                onLicense: { seen.add($0); return false }
            )
            XCTFail("a declined license must stop the install")
        } catch let error as AndroidToolsInstallError {
            XCTAssertEqual(error, .licenseDeclined)
        }
        XCTAssertEqual(seen.all, ["Terms and Conditions\n\nFake license text."], "Google's own text, once")
        XCTAssertEqual(rig.downloader.downloads, [], "nothing of Google's is downloaded without consent")
        XCTAssertEqual(rig.sdk.installed, [])
        XCTAssertFalse(AndroidSDKLocation.hasCommandLineTools(at: rig.root))
    }

    func testAcceptingOnceAlsoAnswersAnOlderSdkmanagersOwnPrompt() async throws {
        let rig = rig()
        rig.sdk.legacyPrompt = "the same license again"
        let seen = Texts()
        try await rig.installer.install(
            allowJavaDownload: false, onProgress: { _ in },
            onLicense: { seen.add($0); return true }
        )
        XCTAssertEqual(seen.all.count, 1, "the user is not asked twice")
        XCTAssertEqual(rig.sdk.licenseAnswer, true)
    }

    func testALicenseAlreadyRecordedInTheSDKIsNotAskedAgain() async throws {
        let rig = rig()
        let licenses = rig.root.appendingPathComponent("licenses")
        try FileManager.default.createDirectory(at: licenses, withIntermediateDirectories: true)
        try Data("24333f8a63b6825ea9c5514f83c2829b004d1fee".utf8).write(to: licenses.appendingPathComponent("android-sdk-license"))
        let seen = Texts()
        try await rig.installer.install(
            allowJavaDownload: false, onProgress: { _ in },
            onLicense: { seen.add($0); return false }
        )
        XCTAssertEqual(seen.all, [])
        XCTAssertTrue(AndroidSDKLocation.hasPlatformTools(at: rig.root))
    }

    func testARerunAfterAFailureReusesTheVerifiedDownloadAndSkipsFinishedSteps() async throws {
        let rig = rig()
        rig.sdk.failPackage = "emulator"
        do {
            try await rig.installer.install(allowJavaDownload: false, onProgress: { _ in }, onLicense: { _ in true })
            XCTFail("expected the emulator step to fail")
        } catch let error as AndroidToolsInstallError {
            XCTAssertEqual(error, .toolFailed("boom"))
        }
        XCTAssertEqual(rig.sdk.installed, ["platform-tools"])
        XCTAssertEqual(rig.downloader.downloads, ["cmdline-fake.zip"])

        rig.sdk.failPackage = nil
        try await rig.installer.install(allowJavaDownload: false, onProgress: { _ in }, onLicense: { _ in true })

        XCTAssertEqual(rig.downloader.downloads, ["cmdline-fake.zip"], "command-line tools are not fetched twice")
        XCTAssertEqual(rig.sdk.installed, ["platform-tools", "emulator"], "platform-tools is not installed twice")
        XCTAssertTrue(rig.installer.missingSteps().isEmpty)
    }

    func testAVerifiedArchiveLeftByACancelledRunIsReusedWithoutDownloading() async throws {
        let rig = rig()
        let downloads = rig.root.appendingPathComponent(AndroidToolsInstaller.downloadsFolderName)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Self.archiveBytes.write(to: downloads.appendingPathComponent("cmdline-fake.zip"))
        // Half of an unpack from an earlier run.
        let staging = rig.root.appendingPathComponent(AndroidToolsInstaller.stagingFolderName + "/junk")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        try await rig.installer.install(allowJavaDownload: false, onProgress: { _ in }, onLicense: { _ in true })

        XCTAssertEqual(rig.downloader.downloads, [])
        XCTAssertTrue(AndroidSDKLocation.hasCommandLineTools(at: rig.root))
    }

    func testAChecksumMismatchDiscardsTheDownloadAndSaysSo() async throws {
        let rig = rig(archiveSha: String(repeating: "0", count: 40))
        do {
            try await rig.installer.install(allowJavaDownload: false, onProgress: { _ in }, onLicense: { _ in true })
            XCTFail("a wrong checksum must stop the install")
        } catch let error as AndroidToolsInstallError {
            XCTAssertEqual(error, .checksumMismatch("cmdline-fake.zip"))
            XCTAssertTrue("\(error)".contains("checksum"))
        }
        XCTAssertFalse(AndroidSDKLocation.hasCommandLineTools(at: rig.root))
        let downloads = rig.root.appendingPathComponent(AndroidToolsInstaller.downloadsFolderName)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? [], [])
        XCTAssertEqual(rig.sdk.installed, [])
    }

    func testWithoutJavaTheInstallAsksFirstAndThenDownloadsTemurin() async throws {
        let rig = rig(findJava: { nil })
        do {
            try await rig.installer.install(allowJavaDownload: false, onProgress: { _ in }, onLicense: { _ in true })
            XCTFail("expected javaRequired")
        } catch let error as AndroidToolsInstallError {
            XCTAssertEqual(error, .javaRequired)
        }
        XCTAssertEqual(rig.downloader.downloads, [], "nothing is downloaded before the user agrees")

        let progress = Progress()
        try await rig.installer.install(allowJavaDownload: true, onProgress: { progress.record($0.step) }, onLicense: { _ in true })

        XCTAssertEqual(rig.downloader.downloads, ["jre-fake.tar.gz", "cmdline-fake.zip"])
        XCTAssertTrue(progress.steps.contains(.downloadingJava))
        let java = try XCTUnwrap(JavaRuntimeLocator.managedJava(in: rig.managedJava))
        XCTAssertEqual(rig.sdk.javaUsed?.path, java.path, "sdkmanager runs on the downloaded runtime")
    }

    func testACorruptJavaDownloadIsRefused() async throws {
        let rig = rig(findJava: { nil })
        rig.downloader.jre = Data("tampered".utf8)
        do {
            try await rig.installer.install(allowJavaDownload: true, onProgress: { _ in }, onLicense: { _ in true })
            XCTFail("expected a checksum mismatch")
        } catch let error as AndroidToolsInstallError {
            XCTAssertEqual(error, .checksumMismatch("jre-fake.tar.gz"))
        }
        XCTAssertNil(JavaRuntimeLocator.managedJava(in: rig.managedJava))
    }

    func testCancellingStopsTheInstallAndReportsIt() async throws {
        let rig = rig()
        let started = expectation(description: "download started")
        rig.downloader.onDownload = {
            started.fulfill()
            try? await Task.sleep(for: .seconds(30))
        }
        let installer = rig.installer
        let task = Task {
            try await installer.install(allowJavaDownload: false, onProgress: { _ in }, onLicense: { _ in true })
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch let error as AndroidToolsInstallError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertFalse(AndroidSDKLocation.hasCommandLineTools(at: rig.root))
    }

    func testANetworkFailureIsAReadableDownloadError() async throws {
        let rig = rig()
        rig.downloader.failDownload = URLError(.notConnectedToInternet)
        do {
            try await rig.installer.install(allowJavaDownload: false, onProgress: { _ in }, onLicense: { _ in true })
            XCTFail("expected a download failure")
        } catch let error as AndroidToolsInstallError {
            guard case .downloadFailed = error else { return XCTFail("\(error)") }
            XCTAssertTrue("\(error)".hasPrefix("The download failed"))
        }
    }

    func testAnUnreadableCatalogIsReported() async throws {
        let rig = rig()
        rig.downloader.catalog = Data("<html>captive portal</html>".utf8)
        do {
            try await rig.installer.install(allowJavaDownload: false, onProgress: { _ in }, onLicense: { _ in true })
            XCTFail("expected a catalog error")
        } catch let error as AndroidToolsInstallError {
            guard case .catalogUnreadable = error else { return XCTFail("\(error)") }
        }
    }

    func testAnAlreadyCompleteSDKIsLeftAlone() async throws {
        let rig = rig()
        for path in ["cmdline-tools/latest/bin/sdkmanager", "platform-tools/adb", "emulator/emulator"] {
            let url = rig.root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        }
        try await rig.installer.install(allowJavaDownload: false, onProgress: { _ in }, onLicense: { _ in true })
        XCTAssertEqual(rig.downloader.dataRequests, [])
        XCTAssertEqual(rig.sdk.installed, [])
    }

    func testACompleteSDKOnAMacWithoutJavaStillGetsAJavaRuntimeForAvdmanager() async throws {
        let rig = rig(findJava: { nil })
        for path in ["cmdline-tools/latest/bin/sdkmanager", "platform-tools/adb", "emulator/emulator"] {
            let url = rig.root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        }
        do {
            try await rig.installer.install(allowJavaDownload: false, onProgress: { _ in }, onLicense: { _ in true })
            XCTFail("expected javaRequired")
        } catch let error as AndroidToolsInstallError {
            XCTAssertEqual(error, .javaRequired)
        }
        try await rig.installer.install(allowJavaDownload: true, onProgress: { _ in }, onLicense: { _ in true })
        XCTAssertEqual(rig.downloader.downloads, ["jre-fake.tar.gz"], "only Java is fetched")
        XCTAssertNotNil(JavaRuntimeLocator.managedJava(in: rig.managedJava))
    }
}
