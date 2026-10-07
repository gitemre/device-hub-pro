import CryptoKit
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The guided Android setup's model: the installer's phases as the card
/// sees them, "Locate SDK…", the app picking the tools up without a
/// relaunch, and when the empty stage shows the card. Nothing here
/// downloads or runs a Google tool.
@MainActor
final class AndroidSetupModelTests: XCTestCase {
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        AndroidSDKLocation.applyPreferredRoot(nil)
        try? FileManager.default.removeItem(at: work)
    }

    // MARK: - Fakes

    private nonisolated static let archive = Data("archive".utf8)

    private final class Downloader: FileDownloading, @unchecked Sendable {
        let catalog: Data
        let lock = NSLock()
        var downloads = 0
        var jreDownloads = 0
        init(catalog: Data) { self.catalog = catalog }
        func data(from url: URL) async throws -> Data {
            if url.host == "api.adoptium.net" {
                let sha = SHA256.hash(data: Data("jre".utf8)).map { String(format: "%02x", $0) }.joined()
                return Data("""
                [{"binary":{"package":{"name":"jre.tar.gz","link":"https://example.test/jre.tar.gz","checksum":"\(sha)","size":3}}}]
                """.utf8)
            }
            return catalog
        }
        func download(_ url: URL, to partial: URL, onProgress: @Sendable @escaping (Int64, Int64?) -> Void) async throws {
            let isJRE = url.lastPathComponent.hasPrefix("jre")
            lock.withLock { if isJRE { jreDownloads += 1 } else { downloads += 1 } }
            try (isJRE ? Data("jre".utf8) : AndroidSetupModelTests.archive).write(to: partial)
            onProgress(3, 3)
        }
    }

    private struct Extractor: ArchiveExtracting {
        func extractZip(_ archive: URL, to directory: URL) async throws {
            let tool = directory.appendingPathComponent("cmdline-tools/bin/sdkmanager")
            try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: tool.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        }
        func extractTarGz(_ archive: URL, to directory: URL) async throws {
            let java = directory.appendingPathComponent("jdk/Contents/Home/bin/java")
            try FileManager.default.createDirectory(at: java.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: java.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        }
    }

    private struct Sdk: SdkPackageInstalling {
        let root: URL
        func install(package: String, onProgress: @Sendable @escaping (Double?) -> Void, onLicense: @Sendable @escaping (String) -> Bool) async throws {
            let target = package == "platform-tools" ? "platform-tools/adb" : "emulator/emulator"
            let url = root.appendingPathComponent(target)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        }
        func cancel() {}
    }

    private func catalog() -> Data {
        let sha = Insecure.SHA1.hash(data: Self.archive).map { String(format: "%02x", $0) }.joined()
        return Data("""
        <?xml version='1.0'?><sdk:sdk-repository xmlns:sdk="x">
        <license id="android-sdk-license" type="text">The license text</license>
        <channel id="channel-0">stable</channel>
        <remotePackage path="cmdline-tools;latest"><uses-license ref="android-sdk-license"/><channelRef ref="channel-0"/>
        <archives><archive><complete><size>7</size><checksum type="sha1">\(sha)</checksum><url>cl.zip</url></complete>
        <host-os>macosx</host-os><host-arch>aarch64</host-arch></archive></archives></remotePackage>
        </sdk:sdk-repository>
        """.utf8)
    }

    private struct Rig {
        let model: AndroidSetupModel
        let downloader: Downloader
        let preferences: AppPreferences
        let root: URL
        var available: Counter
    }

    private final class Counter: @unchecked Sendable {
        var count = 0
    }

    private func rig(java: URL? = URL(fileURLWithPath: "/fake/java")) -> Rig {
        let root = work.appendingPathComponent("sdk")
        let preferences = AppPreferences(defaults: .scratch())
        let downloader = Downloader(catalog: catalog())
        let counter = Counter()
        let model = AndroidSetupModel(
            preferences: preferences,
            environment: [:],
            installRoot: root,
            studioIsInstalled: false,
            makeInstaller: { [work] root in
                AndroidToolsInstaller(
                    root: root,
                    arch: "aarch64",
                    managedJavaDirectory: work!.appendingPathComponent("jdk"),
                    repositoryURL: URL(string: "https://example.test/repo.xml")!,
                    adoptiumListing: URL(string: "https://api.adoptium.net/x")!,
                    downloader: downloader,
                    extractor: Extractor(),
                    findJava: { java },
                    makeSdkmanager: { _, _, root in Sdk(root: root) }
                )
            }
        )
        model.onToolsAvailable = { counter.count += 1 }
        return Rig(model: model, downloader: downloader, preferences: preferences, root: root, available: counter)
    }

    // MARK: - Install

    func testTheInstallAsksForTheLicenseThenFinishesAndTellsTheAppTheToolsArrived() async throws {
        let rig = rig()
        rig.model.startInstall()
        await waitUntil("the license is on screen") {
            if case .awaitingLicense = rig.model.phase { return true }
            return false
        }
        guard case .awaitingLicense(let prompt) = rig.model.phase else { return XCTFail("no license") }
        XCTAssertEqual(prompt.text, "The license text")
        XCTAssertEqual(rig.downloader.downloads, 0, "nothing is downloaded before the click")

        rig.model.acceptLicense()
        await waitUntil("the install finishes") { rig.model.phase == .finished }

        XCTAssertEqual(rig.available.count, 1)
        XCTAssertTrue(AndroidSDKLocation.hasPlatformTools(at: rig.root))
        XCTAssertTrue(AndroidSDKLocation.hasEmulator(at: rig.root))
        XCTAssertEqual(rig.preferences.androidSDKPath, rig.root.path, "outside Studio's default folder the choice is remembered")
    }

    func testDecliningTheLicenseGoesBackToTheStartWithoutAnError() async throws {
        let rig = rig()
        rig.model.startInstall()
        await waitUntil("the license is on screen") {
            if case .awaitingLicense = rig.model.phase { return true }
            return false
        }
        rig.model.declineLicense()
        await waitUntil("back at the start") { rig.model.phase == .idle }
        XCTAssertEqual(rig.model.notice, AndroidSetupModel.licenseDeclinedNotice, "the card says why it went back")
        rig.model.reset()
        XCTAssertNil(rig.model.notice)
        XCTAssertEqual(rig.available.count, 0)
        XCTAssertEqual(rig.downloader.downloads, 0)
    }

    func testWithoutJavaItAsksBeforeDownloadingOneAndThenCarriesOn() async throws {
        let rig = rig(java: nil)
        rig.model.startInstall()
        await waitUntil("asks about Java") { rig.model.phase == .needsJava }
        XCTAssertEqual(rig.downloader.jreDownloads, 0)

        rig.model.startInstall(allowJavaDownload: true)
        await waitUntil("the license is on screen") {
            if case .awaitingLicense = rig.model.phase { return true }
            return false
        }
        rig.model.acceptLicense()
        await waitUntil("the install finishes") { rig.model.phase == .finished }
        XCTAssertEqual(rig.downloader.jreDownloads, 1)
    }

    func testCancellingWhileTheLicenseIsOnScreenGoesBackToTheStart() async throws {
        let rig = rig()
        rig.model.startInstall()
        await waitUntil("the license is on screen") {
            if case .awaitingLicense = rig.model.phase { return true }
            return false
        }
        rig.model.cancel()
        await waitUntil("cancelled") { rig.model.phase == .idle }
        XCTAssertNil(rig.model.notice, "a cancel is the user's own choice")
        XCTAssertFalse(rig.model.isRunning)
        rig.model.reset()
        XCTAssertEqual(rig.model.phase, .idle)
    }

    // MARK: - Locate SDK

    func testALocatedSDKFolderIsRememberedAndPicksTheToolsUp() async throws {
        let rig = rig()
        let sdk = work.appendingPathComponent("elsewhere")
        let adb = sdk.appendingPathComponent("platform-tools/adb")
        try FileManager.default.createDirectory(at: adb.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: adb.path, contents: Data(), attributes: [.posixPermissions: 0o755])

        XCTAssertTrue(rig.model.locateSDK(at: sdk))

        XCTAssertEqual(rig.preferences.androidSDKPath, sdk.path)
        XCTAssertNil(rig.model.locateError)
        await waitUntil("the app is told") { rig.available.count == 1 }
    }

    func testAFolderWithoutAdbIsRefusedWithAReason() throws {
        let rig = rig()
        let empty = work.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertFalse(rig.model.locateSDK(at: empty))
        XCTAssertTrue(rig.model.locateError?.contains("platform-tools") == true, rig.model.locateError ?? "")
        XCTAssertEqual(rig.preferences.androidSDKPath, "")
        XCTAssertFalse(rig.model.locateSDK(at: work.appendingPathComponent("nope")))
        XCTAssertEqual(rig.available.count, 0)
    }

    // MARK: - The stage

    func testTheStageShowsTheCardOnlyWhereItHelps() {
        let idle = AndroidSetupModel.Phase.idle
        XCTAssertTrue(AndroidSetupStage.isShown(adbAvailable: false, dismissed: false, phase: idle))
        XCTAssertFalse(AndroidSetupStage.isShown(adbAvailable: false, dismissed: true, phase: idle), "closed for good")
        XCTAssertFalse(AndroidSetupStage.isShown(adbAvailable: true, dismissed: false, phase: idle))
        XCTAssertTrue(AndroidSetupStage.isShown(adbAvailable: true, dismissed: true, phase: .installing), "a run in progress is never hidden")
        XCTAssertTrue(AndroidSetupStage.isShown(adbAvailable: true, dismissed: false, phase: .finished), "the ready step stays until Done")
    }

    func testTheReadyCardShowsOnlyWithToolsAndNothingToRunAppsOn() {
        func shown(
            adb: Bool = true, loaded: Bool = true, avds: Int = 0, devices: Int = 0,
            dismissed: Bool = false, phase: AndroidSetupModel.Phase = .idle
        ) -> Bool {
            AndroidReadyStage.isShown(
                adbAvailable: adb, avdsLoaded: loaded, avdCount: avds, deviceCount: devices,
                dismissed: dismissed, phase: phase
            )
        }
        XCTAssertTrue(shown())
        XCTAssertFalse(shown(adb: false), "without tools the setup card is the stage")
        XCTAssertFalse(shown(loaded: false), "not before the AVD list was read")
        XCTAssertFalse(shown(avds: 1))
        XCTAssertFalse(shown(devices: 1))
        XCTAssertFalse(shown(dismissed: true))
        XCTAssertFalse(shown(phase: .finished), "the setup run shows its own ready step")
    }

    func testTheInstallFolderIsAndroidStudiosDefaultUnlessTheEnvironmentNamesOne() {
        XCTAssertEqual(
            AndroidSetupModel.defaultInstallRoot(environment: [:]).path,
            AndroidSDKLocation.defaultRoot.path
        )
        XCTAssertEqual(
            AndroidSetupModel.defaultInstallRoot(environment: ["ANDROID_HOME": "/opt/sdk"]).path,
            "/opt/sdk"
        )
        XCTAssertTrue(AndroidSDKLocation.defaultRoot.path.hasSuffix("/Library/Android/sdk"))
    }

    // MARK: - Picking the tools up without a relaunch

    func testTheAppPicksUpAdbThatAppearedAfterLaunchWithoutARelaunch() async throws {
        let stub = try makeStubAdb(arms: "devices*) printf 'List of devices attached\\n\\n' ;;")
        let client = AdbClient.unresolved()
        let model = AppModel.testing(adb: client)
        XCTAssertFalse(model.adbIsAvailable)
        await model.refresh()
        XCTAssertNil(model.status.errorMessage, "a missing adb is a soft state, never an alert")
        XCTAssertFalse(model.inventory.isLifecycleRunning, "nothing is polled without adb")

        let previous = ProcessInfo.processInfo.environment["DHP_ADB"]
        setenv("DHP_ADB", stub.client.adbURL.path, 1)
        defer {
            if let previous { setenv("DHP_ADB", previous, 1) } else { unsetenv("DHP_ADB") }
        }
        await model.adoptAndroidTools()

        XCTAssertTrue(model.adbIsAvailable)
        XCTAssertTrue(client.isResolved, "every holder of the client sees adb")
        XCTAssertEqual(client.adbURL.path, stub.client.adbURL.path)
        XCTAssertTrue(model.inventory.isLifecycleRunning, "polling started")
        XCTAssertFalse(stub.calls(containing: "devices").isEmpty, "the device list was read")
        model.inventory.stopDeviceLifecycle()
    }

    func testAnUnresolvedClientFailsEveryCallWithTheSetupMessage() async {
        let client = AdbClient.unresolved()
        XCTAssertFalse(client.isResolved)
        do {
            _ = try await client.listDevices()
            XCTFail("expected adbNotFound")
        } catch let error as AdbError {
            XCTAssertEqual(error.description, AdbError.adbNotFound.description)
        } catch {
            XCTFail("\(error)")
        }
    }
}
