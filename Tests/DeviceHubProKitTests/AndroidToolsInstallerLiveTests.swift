import XCTest
@testable import DeviceHubProKit

/// The real download and install of Google's packages into a temporary SDK
/// folder (never the user's `~/Library/Android/sdk`). Needs the network and
/// a Java 17+ runtime (Android Studio's bundled one is enough); it installs
/// the command-line tools and platform-tools but not the 400 MB emulator
/// unless `DHP_SDK_INSTALL_EMULATOR=1` is set too. Runs only with
/// `DHP_SDK_INSTALL_LIVE=1`.
final class AndroidToolsInstallerLiveTests: XCTestCase {
    func testTheRealCommandLineToolsAndPlatformToolsInstallIntoATemporaryFolder() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["DHP_SDK_INSTALL_LIVE"] == "1",
            "set DHP_SDK_INSTALL_LIVE=1 to download Google's packages (about 170 MB)"
        )
        let includeEmulator = ProcessInfo.processInfo.environment["DHP_SDK_INSTALL_EMULATOR"] == "1"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicehubpro-live-sdk-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = AndroidToolsInstaller(
            root: root,
            includeEmulator: includeEmulator,
            managedJavaDirectory: root.appendingPathComponent("jdk-never-used")
        )

        let steps = LiveSteps()
        try await installer.install(
            allowJavaDownload: false,
            onProgress: { steps.record($0.step) },
            onLicense: { text in
                steps.noteLicense(text)
                return true
            }
        )

        XCTAssertTrue(AndroidSDKLocation.hasCommandLineTools(at: root))
        XCTAssertTrue(AndroidSDKLocation.hasPlatformTools(at: root))
        XCTAssertEqual(AndroidSDKLocation.hasEmulator(at: root), includeEmulator)
        XCTAssertTrue(steps.licenseText.contains("Terms and Conditions"), "prompts: \(steps.prompts.map { String($0.prefix(80)) })")
        let adb = root.appendingPathComponent("platform-tools/adb")
        let version = try await ProcessRunner.run(executable: adb, arguments: ["version"])
        XCTAssertEqual(version.exitCode, 0)
        XCTAssertTrue(version.standardOutputText.contains("Android Debug Bridge"), version.standardOutputText)
        // The same run again has nothing left to do.
        XCTAssertTrue(installer.missingSteps().isEmpty)
        // The locator finds it from an environment that names the folder.
        XCTAssertEqual(
            AdbBinaryLocator.locate(environment: ["ANDROID_HOME": root.path])?.path,
            adb.path
        )
        XCTAssertEqual(
            AvdmanagerLocator.locate(environment: ["ANDROID_HOME": root.path, "PATH": ""])?.lastPathComponent,
            "avdmanager"
        )
        print("LIVE-SDK-INSTALL steps: \(steps.steps.map(\.title)); adb: \(version.standardOutputText.prefix(60))")
    }

    /// With `DHP_SDK_INSTALL_JAVA=1` as well: pretends the Mac has no
    /// Java, so the installer downloads Eclipse Temurin 21 (about 48 MB) into
    /// a temporary folder, verifies its sha256, unpacks it and runs sdkmanager
    /// on it.
    func testTheRealTemurinRuntimeIsDownloadedAndRunsSdkmanager() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["DHP_SDK_INSTALL_LIVE"] == "1"
                && ProcessInfo.processInfo.environment["DHP_SDK_INSTALL_JAVA"] == "1",
            "set DHP_SDK_INSTALL_LIVE=1 and DHP_SDK_INSTALL_JAVA=1"
        )
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicehubpro-live-jdk-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let managed = base.appendingPathComponent("jdk")
        let root = base.appendingPathComponent("sdk")
        let installer = AndroidToolsInstaller(
            root: root,
            includeEmulator: false,
            managedJavaDirectory: managed,
            findJava: { await JavaRuntimeLocator.workingJava(candidates: JavaRuntimeLocator.candidates(
                environment: [:], managedDirectory: managed, applicationDirectories: [], javaHome: { nil }
            ).filter { $0.path.hasPrefix(managed.path) }) }
        )
        let steps = LiveSteps()
        try await installer.install(
            allowJavaDownload: true,
            onProgress: { steps.record($0.step) },
            onLicense: { _ in true }
        )
        let java = try XCTUnwrap(JavaRuntimeLocator.managedJava(in: managed))
        let version = try await ProcessRunner.run(executable: java, arguments: ["-version"])
        XCTAssertEqual(version.exitCode, 0)
        XCTAssertGreaterThanOrEqual(
            JavaRuntimeLocator.majorVersion(fromVersionOutput: version.standardErrorText) ?? 0, 21
        )
        XCTAssertTrue(AndroidSDKLocation.hasPlatformTools(at: root))
        XCTAssertTrue(steps.steps.contains(.downloadingJava))
        print("LIVE-JDK-INSTALL \(version.standardErrorText.split(separator: "\n").first ?? "")")
    }

    private final class LiveSteps: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var steps: [AndroidToolsInstallStep] = []
        private(set) var licenseText = ""
        func record(_ step: AndroidToolsInstallStep) {
            lock.withLock { if steps.last != step { steps.append(step) } }
        }
        func noteLicense(_ text: String) { lock.withLock { prompts.append(text); if !text.isEmpty { licenseText = text } } }
        private(set) var prompts: [String] = []
    }
}
