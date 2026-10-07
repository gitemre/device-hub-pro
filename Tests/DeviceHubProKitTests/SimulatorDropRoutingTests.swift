import XCTest
@testable import DeviceHubProKit

/// Drops on a simulator's stage (`SimulatorDropRouting`), the app bundles
/// they carry (`SimulatorAppBundle`) and the archives that hold them
/// (`SimulatorAppArchive`).
///
/// The bundles under `Fixtures/ios27-simulator/apps/` are the fixture app of
/// `SimctlAppsFixtureTests` (`AQAAppsFixture`, Device Hub Pro's own code and
/// artwork, no Apple file): its `Info.plist` as the build wrote it, with the
/// icon keys `actool` (Xcode 27.0, 27A266a) merged in from its partial plist,
/// and the two loose icon files `actool` left in the bundle
/// (`AppIcon60x60@2x.png`, 120×120; `AppIcon76x76@2x~ipad.png`, 152×152). The
/// executables and `Assets.car` are left out (not read). The simulator build
/// (`AQAAppsFixture.app`) is the one simctl installed; the device build
/// (`AQAAppsFixture-device.app`) is the one it refused.
final class SimulatorDropRoutingTests: XCTestCase {
    private static let apps = SimctlFixtureTests.root.appendingPathComponent("apps", isDirectory: true)
    private static let simulatorApp = apps.appendingPathComponent("AQAAppsFixture.app", isDirectory: true)
    private static let deviceApp = apps.appendingPathComponent("AQAAppsFixture-device.app", isDirectory: true)

    private func file(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/drops/\(name)")
    }

    // MARK: - Routing

    func testEachKindOfFileHasItsCall() throws {
        XCTAssertEqual(SimulatorDropRouting.route(file("Demo.app")), .installApp(file("Demo.app")))
        XCTAssertEqual(SimulatorDropRouting.route(file("Demo.ipa")), .installArchive(file("Demo.ipa")))
        XCTAssertEqual(SimulatorDropRouting.route(file("Demo.zip")), .installArchive(file("Demo.zip")))
        for name in ["photo.png", "photo.JPG", "photo.jpeg", "photo.heic", "clip.mov", "clip.mp4", "clip.m4v", "anim.gif", "card.vcf"] {
            XCTAssertEqual(SimulatorDropRouting.route(file(name)), .addMedia([file(name)]), name)
        }
        for name in ["root.pem", "root.cer", "root.CRT", "root.der"] {
            XCTAssertEqual(SimulatorDropRouting.route(file(name)), .addRootCertificate(file(name)), name)
        }
        XCTAssertEqual(SimulatorDropRouting.route(file("Corp.mobileconfig")), .addProfile(file("Corp.mobileconfig")))
        XCTAssertEqual(SimulatorDropRouting.route(file("Corp.MobileConfig")), .addProfile(file("Corp.MobileConfig")))
        for name in ["notes.txt", "Data.xcappdata", "route.gpx", "noextension"] {
            guard case .unsupported(let url, let reason) = SimulatorDropRouting.route(file(name)) else {
                XCTFail("\(name) should be unsupported")
                continue
            }
            XCTAssertEqual(url, file(name))
            XCTAssertTrue(reason.contains("“\(name)”"), reason)
        }
    }

    func testLinksOpen() throws {
        for text in ["https://example.com/path?q=1", "http://localhost:8080", "aqaapps://hello", "maps://?q=Istanbul"] {
            let url = try XCTUnwrap(URL(string: text))
            XCTAssertEqual(SimulatorDropRouting.route(url), .openURL(url), text)
        }
        let bare = try XCTUnwrap(URL(string: "example"))
        guard case .unsupported = SimulatorDropRouting.route(bare) else {
            return XCTFail("a link without a scheme opens nothing")
        }
    }

    /// Several files at once: the media merge into one `addmedia` (a Live
    /// Photo's picture and movie together), at the first one's place; the
    /// rest keep their order.
    func testSeveralFilesKeepTheirOrderAndShareOneImport() throws {
        let drops = SimulatorDropRouting.route([
            file("IMG_1.HEIC"), file("Demo.app"), file("IMG_1.MOV"), file("root.pem"), file("notes.txt"), file("b.png"),
        ])
        XCTAssertEqual(drops.count, 4)
        XCTAssertEqual(drops[0], .addMedia([file("IMG_1.HEIC"), file("IMG_1.MOV"), file("b.png")]))
        XCTAssertEqual(drops[1], .installApp(file("Demo.app")))
        XCTAssertEqual(drops[2], .addRootCertificate(file("root.pem")))
        guard case .unsupported = drops[3] else { return XCTFail("notes.txt") }
    }

