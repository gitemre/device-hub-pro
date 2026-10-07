import XCTest
@testable import DeviceHubProKit

/// The simctl app, media, certificate and link calls (`SimctlClient+Apps`)
/// against byte-exact captures, and the argv production sends.
///
/// Provenance: unless a test says otherwise, captured on 2026-09-26 with
/// Xcode 27.0 (27A266a) and CoreSimulator 1171.7, running the real simctl
/// binary (not the `xcrun` wrapper) against `DeviceHubPro-UI-apps`, an iPhone 17
/// Pro on iOS 27.0 (24A434), UDID F5DE19D7-2EB5-4EFC-A3ED-E6C3D7E6935B, in the
/// default device set (created for the capture and deleted afterwards). The
/// Mac's locale is `tr_TR`, which is why the device-build install error is
/// in Turkish. The user app is `AQAAppsFixture` (bundle
/// `dev.devicehubpro.fixture.apps`, 1.2 (7)), a tiny UIKit app built for this
/// capture with `swiftc` for `arm64-apple-ios18.0-simulator` and ad hoc
/// signed; its device build (`arm64-apple-ios18.0`) was the one simctl
/// refused. Exit codes are noted beside each stderr fixture; stdout of the
/// successful `install`, `uninstall`, `addmedia`, `keychain` and `openurl`
/// calls was empty (0 bytes) and is not kept.
///
/// Redaction: the macOS user name inside paths is replaced with the
/// same-length placeholder `aqauser001`, and the scratch folder's
/// machine- and session-specific segment (`<tool>-<uid>/<project>/<session
/// UUID>`) with the same-length
/// `aqa-tmp-01/aqa-project-placeholder-01/aqa-session-placeholder-000000000000`;
/// nothing else was changed.
final class SimctlAppsFixtureTests: XCTestCase {
    static let udid = "F5DE19D7-2EB5-4EFC-A3ED-E6C3D7E6935B"
    static let bundle = "dev.devicehubpro.fixture.apps"

    private static func text(_ folder: String, _ name: String) throws -> String {
        try SimctlFixtureTests.text(folder, name)
    }

    // MARK: - Parsing

    /// `listapps <udid>` with the fixture app installed: the runtime's 39
    /// system apps plus the user app, which simctl marks as a removable
    /// developer app of type User with a data container and no groups.
    func testListAppsWithAUserApp() throws {
        let apps = try SimctlParsing.apps(fromListApps: try Self.text("simctl-core", "simctl-listapps.with-user-app.stdout.txt"))
        XCTAssertEqual(apps.count, 40)
        XCTAssertEqual(apps.filter { $0.applicationType == "System" }.count, 39)

        let app = try XCTUnwrap(apps.first { $0.bundleIdentifier == Self.bundle })
        XCTAssertEqual(app.title, "AQA Fixture")
        XCTAssertEqual(app.bundleName, "AQAAppsFixture")
        XCTAssertEqual(app.shortVersion, "1.2")
        XCTAssertEqual(app.version, "7")
        XCTAssertTrue(app.isUserApp)
        XCTAssertTrue(app.isDeveloperApp)
        XCTAssertTrue(app.isRemovable)
        XCTAssertFalse(app.isFirstParty)
        XCTAssertFalse(app.isHidden)
        XCTAssertFalse(app.isAppClip)
        XCTAssertEqual(app.groupContainers, [:])
        XCTAssertEqual(
            app.dataContainer?.path,
            "/Users/aqauser001/Library/Developer/CoreSimulator/Devices/\(Self.udid)/data/Containers/Data/Application/2431DF93-C88C-4040-86CC-14B749A24295"
        )
        XCTAssertTrue(app.path?.hasSuffix("/AQAAppsFixture.app") == true)

        // No system app is a developer app, removable, hidden or a clip on a
        // fresh iOS 27.0 simulator.
        let system = apps.filter { $0.applicationType == "System" }
        XCTAssertFalse(system.contains { $0.isDeveloperApp || $0.isRemovable || $0.isHidden || $0.isAppClip })
    }

