import DeviceHubProKit
@testable import DeviceHubProApp
import XCTest

final class MacAudioDevicesTests: XCTestCase {
    /// The Output and Input popups list what the Mac's Sound settings list:
    /// no hidden device and no CoreAudio default-device aggregate.
    func testHiddenAndDefaultAggregateDevicesAreNotListed() {
        XCTAssertTrue(MacAudioDevices.isListed(uid: "BuiltInSpeakerDevice", name: "Mac mini Speakers", hidden: false))
        XCTAssertFalse(MacAudioDevices.isListed(uid: "BuiltInSpeakerDevice", name: "Mac mini Speakers", hidden: true))
        XCTAssertFalse(MacAudioDevices.isListed(
            uid: "CADefaultDeviceAggregate-38792-0", name: "CADefaultDeviceAggregate-38792-0", hidden: false
        ))
    }
}

final class SimulatorMenuFamilyTests: XCTestCase {
    /// Shake is an iPhone's and an iPad's gesture: an Apple TV listed it.
    func testOnlyHandheldSimulatorsListShake() {
        XCTAssertTrue(ControlsMenuItems.shakes(.iPhone))
        XCTAssertTrue(ControlsMenuItems.shakes(.iPad))
        XCTAssertFalse(ControlsMenuItems.shakes(.appleTV))
        XCTAssertFalse(ControlsMenuItems.shakes(.appleWatch))
        XCTAssertFalse(ControlsMenuItems.shakes(.appleVision))
    }

    /// A stopped Apple TV has no biometrics: its Device menu has no Face ID.
    func testAnAppleTVPlanHasNoBiometricMenu() {
        XCTAssertNil(AppleSettingsMenuPlan(family: .appleTV, isRunning: false).biometricMenuTitle)
        XCTAssertEqual(AppleSettingsMenuPlan(family: .iPhone, isRunning: false).biometricMenuTitle, "Face ID")
    }
}

@MainActor
final class AndroidHardwareFeatureTests: XCTestCase {
    /// A Wear OS image has no fingerprint sensor: Fingerprint is left out of
    /// the panel and the Simulate menu. Unknown (no Info yet) keeps it.
    func testAMissingHardwareFeatureHidesItsItems() {
        let model = AppModel.testing()
        let workspace = model.workspace
        workspace.context.serial = "emulator-5556"
        XCTAssertTrue(workspace.androidDeviceHas(DeviceWorkspace.fingerprintFeature), "nothing read yet")

        model.inventory.deviceInfos["emulator-5556"] = DeviceInfo(
            serial: "emulator-5556", model: "sdk_gwear", manufacturer: "Google", androidVersion: "17",
            apiLevel: "37", abi: "arm64-v8a", isEmulator: true, characteristics: "emulator,nosdcard,watch",
            features: ["android.hardware.telephony", "android.hardware.type.watch"]
        )
        XCTAssertFalse(workspace.androidDeviceHas(DeviceWorkspace.fingerprintFeature))
        XCTAssertTrue(workspace.androidDeviceHas(DeviceWorkspace.telephonyFeature))
    }
}

final class AvdCardOSTitleTests: XCTestCase {
    /// A stopped emulator's stage and Info name its OS as the sidebar does.
    func testAStoppedEmulatorNamesItsAndroidRelease() {
        func card(_ target: String?) -> AvdCard {
            AvdCard(name: "TV", displayName: "TV", target: target, skin: nil, isRunning: false, serial: nil)
        }
        XCTAssertEqual(card("android-36").osTitle, "Android 16")
        XCTAssertEqual(card("android-36").osDetailTitle, "Android 16 (API 36)")
        XCTAssertEqual(card("android-99").osTitle, "API 99", "an unknown level keeps the API label")
        XCTAssertNil(card(nil).osTitle)
    }
}

@MainActor
final class AndroidTVFeatureTests: XCTestCase {
    /// A Google TV image (measured, API 36) lists leanback_only and no
    /// accelerometer, telephony or fingerprint.
    func testATVReportsNoShakeSplitScreenOrPhoneHardware() {
        let model = AppModel.testing()
        let workspace = model.workspace
        workspace.context.serial = "emulator-5556"
        XCTAssertFalse(workspace.androidHasReadFeatures)
        model.inventory.deviceInfos["emulator-5556"] = DeviceInfo(
            serial: "emulator-5556", model: "sdk_google_atv", manufacturer: "Google", androidVersion: "16",
            apiLevel: "36", abi: "arm64-v8a", isEmulator: true, characteristics: "emulator",
            features: ["android.hardware.type.television", "android.software.leanback", "android.software.leanback_only"]
        )
        XCTAssertTrue(workspace.androidHasReadFeatures)
        XCTAssertTrue(workspace.androidDeviceHas(DeviceWorkspace.leanbackOnlyFeature))
        XCTAssertFalse(workspace.androidDeviceHas(DeviceWorkspace.accelerometerFeature))
        XCTAssertFalse(workspace.androidDeviceHas(DeviceWorkspace.telephonyFeature))
        XCTAssertFalse(workspace.androidDeviceHas(DeviceWorkspace.fingerprintFeature))
    }
}