    // MARK: - Bundles

    func testTheSimulatorBuildReadsAsAnIOSSimulatorApp() throws {
        let bundle = try XCTUnwrap(SimulatorAppBundle.read(app: Self.simulatorApp))
        XCTAssertEqual(bundle.bundleIdentifier, "dev.devicehubpro.fixture.apps")
        XCTAssertEqual(bundle.title, "AQA Fixture")
        XCTAssertEqual(bundle.shortVersion, "1.2")
        XCTAssertEqual(bundle.version, "7")
        XCTAssertEqual(bundle.supportedPlatforms, ["iPhoneSimulator"])
        XCTAssertEqual(bundle.platformName, "iphonesimulator")
        XCTAssertEqual(bundle.build, .init(platform: .iOS, isSimulator: true))
        XCTAssertEqual(bundle.iconNames, ["AppIcon60x60", "AppIcon76x76"])
        XCTAssertNil(bundle.installProblem(runtimePlatform: "iOS"))
        XCTAssertEqual(
            bundle.installProblem(runtimePlatform: "tvOS"),
            "“AQA Fixture” is built for iOS simulators, not tvOS."
        )
        // Designed for iPad: an iOS simulator build runs on a visionOS
        // simulator (Apple's run destination; not captured, simctl decides).
        XCTAssertNil(bundle.installProblem(runtimePlatform: "xrOS"))
        XCTAssertEqual(
            bundle.installProblem(runtimePlatform: "watchOS"),
            "“AQA Fixture” is built for iOS simulators, not watchOS."
        )
    }

    func testTheDeviceBuildIsRefusedWithItsReason() throws {
        let bundle = try XCTUnwrap(SimulatorAppBundle.read(app: Self.deviceApp))
        XCTAssertEqual(bundle.supportedPlatforms, ["iPhoneOS"])
        XCTAssertEqual(bundle.build, .init(platform: .iOS, isSimulator: false))
        let problem = try XCTUnwrap(bundle.installProblem(runtimePlatform: "iOS"))
        XCTAssertTrue(problem.hasPrefix("“AQA Fixture” is built for iPhone and iPad devices, not for a simulator."), problem)
    }

    /// Without the platform keys, `DTPlatformName` decides; without either,
    /// the install goes ahead and simctl decides.
    func testPlatformKeys() throws {
        let deviceOnlyByName = SimulatorAppBundle(
            bundleIdentifier: "a", displayName: nil, bundleName: "A", shortVersion: nil, version: nil,
            supportedPlatforms: [], platformName: "appletvos", iconNames: []
        )
        XCTAssertEqual(deviceOnlyByName.build, .init(platform: .tvOS, isSimulator: false))
        XCTAssertNotNil(deviceOnlyByName.installProblem(runtimePlatform: "tvOS"))

        let unknown = SimulatorAppBundle(
            bundleIdentifier: "a", displayName: nil, bundleName: nil, shortVersion: nil, version: nil,
            supportedPlatforms: [], platformName: nil, iconNames: []
        )
        XCTAssertNil(unknown.build)
        XCTAssertNil(unknown.installProblem(runtimePlatform: "iOS"))
        XCTAssertEqual(SimulatorAppBundle.platform(ofRuntimePlatform: "xrOS"), .visionOS)
    }

    /// The icon: of the files the plist names, the one with the most pixels
    /// (the iPad icon, 152 px, over the iPhone one, 120 px).
    func testTheLargestListedIconWins() throws {
        let bundle = try XCTUnwrap(SimulatorAppBundle.read(app: Self.simulatorApp))
        let icon = try XCTUnwrap(bundle.iconFile(in: Self.simulatorApp))
        XCTAssertEqual(icon.lastPathComponent, "AppIcon76x76@2x~ipad.png")
        XCTAssertEqual(SimulatorAppBundle.pixelWidth(of: icon), 152)
        XCTAssertEqual(
            SimulatorAppBundle.pixelWidth(of: Self.simulatorApp.appendingPathComponent("AppIcon60x60@2x.png")),
            120
        )
        XCTAssertNil(bundle.iconFile(in: Self.deviceApp), "the device build's folder keeps no icon file")
    }

