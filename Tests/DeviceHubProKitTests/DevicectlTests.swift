import XCTest
@testable import DeviceHubProKit

/// devicectl's JSON documents and `DevicectlClient`, fed real captures.
///
/// The fixtures under `Fixtures/ios27-simulator/devicectl/` are the stdout
/// (`-j -`) and, where noted, stderr of devicectl 642.16 (CoreDevice 642.16,
/// JSON version 5, Xcode 27.0 27A266a), captured on 2026-09-25 through the
/// real binary inside CoreDevice.framework. CoreDevice does not see
/// simulators in a private `simctl --set` (the `.private-set` capture: error
/// 1000 for the private-set device of `SimctlFixtureTests`, booted), so the
/// others come from `DeviceHubPro-A-devicectl`, a throwaway iPhone 17 Pro
/// (iOS 27.0, 24A434) created for the capture in the default set, UDID
/// A89AEB35-14AC-4482-BA79-2DEB4D80A4B6, booted (inheriting the Mac's `tr_TR`
/// locale and `Europe/Istanbul` time zone), then deleted. Every call
/// carried `--device <that UDID> -j - -t 30`; no device was listed. The
/// captures hold no user name or path; they are byte-exact.
///
/// Capture order: `info details`, `info appearance` (light, defaults),
/// `settings appearance --mode dark`, `--reduce-motion on`, `info appearance`
/// again, then the failures: `--reduce-motion off --text-size
/// accessibility-large` (two flags: 21031 wrapping 21063, nothing applied),
/// `--text-size accessibility-large` alone (the same pair), and
/// `--reduce-motion true` (a usage error, exit 64, no JSON), then
/// `orientation get`.
final class DevicectlTests: XCTestCase {
    private static let udid = "A89AEB35-14AC-4482-BA79-2DEB4D80A4B6"

    private static func url(_ name: String) -> URL {
        SimctlFixtureTests.url("devicectl", name)
    }

    private static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    // MARK: - Documents

    /// `device info details`: identity from `properties`, 43 capabilities.
    func testInfoDetails() throws {
        let result = try DevicectlJSON.decode(DevicectlDeviceDetails.self, from: try Self.data("devicectl-device-info-details.json"))
        XCTAssertEqual(result.info.jsonVersion, 5)
        XCTAssertEqual(result.info.version, "642.16")
        XCTAssertEqual(result.info.commandType, "devicectl.device.info.details")
        XCTAssertEqual(result.info.arguments, [
            "devicectl", "device", "info", "details", "--device", Self.udid, "-j", "-", "-t", "30",
        ])

        let details = result.value
        XCTAssertEqual(details.identifier, Self.udid)
        XCTAssertEqual(details.udid, Self.udid)
        XCTAssertEqual(details.name, "DeviceHubPro-A-devicectl")
        XCTAssertEqual(details.bootState, "booted")
        XCTAssertEqual(details.osVersion, "27.0")
        XCTAssertEqual(details.osBuild, "24A434")
        XCTAssertEqual(details.marketingName, "iPhone 17 Pro")
        XCTAssertEqual(details.productType, "iPhone18,1")
        XCTAssertEqual(details.deviceType, "iPhone")
        XCTAssertEqual(details.platform, "iOS")
        XCTAssertTrue(details.isSimulator)
        XCTAssertEqual(details.visibilityClass, "simulators")
        XCTAssertEqual(details.supportedBiometrics, ["faceID"])
        XCTAssertEqual(details.capabilities.count, 43)
        XCTAssertTrue(details.supports("com.apple.coredevice.feature.sendmemorywarningtoprocess"))
        XCTAssertTrue(details.supports("com.apple.coredevice.feature.customizeappearancesettings"))
        XCTAssertFalse(details.supports("com.apple.coredevice.feature.doesnotexist"))
    }

