import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// What the app hands a problem report about itself (`AppModel+ProblemReport`):
/// its adb and emulator, the inventory's rows, one entry per window, the
/// preferences as yes/no and the values the scrubber must remove.
@MainActor
final class ProblemReportStateTests: XCTestCase {
    func testTheInputsNameTheAdbAndEmulatorTheModelUses() throws {
        let stub = try makeStubAdb(arms: "")
        let model = AppModel.testing(adb: stub.client)

        let inputs = model.problemReportInputs()

        XCTAssertEqual(inputs.adbURL, stub.client.adbURL)
        XCTAssertEqual(inputs.emulatorURL?.path, "/usr/bin/false")
    }

    func testWithoutAnAdbTheInputsHaveNone() {
        let model = AppModel.testing(emulator: nil)

        let inputs = model.problemReportInputs()

        XCTAssertNil(inputs.adbURL)
        XCTAssertNil(inputs.emulatorURL)
    }

    /// A client that never found an adb has no path to offer: the report says
    /// "can't find adb" instead of naming a placeholder.
    func testAnUnresolvedAdbClientIsNoAdb() {
        let model = AppModel.testing(adb: AdbClient.unresolved())

        XCTAssertNil(model.problemReportInputs().adbURL)
    }

    func testTheSnapshotCopiesTheInventoryAndNeverAsksADevice() throws {
        let model = AppModel.testing()
        model.inventory.setRealDevices([
            .online("emulator-5554", transport: "1"),
            AndroidDevice(serial: "0a1b2c3d4e5f", state: "device", model: "2209116AG"),
        ])
        model.inventory.deviceInfos["0a1b2c3d4e5f"] = DeviceInfo(
            serial: "0a1b2c3d4e5f", model: "2209116AG", manufacturer: "Xiaomi", androidVersion: "14",
            apiLevel: "34", abi: "arm64-v8a", isEmulator: false
        )
        model.inventory.avdNamesBySerial["emulator-5554"] = (transportID: "1", avd: "Pixel_8_Pro")

        let state = model.problemReportState()

        XCTAssertEqual(state.devices.map(\.serial), ["emulator-5554", "0a1b2c3d4e5f"])
        XCTAssertEqual(state.androidVersions, ["0a1b2c3d4e5f": "14"], "a phone's version, never an emulator's")
        XCTAssertEqual(state.consoleNames, ["emulator-5554": "Pixel_8_Pro"])
        XCTAssertNil(state.emulatorListAvds, "the list was not read yet")
        XCTAssertFalse(state.adbAvailable)
        XCTAssertFalse(state.adbServerProblem)
        XCTAssertEqual(state.adbRestarts, 0)
        XCTAssertEqual(state.localNetworkAccess, "unknown")
        XCTAssertEqual(state.startingAvds, [])
    }

    func testTheEmulatorListIsCopiedOnceItWasRead() {
        let model = AppModel.testing()
        model.catalog.avds = ["Pixel_8_Pro", "Pixel_9"]
        model.catalog.avdsLoaded = true

        XCTAssertEqual(model.problemReportState().emulatorListAvds, ["Pixel_8_Pro", "Pixel_9"])
    }

    /// One entry per window, and what it shows by kind: never a serial or a
    /// UDID.
    func testEachWindowIsDescribedByKindNeverBySerial() throws {
        let model = AppModel.testing()
        model.inventory.avdNamesBySerial["emulator-5554"] = (transportID: nil, avd: "Pixel_8_Pro")
        let second = DeviceWorkspace(services: model.services)
        model.registry.register(second)

        XCTAssertEqual(model.problemReportState().windows.map(\.selection), ["none", "none"])

        model.workspace.deviceSelection = .device("0a1b2c3d4e5f")
        second.deviceSelection = .device("emulator-5554")
        let windows = model.problemReportState().windows
        XCTAssertEqual(windows.map(\.selection), ["phone", "emulator"])
        XCTAssertNil(windows[0].avd)
        XCTAssertEqual(windows[1].avd, "Pixel_8_Pro", "the AVD behind an emulator's console")
        let json = String(decoding: try JSONEncoder().encode(windows), as: UTF8.self)
        XCTAssertFalse(json.contains("0a1b2c3d4e5f"))
        XCTAssertFalse(json.contains("emulator-5554"))
    }

