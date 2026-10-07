import XCTest
@testable import DeviceHubProKit

/// What Device Hub's Settings and Apps show that Device Hub Pro now reads too
/// (2026-09-29), from captures of an iOS 26.5 simulator, a throwaway iPhone 17
/// in the default set, with Xcode 27.0's devicectl 642.16:
/// - `ios26-simulator/devicectl/`: `info audio` with the output on the Mac's
///   default device and pinned to `BuiltInSpeakerDevice`, `settings audio
///   --output-device` for both, `info appearance` (Clear Liquid Glass and
///   Tinted) and `settings appearance --look-and-feel tinted|clear`.
/// - `ios26-simulator/runtime-apps/`: the runtime's own `Info.plist` of
///   ActivityMessagesApp (`LSApplicationLaunchProhibited`, an app `simctl
///   listapps` leaves out and Device Hub lists) and Web (an ordinary one).
final class SimulatorInspectorTests: XCTestCase {
    private static func fixture(_ folder: String, _ name: String) throws -> Data {
        try SimctlFixtureTests.data("../ios26-simulator/\(folder)", name)
    }

    private func decode<T: Decodable & Sendable>(_ type: T.Type, _ name: String) throws -> T {
        try DevicectlJSON.decode(type, from: Self.fixture("devicectl", name)).value
    }

    func testAudioDevicesDecodeTheSystemDefaultAndAPinnedDevice() throws {
        let system = try decode(DevicectlAudio.self, "devicectl-device-info-audio.json")
        XCTAssertEqual(system.outputDevice, .systemDefault)
        XCTAssertEqual(system.inputDevice, .systemDefault)
        XCTAssertEqual(system.outputIsSystemDefault, true)

        let pinned = try decode(DevicectlAudio.self, "devicectl-device-info-audio.output-pinned.json")
        XCTAssertEqual(pinned.outputDevice, .device("BuiltInSpeakerDevice"))
        XCTAssertEqual(pinned.outputIsSystemDefault, false)
        XCTAssertEqual(pinned.inputDevice, .systemDefault)

        // A `settings audio --output-device` answer carries the device that changed only.
        let answer = try decode(DevicectlAudio.self, "devicectl-device-settings-audio-output-device.json")
        XCTAssertEqual(answer.outputDevice, .device("BuiltInSpeakerDevice"))
        XCTAssertNil(answer.inputDevice)
        XCTAssertNil(answer.volume)
        XCTAssertEqual(
            try decode(DevicectlAudio.self, "devicectl-device-settings-audio-output-device.system-default.json").outputDevice,
            .systemDefault
        )
    }

    func testAudioDeviceArguments() {
        XCTAssertEqual(DevicectlAudioDevice.systemDefault.argument, "systemDefault")
        XCTAssertEqual(DevicectlAudioDevice.device("BuiltInSpeakerDevice").argument, "BuiltInSpeakerDevice")
    }

    func testAnAudioAnswerUpdatesTheState() throws {
        var state = AppleControlsState()
        state.apply(.audio(try decode(DevicectlAudio.self, "devicectl-device-info-audio.output-pinned.json")))
        XCTAssertEqual(state.volume, 60)
        XCTAssertEqual(state.audioOutput, .device("BuiltInSpeakerDevice"))
        XCTAssertEqual(state.audioInput, .systemDefault)
        // A partial answer keeps what it does not carry.
        state.apply(.audio(try decode(DevicectlAudio.self, "devicectl-device-settings-audio-output-device.system-default.json")))
        XCTAssertEqual(state.volume, 60)
        XCTAssertEqual(state.audioOutput, .systemDefault)
        XCTAssertEqual(AppleControlChange.audioOutput(.systemDefault).control, .volume)
        XCTAssertEqual(AppleControlChange.audioInput(.systemDefault).control, .volume)
    }