    /// The same capture decoded twice more, edited in the test (not on disk):
    /// without the deprecated blocks (what `--omit-deprecated-fields-in-json`
    /// asks for) the values are unchanged, and without `properties` (a
    /// CoreDevice that only writes the deprecated blocks) they come from the
    /// deprecated `deviceProperties` / `hardwareProperties`.
    func testInfoDetailsReadsPropertiesFirstAndToleratesDeprecatedKeys() throws {
        let original = try Self.data("devicectl-device-info-details.json")
        let full = try DevicectlJSON.decode(DevicectlDeviceDetails.self, from: original).value

        let withoutDeprecated = try Self.editResult(original) { result in
            result.removeValue(forKey: "deviceProperties")
            result.removeValue(forKey: "hardwareProperties")
            result.removeValue(forKey: "connectionProperties")
            result.removeValue(forKey: "_deprecationNotice")
        }
        XCTAssertEqual(try DevicectlJSON.decode(DevicectlDeviceDetails.self, from: withoutDeprecated).value, full)

        let deprecatedOnly = try Self.editResult(original) { result in
            result.removeValue(forKey: "properties")
        }
        let legacy = try DevicectlJSON.decode(DevicectlDeviceDetails.self, from: deprecatedOnly).value
        XCTAssertEqual(legacy.name, "DeviceHubPro-A-devicectl")
        XCTAssertEqual(legacy.osVersion, "27.0")
        XCTAssertEqual(legacy.osBuild, "24A434")
        XCTAssertEqual(legacy.marketingName, "iPhone 17 Pro")
        XCTAssertEqual(legacy.reality, "simulated")
        XCTAssertEqual(legacy.visibilityClass, "simulators", "the top-level copy")
        XCTAssertEqual(legacy.supportedBiometrics, [], "only `properties` lists biometrics")
    }

    /// `device info appearance` on a new device, then after `--mode dark`
    /// and `--reduce-motion on`.
    func testInfoAppearance() throws {
        let before = try DevicectlJSON.decode(DevicectlAppearance.self, from: try Self.data("devicectl-device-info-appearance.json")).value
        XCTAssertEqual(before.userInterfaceStyle, "light")
        XCTAssertEqual(before.textSize, "Large")
        XCTAssertEqual(before.increaseContrast, false)
        XCTAssertEqual(before.reduceMotion, false)
        XCTAssertEqual(before.reduceTransparency, false)
        XCTAssertEqual(before.showBorders, false)
        XCTAssertEqual(before.colorFilter, false)
        XCTAssertEqual(before.largerAccessibilitySizesEnabled, false)
        XCTAssertEqual(before.lookAndFeel, "Liquid Glass")
        XCTAssertEqual(before.supportedLooksAndFeels, ["Liquid Glass"])
        XCTAssertEqual(before.liquidGlassOpacity, 0.5)

        let after = try DevicectlJSON.decode(
            DevicectlAppearance.self,
            from: try Self.data("devicectl-device-info-appearance.dark-reduce-motion.json")
        ).value
        XCTAssertEqual(after.userInterfaceStyle, "dark")
        XCTAssertEqual(after.reduceMotion, true)
        XCTAssertEqual(after.reduceTransparency, false)
    }

    /// A successful `settings appearance` echoes only what the call touched.
    func testSettingsAppearanceResults() throws {
        let dark = try DevicectlJSON.decode(
            DevicectlAppearance.self,
            from: try Self.data("devicectl-device-settings-appearance-mode-dark.json")
        )
        XCTAssertEqual(dark.info.outcome, "success")
        XCTAssertEqual(dark.value.userInterfaceStyle, "dark")
        XCTAssertNil(dark.value.reduceMotion)
        XCTAssertNil(dark.value.textSize)

        let motion = try DevicectlJSON.decode(
            DevicectlAppearance.self,
            from: try Self.data("devicectl-device-settings-appearance-reduce-motion-on.json")
        ).value
        XCTAssertEqual(motion.reduceMotion, true)
        XCTAssertEqual(motion.userInterfaceStyle, "dark")
    }

    /// Two flags in one call, one of them impossible: the whole call fails
    /// with 21031 wrapping 21063 (exit 1), and the stderr text says the same.
    func testMultiFlagAppearanceCallFailsAsAWhole() throws {
        XCTAssertThrowsError(try DevicectlJSON.decode(
            DevicectlAppearance.self,
            from: try Self.data("devicectl-device-settings-appearance-multi-flag.json")
        )) { error in
            guard let error = error as? DevicectlError else { return XCTFail("\(error)") }
            XCTAssertEqual(error.info?.outcome, "failed")
            XCTAssertEqual(error.domain, DevicectlError.coreDeviceDomain)
            XCTAssertEqual(error.code, DevicectlError.Code.appearanceChangeFailed)
            XCTAssertEqual(error.message, "Failed to set the device's appearance on device \(Self.udid).")
            XCTAssertEqual(error.frames.map(\.code), [21031, 21063])
            XCTAssertTrue(error.contains(code: DevicectlError.Code.largerAccessibilitySizesRequired))
            XCTAssertEqual(
                error.frames.last?.message,
                "Enable Larger Accessibility Sizes on the device before setting an accessibility text size."
            )
        }
        let stderr = try XCTUnwrap(String(data: try Self.data("devicectl-device-settings-appearance-multi-flag.stderr.txt"), encoding: .utf8))
        XCTAssertTrue(stderr.contains("error 21031") && stderr.contains("error 21063"))
    }

