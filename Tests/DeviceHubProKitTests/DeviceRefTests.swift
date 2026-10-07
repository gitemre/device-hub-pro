import Foundation
import XCTest
@testable import DeviceHubProKit

/// The platform-neutral device identity: which identifiers reach adb, the
/// encoded shape a stored reference keeps, and the Android capability
/// buckets.
final class DeviceRefTests: XCTestCase {
    func testOnlyAnAndroidReferenceHasAnAdbSerial() {
        XCTAssertEqual(DeviceRef.android("emulator-5554").adbSerial, "emulator-5554")
        XCTAssertEqual(DeviceRef(platform: .android, id: "HT4CWJT01234").adbSerial, "HT4CWJT01234")
        XCTAssertNil(DeviceRef.apple("00000000-0000-0000-0000-000000000000").adbSerial)
    }

    /// The same id on two platforms is two devices.
    func testThePlatformIsPartOfTheIdentity() {
        XCTAssertNotEqual(DeviceRef.android("A1"), DeviceRef.apple("A1"))
        XCTAssertEqual(Set([DeviceRef.android("A1"), .apple("A1"), .android("A1")]).count, 2)
    }

    func testAReferenceEncodesAsItsPlatformAndId() throws {
        let reference = DeviceRef.apple("00000000-0000-0000-0000-000000000000")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(reference), as: UTF8.self)
        XCTAssertEqual(json, #"{"id":"00000000-0000-0000-0000-000000000000","platform":"apple"}"#)
        XCTAssertEqual(try JSONDecoder().decode(DeviceRef.self, from: Data(json.utf8)), reference)
    }

    func testAnEmulatorAddsTheGrpcBucketAPhoneLacks() {
        let emulator = DeviceCapabilities.android(emulatorGrpc: true)
        let phone = DeviceCapabilities.android(emulatorGrpc: false)

        for bucket: DeviceCapabilities in [.adbSettings, .androidKeys, .mirror, .screenshot, .record] {
            XCTAssertTrue(emulator.contains(bucket))
            XCTAssertTrue(phone.contains(bucket))
        }
        XCTAssertTrue(emulator.isSuperset(of: phone))
        XCTAssertEqual(emulator.subtracting(phone), [.emulatorGrpc, .rotate, .location])
        XCTAssertTrue(emulator.isDisjoint(with: [.statusBar, .privacy, .push, .hardwareButtons]))
    }

    /// A simulator's live canvas takes input and presses buttons; the
    /// view-only one only shows and shakes, and rotates only where
    /// devicectl can (the default set). Neither has an Android bucket.
    func testASimulatorCanvasOffersWhatItsTransportCan() {
        let live = DeviceCapabilities.simulator(liveCanvas: true, rotatesWithoutBridge: false)
        XCTAssertEqual(live, [.mirror, .touch, .keyboard, .rotate, .hardwareButtons, .shake])
        XCTAssertEqual(DeviceCapabilities.simulator(liveCanvas: true, rotatesWithoutBridge: true), live)
        XCTAssertEqual(DeviceCapabilities.simulator(liveCanvas: false, rotatesWithoutBridge: true), [.mirror, .rotate, .shake])
        XCTAssertEqual(DeviceCapabilities.simulator(liveCanvas: false, rotatesWithoutBridge: false), [.mirror, .shake])
        XCTAssertTrue(live.isDisjoint(with: [.adbSettings, .emulatorGrpc, .androidKeys]))
    }

    /// Every capability is a bit of its own.
    func testTheCapabilityBitsAreDistinct() {
        let all: [DeviceCapabilities] = [
            .mirror, .touch, .keyboard, .rotate, .screenshot, .record, .apps, .logs, .clipboard, .location, .openURL,
            .statusBar, .privacy, .push, .hardwareButtons, .shake,
            .adbSettings, .emulatorGrpc, .androidKeys,
        ]
        for capability in all {
            XCTAssertEqual(capability.rawValue.nonzeroBitCount, 1)
        }
        XCTAssertEqual(Set(all.map(\.rawValue)).count, all.count)
    }
}