    /// An iOS 26.5 runtime lists two looks and reads the chosen one back (iOS
    /// 27.0 lists one, "Liquid Glass", and reads back nothing of the choice).
    func testLookAndFeelReadsBackOnIOS26() throws {
        let clear = try decode(DevicectlAppearance.self, "devicectl-device-info-appearance.json")
        XCTAssertEqual(clear.lookSelection, .clear)
        XCTAssertEqual(clear.supportedLooks, [.clear, .tinted])
        XCTAssertNil(clear.liquidGlassOpacity)
        let tinted = try decode(DevicectlAppearance.self, "devicectl-device-info-appearance.tinted.json")
        XCTAssertEqual(tinted.lookSelection, .tinted)

        var state = AppleControlsState()
        state.apply(.appearance(tinted))
        XCTAssertEqual(state.lookAndFeel, .tinted)
        XCTAssertEqual(state.supportedLooks, [.clear, .tinted])
        let answer = try decode(DevicectlAppearance.self, "devicectl-device-settings-appearance-look-and-feel-clear.json")
        state.apply(.appearance(answer))
        XCTAssertEqual(state.lookAndFeel, .clear)
        XCTAssertEqual(DevicectlAppearanceSetting.lookAndFeel(.tinted).arguments, ["--look-and-feel", "tinted"])
        XCTAssertEqual(DevicectlLookAndFeel.clear.title, "Clear")
    }

    // MARK: Runtime apps

    func testLaunchProhibitedAppsAreFoundInARuntimeApplicationsFolder() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceHubPro-runtime-apps-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("RuntimeRoot/Applications", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        for (name, plist) in [("ActivityMessagesApp", "ActivityMessagesApp.Info.plist"), ("Web", "Web.Info.plist")] {
            let app = folder.appendingPathComponent("\(name).app", isDirectory: true)
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            try Self.fixture("runtime-apps", plist).write(to: app.appendingPathComponent("Info.plist"))
        }
        XCTAssertEqual(SimulatorRuntimeApps.launchProhibitedIdentifiers(in: folder), ["com.apple.ActivityMessagesApp"])

        // The folder is found from a listed system app's path, and an app the listing has is not missing.
        func app(_ id: String, path: String) throws -> SimulatorApp {
            try SimctlParsing.app(fromAppInfo: """
            {
                ApplicationType = System;
                CFBundleIdentifier = "\(id)";
                Path = "\(path)";
            }
            """)
        }
        let web = try app("com.apple.webapp", path: folder.appendingPathComponent("Web.app").path)
        XCTAssertEqual(SimulatorRuntimeApps.applicationsFolder(from: [web])?.path, folder.path)
        XCTAssertEqual(SimulatorRuntimeApps.missingIdentifiers(from: [web]), ["com.apple.ActivityMessagesApp"])
        let both = try [web, app("com.apple.ActivityMessagesApp", path: folder.appendingPathComponent("ActivityMessagesApp.app").path)]
        XCTAssertEqual(SimulatorRuntimeApps.missingIdentifiers(from: both), [])
        XCTAssertNil(SimulatorRuntimeApps.applicationsFolder(from: []))
    }

    func testTheBundleReadsLaunchProhibited() throws {
        let hosted = try XCTUnwrap(SimulatorAppBundle.parse(infoPlist: Self.fixture("runtime-apps", "ActivityMessagesApp.Info.plist")))
        XCTAssertTrue(hosted.launchProhibited)
        let web = try XCTUnwrap(SimulatorAppBundle.parse(infoPlist: Self.fixture("runtime-apps", "Web.Info.plist")))
        XCTAssertFalse(web.launchProhibited)
    }

    /// Device Hub 27.0's Apps list on iOS 26.5 (2x captures): the icon
    /// template on a white tile for the message and business hosts, the
    /// hashtag images host and FullKeyboardAccess; the App Store "A" for
    /// Emoji, Kaleidoscope (a launch screen), Escrow and AssistiveTouch (an
    /// icon key without a file). The plists are the runtime's own.
    func testTheIconTemplateTileIsForAppsThatCannotBeLaunchedOrShowNothing() throws {
        func bundle(_ name: String) throws -> SimulatorAppBundle {
            try XCTUnwrap(SimulatorAppBundle.parse(infoPlist: Self.fixture("runtime-apps", "\(name).Info.plist")))
        }
        for name in ["ActivityMessagesApp", "BusinessExtensionsWrapper", "HashtagImages", "FullKeyboardAccess"] {
            XCTAssertTrue(try bundle(name).usesIconTemplateTile, name)
        }
        for name in ["EmojiPoster", "KaleidoscopePosterApp", "EscrowSecurityAlert", "AssistiveTouch", "Web"] {
            XCTAssertFalse(try bundle(name).usesIconTemplateTile, name)
        }
    }
}