    func testSelectionKinds() {
        XCTAssertEqual(AppModel.problemReportSelection(nil).kind, "none")
        XCTAssertEqual(AppModel.problemReportSelection(.avd("Pixel_8_Pro")).kind, "emulator")
        XCTAssertEqual(AppModel.problemReportSelection(.avd("Pixel_8_Pro")).avd, "Pixel_8_Pro")
        XCTAssertEqual(AppModel.problemReportSelection(.device("emulator-5556")).kind, "emulator")
        XCTAssertEqual(AppModel.problemReportSelection(.device("192.168.1.5:5555")).kind, "phone")
        XCTAssertEqual(AppModel.problemReportSelection(.pixel("pixel_8")).kind, "Pixel catalog")
        XCTAssertEqual(AppModel.problemReportSelection(.simulator("425BD068-3D87-4F27-BE58-EB56A58B2C3A")).kind, "simulator")
        XCTAssertEqual(AppModel.problemReportSelection(.physicalApple("00008101-001E30590A0A001E")).kind, "iPhone or iPad")
    }

    /// The preferences are yes/no and counts: no path, no team, no identifier.
    func testPreferencesAreYesNoAndCountsOnly() throws {
        let defaults = UserDefaults.scratch()
        defaults.set("/Volumes/Tools/emulator", forKey: AppPreferences.Keys.emulatorBinaryPath)
        defaults.set("/Volumes/Tools/sdk", forKey: AppPreferences.Keys.androidSDKPath)
        defaults.set("ABCDE12345", forKey: AppPreferences.Keys.physicalControlTeamID)
        defaults.set(["00000000-0000000000000000", "00000000-0000000000000001"], forKey: AppPreferences.Keys.enabledPhysicalAppleDevices)
        defaults.set(true, forKey: AppPreferences.Keys.localNetworkInUse)
        let model = AppModel.testing(defaults: defaults)

        let preferences = model.problemReportState().preferences

        XCTAssertTrue(preferences.customEmulatorBinary)
        XCTAssertTrue(preferences.customSDKFolder)
        XCTAssertTrue(preferences.developmentTeamSet)
        XCTAssertEqual(preferences.enabledPhysicalDeviceCount, 2)
        XCTAssertTrue(preferences.localNetworkInUse)
        XCTAssertTrue(preferences.physicalFastInput, "on by default")
        let json = String(decoding: try ProblemReport.encoder().encode(preferences), as: UTF8.self)
        for private_ in ["/Volumes", "ABCDE12345", "00000000-"] {
            XCTAssertFalse(json.contains(private_), private_)
        }
    }

    func testTheSecretsHoldTheTeamTheEnabledDevicesAndTheLaunchUDID() {
        let defaults = UserDefaults.scratch()
        defaults.set("ABCDE12345", forKey: AppPreferences.Keys.physicalControlTeamID)
        defaults.set(["00000000-0000000000000000"], forKey: AppPreferences.Keys.enabledPhysicalAppleDevices)
        var launch = LaunchOptions.none
        launch.iphoneUDID = "TESTPHONE-UDID-0001"
        let model = AppModel.testing(launch: launch, defaults: defaults)

        let secrets = model.problemReportState().secrets

        XCTAssertEqual(Set(secrets), ["ABCDE12345", "00000000-0000000000000000", "TESTPHONE-UDID-0001"])
        XCTAssertEqual(secrets.count, 3, "each once")
    }

