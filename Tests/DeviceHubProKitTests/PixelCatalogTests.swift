import XCTest
@testable import DeviceHubProKit

final class PixelCatalogTests: XCTestCase {
    func testDeviceFilteringAndNames() throws {
        let skins = try Self.temporarySkins(names: [
            "pixel_2", "pixel_9_pro", "pixel_fold", "pixel_tablet",
            "pixel_silver", "pixel_xl_silver", "nexus_5", "tv_1080p",
        ])
        let devices = PixelCatalog.devices(
            skins: skins,
            installedAvdNames: [],
            avdDevices: [
                AvdDevice(id: "pixel", name: "Pixel"),
                AvdDevice(id: "pixel_xl", name: "Pixel XL"),
                AvdDevice(id: "pixel_9_pro", name: "Pixel 9 Pro"),
                AvdDevice(id: "pixel_fold", name: "Pixel Fold"),
                AvdDevice(id: "pixel_tablet", name: "Pixel Tablet"),
            ],
            avdHome: nil
        )
        let names = devices.map(\.skinName)
        // Newest first (`SkinReleaseOrder`).
        let expected = ["pixel_9_pro", "pixel_fold", "pixel_tablet", "pixel_2", "pixel_silver", "pixel_xl_silver"]
        XCTAssertEqual(names, expected)
        XCTAssertFalse(names.contains("nexus_5"))
        XCTAssertFalse(names.contains("tv_1080p"))
        XCTAssertEqual(devices.first(where: { $0.skinName == "pixel_silver" })?.deviceProfileID, "pixel")
        XCTAssertEqual(devices.first(where: { $0.skinName == "pixel_xl_silver" })?.deviceProfileID, "pixel_xl")
        XCTAssertEqual(devices.first(where: { $0.skinName == "pixel_fold" })?.category, .foldable)
        XCTAssertEqual(devices.first(where: { $0.skinName == "pixel_tablet" })?.category, .tablet)
    }

    func testInstalledAvdMatching() throws {
        let root = try Self.temporaryRoot()
        let skins = try Self.temporarySkins(names: ["pixel_9_pro"], root: root)
        let avdHome = root.appendingPathComponent("avd", isDirectory: true)
        try Self.writeConfig(
            "hw.device.name=pixel_9_pro\nskin.name=pixel_9_pro\n",
            avdName: "Pixel_9_Pro",
            avdHome: avdHome
        )
        try Self.writeConfig(
            "hw.device.name=pixel_9_pro\nskin.name=2208x1840\n",
            avdName: "Generic",
            avdHome: avdHome
        )

        let devices = PixelCatalog.devices(
            skins: skins,
            installedAvdNames: ["Pixel_9_Pro", "Generic", "Unrelated"],
            avdDevices: [AvdDevice(id: "pixel_9_pro", name: "Pixel 9 Pro")],
            avdHome: avdHome
        )
        XCTAssertEqual(devices.first?.installedAvdNames, ["Generic", "Pixel_9_Pro"])
    }

    func testAvdNameCollisionSuffixes() {
        let device = PixelDevice(
            skinName: "pixel_9_pro",
            displayName: "Pixel 9 Pro",
            category: .phone,
            skin: Self.entry(name: "pixel_9_pro"),
            deviceProfileID: "pixel_9_pro",
            minApi: "35",
            playstoreEnabled: true,
            installedAvdNames: []
        )
        let image = SystemImage(
            package: "system-images;android-35;google_apis;arm64-v8a",
            api: "android-35",
            tag: "google_apis",
            abi: "arm64-v8a"
        )
        XCTAssertEqual(PixelCatalog.avdName(for: device, image: image, existing: []), "Pixel_9_Pro")
        XCTAssertEqual(
            PixelCatalog.avdName(for: device, image: image, existing: ["Pixel_9_Pro"]),
            "Pixel_9_Pro_API35"
        )
        XCTAssertEqual(
            PixelCatalog.avdName(
                for: device,
                image: image,
                existing: ["Pixel_9_Pro", "Pixel_9_Pro_API35"]
            ),
            "Pixel_9_Pro_API35_2"
        )
        // The volume ignores case, so the name ladder must too: `pixel_9_pro`
        // on disk is the same folder as `Pixel_9_Pro`.
        XCTAssertEqual(
            PixelCatalog.avdName(
                for: device,
                image: image,
                existing: ["pixel_9_pro", "PIXEL_9_PRO_API35"]
            ),
            "Pixel_9_Pro_API35_2"
        )
    }

    // MARK: - Helpers

    static func entry(
        name: String,
        directory: URL = URL(fileURLWithPath: "/tmp")
    ) -> SkinCatalogEntry {
        SkinCatalogEntry(
            name: name,
            displayName: SkinResolver.displayName(forSkinName: name),
            category: SkinResolver.category(forSkinName: name),
            directory: directory,
            variants: []
        )
    }

    static func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pixel-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func temporarySkins(names: [String], root: URL? = nil) throws -> [SkinCatalogEntry] {
        let base = try root ?? temporaryRoot()
        let skins = base.appendingPathComponent("skins", isDirectory: true)
        for name in names {
            let dir = skins.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "parts {}\nlayouts {}\n".write(
                to: dir.appendingPathComponent("layout"),
                atomically: true,
                encoding: .utf8
            )
        }
        return names.map {
            entry(name: $0, directory: skins.appendingPathComponent($0, isDirectory: true))
        }
    }

    static func writeConfig(_ text: String, avdName: String, avdHome: URL) throws {
        let dir = avdHome.appendingPathComponent("\(avdName).avd", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(
            to: dir.appendingPathComponent("config.ini"),
            atomically: true,
            encoding: .utf8
        )
    }
}
