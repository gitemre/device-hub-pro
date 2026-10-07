import XCTest
@testable import DeviceHubProKit

final class AdbParsingTests: XCTestCase {
    func testDevicesParsing() {
        let output = """
        List of devices attached
        emulator-5554          device product:sdk_gphone16k_arm64 model:sdk_gphone16k_arm64 device:emu64a16k transport_id:13
        R58M123456A            unauthorized usb:337641472X transport_id:2
        192.168.1.42:5555      offline product:panther model:Pixel_7 device:panther transport_id:5

        """

        let devices = AdbParsing.devices(from: output)
        XCTAssertEqual(devices.count, 3)

        XCTAssertEqual(devices[0].serial, "emulator-5554")
        XCTAssertEqual(devices[0].state, "device")
        XCTAssertEqual(devices[0].model, "sdk_gphone16k_arm64")
        XCTAssertTrue(devices[0].isEmulator)
        XCTAssertTrue(devices[0].isOnline)
        XCTAssertEqual(devices[0].transportID, "13")

        XCTAssertEqual(devices[1].state, "unauthorized")
        XCTAssertNil(devices[1].model)
        XCTAssertFalse(devices[1].isEmulator)
        XCTAssertFalse(devices[1].isOnline)

        XCTAssertEqual(devices[2].state, "offline")
        XCTAssertEqual(devices[2].model, "Pixel_7")
    }

