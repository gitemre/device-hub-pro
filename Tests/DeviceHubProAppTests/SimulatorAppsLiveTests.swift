import AppKit
import CryptoKit
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The Apps inspector and the stage's drops (`SimulatorAppsController`)
/// against a real simulator, behind `DHP_IOS_LIVE=1`:
///
///     DHP_IOS_LIVE=1 swift test --filter SimulatorAppsLiveTests
///
/// It creates its own iPhone in a private device set (`LiveTestSimulators`,
/// shared with the Kit's live tests through a symbolic link), boots it and
/// deletes it afterwards with its set and log folders; it never touches the
/// default set (nothing here needs CoreDevice). It builds a tiny UIKit app
/// with the Xcode toolchain's `swiftc` for the simulator, installs it the
/// way Xcode does (the list must follow on its own: the fresh simulator has
/// no installed-apps folder yet), drops it (and an `.ipa` of it), a PNG, a
/// link and a root certificate the test makes, and checks each on the
/// simulator: the app in `listapps` and running after Launch, gone after
/// Terminate and Uninstall; the photo in the device's DCIM folder; the
/// certificate's SHA-256 in its trust store.
@MainActor
final class SimulatorAppsLiveTests: XCTestCase {
    private static let bundle = "dev.devicehubpro.live.apps"

    func testDropsAndAppActionsOnARealSimulator() async throws {
        let toolchain = try await LiveTestSimulators.toolchain()
        guard let developer = toolchain.developerDirectory else {
            throw XCTSkip("no developer directory")
        }
        let simulators = try LiveTestSimulators.Session(toolchain: toolchain)
        do {
            try await exercise(simulators, developer: developer)
        } catch {
            let leftovers = await simulators.tearDown()
            XCTAssertEqual(leftovers, [])
            throw error
        }
        let leftovers = await simulators.tearDown()
        XCTAssertEqual(leftovers, [])
    }

    // swiftlint:disable:next function_body_length
    private func exercise(_ simulators: LiveTestSimulators.Session, developer: URL) async throws {
        let device = try await simulators.createDevice(name: "DeviceHubPro-AppsLive")
        let udid = device.udid
        let simctl = simulators.simctl
        print("APPS-LIVE created \(udid) in \(simulators.setDirectory.path)")
        try await simctl.bootStatus(udid: udid, bootIfNeeded: true)
        // "Booted" comes before SpringBoard settles.
        try await Task.sleep(for: .seconds(10))

        let inventory = SimulatorInventory(
            apple: AppleTooling(
                probe: { [toolchain = simulators.toolchain] in toolchain },
                deviceSet: simulators.setDirectory,
                devicesDirectory: simulators.setDirectory,
                logsDirectory: LiveTestSimulators.logsDirectory
            ),
            preferences: AppPreferences(defaults: .scratch())
        )
        await inventory.refresh()
        let status = StatusCenter()
        let controller = SimulatorAppsController(simulators: inventory, status: status, defaults: .scratch())
        defer {
            controller.clear()
            inventory.stop()
        }
        let entry = try XCTUnwrap(inventory.entry(udid: udid), "the private set lists its device")
        XCTAssertEqual(entry.state, .booted)
        let dataPath = try XCTUnwrap(entry.dataPath)
        XCTAssertTrue(
            URL(fileURLWithPath: dataPath).resolvingSymlinksInPath().path
                .hasPrefix(simulators.setDirectory.resolvingSymlinksInPath().path),
            dataPath
        )
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimulatorAppsLiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        controller.temporaryDirectory = work

        // Build the app for the simulator.
        let app = try await buildApp(in: work, developer: developer)
        let clock = ContinuousClock()

        // The Apps tab shows the fresh simulator, which has no installed-apps
        // folder yet; an install made elsewhere (simctl, as Xcode does) shows
        // up without anything reading the list by hand.
        await controller.load(udid: udid)
        XCTAssertNil(controller.loadProblem)
        XCTAssertFalse(controller.apps.contains { $0.bundleIdentifier == Self.bundle })
        let applications = URL(fileURLWithPath: dataPath).appendingPathComponent("Containers/Bundle/Application").path
        let hadFolder = FileManager.default.fileExists(atPath: applications)
        var started = clock.now
        try await simctl.install(udid: udid, app: app)
        let outsideInstallSeconds = (clock.now - started).seconds
        started = clock.now
        var followed = false
        while !followed, clock.now - started < .seconds(15) {
            followed = controller.apps.contains { $0.bundleIdentifier == Self.bundle }
            if !followed { try await Task.sleep(for: .milliseconds(100)) }
        }
        let followSeconds = (clock.now - started).seconds
        XCTAssertTrue(followed, "the list followed an install made elsewhere (installed-apps folder before: \(hadFolder))")
        let installed = try XCTUnwrap(controller.apps.first { $0.bundleIdentifier == Self.bundle })
        XCTAssertTrue(installed.isDeveloperApp)
        XCTAssertTrue(installed.isRemovable)
        controller.scope = .developer
        XCTAssertTrue(controller.filteredApps.contains { $0.bundleIdentifier == Self.bundle })
        await controller.uninstall(bundleIdentifier: Self.bundle, name: installed.title, udid: udid)
        XCTAssertFalse(controller.apps.contains { $0.bundleIdentifier == Self.bundle }, "gone after the uninstall")

        // Drop the .app: installed and listed.
        started = clock.now
        await controller.handleDrop([app], udid: udid) { _ in XCTFail("no certificate was dropped") }
        let installSeconds = (clock.now - started).seconds
        XCTAssertNil(status.errorMessage)
        XCTAssertTrue(controller.apps.contains { $0.bundleIdentifier == Self.bundle }, "listed after the drop")

        // Launch, then Terminate.
        await controller.launch(installed, udid: udid)
        XCTAssertNil(status.errorMessage)
        var jobs = try await simctl.launchdJobs(udid: udid)
        XCTAssertTrue(jobs.contains { $0.label.hasPrefix("UIKitApplication:\(Self.bundle)[") && $0.pid != nil }, "running")
        await controller.terminate(installed, udid: udid)
        var stillRunning = true
        for _ in 0..<15 where stillRunning {
            jobs = try await simctl.launchdJobs(udid: udid)
            stillRunning = jobs.contains { $0.label.hasPrefix("UIKitApplication:\(Self.bundle)[") && $0.pid != nil }
            if stillRunning { try await Task.sleep(for: .milliseconds(200)) }
        }
        XCTAssertFalse(stillRunning, "terminated")

        // Show the data container (recorded, not opened).
        var revealed: [URL] = []
        controller.revealInFinder = { revealed.append($0) }
        let listed = try XCTUnwrap(controller.apps.first { $0.bundleIdentifier == Self.bundle })
        await controller.showDataContainer(listed, udid: udid)
        XCTAssertEqual(revealed.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: revealed[0].path), revealed.description)

