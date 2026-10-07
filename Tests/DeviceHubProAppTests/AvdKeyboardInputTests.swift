import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The hardware keyboard of the AVDs Device Hub Pro creates and of the ones it
/// finds without it: the config a new AVD gets
/// (`AvdCatalogController.completeNewAvdConfig`), the stopped AVD's
/// "Enable Keyboard Input" (`enableHardwareKeyboard`) and the card that
/// offers it. The configs are the real `config.ini` captures
/// (`DeviceHubProKitTests/Fixtures/api37-emulator/logcat-sdk-apk/avd`:
/// `Pixel_9_Pro` as avdmanager wrote it, `hw.keyboard=no`), copied into a
/// temporary AVD home; the user's AVD home is never touched.
@MainActor
final class AvdKeyboardInputTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("DeviceHubProKitTests/Fixtures/api37-emulator/logcat-sdk-apk", isDirectory: true)

    private static var avdmanagerConfig: String {
        get throws {
            try String(
                contentsOf: fixtures.appendingPathComponent("avd/Pixel_9_Pro.avd/config.ini"),
                encoding: .utf8
            )
        }
    }

    /// A temporary AVD home with the avdmanager-written config under the
    /// AVD name `name`; returns the home and the config.
    private func home(avdName name: String) throws -> (home: URL, config: URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("AvdKeyboardInputTests-\(UUID().uuidString)", isDirectory: true)
        let config = home.appendingPathComponent("\(name).avd/config.ini")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        try Data(Self.avdmanagerConfig.utf8).write(to: config)
        return (home, config)
    }

    // MARK: - A new AVD

    /// What avdmanager wrote gets `hw.keyboard=yes` in place of its `no`,
    /// every other byte kept, before the AVD ever boots.
    func testANewAvdGetsItsHardwareKeyboard() throws {
        let (home, config) = try home(avdName: "Pixel_9_Pro")

        let problem = AvdCatalogController.completeNewAvdConfig(
            avdName: "Pixel_9_Pro",
            deviceId: "pixel_9_pro",
            skinsDirectory: nil,
            avdHome: home
        )

        XCTAssertNil(problem)
        XCTAssertEqual(
            try String(contentsOf: config, encoding: .utf8),
            try Self.avdmanagerConfig.replacingOccurrences(of: "\nhw.keyboard=no\n", with: "\nhw.keyboard=yes\n")
        )
    }

    /// With the SDK's skins the matching skin is pinned too, after the
    /// keyboard.
    func testANewAvdGetsItsSkinPinnedToo() throws {
        let (home, config) = try home(avdName: "Pixel_9_Pro")
        let skins = Self.fixtures.appendingPathComponent("skins", isDirectory: true)

        let problem = AvdCatalogController.completeNewAvdConfig(
            avdName: "Pixel_9_Pro",
            deviceId: "pixel_9_pro",
            skinsDirectory: skins,
            avdHome: home
        )

        XCTAssertNil(problem)
        XCTAssertEqual(
            try String(contentsOf: config, encoding: .utf8),
            try Self.avdmanagerConfig.replacingOccurrences(of: "\nhw.keyboard=no\n", with: "\nhw.keyboard=yes\n")
                + "skin.name=pixel_9_pro\nskin.path=\(skins.appendingPathComponent("pixel_9_pro").path)\nskin.dynamic=yes\n"
        )
    }

    /// A config that cannot be read is reported (the status the create
    /// flashes), and nothing is written in its place.
    func testANewAvdWhoseConfigIsGoneIsReported() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("AvdKeyboardInputTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }

        let problem = AvdCatalogController.completeNewAvdConfig(
            avdName: "Gone",
            deviceId: "pixel_9_pro",
            skinsDirectory: nil,
            avdHome: home
        )

        XCTAssertEqual(problem, "Could not turn on the hardware keyboard")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Gone.avd/config.ini").path))
    }

    // MARK: - An existing AVD

    /// A stopped AVD's keyboard is turned on in its config, with the flash
    /// that says what its next start costs.
    func testEnablingTheKeyboardOfAStoppedAvd() async throws {
        let name = "DeviceHubPro_Keyboardless_\(UUID().uuidString.prefix(8))"
        let (home, config) = try home(avdName: name)
        let model = AppModel.testing()

        await model.catalog.enableHardwareKeyboard(name, avdHome: home)

        XCTAssertNil(model.status.errorMessage)
        XCTAssertEqual(AvdConfig.hardwareKeyboard(avdName: name, avdHome: home), true)
        XCTAssertEqual(
            try String(contentsOf: config, encoding: .utf8),
            try Self.avdmanagerConfig.replacingOccurrences(of: "\nhw.keyboard=no\n", with: "\nhw.keyboard=yes\n")
        )
        XCTAssertEqual(
            model.status.statusMessage,
            "Keyboard input on for \"\(name)\". Its next start is a cold boot; snapshots saved before it will not load."
        )
    }

    /// An AVD whose config is gone reports the failure instead of creating
    /// one.
    func testEnablingTheKeyboardWithoutAConfigReportsIt() async throws {
        let name = "DeviceHubPro_Keyboardless_\(UUID().uuidString.prefix(8))"
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("AvdKeyboardInputTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let model = AppModel.testing()

        await model.catalog.enableHardwareKeyboard(name, avdHome: home)

        XCTAssertTrue(
            model.status.errorMessage?.hasPrefix("Could not turn on the hardware keyboard of \"\(name)\"") == true,
            model.status.errorMessage ?? "no error"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("\(name).avd/config.ini").path))
    }

    // MARK: - The card

    /// The card's keyboard flag survives both running-state passes.
    func testTheCardKeepsItsKeyboardFlagThroughTheRunningPasses() {
        let card = AvdCard(
            name: "Pixel_9_Pro",
            displayName: "Pixel 9 Pro",
            target: "android-37.0",
            skin: nil,
            isRunning: false,
            serial: nil,
            hasHardwareKeyboard: false
        )
        XCTAssertFalse(card.withRunningState(runningAVDNames: ["Pixel_9_Pro"]).hasHardwareKeyboard)
        let reconciled = AvdCatalogController.reconcileAvdCards(
            [card],
            runningAVDNames: ["Pixel_9_Pro"],
            serialsByAvd: ["Pixel_9_Pro": "emulator-5558"]
        )
        XCTAssertEqual(reconciled.map(\.hasHardwareKeyboard), [false])
        XCTAssertEqual(reconciled.map(\.serial), ["emulator-5558"])

        let unknown = AvdCard(name: "X", displayName: "X", target: nil, skin: nil, isRunning: false, serial: nil)
        XCTAssertTrue(unknown.hasHardwareKeyboard, "a card that says nothing offers nothing")
    }
}