    /// `appinfo` on the user app prints the same dictionary `listapps` does.
    func testAppInfoOfAUserApp() throws {
        let app = try SimctlParsing.app(fromAppInfo: try Self.text("simctl-core", "simctl-appinfo-user-app.stdout.txt"))
        let listed = try SimctlParsing.apps(fromListApps: try Self.text("simctl-core", "simctl-listapps.with-user-app.stdout.txt"))
            .first { $0.bundleIdentifier == Self.bundle }
        XCTAssertEqual(app, listed)
    }

    /// `get_app_container <udid> <bundle> data` prints the container
    /// `listapps` names, without the trailing slash of its URL.
    func testDataContainerOfAUserApp() throws {
        let printed = try Self.text("simctl-core", "simctl-get_app_container-user-data.stdout.txt")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let app = try SimctlParsing.app(fromAppInfo: try Self.text("simctl-core", "simctl-appinfo-user-app.stdout.txt"))
        XCTAssertEqual(printed, app.dataContainer?.path)
    }

    // MARK: - Failures

    /// A shut-down device: `listapps` and `install` fail with SimError 405
    /// (exit 149) before anything is copied.
    func testAppsNeedABootedDevice() throws {
        for (command, name) in [("listapps", "simctl-listapps-shutdown.stderr.txt"), ("install", "simctl-install-shutdown.stderr.txt")] {
            let failure = SimctlErrors.failure(
                arguments: [command, Self.udid],
                exitCode: 149,
                standardError: try Self.text("simctl-core", name)
            )
            XCTAssertEqual(failure.kind, .invalidState, name)
            XCTAssertEqual(failure.message, "Unable to lookup in current state: Shutdown", name)
        }
    }

    /// `install` of a device build (exit 4): IXUserPresentableErrorDomain 4,
    /// in the Mac's language, naming the executable's platforms.
    func testInstallOfADeviceBuild() throws {
        let failure = SimctlErrors.failure(
            arguments: ["install", Self.udid, "/tmp/AQAAppsFixture.app"],
            exitCode: 4,
            standardError: try Self.text("simctl-core", "simctl-install-device-build.stderr.txt")
        )
        XCTAssertEqual(failure.error, SimctlErrorReference(domain: "IXUserPresentableErrorDomain", code: 4))
        XCTAssertEqual(failure.kind, .other)
        XCTAssertTrue(failure.message.hasPrefix("App installation failed: “AQA Fixture”"), failure.message)
        XCTAssertEqual(failure.underlying, [SimctlErrorReference(domain: "IXUserPresentableErrorDomain", code: 4)])
        XCTAssertTrue(
            try Self.text("simctl-core", "simctl-install-device-build.stderr.txt")
                .contains("This device can run code for these platforms: iOS-simulator")
        )
    }

    /// `launch` of an app that is not installed (exit 4) and `openurl` of a
    /// scheme nothing handles (exit 115).
    func testLaunchAndOpenURLFailures() throws {
        let launch = SimctlErrors.failure(
            arguments: ["launch", Self.udid, Self.bundle],
            exitCode: 4,
            standardError: try Self.text("simctl-core", "simctl-launch-not-installed.stderr.txt")
        )
        XCTAssertEqual(launch.error, SimctlErrorReference(domain: "FBSOpenApplicationServiceErrorDomain", code: 4))
        XCTAssertEqual(launch.message, "Simulator device failed to launch dev.devicehubpro.fixture.apps.")

        let openURL = SimctlErrors.failure(
            arguments: ["openurl", Self.udid, "nosuchscheme-aqa://x"],
            exitCode: 115,
            standardError: try Self.text("simctl-core", "simctl-openurl-unknown-scheme.stderr.txt")
        )
        XCTAssertEqual(openURL.error, SimctlErrorReference(domain: "LSApplicationWorkspaceErrorDomain", code: 115))
        XCTAssertEqual(openURL.message, "Simulator device failed to open nosuchscheme-aqa://x.")
        XCTAssertEqual(SimctlErrors.exitStatus(forErrorCode: 115), 115)
    }