        // Uninstall, then drop the app as an .ipa: installed again from the
        // unzipped copy, which is removed.
        await controller.uninstall(bundleIdentifier: Self.bundle, name: installed.title, udid: udid)
        XCTAssertFalse(controller.apps.contains { $0.bundleIdentifier == Self.bundle }, "gone after the uninstall")
        let ipa = try await zipAsIPA(app, in: work)
        started = clock.now
        await controller.handleDrop([ipa], udid: udid) { _ in }
        let ipaSeconds = (clock.now - started).seconds
        XCTAssertNil(status.errorMessage)
        XCTAssertTrue(controller.apps.contains { $0.bundleIdentifier == Self.bundle })
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: work.path).filter { $0.hasPrefix("DeviceHubPro-install-") },
            []
        )

        // A PNG and a link.
        let dcim = URL(fileURLWithPath: dataPath).appendingPathComponent("Media/DCIM", isDirectory: true)
        let photosBefore = Self.fileCount(in: dcim)
        let png = work.appendingPathComponent("aqa-live-photo.png")
        try Self.png().write(to: png)
        started = clock.now
        await controller.handleDrop([png, try XCTUnwrap(URL(string: "https://example.com/"))], udid: udid) { _ in }
        let mediaAndLinkSeconds = (clock.now - started).seconds
        XCTAssertNil(status.errorMessage)
        XCTAssertEqual(Self.fileCount(in: dcim), photosBefore + 1, "one photo more in \(dcim.path)")

        // Two root certificates in one drop: asked about together, then
        // both trusted.
        let (pem, sha256) = try await makeRootCertificate(named: "aqa-live-root", in: work)
        let (secondPEM, secondSHA256) = try await makeRootCertificate(named: "aqa-live-root-2", in: work)
        var confirmations: [[URL]] = []
        await controller.handleDrop([pem, secondPEM], udid: udid) { confirmations.append($0) }
        XCTAssertEqual(confirmations, [[pem, secondPEM]])
        await controller.trustRootCertificates([pem, secondPEM], udid: udid)
        XCTAssertNil(status.errorMessage)
        let trustStore = URL(fileURLWithPath: dataPath)
            .appendingPathComponent("private/var/protected/trustd/private/TrustStore.sqlite3")
        let trusted = try await Self.run("/usr/bin/sqlite3", [trustStore.path, "select hex(sha256) from tsettings;"])
        XCTAssertTrue(trusted.contains(sha256), "\(sha256) in \(trusted)")
        XCTAssertTrue(trusted.contains(secondSHA256), "\(secondSHA256) in \(trusted)")

        await controller.uninstall(bundleIdentifier: Self.bundle, name: installed.title, udid: udid)
        XCTAssertFalse(controller.apps.contains { $0.bundleIdentifier == Self.bundle })
        print(
            "SimulatorAppsLiveTests: an outside install took \(outsideInstallSeconds) s and the list followed \(followSeconds) s after it "
                + "(installed-apps folder before: \(hadFolder)), "
                + "drop install \(installSeconds) s, ipa \(ipaSeconds) s, png+link \(mediaAndLinkSeconds) s"
        )
    }

    // MARK: - Helpers

    /// A one-screen UIKit app with a scene manifest (iOS 27 launches no app
    /// without one), built with the toolchain's `swiftc` for the simulator
    /// and signed ad hoc.
    private func buildApp(in work: URL, developer: URL) async throws -> URL {
        let app = work.appendingPathComponent("AQALiveApps.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let source = work.appendingPathComponent("main.swift")
        try Data("""
        import UIKit
        final class AppDelegate: UIResponder, UIApplicationDelegate {
            func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
                let configuration = UISceneConfiguration(name: "Default", sessionRole: session.role)
                configuration.delegateClass = SceneDelegate.self
                return configuration
            }
        }
        final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
            var window: UIWindow?
            func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
                guard let scene = scene as? UIWindowScene else { return }
                let window = UIWindow(windowScene: scene)
                window.rootViewController = UIViewController()
                window.rootViewController?.view.backgroundColor = .systemOrange
                window.makeKeyAndVisible()
                self.window = window
            }
        }
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
        """.utf8).write(to: source)
        let plist: [String: Any] = [
            "CFBundleIdentifier": Self.bundle,
            "CFBundleExecutable": "AQALiveApps",
            "CFBundleName": "AQALiveApps",
            "CFBundleDisplayName": "AQA Live",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
            "DTPlatformName": "iphonesimulator",
            "MinimumOSVersion": "18.0",
            "UIDeviceFamily": [1, 2],
            "UILaunchScreen": [String: Any](),
            "UIApplicationSceneManifest": ["UIApplicationSupportsMultipleScenes": false],
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        let swiftc = developer.appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc").path
        let sdk = developer.appendingPathComponent("Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk").path
        _ = try await Self.run(swiftc, [
            "-target", "arm64-apple-ios18.0-simulator", "-sdk", sdk,
            source.path, "-o", app.appendingPathComponent("AQALiveApps").path,
        ], environment: ["DEVELOPER_DIR": developer.path], timeout: .seconds(300))
        _ = try await Self.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        return app
    }

    private func zipAsIPA(_ app: URL, in work: URL) async throws -> URL {
        let payload = work.appendingPathComponent("ipa/Payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: app, to: payload.appendingPathComponent(app.lastPathComponent))
        let ipa = work.appendingPathComponent("AQALiveApps.ipa")
        _ = try await Self.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", payload.path, ipa.path])
        return ipa
    }

    /// A throwaway root CA (PEM) and the SHA-256 of its DER, as trustd keys it.
    private func makeRootCertificate(named name: String, in work: URL) async throws -> (URL, String) {
        let pem = work.appendingPathComponent("\(name).pem")
        let der = work.appendingPathComponent("\(name).der")
        _ = try await Self.run("/usr/bin/openssl", [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
            "-subj", "/CN=Device Hub Pro Live Test Root \(name)",
            "-addext", "basicConstraints=critical,CA:TRUE",
            "-addext", "keyUsage=critical,keyCertSign,cRLSign",
            "-keyout", work.appendingPathComponent("\(name).key").path,
            "-out", pem.path,
        ])
        _ = try await Self.run("/usr/bin/openssl", ["x509", "-in", pem.path, "-outform", "der", "-out", der.path])
        let digest = SHA256.hash(data: try Data(contentsOf: der)).map { String(format: "%02X", $0) }.joined()
        return (pem, digest)
    }

    private static func fileCount(in folder: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return 0
        }
        return enumerator.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.count
    }

    /// A 64×64 PNG drawn here.
    private static func png() throws -> Data {
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    }

    @discardableResult
    private static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        timeout: Duration = .seconds(60)
    ) async throws -> String {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: executable),
            arguments: arguments,
            environment: environment,
            timeout: timeout
        )
        XCTAssertEqual(result.exitCode, 0, "\(executable) \(arguments.joined(separator: " ")): \(result.standardErrorText)")
        return result.standardOutputText
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
