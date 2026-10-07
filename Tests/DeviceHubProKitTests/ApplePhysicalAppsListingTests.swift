import XCTest
@testable import DeviceHubProKit

/// The Kit side of the Apps tab's "All Apps" scope (`device info apps
/// --include-default-apps`), real app icons (`device info appIcon`) and the
/// three details the Device Hub-style Info card adds (ECID, serial number,
/// capacity).
///
/// `devicectl-info-apps-default-apps.json`, `devicectl-info-appIcon.json` and
/// `devicectl-info-appIcon-missing.json` are captures of devicectl 642.16
/// (CoreDevice 642.16, JSON version 5, Xcode 27.0) from the dedicated
/// test iPhone (iPhone 12, iOS 27.0), taken 2026-09-29, byte-exact apart from
/// the same-length placeholders of the earlier fixtures (UDID, device
/// identifier, the Mac user name; the bundle folders' UUIDs are random per
/// install and kept). The apps list is trimmed from 81 entries to ten, in
/// their captured order and bytes (one of each kind the tests use: developer
/// builds, removable and non-removable default apps, a third-party app, one
/// without a version); only whole entries and their separators were cut.
final class ApplePhysicalAppsListingTests: XCTestCase {
    private static let id = ApplePhysicalDeviceTests.coreDeviceIdentifier

    private func url(_ name: String) -> URL { ApplePhysicalDeviceTests.url(name) }
    private func data(_ name: String) throws -> Data { try ApplePhysicalDeviceTests.data(name) }

    private func makeClient(_ fake: FakeTool) throws -> DevicectlPhysicalClient {
        try DevicectlPhysicalClient(
            devicectlURL: fake.executableURL,
            device: try ApplePhysicalDeviceTests.device(),
            commandTimeout: .seconds(30)
        )
    }

    // MARK: - Apps

