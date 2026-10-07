import XCTest
@testable import DeviceHubProKit

/// `avdmanager list device` from cmdline-tools 23.0.0 on a fresh macOS 26.6
/// VM (96 definitions, no skins folder): the Phone/Tablet/... sheets' model
/// lists are built from this capture. The expected lists are read off the
/// capture's own `Tag :` lines and names.
final class AvdDeviceCatalogTests: XCTestCase {
    private static let devices: [AvdDevice] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/cmdline-tools-23/avdmanager-list-device.stdout")
        let text = String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
        return AvdmanagerParsing.devices(from: text)
    }()

    func testParsesEveryEntryWithItsTag() {
        let devices = Self.devices
        XCTAssertEqual(devices.count, 96)
        XCTAssertEqual(Set(devices.map(\.id)).count, 96)
        XCTAssertEqual(devices.first, AvdDevice(id: "ai_glasses_displayless", name: "Audio Glasses", tag: "ai-glasses"))
        // Entries without a Tag line keep neither a stale tag nor a stale name.
        XCTAssertEqual(devices.first { $0.id == "Galaxy Nexus" }, AvdDevice(id: "Galaxy Nexus", name: "Galaxy Nexus"))
        XCTAssertEqual(devices.first { $0.id == "Nexus 10" }, AvdDevice(id: "Nexus 10", name: "Nexus 10"))
        XCTAssertEqual(devices.first { $0.id == "medium_phone" }, AvdDevice(id: "medium_phone", name: "Medium Phone"))
        XCTAssertEqual(devices.first { $0.id == "tv_4k" }?.tag, "android-tv")
    }

    func testPhoneSheetListsOnlyPhonesNewestPixelFirst() {
        let phones = AvdDeviceCatalog.models(for: .phone, in: Self.devices)
        XCTAssertEqual(phones.prefix(6).map(\.name), [
            "Pixel 10 Pro", "Pixel 10 Pro XL", "Pixel 10", "Pixel 10a", "Pixel 9 Pro", "Pixel 9 Pro XL",
        ])
        let ids = Set(phones.map(\.id))
        for excluded in [
            "ai_glasses_displayless", "automotive_portrait", "desktop_api37", "tv_4k", "wearos_rect",
            "xr_headset_device", "pixel_10_pro_fold", "pixel_tablet", "Nexus 10", "medium_tablet",
            "10.1in WXGA (Tablet)", "7.6in Foldable", "resizable",
        ] {
            XCTAssertFalse(ids.contains(excluded), "\(excluded) is not a phone")
        }
        XCTAssertTrue(ids.isSuperset(of: ["medium_phone", "small_phone", "Nexus 5", "Galaxy Nexus", "5.4in FWVGA", "pixel", "pixel_xl"]))
    }

    func testOtherSheets() {
        let tablets = AvdDeviceCatalog.models(for: .tablet, in: Self.devices)
        XCTAssertEqual(tablets.prefix(2).map(\.id), ["pixel_tablet", "pixel_c"])
        XCTAssertTrue(tablets.contains { $0.id == "Nexus 9" })
        XCTAssertEqual(
            AvdDeviceCatalog.models(for: .foldable, in: Self.devices).prefix(3).map(\.id),
            ["pixel_10_pro_fold", "pixel_9_pro_fold", "pixel_fold"]
        )
        XCTAssertEqual(AvdDeviceCatalog.models(for: .wear, in: Self.devices).count, 5)
        XCTAssertEqual(AvdDeviceCatalog.models(for: .tv, in: Self.devices).count, 3)
        XCTAssertEqual(AvdDeviceCatalog.models(for: .automotive, in: Self.devices).count, 9)
    }
}