    /// An accessibility text size alone fails the same way until Larger
    /// Accessibility Sizes is on.
    func testAccessibilityTextSizeNeedsLargerSizesFirst() throws {
        XCTAssertThrowsError(try DevicectlJSON.decode(
            DevicectlAppearance.self,
            from: try Self.data("devicectl-device-settings-appearance-text-size-accessibility-large.json")
        )) { error in
            let error = error as? DevicectlError
            XCTAssertEqual(error?.frames.map(\.code), [21031, 21063])
        }
    }

    /// A simulator in a private set: "The specified device was not found".
    func testPrivateSetSimulatorIsNotFound() throws {
        XCTAssertThrowsError(try DevicectlJSON.decode(
            DevicectlDeviceDetails.self,
            from: try Self.data("devicectl-device-info-details.private-set.json")
        )) { error in
            guard let error = error as? DevicectlError else { return XCTFail("\(error)") }
            XCTAssertEqual(error.code, DevicectlError.Code.deviceNotFound)
            XCTAssertEqual(error.frames.count, 1)
            XCTAssertEqual(error.info?.jsonVersion, 5)
            XCTAssertEqual(
                error.message,
                "The specified device was not found. (Name: 95D9676B-3317-4BA5-8CF6-3CDD0488CACA)"
            )
        }
    }

    /// `device orientation get` on an iPhone home screen that never rotated.
    func testOrientation() throws {
        let orientation = try DevicectlJSON.decode(
            DevicectlOrientation.self,
            from: try Self.data("devicectl-device-orientation-get.json")
        ).value
        XCTAssertEqual(orientation.deviceOrientation, "unknown")
        XCTAssertEqual(orientation.deviceOrientationNonFlat, "portrait")
        XCTAssertEqual(orientation.deviceIsOrientationLocked, false)
    }

    func testEmptyOutputIsNoDocument() {
        XCTAssertThrowsError(try DevicectlJSON.decode(DevicectlOrientation.self, from: Data("\n".utf8))) { error in
            XCTAssertEqual(error as? DevicectlJSON.DecodeError, .noDocument)
        }
    }

    // MARK: - Client

    private func makeSimulator(udid: String = DevicectlTests.udid) throws -> SimulatorDevice {
        SimulatorDevice(
            udid: udid,
            name: "DeviceHubPro-A-devicectl",
            state: .booted,
            isAvailable: true,
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
        )
    }