    /// `addmedia` of a file it cannot import (exit 133): the header says
    /// "see stderr", the line before it names the file. A shut-down device
    /// fails the same way, with no line naming a file.
    func testAddMediaFailures() throws {
        let unsupported = SimctlErrors.failure(
            arguments: ["addmedia", Self.udid, "notes.txt"],
            exitCode: 133,
            standardError: try Self.text("controls", "simctl-addmedia-unsupported.stderr.txt")
        )
        XCTAssertEqual(unsupported.error, SimctlErrorReference(domain: "com.apple.CoreSimulator.LaunchdSimError", code: 133))
        XCTAssertEqual(unsupported.message, "Multiple errors were returned; see stderr")
        XCTAssertTrue(
            try Self.text("controls", "simctl-addmedia-unsupported.stderr.txt")
                .hasPrefix("Failed to import '/private/tmp/aqa-tmp-01/")
        )

        let shutDown = SimctlErrors.failure(
            arguments: ["addmedia", Self.udid, "photo.png"],
            exitCode: 133,
            standardError: try Self.text("controls", "simctl-addmedia-shutdown.stderr.txt")
        )
        XCTAssertEqual(shutDown.error?.code, 133)
        XCTAssertEqual(shutDown.message, "Multiple errors were returned; see stderr")

        // What tells them apart: the line naming the file.
        XCTAssertEqual(unsupported.leadingLines.count, 1)
        XCTAssertTrue(unsupported.leadingLines[0].hasPrefix("Failed to import '/private/tmp/aqa-tmp-01/"), unsupported.leadingLines[0])
        XCTAssertTrue(unsupported.leadingLines[0].hasSuffix("File type unsupported."), unsupported.leadingLines[0])
        XCTAssertEqual(shutDown.leadingLines, [])
    }

    /// `keychain … add-root-cert` of a file that is no certificate (exit 22).
    func testRootCertificateOfANonCertificate() throws {
        let failure = SimctlErrors.failure(
            arguments: ["keychain", Self.udid, "add-root-cert", "notes.txt"],
            exitCode: 22,
            standardError: try Self.text("controls", "simctl-keychain-add-root-cert-invalid.stderr.txt")
        )
        XCTAssertEqual(failure.kind, .invalidArgument)
        XCTAssertEqual(failure.message, "Simulator device failed to complete the requested operation.")
        XCTAssertEqual(failure.underlying, [SimctlErrorReference(domain: "NSPOSIXErrorDomain", code: 22)])
    }

    /// `create` with a device type the runtime does not support (exit 147):
    /// the complaint on stdout, SimError 403 "Incompatible device" on stderr.
    func testCreateOfAnIncompatiblePair() throws {
        XCTAssertTrue(
            try Self.text("simctl-core", "simctl-create-incompatible.stdout.txt")
                .hasPrefix("Unable to create a device for device type: iPhone 17 Pro")
        )
        let failure = SimctlErrors.failure(
            arguments: ["create", "x", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "com.apple.CoreSimulator.SimRuntime.tvOS-27-0"],
            exitCode: 147,
            standardError: try Self.text("simctl-core", "simctl-create-incompatible.stderr.txt")
        )
        XCTAssertEqual(failure.error, SimctlErrorReference(domain: "com.apple.CoreSimulator.SimError", code: 403))
        XCTAssertEqual(failure.message, "Incompatible device")
        XCTAssertEqual(SimctlErrors.exitStatus(forErrorCode: 403), 147)
    }

    // MARK: - Argv

