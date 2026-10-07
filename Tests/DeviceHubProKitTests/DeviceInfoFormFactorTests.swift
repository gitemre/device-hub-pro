import XCTest
@testable import DeviceHubProKit

/// The device class the Controls panel gates its rows on
/// (`DeviceInfo.formFactor`, from `ro.build.characteristics`).
final class DeviceInfoFormFactorTests: XCTestCase {
    /// Captured: `adb -s emulator-5554 shell getprop ro.build.characteristics` on the
    /// `Pixel_9_Pro` AVD (API 37.1 phone image) and, the same day, on the
    /// `wearos_small_round_API37.1` AVD, which carries a Wear skin on the same phone
    /// image: both answer `emulator`. The class comes from the running system, not the skin.
    func testPhoneImagesAreHandheldWhateverTheirSkin() {
        XCTAssertEqual(DeviceInfo.formFactor(characteristics: "emulator"), .handheld)
        XCTAssertEqual(DeviceInfo.formFactor(characteristics: ""), .handheld, "not read yet")
        XCTAssertEqual(DeviceInfo.formFactor(characteristics: "nosdcard"), .handheld)
    }

    /// SOURCE-DERIVED: AOSP's `PRODUCT_CHARACTERISTICS` convention (the tokens `tablet`,
    /// `watch`, `tv`, `automotive`, `desktop`); no Wear OS, TV, automotive or desktop
    /// image is installed on the test machine to capture one. `xr` is a guess at
    /// the token of Android XR images and is unverified.
    func testTheDeclaredTokensPickTheClass() {
        XCTAssertEqual(DeviceInfo.formFactor(characteristics: "tablet"), .handheld)
        XCTAssertEqual(DeviceInfo.formFactor(characteristics: "emulator,nosdcard,watch"), .wear)
        XCTAssertEqual(DeviceInfo.formFactor(characteristics: "tv"), .tv)
        XCTAssertEqual(DeviceInfo.formFactor(characteristics: "emulator,tv"), .tv)
        XCTAssertEqual(DeviceInfo.formFactor(characteristics: "emulator, automotive"), .automotive)
        XCTAssertEqual(DeviceInfo.formFactor(characteristics: "Desktop"), .desktop)
        XCTAssertEqual(DeviceInfo.formFactor(characteristics: "xr"), .xr)
        // A token is whole: a product named "tvbox" is no TV.
        XCTAssertEqual(DeviceInfo.formFactor(characteristics: "tvbox"), .handheld)
    }

    func testDeviceInfoReadsTheCharacteristicsProperty() {
        let info = DeviceInfo.from(
            serial: "emulator-5554",
            properties: ["ro.build.characteristics": "emulator,nosdcard,watch"],
            isEmulator: true
        )
        XCTAssertEqual(info.characteristics, "emulator,nosdcard,watch")
        XCTAssertEqual(info.formFactor, .wear)
        XCTAssertEqual(DeviceInfo.from(serial: "x", properties: [:], isEmulator: false).formFactor, .handheld)
    }
}
