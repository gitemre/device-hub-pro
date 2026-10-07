import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// Settings profiles applied through Apply to Selected's real path
/// (`BatchPerformer`) to a real simulator, behind `DHP_IOS_LIVE=1`; the
/// simulator is made in a private device set (`LiveTestSimulators`) and
/// deleted afterwards. With `DHP_PROFILE_EMULATOR_SERIAL=emulator-55xx`
/// (an emulator the run owns) the same profiles also go to it, read back
/// through adb, and Defaults puts it back.
@MainActor
final class SettingsProfileLiveTests: XCTestCase {
    func testProfilesOnARealSimulatorAndEmulator() async throws {
        let toolchain = try await LiveTestSimulators.toolchain()
        let simulators = try LiveTestSimulators.Session(toolchain: toolchain)
        do {
            try await exercise(simulators)
        } catch {
            _ = await simulators.tearDown()
            throw error
        }
        let leftovers = await simulators.tearDown()
        XCTAssertEqual(leftovers, [])
    }

    private func exercise(_ simulators: LiveTestSimulators.Session) async throws {
        let device = try await simulators.createDevice(name: "DeviceHubPro-ProfilesLive")
        let udid = device.udid
        let simctl = simulators.simctl
        try await simctl.bootStatus(udid: udid, bootIfNeeded: true)
        try await Task.sleep(for: .seconds(10))

        let serial = ProcessInfo.processInfo.environment["DHP_PROFILE_EMULATOR_SERIAL"]
        let adb = serial == nil ? nil : AdbClient.locate()
        let model = AppModel.testing(
            adb: adb,
            apple: AppleTooling(
                probe: { [toolchain = simulators.toolchain] in toolchain },
                deviceSet: simulators.setDirectory,
                devicesDirectory: simulators.setDirectory,
                logsDirectory: LiveTestSimulators.logsDirectory
            )
        )
        await model.simulators.refresh()
        let backend = try AppleControlsBackend(udid: udid, simctl: simctl, devicectl: nil, dataDirectory: nil)
        let sim = BatchTarget(
            id: "simulator:\(udid)", platform: .apple, kind: .simulator, ref: .apple(udid),
            name: "DeviceHubPro-ProfilesLive", osName: "iOS", osVersion: nil, readiness: .ready
        )

        // Accessibility Stress: 200 % text (an accessibility size) and Increase Contrast.
        var report = await model.multiDevice.run(.profile(SettingsProfiles.accessibilityStress), on: [sim])
        XCTAssertEqual(report?.succeeded, ["DeviceHubPro-ProfilesLive"], "\(String(describing: report))")
        let size = try await backend.read(.simctlContentSize)
        XCTAssertEqual(size, .contentSize(BatchTextSize.doubled.simulatorSize))
        let contrast = try await backend.read(.simctlIncreaseContrast)
        XCTAssertEqual(contrast, .increaseContrast(.enabled))

        // Screenshots: default text and the clean status bar.
        report = await model.multiDevice.run(.profile(SettingsProfiles.screenshots), on: [sim])
        XCTAssertEqual(report?.succeeded, ["DeviceHubPro-ProfilesLive"], "\(String(describing: report))")
        let sizeAgain = try await backend.read(.simctlContentSize)
        XCTAssertEqual(sizeAgain, .contentSize(.large))
        let bar = try await backend.readStatusBar(over: SimulatorStatusBarState())
        XCTAssertEqual(bar?.time.trimmingCharacters(in: CharacterSet(charactersIn: "0")), "9:41")
        XCTAssertEqual(bar?.batteryLevel, 100)

        // Dark Mode, then Defaults puts it all back.
        report = await model.multiDevice.run(.profile(SettingsProfiles.darkMode), on: [sim])
        XCTAssertEqual(report?.succeeded.count, 1)
        let dark = try await backend.read(.simctlAppearance)
        XCTAssertEqual(dark, .simctlAppearance(.dark))
        report = await model.multiDevice.run(.profile(SettingsProfiles.defaults), on: [sim])
        XCTAssertEqual(report?.succeeded.count, 1, "\(String(describing: report)) \(model.status.errorMessage ?? "")")
        let light = try await backend.read(.simctlAppearance)
        XCTAssertEqual(light, .simctlAppearance(.light))
        let contrastOff = try await backend.read(.simctlIncreaseContrast)
        XCTAssertEqual(contrastOff, .increaseContrast(.disabled))
        let barOff = try await backend.readStatusBar(over: SimulatorStatusBarState())
        XCTAssertNil(barOff)

        if let serial, adb != nil {
            let phone = BatchTarget(
                id: "device:\(serial)", platform: .android, kind: .emulator, ref: .android(serial),
                name: serial, osName: "Android", osVersion: nil, readiness: .ready, apiLevel: 35
            )
            report = await model.multiDevice.run(.profile(SettingsProfiles.accessibilityStress), on: [phone, sim])
            XCTAssertEqual(report?.succeeded.count, 2, "\(String(describing: report)) \(model.status.errorMessage ?? "")")
            XCTAssertEqual(try adbSetting(serial, "system", "font_scale"), "2.0")
            XCTAssertEqual(try adbSetting(serial, "global", "animator_duration_scale"), "0")
            report = await model.multiDevice.run(.profile(SettingsProfiles.defaults), on: [phone, sim])
            XCTAssertEqual(report?.succeeded.count, 2, "\(String(describing: report))")
            XCTAssertEqual(try adbSetting(serial, "system", "font_scale"), "1.0")
            XCTAssertEqual(try adbSetting(serial, "global", "animator_duration_scale"), "1.0")
        }
    }

    private func adbSetting(_ serial: String, _ namespace: String, _ key: String) throws -> String {
        let process = Process()
        process.executableURL = try XCTUnwrap(AdbBinaryLocator.locate())
        process.arguments = ["-s", serial, "shell", "settings", "get", namespace, key]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