@MainActor
final class AdbRestartSafetyTests: XCTestCase {
    /// A phone's scrcpy stream rides adb's forward: enabling mDNS discovery
    /// (an adb restart) must wait while any window mirrors a phone.
    func testAPhoneMirrorMakesAnAdbRestartUnsafe() {
        let model = AppModel.testing()
        XCTAssertFalse(model.isAdbRestartUnsafe)
        model.workspace.beginMirrorSession(
            FakePhysicalSession(serial: "phone-a"), device: .android("phone-a"), port: nil,
            avdName: nil, capabilities: .android(emulatorGrpc: false)
        )
        XCTAssertTrue(model.isAdbRestartUnsafe)
    }
}

@MainActor
final class ProfileOnStoppedDeviceTests: XCTestCase {
    /// A single stopped device gets no profile items: applying one only
    /// answered "Skipped the device: Not running".
    func testAStoppedSingleDeviceCannotTakeAProfile() {
        let model = AppModel.testing()
        model.catalog.avdCards = [AvdCard(
            name: "Pixel_Off", displayName: "Pixel Off", target: "android-36", skin: nil, isRunning: false, serial: nil
        )]
        model.workspace.deviceSelection = .avd("Pixel_Off")
        XCTAssertFalse(model.profileTargets(in: model.workspace).isEmpty, "the row resolves to a target")
        XCTAssertFalse(model.canApplyProfile(in: model.workspace))
    }
}

@MainActor
final class MenuTargetSerialTests: XCTestCase {
    /// With a stopped AVD selected, the context can still hold the device
    /// shown before: the menus must not act on it (Controls ▸ Home sent home to an
    /// emulator that was not shown).
    func testAStoppedAVDSelectionHasNoMenuTarget() {
        let model = AppModel.testing()
        let workspace = model.workspace
        workspace.context.serial = "emulator-5554"
        model.catalog.avdCards = [AvdCard(
            name: "Fold_Off", displayName: "Fold Off", target: "android-36", skin: nil, isRunning: false, serial: nil
        )]
        workspace.deviceSelection = .avd("Fold_Off")
        XCTAssertNil(workspace.menuTargetSerial)
    }
}

@MainActor
final class BatterySaverCaptionTests: XCTestCase {
    /// A charging phone (no Charging row) says why Battery saver is off; an
    /// emulator offers its Charging row instead, and a free switch says nothing.
    func testOnlyAChargingPhoneGetsTheLine() {
        let phone = batterySaverRowModel(saverEnabled: false, effect: nil, devicePowered: true, emulatorCharging: nil)
        XCTAssertNotNil(ControlsView.batterySaverCaption(phone))
        let emulator = batterySaverRowModel(saverEnabled: false, effect: nil, devicePowered: true, emulatorCharging: true)
        XCTAssertNil(ControlsView.batterySaverCaption(emulator))
        let free = batterySaverRowModel(saverEnabled: false, effect: nil, devicePowered: false, emulatorCharging: nil)
        XCTAssertNil(ControlsView.batterySaverCaption(free))
    }
}

final class LiveTransportSelectionTests: XCTestCase {
    /// A selection on a phone's vanished USB serial finds the phone's live
    /// row (its serialno, or one of its listed transports); a live selection
    /// and another phone are left alone.
    func testASelectionFollowsThePhonesLiveTransport() {
        let mdns = "adb-aqaserial001-xMmJsj._adb-tls-connect._tcp"
        let live = AndroidDevice(serial: mdns, state: "device", hardwareSerial: "aqaserial001")
        let ghost = AndroidDevice(serial: "aqaserial001", state: "offline")
        XCTAssertEqual(AppModel.liveTransport(of: "aqaserial001", in: [ghost, live]), mdns)
        let listed = AndroidDevice(serial: mdns, state: "device", hardwareSerial: "X", alternateSerials: ["192.168.1.101:5555"])
        XCTAssertEqual(AppModel.liveTransport(of: "192.168.1.101:5555", in: [listed]), mdns)
        let usb = AndroidDevice(serial: "aqaserial001", state: "device")
        XCTAssertNil(AppModel.liveTransport(of: "aqaserial001", in: [usb, live]), "a live selection stays")
        XCTAssertNil(AppModel.liveTransport(of: "OTHER", in: [live]))
    }
}