    func testTheDefaultListingKeepsItsOldArgv() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("info apps", jsonOutputFile: url("devicectl-info-apps.json")),
        ])
        _ = try await makeClient(fake).apps()
        let argv = try XCTUnwrap(fake.invocations.first)
        XCTAssertEqual(Array(argv.prefix(3)), ["device", "info", "apps"])
        XCTAssertFalse(argv.contains("--include-default-apps"))
        XCTAssertEqual(Array(argv.dropFirst(10)), [])
    }

    /// HELP-DERIVED Xcode 27.0 (27A266a): `devicectl device info apps -h` documents `--include-all-apps`
    /// ("Display all apps"); the JSON body is the existing apps fixture's shape.
    func testIncludeAllAddsExactlyTheIncludeAllAppsFlag() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("info apps", jsonOutputFile: url("devicectl-info-apps-default-apps.json")),
        ])
        _ = try await makeClient(fake).apps(includeAll: true)
        let argv = try XCTUnwrap(fake.invocations.first)
        XCTAssertEqual(Array(argv.prefix(3)), ["device", "info", "apps"])
        XCTAssertEqual(Array(argv.dropFirst(10)), ["--include-all-apps"])
    }

    func testAllAppsAddsExactlyTheIncludeDefaultAppsFlag() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("info apps", jsonOutputFile: url("devicectl-info-apps-default-apps.json")),
        ])
        let result = try await makeClient(fake).apps(includeDefaultApps: true).value
        let argv = try XCTUnwrap(fake.invocations.first)
        XCTAssertEqual(Array(argv.prefix(3)), ["device", "info", "apps"])
        XCTAssertEqual(Array(argv[3...5]), ["--device", Self.id, "--json-output"])
        XCTAssertEqual(Array(argv[7...9]), ["-q", "-t", "30"])
        XCTAssertEqual(Array(argv.dropFirst(10)), ["--include-default-apps"])
        // Measured: devicectl 642.16 answers `defaultAppsIncluded: false` even with the flag, and
        // lists the system apps anyway; the app decides the scope by the argv it sent, never by this key.
        XCTAssertEqual(result.defaultAppsIncluded, false)
        XCTAssertTrue(result.apps.contains { $0.defaultApp == true })
        XCTAssertEqual(result.apps.count, 10)
    }

    /// The capture's entries: what "User Apps" and "All Apps" and the context
    /// menu tell apart.
    func testTheDefaultAppsCaptureDecodes() throws {
        let list = try DevicectlJSON.decode(DevicectlAppList.self, from: try data("devicectl-info-apps-default-apps.json")).value
        func app(_ id: String) throws -> DevicectlInstalledApp {
            try XCTUnwrap(list.apps.first { $0.bundleIdentifier == id }, id)
        }
        let verifier = try app("com.devicehubpro.verifier")
        XCTAssertEqual(verifier.builtByDeveloper, true)
        XCTAssertEqual(verifier.defaultApp, false)
        XCTAssertEqual(verifier.removable, true)
        XCTAssertEqual(verifier.containerAccessible, true)
        let calculator = try app("com.apple.calculator")
        XCTAssertEqual(calculator.defaultApp, true)
        XCTAssertEqual(calculator.removable, true)
        XCTAssertEqual(calculator.builtByDeveloper, false)
        XCTAssertEqual(calculator.version, "12.0")
        let bluetooth = try app("com.apple.BluetoothUIService")
        XCTAssertEqual(bluetooth.removable, false)
        XCTAssertEqual(bluetooth.defaultApp, true)
        let thirdParty = try app("com.example.app")
        XCTAssertEqual(thirdParty.defaultApp, false)
        XCTAssertEqual(thirdParty.builtByDeveloper, false)
        XCTAssertEqual(thirdParty.removable, true)
        XCTAssertNil(try app("com.apple.ShortcutsActions").version, "some system apps carry no short version")
    }

    // MARK: - Icons

    func testAppIconArgvAndResult() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("info appIcon", jsonOutputFile: url("devicectl-info-appIcon.json")),
        ])
        let destination = URL(fileURLWithPath: "/tmp/icons/x.png")
        let result = try await makeClient(fake).appIcon(
            bundleID: "com.apple.calculator", width: 64, height: 64, to: destination
        ).value
        let argv = try XCTUnwrap(fake.invocations.first)
        XCTAssertEqual(Array(argv.prefix(3)), ["device", "info", "appIcon"])
        XCTAssertEqual(Array(argv[3...5]), ["--device", Self.id, "--json-output"])
        XCTAssertEqual(Array(argv[7...9]), ["-q", "-t", "30"])
        XCTAssertEqual(Array(argv.dropFirst(10)), [
            "--app-bundle-id", "com.apple.calculator", "--width", "64", "--height", "64",
            "--destination", "/tmp/icons/x.png",
        ])
        ApplePhysicalDeviceTests.assertSafeArguments(argv)
        XCTAssertEqual(result.icon?.placeholder, false)
        XCTAssertEqual(result.icon?.pixelSize?.width, 64)
        XCTAssertEqual(result.icon?.pixelSize?.height, 64)
        XCTAssertEqual(result.icon?.scale, 1)
        XCTAssertTrue(result.destination?.hasSuffix("/raw/icon-calculator.png") == true)
    }

    /// An app the device does not know is CoreDevice error 6003.
    func testAnUnknownAppIsAnError() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("info appIcon", jsonOutputFile: url("devicectl-info-appIcon-missing.json"), exitCode: 1),
        ])
        do {
            _ = try await makeClient(fake).appIcon(
                bundleID: "com.example.notinstalled", width: 64, height: 64, to: URL(fileURLWithPath: "/tmp/x.png")
            )
            XCTFail("an app that is not installed has no icon")
        } catch let error as DevicectlError {
            XCTAssertEqual(error.frames.first?.code, 6003)
        }
    }

    /// The icon call is one fixed shape; everything else under `info
    /// appIcon`, and the apps flag on any other read, is refused before
    /// devicectl runs.
    func testMalformedIconAndAppsShapesAreRefused() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [])
        let client = try makeClient(fake)
        let bundle = "com.apple.calculator"
        let refused: [[String]] = [
            ["device", "info", "appIcon"],
            ["device", "info", "appIcon", "--app-bundle-id", bundle],
            ["device", "info", "appIcon", "--app-bundle-id", bundle, "--width", "64", "--height", "64"],
            // Not a PNG, an option as a path, a size out of range, an app path, placeholders.
            ["device", "info", "appIcon", "--app-bundle-id", bundle, "--width", "64", "--height", "64", "--destination", "/tmp/x.jpg"],
            ["device", "info", "appIcon", "--app-bundle-id", bundle, "--width", "64", "--height", "64", "--destination", "-x.png"],
            ["device", "info", "appIcon", "--app-bundle-id", bundle, "--width", "0", "--height", "64", "--destination", "/tmp/x.png"],
            ["device", "info", "appIcon", "--app-bundle-id", bundle, "--width", "64", "--height", "9999", "--destination", "/tmp/x.png"],
            ["device", "info", "appIcon", "--app-bundle-id", "-a", "--width", "64", "--height", "64", "--destination", "/tmp/x.png"],
            ["device", "info", "appIcon", "--app-path", "/x", "--width", "64", "--height", "64", "--destination", "/tmp/x.png"],
            ["device", "info", "appIcon", "--app-bundle-id", bundle, "--width", "64", "--height", "64", "--destination", "/tmp/x.png", "--allow-placeholder", "true"],
            ["device", "info", "appIcon", "--app-bundle-id", bundle, "--height", "64", "--width", "64", "--destination", "/tmp/x.png"],
            // The apps flag: only on `apps`, only that one.
            ["device", "info", "apps", "--include-app-clips"],
            ["device", "info", "apps", "--include-default-apps", "--include-app-clips"],
            ["device", "info", "apps", "--include-container-paths"],
            ["device", "info", "apps", "--include-all-apps", "--include-default-apps"],
            ["device", "info", "processes", "--include-all-apps"],
            ["device", "info", "processes", "--include-default-apps"],
            ["device", "info", "details", "--include-default-apps"],
        ]
        for command in refused {
            do {
                _ = try await client.run(command, as: DevicectlIgnoredResult.self)
                XCTFail("\(command) must be refused")
            } catch let error as DevicectlClientError {
                XCTAssertEqual(error, .refusedCommand(command.joined(separator: " ")), "\(command)")
            }
        }
        XCTAssertEqual(fake.calls, [], "devicectl never ran")
    }

    func testTheTypedIconCallRefusesMalformedValues() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [])
        let client = try makeClient(fake)
        let png = URL(fileURLWithPath: "/tmp/x.png")
        do {
            _ = try await client.appIcon(bundleID: "--all", width: 64, height: 64, to: png)
            XCTFail("bundle")
        } catch is DevicectlClientError {}
        do {
            _ = try await client.appIcon(bundleID: "com.a.b", width: 0, height: 64, to: png)
            XCTFail("size")
        } catch is DevicectlClientError {}
        do {
            _ = try await client.appIcon(bundleID: "com.a.b", width: 64, height: 64, to: URL(fileURLWithPath: "/tmp/x.tiff"))
            XCTFail("suffix")
        } catch is DevicectlClientError {}
        XCTAssertEqual(fake.calls, [])
    }

    // MARK: - Details

    /// The Info card's Capacity, ECID, Serial Number and UDID come from the
    /// captured `details` (placeholders: the same-length ones of the fixture).
    func testDetailsCarryEcidSerialAndCapacity() throws {
        let details = try DevicectlJSON.decode(DevicectlDeviceDetails.self, from: try data("devicectl-info-details.json")).value
        XCTAssertEqual(details.ecid, "1000000000000000")
        XCTAssertEqual(details.serialNumber, "AQASERIAL000")
        XCTAssertEqual(details.internalStorageCapacity, 64_000_000_000)
        XCTAssertEqual(details.udid, "00000000-0000000000000000")
    }

    /// A simulator's details have none of them.
    func testASimulatorsDetailsHaveNoEcidOrCapacity() throws {
        let data = try Data(contentsOf: ApplePhysicalDeviceTests.url("devicectl-info-details.json"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var result = try XCTUnwrap(object["result"] as? [String: Any])
        var properties = try XCTUnwrap(result["properties"] as? [String: Any])
        var hardware = try XCTUnwrap(properties["hardware"] as? [String: Any])
        for key in ["ecid", "serialNumber", "internalStorageCapacity"] { hardware.removeValue(forKey: key) }
        properties["hardware"] = hardware
        result["properties"] = properties
        result.removeValue(forKey: "hardwareProperties")
        object["result"] = result
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let details = try DevicectlJSON.decode(DevicectlDeviceDetails.self, from: stripped).value
        XCTAssertNil(details.ecid)
        XCTAssertNil(details.serialNumber)
        XCTAssertNil(details.internalStorageCapacity)
    }
}
