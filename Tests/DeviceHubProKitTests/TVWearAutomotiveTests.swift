import XCTest
@testable import DeviceHubProKit

/// Real captures of the Google TV (API 36, `Television_1080p`) and Wear OS
/// (API 36, `Wear_OS_Large_Round`) emulators, 2026-10-01
/// (`Fixtures/api36-tv`, `Fixtures/api36-wear`; the home path in the AVD
/// files is the same-length placeholder `aqauser001`).
final class TVWearAutomotiveTests: XCTestCase {
    private static func fixture(_ folder: String, _ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(folder)/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Form factor of the running system

    /// The Google TV image declares only `emulator` in
    /// `ro.build.characteristics`; its class is in the hardware type features.
    func testTheTVImageIsATVThroughItsFeaturesNotItsCharacteristics() throws {
        let characteristics = try Self.fixture("api36-tv", "getprop-characteristics.txt")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(characteristics, "emulator")
        XCTAssertEqual(DeviceInfo.formFactor(characteristics: characteristics), .handheld)

        let features = AdbParsing.features(from: try Self.fixture("api36-tv", "pm-list-features.txt"))
        XCTAssertTrue(features.contains("android.hardware.type.television"))
        XCTAssertTrue(features.contains("android.software.leanback"))
        XCTAssertEqual(DeviceInfo.formFactor(characteristics: characteristics, features: features), .tv)

        let info = DeviceInfo.from(
            serial: "emulator-5556",
            properties: ["ro.build.characteristics": characteristics],
            isEmulator: true,
            features: features
        )
        XCTAssertEqual(info.formFactor, .tv)
    }

    func testTheWearImageIsAWatchThroughEitherSource() throws {
        let characteristics = try Self.fixture("api36-wear", "getprop-characteristics.txt")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let features = AdbParsing.features(from: try Self.fixture("api36-wear", "pm-list-features.txt"))
        XCTAssertTrue(features.contains("android.hardware.type.watch"))
        XCTAssertEqual(DeviceInfo.formFactor(characteristics: characteristics), .wear)
        XCTAssertEqual(DeviceInfo.formFactor(characteristics: "emulator", features: features), .wear)
    }

    func testAPhoneKeepsItsClassWhateverItsFeatures() {
        XCTAssertEqual(
            DeviceInfo.formFactor(
                characteristics: "emulator",
                features: ["android.hardware.touchscreen", "android.hardware.telephony"]
            ),
            .handheld
        )
        // SOURCE-DERIVED: AOSP `PackageManager.FEATURE_AUTOMOTIVE`
        // (`android.hardware.type.automotive`); no automotive image was
        // running to capture one.
        XCTAssertEqual(
            DeviceInfo.formFactor(characteristics: "emulator", features: ["android.hardware.type.automotive"]),
            .automotive
        )
    }

    func testFeaturesParseWithAndWithoutAVersionAndLineEndings() {
        let output = "feature:reqGlEsVersion=0x30001\r\nfeature:android.hardware.type.television\r\nnoise\r\n"
        XCTAssertEqual(
            AdbParsing.features(from: output),
            ["reqGlEsVersion", "android.hardware.type.television"]
        )
        XCTAssertEqual(AdbParsing.features(from: ""), [])
    }

    // MARK: - The AVD's own class and orientation

    private func avdHome(copying folder: String, avd: String, ini: Bool = true) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tv-wear-\(UUID().uuidString)", isDirectory: true)
        let directory = home.appendingPathComponent("\(avd).avd", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = try Self.fixture(folder, "config.ini")
        try config.write(to: directory.appendingPathComponent("config.ini"), atomically: true, encoding: .utf8)
        if ini {
            try "path=\(directory.path)\n".write(
                to: home.appendingPathComponent("\(avd).ini"), atomically: true, encoding: .utf8
            )
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    func testAnAvdsClassComesFromItsImageTag() throws {
        let tv = try avdHome(copying: "api36-tv", avd: "Television_1080p")
        XCTAssertEqual(AvdConfig.formFactor(avdName: "Television_1080p", avdHome: tv), .tv)
        let wear = try avdHome(copying: "api36-wear", avd: "Wear_OS_Large_Round")
        XCTAssertEqual(AvdConfig.formFactor(avdName: "Wear_OS_Large_Round", avdHome: wear), .wear)
        // With no tag, the tag in the system image's path.
        XCTAssertEqual(
            AvdConfig.formFactor(values: ["image.sysdir.1": "system-images/android-36/google-tv/arm64-v8a/"]),
            .tv
        )
        XCTAssertEqual(
            AvdConfig.formFactor(values: ["image.sysdir.1": "system-images/android-35-ext15/android-automotive/arm64-v8a/"]),
            .automotive
        )
        XCTAssertEqual(AvdConfig.formFactor(values: [:]), .handheld)
    }

    /// avdmanager wrote `hw.initialOrientation=portrait` and
    /// `hw.lcd.circular=false` for these two profiles (the captures). The TV's
    /// LCD is 1920x1080, and the emulator read the physical model as turned a
    /// quarter (`rotation` -90 over gRPC, measured), which drew a portrait
    /// phone. Android Studio writes the profile's own orientation and round flag.
    func testTheCapturedAvdmanagerOutputIsWhatNeedsCompleting() throws {
        let tv = try Self.fixture("api36-tv", "config.ini")
        XCTAssertTrue(tv.contains("hw.initialOrientation=portrait\n"))
        XCTAssertTrue(tv.contains("hw.lcd.width=1920\n"))
        XCTAssertTrue(tv.contains("hw.lcd.height=1080\n"))
        XCTAssertFalse(tv.contains("avd.ini.displayname"), "the typed name 'Television (1080p)' was dropped")
        let wear = try Self.fixture("api36-wear", "config.ini")
        XCTAssertTrue(wear.contains("hw.lcd.circular=false\n"))
        XCTAssertTrue(wear.contains("hw.device.name=wearos_large_round\n"))
    }

    func testCompletingATVWritesLandscapeAndTheTypedName() throws {
        let home = try avdHome(copying: "api36-tv", avd: "Television_1080p")
        try AvdConfig.completeDeviceKeys(
            avdName: "Television_1080p",
            deviceId: "tv_1080p",
            displayName: "Television (1080p)",
            avdHome: home
        )
        let values = AvdConfig.values(avdName: "Television_1080p", avdHome: home)
        XCTAssertEqual(values["hw.initialOrientation"], "landscape")
        XCTAssertEqual(values["hw.lcd.circular"], "false")
        XCTAssertEqual(values["avd.ini.displayname"], "Television (1080p)")
        XCTAssertEqual(values["AvdId"], "Television_1080p")
        XCTAssertEqual(
            AvdConfig.displayName(avdName: "Television_1080p", avdHome: home),
            "Television (1080p)"
        )
        // Every other line stays.
        XCTAssertEqual(values["hw.lcd.width"], "1920")
        XCTAssertEqual(values["skin.name"], "tv_1080p")
    }

    func testCompletingARoundWatchWritesCircularTrue() throws {
        let home = try avdHome(copying: "api36-wear", avd: "Wear_OS_Large_Round")
        try AvdConfig.completeDeviceKeys(
            avdName: "Wear_OS_Large_Round",
            deviceId: "wearos_large_round",
            displayName: nil,
            avdHome: home
        )
        let values = AvdConfig.values(avdName: "Wear_OS_Large_Round", avdHome: home)
        XCTAssertEqual(values["hw.lcd.circular"], "true")
        XCTAssertEqual(values["hw.initialOrientation"], "portrait", "454x454 is not landscape")
        XCTAssertNil(values["avd.ini.displayname"], "no typed name, nothing to add")
        XCTAssertFalse(
            try String(
                contentsOf: AvdConfig.configURL(avdName: "Wear_OS_Large_Round", avdHome: home),
                encoding: .utf8
            ).contains("hw.lcd.circular=false")
        )
    }

    func testRoundProfilesAndOrientations() {
        for id in ["wearos_small_round", "wearos_large_round", "wearos_xl_round", "wear_round_chin_320_290"] {
            XCTAssertTrue(AvdConfig.isRoundProfile(deviceId: id), id)
        }
        for id in ["wearos_square", "wearos_rect", "tv_1080p", "pixel_9_pro", "automotive_1024p_landscape"] {
            XCTAssertFalse(AvdConfig.isRoundProfile(deviceId: id), id)
        }
        XCTAssertEqual(AvdConfig.initialOrientation(lcdWidth: 1920, lcdHeight: 1080), "landscape")
        XCTAssertEqual(AvdConfig.initialOrientation(lcdWidth: 1024, lcdHeight: 768), "landscape")
        XCTAssertEqual(AvdConfig.initialOrientation(lcdWidth: 1080, lcdHeight: 2400), "portrait")
        XCTAssertEqual(AvdConfig.initialOrientation(lcdWidth: 454, lcdHeight: 454), "portrait")
    }

    func testAnExistingKeyIsRewrittenInPlace() throws {
        let home = try avdHome(copying: "api36-tv", avd: "Television_1080p")
        try AvdConfig.setValue("landscape", forKey: "hw.initialOrientation", avdName: "Television_1080p", avdHome: home)
        let text = try String(
            contentsOf: AvdConfig.configURL(avdName: "Television_1080p", avdHome: home),
            encoding: .utf8
        )
        XCTAssertEqual(text.components(separatedBy: "hw.initialOrientation").count, 2, "one line")
        XCTAssertTrue(text.contains("hw.initialOrientation=landscape\n"))
    }

    // MARK: - Remote keys

    /// The names of the KEY codes the emulator's keyboard device reports
    /// (`getevent -lp`, "qwerty2").
    private func reportedKeys() throws -> Set<String> {
        let text = try Self.fixture("api36-tv", "getevent-lp.txt")
        guard let start = text.range(of: "\"qwerty2\"") else { return [] }
        let keys = text[start.upperBound...].split(whereSeparator: \.isWhitespace).map(String.init)
        return Set(keys.filter { $0.hasPrefix("KEY_") })
    }

    func testTheEmulatorKeyboardReportsEveryEvdevKeyTheRemoteSends() throws {
        let names: [RemoteKey: String] = [
            .up: "KEY_UP", .down: "KEY_DOWN", .left: "KEY_LEFT", .right: "KEY_RIGHT",
            .select: "KEY_ENTER", .back: "KEY_BACK",
            .playPause: "KEY_PLAYPAUSE", .menu: "KEY_MENU",
        ]
        let reported = try reportedKeys()
        XCTAssertTrue(reported.contains("KEY_ENTER"))
        XCTAssertNil(RemoteKey.home.evdevCode, "Home did not act over gRPC (measured): adb only")
        for key in RemoteKey.allCases where key != .home {
            let name = try XCTUnwrap(names[key])
            XCTAssertTrue(reported.contains(name), "\(key) sends \(name)")
        }
        // The keys the generic layout maps to DPAD_CENTER are not reported,
        // which is why Select is Enter on this path.
        XCTAssertFalse(reported.contains("KEY_SELECT"))
        XCTAssertFalse(reported.contains("KEY_OK"))
    }

    func testTheGenericLayoutMapsEveryEvdevCodeToTheKeyTheRemoteMeans() throws {
        let layout = try Self.fixture("api36-tv", "generic-kl-remote-keys.txt")
        var map: [Int32: String] = [:]
        for line in layout.split(separator: "\n") where line.hasPrefix("key ") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.count >= 3, let code = Int32(parts[1]) { map[code] = String(parts[2]) }
        }
        let expected: [RemoteKey: String] = [
            .up: "DPAD_UP", .down: "DPAD_DOWN", .left: "DPAD_LEFT", .right: "DPAD_RIGHT",
            .select: "ENTER", .back: "BACK", .playPause: "MEDIA_PLAY_PAUSE", .menu: "MENU",
        ]
        for key in RemoteKey.allCases {
            guard let code = key.evdevCode else { continue }
            XCTAssertEqual(map[code], expected[key], "\(key)")
        }
        XCTAssertEqual(map[353], "DPAD_CENTER", "what the adb path's key 23 is")
    }

    func testAndroidKeyCodes() {
        XCTAssertEqual(RemoteKey.up.androidKeyCode, 19)
        XCTAssertEqual(RemoteKey.down.androidKeyCode, 20)
        XCTAssertEqual(RemoteKey.left.androidKeyCode, 21)
        XCTAssertEqual(RemoteKey.right.androidKeyCode, 22)
        XCTAssertEqual(RemoteKey.select.androidKeyCode, 23)
        XCTAssertEqual(RemoteKey.back.androidKeyCode, 4)
        XCTAssertEqual(RemoteKey.home.androidKeyCode, 3)
        XCTAssertEqual(RemoteKeys.adbArguments(for: .select), ["input", "keyevent", "23"])
    }

    func testTheMacKeysThatMeanARemoteButton() {
        XCTAssertEqual(RemoteKey(macKeyCode: 126), .up)
        XCTAssertEqual(RemoteKey(macKeyCode: 125), .down)
        XCTAssertEqual(RemoteKey(macKeyCode: 123), .left)
        XCTAssertEqual(RemoteKey(macKeyCode: 124), .right)
        XCTAssertEqual(RemoteKey(macKeyCode: 36), .select)
        XCTAssertEqual(RemoteKey(macKeyCode: 76), .select)
        XCTAssertEqual(RemoteKey(macKeyCode: 53), .back)
        XCTAssertEqual(RemoteKey(macKeyCode: 51), .back)
        XCTAssertNil(RemoteKey(macKeyCode: 48), "Tab stays a keyboard key")
        XCTAssertNil(RemoteKey(macKeyCode: 0))
    }
}
