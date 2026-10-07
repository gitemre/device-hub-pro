import XCTest
@testable import DeviceHubProKit

/// The physical-iPhone Kit: `ApplePhysicalDeviceLister`,
/// `DevicectlPhysicalClient` and the decoders, fed real captures.
///
/// The fixtures under `Fixtures/ios27-device/` are byte-exact captures of
/// devicectl 642.16 (CoreDevice 642.16, JSON version 5, Xcode 27.0) from the
/// the dedicated test iPhone (an iPhone 12 on iOS 27.0, paired, Developer
/// Mode on, wired), taken on 2026-09-28 with `list devices` and the nine
/// read-only `device info` subcommands, each with `--json-output` and `-q`.
/// Two kinds of edits were made, both the AGENTS.md exceptions: personal
/// identifiers were replaced by same-length placeholders (the UDID
/// `00000000-0000000000000000`, the CoreDevice identifier
/// `00000000-0000-4000-8000-000000000001`, the serial `AQASERIAL000`, the
/// device name and one hostname label `aqa-test-...`, the ECID `1000...`, the
/// tunnel IPv6 address with its hex zeroed, and the macOS user name
/// `aqauser001`), and nothing was trimmed. The list capture also holds the
/// the machine's simulators (`reality` is `simulated`); the parser tests prove they
/// are dropped. `info audio` is the captured 1001 failure: this iPhone lacks
/// the audio output selection capability. The fixtures added
/// (the actions, `info files`, `copy from`, the app list after an install)
/// are byte-exact captures with the same same-length placeholders; the loading
/// tests are in `ApplePhysicalActionTests`.
final class ApplePhysicalDeviceTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ios27-device", isDirectory: true)

    static let udid = "00000000-0000000000000000"
    static let coreDeviceIdentifier = "00000000-0000-4000-8000-000000000001"

    static func url(_ name: String) -> URL {
        root.appendingPathComponent(name)
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    static func optIn(_ udids: String...) throws -> PhysicalDeviceOptIn {
        try XCTUnwrap(PhysicalDeviceOptIn(allowedHardwareUDIDs: udids))
    }

    /// The test iPhone as the lister reads it from the list capture.
    static func device() throws -> ApplePhysicalDevice {
        let devices = try ApplePhysicalDeviceLister.devices(
            fromListJSON: try data("devicectl-list-devices.json"),
            optIn: try optIn(udid)
        )
        return try XCTUnwrap(devices.first)
    }

    // MARK: - The list document

    func testListParsesThePhysicalDevice() throws {
        let devices = try ApplePhysicalDeviceLister.devices(
            fromListJSON: try Self.data("devicectl-list-devices.json"),
            optIn: try Self.optIn(Self.udid)
        )
        XCTAssertEqual(devices.count, 1)
        let device = try XCTUnwrap(devices.first)
        XCTAssertEqual(device.coreDeviceIdentifier, Self.coreDeviceIdentifier)
        XCTAssertEqual(device.hardwareUDID, Self.udid)
        XCTAssertEqual(device.name, "aqa-test-phon")
        XCTAssertEqual(device.productType, "iPhone13,2")
        XCTAssertEqual(device.marketingName, "iPhone 12")
        XCTAssertEqual(device.osVersion, "27.0")
        XCTAssertEqual(device.pairingState, "paired")
        XCTAssertEqual(device.tunnelState, "connected")
        XCTAssertEqual(device.transport, "wired")
        XCTAssertEqual(device.developerModeStatus, "enabled")
        XCTAssertEqual(device.ddiServicesAvailable, true)
        XCTAssertTrue(device.isPaired)
        XCTAssertTrue(device.isConnected)
    }

    /// The test iPhone captured right after `manage unpair` (Xcode 27.0, iOS 27.0),
    /// reduced to the phone's entry, with the identifiers, its name and its paths
    /// replaced by same-length placeholders and the hostnames emptied. An unpaired
    /// phone carries no `reality` (only paired devices say "physical"), so the
    /// lister knows it by its ECID; it is still an iPhone the Pair Nearby Device
    /// sheet offers.
    func testAnUnpairedPhoneWithoutRealityIsListed() throws {
        let devices = try ApplePhysicalDeviceLister.devices(
            fromListJSON: try Self.data("devicectl-list-devices-unpaired.json"),
            optIn: try Self.optIn(Self.udid)
        )
        let device = try XCTUnwrap(devices.first)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(device.hardwareUDID, Self.udid)
        XCTAssertEqual(device.productType, "iPhone13,2")
        XCTAssertEqual(device.pairingState, "unpaired")
        XCTAssertEqual(device.transport, "wired")
        XCTAssertFalse(device.isPaired)
        XCTAssertFalse(device.isConnected, "an unpaired phone on the cable is not usable")
        XCTAssertTrue(device.isUnpairedPhone)
    }

    /// A paired phone on the cable whose idle tunnel CoreDevice closed still counts as
    /// connected (the next command opens the tunnel); over the network it does not,
    /// and a restarting phone ("unavailable") never does.
    func testAPairedWiredPhoneIsConnectedWhileItsTunnelIsIdle() throws {
        func device(tunnel: String, transport: String) throws -> ApplePhysicalDevice {
            var document = try XCTUnwrap(JSONSerialization.jsonObject(with: try Self.data("devicectl-list-devices.json")) as? [String: Any])
            var result = try XCTUnwrap(document["result"] as? [String: Any])
            var entries = try XCTUnwrap(result["devices"] as? [[String: Any]])
            for index in entries.indices where (entries[index]["hardwareProperties"] as? [String: Any])?["udid"] as? String == Self.udid {
                var connection = try XCTUnwrap(entries[index]["connectionProperties"] as? [String: Any])
                connection["tunnelState"] = tunnel
                connection["transportType"] = transport
                entries[index]["connectionProperties"] = connection
                var properties = try XCTUnwrap(entries[index]["properties"] as? [String: Any])
                var modern = properties["connection"] as? [String: Any] ?? [:]
                modern["transportType"] = transport
                properties["connection"] = modern
                entries[index]["properties"] = properties
            }
            result["devices"] = entries
            document["result"] = result
            let data = try JSONSerialization.data(withJSONObject: document)
            return try XCTUnwrap(ApplePhysicalDeviceLister.devices(fromListJSON: data, optIn: try Self.optIn(Self.udid)).first)
        }
        XCTAssertTrue(try device(tunnel: "disconnected", transport: "wired").isConnected)
        XCTAssertFalse(try device(tunnel: "disconnected", transport: "localNetwork").isConnected)
        XCTAssertFalse(try device(tunnel: "unavailable", transport: "wired").isConnected)
    }

    /// The capture lists the machine's simulators beside the phone. Whatever the
    /// opt-in names, a simulator never comes back.
    func testListDropsEverySimulatedEntry() throws {
        let data = try Self.data("devicectl-list-devices.json")
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(document["result"] as? [String: Any])
        let entries = try XCTUnwrap(result["devices"] as? [[String: Any]])
        func reality(_ entry: [String: Any]) -> String? {
            (entry["hardwareProperties"] as? [String: Any])?["reality"] as? String
        }
        let simulators = entries.filter { reality($0) == "simulated" }
        XCTAssertEqual(entries.count, 19)
        XCTAssertEqual(simulators.count, 18, "the capture holds the physical phone and 18 simulators")

        let simulatorUDIDs = simulators.compactMap {
            ($0["hardwareProperties"] as? [String: Any])?["udid"] as? String
        }
        XCTAssertEqual(simulatorUDIDs.count, 18)
        // An opt-in naming every simulator and the phone still yields the phone only.
        let everything = try XCTUnwrap(PhysicalDeviceOptIn(allowedHardwareUDIDs: simulatorUDIDs + [Self.udid]))
        let devices = try ApplePhysicalDeviceLister.devices(fromListJSON: data, optIn: everything)
        XCTAssertEqual(devices.map(\.hardwareUDID), [Self.udid])
        // An opt-in naming only simulators yields nothing.
        let onlySimulators = try XCTUnwrap(PhysicalDeviceOptIn(allowedHardwareUDIDs: simulatorUDIDs))
        XCTAssertEqual(try ApplePhysicalDeviceLister.devices(fromListJSON: data, optIn: onlySimulators), [])
    }

    func testListReturnsOnlyOptedInUDIDs() throws {
        let data = try Self.data("devicectl-list-devices.json")
        let other = try Self.optIn("00000000-1111111111111111")
        XCTAssertEqual(try ApplePhysicalDeviceLister.devices(fromListJSON: data, optIn: other), [])
        // Case and whitespace do not matter to the opt-in.
        let lower = try Self.optIn(" " + Self.udid.lowercased() + "\n")
        XCTAssertEqual(try ApplePhysicalDeviceLister.devices(fromListJSON: data, optIn: lower).count, 1)
    }

    func testAnOptInThatNamesNothingIsNotAValue() {
        XCTAssertNil(PhysicalDeviceOptIn(allowedHardwareUDIDs: [String]()))
        XCTAssertNil(PhysicalDeviceOptIn(allowedHardwareUDIDs: ["", "  "]))
    }

    /// The app's user opt-in lists every physical entry and still never a
    /// simulator; it is its own value, apart from the named-UDID form, whose
    /// empty case stays "not a value".
    func testEveryPhysicalDeviceOptInListsAllPhysicalEntriesAndNoSimulator() throws {
        let data = try Self.data("devicectl-list-devices.json")
        let optIn = PhysicalDeviceOptIn.everyPhysicalDevice
        XCTAssertTrue(optIn.listsEveryPhysicalDevice)
        XCTAssertNil(optIn.allowedHardwareUDIDs)
        XCTAssertNotEqual(optIn, try Self.optIn(Self.udid))
        XCTAssertFalse(try Self.optIn(Self.udid).listsEveryPhysicalDevice)
        XCTAssertEqual(try Self.optIn(Self.udid).allowedHardwareUDIDs, [Self.udid])
        let devices = try ApplePhysicalDeviceLister.devices(fromListJSON: data, optIn: optIn)
        XCTAssertEqual(devices.map(\.hardwareUDID), [Self.udid], "the 18 simulators of the capture are dropped")
        XCTAssertNil(PhysicalDeviceOptIn(allowedHardwareUDIDs: [String]()), "the named form still needs a name")
    }

    /// The lister runs with the every-device opt-in like with a named one:
    /// one counted call.
    func testEveryPhysicalDeviceOptInRunsOneCountedListCall() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("list devices", jsonOutputFile: Self.url("devicectl-list-devices.json")),
        ])
        let before = ApplePhysicalDeviceLister.listCallCount
        let lister = ApplePhysicalDeviceLister(devicectlURL: fake.executableURL, commandTimeout: .seconds(20))
        let devices = try await lister.list(optIn: .everyPhysicalDevice)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(ApplePhysicalDeviceLister.listCallCount, before + 1)
        XCTAssertEqual(fake.invocations.count, 1)
    }

    /// `properties` is read first, but a device whose `properties` block is
    /// unreadable still comes back from the deprecated blocks.
    func testListToleratesADamagedPropertiesBlock() throws {
        let original = try Self.data("devicectl-list-devices.json")
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var result = try XCTUnwrap(document["result"] as? [String: Any])
        var entries = try XCTUnwrap(result["devices"] as? [[String: Any]])
        let index = try XCTUnwrap(entries.firstIndex {
            ($0["hardwareProperties"] as? [String: Any])?["reality"] as? String == "physical"
        })
        entries[index]["properties"] = "unexpected"
        entries.append(["identifier": 5])  // a wrongly shaped entry drops alone
        result["devices"] = entries
        document["result"] = result
        let edited = try JSONSerialization.data(withJSONObject: document)
        let device = try XCTUnwrap(
            ApplePhysicalDeviceLister.devices(fromListJSON: edited, optIn: try Self.optIn(Self.udid)).first
        )
        XCTAssertEqual(device.marketingName, "iPhone 12")
        XCTAssertEqual(device.osVersion, "27.0")
        XCTAssertEqual(device.pairingState, "paired")
        XCTAssertEqual(device.developerModeStatus, "enabled")
    }

    // MARK: - The lister's calls

    /// No opt-in, no call: the counter does not move and the binary is never
    /// started (the path does not exist).
    func testNoOptInMakesNoListCall() async throws {
        let before = ApplePhysicalDeviceLister.listCallCount
        let lister = ApplePhysicalDeviceLister(devicectlURL: URL(fileURLWithPath: "/nonexistent/devicectl"))
        let devices = try await lister.list(optIn: nil)
        XCTAssertEqual(devices, [])
        XCTAssertEqual(ApplePhysicalDeviceLister.listCallCount, before)
    }

    /// With an opt-in the lister runs `list devices` once, with the JSON
    /// written to a file, and returns the opted-in device.
    func testOptInRunsOneListCallAndFiltersTheAnswer() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("list devices", jsonOutputFile: Self.url("devicectl-list-devices.json")),
        ])
        let before = ApplePhysicalDeviceLister.listCallCount
        let lister = ApplePhysicalDeviceLister(devicectlURL: fake.executableURL, commandTimeout: .seconds(20))
        let devices = try await lister.list(optIn: try Self.optIn(Self.udid))
        XCTAssertEqual(devices.map(\.coreDeviceIdentifier), [Self.coreDeviceIdentifier])
        XCTAssertEqual(ApplePhysicalDeviceLister.listCallCount, before + 1)

        let argv = try XCTUnwrap(fake.invocations.first)
        XCTAssertEqual(fake.invocations.count, 1)
        XCTAssertEqual(Array(argv.prefix(3)), ["list", "devices", "--json-output"])
        XCTAssertTrue(argv[3].hasSuffix(".json"))
        XCTAssertEqual(Array(argv.suffix(3)), ["-q", "-t", "20"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: argv[3]), "the temporary file is removed")
        Self.assertSafeArguments(argv)
    }

    func testAListUsageErrorSurfaces() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("list devices", stdoutFile: nil, stderrFile: nil, exitCode: 64),
        ])
        let lister = ApplePhysicalDeviceLister(devicectlURL: fake.executableURL)
        do {
            _ = try await lister.list(optIn: try Self.optIn(Self.udid))
            XCTFail("expected a usage error")
        } catch let error as DevicectlClientError {
            XCTAssertEqual(error, .usage(exitCode: 64, message: ""))
        }
    }

    // MARK: - The client

    private func makeClient(_ fake: FakeTool) throws -> DevicectlPhysicalClient {
        try DevicectlPhysicalClient(
            devicectlURL: fake.executableURL,
            device: try Self.device(),
            commandTimeout: .seconds(30)
        )
    }

    /// Argv hygiene for every physical call: an explicit device, a JSON
    /// file, never an implicit selector or an xcrun wrapper.
    static func assertSafeArguments(_ argv: [String], file: StaticString = #filePath, line: UInt = #line) {
        for word in ["booted", "all", "unavailable", "xcrun"] {
            XCTAssertFalse(argv.contains(word), "\(word) in \(argv)", file: file, line: line)
        }
        XCTAssertFalse(argv.contains { $0.hasPrefix("booted") }, file: file, line: line)
    }

    func testEveryInfoCallAddressesTheDeviceWithAJSONFile() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("info details", jsonOutputFile: Self.url("devicectl-info-details.json")),
            .init("info apps", jsonOutputFile: Self.url("devicectl-info-apps.json")),
            .init("info processes", jsonOutputFile: Self.url("devicectl-info-processes.json")),
            .init("info displays", jsonOutputFile: Self.url("devicectl-info-displays.json")),
            .init("info lockState", jsonOutputFile: Self.url("devicectl-info-lockState.json")),
            .init("info appearance", jsonOutputFile: Self.url("devicectl-info-appearance.json")),
            .init("info voiceover", jsonOutputFile: Self.url("devicectl-info-voiceover.json")),
            .init("info ddiServices", jsonOutputFile: Self.url("devicectl-info-ddiServices.json")),
        ])
        let client = try makeClient(fake)

        _ = try await client.details()
        _ = try await client.apps()
        _ = try await client.processes()
        _ = try await client.displays()
        _ = try await client.lockState()
        _ = try await client.appearance()
        _ = try await client.voiceover()
        _ = try await client.ddiServices()

        let expected = ["details", "apps", "processes", "displays", "lockState", "appearance", "voiceover", "ddiServices"]
        XCTAssertEqual(fake.invocations.map { Array($0.prefix(3)) }, expected.map { ["device", "info", $0] })
        for argv in fake.invocations {
            XCTAssertEqual(Array(argv[3...5]), ["--device", Self.coreDeviceIdentifier, "--json-output"])
            XCTAssertTrue(argv[6].hasSuffix(".json"))
            XCTAssertEqual(Array(argv.suffix(3)), ["-q", "-t", "30"])
            XCTAssertEqual(argv.count, 10)
            XCTAssertFalse(FileManager.default.fileExists(atPath: argv[6]), "the temporary file is removed")
            Self.assertSafeArguments(argv)
        }
    }

    // MARK: - Decoding the captures

    func testDecodesInfoDetails() throws {
        let result = try DevicectlJSON.decode(DevicectlDeviceDetails.self, from: try Self.data("devicectl-info-details.json"))
        XCTAssertEqual(result.info.commandType, "devicectl.device.info.details")
        XCTAssertEqual(result.info.jsonVersion, 5)
        XCTAssertEqual(result.info.version, "642.16")
        let details = result.value
        XCTAssertEqual(details.identifier, Self.coreDeviceIdentifier)
        XCTAssertEqual(details.udid, Self.udid)
        XCTAssertEqual(details.name, "aqa-test-phon")
        XCTAssertEqual(details.marketingName, "iPhone 12")
        XCTAssertEqual(details.productType, "iPhone13,2")
        XCTAssertEqual(details.osVersion, "27.0")
        XCTAssertEqual(details.osBuild, "24A5380h")
        XCTAssertEqual(details.reality, "physical")
        XCTAssertFalse(details.isSimulator)
        XCTAssertEqual(details.supportedBiometrics, ["faceID"])
        XCTAssertEqual(details.visibilityClass, "default")
        XCTAssertEqual(details.capabilities.count, 65)
        XCTAssertTrue(details.supports("com.apple.coredevice.feature.capturescreenshot"))
        XCTAssertFalse(details.supports("com.apple.coredevice.feature.audiooutput"))
    }

    func testDecodesInfoApps() throws {
        let apps = try DevicectlJSON.decode(DevicectlAppList.self, from: try Self.data("devicectl-info-apps.json")).value
        XCTAssertEqual(apps.deviceIdentifier, Self.coreDeviceIdentifier)
        XCTAssertEqual(apps.apps, [])
        XCTAssertEqual(apps.defaultAppsIncluded, false)
        XCTAssertEqual(apps.hiddenAppsIncluded, false)
        XCTAssertEqual(apps.internalAppsIncluded, false)
        XCTAssertEqual(apps.removableAppsIncluded, true)
    }

    func testDecodesInfoProcesses() throws {
        let processes = try DevicectlJSON.decode(
            DevicectlProcessList.self,
            from: try Self.data("devicectl-info-processes.json")
        ).value
        XCTAssertEqual(processes.deviceIdentifier, Self.coreDeviceIdentifier)
        XCTAssertGreaterThan(processes.runningProcesses.count, 100)
        XCTAssertEqual(processes.runningProcesses.first, DevicectlRunningProcess(
            executable: "file:///sbin/launchd",
            processIdentifier: 1
        ))
    }

    func testDecodesInfoDisplays() throws {
        let displays = try DevicectlJSON.decode(DevicectlDisplays.self, from: try Self.data("devicectl-info-displays.json")).value
        XCTAssertEqual(displays.backlightState, "activeOn")
        XCTAssertEqual(displays.displays.count, 1)
        let display = try XCTUnwrap(displays.displays.first)
        XCTAssertEqual(display.displayId, 1)
        XCTAssertEqual(display.name, "LCD")
        XCTAssertEqual(display.primary, true)
        XCTAssertEqual(display.bounds, [[0, 0], [1170, 2532]])
        XCTAssertEqual(display.nativeSize, [1170, 2532])
        XCTAssertEqual(display.pointScale, 3)
        XCTAssertEqual(display.chromeIdentifier, "com.apple.dt.devicekit.chrome.phone4")
        XCTAssertEqual(display.currentOrientation, "rot0")
        XCTAssertEqual(display.nativeOrientation, "rot0")
        XCTAssertEqual(display.physicalSize?.count, 2)
        XCTAssertEqual(displays.orientation?.currentDeviceOrientation, "portrait")
        XCTAssertEqual(displays.orientation?.currentDeviceNonFlatOrientation, "portrait")
        XCTAssertEqual(displays.orientation?.currentDeviceOrientationLocked, false)
    }

    func testDecodesInfoLockState() throws {
        let lock = try DevicectlJSON.decode(DevicectlLockState.self, from: try Self.data("devicectl-info-lockState.json")).value
        XCTAssertEqual(lock.deviceIdentifier, Self.coreDeviceIdentifier)
        XCTAssertEqual(lock.passcodeRequired, false)
        XCTAssertEqual(lock.unlockedSinceBoot, true)
    }

    func testDecodesInfoAppearance() throws {
        let appearance = try DevicectlJSON.decode(DevicectlAppearance.self, from: try Self.data("devicectl-info-appearance.json")).value
        XCTAssertEqual(appearance.deviceIdentifier, Self.coreDeviceIdentifier)
        XCTAssertEqual(appearance.userInterfaceStyle, "light")
        XCTAssertEqual(appearance.textSize, "Large")
        XCTAssertEqual(appearance.largerAccessibilitySizesEnabled, true)
        XCTAssertEqual(appearance.increaseContrast, false)
        XCTAssertEqual(appearance.reduceMotion, false)
        XCTAssertEqual(appearance.reduceTransparency, false)
        XCTAssertEqual(appearance.showBorders, false)
        XCTAssertEqual(appearance.colorFilter, false)
        XCTAssertEqual(appearance.lookAndFeel, "Liquid Glass")
        XCTAssertEqual(appearance.liquidGlassOpacity, 0.5)
    }

    func testDecodesInfoVoiceOver() throws {
        let voiceover = try DevicectlJSON.decode(DevicectlVoiceOver.self, from: try Self.data("devicectl-info-voiceover.json")).value
        XCTAssertEqual(voiceover.deviceIdentifier, Self.coreDeviceIdentifier)
        XCTAssertFalse(voiceover.enabled)
        XCTAssertEqual(voiceover.operation, "query")
    }

    func testDecodesInfoDDIServices() throws {
        let result = try DevicectlJSON.decode(DevicectlDDIServices.self, from: try Self.data("devicectl-info-ddiServices.json")).value
        XCTAssertEqual(result.deviceIdentifier, Self.coreDeviceIdentifier)
        let ddi = try XCTUnwrap(result.ddiMetadata)
        XCTAssertEqual(ddi.buildUpdate, "27A266a")
        XCTAssertEqual(ddi.platform, "iOS")
        XCTAssertEqual(ddi.variant, "external")
        XCTAssertEqual(ddi.isUsable, true)
        XCTAssertEqual(ddi.isCryptexDDI, true)
        XCTAssertEqual(ddi.contentIsCompatible, true)
        XCTAssertEqual(ddi.developmentRevision, 0)
        XCTAssertEqual(ddi.enforcingCoreDeviceVersionChecks, true)
        XCTAssertEqual(ddi.projectMetadata.count, 11)
        XCTAssertEqual(ddi.projectMetadata.first(where: { $0.name == "CoreDevice" })?.version, "642.16")
    }

    /// The whole capture set decodes through the client, and a decoder never
    /// needs a key the capture lacks.
    func testEveryCaptureDecodesThroughTheClient() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("info details", jsonOutputFile: Self.url("devicectl-info-details.json")),
            .init("info apps", jsonOutputFile: Self.url("devicectl-info-apps.json")),
            .init("info processes", jsonOutputFile: Self.url("devicectl-info-processes.json")),
            .init("info displays", jsonOutputFile: Self.url("devicectl-info-displays.json")),
            .init("info lockState", jsonOutputFile: Self.url("devicectl-info-lockState.json")),
            .init("info appearance", jsonOutputFile: Self.url("devicectl-info-appearance.json")),
            .init("info voiceover", jsonOutputFile: Self.url("devicectl-info-voiceover.json")),
            .init("info ddiServices", jsonOutputFile: Self.url("devicectl-info-ddiServices.json")),
        ])
        let client = try makeClient(fake)
        let details = try await client.details()
        XCTAssertEqual(details.value.marketingName, "iPhone 12")
        let apps = try await client.apps()
        XCTAssertEqual(apps.value.apps, [])
        let lock = try await client.lockState()
        XCTAssertEqual(lock.value.unlockedSinceBoot, true)
        let ddi = try await client.ddiServices()
        XCTAssertEqual(ddi.value.ddiMetadata?.isUsable, true)
    }

    // MARK: - Errors

    /// The captured `info audio`: CoreDevice 1001 with the capability's
    /// feature identifier, as a typed error.
    func testAudioIsAnUnsupportedCapability() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("info audio", jsonOutputFile: Self.url("devicectl-info-audio.json"), exitCode: 1),
        ])
        let client = try makeClient(fake)
        do {
            _ = try await client.audio()
            XCTFail("expected an unsupported capability")
        } catch let error as DevicectlPhysicalError {
            XCTAssertEqual(error, .unsupportedCapability(
                featureIdentifier: "com.apple.coredevice.feature.audiooutput",
                name: "Audio Output Device Selection"
            ))
        }
    }

    /// The frames of the same document keep the 1001 code and its message.
    func testTheAudioCaptureDecodesAsADevicectlError() throws {
        do {
            _ = try DevicectlJSON.decode(DevicectlAudio.self, from: try Self.data("devicectl-info-audio.json"))
            XCTFail("expected an error")
        } catch let error as DevicectlError {
            XCTAssertEqual(error.code, DevicectlError.Code.capabilityNotSupported)
            XCTAssertEqual(error.domain, DevicectlError.coreDeviceDomain)
            XCTAssertEqual(error.frames.first?.capabilityFeatureIdentifier, "com.apple.coredevice.feature.audiooutput")
            XCTAssertEqual(error.frames.first?.capabilityName, "Audio Output Device Selection")
        }
    }

    func testAUsageErrorSurfaces() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("info details", stdoutFile: nil, stderrFile: nil, exitCode: 64),
        ])
        do {
            _ = try await makeClient(fake).details()
            XCTFail("expected a usage error")
        } catch let error as DevicectlClientError {
            XCTAssertEqual(error, .usage(exitCode: 64, message: ""))
        }
    }

    // MARK: - Refusals

    /// Enumeration, management, pairing and every subcommand the client does
    /// not allow are refused before devicectl runs (the allowed actions and
    /// their malformed shapes are covered in `ApplePhysicalActionTests`).
    func testRefusalsNeverReachDevicectl() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [])
        let client = try makeClient(fake)
        let refused: [[String]] = [
            ["list", "devices"],
            ["manage", "pair", "--columns", "*"],
            ["manage", "ddis"],
            ["device", "manage", "unpair"],
            ["device", "pair"],
            ["device", "unpair"],
            ["device", "settings", "reset"],
            ["device", "settings", "biometrics"],
            ["device", "install", "app"],
            ["device", "uninstall", "app"],
            ["device", "process", "launch"],
            ["device", "copy", "to"],
            ["device", "reboot", "--style", "full"],
            ["device", "info", "list"],
            // Not on the closed read-only list, and not a refusal word either.
            ["device", "info", "unknownThing"],
            ["device", "info"],
            ["device", "info", "details", "extra"],
            [],
        ]
        for command in refused {
            do {
                _ = try await client.run(command, as: DevicectlLockState.self)
                XCTFail("\(command) must be refused")
            } catch let error as DevicectlClientError {
                XCTAssertEqual(error, .refusedCommand(command.joined(separator: " ")))
            }
        }
        XCTAssertEqual(fake.calls, [], "devicectl never ran")
    }

    func testTheRefusalListCoversTheDangerousSubcommands() {
        for word in ["list", "manage", "pair", "reset", "settings"] {
            XCTAssertTrue(DevicectlPhysicalClient.refusedCommands.contains(word), word)
        }
    }

    /// Only a UUID CoreDevice identifier is accepted for the device, and no
    /// call to the lister's document is needed to bind a client.
    func testTheClientIsBoundToTheListedDevice() throws {
        let fake = try FakeTool(name: "devicectl", rules: [])
        let client = try makeClient(fake)
        XCTAssertEqual(client.device.coreDeviceIdentifier, Self.coreDeviceIdentifier)
        XCTAssertEqual(DevicectlPhysicalInfoSubcommand.allCases.count, 9)
    }
}