    /// Each call names the UDID and hands simctl absolute paths or the link.
    func testArgv() async throws {
        let fake = try FakeTool(name: "simctl", rules: [])
        let client = SimctlClient(simctlURL: fake.executableURL)
        let app = URL(fileURLWithPath: "/tmp/Fixture Folder/AQAAppsFixture.app", isDirectory: true)
        try await client.install(udid: Self.udid, app: app)
        try await client.uninstall(udid: Self.udid, bundleIdentifier: Self.bundle)
        try await client.addMedia(udid: Self.udid, files: [
            URL(fileURLWithPath: "/tmp/IMG_0001.HEIC"),
            URL(fileURLWithPath: "/tmp/IMG_0001.MOV"),
        ])
        try await client.addRootCertificate(udid: Self.udid, certificate: URL(fileURLWithPath: "/tmp/root.pem"))
        try await client.resetKeychain(udid: Self.udid)
        try await client.openURL(udid: Self.udid, url: try XCTUnwrap(URL(string: "aqaapps://hello?from=simctl")))
        try await client.openURL(udid: Self.udid, url: try XCTUnwrap(URL(string: "https://example.com/a b".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")))
        XCTAssertEqual(fake.invocations, [
            ["install", Self.udid, "/tmp/Fixture Folder/AQAAppsFixture.app"],
            ["uninstall", Self.udid, Self.bundle],
            ["addmedia", Self.udid, "/tmp/IMG_0001.HEIC", "/tmp/IMG_0001.MOV"],
            ["keychain", Self.udid, "add-root-cert", "/tmp/root.pem"],
            ["keychain", Self.udid, "reset"],
            ["openurl", Self.udid, "aqaapps://hello?from=simctl"],
            ["openurl", Self.udid, "https://example.com/a%20b"],
        ])
    }

    /// What simctl would misread is refused before it runs: a file URL to
    /// `openurl`, a link to `install`, an empty media list, a bundle
    /// identifier with a space or an option's dash, and a non-UDID.
    func testInvalidArgumentsAreRefused() async throws {
        let fake = try FakeTool(name: "simctl", rules: [])
        let client = SimctlClient(simctlURL: fake.executableURL)
        let web = try XCTUnwrap(URL(string: "https://example.com"))
        await XCTAssertThrowsErrorAsync(try await client.openURL(udid: Self.udid, url: URL(fileURLWithPath: "/tmp/a.html")))
        await XCTAssertThrowsErrorAsync(try await client.openURL(udid: Self.udid, url: try XCTUnwrap(URL(string: "no-scheme"))))
        await XCTAssertThrowsErrorAsync(try await client.install(udid: Self.udid, app: web))
        await XCTAssertThrowsErrorAsync(try await client.addMedia(udid: Self.udid, files: []))
        await XCTAssertThrowsErrorAsync(try await client.addMedia(udid: Self.udid, files: [web]))
        await XCTAssertThrowsErrorAsync(try await client.uninstall(udid: Self.udid, bundleIdentifier: "a b"))
        await XCTAssertThrowsErrorAsync(try await client.uninstall(udid: Self.udid, bundleIdentifier: "-x"))
        await XCTAssertThrowsErrorAsync(try await client.uninstall(udid: Self.udid, bundleIdentifier: ""))
        await XCTAssertThrowsErrorAsync(try await client.install(udid: "iPhone 17 Pro", app: URL(fileURLWithPath: "/tmp/A.app")))
        await XCTAssertThrowsErrorAsync(try await client.resetKeychain(udid: "booted"))
        XCTAssertEqual(fake.invocations, [])
    }

    /// A failed call surfaces its decoded failure: `install` on the device
    /// build replays the real stderr and exit 4.
    func testAFailedInstallThrowsItsFailure() async throws {
        let fake = try FakeTool(name: "simctl", rules: [
            .init(
                "install",
                stdoutFile: nil,
                stderrFile: SimctlFixtureTests.url("simctl-core", "simctl-install-device-build.stderr.txt"),
                exitCode: 4
            ),
        ])
        let client = SimctlClient(simctlURL: fake.executableURL)
        do {
            try await client.install(udid: Self.udid, app: URL(fileURLWithPath: "/tmp/AQAAppsFixture.app"))
            XCTFail("expected the install to fail")
        } catch let failure as SimctlFailure {
            XCTAssertEqual(failure.error?.domain, "IXUserPresentableErrorDomain")
            XCTAssertEqual(failure.exitCode, 4)
        }
    }
}