    func testIconFileNames() {
        let names = ["AppIcon60x60", "AppIconUpdated60x60"]
        for fileName in ["AppIcon60x60.png", "AppIcon60x60@2x.png", "AppIcon60x60@3x.png", "AppIcon60x60@2x~ipad.png", "AppIconUpdated60x60@2x.png", "AppIcon60x60~iphone.png"] {
            XCTAssertTrue(SimulatorAppBundle.isIcon(fileName, forNames: names), fileName)
        }
        for fileName in ["AppIcon60x60@2x.jpg", "AppIcon60x60-dark@2x.png", "AppIcon6@2x.png", "Other@2x.png", "AppIcon60x60@x2.png"] {
            XCTAssertFalse(SimulatorAppBundle.isIcon(fileName, forNames: names), fileName)
        }
        let bundle = SimulatorAppBundle(
            bundleIdentifier: nil, displayName: nil, bundleName: nil, shortVersion: nil, version: nil,
            supportedPlatforms: [], platformName: nil, iconNames: ["AppIcon60x60"]
        )
        let widths = ["AppIcon60x60@2x.png": 120, "AppIcon60x60@3x.png": 180, "AppIcon60x60.png": 60]
        XCTAssertEqual(bundle.iconFileName(among: Array(widths.keys) + ["Unreadable@2x.png"]) { widths[$0] }, "AppIcon60x60@3x.png")
        XCTAssertNil(bundle.iconFileName(among: ["AppIcon60x60@2x.png"]) { _ in nil }, "an unreadable file is skipped")
    }

    /// The legacy keys: top-level `CFBundleIconFiles` and `CFBundleIconFile`
    /// (with or without `.png`), deduplicated after the primary icons.
    func testLegacyIconKeys() throws {
        let plist: [String: Any] = [
            "CFBundleIcons": ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["AppIcon60x60"]]],
            "CFBundleIconFiles": ["Icon.png", "AppIcon60x60"],
            "CFBundleIconFile": "Legacy",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        XCTAssertEqual(SimulatorAppBundle.parse(infoPlist: data)?.iconNames, ["AppIcon60x60", "Icon", "Legacy"])
    }

    // MARK: - Archives

    /// An `.ipa` (`Payload/<app>`) and a zipped `.app` unzip to the app, made
    /// here from the fixture bundle with ditto, the way the Finder zips.
    func testArchivesUnzipToTheirApp() async throws {
        let work = try temporaryFolder()
        let payload = work.appendingPathComponent("ipa/Payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.simulatorApp, to: payload.appendingPathComponent("AQAAppsFixture.app"))
        let ipa = work.appendingPathComponent("AQAAppsFixture.ipa")
        try await zip(folder: payload, keepParent: true, to: ipa)
        let zipped = work.appendingPathComponent("AQAAppsFixture.zip")
        try await zip(folder: Self.simulatorApp, keepParent: true, to: zipped)

        for archive in [ipa, zipped] {
            let destination = work.appendingPathComponent("out-\(archive.pathExtension)", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let app = try await SimulatorAppArchive.extract(archive, into: destination)
            XCTAssertEqual(app.lastPathComponent, "AQAAppsFixture.app", archive.lastPathComponent)
            XCTAssertEqual(SimulatorAppBundle.read(app: app)?.bundleIdentifier, "dev.devicehubpro.fixture.apps")
        }
    }

    func testAnArchiveWithoutAnAppOrNotAZipFails() async throws {
        let work = try temporaryFolder()
        let folder = work.appendingPathComponent("Loose", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("text".utf8).write(to: folder.appendingPathComponent("readme.txt"))
        let noApp = work.appendingPathComponent("NoApp.zip")
        try await zip(folder: folder, keepParent: true, to: noApp)
        let destination = work.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            _ = try await SimulatorAppArchive.extract(noApp, into: destination)
            XCTFail("expected no app")
        } catch let failure as SimulatorAppArchive.Failure {
            XCTAssertEqual(failure, .noApp)
        }

        let notZip = work.appendingPathComponent("Broken.ipa")
        try Data("not a zip".utf8).write(to: notZip)
        let other = work.appendingPathComponent("out2", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        do {
            _ = try await SimulatorAppArchive.extract(notZip, into: other)
            XCTFail("expected an unreadable archive")
        } catch let failure as SimulatorAppArchive.Failure {
            guard case .unreadable = failure else { return XCTFail("\(failure)") }
        }
    }

    // MARK: - Helpers

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimulatorDropRoutingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func zip(folder: URL, keepParent: Bool, to archive: URL) async throws {
        var arguments = ["-c", "-k"]
        if keepParent { arguments.append("--keepParent") }
        let result = try await ProcessRunner.run(
            executable: SimulatorAppArchive.ditto,
            arguments: arguments + [folder.path, archive.path],
            timeout: .seconds(30)
        )
        XCTAssertEqual(result.exitCode, 0, result.standardErrorText)
    }
}