    /// Every command carries the device, the JSON destination and the
    /// timeout, and an appearance call carries exactly one flag.
    func testEveryCommandAddressesTheSimulatorWithJSONAndATimeout() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("info details", stdoutFile: Self.url("devicectl-device-info-details.json")),
            .init("info appearance", stdoutFile: Self.url("devicectl-device-info-appearance.json")),
            .init("--mode dark", stdoutFile: Self.url("devicectl-device-settings-appearance-mode-dark.json")),
            .init("--reduce-motion on", stdoutFile: Self.url("devicectl-device-settings-appearance-reduce-motion-on.json")),
            .init("orientation get", stdoutFile: Self.url("devicectl-device-orientation-get.json")),
        ])
        let client = try DevicectlClient(
            devicectlURL: fake.executableURL,
            simulator: try makeSimulator(),
            commandTimeout: .seconds(30)
        )

        let details = try await client.details()
        XCTAssertEqual(details.value.marketingName, "iPhone 17 Pro")
        let appearance = try await client.appearance()
        XCTAssertEqual(appearance.value.userInterfaceStyle, "light")
        try await client.setAppearance(.dark(true))
        let motion = try await client.setAppearance(.reduceMotion(true))
        XCTAssertEqual(motion.value.reduceMotion, true)
        let orientation = try await client.orientation()
        XCTAssertEqual(orientation.value.deviceOrientationNonFlat, "portrait")

        let tail = ["--device", Self.udid, "-j", "-", "-t", "30"]
        XCTAssertEqual(fake.invocations, [
            ["device", "info", "details"] + tail,
            ["device", "info", "appearance"] + tail,
            ["device", "settings", "appearance", "--mode", "dark"] + tail,
            ["device", "settings", "appearance", "--reduce-motion", "on"] + tail,
            ["device", "orientation", "get"] + tail,
        ])
    }

    /// The captured failures surface as typed errors through the client.
    func testClientSurfacesDevicectlErrorsAndUsageErrors() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init(
                "--text-size",
                stdoutFile: Self.url("devicectl-device-settings-appearance-text-size-accessibility-large.json"),
                exitCode: 1
            ),
            .init(
                "--reduce-motion",
                stdoutFile: nil,
                stderrFile: Self.url("devicectl-device-settings-appearance-reduce-motion-true.stderr.txt"),
                exitCode: 64
            ),
        ])
        let client = try DevicectlClient(devicectlURL: fake.executableURL, simulator: try makeSimulator())
        do {
            try await client.setAppearance(.textSize(.accessibilityLarge))
            XCTFail("expected 21031")
        } catch let error as DevicectlError {
            XCTAssertTrue(error.contains(code: DevicectlError.Code.largerAccessibilitySizesRequired))
        }
        do {
            // The fake answers any --reduce-motion call with the captured
            // usage error for `--reduce-motion true`.
            try await client.setAppearance(.reduceMotion(false))
            XCTFail("expected the usage error")
        } catch let error as DevicectlClientError {
            XCTAssertEqual(error, .usage(
                exitCode: 64,
                message: "Error: The value 'true' is invalid for '--reduce-motion <reduce-motion>'. Please provide one of 'on' and 'off'."
            ))
        }
    }

    /// Toggles are spelled on/off (true/false is a usage error).
    func testAppearanceSettingArguments() {
        XCTAssertEqual(DevicectlAppearanceSetting.reduceMotion(true).arguments, ["--reduce-motion", "on"])
        XCTAssertEqual(DevicectlAppearanceSetting.reduceTransparency(false).arguments, ["--reduce-transparency", "off"])
        XCTAssertEqual(DevicectlAppearanceSetting.showBorders(true).arguments, ["--show-borders", "on"])
        XCTAssertEqual(DevicectlAppearanceSetting.dark(false).arguments, ["--mode", "light"])
        XCTAssertEqual(
            DevicectlAppearanceSetting.textSize(.extraExtraLarge).arguments,
            ["--text-size", "extra-extra-large"]
        )
        XCTAssertEqual(
            DevicectlAppearanceSetting.largerAccessibilitySizes(true).arguments,
            ["--larger-accessibility-sizes", "on"]
        )
    }

    /// The read-only content sizes are refused before devicectl runs, as
    /// `SimctlClient.setContentSize` refuses them.
    func testReadOnlyTextSizesAreRefusedBeforeRunning() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [])
        let client = try DevicectlClient(devicectlURL: fake.executableURL, simulator: try makeSimulator())
        for size in [SimulatorContentSize.unknown, .unsupported] {
            do {
                try await client.setAppearance(.textSize(size))
                XCTFail("\(size) must be refused")
            } catch let error as DevicectlClientError {
                XCTAssertEqual(error, .invalidValue("text size \(size.rawValue) cannot be set"))
            }
        }
        XCTAssertEqual(fake.calls, [])
    }

    /// Device enumeration and management never run, and a non-UUID
    /// identifier (a physical device's) is refused up front.
    func testEnumerationManagementAndNonSimulatorsAreRefused() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [])
        let client = try DevicectlClient(devicectlURL: fake.executableURL, simulator: try makeSimulator())
        for command in [["list", "devices"], ["manage", "pair"]] {
            do {
                _ = try await client.run(command, as: DevicectlOrientation.self)
                XCTFail("\(command) must be refused")
            } catch let error as DevicectlClientError {
                XCTAssertEqual(error, .refusedCommand(command.joined(separator: " ")))
            }
        }
        XCTAssertThrowsError(try DevicectlClient(
            devicectlURL: fake.executableURL,
            simulator: try makeSimulator(udid: "00008101-000A0C123456001E")
        ))
        XCTAssertEqual(fake.calls, [])
    }

    // MARK: Helpers

    private static func editResult(_ data: Data, _ edit: (inout [String: Any]) -> Void) throws -> Data {
        var document = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var result = try XCTUnwrap(document["result"] as? [String: Any])
        edit(&result)
        document["result"] = result
        return try JSONSerialization.data(withJSONObject: document)
    }
}