    /// What an error recorded now keeps beside it: the phones' serials (each phone's own, its other transports' and
    /// its hardware serial, never an emulator's) and what the Apple devices are called and identified by, except a
    /// name that is only the model's.
    func testTheIdentifiersKeptWithAnErrorAreThePhonesAndTheAppleDevices() throws {
        let device = try PhysicalFixtures.device()
        let identifiers = AppModel.recentProblemIdentifiers(
            devices: [
                .online("emulator-5554", transport: "1"),
                AndroidDevice(
                    serial: "0a1b2c3d4e5f", state: "device", model: "2209116AG",
                    hardwareSerial: "0A1B2C3D4E5F60718", alternateSerials: ["192.168.1.5:5555"]
                ),
                AndroidDevice(serial: "ZX1G22ABCD", state: "offline"),
            ],
            appleDevices: [device]
        )
        XCTAssertEqual(identifiers.phones, [["0a1b2c3d4e5f", "192.168.1.5:5555", "0A1B2C3D4E5F60718"], ["ZX1G22ABCD"]])
        XCTAssertTrue(identifiers.secrets.contains(device.hardwareUDID))
        XCTAssertTrue(identifiers.secrets.contains(device.coreDeviceIdentifier))
        if let name = device.name, !AppModel.isGenericDeviceName(name, of: device) {
            XCTAssertTrue(identifiers.secrets.contains(name))
        } else if let name = device.name {
            XCTAssertFalse(identifiers.secrets.contains(name), "a name that says only the model is no secret")
        }
        XCTAssertFalse(identifiers.phones.joined().contains { $0.hasPrefix("emulator-") })
        XCTAssertEqual(AppModel.recentProblemIdentifiers(devices: [], appleDevices: []), RecentProblemIdentifiers())
    }

    func testTheAppServicesReadTheInventoryAtTheMomentOfTheError() {
        let model = AppModel.testing()
        XCTAssertTrue(model.services.recentProblemIdentifiers().isEmpty)
        model.inventory.setRealDevices([AndroidDevice(serial: "0a1b2c3d4e5f", state: "device")])
        XCTAssertEqual(model.services.recentProblemIdentifiers().phones, [["0a1b2c3d4e5f"]])
        // A phone that is gone but whose window waits for it is in the merged rows only.
        model.inventory.setRealDevices([])
        model.inventory.devices = [AndroidDevice(serial: "ZX1G22ABCD", state: "offline"), .online("emulator-5554")]
        XCTAssertEqual(model.services.recentProblemIdentifiers().phones, [["ZX1G22ABCD"]])
    }

    func testAFreshModelHasNoSecrets() {
        XCTAssertEqual(AppModel.testing().problemReportState().secrets, [])
    }

    /// A device named after its model says nothing private and would blank
    /// every mention of the model; a name its owner chose is a secret.
    func testGenericDeviceNamesAreNotSecrets() throws {
        let device = try PhysicalFixtures.device()

        XCTAssertTrue(AppModel.isGenericDeviceName("iPhone", of: device))
        XCTAssertTrue(AppModel.isGenericDeviceName("iPad", of: device))
        XCTAssertTrue(AppModel.isGenericDeviceName(try XCTUnwrap(device.marketingName), of: device))
        XCTAssertTrue(AppModel.isGenericDeviceName(try XCTUnwrap(device.productType), of: device))
        XCTAssertFalse(AppModel.isGenericDeviceName("Ada\u{2019}s iPhone", of: device))
    }

    func testTheAppleStateIsWhatTheSidebarAlreadyKnows() {
        let model = AppModel.testing()

        let apple = model.problemReportState().apple

        XCTAssertEqual(apple.tier, "T0")
        XCTAssertNil(apple.toolchain, "no probe for a report")
        XCTAssertFalse(apple.simulatorsListed)
        XCTAssertEqual(apple.simulatorCount, 0)
        XCTAssertEqual(apple.bootedCount, 0)
        XCTAssertNil(apple.runtimeCount, "the runtimes were not read")
        XCTAssertEqual(apple.bridge, "off")
        XCTAssertEqual(apple.canvasReadyCount, 0)
    }

    func testWording() {
        XCTAssertEqual(AppModel.describe(.denied), "denied")
        XCTAssertEqual(AppModel.describe(.allowed), "allowed")
        XCTAssertEqual(AppModel.describe(SimulatorWatcherHealth.degraded), "file watcher off, polling")
        XCTAssertEqual(AppModel.describe(SimulatorWatcherHealth.listFailing(attempt: 3)), "simctl list failing (3 in a row)")
    }
}
