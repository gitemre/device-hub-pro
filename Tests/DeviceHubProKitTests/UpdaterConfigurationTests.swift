import DeviceHubProKit
import Foundation
import XCTest

/// The Sparkle keys of packaging/Info.plist and the rule that decides whether
/// the packaged app runs an updater. `Scripts/package-app.sh` fills the two
/// values from DHP_APPCAST_URL and DHP_SPARKLE_PUBLIC_KEY; the
/// template keeps them empty.
final class UpdaterConfigurationTests: XCTestCase {
    private let key = "dzBN7oweVb0L7eblKSnL8nJqawBOo58TOzVTkQB6EG0="

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func templatePlist() throws -> [String: Any] {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("packaging/Info.plist"))
        return try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }

    func testTheTemplateCarriesEmptySparkleKeysAndAutomaticChecksOn() throws {
        let plist = try templatePlist()
        XCTAssertEqual(plist["SUFeedURL"] as? String, "", "the checked-in template must not name a feed; package-app.sh fills it")
        XCTAssertEqual(plist["SUPublicEDKey"] as? String, "", "a public key is filled at build time, never committed with a feed")
        XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, true)
    }

    func testTheTemplateAloneRunsNoUpdater() throws {
        XCTAssertFalse(UpdaterConfiguration(infoDictionary: try templatePlist()).isEnabled)
    }

    func testNoInfoDictionaryRunsNoUpdater() {
        XCTAssertFalse(UpdaterConfiguration(infoDictionary: nil).isEnabled)
        XCTAssertFalse(UpdaterConfiguration(infoDictionary: [:]).isEnabled)
    }

    func testAFeedAndAKeyEnableTheUpdater() {
        let configuration = UpdaterConfiguration(infoDictionary: [
            "SUFeedURL": "https://example.test/appcast.xml", "SUPublicEDKey": key,
        ])
        XCTAssertTrue(configuration.isEnabled)
        XCTAssertEqual(configuration.feedURL?.absoluteString, "https://example.test/appcast.xml")
        XCTAssertEqual(configuration.publicKey, key)
    }

    func testOneWithoutTheOtherKeepsTheUpdaterOff() {
        XCTAssertFalse(UpdaterConfiguration(infoDictionary: ["SUFeedURL": "https://example.test/a.xml", "SUPublicEDKey": ""]).isEnabled)
        XCTAssertFalse(UpdaterConfiguration(infoDictionary: ["SUFeedURL": "", "SUPublicEDKey": key]).isEnabled)
    }

    func testAFeedThatIsNotHTTPSKeepsTheUpdaterOff() {
        for feed in ["http://example.test/a.xml", "ftp://example.test/a.xml", "not a url", "https://", "   "] {
            XCTAssertFalse(
                UpdaterConfiguration(infoDictionary: ["SUFeedURL": feed, "SUPublicEDKey": key]).isEnabled,
                "\(feed) must not enable the updater"
            )
        }
    }

    func testWhitespaceAroundTheValuesIsIgnored() {
        let configuration = UpdaterConfiguration(infoDictionary: [
            "SUFeedURL": " https://example.test/a.xml\n", "SUPublicEDKey": " \(key) ",
        ])
        XCTAssertTrue(configuration.isEnabled)
        XCTAssertEqual(configuration.publicKey, key)
    }

    func testTheRunningTestBundleHasNoUpdater() {
        XCTAssertFalse(UpdaterConfiguration.current.isEnabled)
    }

    func testPackagingScriptsSignSparkleInsideOutWithoutDeep() throws {
        let script = try String(contentsOf: repositoryRoot.appendingPathComponent("Scripts/package-app.sh"), encoding: .utf8)
        let xpc = try XCTUnwrap(script.range(of: "XPCServices/*.xpc"))
        let autoupdate = try XCTUnwrap(script.range(of: "$sparkle_b/Autoupdate\""))
        let updater = try XCTUnwrap(script.range(of: "$sparkle_b/Updater.app\""))
        let framework = try XCTUnwrap(script.range(of: "codesign \"${code_sign_flags[@]}\" \"$sparkle\""))
        let app = try XCTUnwrap(script.range(of: "codesign \"${app_flags[@]}\" \"$app\""))
        XCTAssertLessThan(xpc.lowerBound, autoupdate.lowerBound)
        XCTAssertLessThan(autoupdate.lowerBound, updater.lowerBound)
        XCTAssertLessThan(updater.lowerBound, framework.lowerBound)
        XCTAssertLessThan(framework.lowerBound, app.lowerBound)
        XCTAssertFalse(script.contains("codesign --deep"), "Sparkle must not be signed with --deep")
        XCTAssertFalse(script.contains("--force --deep"))
    }

    // MARK: Scripts/release.sh (the parts that need no build)

    private func runRelease(_ arguments: [String], environment: [String: String] = [:]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [repositoryRoot.appendingPathComponent("Scripts/release.sh").path] + arguments
        process.currentDirectoryURL = repositoryRoot
        var env = ProcessInfo.processInfo.environment
        for key in ["DHP_SIGN_IDENTITY", "DHP_APPCAST_URL", "DHP_SPARKLE_PUBLIC_KEY", "DHP_DOWNLOAD_BASE_URL"] {
            env[key] = nil
        }
        env.merge(environment) { _, new in new }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testReleaseScriptHelpExitsCleanly() throws {
        let result = try runRelease(["--help"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("--dry-run"))
    }

    func testReleaseScriptRefusesAnUnknownOption() throws {
        let result = try runRelease(["--bogus"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("unknown option"))
    }

    func testARealReleaseNeedsADeveloperIDIdentityBeforeBuildingAnything() throws {
        let result = try runRelease([])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("no signing identity"), result.output)

        let wrong = try runRelease(["--identity", "Apple Development: Someone (ABCDE12345)"])
        XCTAssertNotEqual(wrong.status, 0)
        XCTAssertTrue(wrong.output.contains("Developer ID Application"), wrong.output)
    }
}