    func testDevicesParsingHandlesDaemonMessages() {
        let output = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached
        emulator-5556\tdevice

        """
        let devices = AdbParsing.devices(from: output)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].serial, "emulator-5556")
    }

    func testAvdNameParsing() {
        XCTAssertEqual(AdbParsing.avdName(from: "Pixel_9_Pro_Fold\r\nOK\r\n"), "Pixel_9_Pro_Fold")
        XCTAssertEqual(AdbParsing.avdName(from: "Pixel_9_Pro_Fold\nOK\n"), "Pixel_9_Pro_Fold")
        XCTAssertEqual(AdbParsing.avdName(from: "\n\nPixel_Fold\nOK"), "Pixel_Fold")
        XCTAssertNil(AdbParsing.avdName(from: "OK\n"))
    }

    func testDiscoveryPathParsing() {
        // The console answers `<path>\r\nOK\r\n` (captured:
        // Fixtures/api37-emulator/adb-core/emu-avd-discoverypath.txt).
        let output = "/Users/dev/Library/Caches/TemporaryItems/avd/running/pid_89187.ini\r\nOK\r\n"
        XCTAssertEqual(
            AdbParsing.discoveryPath(from: output),
            "/Users/dev/Library/Caches/TemporaryItems/avd/running/pid_89187.ini"
        )
        XCTAssertEqual(
            AdbParsing.discoveryPath(from: "/tmp/avd/running/pid_1.ini\nOK\n"),
            "/tmp/avd/running/pid_1.ini"
        )
        XCTAssertNil(AdbParsing.discoveryPath(from: "NO_AVD_INFO\nOK\n"))
        XCTAssertNil(AdbParsing.discoveryPath(from: "OK\n"))
    }

    func testEmulatorDiscoveryParsing() {
        let output = """
        emulator.build=15507667
        avd.id=Pixel_9_Pro_Fold
        grpc.jwks=/tmp/avd/running/89187/jwks/361989c8
        grpc.token=dGVzdC1vbmx5LWZha2UtZ3JwYy10b2tlbi1ub3QtYS1zZWNyZXQ=
        grpc.port=8554
        """

        let discovery = AdbParsing.emulatorDiscovery(from: output)
        XCTAssertEqual(discovery.port, 8554)
        XCTAssertEqual(discovery.token, "dGVzdC1vbmx5LWZha2UtZ3JwYy10b2tlbi1ub3QtYS1zZWNyZXQ=")

        let appLaunched = AdbParsing.emulatorDiscovery(from: "avd.id=Fold\n")
        XCTAssertNil(appLaunched.port)
        XCTAssertNil(appLaunched.token)
    }

    func testResizePresetsParsing() {
        // The console's real answer to `resize-display` without an index,
        // the same in emulator 36.6.11 and 37.2.8 (its string table), on
        // every AVD: a KO usage line that lists the presets.
        let usage = "KO usage: \"resize-display <index>\" 0: phone\t1: unfolded\t2: tablet\r\n"
        let presets = AdbParsing.resizePresets(fromUsage: usage)
        XCTAssertEqual(presets.map(\.index), [0, 1, 2])
        XCTAssertEqual(presets.map(\.name), ["phone", "unfolded", "tablet"])

        // A build that lists the desktop preset too.
        let desktop = "KO usage: \"resize-display <index>\" 0: phone\t1: unfolded\t2: tablet\t3: desktop\n"
        XCTAssertEqual(AdbParsing.resizePresets(fromUsage: desktop).map(\.name), ["phone", "unfolded", "tablet", "desktop"])

        // No usage, no presets: a bare KO, another console error, silence.
        XCTAssertEqual(AdbParsing.resizePresets(fromUsage: "KO\r\n"), [])
        XCTAssertEqual(AdbParsing.resizePresets(fromUsage: "KO: unknown command, try 'help'\r\n"), [])
        XCTAssertEqual(AdbParsing.resizePresets(fromUsage: ""), [])
        // An index without a name is dropped, not paired with the next index.
        XCTAssertEqual(
            AdbParsing.resizePresets(fromUsage: "KO usage: \"resize-display <index>\" 0: 1: unfolded"),
            [ResizePreset(index: 1, name: "unfolded")]
        )
    }

    func testSensorTripleParsing() {
        let accel = AdbParsing.sensorTriple(from: "acceleration = 0:9.77631:0.812349\nOK\n")
        XCTAssertEqual(accel?.x, 0)
        XCTAssertEqual(accel?.y, 9.77631)
        XCTAssertEqual(accel?.z, 0.812349)

        let negative = AdbParsing.sensorTriple(from: "OK\nacceleration = -9.81:-1.9e-06:0")
        XCTAssertEqual(negative?.x, -9.81)
        XCTAssertNil(AdbParsing.sensorTriple(from: "KO: unknown sensor"))

        let crlf = AdbParsing.sensorTriple(from: "acceleration = 0:9.81:0\r\nOK\r\n")
        XCTAssertEqual(crlf?.z, 0)

        let emulator = AdbParsing.sensorTriple(from: "acceleration = -9.81:-1.90735e-06:0\r\nOK\r\n")
        XCTAssertEqual(emulator?.x, -9.81)
        XCTAssertNotNil(emulator)
    }

    func testPoseIndexFromGravity() {
        XCTAssertEqual(AdbParsing.poseIndex(x: 0, y: 9.81, z: 0), 0)
        XCTAssertEqual(AdbParsing.poseIndex(x: -9.81, y: 0, z: 0), 1)
        XCTAssertEqual(AdbParsing.poseIndex(x: 0, y: -9.81, z: 0), 2)
        XCTAssertEqual(AdbParsing.poseIndex(x: 9.81, y: 0, z: 0), 3)
    }

    func testGlobalSettingsParsing() {
        let output = """
        airplane_mode_on=0
        wifi_on=1
        bluetooth_on=0
        low_power=0
        some_key=value=with=equals
        """

        let settings = AdbParsing.globalSettings(from: output)
        XCTAssertEqual(settings["airplane_mode_on"], "0")
        XCTAssertEqual(settings["wifi_on"], "1")
        XCTAssertEqual(settings["bluetooth_on"], "0")
        XCTAssertEqual(settings["low_power"], "0")
        XCTAssertEqual(settings["some_key"], "value=with=equals")
    }

    func testPNGDataStripsLeadingWarnings() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02])
        let warning = Data("[Warning] Multiple displays were found\n".utf8)
        let combined = warning + png

        let extracted = AdbParsing.pngData(from: combined)
        XCTAssertEqual(extracted, png)
        XCTAssertNil(AdbParsing.pngData(from: Data("no png here".utf8)))
    }

    func testDisplayRotationParsing() {
        let output = """
        Display Devices: size=1
          mCurrentOrientation=3
          mDisplayId=0
        """
        XCTAssertEqual(AdbParsing.displayRotation(from: output), 3)
        XCTAssertNil(AdbParsing.displayRotation(from: "no rotation here"))
    }

    func testPackagesParsing() {
        let output = """
        package:com.example.app
        package:com.example.browser

        """
        let packages = AdbParsing.packages(from: output)
        XCTAssertEqual(packages, ["com.example.app", "com.example.browser"])
    }

    func testAppearanceReadingParsing() {
        XCTAssertEqual(AdbParsing.appearanceReading(from: "Night mode: no\n"), .mode(.light))
        XCTAssertEqual(AdbParsing.appearanceReading(from: "Night mode: yes\n"), .mode(.dark))
        XCTAssertEqual(AdbParsing.appearanceReading(from: "Night mode: auto"), .mode(.system))
        XCTAssertEqual(AdbParsing.appearanceReading(from: "Night mode: yes\r\n"), .mode(.dark))

        // AOSP answers these for legitimate states (a custom schedule or
        // bedtime, or a mode that was never set). The command works, the
        // value simply has no Light/Dark/System counterpart.
        XCTAssertEqual(
            AdbParsing.appearanceReading(from: "Night mode: custom_schedule\n"),
            .unmapped("custom_schedule")
        )
        XCTAssertEqual(
            AdbParsing.appearanceReading(from: "Night mode: custom_bedtime\n"),
            .unmapped("custom_bedtime")
        )
        XCTAssertEqual(
            AdbParsing.appearanceReading(from: "Night mode: unknown\n"),
            .unmapped("unknown")
        )
        // Older images print the bare `custom` token.
        XCTAssertEqual(AdbParsing.appearanceReading(from: "Night mode: custom"), .unmapped("custom"))

        // Output that never carries a `Night mode:` line is not an answer.
        XCTAssertEqual(AdbParsing.appearanceReading(from: "Unknown command: uimode"), .unreadable)
        XCTAssertEqual(AdbParsing.appearanceReading(from: "Night mode:"), .unreadable)
        XCTAssertEqual(AdbParsing.appearanceReading(from: ""), .unreadable)

        XCTAssertEqual(AppearanceMode.light.commandValue, "no")
        XCTAssertEqual(AppearanceMode.dark.commandValue, "yes")
        XCTAssertEqual(AppearanceMode.system.commandValue, "auto")
        XCTAssertEqual(AppearanceMode.allCases.map(\.label), ["Light", "Dark", "System"])

        // Only mapped readings preselect a popup item.
        XCTAssertEqual(AppearanceReading.mode(.dark).mode, .dark)
        XCTAssertNil(AppearanceReading.unmapped("custom_schedule").mode)
        XCTAssertNil(AppearanceReading.unreadable.mode)
    }

    func testGetpropParsing() {
        let output = """
        [ro.product.model]: [Pixel 9 Pro Fold]
        [ro.product.manufacturer]: [Google]
        [ro.build.version.release]: [17]
        [ro.build.version.sdk]: [37]
        [ro.product.cpu.abi]: [arm64-v8a]
        [persist.sys.locale]: []

        """

        let properties = AdbParsing.getprop(from: output)
        XCTAssertEqual(properties["ro.product.model"], "Pixel 9 Pro Fold")
        XCTAssertEqual(properties["ro.product.manufacturer"], "Google")
        XCTAssertEqual(properties["ro.build.version.release"], "17")
        XCTAssertEqual(properties["ro.build.version.sdk"], "37")
        XCTAssertEqual(properties["ro.product.cpu.abi"], "arm64-v8a")
        XCTAssertEqual(properties["persist.sys.locale"], "")

        let info = DeviceInfo.from(serial: "emulator-5554", properties: properties, isEmulator: true)
        XCTAssertEqual(info.model, "Pixel 9 Pro Fold")
        XCTAssertEqual(info.apiLevel, "37")
        XCTAssertTrue(info.isEmulator)
    }
}
